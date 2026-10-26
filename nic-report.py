#!/usr/bin/env python3
#
# Script Name: nic-report.py
# Description: Companion to nic-xray.sh, nic-health.sh and nic-sweep.sh. Reads nic-sweep sweeps
#              (and legacy nic-health CSV) for one site, several or all, and writes a report:
#              coverage and comparability, verdicts, every finding with its evidence, fleet
#              baselines and outliers, and patterns within and across sites (Markdown, JSON, HTML).
#              Read-only, offline: never contacts a host or the network.
#              Design: docs/design/nic-sweep.md (§6)
#
# Author: Ciro Iriarte <ciro.iriarte+software@gmail.com>
# Created: 2026-10-26
#
# Requirements:
#   - Python 3.9 or newer, standard library only (the one Python script in the repo: CLAUDE.md §2)
#
# Change Log:
#   - 2026-10-26: Phase 3 of docs/design/nic-sweep.md: sweep and legacy CSV loaders, site
#                 selection (-R, -s, --at), record model, evidence extractors, coverage (A1),
#                 verdicts (A2) and findings (A3) in single- and multi-site layouts; Markdown and JSON
#   - 2026-10-26: Phase 4: baselines and outliers (A4) over ports with link, patterns within and across
#                 sites (A5), --baseline scope|all, self-contained HTML output
#
# Version: 2.13.0
"""nic-report.py: single- and multi-site reports from nic-sweep sweeps and legacy nic-health CSV."""

import argparse
import collections
import csv
import datetime
import glob
import html
import json
import math
import os
import re
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


def read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError) as exc:
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
            sev = collections.Counter(r["severity"] for h in col for r in h.records)
            return {"hosts": len(hs), "collected": len(col),
                    "by_verdict": {k: v.get(k, 0) for k in VERDICTS},
                    "clean": v.get("OK", 0), "clean_pct": round(100.0 * v.get("OK", 0) / len(col), 1) if col else None,
                    "findings": {k: sev.get(k, 0) for k in FINDING_SEVERITIES}}
        entry = {"site": site.site, **summary(hosts),
                 "roles": [{"role": role, **summary(hs)} for role, hs in by_role.items()]}
        entry["hosts_detail"] = [{"host": h.name, "role": h.role, "status": h.status, "verdict": h.verdict}
                                 for h in hosts]
        out.append(entry)
    return out


def findings(sites):
    """A3: every WARN/CRIT/UNKNOWN record, worst first, grouped by site -> host -> target."""
    rank = {s: i for i, s in enumerate(SEVERITIES)}
    out = []
    for site in sites:
        for host in sorted(site.hosts.values(), key=lambda h: h.name):
            for r in host.records:
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
            for r in h.records:
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
    for o in a4["rx_outliers"]:
        events.append((o["site"], o["role"], OUTLIER_KIND, o["port"], o["host"]))
    for f in a4["flaps"]:
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
    a4["baseline"] = {"scope": args.baseline, "sites": population,
                      "ports_with_rx": sum(1 for p in baseline_ports if _usable_rx(p)),
                      "excluded": getattr(args, "baseline_excluded", [])}
    a4["pcie"] = pcie
    return {"multi_site": multi, "coverage": coverage(sites, missing, multi),
            "verdicts": verdicts(sites), "findings": findings(sites), "baselines": a4,
            "patterns": patterns(sites, a4, pcie, multi)}


# --------------------------------------------------------------------------------- rendering

def attribution(now):
    stamp = now.strftime("%Y-%m-%d %H:%M:%S %z")
    stamp = stamp[:-2] + ":" + stamp[-2:]
    return f"Generated by nic-report v{SCRIPT_VERSION} — © {now.year} {AUTHOR} · {stamp}"


def md_cell(v):
    text = "—" if v is None or v == "" else str(v)
    return text.replace("|", "/").replace("\n", " ")


def md_inline(v):
    """Untrusted text inside Markdown prose or a code span: one line, no backticks."""
    return " ".join(str(v).split()).replace("`", "'")


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
            sources.append(f"{s.site} sweep {s.stamp}")
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
        md += ["**Caveats**", ""] + [f"- {c}" for c in cov["caveats"]] + [""]

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
                            [[h["host"], h["role"], h["status"], h["verdict"]] for h in v["hosts_detail"]]), ""]

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
    md += ["---", "", attribution(now), ""]
    return "\n".join(md)


def _f(v, digits=2):
    return None if v is None else f"{v:.{digits}f}"


def _where(o, multi):
    return f"{o['site']} {o['host']}" if multi else o["host"]


def render_md_baselines(result, multi):
    b = result["baselines"]
    md = ["## 4. Baselines and outliers", "",
          f"Over ports with link. Baseline: {'every site of the sweep tree' if b['baseline']['scope'] == 'all' else 'the sites in this report'}"
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
        md += [n, ""]
    md += ["### 4.3 Transmit power by module type", ""]
    md += [md_table(["Module type", "Ports", "Min", "Median", "Max"],
                    [[t, st["ports"], _f(st["min"]), _f(st["median"]), _f(st["max"])]
                     for t, st in b["tx_by_module_type"].items()]) if b["tx_by_module_type"] else "No Tx baseline.", ""]
    md += ["### 4.4 Link errors since boot", "", "Uncorrectable symbol errors (rx_symbol_err_phy) since boot.", ""]
    md += [md_table(["Host", "Port", "Role", "Symbol errors", "In window", "Per hour of uptime"],
                    [[_where(e, multi), e["port"], e["role"], f"{e['total']:,}", e["window"], e["per_hour"]]
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
    md += [("Hottest modules: " + ", ".join(f"{_where(t, multi)} {t['port']} {t['temp_c']:g} °C" for t in hot) + ". ")
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
@media (max-width:640px){h1{font-size:1.35rem}main{padding:18px 16px 40px}}
@media print{body{font-size:10pt}.tbl{overflow:visible}tr{break-inside:avoid}h2{break-after:avoid}}
"""
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
    t = text.strip()
    if tag == "td" and t in SEV_BADGES:
        return f'<td><span class="sev sev-{SEV_BADGES[t]}">{t}</span></td>'
    return f"<{tag}>{_html_inline(t)}</{tag}>"


def markdown_to_html(md):
    """The report's Markdown subset (headings, meta list, tables, lists, paragraphs, rules) to HTML."""
    lines, out, i = md.split("\n"), [], 0
    split_row = lambda row: row.strip().strip("|").split("|")  # noqa: E731
    while i < len(lines):
        ln = lines[i]
        if not ln.strip() or ln.strip() == "---":
            i += 1
            continue
        m = re.match(r"^(#{1,3}) (.*)", ln)
        if m:
            level = len(m.group(1))
            out.append(f"<h{level}>{_html_inline(m.group(2))}</h{level}>")
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
            out.append(f'<div class="tbl"><table><thead><tr>{head}</tr></thead><tbody>{body}</tbody></table></div>')
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


def render_html(result, sites, missing, args, now):
    """One self-contained page: inline CSS, no scripts, fonts or remote resources (design §6.4)."""
    md = render_md(result, sites, missing, args, now)
    body, _, _ = md.rpartition("\n---\n")
    title = html.escape(title_for(sites, missing, args))
    return ("<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n"
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n"
            f"<meta name=\"generator\" content=\"{SCRIPT_NAME} {SCRIPT_VERSION}\">\n"
            f"<title>{title}</title>\n<style>{HTML_CSS}</style></head>\n<body><main>\n"
            f"{markdown_to_html(body)}\n<footer>"
            + (f"{html.escape(md_inline(args.classification))} · " if args.classification else "")
            + f"{html.escape(attribution(now))}</footer>\n</main></body></html>\n")


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
                     "ports with link, and patterns within and across sites.\n"
                     "Read-only and offline."),
        epilog=("--import takes SITE and every following path: put SWEEP_DIRs before it, or end its list with --.\n\n"
                "Exit status:\n 0  report written\n 1  input error (unreadable input, unknown schema or site, a site\n"
                "    selected twice, no data for the selection) or the output file cannot be written\n 3  usage error\n\n"
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
    p.add_argument("-O", "--output-format", choices=("md", "json", "html"), default="md",
                   help="md (default), json, or html (one self-contained file)")
    p.add_argument("-o", "--output", metavar="FILE", help="write to FILE instead of standard output")
    p.add_argument("-t", "--title", metavar="TEXT", help="report title")
    p.add_argument("-c", "--classification", metavar="TEXT", help="classification label, e.g. 'confidential site data'")
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
    args.role_re = None
    if args.role_regex:
        try:
            args.role_re = re.compile(args.role_regex)
        except re.error as exc:
            p.error(f"invalid --role-regex: {exc}")
        if args.role_re.groups == 0:
            p.error("--role-regex needs a group: (?P<role>...) or (...)")
    return args


def main(argv=None):
    if sys.version_info < MIN_PYTHON:
        sys.stderr.write(f"❌ {SCRIPT_NAME} needs Python {'.'.join(map(str, MIN_PYTHON))} or newer\n")
        return EXIT_USAGE
    args = parse_args(sys.argv[1:] if argv is None else argv)
    now = datetime.datetime.now().astimezone()
    try:
        sites, missing = load_selection(args)
        result = analyse(sites, missing, args, load_baseline_sites(args, sites))
        renderer = {"json": render_json, "html": render_html, "md": render_md}[args.output_format]
        text = renderer(result, sites, missing, args, now)
    except InputError as exc:
        sys.stderr.write(f"❌ {exc}\n")
        return EXIT_INPUT
    except Exception as exc:  # pylint: disable=broad-except  # backstop: odd input must not end in a traceback
        sys.stderr.write(f"❌ internal error while reading the input ({type(exc).__name__}: {exc}); "
                         "please report it with the input that caused it\n")
        return EXIT_INPUT
    if args.output:
        try:
            with open(args.output, "w", encoding="utf-8") as fh:
                fh.write(text)
        except OSError as exc:
            sys.stderr.write(f"❌ {args.output}: {exc}\n")
            return EXIT_INPUT
    else:
        sys.stdout.write(text)
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
