#!/usr/bin/env python3
#
# Script Name: nic-report.py
# Description: Companion to nic-xray.sh, nic-health.sh and nic-sweep.sh. Reads nic-sweep sweeps
#              (and legacy nic-health CSV) for one site, several or all, and writes a report:
#              coverage and comparability, verdicts, every finding with its evidence, fleet
#              baselines and outliers, patterns within and across sites, and known issues suppressed
#              on request (Markdown, JSON, HTML, PDF). Read-only, offline: never contacts a host or
#              the network.
#              Design: docs/design/nic-sweep.md (§6)
#
# Author: Ciro Iriarte <ciro.iriarte+software@gmail.com>
# Created: 2026-10-26
#
# Requirements:
#   - Python 3.9 or newer, standard library only (the one Python script in the repo: CLAUDE.md §2)
#   - Optional: WeasyPrint, imported only for -O pdf (python3-weasyprint or pip install weasyprint)
#
# Change Log:
#   - 2026-10-26: Phase 3 of docs/design/nic-sweep.md: sweep and legacy CSV loaders, site
#                 selection (-R, -s, --at), record model, evidence extractors, coverage (A1),
#                 verdicts (A2) and findings (A3) in single- and multi-site layouts; Markdown and JSON
#   - 2026-10-26: Phase 4: baselines and outliers (A4) over ports with link, patterns within and across
#                 sites (A5), --baseline scope|all, self-contained HTML output
#   - 2026-10-26: Phase 5: PDF via WeasyPrint (cover, contents with page numbers, running header and
#                 footer with the classification, landscape pages for wide tables), --suppress (A7),
#                 --per-site, themes (--theme, NIC_REPORT_THEME, --strict-theme) and attribution
#
# Version: 2.13.0
"""nic-report.py: single- and multi-site reports from nic-sweep sweeps and legacy nic-health CSV."""

import argparse
import base64
import collections
import contextlib
import csv
import datetime
import glob
import html
import json
import logging
import math
import os
import re
import secrets
import stat
import statistics
import sys

SCRIPT_VERSION = "2.13.0"
SCRIPT_NAME = "nic-report.py"
REPORT_SCHEMA_VERSION = 1
SWEEP_SCHEMA_MAJOR = 1          # newest sweep.json major version this tool understands
DESIGN_REF = "docs/design/nic-sweep.md"
MIN_PYTHON = (3, 9)
AUTHOR = "Ciro Iriarte"

# Exit codes (design §6.5)
EXIT_OK = 0
EXIT_INPUT = 1
EXIT_USAGE = 3

SEVERITIES = ("CRIT", "WARN", "UNKNOWN", "OK", "N/A")
FINDING_SEVERITIES = ("CRIT", "WARN", "UNKNOWN")
VERDICTS = ("OK", "WARN", "CRIT", "UNKNOWN")
# Worst first; a host's verdict from records follows nic-health: CRIT > WARN > UNKNOWN > OK
VERDICT_RANK = {"CRIT": 3, "WARN": 2, "UNKNOWN": 1, "OK": 0, "N/A": 0}
RANK_VERDICT = {3: "CRIT", 2: "WARN", 1: "UNKNOWN", 0: "OK"}
MANIFEST_REQUIRED = ("host", "status")
RECORD_FIELDS = ("severity", "scope", "target", "check_id", "value", "unit", "threshold", "evidence", "hint", "ref")
ST_OK = "ok"
ST_IMPORTED = "imported"
# A host nic-sweep collected whose nodes/<host>.json is missing or malformed: reported, not fatal
ST_UNREADABLE = "unreadable-result"
NO_ROLE = "(no role)"
# nic-health versions that introduced fields this report relies on
LINK_STATE_MIN_VERSION = "2.12.0"     # generic.link.state
HOST_CLOCK_MIN_VERSION = "2.13.0"     # uptime_s, boot_id in the JSON envelope
BER_UNDERFLOW = 1e-30                 # below this a BER is a "zero" placeholder (e.g. 15E-255)
NOT_AVAILABLE = ("", "-", "n/a", "N/A")
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
# C0/C1 controls (tab, newline and the like are folded to spaces instead) and bidi overrides/isolates,
# which could make untrusted text display differently from what it is
CONTROL_RE = re.compile("[\x00-\x08\x0e-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]")
SWEEP_TS_RE = re.compile(r"^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$")
AT_RE = re.compile(r"^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}(:\d{2})?Z?)?$")
# Terminal captures wrapped long fields with a run of spaces between two non-space characters (legacy
# import only). Removing the run rejoins split words; when the wrap fell on a real space two words join,
# an accepted cost: real nic-health fields never contain 5 spaces in a row
WRAP_RE = re.compile(r"(?<=\S) {5,}(?=\S)")
# nic-health's evidence for a counter check whose counters are all zero
COUNTERS_ZERO_RE = re.compile(r"\ball \d+ counters are 0\b")
DEEP_PREFIX = "mlx5.deep."
LINK_STATE = "generic.link.state"
LINK_FLAPS = "generic.link.flaps"
LINK_UP = "up"
PCIE_LINK = "generic.pcie.link"
DEEP_FEC = "mlx5.deep.fec"
MAX_EVIDENCE = 300              # characters of evidence shown per finding in Markdown

# Baselines and outliers (design §6.3 A4); thresholds are options where the design says so
DEFAULT_RX_DELTA_DB = 5.0       # --rx-delta-db: Rx this far below its group's median is an outlier...
ROBUST_Z_MIN = 3.5              # ...when its robust score (median/MAD) is also at least this far out
MAD_SCALE = 1.4826              # MAD to standard deviation for normal data
DEFAULT_FLAP_MIN = 100          # --flap-min: carrier changes since driver load worth listing
MIN_GROUP_PORTS = 3             # fewer linked ports than this make no baseline
NEAR_LIMIT_DB = 3.0             # Rx within this of the module's own low limit (its [low..high] range)
TEMP_MARGIN_C = 10              # module temperature within this of its own high limit
NO_LIGHT_DBM = -40.0            # what modules report without light
TOP_N = 10                      # rows of "highest" lists
TOP_HOT = 5                     # hottest modules listed
PATTERN_ITEMS_SHOWN = 6         # places listed per pattern row before "and N more"
MAX_COUNTER_DIGITS = 20         # 64-bit counters; longer digit runs in untrusted input are not counters
SECONDS_PER_HOUR = 3600
BASELINES = ("scope", "all")
OUTLIER_KIND = "Rx outlier (low)"
FLAP_KIND = "link flaps since driver load"
# One physical fault raises several checks; patterns group them into one issue family
ISSUE_FAMILY = {"mlx5.phy.errors": "link errors (symbol/CRC/BER)", "mlx5.frame.errors": "link errors (symbol/CRC/BER)",
                "mlx5.deep.ber": "link errors (symbol/CRC/BER)", "generic.link.lookback": "link instability",
                "generic.link.flaps": "link instability",
                FLAP_KIND: "link instability", "mlx5.link.phy_down": "link instability"}
PCIE_BELOW = "PCIe below capability"

# Known tool issues (design §6.3 A7): --suppress FILE
SUPPRESS_SCHEMA_VERSION = 1
SUPPRESS_TOP_KEYS = ("schema_version", "suppress")
SUPPRESS_REQUIRED = ("check_id", "reason")
SUPPRESS_OPTIONAL = ("match", "hosts", "sites")
SUPPRESS_MAX = 1024 * 1024      # bytes of a --suppress file
EVIDENCE_MATCH_MAX = 4096       # characters of target/evidence a 'match' regex searches (host-controlled text)
CELL_PIPE = "¦"                 # '|' inside a code span in a table cell (a real '|' would split the cell)
TEMP_NAME_BYTES = 8             # random bytes in an output temp file name

# Themes (design §6.8): --theme DIR or the environment; brand colours, fonts, logos and labels only
THEME_ENV = "NIC_REPORT_THEME"
THEME_SCHEMA_VERSION = 1
THEME_FILE = "theme.json"
THEME_CSS_FILE = "extra.css"            # not supported: free-form CSS could change content (design §6.8)
THEME_REQUIRED = ("schema_version", "name", "org", "colors")
THEME_OPTIONAL = ("fonts", "logos", "labels")
THEME_COLORS = ("primary_dark", "primary", "accent", "link_dark", "header_bg", "header_fg")
THEME_FONT_KEYS = ("heading", "body")
THEME_LOGO_KEYS = ("cover", "header")       # cover: for dark backgrounds (PDF cover); header: for light ones
THEME_LABEL_KEYS = ("header_title", "classification")
COLOR_RE = re.compile(r"^#[0-9A-Fa-f]{6}$")
FONT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$")
EMOJI_FONT_RE = re.compile(r"emoji", re.I)  # never named explicitly (design §6.4): fontconfig falls back to it
MAX_FONTS = 8
MAX_LABEL = 200
THEME_JSON_MAX = 64 * 1024
LOGO_MAX_BYTES = 512 * 1024
MIN_CONTRAST = 4.5                          # WCAG AA for normal text
WHITE = "#ffffff"
LOGO_MAGIC = ((b"\x89PNG\r\n\x1a\n", "image/png"), (b"\xff\xd8\xff", "image/jpeg"))
SVG_SNIFF_BYTES = 4096
FONT_FALLBACK = '"Liberation Sans","DejaVu Sans",sans-serif'

# PDF (design §6.4)
PDF_PACKAGE_HINT = "python3-weasyprint, or pip install weasyprint"
REPORT_MODE = 0o640             # report files hold host names and switch ports (umask still applies)
WIDE_ROW_CHARS = 150            # a table whose Markdown row is longer than this gets a landscape page...
WIDE_COLS = 10                  # ...and so does one with this many columns
WIDE_LEAD_MAX = 2               # paragraphs before a wide table that move with it (plus its heading)


class InputError(Exception):
    """Unreadable input, unknown schema or an impossible selection (exit 1)."""


# --------------------------------------------------------------------------------- extractors
# One small function per value (design §6.2). Each returns None when the value is absent or does not
# parse: never 0. Inputs are nic-health evidence/value strings.

def _float(text):
    """A finite float or None (untrusted input: '1e999' would be inf, which JSON cannot carry)."""
    try:
        v = float(text)
    except (TypeError, ValueError):
        return None
    return v if math.isfinite(v) else None


def _lanes_with_range(label, evidence):
    """('a,b,c' values, (low, high)) for 'Label=a,b,c [low..high]'; None when absent."""
    m = re.search(re.escape(label) + r"=(-?[\d.]+(?:,-?[\d.]+)*) \[(-?[\d.]+)\.\.(-?[\d.]+)\]", evidence or "")
    if not m:
        return None
    lanes = [_float(v) for v in m.group(1).split(",")]
    if any(v is None for v in lanes):
        return None
    return lanes, (_float(m.group(2)), _float(m.group(3)))


def _power(label, evidence):
    """Module optical power in dBm: lowest lane on multi-lane modules, lanes, module range, and whether
    nic-health judged it (it does not without link: '(not judged: no link)')."""
    got = _lanes_with_range(label, evidence)
    if not got:
        return None
    lanes, rng = got
    judged = not re.search(re.escape(label) + r"=[^;]*\(not judged", evidence)
    return {"dbm": min(lanes), "lanes": lanes if len(lanes) > 1 else None, "low": rng[0], "high": rng[1],
            "judged": judged}


def extract_rx_dbm(evidence):
    return _power("Rx Power Current [dBm]", evidence)


def extract_tx_dbm(evidence):
    return _power("Tx Power Current [dBm]", evidence)


def extract_module_temp_c(evidence):
    got = _lanes_with_range("Temperature [C]", evidence)
    return None if not got else {"c": got[0][0], "low": got[1][0], "high": got[1][1]}


def _counter(name, evidence):
    """(total, window delta or None) for 'name=TOTAL (+DELTA)' or 'name=TOTAL'; (0, 0) when nic-health
    reported all of the check's counters as zero. A counter absent while others of the check are shown
    stays None: nic-health omits zeros there, but absence can also mean the firmware lacks the counter."""
    m = re.search(r"\b" + re.escape(name) + r"=(\d{1,%d})\b(?: \(\+(\d{1,%d})\))?" % (MAX_COUNTER_DIGITS, MAX_COUNTER_DIGITS),
                  evidence or "")
    if not m:
        return (0, 0) if COUNTERS_ZERO_RE.search(evidence or "") else None
    return int(m.group(1)), (int(m.group(2)) if m.group(2) is not None else None)


def extract_symbol_errors(evidence):
    got = _counter("rx_symbol_err_phy", evidence)
    return None if not got else {"total": got[0], "delta": got[1]}


def extract_crc_errors(evidence):
    got = _counter("rx_crc_errors_phy", evidence)
    return None if not got else {"total": got[0], "delta": got[1]}


def extract_discards(evidence):
    got = _counter("rx_discards_phy", evidence)
    return None if not got else {"total": got[0], "delta": got[1]}


def extract_carrier_changes(evidence):
    m = re.search(r"\bcarrier_changes=(\d{1,%d})\b" % MAX_COUNTER_DIGITS, evidence or "")
    return int(m.group(1)) if m else None


def extract_aer_totals(evidence):
    m = re.search(r"totals since boot: cor=(\d+) nonfatal=(\d+) fatal=(\d+)", evidence or "")
    return None if not m else {"cor": int(m.group(1)), "nonfatal": int(m.group(2)), "fatal": int(m.group(3))}


def _ber(text):
    """'3E-9' -> 3e-09; '~0' or '15E-255' style underflow -> 0.0; unparseable -> None."""
    text = (text or "").strip()
    if text.startswith("~"):
        return 0.0
    v = _float(text)
    if v is None:
        return None
    return 0.0 if v < BER_UNDERFLOW else v


def extract_ber(evidence):
    m_eff = re.search(r"Effective Physical BER=(\S+)", evidence or "")
    m_raw = re.search(r"Raw Physical BER=(\S+)", evidence or "")
    if not m_eff:
        return None
    m_since = re.search(r"since ([\d.]+) min", evidence or "")
    return {"effective": _ber(m_eff.group(1)), "raw": _ber(m_raw.group(1)) if m_raw else None,
            "since_min": _float(m_since.group(1)) if m_since else None}


def extract_fec(value):
    """FEC mode from the mlx5.deep.fec value ('link: Firecode FEC'); None when the tool reported none."""
    m = re.match(r"link: (.+)$", (value or "").strip())
    if not m or m.group(1).strip() in NOT_AVAILABLE:
        return None
    return m.group(1).strip()



def extract_compliance(evidence):
    m = re.search(r"Compliance=([^;]+)$", (evidence or "").strip())
    if not m or m.group(1).strip() in NOT_AVAILABLE:
        return None
    return m.group(1).strip()


def extract_module_part(evidence):
    """'module VENDOR PART' at the end of the deep module evidence."""
    m = re.search(r"; module (.+)$", (evidence or "").strip())
    return m.group(1).strip() if m and m.group(1).strip() not in NOT_AVAILABLE else None


def metrics_for(check_id, value, evidence):
    """Structured values for one record (design §6.1 'metrics'), by check."""
    out = {}
    if check_id == "mlx5.deep.module":
        for key, fn in (("rx", extract_rx_dbm), ("tx", extract_tx_dbm), ("temp", extract_module_temp_c),
                        ("part", extract_module_part)):
            v = fn(evidence)
            if v is not None:
                out[key] = v
    elif check_id == "mlx5.phy.errors":
        v = extract_symbol_errors(evidence)
        if v is not None:
            out["symbol_errors"] = v
    elif check_id == "mlx5.frame.errors":
        v = extract_crc_errors(evidence)
        if v is not None:
            out["crc_errors"] = v
    elif check_id == "mlx5.nic.discards":
        v = extract_discards(evidence)
        if v is not None:
            out["discards"] = v
    elif check_id == "generic.link.flaps":
        v = extract_carrier_changes(evidence)
        if v is not None:
            out["carrier_changes"] = v
    elif check_id == "generic.pcie.aer":
        v = extract_aer_totals(evidence)
        if v is not None:
            out["aer"] = v
    elif check_id == "mlx5.deep.ber":
        v = extract_ber(evidence)
        if v is not None:
            out["ber"] = v
    elif check_id == DEEP_FEC:
        fec, comp = extract_fec(value), extract_compliance(evidence)
        if fec is not None:
            out["fec"] = fec
        if comp is not None:
            out["compliance"] = comp
    return out


# --------------------------------------------------------------------------------- model

class Host:
    """One host of one site: how it was collected and its records."""

    def __init__(self, site, name, status, verdict=None, exit_code=None, xray=None):
        self.site, self.name, self.status = site, name, status
        self.verdict, self.exit_code, self.xray = verdict, exit_code, xray
        self.role = ""
        self.meta = {}                  # collected_at, tool_version, level, mode, interval_s, uptime_s, boot_id
        self.raw_results = []           # result dicts as read (sweep JSON or CSV rows)
        self.records = []               # normalised records (finalize)
        self.problem = None             # why a collected host's result could not be read
        self.verdict_before = None      # verdict before --suppress recomputed it (only when it did)

    @property
    def collected(self):
        return self.status in (ST_OK, ST_IMPORTED)


class SiteData:
    """The data selected for one site: from a sweep directory or from legacy imports."""

    def __init__(self, site, source, path=None, stamp=None):
        self.site, self.source, self.path, self.stamp = site, source, path, stamp
        self.hosts = {}
        self.host_files = {}            # import: host -> CSV file it came from
        self.repaired_fields = 0
        self.other_site_rows = 0

    def host(self, name, **kw):
        if name not in self.hosts:
            self.hosts[name] = Host(self.site, name, **kw)
        return self.hosts[name]


def _text(value):
    """A record field as text whatever the input type (untrusted files)."""
    return "" if value is None else str(value)


def _typed(value, kind):
    """value when it has the expected type (bool is not an int here), else None."""
    if kind is int and isinstance(value, bool):
        return None
    return value if isinstance(value, kind) else None


def make_record(host, raw):
    rec = {f: _text(raw.get(f)) for f in RECORD_FIELDS}
    rec["site"], rec["host"], rec["role"] = host.site, host.name, host.role
    for key in ("collected_at", "tool_version", "level", "mode", "interval_s", "uptime_s", "boot_id"):
        rec[key] = host.meta.get(key)
    rec["metrics"] = metrics_for(rec["check_id"], rec["value"], rec["evidence"])
    return rec


# --------------------------------------------------------------------------------- loaders

def sweep_stamp_dt(stamp):
    """UTC datetime of a sweep directory name; None when it is not a valid YYYYmmddTHHMMSSZ time."""
    m = SWEEP_TS_RE.match(stamp or "")
    if not m:
        return None
    try:
        return datetime.datetime(*map(int, m.groups()), tzinfo=datetime.timezone.utc)
    except ValueError:
        return None


def read_json(path, limit=None):
    """A JSON document; with limit, a file larger than limit bytes is an input error (read bounded)."""
    try:
        with open(path, "rb") as fh:
            data = fh.read() if limit is None else fh.read(limit + 1)
        if limit is not None and len(data) > limit:
            raise InputError(f"{path}: larger than {limit // 1024} KiB")
        return json.loads(data.decode("utf-8"))
    except (OSError, ValueError, RecursionError) as exc:      # RecursionError: absurdly deep nesting
        raise InputError(f"{path}: {exc}") from exc


def load_sweep_dir(path):
    """Load one nic-sweep directory (design §5.4) into a SiteData."""
    meta_path = os.path.join(path, "sweep.json")
    if not os.path.isfile(meta_path):
        raise InputError(f"{path}: not a nic-sweep directory (no sweep.json)")
    meta = read_json(meta_path)
    if not isinstance(meta, dict):
        raise InputError(f"{meta_path}: not a sweep.json object")
    version = meta.get("schema_version")
    if type(version) is not int or version > SWEEP_SCHEMA_MAJOR or version < 1:
        raise InputError(f"{meta_path}: unsupported sweep schema_version {version!r} "
                         f"(this {SCRIPT_NAME} reads up to {SWEEP_SCHEMA_MAJOR})")
    site = meta.get("site")
    if not (isinstance(site, str) and NAME_RE.match(site)):
        raise InputError(f"{meta_path}: invalid site name {site!r}")
    data = SiteData(site, "sweep", path=path, stamp=os.path.basename(os.path.normpath(path)))
    manifest = os.path.join(path, "MANIFEST.tsv")
    try:
        with open(manifest, encoding="utf-8", newline="") as fh:
            reader = csv.DictReader(fh, delimiter="\t")
            rows = list(reader)
            missing = [c for c in MANIFEST_REQUIRED if c not in (reader.fieldnames or [])]
    except (OSError, UnicodeDecodeError, csv.Error) as exc:
        raise InputError(f"{manifest}: {exc}") from exc
    if missing:
        raise InputError(f"{manifest}: not a nic-sweep manifest (missing columns: {', '.join(missing)})")
    if not rows:
        raise InputError(f"{manifest}: lists no hosts")
    for row in rows:
        name = row.get("host") or ""
        if not (isinstance(name, str) and NAME_RE.match(name)):
            raise InputError(f"{manifest}: invalid host name {name!r}")
        verdict = row.get("verdict") if row.get("verdict") in VERDICTS else None
        host = data.host(name, status=row.get("status") or "", verdict=verdict,
                         exit_code=row.get("exit_code"), xray=row.get("xray"))
        if host.status == ST_OK:
            load_node(path, host)
    return data


def load_node(path, host):
    """Read nodes/<host>.json of a collected host. A missing or malformed file marks that host
    unreadable (listed with the hosts not collected) instead of failing the whole report."""
    node = os.path.join(path, "nodes", host.name + ".json")
    try:
        doc = read_json(node)
        if not isinstance(doc, dict):
            raise InputError(f"{node}: not a nic-health JSON object")
        results = doc.get("results")
        if not isinstance(results, list) or not all(isinstance(r, dict) for r in results):
            raise InputError(f"{node}: 'results' is not a list of objects")
    except InputError as exc:
        host.status, host.problem, host.verdict = ST_UNREADABLE, str(exc), None
        return
    host.meta = {"collected_at": _typed(doc.get("collected_at"), str), "tool_version": _typed(doc.get("version"), str),
                 "level": _typed(doc.get("level"), str), "mode": _typed(doc.get("mode"), str),
                 "interval_s": _typed(doc.get("interval_s"), int), "uptime_s": _typed(doc.get("uptime_s"), int),
                 "boot_id": _typed(doc.get("boot_id"), str)}
    host.raw_results = results
    if host.verdict is None:
        # The manifest's verdict column was missing or invalid: the document's, else from the records
        host.verdict = doc.get("verdict") if doc.get("verdict") in VERDICTS else worst_verdict(results)


def worst_verdict(rows):
    """nic-health's order over result rows: CRIT > WARN > UNKNOWN > OK."""
    return RANK_VERDICT[max((VERDICT_RANK.get(_text(r.get("severity")), 0) for r in rows), default=0)]


def _clean_csv_lines(path):
    """CSV text lines tolerating CRLF and leading blank lines (terminal captures)."""
    try:
        with open(path, encoding="utf-8", newline="") as fh:
            lines = [ln.replace("\r", "") for ln in fh]
    except (OSError, UnicodeDecodeError) as exc:
        raise InputError(f"{path}: {exc}") from exc
    # A NUL byte means a binary or corrupt file; checked here because csv accepts NUL since Python 3.11
    if any("\0" in ln for ln in lines):
        raise InputError(f"{path}: contains NUL bytes (binary or corrupt file)")
    while lines and not lines[0].strip():
        lines.pop(0)
    return lines


def host_from_filename(path):
    """Host name of a per-host CSV: the file name up to the first '_' or '.'."""
    base = os.path.basename(path)
    return re.split(r"[_.]", base, maxsplit=1)[0]


def import_csv(data, path):
    """Add one legacy nic-health CSV (per-host, or merged with site/hostname) to SiteData. A host may come
    from one file only: two captures of the same host would be counted twice."""
    lines = _clean_csv_lines(path)
    if not lines:
        raise InputError(f"{path}: empty file")
    try:
        reader = csv.DictReader(lines)
        cols = set(reader.fieldnames or [])
        missing = [c for c in RECORD_FIELDS if c not in cols]
        if missing:
            raise InputError(f"{path}: not nic-health CSV (missing columns: {', '.join(missing)})")
        merged = "hostname" in cols
        added = 0
        for row in reader:
            if merged:
                if row.get("site") and row["site"] != data.site:
                    data.other_site_rows += 1
                    continue
                name = row.get("hostname") or ""
            else:
                name = host_from_filename(path)
            if not NAME_RE.match(name):
                raise InputError(f"{path}: invalid host name {name!r}")
            first = data.host_files.setdefault(name, os.path.realpath(path))
            if first != os.path.realpath(path):
                raise InputError(f"host {name} of site {data.site} is in two files: {first} and {path}; "
                                 "import one capture per host")
            for f in RECORD_FIELDS:
                fixed = WRAP_RE.sub("", row.get(f) or "")
                if fixed != (row.get(f) or ""):
                    data.repaired_fields += 1
                row[f] = fixed
            data.host(name, status=ST_IMPORTED).raw_results.append(row)
            added += 1
    except csv.Error as exc:
        raise InputError(f"{path}: {exc}") from exc
    if not added:
        raise InputError(f"{path}: no rows for site {data.site}")


def import_paths(site, paths):
    if not NAME_RE.match(site):
        raise InputError(f"--import: invalid site name {site!r}")
    data = SiteData(site, "import", path=", ".join(paths))
    files = []
    for p in paths:
        if os.path.isdir(p):
            files += sorted(glob.glob(os.path.join(p, "*.csv")))
        elif os.path.isfile(p):
            files.append(p)
        else:
            raise InputError(f"--import {site}: {p}: no such file or directory")
    if not files:
        raise InputError(f"--import {site}: no CSV file found in {', '.join(paths)}")
    # The same file named twice (or a directory and a file in it) is imported once
    unique, seen = [], set()
    for f in files:
        real = os.path.realpath(f)
        if real not in seen:
            seen.add(real)
            unique.append(f)
    for f in unique:
        import_csv(data, f)
    for host in data.hosts.values():
        host.verdict = worst_verdict(host.raw_results)
    return data


def role_of(name, role_re):
    """Role from a host name: the regex group named 'role', else its first group; '' without a match."""
    if role_re is None:
        return ""
    m = role_re.search(name)
    if not m:
        return ""
    return (m.group("role") if "role" in role_re.groupindex else m.group(1)) or ""


def finalize(data, role_re):
    """Assign roles and build records once the site's hosts are known."""
    for host in data.hosts.values():
        host.role = role_of(host.name, role_re)
        host.records = [make_record(host, raw) for raw in host.raw_results]
    return data


# --------------------------------------------------------------------------------- selection

def list_tree(root):
    """{site: [stamp, ...] (sorted)} of a nic-sweep tree."""
    if not os.path.isdir(root):
        raise InputError(f"--sweep-root {root}: not a directory")
    tree = {}
    for site in sorted(os.listdir(root)):
        sdir = os.path.join(root, site)
        if not (NAME_RE.match(site) and os.path.isdir(sdir)):
            continue
        stamps = sorted(s for s in os.listdir(sdir)
                        if sweep_stamp_dt(s) and os.path.isfile(os.path.join(sdir, s, "sweep.json")))
        if stamps:
            tree[site] = stamps
    return tree


def parse_at(text):
    """End of the given UTC day (date only) or the given instant."""
    if not AT_RE.match(text):
        raise ValueError(text)
    if "T" not in text:
        day = datetime.datetime.strptime(text, "%Y-%m-%d").replace(tzinfo=datetime.timezone.utc)
        return day + datetime.timedelta(days=1) - datetime.timedelta(seconds=1)
    text = text.rstrip("Z")
    fmt = "%Y-%m-%dT%H:%M:%S" if text.count(":") == 2 else "%Y-%m-%dT%H:%M"
    return datetime.datetime.strptime(text, fmt).replace(tzinfo=datetime.timezone.utc)


def select(args):
    """Resolve the selection: (list of SiteData paths/imports to load, missing sites)."""
    chosen, missing = [], []
    if args.sweep_root:
        tree = list_tree(args.sweep_root)
        wanted = args.site or sorted(tree)
        unknown = [s for s in wanted if s not in tree]
        if unknown:
            raise InputError(f"unknown site(s) {', '.join(unknown)} in {args.sweep_root}; "
                             f"available: {', '.join(sorted(tree)) or 'none'}")
        for site in wanted:
            stamps = tree[site]
            if args.at:
                stamps = [s for s in stamps if sweep_stamp_dt(s) <= args.at]
            if not stamps:
                missing.append(site)
                continue
            chosen.append(("tree", (site, os.path.join(args.sweep_root, site, stamps[-1]))))
    elif args.site:
        raise InputError("--site needs --sweep-root")
    for d in args.sweep_dirs:
        chosen.append(("sweep", d))
    for imp in args.imports or []:
        chosen.append(("import", imp))
    return chosen, missing


def load_selection(args):
    chosen, missing = select(args)
    sites = []
    for kind, what in chosen:
        if kind == "tree":
            site_dir, path = what
            data = load_sweep_dir(path)
            if data.site != site_dir:
                raise InputError(f"{path}/sweep.json is for site {data.site!r}, not {site_dir!r}")
        elif kind == "sweep":
            data = load_sweep_dir(what)
        else:
            data = import_paths(what[0], what[1:])
        sites.append(finalize(data, args.role_re))
    seen = collections.Counter(s.site for s in sites)
    dup = [s for s, n in seen.items() if n > 1]
    if dup:
        raise InputError(f"site(s) {', '.join(sorted(dup))} selected more than once; comparing two sweeps "
                         f"of a site is --compare (design §6.3 A6, not available yet)")
    if not sites:
        raise InputError("nothing to report: " + (f"no sweep at or before the requested date for "
                                                    f"{', '.join(missing)}" if missing else "the selection is empty"))
    return sorted(sites, key=lambda s: s.site), missing


def load_baseline_sites(args, sites):
    """--baseline all: the selection plus the latest sweep (at --at) of every other site in the tree."""
    if args.baseline != "all":
        return None
    extra, chosen = [], {s.site for s in sites}
    args.baseline_excluded = []
    for site, stamps in list_tree(args.sweep_root).items():
        if site in chosen:
            continue
        if args.at:
            stamps = [st for st in stamps if sweep_stamp_dt(st) <= args.at]
        if not stamps:
            continue
        path = os.path.join(args.sweep_root, site, stamps[-1])
        # A site the user did not select must not sink the report: leave it out of the baseline, say why
        try:
            data = load_sweep_dir(path)
        except InputError as exc:
            args.baseline_excluded.append({"site": site, "reason": str(exc)})
            continue
        if data.site != site:
            args.baseline_excluded.append({"site": site, "reason": f"{path}/sweep.json is for site {data.site!r}"})
            continue
        extra.append(finalize(data, args.role_re))
    return sites + extra


# --------------------------------------------------------------------------------- suppression (A7)

def load_suppress(path):
    """Rules of a --suppress file; any deviation from the schema is an input error naming the rule."""
    doc = read_json(path, SUPPRESS_MAX)
    if not isinstance(doc, dict):
        raise InputError(f"{path}: not a suppress object")
    unknown = sorted(set(doc) - set(SUPPRESS_TOP_KEYS))
    if unknown:
        raise InputError(f"{path}: unknown key(s) {', '.join(unknown)}")
    if type(doc.get("schema_version")) is not int or doc["schema_version"] != SUPPRESS_SCHEMA_VERSION:
        raise InputError(f"{path}: unsupported schema_version {doc.get('schema_version')!r} "
                         f"(expected {SUPPRESS_SCHEMA_VERSION})")
    if not isinstance(doc.get("suppress"), list):
        raise InputError(f"{path}: 'suppress' must be a list of rules")
    rules = []
    for n, raw in enumerate(doc["suppress"], 1):
        where = f"{path}: suppress rule {n}"
        if not isinstance(raw, dict):
            raise InputError(f"{where}: not an object")
        unknown = sorted(set(raw) - set(SUPPRESS_REQUIRED) - set(SUPPRESS_OPTIONAL))
        if unknown:
            raise InputError(f"{where}: unknown key(s) {', '.join(unknown)}")
        rule = {"rule": n}
        for key in SUPPRESS_REQUIRED + ("match", "hosts"):
            if key not in raw:
                if key in SUPPRESS_REQUIRED:
                    raise InputError(f"{where}: missing '{key}'")
                rule[key] = None
                continue
            if not (isinstance(raw[key], str) and raw[key].strip()):
                raise InputError(f"{where}: '{key}' must be a non-empty string")
            rule[key] = raw[key]
        for key in ("match", "hosts"):
            try:
                rule[key + "_re"] = re.compile(rule[key]) if rule[key] is not None else None
            except re.error as exc:
                raise InputError(f"{where}: invalid '{key}' regex: {exc}") from exc
        sites = raw.get("sites")
        if sites is not None and not (isinstance(sites, list) and sites
                                      and all(isinstance(x, str) and NAME_RE.match(x) for x in sites)):
            raise InputError(f"{where}: 'sites' must be a non-empty list of site names")
        rule["sites"] = sites
        rules.append(rule)
    return rules


def _suppress_rule(rules, host, r):
    """First rule matching a record: same check, regex found in its target or (bounded) evidence, host and site."""
    for rule in rules:
        if rule["check_id"] != r["check_id"]:
            continue
        if rule["match_re"] and not (rule["match_re"].search(r["target"][:EVIDENCE_MATCH_MAX])
                                     or rule["match_re"].search(r["evidence"][:EVIDENCE_MATCH_MAX])):
            continue
        if rule["hosts_re"] and not rule["hosts_re"].search(host.name):
            continue
        if rule["sites"] and host.site not in rule["sites"]:
            continue
        return rule
    return None


def apply_suppress(sites, rules):
    """Mark WARN/CRIT/UNKNOWN records matched by a rule; a host with any marked record gets its verdict
    recomputed as the worst remaining severity (the original, when it changed, is kept in verdict_before)."""
    for site in sites:
        for host in site.hosts.values():
            hit = False
            for r in host.records:
                rule = _suppress_rule(rules, host, r) if r["severity"] in FINDING_SEVERITIES else None
                if rule:
                    r["suppressed"] = rule["rule"]
                    hit = True
            if hit and host.collected:
                verdict = worst_verdict(_active(host.records))
                if verdict != host.verdict:
                    host.verdict_before, host.verdict = host.verdict, verdict


def _active(records):
    return [r for r in records if not r.get("suppressed")]


def suppressed_summary(sites, rules, path):
    """A7 section: every rule with its reason and count, and every suppressed result."""
    if rules is None:
        return None
    hits = [r for s in sites for h in sorted(s.hosts.values(), key=lambda h: h.name) for r in h.records
            if r.get("suppressed")]
    count = collections.Counter(r["suppressed"] for r in hits)
    hosts = {(h.site, h.name): h for s in sites for h in s.hosts.values()}
    adjusted = [{"site": h.site, "host": h.name, "verdict": h.verdict, "verdict_before": h.verdict_before}
                for s in sites for h in sorted(s.hosts.values(), key=lambda h: h.name) if h.verdict_before]
    return {"file": path,
            "rules": [{k: rule[k] for k in ("rule", "check_id", "match", "hosts", "sites", "reason")}
                      | {"count": count.get(rule["rule"], 0)} for rule in rules],
            "results": [{"site": r["site"], "host": r["host"], "target": r["target"], "check_id": r["check_id"],
                         "severity": r["severity"], "rule": r["suppressed"],
                         "host_verdict": hosts[(r["site"], r["host"])].verdict,
                         "host_verdict_before": hosts[(r["site"], r["host"])].verdict_before} for r in hits],
            "verdicts_adjusted": adjusted}


# --------------------------------------------------------------------------------- analyses

def _group_key(multi, host):
    return host.site if multi else (host.role or NO_ROLE)


def coverage(sites, missing, multi):
    """A1: per site (multi-site) or per role (single site)."""
    groups = collections.OrderedDict()
    for site in sites:
        for host in sorted(site.hosts.values(), key=lambda h: h.name):
            groups.setdefault(_group_key(multi, host), []).append(host)
    cols = []
    for key, hosts in groups.items():
        recs = [r for h in hosts for r in h.records]
        # Ports from generic.link.state; hosts on nic-health < 2.12 have none, so their ports come from
        # generic.link.flaps (every version, once per port) and link counts are unknown for the group
        with_state = {r["host"] for r in recs if r["check_id"] == LINK_STATE}
        ports = {(r["host"], r["target"]) for r in recs if r["check_id"] == LINK_STATE
                 or (r["check_id"] == LINK_FLAPS and r["scope"] == "port" and r["host"] not in with_state)}
        no_state = sorted({h.name for h in hosts if h.records and h.name not in with_state})
        linked = None if no_state else len({(r["host"], r["target"]) for r in recs
                                            if r["check_id"] == LINK_STATE and r["value"] == LINK_UP})
        # generic.pcie.link runs exactly once per ASIC (other ASIC-scope targets carry sensor labels or functions)
        asics = {(r["host"], r["target"]) for r in recs if r["check_id"] == PCIE_LINK}
        fec = collections.Counter(r["metrics"]["fec"] for r in recs if r["check_id"] == DEEP_FEC and "fec" in r["metrics"])
        cols.append({
            "group": key,
            "hosts": len(hosts),
            "collected": sum(h.collected for h in hosts),
            "roles": dict(sorted(collections.Counter(h.role for h in hosts if h.role).items())),
            "asics": len(asics),
            "ports": len(ports),
            "ports_with_link": linked,
            "hosts_without_link_state": no_state,
            "deep_checks_evaluated": sum(1 for r in recs if r["check_id"].startswith(DEEP_PREFIX) and r["severity"] != "N/A"),
            "fec": dict(fec.most_common()),
            "tool_versions": sorted({h.meta.get("tool_version") for h in hosts if h.meta.get("tool_version")}),
            "levels": sorted({h.meta.get("level") for h in hosts if h.meta.get("level")}),
            "intervals_s": sorted({h.meta.get("interval_s") for h in hosts if h.meta.get("interval_s") is not None}),
            "dates": sorted({(h.meta.get("collected_at") or "")[:10] for h in hosts if h.meta.get("collected_at")}),
        })
    not_collected = [{"site": h.site, "host": h.name, "status": h.status, "exit_code": h.exit_code,
                      "problem": h.problem}
                     for s in sites for h in sorted(s.hosts.values(), key=lambda h: h.name) if not h.collected]
    caveats = []
    versions = sorted({v for c in cols for v in c["tool_versions"]})
    if len(versions) > 1:
        caveats.append(f"Mixed nic-health versions: {', '.join(versions)}.")
    intervals = sorted({v for c in cols for v in c["intervals_s"]})
    if len(intervals) > 1:
        caveats.append(f"Mixed sampling windows: {', '.join(str(i) + ' s' for i in intervals)}.")
    dates = sorted({d for c in cols for d in c["dates"]})
    if len(dates) > 1:
        caveats.append(f"Collected on different days: {', '.join(dates)}.")
    for s in sites:
        if s.source == "import":
            caveats.append(f"{s.site}: imported from CSV without collection metadata (version, window, time unknown)"
                           + (f"; {s.repaired_fields} wrapped fields repaired" if s.repaired_fields else "")
                           + (f"; {s.other_site_rows} rows of other sites skipped" if s.other_site_rows else "") + ".")
    if any(h.meta.get("uptime_s") is None for s in sites for h in s.hosts.values() if h.collected and s.source == "sweep"):
        caveats.append(f"Some hosts ran nic-health older than {HOST_CLOCK_MIN_VERSION}: no uptime or boot ID recorded.")
    no_state = [n for c in cols for n in c["hosts_without_link_state"]]
    if no_state:
        caveats.append(f"{len(no_state)} host(s) have no link state (nic-health older than {LINK_STATE_MIN_VERSION}): "
                       "ports counted from link-flap records, ports with link unknown.")
    unreadable = [h for h in not_collected if h["status"] == ST_UNREADABLE]
    if unreadable:
        caveats.append(f"{len(unreadable)} collected host(s) have a missing or malformed result file: "
                       + "; ".join(f"{h['site']}/{h['host']}" for h in unreadable) + ".")
    for site in missing:
        caveats.append(f"{site}: no sweep at or before the requested date; not in this report.")
    return {"by": "site" if multi else "role", "groups": cols, "not_collected": not_collected,
            "missing_sites": missing, "caveats": caveats}


def verdicts(sites):
    """A2: per site, then per role; hosts by verdict, clean share, finding counts."""
    out = []
    for site in sites:
        hosts = sorted(site.hosts.values(), key=lambda h: h.name)
        by_role = collections.OrderedDict()
        for h in hosts:
            by_role.setdefault(h.role or NO_ROLE, []).append(h)

        def summary(hs):
            col = [h for h in hs if h.collected]
            v = collections.Counter(h.verdict for h in col)
            sev = collections.Counter(r["severity"] for h in col for r in _active(h.records))
            return {"hosts": len(hs), "collected": len(col),
                    "by_verdict": {k: v.get(k, 0) for k in VERDICTS},
                    "clean": v.get("OK", 0), "clean_pct": round(100.0 * v.get("OK", 0) / len(col), 1) if col else None,
                    "findings": {k: sev.get(k, 0) for k in FINDING_SEVERITIES}}
        entry = {"site": site.site, **summary(hosts),
                 "roles": [{"role": role, **summary(hs)} for role, hs in by_role.items()]}
        entry["hosts_detail"] = [{"host": h.name, "role": h.role, "status": h.status, "verdict": h.verdict,
                                  **({"verdict_before": h.verdict_before} if h.verdict_before else {})}
                                 for h in hosts]
        out.append(entry)
    return out


def findings(sites):
    """A3: every WARN/CRIT/UNKNOWN record not suppressed, worst first, grouped by site -> host -> target."""
    rank = {s: i for i, s in enumerate(SEVERITIES)}
    out = []
    for site in sites:
        for host in sorted(site.hosts.values(), key=lambda h: h.name):
            for r in _active(host.records):
                if r["severity"] in FINDING_SEVERITIES:
                    out.append(r)
    out.sort(key=lambda r: (r["site"], r["host"], rank.get(r["severity"], 9), r["target"], r["check_id"]))
    return out


def port_facts(sites):
    """One dict per (site, host, port) with what A4/A5 need, from the records' metrics."""
    ports = collections.OrderedDict()
    for site in sites:
        for host in site.hosts.values():
            for r in host.records:
                if r["scope"] != "port":
                    continue
                key = (site.site, host.name, r["target"])
                p = ports.setdefault(key, {"site": site.site, "host": host.name, "role": host.role, "port": r["target"],
                                           "link": None, "uptime_s": host.meta.get("uptime_s")})
                m, cid = r["metrics"], r["check_id"]
                if cid == LINK_STATE:
                    p["link"] = r["value"] == LINK_UP
                elif cid == "mlx5.deep.module":
                    for k in ("rx", "tx", "temp", "part"):
                        if k in m:
                            p[k] = m[k]
                elif cid == DEEP_FEC:
                    for k in ("fec", "compliance"):
                        if k in m:
                            p[k] = m[k]
                elif cid == "mlx5.phy.errors" and "symbol_errors" in m:
                    p["symbol_errors"] = m["symbol_errors"]
                elif cid == "mlx5.nic.discards" and "discards" in m:
                    p["discards"] = m["discards"]
                elif cid == LINK_FLAPS and "carrier_changes" in m:
                    p["carrier_changes"] = m["carrier_changes"]
    # Module type: compliance (deep FEC, only with link) else the part number's compliance elsewhere
    by_part = collections.defaultdict(collections.Counter)
    for p in ports.values():
        if p.get("compliance") and p.get("part"):
            by_part[p["part"]][p["compliance"]] += 1
    for p in ports.values():
        if not p.get("compliance") and p.get("part") in by_part:
            p["compliance"] = by_part[p["part"]].most_common(1)[0][0]
        rx = p.get("rx")
        # With link: from link state. nic-health < 2.12 has none (nor the "not judged" marker): link is then
        # inferred from a deep FEC mode, which the tools report only for a link, plus light on the receiver
        p["link_inferred"] = p["link"] is None
        p["linked"] = p["link"] if p["link"] is not None else bool(
            p.get("fec") and rx and rx["judged"] and rx["dbm"] > NO_LIGHT_DBM)
    return list(ports.values())


def module_type(p):
    """Baseline group: compliance (else part number), split by lane count; None when neither is known."""
    base = p.get("compliance") or p.get("part")
    if not base:
        return None
    lanes = (p.get("rx") or {}).get("lanes")
    return f"{base} · {len(lanes)}-lane" if lanes else base


def _usable_rx(p):
    rx = p.get("rx")
    return p["linked"] and rx is not None and rx["judged"] and rx["dbm"] > NO_LIGHT_DBM


def _stats(values):
    """min, p5 (nearest rank), median, max and MAD of the values."""
    vals = sorted(values)
    med = statistics.median(vals)
    mad = statistics.median([abs(v - med) for v in vals])
    p5 = vals[math.floor(0.05 * (len(vals) - 1) + 0.5)]
    return {"ports": len(vals), "min": vals[0], "p5": p5, "median": med, "max": vals[-1], "mad": mad}


def baselines_and_outliers(report_ports, baseline_ports, args):
    """A4 over ports with link. Medians come from baseline_ports (the selection, or every site of the
    tree with --baseline all); outliers and lists cover report_ports only."""
    groups = collections.defaultdict(list)
    for p in baseline_ports:
        if _usable_rx(p) and module_type(p):
            groups[module_type(p)].append(p["rx"]["dbm"])
    rx_stats = {t: _stats(v) for t, v in groups.items() if len(v) >= MIN_GROUP_PORTS}
    tx_groups = collections.defaultdict(list)
    for p in baseline_ports:
        tx = p.get("tx")
        if p["linked"] and tx and tx["dbm"] > NO_LIGHT_DBM and module_type(p):
            tx_groups[module_type(p)].append(tx["dbm"])
    tx_stats = {t: _stats(v) for t, v in tx_groups.items() if len(v) >= MIN_GROUP_PORTS}

    outliers, near_limit, not_evaluated = [], [], 0
    for p in report_ports:
        if not _usable_rx(p):
            continue
        rx, t = p["rx"], module_type(p)
        st = rx_stats.get(t)
        if not st:
            not_evaluated += 1
        else:
            delta = rx["dbm"] - st["median"]
            z = (delta / (MAD_SCALE * st["mad"])) if st["mad"] else None
            if delta <= -args.rx_delta_db and (z is None or z <= -ROBUST_Z_MIN):
                outliers.append({**_who(p), "module_type": t, "rx_dbm": rx["dbm"], "lanes": rx["lanes"],
                                 "median_dbm": st["median"], "delta_db": round(delta, 2),
                                 "robust_z": round(z, 1) if z is not None else None})
        if rx["low"] is not None and rx["dbm"] - rx["low"] <= NEAR_LIMIT_DB:
            near_limit.append({**_who(p), "rx_dbm": rx["dbm"], "low_limit_dbm": rx["low"]})
    outliers.sort(key=lambda o: o["delta_db"])

    errors = []
    for p in report_ports:
        se = p.get("symbol_errors")
        if se and se["total"]:
            hours = p["uptime_s"] / SECONDS_PER_HOUR if (p.get("uptime_s") or 0) > 0 else None
            errors.append({**_who(p), "total": se["total"], "window": se["delta"],
                           "per_hour": float(f"{se['total'] / hours:.3g}") if hours else None})
    errors.sort(key=lambda e: -e["total"])
    flaps = sorted(({**_who(p), "carrier_changes": p["carrier_changes"]} for p in report_ports
                    if (p.get("carrier_changes") or 0) >= args.flap_min), key=lambda f: -f["carrier_changes"])
    discards = sorted(({**_who(p), "total": p["discards"]["total"], "window": p["discards"]["delta"]}
                       for p in report_ports if (p.get("discards") or {}).get("total")), key=lambda d: -d["total"])
    temps = [p for p in report_ports if p.get("temp")]
    hottest = sorted(({**_who(p), "temp_c": p["temp"]["c"], "high_c": p["temp"]["high"]} for p in temps),
                     key=lambda t: -t["temp_c"])
    near_hot = [t for t in hottest if t["high_c"] is not None and t["temp_c"] >= t["high_c"] - TEMP_MARGIN_C]
    inferred = sum(1 for p in report_ports if p["link_inferred"] and p["linked"])
    # Sites whose readings are whole dBm (some vendor tools round): differences under 2 dB mean little there
    by_site = collections.defaultdict(list)
    for p in report_ports:
        if _usable_rx(p):
            by_site[p["site"]].append(p["rx"]["dbm"])
    whole_dbm = sorted(site for site, v in by_site.items() if v and all(float(x).is_integer() for x in v))
    return {"rx_by_module_type": dict(sorted(rx_stats.items(), key=lambda kv: -kv[1]["ports"])),
            "whole_dbm_sites": whole_dbm,
            "tx_by_module_type": dict(sorted(tx_stats.items(), key=lambda kv: -kv[1]["ports"])),
            "rx_outliers": outliers, "rx_near_low_limit": near_limit, "rx_not_evaluated": not_evaluated,
            "ports_link_inferred": inferred,
            "errors_since_boot": errors[:TOP_N], "errors_ports": len(errors),
            "flaps": flaps, "discards": discards[:TOP_N], "discard_ports": len(discards),
            "hottest_modules": hottest[:TOP_HOT], "modules_near_high_limit": near_hot}


def _who(p):
    return {"site": p["site"], "host": p["host"], "role": p["role"], "port": p["port"]}


def pcie_summary(sites):
    """PCIe links trained below what card and slot support (WARN), and slot-limited ones (OK by design)."""
    below, limited = [], collections.Counter()
    for s in sites:
        for h in s.hosts.values():
            for r in _active(h.records):
                if r["check_id"] != PCIE_LINK:
                    continue
                if r["severity"] == "WARN":
                    below.append({"site": s.site, "host": h.name, "role": h.role, "asic": r["target"],
                                  "value": r["value"], "threshold": r["threshold"]})
                elif "slot-limited" in r["evidence"]:
                    limited[s.site] += 1
    return {"below_capability": below, "slot_limited": dict(limited)}


def patterns(sites, a4, pcie, multi):
    """A5: the same issue on the same port/ASIC in >= 2 hosts of a role (within a site), and the same
    issue on the same role at >= 2 sites (across sites; ports may differ)."""
    events = []   # (site, role, issue, target, host); related checks share one issue family
    for r in findings(sites):
        if r["severity"] in ("CRIT", "WARN"):
            events.append((r["site"], r["role"], ISSUE_FAMILY.get(r["check_id"], r["check_id"]), r["target"], r["host"]))
    # A4 lists are measurements and stay, but a pattern built from a suppressed check is dropped
    suppressed = {(r["site"], r["host"], r["check_id"], r["target"]) for s in sites for h in s.hosts.values()
                  for r in h.records if r.get("suppressed")}
    for o in a4["rx_outliers"]:
        if (o["site"], o["host"], "mlx5.deep.module", o["port"]) not in suppressed:
            events.append((o["site"], o["role"], OUTLIER_KIND, o["port"], o["host"]))
    for f in a4["flaps"]:
        if (f["site"], f["host"], LINK_FLAPS, f["port"]) not in suppressed:
            events.append((f["site"], f["role"], ISSUE_FAMILY[FLAP_KIND], f["port"], f["host"]))
    events = sorted(set(events))
    has_roles = any(h.role for s in sites for h in s.hosts.values())
    # Without roles, a site's hosts form one group (within-site patterns still work); across sites needs roles
    role_hosts = collections.Counter((h.site, h.role or NO_ROLE) for s in sites for h in s.hosts.values() if h.collected)
    within = collections.defaultdict(set)
    for site, role, kind, target, host in events:
        within[(site, role or NO_ROLE, kind, target)].add(host)
    within_rows = [{"site": k[0], "role": k[1], "issue": k[2], "target": k[3], "hosts": sorted(v),
                    "role_hosts": role_hosts[(k[0], k[1])]}
                   for k, v in sorted(within.items()) if len(v) >= 2]
    across_rows = []
    if multi and has_roles:
        across = collections.defaultdict(list)
        for site, role, kind, target, host in events:
            if role:
                across[(role, kind)].append({"site": site, "host": host, "target": target})
        for (role, kind), items in sorted(across.items()):
            sites_hit = sorted({i["site"] for i in items})
            if len(sites_hit) >= 2:
                across_rows.append({"role": role, "issue": kind, "sites": sites_hit, "items": items})
    return {"within_sites": within_rows, "across_sites": across_rows, "roles_known": has_roles}


def analyse(sites, missing, args=None, baseline_sites=None):
    multi = len(sites) + len(missing) > 1
    args = args or argparse.Namespace(rx_delta_db=DEFAULT_RX_DELTA_DB, flap_min=DEFAULT_FLAP_MIN, baseline="scope")
    # One pass over the baseline population, so a port gets the same module type in the baseline and
    # in the report (part-number borrowing depends on the population); the report keeps its own sites
    baseline_ports = port_facts(baseline_sites or sites)
    selected = {s.site for s in sites}
    report_ports = [p for p in baseline_ports if p["site"] in selected]
    a4 = baselines_and_outliers(report_ports, baseline_ports, args)
    pcie = pcie_summary(sites)
    population = sorted({s.site for s in (baseline_sites or sites)})
    a4["baseline"] = {"scope": args.baseline, "sites": population, "report_sites": sorted(selected),
                      "ports_with_rx": sum(1 for p in baseline_ports if _usable_rx(p)),
                      "excluded": getattr(args, "baseline_excluded", [])}
    a4["pcie"] = pcie
    cov = coverage(sites, missing, multi)
    supp = suppressed_summary(sites, getattr(args, "suppress_rules", None), getattr(args, "suppress", None))
    if supp:
        used = sum(1 for x in supp["rules"] if x["count"])
        adjusted = ", ".join(f"{x['site']}/{x['host']} ({x['verdict_before']} → {x['verdict']})"
                             for x in supp["verdicts_adjusted"])
        cov["caveats"].append(f"Known issues suppressed with {supp['file']}: {len(supp['results'])} result(s) by "
                              f"{used} of {len(supp['rules'])} rule(s), listed in their own section"
                              + (f"; verdicts recomputed from the remaining results: {adjusted}" if adjusted else "") + ".")
    return {"multi_site": multi, "coverage": cov,
            "verdicts": verdicts(sites), "findings": findings(sites), "baselines": a4,
            "patterns": patterns(sites, a4, pcie, multi), "suppressed": supp}


# --------------------------------------------------------------------------------- themes (§6.8)

def _luminance(color):
    """WCAG relative luminance of #RRGGBB."""
    def channel(c):
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (int(color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)


def contrast_ratio(fg, bg):
    hi, lo = sorted((_luminance(fg), _luminance(bg)), reverse=True)
    return (hi + 0.05) / (lo + 0.05)


def _theme_file(real_dir, name, what, limit):
    """Bytes of a file named in (or fixed by) the theme, which must stay inside the theme folder."""
    if not (isinstance(name, str) and NAME_RE.match(name)):
        raise InputError(f"theme {what}: {name!r} is not a plain file name in the theme folder")
    real = os.path.realpath(os.path.join(real_dir, name))
    if os.path.commonpath([real, real_dir]) != real_dir:
        raise InputError(f"theme {what}: {name} points outside the theme folder")
    if not os.path.isfile(real):
        raise InputError(f"theme {what}: {name}: no such file in {real_dir}")
    try:
        with open(real, "rb") as fh:
            data = fh.read(limit + 1)
    except OSError as exc:
        raise InputError(f"theme {what}: {exc}") from exc
    if len(data) > limit:
        raise InputError(f"theme {what}: {name} is larger than {limit // 1024} KiB")
    return data


def _logo_uri(data, what):
    """data: URI of a PNG, JPEG or SVG logo, recognised by its first bytes (never by its name)."""
    mime = next((m for magic, m in LOGO_MAGIC if data.startswith(magic)), None)
    head = data[:SVG_SNIFF_BYTES].lstrip(b"\xef\xbb\xbf").lstrip()
    if mime is None and (head.startswith(b"<svg") or head.startswith(b"<?xml")) and b"<svg" in head:
        mime = "image/svg+xml"
    if mime is None:
        raise InputError(f"theme {what}: not a PNG, JPEG or SVG image")
    return f"data:{mime};base64,{base64.b64encode(data).decode('ascii')}"


def _theme_section(doc, key, allowed, where):
    sec = doc.get(key, {})
    if not isinstance(sec, dict):
        raise InputError(f"{where}: '{key}' must be an object")
    unknown = sorted(set(sec) - set(allowed))
    if unknown:
        raise InputError(f"{where}: unknown key(s) in '{key}': {', '.join(unknown)}")
    return sec


def load_theme(path):
    """Validated theme: colours, fonts, logos as data: URIs, labels; contrast warnings and other notices."""
    if not os.path.isdir(path):
        raise InputError(f"theme {path}: not a directory")
    real_dir = os.path.realpath(path)
    where = os.path.join(path, THEME_FILE)
    try:
        doc = json.loads(_theme_file(real_dir, THEME_FILE, "file", THEME_JSON_MAX).decode("utf-8"))
    except (UnicodeDecodeError, ValueError, RecursionError) as exc:
        raise InputError(f"{where}: {exc}") from exc
    if not isinstance(doc, dict):
        raise InputError(f"{where}: not a theme object")
    unknown = sorted(set(doc) - set(THEME_REQUIRED) - set(THEME_OPTIONAL))
    missing = [k for k in THEME_REQUIRED if k not in doc]
    if unknown or missing:
        raise InputError(f"{where}: " + "; ".join(([f"unknown key(s) {', '.join(unknown)}"] if unknown else [])
                                                  + ([f"missing {', '.join(missing)}"] if missing else [])))
    if type(doc["schema_version"]) is not int or doc["schema_version"] != THEME_SCHEMA_VERSION:
        raise InputError(f"{where}: unsupported schema_version {doc['schema_version']!r} (expected {THEME_SCHEMA_VERSION})")
    if not (isinstance(doc["name"], str) and NAME_RE.match(doc["name"]) and len(doc["name"]) <= MAX_LABEL):
        raise InputError(f"{where}: 'name' must be letters, digits, '.', '_' or '-', not {doc['name']!r}")
    if not (isinstance(doc["org"], str) and CONTROL_RE.sub("", doc["org"]).strip() and len(doc["org"]) <= MAX_LABEL):
        raise InputError(f"{where}: 'org' must be a non-empty string of up to {MAX_LABEL} characters")
    colors = _theme_section(doc, "colors", THEME_COLORS, where)
    for key in THEME_COLORS:
        if not (isinstance(colors.get(key), str) and COLOR_RE.match(colors[key])):
            raise InputError(f"{where}: colors.{key} must be #RRGGBB, not {colors.get(key)!r}")
    fonts = _theme_section(doc, "fonts", THEME_FONT_KEYS, where)
    for key, names in fonts.items():
        if not (isinstance(names, list) and len(names) <= MAX_FONTS
                and all(isinstance(n, str) and FONT_RE.match(n) for n in names)):
            raise InputError(f"{where}: fonts.{key} must be a list of up to {MAX_FONTS} font family names "
                             "(letters, digits, space, . _ -)")
        if any(EMOJI_FONT_RE.search(n) for n in names):
            raise InputError(f"{where}: fonts.{key} names an emoji font; leave it out, fontconfig falls back to it")
    labels = _theme_section(doc, "labels", THEME_LABEL_KEYS, where)
    for key, text in labels.items():
        if not (isinstance(text, str) and CONTROL_RE.sub("", text).strip() and len(text) <= MAX_LABEL):
            raise InputError(f"{where}: labels.{key} must be a non-empty string of up to {MAX_LABEL} characters")
    logos = {key: _logo_uri(_theme_file(real_dir, name, f"logo {key}", LOGO_MAX_BYTES), f"logo {key} ({name})")
             for key, name in _theme_section(doc, "logos", THEME_LOGO_KEYS, where).items()}
    notices = []
    if os.path.lexists(os.path.join(path, THEME_CSS_FILE)):
        notices.append(f"theme {doc['name']!r}: {THEME_CSS_FILE} is not supported and is ignored")
    warnings = []
    for fg, bg, what in ((colors["primary"], WHITE, "primary on white"),
                         (colors["header_fg"], colors["header_bg"], "header_fg on header_bg"),
                         (WHITE, colors["primary_dark"], "white on primary_dark")):
        ratio = contrast_ratio(fg, bg)
        if ratio < MIN_CONTRAST:
            warnings.append(f"theme {doc['name']!r}: {what} contrast is {ratio:.2f}:1, below {MIN_CONTRAST}:1")
    return {"name": doc["name"], "org": " ".join(CONTROL_RE.sub("", doc["org"]).split()),
            "colors": {k: colors[k] for k in THEME_COLORS}, "fonts": {k: list(fonts.get(k, [])) for k in THEME_FONT_KEYS},
            "logos": logos, "labels": {k: " ".join(CONTROL_RE.sub("", v).split()) for k, v in labels.items()},
            "warnings": warnings, "notices": notices}


# --------------------------------------------------------------------------------- rendering

def attribution(now):
    stamp = now.strftime("%Y-%m-%d %H:%M:%S %z")
    stamp = stamp[:-2] + ":" + stamp[-2:]
    return f"Generated by nic-report v{SCRIPT_VERSION} — © {now.year} {AUTHOR} · {stamp}"


class _MD(str):
    """Markdown the report built itself (severity badges, code spans): md_cell keeps its markup."""


def _plain(v):
    """Untrusted text on one line, without control or bidi characters."""
    return " ".join(CONTROL_RE.sub("", str(v)).split())


def md_cell(v):
    if isinstance(v, _MD):
        return v.replace("|", "/")
    # '*' neutralised: untrusted text must not turn into bold or a severity badge
    return "—" if v is None or v == "" else _plain(v).replace("*", "∗").replace("|", "/")


def md_inline(v):
    """Untrusted text inside Markdown prose or a code span: one line, no backticks, no markup."""
    return _plain(v).replace("`", "'").replace("*", "∗")


def _badge(v):
    """A severity or verdict the report computed, shown as a badge (HTML); untrusted text never becomes one."""
    return _MD(f"**{v}**") if v in SEVERITIES else v


def _verdict_cell(verdict, before):
    return _MD(f"**{verdict}** (was {before})") if before else _badge(verdict)


def md_table(head, rows):
    out = ["| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
    out += ["| " + " | ".join(md_cell(c) for c in row) + " |" for row in rows]
    return "\n".join(out)


def title_for(sites, missing, args):
    if args.title:
        return md_inline(args.title)
    names = [s.site for s in sites] + missing
    return f"NIC Health: {names[0]}" if len(names) == 1 else f"NIC Health: cross-site comparison ({' · '.join(names)})"


def render_md(result, sites, missing, args, now):
    cov, multi = result["coverage"], result["multi_site"]
    md = [f"# 🩺 {title_for(sites, missing, args)}", ""]
    sources = []
    for s in sites:
        if s.source == "sweep":
            sources.append(f"{s.site} sweep {md_inline(s.stamp)}")
        else:
            sources.append(f"{s.site} imported CSV")
    md += [f"- **Prepared:** {now.strftime('%Y-%m-%d')} · **Sites:** {len(sites)}"
           + (f" (+{len(missing)} missing)" if missing else "")
           + f" · **Hosts:** {sum(len(s.hosts) for s in sites)}",
           f"- **Data:** {'; '.join(sources) or 'none'}"]
    if args.classification:
        md.append(f"- **Classification:** {md_inline(args.classification)}")
    md.append("")

    # 1. Coverage
    md += ["## 1. Coverage and comparability", ""]
    head = ["", *[c["group"] for c in cov["groups"]]]
    rows = [
        ["Hosts", *[c["hosts"] for c in cov["groups"]]],
        ["Collected", *[c["collected"] for c in cov["groups"]]],
    ]
    if multi:
        rows.append(["Roles", *[", ".join(f"{k}×{v}" for k, v in c["roles"].items()) for c in cov["groups"]]])
    rows += [
        ["NIC ASICs / ports", *[f"{c['asics']} / {c['ports']}" for c in cov["groups"]]],
        ["Ports with link", *[c["ports_with_link"] for c in cov["groups"]]],     # None (—) on nic-health < 2.12
        ["Deep checks evaluated", *[c["deep_checks_evaluated"] for c in cov["groups"]]],
        ["FEC in use", *[" · ".join(f"{k} {v}" for k, v in c["fec"].items()) for c in cov["groups"]]],
        ["nic-health version", *[", ".join(c["tool_versions"]) for c in cov["groups"]]],
        ["Window", *[", ".join(f"{i} s" for i in c["intervals_s"]) for c in cov["groups"]]],
        ["Collected on", *[", ".join(c["dates"]) for c in cov["groups"]]],
    ]
    md += [md_table(head, rows), ""]
    if cov["not_collected"]:
        md += ["**Hosts not collected**", "",
               md_table(["Site", "Host", "Status", "Exit", "Problem"],
                        [[h["site"], h["host"], h["status"], h["exit_code"],
                          md_inline(h["problem"]) if h["problem"] else None] for h in cov["not_collected"]]), ""]
    if cov["caveats"]:
        md += ["**Caveats**", ""] + [f"- {md_inline(c)}" for c in cov["caveats"]] + [""]

    # 2. Verdicts
    md += ["## 2. Verdicts", ""]
    if multi:
        md += [md_table(["Site", "Hosts", "Collected", "OK", "WARN", "CRIT", "UNKNOWN", "Clean (of collected)", "CRIT / WARN / UNKNOWN rows"],
                        [[v["site"], v["hosts"], v["collected"], *[v["by_verdict"][k] for k in VERDICTS],
                          f"{v['clean_pct']}%" if v["clean_pct"] is not None else None,
                          " / ".join(str(v["findings"][k]) for k in FINDING_SEVERITIES)] for v in result["verdicts"]]), ""]
    for v in result["verdicts"]:
        if multi:
            md += [f"### {v['site']} by role", ""]
        md += [md_table(["Role", "Hosts", "OK", "WARN", "CRIT", "UNKNOWN", "Clean (of collected)"],
                        [[r["role"], r["hosts"], *[r["by_verdict"][k] for k in VERDICTS],
                          f"{r['clean_pct']}%" if r["clean_pct"] is not None else None] for r in v["roles"]]), ""]
        if not multi:
            md += [md_table(["Host", "Role", "Status", "Verdict"],
                            [[h["host"], h["role"], h["status"], _verdict_cell(h["verdict"], h.get("verdict_before"))]
                             for h in v["hosts_detail"]]), ""]

    # 3. Findings
    md += ["## 3. Findings", ""]
    fnd = result["findings"]
    if not fnd:
        md += ["No WARN, CRIT or UNKNOWN result.", ""]
    else:
        current = None
        for r in fnd:
            key = (r["site"], r["host"])
            if key != current:
                current = key
                if md[-1] != "":
                    md.append("")
                md += [f"### {r['site'] + ' · ' if multi else ''}{r['host']}", ""]
            ev = md_inline(r["evidence"])
            ev = ev if len(ev) <= MAX_EVIDENCE else ev[:MAX_EVIDENCE] + "…"
            md.append(f"- **{r['severity']}** `{md_inline(r['target'])}` `{md_inline(r['check_id'])}`: "
                      f"{md_inline(r['value']) or '—'}")
            if ev:
                md.append(f"  - Evidence: {ev}")
            if r["hint"]:
                md.append(f"  - Hint: {md_inline(r['hint'])}")
        md.append("")
    md += render_md_baselines(result, multi)
    md += render_md_patterns(result, multi)
    md += render_md_suppressed(result, multi)
    md += ["---", "", attribution(now), ""]
    return "\n".join(md)


def _f(v, digits=2):
    return None if v is None else f"{v:.{digits}f}"


def _rate(v):
    """A rate for display: thousands separators from 100 up, else 3 significant digits (JSON keeps the float)."""
    if v is None:
        return None
    return f"{v:,.0f}" if v >= 100 else f"{v:.3g}"


def _where(o, multi):
    return f"{o['site']} {o['host']}" if multi else o["host"]


def render_md_baselines(result, multi):
    b = result["baselines"]
    if b["baseline"]["scope"] == "all":
        population = "every site of the sweep tree"
    elif b["baseline"]["sites"] == b["baseline"]["report_sites"]:
        population = "the sites in this report"
    else:
        population = "the sites of the combined report"           # --per-site: same medians as the combined one
    md = ["## 4. Baselines and outliers", "",
          f"Over ports with link. Baseline: {population}"
          f" ({', '.join(b['baseline']['sites'])}; {b['baseline']['ports_with_rx']} ports with an Rx reading)."
          + "".join(f" {x['site']} left out of the baseline: {md_inline(x['reason'])}." for x in b["baseline"]["excluded"]), "",
          "### 4.1 Receive power by module type", ""]
    if b["whole_dbm_sites"]:
        md[-2:-2] = [f"Power at {', '.join(b['whole_dbm_sites'])} was recorded in whole dBm: differences under 2 dB "
                     "are not significant there, and minima and p5 values lean on that rounding.", ""]
    md += [md_table(["Module type", "Ports", "Min", "p5", "Median", "Max"],
                    [[t, st["ports"], _f(st["min"]), _f(st["p5"]), _f(st["median"]), _f(st["max"])]
                     for t, st in b["rx_by_module_type"].items()]) if b["rx_by_module_type"]
           else "No module type has enough ports with an Rx reading for a baseline.", ""]
    md += ["### 4.2 Receive power outliers", "",
           "At least the configured margin below the median for the module type, with a robust score "
           f"(median/MAD) of at least {ROBUST_Z_MIN:g}.", ""]
    md += [md_table(["Host", "Port", "Role", "Module type", "Rx dBm", "Median", "Δ dB", "Robust z"],
                    [[_where(o, multi), o["port"], o["role"], o["module_type"], _f(o["rx_dbm"]), _f(o["median_dbm"]),
                      _f(o["delta_db"], 1), o["robust_z"]] for o in b["rx_outliers"]]) if b["rx_outliers"]
           else "No outlier.", ""]
    notes = []
    if b["rx_not_evaluated"]:
        notes.append(f"{b['rx_not_evaluated']} port(s) with an Rx reading were not evaluated: their module type has fewer "
                     f"than {MIN_GROUP_PORTS} ports with link, or is unknown.")
    if b["ports_link_inferred"]:
        notes.append(f"Link for {b['ports_link_inferred']} port(s) was inferred (nic-health < {LINK_STATE_MIN_VERSION}: "
                     "deep FEC mode plus light on the receiver).")
    if b["rx_near_low_limit"]:
        notes.append(f"Within {NEAR_LIMIT_DB:g} dB of the module's own low limit: "
                     + ", ".join(f"{_where(o, multi)} {o['port']} ({_f(o['rx_dbm'])} dBm, limit {_f(o['low_limit_dbm'], 1)})"
                                 for o in b["rx_near_low_limit"]) + ".")
    for n in notes:
        md += [md_inline(n), ""]
    md += ["### 4.3 Transmit power by module type", ""]
    md += [md_table(["Module type", "Ports", "Min", "Median", "Max"],
                    [[t, st["ports"], _f(st["min"]), _f(st["median"]), _f(st["max"])]
                     for t, st in b["tx_by_module_type"].items()]) if b["tx_by_module_type"] else "No Tx baseline.", ""]
    md += ["### 4.4 Link errors since boot", "", "Uncorrectable symbol errors (rx_symbol_err_phy) since boot.", ""]
    md += [md_table(["Host", "Port", "Role", "Symbol errors", "In window", "Per hour of uptime"],
                    [[_where(e, multi), e["port"], e["role"], f"{e['total']:,}", e["window"], _rate(e["per_hour"])]
                     for e in b["errors_since_boot"]]) + (f"\n\n{b['errors_ports']} ports with errors; the {TOP_N} highest shown."
                                                         if b["errors_ports"] > TOP_N else "")
           if b["errors_since_boot"] else "No port with symbol errors since boot.", ""]
    md += ["### 4.5 Link stability", ""]
    md += [md_table(["Host", "Port", "Role", "Carrier changes"],
                    [[_where(f, multi), f["port"], f["role"], f"{f['carrier_changes']:,}"] for f in b["flaps"]])
           if b["flaps"] else "No port above the carrier-change threshold.", ""]
    md += ["### 4.6 Receive discards since boot", ""]
    md += [md_table(["Host", "Port", "Role", "Discards", "In window"],
                    [[_where(d, multi), d["port"], d["role"], f"{d['total']:,}", d["window"]] for d in b["discards"]])
           if b["discards"] else "No port with receive discards since boot.", ""]
    md += ["### 4.7 Module temperature and PCIe", ""]
    hot = b["hottest_modules"]
    md += [("Hottest modules: " + md_inline(", ".join(f"{_where(t, multi)} {t['port']} {t['temp_c']:g} °C" for t in hot)) + ". ")
           if hot else ""]
    md[-1] += (f"{len(b['modules_near_high_limit'])} module(s) within {TEMP_MARGIN_C} °C of their own high limit."
               if b["modules_near_high_limit"] else f"No module within {TEMP_MARGIN_C} °C of its own high limit.")
    md.append("")
    pc = b["pcie"]
    if pc["below_capability"]:
        md += [md_table(["Host", "ASIC", "Role", "Trained", "Supported"],
                        [[_where(x, multi), x["asic"], x["role"], x["value"], x["threshold"]] for x in pc["below_capability"]]), ""]
    else:
        md += ["Every PCIe link trained at what the card and its slot support.", ""]
    if pc["slot_limited"]:
        md += ["Slot-limited cards (slot narrower or slower than the card, by design): "
               + ", ".join(f"{k} {v}" for k, v in pc["slot_limited"].items()) + ".", ""]
    return md


def _places(items):
    shown = "; ".join(f"{i['site']} {i['host']} {i['target']}" for i in items[:PATTERN_ITEMS_SHOWN])
    more = len(items) - PATTERN_ITEMS_SHOWN
    return shown + (f"; and {more} more" if more > 0 else "")


def render_md_patterns(result, multi):
    pt = result["patterns"]
    md = ["## 5. Patterns", ""]
    if not pt["roles_known"]:
        md += ["Hosts have no role (use -r/--role-regex): within-site patterns group all hosts of a site, "
               "and cross-site patterns need roles.", ""]
    if pt["within_sites"]:
        md += ["**Within a site:** the same issue on the same port or ASIC in two or more hosts of a role.", "",
               md_table(["Site", "Role", "Issue", "Port / ASIC", "Hosts"],
                        [[w["site"], w["role"], w["issue"], w["target"], f"{len(w['hosts'])} of {w['role_hosts']}: "
                          + ", ".join(w["hosts"])] for w in pt["within_sites"]]), ""]
    else:
        md += ["No issue repeats on the same port or ASIC across hosts of a role.", ""]
    if multi:
        if pt["across_sites"]:
            md += ["**Across sites:** the same issue on the same role at two or more sites, a hint of a shared cause "
                   "(cabling standard, breakout harness, part batch, BIOS profile).", "",
                   md_table(["Role", "Issue", "Sites", "Where"],
                            [[a["role"], a["issue"], ", ".join(a["sites"]), _places(a["items"])]
                             for a in pt["across_sites"]]), ""]
        elif pt["roles_known"]:
            md += ["No issue repeats on the same role at two or more sites.", ""]
    return md


def _code(v):
    """A code span the report builds around untrusted text ('*' is literal inside it)."""
    return _MD(f"`{_plain(v).replace('`', chr(39)).replace('|', CELL_PIPE)}`") if v else None


def render_md_suppressed(result, multi):
    sp = result.get("suppressed")
    if not sp:
        return []
    md = ["## 6. Suppressed known issues", "",
          f"Rules from {md_inline(sp['file'])}. Matching results are left out of the findings, verdicts, PCIe list and "
          "patterns above (baselines and outlier lists are measurements and stay; patterns built from a suppressed "
          "check are dropped), and listed here.", "",
          md_table(["Rule", "Check", "Match (target or evidence)", "Hosts", "Sites", "Reason", "Suppressed"],
                   [[f"#{x['rule']}", _code(x["check_id"]), _code(x["match"]), _code(x["hosts"]), ", ".join(x["sites"] or []),
                     md_inline(x["reason"]), x["count"]] for x in sp["rules"]]) if sp["rules"] else "The file has no rule.",
          ""]
    if sp["results"]:
        md += [md_table(["Host", "Target", "Check", "Severity", "Host verdict", "Rule"],
                        [[_where(x, multi), x["target"], x["check_id"], _badge(x["severity"]),
                          _verdict_cell(x["host_verdict"], x["host_verdict_before"]), f"#{x['rule']}"]
                         for x in sp["results"]]), ""]
    else:
        md += ["No result matched.", ""]
    return md


HTML_CSS = """
:root{--bg:#fff;--fg:#1d2330;--muted:#5b6475;--line:#dfe3ea;--panel:#f6f8fb;--accent:#2457c5;--code:#eef1f6;
--crit:#c62828;--crit-bg:#fdecec;--warn:#9a5b00;--warn-bg:#fdf3e1;--ok:#1b7f3b;--ok-bg:#e8f6ed;--na:#5b6475;--na-bg:#eef0f4}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#12151c;--fg:#e4e7ee;--muted:#9aa3b5;--line:#2a303c;
--panel:#191d26;--accent:#7ea6ff;--code:#232833;--crit:#ff8a80;--crit-bg:#3a1d1f;--warn:#f3c969;--warn-bg:#352c16;
--ok:#7ed69a;--ok-bg:#16301f;--na:#a7afc0;--na-bg:#232833}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);
font:15px/1.55 -apple-system,"Segoe UI",Roboto,"Liberation Sans","DejaVu Sans",sans-serif}
main{max-width:1100px;margin:0 auto;padding:28px 16px 56px}h1{font-size:1.7rem;margin:0 0 10px}
h2{font-size:1.3rem;margin:36px 0 10px;padding-bottom:6px;border-bottom:1px solid var(--line)}h3{font-size:1.05rem;margin:24px 0 8px}
.meta{list-style:none;padding:0;color:var(--muted);font-size:.92rem}code{font:.86em ui-monospace,Menlo,Consolas,"Liberation Mono",monospace;
background:var(--code);padding:1px 5px;border-radius:4px;overflow-wrap:anywhere}
.tbl{overflow-x:auto;margin:10px 0 16px;border:1px solid var(--line);border-radius:8px}
table{border-collapse:collapse;width:100%;font-size:.88rem}th,td{padding:6px 10px;text-align:left;vertical-align:top;border-bottom:1px solid var(--line)}
thead th{background:var(--panel);white-space:nowrap}tbody tr:last-child td{border-bottom:0}
.sev{display:inline-block;font-weight:700;font-size:.75rem;padding:1px 7px;border-radius:999px}
.sev-CRIT{color:var(--crit);background:var(--crit-bg)}.sev-WARN{color:var(--warn);background:var(--warn-bg)}
.sev-OK{color:var(--ok);background:var(--ok-bg)}.sev-UNKNOWN,.sev-NA{color:var(--na);background:var(--na-bg)}
footer{margin-top:40px;color:var(--muted);font-size:.8rem;border-top:1px solid var(--line);padding-top:10px}
.attrib{color:var(--muted);font-size:.78rem;margin:8px 0 0}.cover-logo{display:block;height:44px;margin:0 0 14px}
@media (max-width:640px){h1{font-size:1.35rem}main{padding:18px 16px 40px}}
@media print{body{font-size:10pt}.tbl{overflow:visible}tr{break-inside:avoid}h2{break-after:avoid}}
"""
# Severity badge colours (light, dark), as in HTML_CSS. Themes set brand colours only and never these; with a
# theme they are also locked with !important, as is the visibility of the attribution (design §6.8)
SEV_COLORS = {"CRIT": (("#c62828", "#fdecec"), ("#ff8a80", "#3a1d1f")), "WARN": (("#9a5b00", "#fdf3e1"), ("#f3c969", "#352c16")),
              "OK": (("#1b7f3b", "#e8f6ed"), ("#7ed69a", "#16301f")), "UNKNOWN": (("#5b6475", "#eef0f4"), ("#a7afc0", "#232833")),
              "NA": (("#5b6475", "#eef0f4"), ("#a7afc0", "#232833"))}
DARK = ':root:not([data-theme="light"])'
LOCKED_CSS = ("\n.sev{display:inline-block!important;visibility:visible!important;opacity:1!important}\n"
              + "".join(f".sev-{k}{{color:{lt[0]}!important;background:{lt[1]}!important}}" for k, (lt, _) in SEV_COLORS.items())
              + "\n@media (prefers-color-scheme:dark){"
              + "".join(f"{DARK} .sev-{k}{{color:{dk[0]}!important;background:{dk[1]}!important}}" for k, (_, dk) in SEV_COLORS.items())
              + "}\n.attrib,footer{display:block!important;visibility:visible!important;opacity:1!important}\n"
              ".attrib::before,.attrib::after,footer::before,footer::after{content:none!important}\n")
# Paged media for -O pdf (design §6.4): cover, contents with page numbers, running header with the section,
# "Page N of M" and the classification on every page, landscape named pages for wide tables
PRINT_CSS = """
@page{size:A4;margin:20mm 16mm 18mm;font-family:%(font)s;
 @top-left{content:element(runtitle)}
 @top-right{content:string(section);font-size:8pt;color:#5b6475}
 @bottom-left{content:element(runclass)}
 @bottom-right{content:"Page " counter(page) " of " counter(pages);font-size:8pt;color:#5b6475}}
@page :first{margin:0;@top-left{content:none}@top-center{content:none}@top-right{content:none}
 @bottom-left{content:none}@bottom-right{content:none}}
@page wide{size:A4 landscape;margin:16mm 14mm 16mm}
:root{--bg:#fff;--fg:#1d2330;--panel:#f3f5f8;--line:#d5dae2;--cover-from:#1f3f8f;--cover-to:#2457c5}
.run-title{position:running(runtitle);font-size:8pt;color:#5b6475}
.run-class{position:running(runclass);font-size:7.5pt;color:#5b6475}
.run-logo{position:running(runlogo)}.run-logo img{height:7mm}
body{font-family:%(font)s;font-size:9.6pt;line-height:1.45}
code{font-family:"Liberation Mono","DejaVu Sans Mono",monospace}
main{max-width:none;padding:0}
.cover{height:297mm;margin:0;padding:60mm 22mm 0;border:0;position:relative;break-after:page;color:#fff;
 background:linear-gradient(180deg,var(--cover-from) 0,var(--cover-to) 100%%)}
.cover h1{font-size:28pt;line-height:1.15;color:#fff;margin:0 0 14mm}
.cover .meta{color:#e6ecfa;font-size:11pt}.cover .meta li{margin:2.5mm 0}
.cover code{background:rgba(255,255,255,.16);color:#fff}
.cover .cover-logo{height:24mm;margin:0 0 18mm}
.cover .attrib,.cover-class{background:#0b1220;color:#f3f5f8;padding:2mm 3mm;font-size:8pt;margin:0}
.cover .attrib{position:absolute;left:22mm;right:22mm;bottom:14mm}
.cover-class{position:absolute;left:22mm;right:22mm;top:14mm;font-weight:700}
.toc{break-after:page}
.toc h2{font-size:16pt;margin:0 0 8mm;padding-bottom:3mm;border-bottom:2px solid var(--accent)}
.toc ol{list-style:none;padding:0;margin:0}.toc li{margin:3.5mm 0;font-size:11pt}
.toc a{color:var(--fg);text-decoration:none}
.toc a::after{content:leader(".") target-counter(attr(href), page);color:var(--muted)}
h2{break-before:page;string-set:section content(text);font-size:15pt;margin:0 0 5mm;border-bottom:2px solid var(--accent)}
h3{break-after:avoid;margin:7mm 0 3mm}
p,li{orphans:3;widows:3}
.tbl{overflow:visible;border:0;border-radius:0}
table{font-size:8.6pt;border:1px solid var(--line)}
thead{display:table-header-group}
tr{break-inside:avoid}
th,td{padding:4.5px 7px}
.wide{page:wide}
footer{font-size:7.5pt;break-inside:avoid}
""" % {"font": FONT_FALLBACK}
# Lines that start a block in markdown_to_html (everything else continues a paragraph)
BLOCK_START_RE = re.compile(r"^(#{1,3} |\||- |---$)")
SEV_BADGES = {"CRIT": "CRIT", "WARN": "WARN", "OK": "OK", "UNKNOWN": "UNKNOWN", "N/A": "NA"}


def _html_inline(text):
    """Markdown inline subset (code spans, bold) to HTML; everything else escaped."""
    out = []
    for i, part in enumerate(re.split(r"(`[^`]*`)", text)):
        if i % 2:
            out.append(f"<code>{html.escape(part[1:-1])}</code>")
            continue
        part = html.escape(part, quote=False)
        part = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", part)
        for word, cls in SEV_BADGES.items():
            part = part.replace(f"<strong>{word}</strong>", f'<span class="sev sev-{cls}">{word}</span>')
        out.append(part)
    return "".join(out)


def _html_cell(text, tag):
    return f"<{tag}>{_html_inline(text.strip())}</{tag}>"


def markdown_to_html(md, paged=False):
    """The report's Markdown subset (headings, meta list, tables, lists, paragraphs, rules) to HTML. Section
    headings get ids (sec-N) for the PDF contents; paged, a wide table moves to a landscape page with its lead."""
    lines, out, i, sections = md.split("\n"), [], 0, 0
    split_row = lambda row: row.strip().strip("|").split("|")  # noqa: E731
    while i < len(lines):
        ln = lines[i]
        if not ln.strip() or ln.strip() == "---":
            i += 1
            continue
        m = re.match(r"^(#{1,3}) (.*)", ln)
        if m:
            level = len(m.group(1))
            if level == 2:
                sections += 1
            ident = f' id="sec-{sections}"' if level == 2 else ""
            out.append(f"<h{level}{ident}>{_html_inline(m.group(2))}</h{level}>")
            i += 1
            if level == 1:
                items = []
                while i < len(lines) and not lines[i].strip():
                    i += 1
                while i < len(lines) and lines[i].startswith("- "):
                    items.append(f"<li>{_html_inline(lines[i][2:])}</li>")
                    i += 1
                out.append(f'<ul class="meta">{"".join(items)}</ul>')
            continue
        if ln.startswith("|"):
            rows = []
            while i < len(lines) and lines[i].startswith("|"):
                rows.append(lines[i])
                i += 1
            head = "".join(_html_cell(c, "th") for c in split_row(rows[0]))
            body = "".join("<tr>" + "".join(_html_cell(c, "td") for c in split_row(r)) + "</tr>" for r in rows[2:])
            table = f'<div class="tbl"><table><thead><tr>{head}</tr></thead><tbody>{body}</tbody></table></div>'
            if paged and (max(len(r) for r in rows) > WIDE_ROW_CHARS or len(split_row(rows[0])) >= WIDE_COLS):
                lead = []
                while out and out[-1].startswith("<p>") and len(lead) < WIDE_LEAD_MAX:
                    lead.insert(0, out.pop())
                if out and re.match(r"<h[23][ >]", out[-1]):
                    lead.insert(0, out.pop())
                table = f'<section class="wide">{"".join(lead)}{table}</section>'
            out.append(table)
            continue
        if ln.startswith("- "):
            items = []
            while i < len(lines) and (lines[i].startswith("- ") or lines[i].startswith("  - ")):
                if lines[i].startswith("- "):
                    items.append([lines[i][2:], []])
                else:
                    items[-1][1].append(lines[i][4:])
                i += 1
            out.append("<ul>" + "".join(
                f"<li>{_html_inline(t)}" + ("<ul>" + "".join(f"<li>{_html_inline(x)}</li>" for x in sub) + "</ul>" if sub else "")
                + "</li>" for t, sub in items) + "</ul>")
            continue
        # Paragraph: up to the next block this converter handles. A line that starts like a block but is
        # not one (e.g. '####', '----') still advances, so no input can stall the loop
        para = [ln.strip()]
        i += 1
        while i < len(lines) and lines[i].strip() and not BLOCK_START_RE.match(lines[i]):
            para.append(lines[i].strip())
            i += 1
        out.append(f"<p>{_html_inline(' '.join(para))}</p>")
    return "\n".join(out)


def theme_css(theme, paged):
    """Brand colours and fonts of a theme, then the locked rules. Severity badges, the attribution and the
    classification keep fixed colours (the cover's sit on fixed bands), so theme values cannot hide them."""
    if not theme:
        return ""
    c, f = theme["colors"], theme["fonts"]
    body = ",".join([f'"{n}"' for n in f["body"]] + [FONT_FALLBACK])       # built-in fallbacks always last
    head = ",".join([f'"{n}"' for n in f["heading"] + f["body"]] + [FONT_FALLBACK])
    css = (f"\n:root{{--accent:{c['primary']}}}\n@media (prefers-color-scheme:dark){{{DARK}{{--accent:{c['link_dark']}}}}}\n"
           f"body{{font-family:{body}}}h1,h2,h3{{font-family:{head}}}h1,h2{{color:{c['primary_dark']}}}"
           f"h2{{border-bottom-color:{c['accent']}}}thead th{{background:{c['header_bg']};color:{c['header_fg']}}}\n"
           f"@media (prefers-color-scheme:dark){{{DARK} h1,{DARK} h2{{color:inherit}}"
           f"{DARK} thead th{{background:var(--panel);color:inherit}}}}\n")
    if paged:
        css += (f":root{{--cover-from:{c['primary_dark']};--cover-to:{c['primary']}}}\n@page{{font-family:{body}}}\n"
                + ("@page{@top-left{content:element(runlogo)}@top-center{content:element(runtitle)}}\n"
                   if theme["logos"].get("header") else ""))
    else:
        css += ".cover{border-bottom:3px solid var(--accent);padding-bottom:12px}\n"
    return css + LOCKED_CSS


def render_html(result, sites, missing, args, now, paged=False):
    """One self-contained page: inline CSS, no scripts, fonts or remote resources (design §6.4); logos only as
    data: URIs. Paged (for -O pdf) adds the cover, contents and running header and footer elements."""
    theme = getattr(args, "theme_data", None)
    md = render_md(result, sites, missing, args, now)
    body, _, _ = md.rpartition("\n---\n")
    head_md, _, rest = body.partition("\n## ")
    title = html.escape(title_for(sites, missing, args))
    sections = markdown_to_html("## " + rest if rest else "", paged)
    org = html.escape(theme["org"]) if theme else ""
    logo = (theme or {}).get("logos", {}).get("cover" if paged else "header")
    label = html.escape(md_inline(args.classification)) if args.classification else ""
    cover = ('<header class="cover">' + (f'<p class="cover-class">{label}</p>' if paged and label else "")
             + (f'<img class="cover-logo" alt="{org}" src="{logo}">' if logo else "")
             + f'{markdown_to_html(head_md)}\n<p class="attrib">{html.escape(attribution(now))}</p></header>\n')
    css = HTML_CSS + (PRINT_CSS if paged else "") + theme_css(theme, paged)
    running = ""
    if paged:
        header_title = html.escape(md_inline((theme or {}).get("labels", {}).get("header_title") or title_for(sites, missing, args)))
        header_logo = (theme or {}).get("logos", {}).get("header")
        running = (f'<div class="run-title">{header_title}</div>' + (f'<div class="run-class">{label}</div>' if label else "")
                   + (f'<div class="run-logo"><img alt="{org}" src="{header_logo}"></div>' if header_logo else "") + "\n")
        toc = "".join(f'<li><a href="#{ident}">{text}</a></li>'
                      for ident, text in re.findall(r'<h2 id="(sec-\d+)">(.*?)</h2>', sections))
        sections = f'<nav class="toc"><h2>Contents</h2><ol>{toc}</ol></nav>\n{sections}'
    return ("<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n"
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n"
            f"<meta name=\"generator\" content=\"{SCRIPT_NAME} {SCRIPT_VERSION}\">\n"
            + (f"<meta name=\"author\" content=\"{org}\">\n" if org else "")
            + f"<title>{title}</title>\n<style>{css}</style></head>\n<body><main>\n{running}{cover}"
            f"{sections}\n<footer>" + (f"{label} · " if label else "")
            + f"{html.escape(attribution(now))}</footer>\n</main></body></html>\n")


def _weasyprint():
    """WeasyPrint, imported only for -O pdf; its absence is an input error naming the package."""
    try:
        import weasyprint  # pylint: disable=import-outside-toplevel
    except (ImportError, OSError) as exc:
        raise InputError(f"-O pdf needs WeasyPrint ({PDF_PACKAGE_HINT}): {exc}") from exc
    return weasyprint


def local_fetcher(weasyprint):
    """A WeasyPrint URL fetcher for data: URIs only, so a report never reaches the network (design §9):
    a URLFetcher limited to that scheme (WeasyPrint 70+), else a function around default_url_fetcher."""
    if hasattr(weasyprint, "URLFetcher"):
        return weasyprint.URLFetcher(allowed_protocols={"data"})

    def fetch(url):
        if not url.startswith("data:"):
            raise ValueError(f"remote resource refused: {url}")
        return weasyprint.default_url_fetcher(url)
    return fetch


def render_pdf(result, sites, missing, args, now):
    """The paged HTML through WeasyPrint; <meta name="generator"> becomes the PDF Creator."""
    weasyprint = _weasyprint()
    for name in ("weasyprint", "fontTools"):         # CSS it does not support (screen rules) is not an error
        logging.getLogger(name).setLevel(logging.ERROR)
    page = render_html(result, sites, missing, args, now, paged=True)
    try:
        return weasyprint.HTML(string=page, url_fetcher=local_fetcher(weasyprint)).write_pdf()
    except Exception as exc:  # pylint: disable=broad-except  # a WeasyPrint failure, reported as such
        raise InputError(f"PDF rendering failed: {type(exc).__name__}: {exc}") from exc


def render_json(result, sites, missing, args, now):
    doc = {
        "schema_version": REPORT_SCHEMA_VERSION,
        "generator": {"tool": SCRIPT_NAME, "version": SCRIPT_VERSION, "generated_at": now.isoformat(timespec="seconds")},
        "title": title_for(sites, missing, args),
        "classification": args.classification,
        "selection": {
            "sites": [{"site": s.site, "source": s.source, "sweep": s.stamp, "path": s.path,
                       "hosts": len(s.hosts)} for s in sites],
            "missing_sites": missing,
            "at": args.at.isoformat() if args.at else None,
            "role_regex": args.role_regex,
            "baseline": args.baseline, "rx_delta_db": args.rx_delta_db, "flap_min": args.flap_min,
            "suppress": getattr(args, "suppress", None),
        },
        **result,
    }
    return json.dumps(doc, indent=2, ensure_ascii=False, allow_nan=False) + "\n"


# --------------------------------------------------------------------------------- CLI

class Parser(argparse.ArgumentParser):
    """argparse with the repo's usage exit code (3) instead of 2."""

    def error(self, message):
        self.print_usage(sys.stderr)
        sys.stderr.write(f"❌ {message}\n")
        sys.exit(EXIT_USAGE)


def build_parser():
    p = Parser(
        prog=SCRIPT_NAME, formatter_class=argparse.RawDescriptionHelpFormatter, allow_abbrev=False,
        description=(f"Version: {SCRIPT_VERSION}\n\n"
                     "Reports on nic-sweep sweeps (and legacy nic-health CSV) for one site, several or all:\n"
                     "coverage, verdicts, every finding with its evidence, baselines and outliers over\n"
                     "ports with link, patterns within and across sites, and suppressed known issues.\n"
                     "Read-only and offline."),
        epilog=("--import takes SITE and every following path: put SWEEP_DIRs before it, or end its list with --.\n"
                f"-O pdf needs WeasyPrint ({PDF_PACKAGE_HINT}) and -o FILE.\n"
                f"Environment: {THEME_ENV}=DIR selects a theme for html and pdf when --theme is not given.\n"
                f"Report files are written atomically with mode {REPORT_MODE:04o} (less the umask).\n\n"
                "Exit status:\n 0  report written\n 1  input error (unreadable input, unknown schema or site, a site\n"
                "    selected twice, no data for the selection, an invalid suppress file or theme, theme contrast\n"
                f"    below {MIN_CONTRAST}:1 with --strict-theme, WeasyPrint missing or failing for -O pdf) or an\n"
                "    output file cannot be written\n 3  usage error\n\n"
                f"See also: nic-sweep.sh(8), nic-health.sh(8), nic-xray.sh(8). Design: {DESIGN_REF}"))
    p.add_argument("sweep_dirs", nargs="*", metavar="SWEEP_DIR", help="nic-sweep directories (DIR/<site>/<UTC time>)")
    p.add_argument("-R", "--sweep-root", metavar="DIR", help="nic-sweep tree; selects the latest sweep of each site")
    p.add_argument("-s", "--site", action="append", metavar="SITE", help="only this site of --sweep-root (repeatable)")
    p.add_argument("-a", "--at", metavar="DATE", help="latest sweep on or before DATE (YYYY-MM-DD or YYYY-MM-DDTHH:MM[:SS]Z, UTC)")
    p.add_argument("-i", "--import", dest="imports", action="append", nargs="+", metavar=("SITE", "PATH"),
                   help="legacy nic-health CSV for SITE: files or directories of *.csv (repeatable)")
    p.add_argument("-r", "--role-regex", metavar="RE", help="role from the host name: a group named 'role' (or the first group)")
    p.add_argument("-b", "--baseline", choices=BASELINES, default="scope",
                   help="medians for outliers from the selected sites (scope, default) or from every site "
                        "of --sweep-root (all)")
    p.add_argument("-d", "--rx-delta-db", type=float, default=DEFAULT_RX_DELTA_DB, metavar="DB",
                   help=f"Rx at least DB below its module type's median is an outlier (default {DEFAULT_RX_DELTA_DB:g})")
    p.add_argument("-f", "--flap-min", type=int, default=DEFAULT_FLAP_MIN, metavar="N",
                   help=f"list ports with at least N carrier changes since driver load (default {DEFAULT_FLAP_MIN})")
    p.add_argument("-S", "--suppress", metavar="FILE",
                   help="JSON rules for known tool issues: matching results leave findings, verdicts and patterns "
                        "and are listed in their own section")
    p.add_argument("-O", "--output-format", choices=("md", "json", "html", "pdf"), default="md",
                   help="md (default), json, html (one self-contained file) or pdf (WeasyPrint; needs -o)")
    p.add_argument("-o", "--output", metavar="FILE", help="write to FILE instead of standard output")
    p.add_argument("-P", "--per-site", action="store_true",
                   help="with -o FILE.ext, also write FILE-SITE.ext per selected site (same baseline)")
    p.add_argument("-T", "--theme", metavar="DIR", default=os.environ.get(THEME_ENV) or None,
                   help=f"theme folder for html and pdf (default: ${THEME_ENV}; -T '' for no theme)")
    p.add_argument("-X", "--strict-theme", action="store_true",
                   help=f"a theme colour pair with contrast below {MIN_CONTRAST}:1 is an error, not a warning")
    p.add_argument("-t", "--title", metavar="TEXT", help="report title")
    p.add_argument("-c", "--classification", metavar="TEXT",
                   help="classification label, e.g. 'confidential site data' (overrides the theme's)")
    p.add_argument("-v", "--version", action="version", version=f"{SCRIPT_NAME} {SCRIPT_VERSION}")
    return p


def parse_args(argv):
    p = build_parser()
    args = p.parse_args(argv)
    if not (args.sweep_dirs or args.sweep_root or args.imports):
        p.print_help(sys.stderr)
        sys.stderr.write("\n❌ Nothing to report: give SWEEP_DIR, --sweep-root or --import.\n")
        sys.exit(EXIT_USAGE)
    for site in args.site or []:
        if not NAME_RE.match(site):
            p.error(f"invalid --site value {site!r}")
    for imp in args.imports or []:
        if len(imp) < 2:
            p.error("--import needs SITE and at least one PATH")
    if args.at:
        try:
            args.at = parse_at(args.at)
        except ValueError:
            p.error(f"invalid --at value {args.at!r} (expected YYYY-MM-DD or YYYY-MM-DDTHH:MM[:SS]Z)")
    if args.at and not args.sweep_root:
        p.error("--at needs --sweep-root")
    if args.baseline == "all" and not args.sweep_root:
        p.error("--baseline all needs --sweep-root")
    if not math.isfinite(args.rx_delta_db) or args.rx_delta_db <= 0:
        p.error("--rx-delta-db must be a positive number")
    if args.flap_min < 1:
        p.error("--flap-min must be at least 1")
    if args.output_format == "pdf" and not args.output:
        p.error("-O pdf writes a binary file: give -o FILE")
    if args.per_site and not args.output:
        p.error("--per-site needs -o FILE (per-site files are named FILE-SITE.ext)")
    if args.strict_theme and args.output_format not in ("html", "pdf"):
        p.error("--strict-theme applies to -O html and pdf only (md and json ignore themes)")
    if args.strict_theme and not args.theme:
        p.error(f"--strict-theme needs --theme or {THEME_ENV}")
    args.role_re = None
    if args.role_regex:
        try:
            args.role_re = re.compile(args.role_regex)
        except re.error as exc:
            p.error(f"invalid --role-regex: {exc}")
        if args.role_re.groups == 0:
            p.error("--role-regex needs a group: (?P<role>...) or (...)")
    return args


def per_site_path(output, site):
    """FILE.ext -> FILE-SITE.ext. Site names are validated (NAME_RE): no path separator can get in."""
    if not NAME_RE.match(site):
        raise InputError(f"site name {site!r} cannot be part of a file name")
    root, ext = os.path.splitext(output)
    return f"{root}-{site}{ext}"


def _warn(text):
    sys.stderr.write(f"⚠️  {text}\n")


def build_outputs(args, now):
    """[(path or None for stdout, text or PDF bytes)]: the report, then one per site with --per-site."""
    args.theme_data = None
    if args.theme and args.output_format in ("html", "pdf"):    # md and json never read a theme
        args.theme_data = load_theme(args.theme)
        for warning in args.theme_data["warnings"]:
            if args.strict_theme:
                raise InputError(f"{warning} (--strict-theme)")
            _warn(warning)
        for notice in args.theme_data["notices"]:
            _warn(notice)
        if not args.classification:
            args.classification = args.theme_data["labels"].get("classification")
    if args.output_format == "pdf":
        _weasyprint()                                   # fail before reading any input
    args.suppress_rules = load_suppress(args.suppress) if args.suppress else None
    sites, missing = load_selection(args)
    if args.suppress_rules:
        apply_suppress(sites, args.suppress_rules)
        selected = {s.site for s in sites}
        hits = collections.Counter(r["suppressed"] for s in sites for h in s.hosts.values() for r in h.records
                                   if r.get("suppressed"))
        for rule in args.suppress_rules:
            if not hits[rule["rule"]]:
                _warn(f"suppress rule {rule['rule']} ({rule['check_id']}) matched nothing")
            for site in rule["sites"] or []:
                if site not in selected:
                    _warn(f"suppress rule {rule['rule']}: site {site} is not in the selection")
    baseline_sites = load_baseline_sites(args, sites)
    renderer = {"json": render_json, "html": render_html, "md": render_md, "pdf": render_pdf}[args.output_format]
    result = analyse(sites, missing, args, baseline_sites)
    outputs = [(args.output, renderer(result, sites, missing, args, now))]
    if args.per_site and len(sites) + len(missing) == 1:
        _warn("--per-site: one site selected, the report is already per site")
    for site in sites if args.per_site and len(sites) + len(missing) > 1 else []:
        # Single-site report over the combined report's baseline population, so outliers agree
        site_args = argparse.Namespace(**vars(args))
        if args.title:
            site_args.title = f"{args.title} · {site.site}"
        site_result = analyse([site], [], site_args, baseline_sites or sites)
        outputs.append((per_site_path(args.output, site.site), renderer(site_result, [site], [], site_args, now)))
    return outputs


def write_outputs(outputs):
    """Write every file atomically: a temp file next to it (exclusive, random name, never through a symlink,
    REPORT_MODE), then os.replace, which also replaces a symlink at the target instead of following it. All
    target directories are checked first so --per-site does not leave a partial set; temp files go on failure.
    An existing target that is not a regular file (/dev/null, a FIFO, /dev/stdout) is written to directly:
    replacing it would destroy it (as root, the system's /dev/null)."""
    files, special = [], []
    for path, content in outputs:
        if path is None:
            continue
        data = content if isinstance(content, bytes) else content.encode("utf-8")
        try:
            st = os.stat(path)
        except OSError:
            st = None
        if st and not stat.S_ISREG(st.st_mode) and not stat.S_ISDIR(st.st_mode):
            special.append((path, data))
        else:
            files.append((path, data))
    for path, _ in files:
        folder = os.path.dirname(os.path.abspath(path))
        if not (os.path.isdir(folder) and os.access(folder, os.W_OK | os.X_OK)):
            raise InputError(f"{path}: directory {folder} does not exist or is not writable")
        if os.path.isdir(path) and not os.path.islink(path):
            raise InputError(f"{path}: is a directory")
    temps = []
    try:
        for path, data in files:
            folder, base = os.path.split(os.path.abspath(path))
            tmp = os.path.join(folder, f".{base}.{secrets.token_hex(TEMP_NAME_BYTES)}.tmp")
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), REPORT_MODE)
            temps.append(tmp)
            with os.fdopen(fd, "wb") as fh:
                fh.write(data)
        for (path, _), tmp in zip(files, temps):
            os.replace(tmp, path)
        for path, data in special:
            with open(path, "wb") as fh:
                fh.write(data)
    except OSError as exc:
        for tmp in temps:
            with contextlib.suppress(OSError):
                os.remove(tmp)
        raise InputError(f"cannot write the report: {exc}") from exc
    for path, content in outputs:
        if path is None:
            sys.stdout.write(content)


def main(argv=None):
    if sys.version_info < MIN_PYTHON:
        sys.stderr.write(f"❌ {SCRIPT_NAME} needs Python {'.'.join(map(str, MIN_PYTHON))} or newer\n")
        return EXIT_USAGE
    args = parse_args(sys.argv[1:] if argv is None else argv)
    now = datetime.datetime.now().astimezone()
    try:
        write_outputs(build_outputs(args, now))
    except InputError as exc:
        sys.stderr.write(f"❌ {exc}\n")
        return EXIT_INPUT
    except Exception as exc:  # pylint: disable=broad-except  # backstop: odd input must not end in a traceback
        sys.stderr.write(f"❌ internal error while reading the input ({type(exc).__name__}: {exc}); "
                         "please report it with the input that caused it\n")
        return EXIT_INPUT
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
