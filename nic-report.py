#!/usr/bin/env python3
#
# Script Name: nic-report.py
# Description: Companion to nic-xray.sh, nic-health.sh and nic-sweep.sh. Reads nic-sweep sweeps
#              (and legacy nic-health CSV) for one site, several or all, and writes a report:
#              coverage and comparability, verdicts, and every finding with its evidence.
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
#
# Version: 2.13.0
"""nic-report.py: single- and multi-site reports from nic-sweep sweeps and legacy nic-health CSV."""

import argparse
import collections
import csv
import datetime
import glob
import json
import os
import re
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


class InputError(Exception):
    """Unreadable input, unknown schema or an impossible selection (exit 1)."""


# --------------------------------------------------------------------------------- extractors
# One small function per value (design §6.2). Each returns None when the value is absent or does not
# parse: never 0. Inputs are nic-health evidence/value strings.

def _float(text):
    try:
        return float(text)
    except (TypeError, ValueError):
        return None


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
    m = re.search(r"\b" + re.escape(name) + r"=(\d+)(?: \(\+(\d+)\))?", evidence or "")
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
    m = re.search(r"\bcarrier_changes=(\d+)", evidence or "")
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


def metrics_for(check_id, value, evidence):
    """Structured values for one record (design §6.1 'metrics'), by check."""
    out = {}
    if check_id == "mlx5.deep.module":
        for key, fn in (("rx", extract_rx_dbm), ("tx", extract_tx_dbm), ("temp", extract_module_temp_c)):
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


def analyse(sites, missing):
    multi = len(sites) + len(missing) > 1
    return {"multi_site": multi, "coverage": coverage(sites, missing, multi),
            "verdicts": verdicts(sites), "findings": findings(sites)}


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
        return args.title
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
        md.append(f"- **Classification:** {args.classification}")
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
    md += ["---", "", attribution(now), ""]
    return "\n".join(md)


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
        },
        **result,
    }
    return json.dumps(doc, indent=2, ensure_ascii=False) + "\n"


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
                     "coverage and comparability, verdicts, and every finding with its evidence.\n"
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
    p.add_argument("-O", "--output-format", choices=("md", "json"), default="md", help="md (default) or json")
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
        result = analyse(sites, missing)
        text = (render_json if args.output_format == "json" else render_md)(result, sites, missing, args, now)
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
