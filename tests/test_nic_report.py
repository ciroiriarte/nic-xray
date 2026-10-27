#!/usr/bin/env python3
"""Unit tests for nic-report.py (design docs/design/nic-sweep.md §6, Phase 3).

Fixtures are generated in a temporary directory: fictional site/host names, evidence strings in the
exact formats nic-health writes. Run: python3 -m unittest discover -s tests -p 'test_nic_report.py'
"""
import collections
import contextlib
import importlib.util
import io
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(REPO, "nic-report.py")
_spec = importlib.util.spec_from_file_location("nic_report", SCRIPT)
nr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(nr)

ROLE_RE = r"^[^-]+-[^-]+-(?P<role>[a-z]+\d+[a-z]*)-\d+"
THEMES = os.path.join(REPO, "tests", "fixtures", "themes")
EXAMPLE_THEME = os.path.join(THEMES, "example")
try:
    import weasyprint  # noqa: F401  # optional: PDF tests run only where it is installed
    HAVE_WEASYPRINT = True
except (ImportError, OSError):
    HAVE_WEASYPRINT = False

# Evidence strings in nic-health's formats (fictional values)
EV_MODULE_25G = ("Temperature [C]=39 [-5..90]; Voltage [mV]=3325.3 [3080..3500]; Bias Current [mA]=5.500 [0.5..13]; "
                 "Rx Power Current [dBm]=-8.827 [-11.308..3.398]; Tx Power Current [dBm]=-0.846 [-9.431..3.398]; "
                 "Tx Fault [per lane]=0; Rx LOS [per lane]=0; module VENDOR PART25")
EV_MODULE_100G = ("Temperature [C]=52 [-8..93]; Voltage [mV]=3295.3 [2850..3700]; Bias Current [mA]=7.592,7.468,7.468,7.408 [3..13]; "
                  "Rx Power Current [dBm]=-1.445,-0.405,-0.372,-1.284 [-14.089..3.398]; "
                  "Tx Power Current [dBm]=1.386,1.189,1.339,1.278 [-10..5]; Tx Fault [per lane]=0,0,0,0; module VENDOR PART100")
EV_MODULE_DARK = ("Temperature [C]=34 [-5..90]; Rx Power Current [dBm]=-40 [-11.308..3.398] (not judged: no link); "
                  "Tx Power Current [dBm]=-0.92 [-9.431..3.398]; module VENDOR PART25")
EV_PHY = ("rx_symbol_err_phy=414877072 (+943) rx_pcs_symbol_err_phy=414877072 (+943) "
          "rx_corrected_bits_phy=2379976318 (+9297); rx_bits_phy not exposed")
EV_BER = "Effective Physical BER=3E-9 Raw Physical BER=7E-7 Effective Physical Errors=44030843 since 9387.7 min"
EV_BER_ZERO = "Effective Physical BER=15E-255 Raw Physical BER=15E-255 Effective Physical Errors=0 since 62465.4 min"


def rec(severity, scope, target, check_id, value="", evidence="", hint="", threshold=""):
    return {"severity": severity, "scope": scope, "target": target, "check_id": check_id, "value": value,
            "unit": "", "threshold": threshold, "evidence": evidence, "hint": hint, "ref": "docs/design/nic-health.md"}


def host_doc(host, verdict, version="2.13.0", collected="2026-10-26T12:00:00Z", interval=30, extra=()):
    results = [
        rec("OK", "asic", "0000:01:00", "generic.pcie.link", "16.0 GT/s x8"),
        rec("OK", "asic", "0000:01:00 (Module0)", "generic.temperature", "39"),
        rec("OK", "port", "eth0", "generic.link.state", "up"),
        rec("N/A", "port", "eth1", "generic.link.state", "no link", hint="Spare port without link"),
        rec("OK", "port", "eth0", "generic.link.flaps", "+0", "carrier_changes=3 (since driver load)"),
        rec("OK", "port", "eth0", "mlx5.deep.fec", "link: Firecode FEC", "FEC=Firecode FEC; module Compliance=100GBASE-SR4 or 25GBASE-SR"),
        rec("OK", "port", "eth0", "mlx5.deep.module", "Rx=-0.1", EV_MODULE_25G.replace("-8.827", "-0.100")),
        rec("N/A", "port", "eth1", "mlx5.deep.ber", "-", "no link (operstate=down): see generic.link.state"),
    ] + list(extra)
    return {"schema_version": 1, "tool": "nic-health.sh", "version": version, "host": host, "collected_at": collected,
            "uptime_s": 1000 if version >= "2.13.0" else None, "boot_id": None, "level": "deep", "mode": "delta",
            "interval_s": interval, "verdict": verdict, "exit_code": 0, "results": results}


def write_sweep(root, site, stamp, hosts, schema=1):
    """hosts: list of (name, status, verdict, doc or None)."""
    d = os.path.join(root, site, stamp)
    os.makedirs(os.path.join(d, "nodes"))
    with open(os.path.join(d, "sweep.json"), "w") as fh:
        json.dump({"schema_version": schema, "tool": "nic-sweep.sh", "version": "2.13.0", "site": site}, fh)
    with open(os.path.join(d, "MANIFEST.tsv"), "w") as fh:
        fh.write("host\taddress\tstatus\texit_code\tduration_s\txray\tverdict\n")
        for name, status, verdict, doc in hosts:
            fh.write(f"{name}\t10.0.0.1\t{status}\t{0 if status == 'ok' else 255}\t5\tok\t{verdict or '-'}\n")
            if doc is not None:
                with open(os.path.join(d, "nodes", name + ".json"), "w") as nf:
                    json.dump(doc, nf)
    return d


class Fixture(unittest.TestCase):
    """A sweep tree with SITE1 (two sweeps) and SITE2 (one, later), plus legacy CSVs."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        t = cls.root = os.path.join(cls.tmp.name, "sweeps")
        crit = [rec("CRIT", "port", "eth0", "mlx5.phy.errors", "rx_symbol_err_phy=+943", EV_PHY, "Uncorrectable symbol errors"),
                rec("WARN", "port", "eth0", "mlx5.deep.ber", "effective 3E-9", EV_BER, "Clean the optic")]
        write_sweep(t, "SITE1", "20261020T100000Z", [
            ("acme-s1-stop1d-01", "ok", "OK", host_doc("acme-s1-stop1d-01", "OK", version="2.12.1", interval=5)),
        ])
        write_sweep(t, "SITE1", "20261026T100000Z", [
            ("acme-s1-stop1d-01", "ok", "CRIT", host_doc("acme-s1-stop1d-01", "CRIT", extra=crit)),
            ("acme-s1-stop1d-02", "ok", "OK", host_doc("acme-s1-stop1d-02", "OK")),
            ("acme-s1-ctrl2d-01", "ok", "OK", host_doc("acme-s1-ctrl2d-01", "OK")),
            ("acme-s1-ctrl2d-02", "ssh-fail", None, None),
        ])
        write_sweep(t, "SITE2", "20261025T080000Z", [
            ("acme-s2-cmpgp4ad-01", "ok", "WARN", host_doc("acme-s2-cmpgp4ad-01", "WARN", version="2.12.1",
                extra=[rec("WARN", "port", "eth0", "generic.link.lookback", "3", "3 link-downs")])),
        ])
        # Legacy CSV: per-host, CRLF, leading blank line, one field wrapped by a terminal
        legacy = cls.legacy = os.path.join(cls.tmp.name, "legacy")
        os.makedirs(legacy)
        header = "severity,scope,target,check_id,value,unit,threshold,evidence,hint,ref"
        rows = [header,
                '"OK","asic","0000:18:00","generic.pcie.link","8.0 GT/s x8","","8.0 GT/s x8","ok","",""',
                '"OK","port","eno1","generic.link.state","up","","","operstate=up","",""',
                '"WARN","port","eno1","mlx5.nic.discards","rx_discards_phy=+7","","","rx_discards_phy=12818188 (+7)","NIC buf      fer exhausted",""']
        with open(os.path.join(legacy, "acme-s3-stoc2-01.oam.example_20261023T141935Z_nic-health.csv"), "wb") as fh:
            fh.write(b"\r\n" + "\r\n".join(rows).encode() + b"\r\n")
        with open(os.path.join(legacy, "acme-s3-stoc2-02_20261023T141935Z_nic-health.csv"), "w") as fh:
            fh.write("\n".join(rows[:3]) + "\n")
        merged = cls.merged = os.path.join(cls.tmp.name, "merged.csv")
        with open(merged, "w") as fh:
            fh.write('"site","hostname",' + header + "\n")
            fh.write('"SITE4","acme-s4-ctrl1-01","OK","port","eth0","generic.link.state","up","","","","",""\n')
            fh.write('"OTHER","acme-x-ctrl1-01","CRIT","port","eth0","generic.link.state","no link","","","","",""\n')

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def args(self, argv):
        return nr.parse_args(argv)

    def run_cli(self, *argv):
        p = subprocess.run([sys.executable, SCRIPT, *argv], capture_output=True, text=True)
        return p.returncode, p.stdout, p.stderr


class TestExtractors(unittest.TestCase):
    def test_rx_single_lane(self):
        self.assertEqual(nr.extract_rx_dbm(EV_MODULE_25G),
                         {"dbm": -8.827, "lanes": None, "low": -11.308, "high": 3.398, "judged": True})

    def test_rx_multi_lane_lowest(self):
        got = nr.extract_rx_dbm(EV_MODULE_100G)
        self.assertEqual(got["dbm"], -1.445)
        self.assertEqual(got["lanes"], [-1.445, -0.405, -0.372, -1.284])

    def test_rx_dark_port(self):
        got = nr.extract_rx_dbm(EV_MODULE_DARK)
        self.assertEqual((got["dbm"], got["judged"]), (-40.0, False))     # shown, not judged, without link
        self.assertTrue(nr.extract_tx_dbm(EV_MODULE_DARK)["judged"])

    def test_all_counters_zero_is_zero_not_none(self):
        for fn in (nr.extract_symbol_errors, nr.extract_crc_errors, nr.extract_discards):
            self.assertEqual(fn("all 7 counters are 0"), {"total": 0, "delta": 0}, fn.__name__)

    def test_tx_and_temp(self):
        self.assertEqual(nr.extract_tx_dbm(EV_MODULE_100G)["dbm"], 1.189)
        self.assertEqual(nr.extract_module_temp_c(EV_MODULE_100G), {"c": 52.0, "low": -8.0, "high": 93.0})

    def test_counters(self):
        self.assertEqual(nr.extract_symbol_errors(EV_PHY), {"total": 414877072, "delta": 943})
        self.assertEqual(nr.extract_crc_errors("rx_crc_errors_phy=3484582 (+2185599) rx_fragments_phy=3827 (+0)"),
                         {"total": 3484582, "delta": 2185599})
        self.assertEqual(nr.extract_discards("rx_discards_phy=12818188 (+7)"), {"total": 12818188, "delta": 7})
        self.assertEqual(nr.extract_symbol_errors("rx_symbol_err_phy=58"), {"total": 58, "delta": None})

    def test_carrier_and_aer(self):
        self.assertEqual(nr.extract_carrier_changes("carrier_changes=215125 (since driver load)"), 215125)
        self.assertEqual(nr.extract_carrier_changes("carrier_changes=7"), 7)
        self.assertEqual(nr.extract_aer_totals("totals since boot: cor=1 nonfatal=0 fatal=2"), {"cor": 1, "nonfatal": 0, "fatal": 2})

    def test_ber(self):
        self.assertEqual(nr.extract_ber(EV_BER), {"effective": 3e-9, "raw": 7e-7, "since_min": 9387.7})
        self.assertEqual(nr.extract_ber(EV_BER_ZERO)["effective"], 0.0)
        self.assertIsNone(nr.extract_ber("effective ~0"))          # the record value, not the evidence
        self.assertEqual(nr.extract_ber("Effective Physical BER=~0")["effective"], 0.0)

    def test_fec_and_compliance(self):
        self.assertEqual(nr.extract_fec("link: Standard RS-FEC - RS(528,514)"), "Standard RS-FEC - RS(528,514)")
        self.assertIsNone(nr.extract_fec("link: N/A"))
        self.assertEqual(nr.extract_compliance("FEC=Firecode FEC; module Compliance=100GBASE-SR4 or 25GBASE-SR"),
                         "100GBASE-SR4 or 25GBASE-SR")
        self.assertIsNone(nr.extract_compliance("FEC=No FEC; module Compliance=n/a"))

    def test_unparseable_is_none_never_zero(self):
        for fn in (nr.extract_rx_dbm, nr.extract_tx_dbm, nr.extract_module_temp_c, nr.extract_symbol_errors,
                   nr.extract_crc_errors, nr.extract_discards, nr.extract_carrier_changes, nr.extract_aer_totals,
                   nr.extract_ber, nr.extract_compliance):
            self.assertIsNone(fn("garbage"), fn.__name__)
            self.assertIsNone(fn(""), fn.__name__)
        self.assertIsNone(nr.extract_rx_dbm("Rx Power Current [dBm]=-1.4,N/A [-14..3]"))

    def test_metrics_for(self):
        self.assertIn("rx", nr.metrics_for("mlx5.deep.module", "", EV_MODULE_25G))
        self.assertEqual(nr.metrics_for("mlx5.deep.fec", "link: Firecode FEC", "FEC=Firecode FEC; module Compliance=X"),
                         {"fec": "Firecode FEC", "compliance": "X"})
        self.assertEqual(nr.metrics_for("generic.pcie.link", "16.0 GT/s x8", "x"), {})


class TestLoaders(Fixture):
    def test_load_sweep_dir(self):
        d = nr.load_sweep_dir(os.path.join(self.root, "SITE1", "20261026T100000Z"))
        self.assertEqual(d.site, "SITE1")
        self.assertEqual(sorted(d.hosts), ["acme-s1-ctrl2d-01", "acme-s1-ctrl2d-02", "acme-s1-stop1d-01", "acme-s1-stop1d-02"])
        self.assertEqual(d.hosts["acme-s1-ctrl2d-02"].status, "ssh-fail")
        self.assertEqual(d.hosts["acme-s1-ctrl2d-02"].raw_results, [])
        self.assertEqual(d.hosts["acme-s1-stop1d-01"].meta["tool_version"], "2.13.0")

    def test_newer_schema_refused(self):
        t = os.path.join(self.tmp.name, "newer")
        write_sweep(t, "SITE9", "20261026T100000Z", [], schema=2)
        with self.assertRaisesRegex(nr.InputError, "unsupported sweep schema_version 2"):
            nr.load_sweep_dir(os.path.join(t, "SITE9", "20261026T100000Z"))

    def test_not_a_sweep(self):
        with self.assertRaisesRegex(nr.InputError, "no sweep.json"):
            nr.load_sweep_dir(self.legacy)

    def test_import_crlf_blank_line_and_wrap(self):
        d = nr.import_paths("SITE3", [self.legacy])
        self.assertEqual(sorted(d.hosts), ["acme-s3-stoc2-01", "acme-s3-stoc2-02"])
        h = d.hosts["acme-s3-stoc2-01"]
        self.assertEqual(h.status, "imported")
        self.assertEqual(h.verdict, "WARN")
        self.assertEqual(d.repaired_fields, 1)
        hint = [r["hint"] for r in h.raw_results if r["check_id"] == "mlx5.nic.discards"][0]
        self.assertEqual(hint, "NIC buffer exhausted")

    def test_import_merged_keeps_only_its_site(self):
        d = nr.import_paths("SITE4", [self.merged])
        self.assertEqual(list(d.hosts), ["acme-s4-ctrl1-01"])

    def test_import_rejects_non_nic_health_csv(self):
        bad = os.path.join(self.tmp.name, "bad.csv")
        with open(bad, "w") as fh:
            fh.write("a,b\n1,2\n")
        with self.assertRaisesRegex(nr.InputError, "missing columns"):
            nr.import_paths("SITE5", [bad])

    def test_host_from_filename(self):
        self.assertEqual(nr.host_from_filename("/x/acme-s3-stoc2-01.oam.example_2026_nic-health.csv"), "acme-s3-stoc2-01")
        self.assertEqual(nr.host_from_filename("node-01_20261023T1Z.csv"), "node-01")

    def test_roles(self):
        d = nr.finalize(nr.load_sweep_dir(os.path.join(self.root, "SITE1", "20261026T100000Z")), nr.re.compile(ROLE_RE))
        self.assertEqual(d.hosts["acme-s1-stop1d-01"].role, "stop1d")
        self.assertEqual(d.hosts["acme-s1-ctrl2d-02"].role, "ctrl2d")


class TestSelection(Fixture):
    def test_latest_per_site(self):
        sites, missing = nr.load_selection(self.args(["-R", self.root]))
        self.assertEqual([(s.site, s.stamp) for s in sites], [("SITE1", "20261026T100000Z"), ("SITE2", "20261025T080000Z")])
        self.assertEqual(missing, [])

    def test_site_filter(self):
        sites, _ = nr.load_selection(self.args(["-R", self.root, "-s", "SITE2"]))
        self.assertEqual([s.site for s in sites], ["SITE2"])

    def test_unknown_site_lists_available(self):
        with self.assertRaisesRegex(nr.InputError, r"unknown site\(s\) NOPE .*available: SITE1, SITE2"):
            nr.load_selection(self.args(["-R", self.root, "-s", "NOPE"]))

    def test_at_selects_older_sweep(self):
        sites, missing = nr.load_selection(self.args(["-R", self.root, "-s", "SITE1", "--at", "2026-10-21"]))
        self.assertEqual(sites[0].stamp, "20261020T100000Z")

    def test_at_with_missing_site(self):
        sites, missing = nr.load_selection(self.args(["-R", self.root, "--at", "2026-10-21"]))
        self.assertEqual([s.site for s in sites], ["SITE1"])
        self.assertEqual(missing, ["SITE2"])

    def test_at_instant(self):
        sites, _ = nr.load_selection(self.args(["-R", self.root, "--at", "2026-10-26T09:59Z"]))
        self.assertEqual([(s.site, s.stamp) for s in sites], [("SITE1", "20261020T100000Z"), ("SITE2", "20261025T080000Z")])

    def test_same_site_twice_is_an_error(self):
        with self.assertRaisesRegex(nr.InputError, "selected more than once"):
            nr.load_selection(self.args(["-R", self.root, os.path.join(self.root, "SITE1", "20261020T100000Z")]))

    def test_explicit_dirs_and_imports_mix(self):
        sites, _ = nr.load_selection(self.args([os.path.join(self.root, "SITE2", "20261025T080000Z"),
                                                "--import", "SITE3", self.legacy]))
        self.assertEqual([(s.site, s.source) for s in sites], [("SITE2", "sweep"), ("SITE3", "import")])


class TestAnalyses(Fixture):
    def result(self, argv):
        args = self.args(argv + ["--role-regex", ROLE_RE])
        sites, missing = nr.load_selection(args)
        return nr.analyse(sites, missing), sites, missing, args

    def test_single_site_coverage_by_role(self):
        res, *_ = self.result(["-R", self.root, "-s", "SITE1"])
        self.assertFalse(res["multi_site"])
        cov = res["coverage"]
        self.assertEqual(cov["by"], "role")
        groups = {g["group"]: g for g in cov["groups"]}
        self.assertEqual(sorted(groups), ["ctrl2d", "stop1d"])
        self.assertEqual(groups["stop1d"]["asics"], 2)          # pcie.link once per host, not per sensor label
        self.assertEqual(groups["stop1d"]["ports"], 4)
        self.assertEqual(groups["stop1d"]["ports_with_link"], 2)
        self.assertEqual(groups["ctrl2d"]["collected"], 1)
        self.assertEqual(cov["not_collected"], [{"site": "SITE1", "host": "acme-s1-ctrl2d-02", "status": "ssh-fail",
                                                 "exit_code": "255", "problem": None}])

    def test_multi_site_coverage_and_caveats(self):
        res, *_ = self.result(["-R", self.root, "--import", "SITE3", self.legacy])
        cov = res["coverage"]
        self.assertTrue(res["multi_site"])
        self.assertEqual([g["group"] for g in cov["groups"]], ["SITE1", "SITE2", "SITE3"])
        text = " ".join(cov["caveats"])
        self.assertIn("Mixed nic-health versions: 2.12.1, 2.13.0", text)
        self.assertIn("SITE3: imported from CSV", text)
        self.assertIn("1 wrapped fields repaired", text)
        self.assertIn("older than 2.13.0", text)

    def test_missing_site_caveat(self):
        res, *_ = self.result(["-R", self.root, "--at", "2026-10-21"])
        self.assertEqual(res["coverage"]["missing_sites"], ["SITE2"])
        self.assertTrue(any("SITE2: no sweep" in c for c in res["coverage"]["caveats"]))
        self.assertTrue(res["multi_site"])

    def test_verdicts(self):
        res, *_ = self.result(["-R", self.root, "-s", "SITE1"])
        v = res["verdicts"][0]
        self.assertEqual((v["hosts"], v["collected"]), (4, 3))
        self.assertEqual(v["by_verdict"], {"OK": 2, "WARN": 0, "CRIT": 1, "UNKNOWN": 0})
        self.assertEqual(v["clean_pct"], 66.7)
        self.assertEqual(v["findings"], {"CRIT": 1, "WARN": 1, "UNKNOWN": 0})
        roles = {r["role"]: r for r in v["roles"]}
        self.assertEqual(roles["stop1d"]["by_verdict"]["CRIT"], 1)

    def test_findings_worst_first_only_problems(self):
        res, *_ = self.result(["-R", self.root])
        f = res["findings"]
        self.assertEqual([(r["site"], r["severity"], r["check_id"]) for r in f],
                         [("SITE1", "CRIT", "mlx5.phy.errors"), ("SITE1", "WARN", "mlx5.deep.ber"),
                          ("SITE2", "WARN", "generic.link.lookback")])
        self.assertEqual(f[0]["metrics"]["symbol_errors"], {"total": 414877072, "delta": 943})
        self.assertEqual(f[0]["role"], "stop1d")
        self.assertEqual(f[0]["tool_version"], "2.13.0")


class TestRendering(Fixture):
    def render(self, argv, fmt="md"):
        args = self.args(argv + ["--role-regex", ROLE_RE, "-O", fmt])
        sites, missing = nr.load_selection(args)
        res = nr.analyse(sites, missing)
        now = nr.datetime.datetime(2026, 10, 26, 12, 0, tzinfo=nr.datetime.timezone.utc)
        fn = nr.render_json if fmt == "json" else nr.render_md
        return fn(res, sites, missing, args, now)

    def test_single_site_markdown(self):
        md = self.render(["-R", self.root, "-s", "SITE1"])
        self.assertTrue(md.startswith("# 🩺 NIC Health: SITE1\n"))
        for heading in ("## 1. Coverage and comparability", "## 2. Verdicts", "## 3. Findings", "### acme-s1-stop1d-01"):
            self.assertIn(heading, md)
        self.assertIn("| Host | Role | Status | Verdict |", md)       # per-host table only in single-site layout
        self.assertIn("**Hosts not collected**", md)
        self.assertTrue(md.rstrip().endswith("Ciro Iriarte · 2026-10-26 12:00:00 +00:00"))
        self.assertIn("Generated by nic-report v" + nr.SCRIPT_VERSION, md)

    def test_multi_site_markdown(self):
        md = self.render(["-R", self.root])
        self.assertIn("# 🩺 NIC Health: cross-site comparison (SITE1 · SITE2)", md)
        self.assertIn("| Site | Hosts | Collected |", md)
        self.assertIn("### SITE1 by role", md)
        self.assertIn("### SITE1 · acme-s1-stop1d-01", md)
        self.assertNotIn("| Host | Role | Status | Verdict |", md)

    def test_json_document(self):
        doc = json.loads(self.render(["-R", self.root, "--at", "2026-10-21"], fmt="json"))
        self.assertEqual(doc["schema_version"], 1)
        self.assertEqual(doc["generator"]["tool"], "nic-report.py")
        self.assertEqual(doc["selection"]["missing_sites"], ["SITE2"])
        self.assertEqual(doc["selection"]["sites"][0]["sweep"], "20261020T100000Z")
        self.assertTrue({"coverage", "verdicts", "findings", "multi_site"} <= set(doc))

    def test_title_and_classification(self):
        md = self.render(["-R", self.root, "-s", "SITE2", "--title", "Quarterly check", "--classification", "internal"])
        self.assertTrue(md.startswith("# 🩺 Quarterly check\n"))
        self.assertIn("- **Classification:** internal", md)

    def test_pipe_in_values_does_not_break_tables(self):
        self.assertEqual(nr.md_cell("a|b\nc"), "a/b c")


class TestCLI(Fixture):
    def test_version(self):
        rc, out, _ = self.run_cli("--version")
        self.assertEqual((rc, out.strip()), (0, f"nic-report.py {nr.SCRIPT_VERSION}"))

    def test_usage_errors_exit_3(self):
        for argv in ([], ["--at", "2026-10-21", self.root], ["-R", self.root, "--at", "yesterday"],
                     ["-R", self.root, "-s", "bad/site"], ["-R", self.root, "-O", "pdf"], ["--import", "SITE3"],
                     ["-R", self.root, "--role-regex", "("], ["--bogus"]):
            rc, _, err = self.run_cli(*argv)
            self.assertEqual(rc, 3, f"{argv}: {err}")

    def test_input_errors_exit_1(self):
        for argv in (["-R", self.root, "-s", "NOPE"], [self.legacy], ["--import", "SITE3", "/nonexistent"],
                     ["-R", os.path.join(self.tmp.name, "no-such-root")]):
            rc, _, err = self.run_cli(*argv)
            self.assertEqual(rc, 1, f"{argv}: {err}")
            self.assertIn("❌", err)

    def test_output_file(self):
        out = os.path.join(self.tmp.name, "report.json")
        rc, stdout, _ = self.run_cli("-R", self.root, "-O", "json", "-o", out)
        self.assertEqual((rc, stdout), (0, ""))
        with open(out) as fh:
            self.assertEqual(json.load(fh)["schema_version"], 1)

    def test_main_returns_codes(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(nr.main(["-R", self.root, "-s", "SITE2"]), 0)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(nr.main(["-R", self.root, "-s", "NOPE"]), 1)


class TestMalformedInput(unittest.TestCase):
    """Odd input must end in an error message (exit 1) or a marked host, never a traceback."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = os.path.join(self.tmp.name, "sweeps")

    def sweep(self, site="SITE1", stamp="20261026T100000Z", docs=None):
        docs = docs if docs is not None else {"acme-s1-ctrl2d-01": host_doc("acme-s1-ctrl2d-01", "OK")}
        return write_sweep(self.root, site, stamp, [(n, "ok", "OK", d) for n, d in docs.items()])

    def cli(self, *argv):
        p = subprocess.run([sys.executable, SCRIPT, *argv], capture_output=True, text=True)
        return p.returncode, p.stdout, p.stderr

    def assert_clean_failure(self, *argv):
        rc, _, err = self.cli(*argv)
        self.assertEqual(rc, 1, err)
        self.assertNotIn("Traceback", err)
        self.assertIn("❌", err)
        return err

    def test_sweep_json_not_an_object(self):
        d = self.sweep()
        with open(os.path.join(d, "sweep.json"), "w") as fh:
            fh.write("[1, 2]")
        self.assert_clean_failure(d)

    def test_site_not_a_string(self):
        d = self.sweep()
        with open(os.path.join(d, "sweep.json"), "w") as fh:
            json.dump({"schema_version": 1, "site": 5}, fh)
        self.assertIn("invalid site name", self.assert_clean_failure(d))

    def test_schema_version_bool_refused(self):
        d = self.sweep()
        with open(os.path.join(d, "sweep.json"), "w") as fh:
            json.dump({"schema_version": True, "site": "SITE1"}, fh)
        self.assertIn("schema_version", self.assert_clean_failure(d))

    def test_manifest_not_utf8(self):
        d = self.sweep()
        with open(os.path.join(d, "MANIFEST.tsv"), "wb") as fh:
            fh.write(b"host\tstatus\n\xff\xfe\tok\n")
        self.assert_clean_failure(d)

    def test_bad_node_documents_mark_the_host_only(self):
        good = host_doc("acme-s1-ctrl2d-01", "OK")
        d = self.sweep(docs={"acme-s1-ctrl2d-01": good, "acme-s1-ctrl2d-02": good, "acme-s1-ctrl2d-03": good,
                             "acme-s1-ctrl2d-04": good})
        bad = {"acme-s1-ctrl2d-02": "[1]", "acme-s1-ctrl2d-03": '{"results": {"a": 1}}',
               "acme-s1-ctrl2d-04": '{"results": [1, 2]}'}
        for name, text in bad.items():
            with open(os.path.join(d, "nodes", name + ".json"), "w") as fh:
                fh.write(text)
        data = nr.load_sweep_dir(d)
        self.assertEqual(data.hosts["acme-s1-ctrl2d-01"].status, "ok")
        for name in bad:
            self.assertEqual(data.hosts[name].status, nr.ST_UNREADABLE, name)
            self.assertIsNotNone(data.hosts[name].problem)
        os.remove(os.path.join(d, "nodes", "acme-s1-ctrl2d-01.json"))
        res = nr.analyse([nr.finalize(nr.load_sweep_dir(d), None)], [])
        self.assertEqual(len(res["coverage"]["not_collected"]), 4)
        self.assertTrue(any("missing or malformed result file" in c for c in res["coverage"]["caveats"]))

    def test_invalid_utf8_is_replaced_not_fatal(self):
        doc = host_doc("acme-s1-ctrl2d-01", "CRIT", extra=[rec("CRIT", "port", "eth0", "mlx5.phy.errors", "x", EV_PHY)])
        d = self.sweep(docs={"acme-s1-ctrl2d-01": doc})
        node = os.path.join(d, "nodes", "acme-s1-ctrl2d-01.json")
        with open(node, "rb") as fh:
            raw = fh.read()
        with open(node, "wb") as fh:                          # a module EEPROM string with one bad byte
            fh.write(raw.replace(b"VENDOR PART25", b"VEND\xffR PART25"))
        res = nr.analyse([nr.finalize(nr.load_sweep_dir(d), None)], [])
        self.assertEqual(res["coverage"]["not_collected"], [])
        self.assertEqual([r["severity"] for r in res["findings"]], ["CRIT"])     # the CRIT stays visible
        self.assertIn("1 host file(s) contained invalid UTF-8, replaced with U+FFFD: SITE1/acme-s1-ctrl2d-01.",
                      res["coverage"]["caveats"])
        with self.assertRaises(nr.InputError):                # other inputs stay strict
            nr.read_json(node)

    def test_node_file_size_limit(self):
        d = self.sweep()
        node = os.path.join(d, "nodes", "acme-s1-ctrl2d-01.json")
        with open(node, "ab") as fh:
            fh.write(b" " * (nr.NODE_MAX_BYTES + 1))           # whitespace: valid JSON, but too large
        host = nr.load_sweep_dir(d).hosts["acme-s1-ctrl2d-01"]
        self.assertEqual(host.status, nr.ST_UNREADABLE)
        self.assertIn("larger than 32768 KiB", host.problem)

    def test_odd_field_types_do_not_crash(self):
        doc = host_doc("acme-s1-ctrl2d-01", "OK")
        doc["collected_at"], doc["interval_s"], doc["version"] = 20261026, "30", ["x"]
        doc["results"].append({"severity": "WARN", "scope": "port", "target": 7, "check_id": None, "evidence": 3.5})
        doc2 = host_doc("acme-s1-ctrl2d-02", "OK", interval=30)
        d = self.sweep(docs={"acme-s1-ctrl2d-01": doc, "acme-s1-ctrl2d-02": doc2})
        rc, out, err = self.cli(d)
        self.assertEqual(rc, 0, err)
        self.assertIn("`7`", out)
        data = nr.load_sweep_dir(d)
        self.assertEqual(data.hosts["acme-s1-ctrl2d-01"].meta["interval_s"], None)
        self.assertEqual(data.hosts["acme-s1-ctrl2d-01"].meta["collected_at"], None)

    def test_csv_with_nul_byte(self):
        f = os.path.join(self.tmp.name, "h1_x.csv")
        with open(f, "w") as fh:
            fh.write("severity,scope,target,check_id,value,unit,threshold,evidence,hint,ref\n\"OK\0\",a,b,c,d,e,f,g,h,i\n")
        self.assertIn("NUL bytes", self.assert_clean_failure("-i", "SITE3", f))   # on every Python version

    def test_invalid_stamp_dates_are_skipped(self):
        self.sweep(stamp="20261020T100000Z")
        self.sweep(stamp="20261399T100000Z")
        self.assertEqual(nr.list_tree(self.root), {"SITE1": ["20261020T100000Z"]})
        rc, _, err = self.cli("-R", self.root, "-a", "2026-10-30")
        self.assertEqual(rc, 0, err)

    def test_site_in_sweep_json_must_match_tree(self):
        d = self.sweep(site="SITE1")
        with open(os.path.join(d, "sweep.json"), "w") as fh:
            json.dump({"schema_version": 1, "site": "OTHER"}, fh)
        self.assertIn("is for site 'OTHER', not 'SITE1'", self.assert_clean_failure("-R", self.root, "-s", "SITE1"))

    def test_all_selected_sites_missing_is_an_error(self):
        self.sweep(stamp="20261026T100000Z")
        self.assertIn("no sweep at or before", self.assert_clean_failure("-R", self.root, "-a", "2026-10-01"))

    def test_manifest_without_hosts_or_columns(self):
        d = self.sweep()
        with open(os.path.join(d, "MANIFEST.tsv"), "w") as fh:
            fh.write("host\taddress\tstatus\texit_code\tduration_s\txray\tverdict\n")
        self.assertIn("lists no hosts", self.assert_clean_failure(d))
        with open(os.path.join(d, "MANIFEST.tsv"), "w") as fh:
            fh.write("name\tstate\nx\tok\n")
        self.assertIn("missing columns: host, status", self.assert_clean_failure(d))

    def test_unreadable_reason_shown_in_markdown(self):
        d = self.sweep()
        os.remove(os.path.join(d, "nodes", "acme-s1-ctrl2d-01.json"))
        rc, out, err = self.cli(d)
        self.assertEqual(rc, 0, err)
        self.assertIn("| Site | Host | Status | Exit | Problem |", out)
        self.assertIn("unreadable-result", out)
        self.assertIn("No such file or directory", out)

    def test_manifest_verdict_fallback(self):
        doc = host_doc("acme-s1-ctrl2d-01", "WARN")
        d = write_sweep(self.root, "SITE1", "20261026T100000Z", [("acme-s1-ctrl2d-01", "ok", None, doc)])
        self.assertEqual(nr.load_sweep_dir(d).hosts["acme-s1-ctrl2d-01"].verdict, "WARN")


class TestImportRules(Fixture):
    def write(self, name, rows, header="severity,scope,target,check_id,value,unit,threshold,evidence,hint,ref"):
        d = tempfile.mkdtemp(dir=self.tmp.name)
        path = os.path.join(d, name)
        with open(path, "w") as fh:
            fh.write(header + "\n" + "".join(r + "\n" for r in rows))
        return d, path

    def test_two_files_for_one_host_refused(self):
        d, _ = self.write("h1_a.csv", ['"OK","port","eth0","generic.link.state","up","","","","",""'])
        with open(os.path.join(d, "h1_b.csv"), "w") as fh:
            fh.write("severity,scope,target,check_id,value,unit,threshold,evidence,hint,ref\n"
                     '"OK","port","eth0","generic.link.state","up","","","","",""\n')
        with self.assertRaisesRegex(nr.InputError, "host h1 of site SITE3 is in two files"):
            nr.import_paths("SITE3", [d])

    def test_no_rows_for_site_refused(self):
        _, path = self.write("x.csv", [], header="site,hostname,severity,scope,target,check_id,value,unit,threshold,evidence,hint,ref")
        with self.assertRaisesRegex(nr.InputError, "no rows for site SITE3"):
            nr.import_paths("SITE3", [path])
        with self.assertRaisesRegex(nr.InputError, "no rows for site OTHER2"):
            nr.import_paths("OTHER2", [self.merged])

    def test_same_file_twice_imported_once(self):
        d, path = self.write("h1_a.csv", ['"WARN","port","eth0","x.check","v","","","","",""'])
        for paths in ([path, path], [d, path], [d, os.path.join(d, ".", "h1_a.csv")]):
            data = nr.import_paths("SITE3", paths)
            self.assertEqual(len(data.hosts["h1"].raw_results), 1, paths)

    def test_other_site_rows_counted(self):
        args = self.args(["-i", "SITE4", self.merged])
        sites, missing = nr.load_selection(args)
        self.assertEqual(sites[0].other_site_rows, 1)
        res = nr.analyse(sites, missing)
        self.assertTrue(any("1 rows of other sites skipped" in c for c in res["coverage"]["caveats"]))

    def test_import_verdict_precedence(self):
        row = '"{}","port","eth0","x.check","v","","","","",""'
        d, _ = self.write("h1_a.csv", [row.format(s) for s in ("OK", "UNKNOWN", "WARN", "CRIT")])
        with open(os.path.join(d, "h2_a.csv"), "w") as fh:
            fh.write("severity,scope,target,check_id,value,unit,threshold,evidence,hint,ref\n"
                     + "".join(row.format(s) + "\n" for s in ("OK", "N/A", "UNKNOWN")))
        with open(os.path.join(d, "h3_a.csv"), "w") as fh:
            fh.write("severity,scope,target,check_id,value,unit,threshold,evidence,hint,ref\n"
                     + "".join(row.format(s) + "\n" for s in ("OK", "N/A")))
        data = nr.import_paths("SITE3", [d])
        self.assertEqual({h: data.hosts[h].verdict for h in ("h1", "h2", "h3")}, {"h1": "CRIT", "h2": "UNKNOWN", "h3": "OK"})


class TestBoundariesAndOptions(Fixture):
    def test_at_end_of_day_boundary(self):
        root = os.path.join(self.tmp.name, "boundary")
        for stamp in ("20261023T235959Z", "20261024T000000Z"):
            write_sweep(root, "SITE7", stamp, [("acme-s7-ctrl2d-01", "ok", "OK", host_doc("acme-s7-ctrl2d-01", "OK"))])
        sites, _ = nr.load_selection(self.args(["-R", root, "-a", "2026-10-23"]))
        self.assertEqual(sites[0].stamp, "20261023T235959Z")
        sites, _ = nr.load_selection(self.args(["-R", root, "-a", "2026-10-24"]))
        self.assertEqual(sites[0].stamp, "20261024T000000Z")

    def test_role_regex_unnamed_group_and_no_group(self):
        self.assertEqual(nr.role_of("acme-s1-stop1d-01", nr.re.compile(r"-([a-z]+\d+[a-z]*)-\d+$")), "stop1d")
        self.assertEqual(nr.role_of("nomatch", nr.re.compile(ROLE_RE)), "")
        rc, _, err = self.run_cli("-R", self.root, "-r", "^acme")
        self.assertEqual(rc, 3, err)
        self.assertIn("needs a group", err)

    def test_short_options_and_no_abbreviation(self):
        rc, out, err = self.run_cli("-R", self.root, "-s", "SITE1", "-a", "2026-10-21", "-r", ROLE_RE,
                                    "-t", "T", "-c", "C", "-i", "SITE3", self.legacy)
        self.assertEqual(rc, 0, err)
        self.assertTrue(out.startswith("# 🩺 T\n"))
        rc, _, _ = self.run_cli("--sweep", self.root)
        self.assertEqual(rc, 3)

    def test_import_list_ends_with_double_dash(self):
        rc, out, err = self.run_cli("-i", "SITE3", self.legacy, "--", os.path.join(self.root, "SITE2", "20261025T080000Z"))
        self.assertEqual(rc, 0, err)
        self.assertIn("cross-site comparison (SITE2 · SITE3)", out)

    def test_markdown_escaping_of_untrusted_text(self):
        self.assertEqual(nr.md_inline("a`b\nc  d"), "a'b c d")


class TestRealSamples(unittest.TestCase):
    """The repository's own captured outputs (samples/), as design §6.2 asks."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_json_sample_as_a_sweep(self):
        with open(os.path.join(REPO, "samples", "nic-health-json-deep.json"), encoding="utf-8") as fh:
            doc = json.load(fh)
        d = write_sweep(os.path.join(self.tmp.name, "sweeps"), "SITE1", "20261020T174609Z",
                        [("server-01", "ok", doc["verdict"], doc)])
        res = nr.analyse([nr.finalize(nr.load_sweep_dir(d), None)], [])
        g = res["coverage"]["groups"][0]
        self.assertEqual((g["asics"], g["ports"], g["fec"]), (4, 8, {"No FEC": 8}))
        self.assertEqual((g["ports_with_link"], g["hosts_without_link_state"]), (8, []))
        self.assertEqual((g["hosts_with_typed_metrics"], g["hosts_with_impact_facts"]), (1, 1))
        facts = {p["port"]: p.get("service") for p in nr.port_facts([nr.finalize(nr.load_sweep_dir(d), None)])}
        self.assertEqual(facts["ens13f0np0"], {"in_use": True, "in_use_reasons": ["bond"], "bond": "bond0",
                                               "bond_link_failures": 2, "has_traffic": True})
        self.assertEqual(facts["ens4f1np1"], {"in_use": False, "in_use_reasons": [], "has_traffic": False})
        self.assertEqual(res["verdicts"][0]["by_verdict"]["CRIT"], 1)
        self.assertEqual(len(res["findings"]), 20)                       # 16 WARN + 4 CRIT
        recs = [r for r in nr.load_sweep_dir(d).hosts["server-01"].raw_results]
        zero = [r for r in recs if r["check_id"] == "mlx5.phy.errors" and "counters are 0" in r["evidence"]]
        self.assertTrue(zero)
        self.assertEqual(nr.metrics_for("mlx5.phy.errors", "", zero[0]["evidence"])["symbol_errors"], {"total": 0, "delta": 0})

    def test_csv_sample_import(self):
        path = os.path.join(self.tmp.name, "server-01_20261020T174609Z_nic-health.csv")
        with open(os.path.join(REPO, "samples", "nic-health-csv-deep.csv"), encoding="utf-8") as src, open(path, "w") as dst:
            dst.write(src.read())
        data = nr.import_paths("SITE1", [path])
        self.assertEqual(list(data.hosts), ["server-01"])
        self.assertEqual(len(data.hosts["server-01"].raw_results), 24)
        self.assertEqual(data.hosts["server-01"].verdict, "CRIT")


def port_rows(port, link=True, rx=None, tx=-1.0, comp="100GBASE-SR4 or 25GBASE-SR", part="VENDOR PART25",
              judged=True, sym=None, carrier=1, discards=None, temp=40, temp_high=90, low=-11.3):
    """nic-health records for one port in real evidence formats (fictional values)."""
    rows = [rec("OK", "port", port, "generic.link.state", "up" if link else "no link"),
            rec("OK", "port", port, "generic.link.flaps", "+0", f"carrier_changes={carrier} (since driver load)")]
    if rx is not None:
        rx = ",".join(str(v) for v in rx) if isinstance(rx, (list, tuple)) else rx
        note = "" if judged else " (not judged: no link)"
        rows.append(rec("OK", "port", port, "mlx5.deep.module", "",
                        f"Temperature [C]={temp} [-5..{temp_high}]; Rx Power Current [dBm]={rx} [{low}..3.398]{note}; "
                        f"Tx Power Current [dBm]={tx} [-9.4..3.398]; Tx Fault [per lane]=0; module {part}"))
    if link and comp:
        rows.append(rec("OK", "port", port, "mlx5.deep.fec", "link: Firecode FEC", f"FEC=Firecode FEC; module Compliance={comp}"))
    rows.append(rec("OK", "port", port, "mlx5.phy.errors", "+0",
                    f"rx_symbol_err_phy={sym} (+0)" if sym else "all 4 counters are 0"))
    if discards:
        rows.append(rec("WARN", "port", port, "mlx5.nic.discards", f"rx_discards_phy=+1", f"rx_discards_phy={discards} (+1)"))
    return rows


def ports_doc(host, ports, uptime=3600 * 1000, extra=()):
    doc = host_doc(host, "OK")
    doc["results"] = [rec("OK", "asic", "0000:01:00", "generic.pcie.link", "16.0 GT/s x8")] + list(extra)
    for p in ports:
        doc["results"] += port_rows(**p)
    doc["uptime_s"] = uptime
    return doc


class Phase4Base(unittest.TestCase):
    """Shared fixtures for the Phase 4 tests (no tests of its own)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = os.path.join(self.tmp.name, "sweeps")

    def site(self, site, hosts, stamp="20261026T100000Z"):
        return write_sweep(self.root, site, stamp, [(h, "ok", "OK", ports_doc(h, ps, **kw)) for h, ps, kw in hosts])

    def analyse(self, argv):
        args = nr.parse_args(argv + ["-r", ROLE_RE])
        sites, missing = nr.load_selection(args)
        return nr.analyse(sites, missing, args, nr.load_baseline_sites(args, sites)), sites, missing, args

    def normal_site(self, site="SITE1", weak=None):
        hosts = []
        for i in range(1, 5):
            ports = [{"port": f"eth{j}", "rx": round(-0.4 + 0.05 * ((i + j) % 5), 3)} for j in range(4)]
            if weak and i == 1:
                ports[0]["rx"] = weak
            hosts.append((f"acme-{site.lower()}-stop1d-0{i}", ports, {}))
        return self.site(site, hosts)


class TestBaselinesAndOutliers(Phase4Base):
    def test_stats(self):
        st = nr._stats([-1.0, -0.5, 0.0, 0.5, 9.0])
        self.assertEqual((st["ports"], st["min"], st["p5"], st["median"], st["max"], st["mad"]), (5, -1.0, -1.0, 0.0, 9.0, 0.5))
        self.assertEqual(nr._stats([float(v) for v in range(21)])["p5"], 1.0)     # nearest rank

    def test_robust_score_side_of_the_rule(self):
        # A wide group: -8 is 6 dB under the median but only ~1 MAD-sigma away, so not an outlier
        values = [-8, -6, -4, -2, 0, 2, 4]
        self.site("SITE1", [(f"acme-s1-stop1d-0{i}", [{"port": "eth0", "rx": v}], {}) for i, v in enumerate(values, 1)])
        res, *_ = self.analyse(["-R", self.root])
        self.assertEqual(res["baselines"]["rx_outliers"], [])
        self.assertEqual(res["baselines"]["rx_by_module_type"]["100GBASE-SR4 or 25GBASE-SR"]["mad"], 4)

    def test_multi_lane_modules_are_their_own_type(self):
        hosts = [(f"acme-s1-stop1d-0{i}", [{"port": "eth0", "rx": -0.5},
                                            {"port": "eth1", "rx": [-1.2, -0.4, -0.3, -0.5], "part": "VENDOR P100"}], {})
                 for i in range(1, 4)]
        self.site("SITE1", hosts)
        res, *_ = self.analyse(["-R", self.root])
        types = res["baselines"]["rx_by_module_type"]
        self.assertEqual(types["100GBASE-SR4 or 25GBASE-SR · 4-lane"]["ports"], 3)
        self.assertEqual(types["100GBASE-SR4 or 25GBASE-SR · 4-lane"]["median"], -1.2)      # lowest lane
        self.assertEqual(types["100GBASE-SR4 or 25GBASE-SR"]["ports"], 3)

    def test_baseline_all_types_ports_the_same_way(self):
        # SITE1 has no FEC compliance (only the part number); SITE2 knows the part's compliance
        self.site("SITE1", [("acme-s1-stop1d-01", [{"port": "eth0", "rx": -9.0, "comp": None, "part": "VEND P"},
                                                   {"port": "eth1", "rx": -0.4, "comp": None, "part": "VEND P"}], {})])
        self.site("SITE2", [(f"acme-s2-stop1d-0{i}", [{"port": f"eth{j}", "rx": -0.5 + 0.05 * j, "part": "VEND P"}
                                                       for j in range(3)], {}) for i in range(1, 4)])
        res, *_ = self.analyse(["-R", self.root])
        self.assertEqual([(o["site"], o["port"]) for o in res["baselines"]["rx_outliers"]], [("SITE1", "eth0")])
        res, *_ = self.analyse(["-R", self.root, "-s", "SITE1", "-b", "all"])
        self.assertEqual([(o["site"], o["port"], o["module_type"]) for o in res["baselines"]["rx_outliers"]],
                         [("SITE1", "eth0", "100GBASE-SR4 or 25GBASE-SR")])

    def test_baseline_all_does_not_leak_other_sites(self):
        noisy = [rec("WARN", "asic", "0000:04:00", "generic.pcie.link", "2.5 GT/s x4")]
        self.site("SITE1", [(f"acme-s1-stop1d-0{i}", [{"port": "eth0", "rx": -0.5}], {}) for i in range(1, 4)])
        self.site("SITE2", [(f"acme-s2-stop1d-0{i}", [{"port": "eth0", "rx": -9.0 if i == 1 else -0.5, "sym": 99,
                                                        "carrier": 900, "discards": 5, "temp": 88}],
                             {"extra": noisy}) for i in range(1, 4)])
        res, *_ = self.analyse(["-R", self.root, "-s", "SITE1", "-b", "all"])
        b = res["baselines"]
        for key in ("rx_outliers", "rx_near_low_limit", "errors_since_boot", "flaps", "discards", "hottest_modules",
                    "modules_near_high_limit"):
            self.assertEqual({x["site"] for x in b[key]} - {"SITE1"}, set(), key)
        self.assertEqual(b["pcie"]["below_capability"], [])
        self.assertEqual(res["patterns"]["within_sites"], [])
        self.assertEqual(b["baseline"]["sites"], ["SITE1", "SITE2"])

    def test_baseline_all_skips_broken_and_mismatched_sites(self):
        self.normal_site("SITE1", weak=-8.5)
        bad = write_sweep(self.root, "SITE2", "20261026T100000Z", [], schema=1)       # manifest lists no hosts
        odd = self.site("SITE3", [("acme-s3-stop1d-01", [{"port": "eth0", "rx": -0.5}], {})])
        with open(os.path.join(odd, "sweep.json"), "w") as fh:
            json.dump({"schema_version": 1, "site": "OTHER"}, fh)
        self.assertTrue(os.path.isdir(bad))
        res, sites, missing, args = self.analyse(["-R", self.root, "-s", "SITE1", "-b", "all"])
        excluded = {x["site"]: x["reason"] for x in res["baselines"]["baseline"]["excluded"]}
        self.assertIn("lists no hosts", excluded["SITE2"])
        self.assertIn("is for site 'OTHER'", excluded["SITE3"])
        self.assertEqual(len(res["baselines"]["rx_outliers"]), 1)
        md = nr.render_md(res, sites, missing, args, nr.datetime.datetime.now().astimezone())
        self.assertIn("SITE2 left out of the baseline", md)

    def test_uptime_zero_gives_no_rate(self):
        self.site("SITE1", [("acme-s1-stop1d-01", [{"port": "eth0", "rx": -0.5, "sym": 50}], {"uptime": 0})])
        res, *_ = self.analyse(["-R", self.root])
        self.assertIsNone(res["baselines"]["errors_since_boot"][0]["per_hour"])

    def test_patterns_without_roles(self):
        pcie = [rec("WARN", "asic", "0000:04:00", "generic.pcie.link", "2.5 GT/s x4")]
        self.site("SITE1", [(f"acme-s1-stoc2-0{i}", [{"port": "eth0", "rx": -0.5}], {"extra": pcie}) for i in range(1, 3)])
        args = nr.parse_args(["-R", self.root])                       # no -r
        sites, missing = nr.load_selection(args)
        res = nr.analyse(sites, missing, args)
        self.assertFalse(res["patterns"]["roles_known"])
        self.assertEqual([(w["role"], w["target"], len(w["hosts"])) for w in res["patterns"]["within_sites"]],
                         [(nr.NO_ROLE, "0000:04:00", 2)])
        md = nr.render_md(res, sites, missing, args, nr.datetime.datetime.now().astimezone())
        self.assertIn("Hosts have no role (use -r/--role-regex)", md)

    def test_related_checks_form_one_issue_family(self):
        ev = [rec("CRIT", "port", "eth0", "mlx5.phy.errors", "x"), rec("WARN", "port", "eth0", "mlx5.frame.errors", "x"),
              rec("WARN", "port", "eth0", "mlx5.deep.ber", "x")]
        self.site("SITE1", [(f"acme-s1-stop1d-0{i}", [{"port": "eth0", "rx": -0.5}], {"extra": ev}) for i in range(1, 3)])
        res, *_ = self.analyse(["-R", self.root])
        self.assertEqual([w["issue"] for w in res["patterns"]["within_sites"]], ["link errors (symbol/CRC/BER)"])

    def test_pre_2_12_link_needs_a_fec_mode(self):
        doc = ports_doc("acme-s1-stop1d-01", [{"port": "eth0", "rx": -0.5}, {"port": "eth1", "rx": -25.0, "comp": None}])
        doc["results"] = [r for r in doc["results"] if r["check_id"] != "generic.link.state"]
        d = write_sweep(self.root, "SITE1", "20261026T100000Z", [("acme-s1-stop1d-01", "ok", "OK", doc)])
        facts = {p["port"]: p["linked"] for p in nr.port_facts([nr.finalize(nr.load_sweep_dir(d), None)])}
        self.assertEqual(facts, {"eth0": True, "eth1": False})     # stray light without a FEC mode is not a link

    def test_weak_port_is_an_outlier(self):
        self.normal_site(weak=-8.5)
        res, *_ = self.analyse(["-R", self.root])
        out = res["baselines"]["rx_outliers"]
        self.assertEqual([(o["host"], o["port"]) for o in out], [("acme-site1-stop1d-01", "eth0")])
        self.assertLess(out[0]["delta_db"], -7.5)
        self.assertLess(out[0]["robust_z"], -3.5)
        self.assertEqual(res["baselines"]["rx_by_module_type"]["100GBASE-SR4 or 25GBASE-SR"]["ports"], 16)

    def test_margin_must_also_hold(self):
        self.normal_site(weak=-4.0)                       # far by robust score, but under the 5 dB margin
        res, *_ = self.analyse(["-R", self.root])
        self.assertEqual(res["baselines"]["rx_outliers"], [])
        res, *_ = self.analyse(["-R", self.root, "-d", "3"])
        self.assertEqual(len(res["baselines"]["rx_outliers"]), 1)

    def test_tight_group_uses_margin_only(self):
        hosts = [(f"acme-s1-ctrl2d-0{i}", [{"port": "eth0", "rx": -0.5}], {}) for i in range(1, 5)]
        hosts.append(("acme-s1-ctrl2d-05", [{"port": "eth0", "rx": -6.0}], {}))
        self.site("SITE1", hosts)
        res, *_ = self.analyse(["-R", self.root])
        self.assertEqual([(o["host"], o["robust_z"]) for o in res["baselines"]["rx_outliers"]], [("acme-s1-ctrl2d-05", None)])

    def test_dark_unlinked_and_small_groups_excluded(self):
        hosts = [(f"acme-s1-stop1d-0{i}", [{"port": "eth0", "rx": -0.5},
                                            {"port": "eth1", "rx": -40, "link": False, "judged": False},
                                            {"port": "eth2", "rx": -9.0, "link": False}], {}) for i in range(1, 4)]
        hosts.append(("acme-s1-stop1d-04", [{"port": "eth0", "rx": -9.0, "comp": "OTHER-TYPE", "part": "P2"},
                                             {"port": "eth1", "rx": -0.4}], {}))
        self.site("SITE1", hosts)
        res, *_ = self.analyse(["-R", self.root])
        b = res["baselines"]
        self.assertEqual(b["rx_outliers"], [])                              # dark/unlinked ignored; OTHER-TYPE has 1 port
        self.assertNotIn("OTHER-TYPE", b["rx_by_module_type"])
        self.assertEqual(b["rx_by_module_type"]["100GBASE-SR4 or 25GBASE-SR"]["ports"], 4)

    def test_pre_2_12_link_from_judged_power(self):
        doc = ports_doc("acme-s1-stop1d-01", [{"port": f"eth{j}", "rx": -0.5} for j in range(3)])
        doc["results"] = [r for r in doc["results"] if r["check_id"] != "generic.link.state"]
        d = write_sweep(self.root, "SITE1", "20261026T100000Z", [("acme-s1-stop1d-01", "ok", "OK", doc)])
        facts = nr.port_facts([nr.finalize(nr.load_sweep_dir(d), None)])
        self.assertTrue(all(p["linked"] for p in facts))

    def test_lists_errors_flaps_discards_temperature_pcie(self):
        pcie = [rec("WARN", "asic", "0000:04:00", "generic.pcie.link", "2.5 GT/s x4", threshold="16.0 GT/s x4 (slot)")]
        hosts = [("acme-s1-stoc2-01", [{"port": "eth0", "rx": -0.5, "sym": 7200, "carrier": 500, "discards": 99,
                                        "temp": 85, "temp_high": 90}], {"uptime": 7200, "extra": pcie}),
                 ("acme-s1-stoc2-02", [{"port": "eth0", "rx": -0.5, "carrier": 50}], {"extra": pcie}),
                 ("acme-s1-stoc2-03", [{"port": "eth0", "rx": -0.5}], {})]
        self.site("SITE1", hosts)
        res, *_ = self.analyse(["-R", self.root])
        b = res["baselines"]
        self.assertEqual([(e["host"], e["total"], e["per_hour"]) for e in b["errors_since_boot"]], [("acme-s1-stoc2-01", 7200, 3600.0)])
        self.assertEqual([f["carrier_changes"] for f in b["flaps"]], [500])
        res2, *_ = self.analyse(["-R", self.root, "-f", "10"])
        self.assertEqual([f["carrier_changes"] for f in res2["baselines"]["flaps"]], [500, 50])
        self.assertEqual(b["discards"][0]["total"], 99)
        self.assertEqual([t["temp_c"] for t in b["modules_near_high_limit"]], [85.0])
        self.assertEqual(len(b["pcie"]["below_capability"]), 2)
        within = res["patterns"]["within_sites"]
        self.assertIn(("stoc2", "generic.pcie.link", "0000:04:00", 2, 3),
                      [(w["role"], w["issue"], w["target"], len(w["hosts"]), w["role_hosts"]) for w in within])

    def test_cross_site_pattern_and_single_site_has_none(self):
        self.normal_site("SITE1", weak=-8.5)
        self.normal_site("SITE2", weak=-8.0)
        res, *_ = self.analyse(["-R", self.root])
        across = res["patterns"]["across_sites"]
        self.assertEqual([(a["role"], a["issue"], a["sites"]) for a in across], [("stop1d", nr.OUTLIER_KIND, ["SITE1", "SITE2"])])
        res, *_ = self.analyse(["-R", self.root, "-s", "SITE1"])
        self.assertEqual(res["patterns"]["across_sites"], [])

    def test_baseline_all_uses_every_site_of_the_tree(self):
        # SITE1 alone reads low everywhere (no outlier by its own median); against SITE2's fleet it is
        self.site("SITE1", [(f"acme-s1-stop1d-0{i}", [{"port": "eth0", "rx": -6.5}], {}) for i in range(1, 4)])
        self.normal_site("SITE2")
        res, *_ = self.analyse(["-R", self.root, "-s", "SITE1"])
        self.assertEqual(res["baselines"]["rx_outliers"], [])
        self.assertEqual(res["baselines"]["baseline"]["sites"], ["SITE1"])
        res, *_ = self.analyse(["-R", self.root, "-s", "SITE1", "-b", "all"])
        self.assertEqual(res["baselines"]["baseline"]["sites"], ["SITE1", "SITE2"])
        self.assertEqual({o["site"] for o in res["baselines"]["rx_outliers"]}, {"SITE1"})   # reports on SITE1 only
        self.assertEqual(len(res["baselines"]["rx_outliers"]), 3)

    def test_baseline_all_needs_sweep_root(self):
        p = subprocess.run([sys.executable, SCRIPT, "-b", "all", "-i", "X", "/nonexistent"], capture_output=True, text=True)
        self.assertEqual(p.returncode, 3)

    def test_whole_dbm_note(self):
        self.site("SITE1", [(f"acme-s1-stop1d-0{i}", [{"port": "eth0", "rx": -2}], {}) for i in range(1, 4)])
        res, sites, missing, args = self.analyse(["-R", self.root])
        self.assertEqual(res["baselines"]["whole_dbm_sites"], ["SITE1"])
        md = nr.render_md(res, sites, missing, args, nr.datetime.datetime.now().astimezone())
        self.assertIn("recorded in whole dBm", md)


class TestPhase4Rendering(Phase4Base):
    def render(self, argv, fmt):
        res, sites, missing, args = self.analyse(argv)
        now = nr.datetime.datetime(2026, 10, 26, 12, 0, tzinfo=nr.datetime.timezone.utc)
        return {"md": nr.render_md, "html": nr.render_html, "json": nr.render_json}[fmt](res, sites, missing, args, now)

    def test_markdown_sections(self):
        self.normal_site("SITE1", weak=-8.5)
        md = self.render(["-R", self.root], "md")
        for heading in ("## 4. Baselines and outliers", "### 4.2 Receive power outliers", "### 4.6 Receive discards",
                        "## 5. Patterns"):
            self.assertIn(heading, md)
        self.assertIn("| acme-site1-stop1d-01 | eth0 | stop1d | 100GBASE-SR4 or 25GBASE-SR | -8.50 |", md)
        self.assertNotIn("Across sites", md)                               # single site: within-site only

    def test_converter_never_stalls(self):
        self.normal_site("SITE1")
        for argv in (["-t", "A\n#b"], ["-c", "x\n----"], ["-t", "#### x"], ["-c", "- item\n| a |"]):
            p = subprocess.run([sys.executable, SCRIPT, "-R", self.root, "-O", "html", *argv],
                               capture_output=True, text=True, timeout=30)
            self.assertEqual(p.returncode, 0, (argv, p.stderr))
            self.assertIn("</html>", p.stdout)
        self.assertIn("<p>#### x</p>", nr.markdown_to_html("#### x"))
        self.assertIn("<p>----</p>", nr.markdown_to_html("----"))

    def test_threshold_options_validated(self):
        self.normal_site("SITE1")
        for argv in (["-d", "0"], ["-d", "-1"], ["-d", "nan"], ["-d", "inf"], ["-f", "0"], ["-f", "x"]):
            p = subprocess.run([sys.executable, SCRIPT, "-R", self.root, *argv], capture_output=True, text=True)
            self.assertEqual(p.returncode, 3, argv)

    def test_classification_in_html_footer(self):
        self.normal_site("SITE1")
        page = self.render(["-R", self.root, "-c", "internal <x>"], "html")
        self.assertIn("internal &lt;x&gt; · Generated by", page.split("<footer>")[1])

    def test_json_has_baselines_and_patterns(self):
        self.normal_site("SITE1", weak=-8.5)
        doc = json.loads(self.render(["-R", self.root, "-d", "4", "-f", "50"], "json"))
        self.assertEqual(len(doc["baselines"]["rx_outliers"]), 1)
        self.assertEqual((doc["selection"]["rx_delta_db"], doc["selection"]["flap_min"], doc["selection"]["baseline"]), (4.0, 50, "scope"))
        self.assertIn("within_sites", doc["patterns"])

    def test_html_is_self_contained_and_escaped(self):
        evil = [rec("CRIT", "port", "eth0", "mlx5.phy.errors", "<script>alert(1)</script>", "a <b>bold</b> & `tick`",
                    "Hint with <img src=x onerror=alert(1)>")]
        self.site("SITE1", [("acme-s1-stop1d-01", [{"port": "eth0", "rx": -0.5}], {"extra": evil})])
        page = self.render(["-R", self.root], "html")
        self.assertTrue(page.startswith("<!doctype html>"))
        self.assertNotIn("<script", page)
        self.assertNotIn("<img", page)
        self.assertNotIn("http://", page)
        self.assertNotIn("https://", page)
        self.assertIn("&lt;script&gt;", page)
        self.assertIn('<meta name="generator" content="nic-report.py', page)
        self.assertIn("prefers-color-scheme:dark", page)
        self.assertIn('<span class="sev sev-CRIT">CRIT</span>', page)
        self.assertIn("<table>", page)
        self.assertIn('<ul class="meta"><li><strong>Prepared:</strong>', page)     # header lines, not a bullet list
        self.assertIn("Generated by nic-report v", page.split("<footer>")[1])

    def test_html_cli(self):
        self.normal_site("SITE1", weak=-8.5)
        out = os.path.join(self.tmp.name, "r.html")
        p = subprocess.run([sys.executable, SCRIPT, "-R", self.root, "-O", "html", "-o", out], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        with open(out, encoding="utf-8") as fh:
            self.assertIn("<title>NIC Health: SITE1</title>", fh.read())


class Phase5Base(Phase4Base):
    """Shared helpers for the Phase 5 tests (no tests of its own)."""

    NOW = nr.datetime.datetime(2026, 10, 26, 12, 0, tzinfo=nr.datetime.timezone.utc)
    NO_ENV_THEME = {nr.THEME_ENV: ""}

    def analyse(self, argv):
        args = nr.parse_args(argv + ["-r", ROLE_RE])
        args.suppress_rules = nr.load_suppress(args.suppress) if args.suppress else None
        sites, missing = nr.load_selection(args)
        if args.suppress_rules:
            nr.apply_suppress(sites, args.suppress_rules)
        return nr.analyse(sites, missing, args, nr.load_baseline_sites(args, sites)), sites, missing, args

    def write_json(self, name, doc):
        path = os.path.join(self.tmp.name, name)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(doc if isinstance(doc, str) else json.dumps(doc))
        return path

    def cli(self, *argv, env=None):
        p = subprocess.run([sys.executable, SCRIPT, *argv], capture_output=True, text=True,
                           env={**os.environ, **(env or {})})
        return p.returncode, p.stdout, p.stderr

    def report(self, argv, fmt="md"):
        args = nr.parse_args(argv + ["-r", ROLE_RE, "-O", fmt] + (["-o", os.path.join(self.tmp.name, "x.pdf")] if fmt == "pdf" else []))
        with contextlib.redirect_stderr(io.StringIO()):
            outputs = nr.build_outputs(args, self.NOW)
        return outputs[0][1], args

    def pcie_site(self, site="SITE1"):
        """Three storage hosts: a PCIe WARN on two (a pattern) and a BER WARN on one."""
        pcie = [rec("WARN", "asic", "0000:04:00", "generic.pcie.link", "2.5 GT/s x4", threshold="16.0 GT/s x4 (slot)")]
        ber = [rec("WARN", "port", "eth0", "mlx5.deep.ber", "effective 3E-9", EV_BER, "Clean the optic")]
        hosts = [("acme-s1-stoc2-01", [{"port": "eth0", "rx": -0.5}], {"extra": pcie + ber}),
                 ("acme-s1-stoc2-02", [{"port": "eth0", "rx": -0.5}], {"extra": pcie}),
                 ("acme-s1-stoc2-03", [{"port": "eth0", "rx": -0.5}], {})]
        return write_sweep(self.root, site, "20261026T100000Z",
                           [(h, "ok", "WARN" if kw else "OK", ports_doc(h, ps, **kw)) for h, ps, kw in hosts])

    def theme_dir(self, doc=None, files=None):
        """A copy of the example theme with theme.json fields replaced (None removes) and files added."""
        d = tempfile.mkdtemp(dir=self.tmp.name)
        for name in os.listdir(EXAMPLE_THEME):
            shutil.copy(os.path.join(EXAMPLE_THEME, name), d)
        with open(os.path.join(EXAMPLE_THEME, "theme.json"), encoding="utf-8") as fh:
            base = json.load(fh)
        base.update(doc or {})
        with open(os.path.join(d, "theme.json"), "w", encoding="utf-8") as fh:
            json.dump({k: v for k, v in base.items() if v is not None}, fh)
        for name, data in (files or {}).items():
            with open(os.path.join(d, name), "wb") as fh:
                fh.write(data if isinstance(data, bytes) else data.encode())
        return d


class TestSuppress(Phase5Base):
    RULES = {"schema_version": 1, "suppress": [
        {"check_id": "mlx5.deep.ber", "match": "BER=3E-9", "reason": "Known nic-health BER issue (fictional)"},
        {"check_id": "generic.pcie.link", "hosts": "stoc2-0[12]$", "sites": ["SITE1"], "reason": "BIOS fix scheduled"},
        {"check_id": "generic.link.lookback", "reason": "Matches nothing here"}]}

    def test_schema_validation(self):
        bad = {"not a suppress object": [1],
               "unknown key(s) extra": {"schema_version": 1, "suppress": [], "extra": 1},
               "unsupported schema_version 2": {"schema_version": 2, "suppress": []},
               "unsupported schema_version True": {"schema_version": True, "suppress": []},
               "must be a list": {"schema_version": 1, "suppress": {}},
               "rule 1: not an object": {"schema_version": 1, "suppress": ["x"]},
               "rule 1: unknown key(s) checkid": {"schema_version": 1, "suppress": [{"checkid": "x", "reason": "r"}]},
               "rule 1: missing 'reason'": {"schema_version": 1, "suppress": [{"check_id": "x"}]},
               "'check_id' must be a non-empty string": {"schema_version": 1, "suppress": [{"check_id": 5, "reason": "r"}]},
               "invalid 'match' regex": {"schema_version": 1, "suppress": [{"check_id": "x", "reason": "r", "match": "("}]},
               "invalid 'hosts' regex": {"schema_version": 1, "suppress": [{"check_id": "x", "reason": "r", "hosts": "[a"}]},
               "'sites' must be": {"schema_version": 1, "suppress": [{"check_id": "x", "reason": "r", "sites": ["a/b"]}]},
               "rule 2": {"schema_version": 1, "suppress": [{"check_id": "x", "reason": "r"}, {"check_id": "x", "reason": ""}]},
               "larger than 1024 KiB": " " * (nr.SUPPRESS_MAX + 1),
               "recursion": "[" * 100000}
        for n, (msg, doc) in enumerate(bad.items()):
            path = self.write_json(f"s{n}.json", doc)
            with self.assertRaises(nr.InputError, msg=msg) as cm:
                nr.load_suppress(path)
            self.assertIn(msg, str(cm.exception))
        self.pcie_site()
        rc, _, err = self.cli("-R", self.root, "-S", self.write_json("broken.json", "{"))
        self.assertEqual(rc, 1, err)
        self.assertNotIn("Traceback", err)

    def test_effect_on_findings_verdicts_pcie_and_patterns(self):
        self.pcie_site()
        res, *_ = self.analyse(["-R", self.root])
        self.assertEqual(len(res["findings"]), 3)
        self.assertEqual(len(res["patterns"]["within_sites"]), 1)
        self.assertIsNone(res["suppressed"])
        res, *_ = self.analyse(["-R", self.root, "-S", self.write_json("s.json", self.RULES)])
        self.assertEqual(res["findings"], [])
        self.assertEqual(res["patterns"]["within_sites"], [])
        self.assertEqual(res["baselines"]["pcie"]["below_capability"], [])
        v = res["verdicts"][0]
        self.assertEqual(v["by_verdict"], {"OK": 3, "WARN": 0, "CRIT": 0, "UNKNOWN": 0})
        self.assertEqual(v["findings"], {"CRIT": 0, "WARN": 0, "UNKNOWN": 0})
        detail = {h["host"]: h for h in v["hosts_detail"]}
        self.assertEqual((detail["acme-s1-stoc2-01"]["verdict"], detail["acme-s1-stoc2-01"]["verdict_before"]), ("OK", "WARN"))
        self.assertNotIn("verdict_before", detail["acme-s1-stoc2-03"])
        sp = res["suppressed"]
        self.assertEqual([r["count"] for r in sp["rules"]], [1, 2, 0])
        self.assertEqual(len(sp["results"]), 3)                            # nothing silently dropped
        self.assertTrue(any("Known issues suppressed" in c and "3 result(s) by 2 of 3 rule(s)" in c
                            for c in res["coverage"]["caveats"]))

    def test_first_matching_rule_wins(self):
        self.pcie_site()
        rules = {"schema_version": 1, "suppress": [
            {"check_id": "generic.pcie.link", "reason": "first"},
            {"check_id": "generic.pcie.link", "hosts": "stoc2", "reason": "second, also matching"}]}
        res, *_ = self.analyse(["-R", self.root, "-S", self.write_json("s.json", rules)])
        self.assertEqual([r["count"] for r in res["suppressed"]["rules"]], [2, 0])
        self.assertEqual({r["rule"] for r in res["suppressed"]["results"]}, {1})

    def test_verdict_recomputed_to_unknown(self):
        extra = [rec("CRIT", "port", "eth0", "mlx5.phy.errors", "x", EV_PHY), rec("UNKNOWN", "asic", "0000:01:00", "generic.aer", "?")]
        d = write_sweep(self.root, "SITE1", "20261026T100000Z",
                        [("acme-s1-stop1d-01", "ok", "CRIT", ports_doc("acme-s1-stop1d-01", [{"port": "eth0", "rx": -0.5}], extra=extra))])
        self.assertTrue(os.path.isdir(d))
        rules = {"schema_version": 1, "suppress": [{"check_id": "mlx5.phy.errors", "reason": "r"}]}
        res, *_ = self.analyse(["-R", self.root, "-S", self.write_json("s.json", rules)])
        h = res["verdicts"][0]["hosts_detail"][0]
        self.assertEqual((h["verdict"], h["verdict_before"]), ("UNKNOWN", "CRIT"))

    def test_imported_hosts(self):
        rules = {"schema_version": 1, "suppress": [{"check_id": "mlx5.nic.discards", "hosts": "stoc2-01$", "reason": "r"}]}
        args = nr.parse_args(["-i", "SITE3", self.legacy_dir(), "-S", self.write_json("s.json", rules)])
        args.suppress_rules = nr.load_suppress(args.suppress)
        sites, missing = nr.load_selection(args)
        nr.apply_suppress(sites, args.suppress_rules)
        res = nr.analyse(sites, missing, args)
        self.assertEqual(res["findings"], [])
        h = {x["host"]: x for x in res["verdicts"][0]["hosts_detail"]}["acme-s3-stoc2-01"]
        self.assertEqual((h["verdict"], h["verdict_before"]), ("OK", "WARN"))

    def legacy_dir(self):
        d = os.path.join(self.tmp.name, "legacy")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "acme-s3-stoc2-01_20261023T141935Z_nic-health.csv"), "w") as fh:
            fh.write("severity,scope,target,check_id,value,unit,threshold,evidence,hint,ref\n"
                     '"OK","port","eno1","generic.link.state","up","","","","",""\n'
                     '"WARN","port","eno1","mlx5.nic.discards","rx_discards_phy=+7","","","rx_discards_phy=12818188 (+7)","",""\n')
        return d

    def test_patterns_from_suppressed_measurements_are_dropped(self):
        hosts = []
        for i in range(1, 4):
            doc = ports_doc(f"acme-s1-stop1d-0{i}", [{"port": "eth0", "rx": -0.5, "carrier": 500}])
            for r in doc["results"]:
                if r["check_id"] == "generic.link.flaps":
                    r["severity"] = "WARN"
            hosts.append((f"acme-s1-stop1d-0{i}", "ok", "WARN", doc))
        write_sweep(self.root, "SITE1", "20261026T100000Z", hosts)
        res, *_ = self.analyse(["-R", self.root])
        self.assertIn("link instability", [w["issue"] for w in res["patterns"]["within_sites"]])
        rules = {"schema_version": 1, "suppress": [{"check_id": "generic.link.flaps", "reason": "known counter issue"}]}
        res, *_ = self.analyse(["-R", self.root, "-S", self.write_json("s.json", rules)])
        self.assertEqual(res["patterns"]["within_sites"], [])
        self.assertEqual(len(res["baselines"]["flaps"]), 3)                 # measurements stay

    def test_outlier_pattern_dropped_with_suppressed_module_check(self):
        self.normal_site("SITE1", weak=-8.5)
        self.normal_site("SITE2", weak=-8.0)
        for site in ("site1", "site2"):                                    # nic-health flagged the weak module
            d = os.path.join(self.root, site.upper(), "20261026T100000Z", "nodes", f"acme-{site}-stop1d-01.json")
            with open(d) as fh:
                doc = json.load(fh)
            next(r for r in doc["results"] if r["check_id"] == "mlx5.deep.module" and r["target"] == "eth0")["severity"] = "WARN"
            with open(d, "w") as fh:
                json.dump(doc, fh)
        res, *_ = self.analyse(["-R", self.root])
        self.assertIn(nr.OUTLIER_KIND, [a["issue"] for a in res["patterns"]["across_sites"]])
        rules = {"schema_version": 1, "suppress": [{"check_id": "mlx5.deep.module", "reason": "r"}]}
        res, *_ = self.analyse(["-R", self.root, "-S", self.write_json("s.json", rules)])
        self.assertNotIn(nr.OUTLIER_KIND, [a["issue"] for a in res["patterns"]["across_sites"]])
        self.assertEqual(len(res["baselines"]["rx_outliers"]), 2)

    def test_filters_hosts_sites_and_match(self):
        self.pcie_site()
        rules = {"schema_version": 1, "suppress": [
            {"check_id": "generic.pcie.link", "hosts": "stoc2-02$", "reason": "one host"},
            {"check_id": "generic.pcie.link", "sites": ["SITE9"], "reason": "other site"},
            {"check_id": "mlx5.deep.ber", "match": "^eth9$", "reason": "other port"}]}
        res, *_ = self.analyse(["-R", self.root, "-S", self.write_json("s.json", rules)])
        self.assertEqual([(r["host"], r["check_id"]) for r in res["suppressed"]["results"]],
                         [("acme-s1-stoc2-02", "generic.pcie.link")])
        self.assertEqual(len(res["findings"]), 2)
        rules["suppress"] = [{"check_id": "mlx5.deep.ber", "match": "^eth0$", "reason": "target"}]
        res, *_ = self.analyse(["-R", self.root, "-S", self.write_json("t.json", rules)])
        self.assertEqual(len(res["suppressed"]["results"]), 1)              # regex found in the target

    def test_match_searches_bounded_evidence(self):
        long_ev = "x" * nr.EVIDENCE_MATCH_MAX + " MARKER"
        d = write_sweep(self.root, "SITE1", "20261026T100000Z", [("acme-s1-stop1d-01", "ok", "WARN", ports_doc(
            "acme-s1-stop1d-01", [{"port": "eth0", "rx": -0.5}], extra=[rec("WARN", "port", "eth0", "x.check", "v", long_ev),
                                                                        rec("WARN", "port", "eth1", "x.check", "v", "MARKER")]))])
        self.assertTrue(os.path.isdir(d))
        rules = {"schema_version": 1, "suppress": [{"check_id": "x.check", "match": "MARKER", "reason": "r"}]}
        res, *_ = self.analyse(["-R", self.root, "-S", self.write_json("s.json", rules)])
        self.assertEqual([r["target"] for r in res["suppressed"]["results"]], ["eth1"])

    def test_warnings_for_unused_rules_and_unselected_sites(self):
        self.pcie_site()
        rc, _, err = self.cli("-R", self.root, "-S", self.write_json("s.json", self.RULES))
        self.assertEqual(rc, 0, err)
        self.assertIn("suppress rule 3 (generic.link.lookback) matched nothing", err)
        rules = {"schema_version": 1, "suppress": [{"check_id": "generic.pcie.link", "sites": ["SITE1", "SITE7"], "reason": "r"}]}
        rc, _, err = self.cli("-R", self.root, "-S", self.write_json("t.json", rules))
        self.assertIn("suppress rule 1: site SITE7 is not in the selection", err)
        self.assertNotIn("matched nothing", err)

    def test_section_in_every_format(self):
        self.pcie_site()
        path = self.write_json("s.json", self.RULES)
        md, _ = self.report(["-R", self.root, "-S", path])
        self.assertIn("## 6. Suppressed known issues", md)
        self.assertIn("| #1 | `mlx5.deep.ber` | `BER=3E-9` |", md)
        self.assertIn("| acme-s1-stoc2-01 | eth0 | mlx5.deep.ber | **WARN** | **OK** (was WARN) | #1 |", md)
        self.assertIn("| acme-s1-stoc2-01 | stoc2 | ok | **OK** (was WARN) |", md)
        self.assertIn("patterns built from a suppressed check are dropped", md)
        page, _ = self.report(["-R", self.root, "-S", path], "html")
        self.assertIn("Suppressed known issues</h2>", page)
        self.assertIn('<td><span class="sev sev-OK">OK</span> (was WARN)</td>', page)
        doc = json.loads(self.report(["-R", self.root, "-S", path], "json")[0])
        self.assertEqual(doc["suppressed"]["rules"][0]["reason"], "Known nic-health BER issue (fictional)")
        self.assertEqual(doc["suppressed"]["results"][0]["host_verdict_before"], "WARN")
        self.assertEqual(doc["selection"]["suppress"], path)
        md, _ = self.report(["-R", self.root])
        self.assertNotIn("Suppressed known issues", md)


class TestUntrustedText(Phase5Base):
    def test_no_fake_badges(self):
        fake = [rec("WARN", "port", "**CRIT**", "x.check", "**CRIT** value", "evidence **CRIT** here", "hint **OK**"),
                rec("WARN", "asic", "0000:04:00", "generic.pcie.link", "**CRIT**", threshold="CRIT")]
        self.site("SITE1", [("acme-s1-stop1d-01", [{"port": "eth0", "rx": -0.5}], {"extra": fake})])
        page, _ = self.report(["-R", self.root], "html")
        self.assertNotIn('class="sev sev-CRIT"', page)
        self.assertIn("∗∗CRIT∗∗ value", page)
        self.assertIn("<td>CRIT</td>", page)                                # bare text in a cell stays text
        self.assertIn('<span class="sev sev-WARN">WARN</span>', page)       # report-built badges still work
        self.assertEqual(nr.md_cell("a*b"), "a∗b")
        self.assertEqual(nr.md_cell(nr._badge("OK")), "**OK**")

    def test_control_and_bidi_characters_removed(self):
        self.assertEqual(nr.md_inline("a‮b\x1b[31mc⁦d\x85e\tf\ng"), "ab[31mcde f g")
        self.assertEqual(nr.md_cell("x‮y"), "xy")
        evil = [rec("WARN", "port", "eth‮0", "x.check", "v\x07", "ev⁧il\x00", "")]
        self.site("SITE1", [("acme-s1-stop1d-01", [{"port": "eth0", "rx": -0.5}], {"extra": evil})])
        md, _ = self.report(["-R", self.root])
        self.assertIsNone(nr.CONTROL_RE.search(md))
        self.assertIn("`eth0`", md)

    def test_no_links_from_host_text(self):
        self.assertEqual(nr.md_inline("see [here](http://evil.example) and ![i](x) or [a][b]"),
                         "see [here］(http://evil.example) and ![i］(x) or [a］[b]")
        self.assertEqual(nr.md_cell("[x](y)"), "[x］(y)")
        self.assertEqual(nr.md_inline("Rx Power Current [dBm]=-0.1 [-11.3..3.4]"), "Rx Power Current [dBm]=-0.1 [-11.3..3.4]")
        self.assertEqual(nr.md_inline("a\u200eb\u200fc\u061cd\u2028e\u2029f\ufeffg\u2060h"), "abcde fgh".replace(" ", ""))
        evil = [rec("WARN", "port", "eth0", "x.check", "[x](http://evil.example)", "go [here](javascript:alert(1))", "")]
        self.site("SITE1", [("acme-s1-stop1d-01", [{"port": "eth0", "rx": -0.5}], {"extra": evil})])
        md, _ = self.report(["-R", self.root])
        page, _ = self.report(["-R", self.root], "html")
        self.assertNotRegex(md, r"\]\(")
        self.assertNotIn("<a ", page)

    def test_rate_display(self):
        self.assertEqual([nr._rate(v) for v in (None, 0.00412, 3.14159, 99.94, 100.0, 412000.0)],
                         [None, "0.00412", "3.14", "99.9", "100", "412,000"])


class TestPerSite(Phase5Base):
    def test_files_and_outliers_agree_with_combined(self):
        self.normal_site("SITE1", weak=-8.5)
        self.normal_site("SITE2", weak=-6.0)
        out = os.path.join(self.tmp.name, "rep.json")
        rc, stdout, err = self.cli("-R", self.root, "-r", ROLE_RE, "-O", "json", "-o", out, "-P")
        self.assertEqual((rc, stdout), (0, ""), err)
        with open(out) as fh:
            combined = json.load(fh)
        for site in ("SITE1", "SITE2"):
            with open(os.path.join(self.tmp.name, f"rep-{site}.json")) as fh:
                one = json.load(fh)
            self.assertFalse(one["multi_site"])
            self.assertEqual([s["site"] for s in one["selection"]["sites"]], [site])
            self.assertEqual(one["baselines"]["baseline"]["sites"], ["SITE1", "SITE2"])       # same population
            self.assertEqual(one["baselines"]["rx_outliers"],
                             [o for o in combined["baselines"]["rx_outliers"] if o["site"] == site])
            self.assertEqual(one["baselines"]["rx_by_module_type"], combined["baselines"]["rx_by_module_type"])
        self.assertEqual(len(combined["baselines"]["rx_outliers"]), 2)
        md = os.path.join(self.tmp.name, "rep.md")
        rc, _, err = self.cli("-R", self.root, "-o", md, "--per-site", "-t", "Q4")
        self.assertEqual(rc, 0, err)
        with open(os.path.join(self.tmp.name, "rep-SITE2.md"), encoding="utf-8") as fh:
            text = fh.read()
        self.assertTrue(text.startswith("# 🩺 Q4 · SITE2\n"))
        self.assertIn("Baseline: the sites of the combined report (SITE1, SITE2;", text)

    def test_with_baseline_all(self):
        self.site("SITE1", [(f"acme-s1-stop1d-0{i}", [{"port": "eth0", "rx": -6.5}], {}) for i in range(1, 4)])
        self.normal_site("SITE2")
        self.normal_site("SITE3", weak=-8.5)
        out = os.path.join(self.tmp.name, "b.json")
        rc, _, err = self.cli("-R", self.root, "-s", "SITE1", "-s", "SITE3", "-b", "all", "-O", "json", "-o", out, "-P")
        self.assertEqual(rc, 0, err)
        with open(out) as fh:
            combined = json.load(fh)
        for site in ("SITE1", "SITE3"):
            with open(os.path.join(self.tmp.name, f"b-{site}.json")) as fh:
                one = json.load(fh)
            self.assertEqual(one["baselines"]["baseline"]["sites"], ["SITE1", "SITE2", "SITE3"])
            self.assertEqual(one["baselines"]["rx_outliers"],
                             [o for o in combined["baselines"]["rx_outliers"] if o["site"] == site])
        self.assertFalse(os.path.exists(os.path.join(self.tmp.name, "b-SITE2.json")))     # baseline only
        self.assertEqual(len(combined["baselines"]["rx_outliers"]), 4)

    def test_single_site_writes_no_duplicate(self):
        self.normal_site("SITE1")
        out = os.path.join(self.tmp.name, "one.md")
        rc, _, err = self.cli("-R", self.root, "-o", out, "-P")
        self.assertEqual(rc, 0, err)
        self.assertIn("one site selected", err)
        self.assertEqual(sorted(os.listdir(self.tmp.name)), ["one.md", "sweeps"])

    def test_needs_output_and_names_are_safe(self):
        self.normal_site("SITE1")
        rc, _, err = self.cli("-R", self.root, "-P")
        self.assertEqual(rc, 3, err)
        self.assertEqual(nr.per_site_path("/x/r.d/rep.html", "S-1"), "/x/r.d/rep-S-1.html")
        self.assertEqual(nr.per_site_path("rep", "S1"), "rep-S1")
        with self.assertRaises(nr.InputError):
            nr.per_site_path("rep.md", "../x")


class TestOutputFiles(Phase5Base):
    def test_mode_and_symlink_replaced_not_followed(self):
        self.normal_site("SITE1")
        victim = os.path.join(self.tmp.name, "victim.txt")
        with open(victim, "w") as fh:
            fh.write("keep me")
        out = os.path.join(self.tmp.name, "r.md")
        os.symlink(victim, out)
        old = os.umask(0o002)
        try:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(nr.main(["-R", self.root, "-o", out]), 0)
        finally:
            os.umask(old)
        self.assertFalse(os.path.islink(out))
        with open(victim) as fh:
            self.assertEqual(fh.read(), "keep me")
        self.assertEqual(os.stat(out).st_mode & 0o777, 0o640)
        self.assertEqual([f for f in os.listdir(self.tmp.name) if f.endswith(".tmp")], [])

    def test_unwritable_target_leaves_nothing(self):
        self.normal_site("SITE1")
        self.normal_site("SITE2")
        out = os.path.join(self.tmp.name, "missing-dir", "r.md")
        rc, _, err = self.cli("-R", self.root, "-o", out, "-P")
        self.assertEqual(rc, 1, err)
        self.assertIn("does not exist or is not writable", err)
        ro = os.path.join(self.tmp.name, "ro")
        os.mkdir(ro, 0o500)
        self.addCleanup(os.chmod, ro, 0o700)
        if os.access(ro, os.W_OK):
            self.skipTest("running with privileges that ignore directory permissions")
        rc, _, err = self.cli("-R", self.root, "-o", os.path.join(ro, "r.md"), "-P")
        self.assertEqual(rc, 1, err)
        self.assertEqual(os.listdir(ro), [])

    def test_failed_write_removes_temp_files(self):
        out = os.path.join(self.tmp.name, "a.md")
        os.mkdir(os.path.join(self.tmp.name, "b.md"))
        with self.assertRaises(nr.InputError):
            nr.write_outputs([(out, "x"), (os.path.join(self.tmp.name, "b.md"), "y")])
        self.assertEqual(sorted(os.listdir(self.tmp.name)), ["b.md"])


class TestThemes(Phase5Base):
    def test_example_theme_loads_and_brands_html(self):
        theme = nr.load_theme(EXAMPLE_THEME)
        self.assertEqual((theme["name"], theme["warnings"], theme["notices"]), ("example", [], []))
        self.assertTrue(theme["logos"]["header"].startswith("data:image/png;base64,"))
        self.assertTrue(theme["logos"]["cover"].startswith("data:image/svg+xml;base64,"))
        self.normal_site("SITE1")
        page, _ = self.report(["-R", self.root, "-T", EXAMPLE_THEME], "html")
        self.assertIn('<img class="cover-logo" alt="Example Corp" src="data:image/png;base64,', page)
        self.assertIn("thead th{background:#DDE3EA;color:#0B1F44}", page)
        self.assertIn('"Example Sans",' + nr.FONT_FALLBACK, page)
        self.assertIn("Example Corp internal · Generated by", page.split("<footer>")[1])     # theme classification
        self.assertNotIn("http://", page.replace('xmlns="http://www.w3.org/2000/svg"', ""))
        self.assertNotIn("<script", page)
        page, _ = self.report(["-R", self.root, "-T", EXAMPLE_THEME, "-c", "CLI label"], "html")
        self.assertIn("CLI label · Generated by", page.split("<footer>")[1])                 # -c wins
        md, args = self.report(["-R", self.root, "-T", EXAMPLE_THEME])
        self.assertNotIn("Example Corp", md)                                                   # md ignores themes
        self.assertIsNone(args.theme_data)
        doc = json.loads(self.report(["-R", self.root, "-T", EXAMPLE_THEME], "json")[0])
        self.assertNotIn("theme", doc)
        self.assertIsNone(doc["classification"])

    def test_environment_and_empty_theme_option(self):
        self.normal_site("SITE1")
        rc, out, err = self.cli("-R", self.root, "-O", "json", env={nr.THEME_ENV: "/etc/hostname"})
        self.assertEqual(rc, 0, err)                                         # json never reads the theme
        rc, out, err = self.cli("-R", self.root, "-O", "html", env={nr.THEME_ENV: EXAMPLE_THEME})
        self.assertEqual(rc, 0, err)
        self.assertIn('class="cover-logo"', out)
        rc, out, err = self.cli("-R", self.root, "-O", "html", "-T", "", env={nr.THEME_ENV: EXAMPLE_THEME})
        self.assertEqual(rc, 0, err)
        self.assertNotIn('class="cover-logo"', out)                          # -T '' overrides the environment

    def test_invalid_themes(self):
        colors = nr.load_theme(EXAMPLE_THEME)["colors"]
        cases = {"colors.primary must be #RRGGBB": ({"colors": {**colors, "primary": "blue"}}, {}),
                 "unknown key(s) source": ({"source": "x"}, {}),
                 "missing name": ({"name": None}, {}),
                 "'name' must be letters": ({"name": "my theme"}, {}),
                 "'name' must be letters, digits": ({"name": "ex‮ample"}, {}),
                 "unsupported schema_version": ({"schema_version": 2}, {}),
                 "not a plain file name": ({"logos": {"cover": "../logo-light.png"}}, {}),
                 "not a plain file name in": ({"logos": {"cover": "/etc/hostname"}}, {}),
                 "not a PNG, JPEG or SVG": ({"logos": {"cover": "fake.png"}}, {"fake.png": b"GIF89a....."}),
                 "is larger than 512 KiB": ({"logos": {"cover": "big.png"}},
                                            {"big.png": b"\x89PNG\r\n\x1a\n" + b"0" * nr.LOGO_MAX_BYTES}),
                 "names an emoji font": ({"fonts": {"body": ["Noto Color Emoji"]}}, {}),
                 "fonts.body must be a list": ({"fonts": {"body": ['A";}body{x']}}, {}),
                 "'org' must be a non-empty string": ({"org": "‮\x07"}, {}),
                 "unknown key(s) in 'labels'": ({"labels": {"footer": "x"}}, {})}
        for msg, (doc, files) in cases.items():
            with self.assertRaises(nr.InputError, msg=msg) as cm:
                nr.load_theme(self.theme_dir(doc, files))
            self.assertIn(msg, str(cm.exception))
        d = self.theme_dir()
        with open(os.path.join(d, "theme.json"), "w") as fh:
            fh.write("[" * 50000)
        with self.assertRaisesRegex(nr.InputError, "recursion"):
            nr.load_theme(d)

    def test_text_fields_cleaned(self):
        theme = nr.load_theme(self.theme_dir({"org": "Ex‮ample\x07 Corp", "labels": {"classification": "In⁦ternal\n"}}))
        self.assertEqual((theme["org"], theme["labels"]["classification"]), ("Example Corp", "Internal"))

    def test_extra_css_is_ignored_with_a_notice(self):
        self.normal_site("SITE1")
        d = self.theme_dir(files={"extra.css": ".sev-CRIT{color:#00ff00}"})
        self.assertEqual(nr.load_theme(d)["notices"], ["theme 'example': extra.css is not supported and is ignored"])
        rc, out, err = self.cli("-R", self.root, "-O", "html", "-T", d)
        self.assertEqual(rc, 0, err)
        self.assertIn("extra.css is not supported and is ignored", err)
        self.assertNotIn("#00ff00", out)

    def test_symlink_escaping_the_theme_folder(self):
        outside = os.path.join(self.tmp.name, "outside.png")
        shutil.copy(os.path.join(EXAMPLE_THEME, "logo-light.png"), outside)
        d = self.theme_dir({"logos": {"cover": "link.png"}})
        os.symlink(outside, os.path.join(d, "link.png"))
        with self.assertRaisesRegex(nr.InputError, "points outside the theme folder"):
            nr.load_theme(d)

    def test_contrast_warning_and_strict_failure(self):
        self.assertAlmostEqual(nr.contrast_ratio("#000000", "#ffffff"), 21.0)
        self.normal_site("SITE1")
        low = os.path.join(THEMES, "low-contrast")
        rc, out, err = self.cli("-R", self.root, "-O", "html", "-T", low)
        self.assertEqual(rc, 0, err)
        self.assertIn("⚠️  theme 'low-contrast': primary on white contrast is", err)
        self.assertIn("</html>", out)
        rc, _, err = self.cli("-R", self.root, "-O", "html", "-T", low, "-X")
        self.assertEqual(rc, 1, err)
        self.assertIn("(--strict-theme)", err)
        self.assertNotIn("Traceback", err)
        rc, _, err = self.cli("-R", self.root, "-O", "html", "-T", EXAMPLE_THEME, "--strict-theme")
        self.assertEqual((rc, err), (0, ""))
        rc, _, err = self.cli("-R", self.root, "-O", "html", "-X", env=self.NO_ENV_THEME)
        self.assertEqual(rc, 3, err)                                          # -X without a theme
        rc, _, err = self.cli("-R", self.root, "-O", "json", "-T", low, "-X")
        self.assertEqual(rc, 3, err)                                          # -X with a format that ignores themes
        rc, _, err = self.cli("-R", self.root, "-O", "html", "-T", os.path.join(self.tmp.name, "none"))
        self.assertEqual(rc, 1, err)

    def test_fixed_colours_for_severity_attribution_and_classification(self):
        for (lt, dk) in nr.SEV_COLORS.values():                              # the lock repeats HTML_CSS's colours
            for colour in lt + dk:
                self.assertIn(colour, nr.HTML_CSS)
        theme = nr.load_theme(os.path.join(THEMES, "low-contrast"))
        for paged in (False, True):
            css = nr.theme_css(theme, paged)
            for var in ("--crit", "--warn", "--ok", "--na", "--muted", "--bg", "--fg"):
                self.assertNotIn(var + ":", css)
            for sel in (".attrib", "footer", ".run-class", ".cover-class", ".meta"):
                self.assertNotIn(sel + "{", css.replace(nr.LOCKED_CSS, ""))
            self.assertIn(nr.LOCKED_CSS, css)
        self.assertIn(".cover .attrib,.cover-class{background:#0b1220;color:#f3f5f8", nr.PRINT_CSS)
        self.assertEqual(nr.theme_css(None, False), "")


class TestAttribution(Phase5Base):
    def test_every_text_format(self):
        self.normal_site("SITE1")
        line = nr.attribution(self.NOW)
        md, _ = self.report(["-R", self.root])
        self.assertEqual(md.rstrip().splitlines()[-1], line)
        doc = json.loads(self.report(["-R", self.root], "json")[0])
        self.assertEqual((doc["generator"]["tool"], doc["generator"]["version"]), (nr.SCRIPT_NAME, nr.SCRIPT_VERSION))
        page, _ = self.report(["-R", self.root, "-T", EXAMPLE_THEME], "html")
        title_block = page.split('<header class="cover">')[1].split("</header>")[0]
        self.assertIn(f'<p class="attrib">{line}</p>', title_block)
        self.assertIn(line, page.split("<footer>")[1])
        self.assertIn(f'<meta name="generator" content="{nr.SCRIPT_NAME} {nr.SCRIPT_VERSION}">', page)


FILE_SVG = ('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="96" height="24">'
            '<rect width="20" height="20" fill="#fff"/><image href="file://{0}" xlink:href="file://{0}" width="96" height="24"/></svg>')


class TestWriteSpecialTargets(unittest.TestCase):
    """An existing target that is not a regular file is written to, never replaced."""

    def test_fifo_target_is_written_not_replaced(self):
        with tempfile.TemporaryDirectory() as d:
            fifo = os.path.join(d, "p")
            os.mkfifo(fifo)
            got = {}

            def reader():
                with open(fifo, "rb") as fh:
                    got["data"] = fh.read()
            th = threading.Thread(target=reader, daemon=True)     # never hangs the suite if nothing writes
            th.start()
            nr.write_outputs([(fifo, "report\n")])
            th.join(10)
            self.assertEqual(got.get("data"), b"report\n")
            self.assertTrue(stat.S_ISFIFO(os.stat(fifo).st_mode))
            self.assertEqual([f for f in os.listdir(d) if f.endswith(".tmp")], [])

    def test_dev_null_target(self):
        nr.write_outputs([(os.devnull, "report\n")])
        self.assertTrue(stat.S_ISCHR(os.stat(os.devnull).st_mode))


class TestPDF(Phase5Base):
    def test_pdf_needs_output_file(self):
        self.normal_site("SITE1")
        rc, out, err = self.cli("-R", self.root, "-O", "pdf")
        self.assertEqual((rc, out), (3, ""))
        self.assertIn("give -o FILE", err)

    def test_missing_weasyprint_is_a_clear_input_error(self):
        self.normal_site("SITE1")
        saved = sys.modules.get("weasyprint", "absent")
        sys.modules["weasyprint"] = None                                    # import weasyprint now fails
        try:
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                rc = nr.main(["-R", self.root, "-O", "pdf", "-o", os.path.join(self.tmp.name, "r.pdf")])
        finally:
            if saved == "absent":
                del sys.modules["weasyprint"]
            else:
                sys.modules["weasyprint"] = saved
        self.assertEqual(rc, 1)
        self.assertIn("python3-weasyprint", err.getvalue())
        self.assertFalse(os.path.exists(os.path.join(self.tmp.name, "r.pdf")))

    def test_rendering_failure_is_an_input_error(self):
        self.normal_site("SITE1")
        failing = nr.argparse.Namespace(default_url_fetcher=None,
                                        HTML=lambda **kw: nr.argparse.Namespace(write_pdf=lambda: 1 / 0))
        args = nr.parse_args(["-R", self.root, "-O", "pdf", "-o", "x.pdf"])
        sites, missing = nr.load_selection(args)
        res = nr.analyse(sites, missing, args)
        saved = nr._weasyprint
        nr._weasyprint = lambda: failing
        try:
            with self.assertRaisesRegex(nr.InputError, "PDF rendering failed: ZeroDivisionError"):
                nr.render_pdf(res, sites, missing, args, self.NOW)
        finally:
            nr._weasyprint = saved

    def test_fetcher_without_url_fetcher_class(self):
        fake = nr.argparse.Namespace(default_url_fetcher=lambda url: ("fetched", url))
        fetch = nr.local_fetcher(fake)
        self.assertEqual(fetch("data:,x"), ("fetched", "data:,x"))
        with self.assertRaises(ValueError):
            fetch("https://example.invalid/logo.png")

    def test_paged_html_structure(self):
        for site in ("SITE1", "SITE2", "SITE3", "SITE4", "SITE5"):
            self.normal_site(site, weak=-8.5)
        args = nr.parse_args(["-R", self.root, "-r", ROLE_RE, "-c", "confidential <site> data", "-T", EXAMPLE_THEME])
        args.theme_data = nr.load_theme(EXAMPLE_THEME)
        sites, missing = nr.load_selection(args)
        page = nr.render_html(nr.analyse(sites, missing, args), sites, missing, args, self.NOW, paged=True)
        self.assertIn('<nav class="toc"><h2>Contents</h2><ol><li><a href="#sec-1">1. Coverage and comparability</a>', page)
        self.assertIn('<div class="run-class">confidential &lt;site&gt; data</div>', page)
        self.assertIn('<p class="cover-class">confidential &lt;site&gt; data</p>', page)
        self.assertIn('<div class="run-title">NIC Health · Example Corp</div>', page)
        self.assertIn('<div class="run-logo"><img alt="Example Corp" src="data:image/png;base64,', page)
        self.assertIn('<img class="cover-logo" alt="Example Corp" src="data:image/svg+xml;base64,', page)
        wide = page.split('<section class="wide">')[1].split("</section>")[0]
        self.assertTrue(wide.startswith('<h2 id="sec-5">5. Patterns</h2>'))           # the table's lead moves with it
        self.assertIn("<strong>Across sites:</strong>", wide)
        self.assertIn("target-counter(attr(href), page)", page)
        self.assertNotIn("Noto Color Emoji", page)
        self.assertNotIn('class="wide"', nr.render_html(nr.analyse(sites, missing, args), sites, missing, args, self.NOW))

    @unittest.skipUnless(HAVE_WEASYPRINT, "WeasyPrint not installed")
    def test_landscape_page_for_wide_table(self):
        for site in ("SITE1", "SITE2", "SITE3", "SITE4", "SITE5"):
            self.normal_site(site, weak=-8.5)
        args = nr.parse_args(["-R", self.root, "-r", ROLE_RE])
        sites, missing = nr.load_selection(args)
        doc = weasyprint.HTML(string=nr.render_html(nr.analyse(sites, missing, args), sites, missing, args, self.NOW,
                                                    paged=True)).render()
        self.assertEqual(doc.metadata.generator, f"{nr.SCRIPT_NAME} {nr.SCRIPT_VERSION}")
        sizes = [(round(pg.width), round(pg.height)) for pg in doc.pages]
        self.assertLess(sizes[0][0], sizes[0][1])                           # A4 portrait cover...
        self.assertIn((sizes[0][1], sizes[0][0]), sizes)                    # ...and a landscape page for a wide table

    @unittest.skipUnless(HAVE_WEASYPRINT, "WeasyPrint not installed")
    def test_cli_pdf_metadata_contents_and_every_page(self):
        if not (shutil.which("pdfinfo") and shutil.which("pdftotext")):
            self.skipTest("pdfinfo/pdftotext (poppler-utils) not installed: PDF text checks need them")
        for site in ("SITE1", "SITE2", "SITE3", "SITE4", "SITE5"):
            self.normal_site(site, weak=-8.5)
        out = os.path.join(self.tmp.name, "r.pdf")
        rc, stdout, err = self.cli("-R", self.root, "-r", ROLE_RE, "-O", "pdf", "-o", out, "-c", "confidential site data",
                                   "-T", EXAMPLE_THEME, "-P")
        self.assertEqual((rc, stdout, err), (0, "", ""))
        self.assertTrue(os.path.isfile(os.path.join(self.tmp.name, "r-SITE3.pdf")))
        info = subprocess.run(["pdfinfo", out], capture_output=True, text=True).stdout
        self.assertRegex(info, rf"Creator:\s+{nr.SCRIPT_NAME} {nr.SCRIPT_VERSION}")
        self.assertRegex(info, r"Author:\s+Example Corp")
        pages = subprocess.run(["pdftotext", "-layout", out, "-"], capture_output=True, text=True).stdout.split("\f")[:-1]
        self.assertIn("Generated by nic-report v" + nr.SCRIPT_VERSION, pages[0])               # cover
        self.assertIn("confidential site data", pages[0])
        self.assertIn("Generated by nic-report v" + nr.SCRIPT_VERSION, pages[-1])              # closing footer
        toc = re.findall(r"^\s*(\d+\. [A-Za-z ]+?) \.{3,}\s*(\d+)\s*$", pages[1], re.M)
        self.assertEqual([t for t, _ in toc], ["1. Coverage and comparability", "2. Verdicts", "3. Findings",
                                               "4. Baselines and outliers", "5. Patterns"])
        for title, number in toc:                                            # heading and running header on its page
            self.assertGreaterEqual(pages[int(number) - 1].count(title), 2, (title, number))
        for n, pg in enumerate(pages[1:], 2):                               # every page after the cover
            self.assertIn("confidential site data", pg, n)
            self.assertIn(f"Page {n} of {len(pages)}", pg)
            self.assertIn("NIC Health · Example Corp", pg)

    @unittest.skipUnless(HAVE_WEASYPRINT, "WeasyPrint not installed")
    def test_fetcher_blocks_files_referenced_by_svg_logos(self):
        self.normal_site("SITE1")

        def images(*theme):
            out = os.path.join(self.tmp.name, f"i{len(os.listdir(self.tmp.name))}.pdf")
            rc, _, err = self.cli("-R", self.root, "-O", "pdf", "-o", out, *theme, env=self.NO_ENV_THEME)
            self.assertEqual(rc, 0, err)
            with open(out, "rb") as fh:
                return fh.read().count(b"/Subtype /Image")
        base = images()                                                      # emoji glyph bitmaps, if any
        self.assertGreater(images("-T", EXAMPLE_THEME), base)                # control: the PNG header logo
        png = os.path.join(EXAMPLE_THEME, "logo-light.png")
        d = self.theme_dir({"logos": {"cover": "file.svg", "header": "file.svg"}}, {"file.svg": FILE_SVG.format(png)})
        self.assertEqual(images("-T", d), base)                              # file:// inside the SVG not loaded


# --------------------------------------------------------------------------------- Phase 6: typed metrics (P2/P3)

def typed_port_rows(port, impact=None, **p):
    """port_rows with the typed metrics nic-health (JSON schema 2) writes next to that evidence."""
    rows = port_rows(port, **p)
    rx, tx, part = p.get("rx"), p.get("tx", -1.0), p.get("part", "VENDOR PART25")
    for r in rows:
        cid = r["check_id"]
        if cid == "generic.link.state":
            r["metrics"] = {"carrier": p.get("link", True), "operstate": "up", **(impact or {})}
        elif cid == "generic.link.flaps":
            r["metrics"] = {"carrier_changes": {"total": p.get("carrier", 1), "delta": 0}}
        elif cid == "mlx5.deep.module":
            lanes = list(rx) if isinstance(rx, (list, tuple)) else None
            m = {"temperature_c": p.get("temp", 40), "temperature_c_low": -5, "temperature_c_high": p.get("temp_high", 90),
                 "rx_dbm": min(lanes) if lanes else rx, "rx_dbm_low": p.get("low", -11.3), "rx_dbm_high": 3.398,
                 "rx_dbm_judged": p.get("judged", True), "tx_dbm": tx, "tx_dbm_low": -9.4, "tx_dbm_high": 3.398, "tx_fault": [0],
                 "vendor": part.split(" ", 1)[0], "part_number": part.split(" ", 1)[-1]}
            if lanes:
                m["rx_dbm_lanes"] = lanes
            r["metrics"] = m
        elif cid == "mlx5.deep.fec":
            r["metrics"] = {"fec": "Firecode FEC", "compliance": p.get("comp", "100GBASE-SR4 or 25GBASE-SR"), "fec_mismatch": False}
        elif cid == "mlx5.phy.errors":
            r["metrics"] = {n: {"total": p.get("sym") or 0 if n == "rx_symbol_err_phy" else 0, "delta": 0}
                            for n in ("rx_symbol_err_phy", "rx_pcs_symbol_err_phy", "rx_corrected_bits_phy", "rx_err_lane_0_phy")}
        elif cid == "mlx5.nic.discards":
            r["metrics"] = {"rx_discards_phy": {"total": p["discards"], "delta": 1}, "tx_discards_phy": {"total": 0, "delta": 0}}
    return rows


def strip_metrics(doc, keep=()):
    """A copy of a nic-health document without 'metrics', except on the check_ids in keep."""
    doc = json.loads(json.dumps(doc))
    for r in doc["results"]:
        if r["check_id"] not in keep:
            r.pop("metrics", None)
    return doc


BOND_MEMBER = {"in_use": True, "in_use_reasons": ["bond"], "bond": "bond0", "bond_link_failures": 3,
               "rx_bytes": {"total": 9000, "delta": 500}, "tx_bytes": {"total": 10, "delta": 0}}


class TestTypedMetrics(unittest.TestCase):
    """metrics_for prefers nic-health's typed metrics, value by value, and falls back to the evidence."""

    def test_typed_values_are_preferred(self):
        typed = {"rx_dbm": -9.5, "rx_dbm_low": -12.0, "rx_dbm_high": 3.0, "rx_dbm_judged": True,
                 "vendor": "ACME", "part_number": "X1"}
        m = nr.metrics_for("mlx5.deep.module", "", EV_MODULE_25G, typed)
        self.assertEqual(m["rx"], {"dbm": -9.5, "lanes": None, "low": -12.0, "high": 3.0, "judged": True})
        self.assertEqual(m["part"], "ACME X1")
        self.assertEqual(m["tx"], nr.extract_tx_dbm(EV_MODULE_25G))                  # not typed: from the evidence
        lanes = nr.metrics_for("mlx5.deep.module", "", "", {"rx_dbm": -2, "rx_dbm_lanes": [-1, -2.5, 0], "rx_dbm_low": -14,
                                                             "rx_dbm_high": 3, "rx_dbm_judged": False})["rx"]
        self.assertEqual(lanes, {"dbm": -2.5, "lanes": [-1.0, -2.5, 0.0], "low": -14.0, "high": 3.0, "judged": False})
        self.assertEqual(nr.metrics_for("mlx5.deep.ber", "", EV_BER, {"effective_ber": 15e-255, "raw_ber": 2e-8})["ber"],
                         {"effective": 0.0, "raw": 2e-8, "since_min": None})
        self.assertEqual(nr.metrics_for("generic.pcie.aer", "", "", {"cor": {"total": 5, "delta": 1}})["aer"],
                         {"cor": 5, "nonfatal": 0, "fatal": 0})
        self.assertEqual(nr.metrics_for("mlx5.deep.fec", "link: X", "FEC=X; module Compliance=Y", {"fec": "RS-FEC"}),
                         {"fec": "RS-FEC", "compliance": "Y"})

    def test_counters_follow_the_evidence_rules(self):
        zeros = {"rx_discards_phy": {"total": 0, "delta": 0}, "tx_discards_phy": {"total": 0, "delta": 0}}
        self.assertEqual(nr.metrics_for("mlx5.nic.discards", "", "", zeros)["discards"], {"total": 0, "delta": 0})
        # a zero next to a counter that is not: not listed in the evidence, so not a value either
        tx_only = dict(zeros, tx_discards_phy={"total": 5570, "delta": 1})
        self.assertNotIn("discards", nr.metrics_for("mlx5.nic.discards", "", "tx_discards_phy=5570 (+1)", tx_only))
        # rx_bits_phy (the BER denominator) never counts against "all counters are 0"
        phy = {"rx_symbol_err_phy": {"total": 0}, "rx_bits_phy": {"total": 10 ** 15}}
        self.assertEqual(nr.metrics_for("mlx5.phy.errors", "", "", phy)["symbol_errors"], {"total": 0, "delta": 0})
        absolute = {"rx_symbol_err_phy": {"total": 58}}
        self.assertEqual(nr.metrics_for("mlx5.phy.errors", "", "", absolute)["symbol_errors"], {"total": 58, "delta": None})
        self.assertEqual(nr.metrics_for("generic.link.flaps", "", "", {"carrier_changes": {"total": 215788, "delta": 6}}),
                         {"carrier_changes": 215788})

    def test_bad_types_fall_back_to_the_evidence(self):
        ev_rx = nr.extract_rx_dbm(EV_MODULE_25G)
        for typed in ({"rx_dbm": "-9.5", "rx_dbm_low": -12, "rx_dbm_high": 3},          # string, not a number
                      {"rx_dbm": True, "rx_dbm_low": -12, "rx_dbm_high": 3},            # bool is not a number
                      {"rx_dbm": -9.5, "rx_dbm_high": 3},                               # range incomplete
                      {"rx_dbm": -9.5, "rx_dbm_low": -12, "rx_dbm_high": 3, "rx_dbm_judged": "yes"},
                      {"rx_dbm": -9.5, "rx_dbm_low": -12, "rx_dbm_high": 3, "rx_dbm_lanes": [-1, "x"]},
                      {"rx_dbm": -9.5, "rx_dbm_low": -12, "rx_dbm_high": 3, "rx_dbm_lanes": []},
                      {"rx_dbm": 10 ** 400, "rx_dbm_low": -12, "rx_dbm_high": 3},       # float() would overflow
                      {"rx_dbm": float("inf"), "rx_dbm_low": -12, "rx_dbm_high": 3}):
            self.assertEqual(nr.metrics_for("mlx5.deep.module", "", EV_MODULE_25G, typed)["rx"], ev_rx, typed)
        ev_sym = nr.extract_symbol_errors(EV_PHY)
        for typed in ({"rx_symbol_err_phy": {"total": -1}}, {"rx_symbol_err_phy": {"total": True}},
                      {"rx_symbol_err_phy": {"total": 10 ** 20}}, {"rx_symbol_err_phy": {"total": 5, "delta": "1"}},
                      {"rx_symbol_err_phy": 943}, {"rx_symbol_err_phy": {"total": 0}, "rx_pcs_symbol_err_phy": {"total": "x"}}):
            self.assertEqual(nr.metrics_for("mlx5.phy.errors", "", EV_PHY, typed)["symbol_errors"], ev_sym, typed)
        for typed in (None, [], "metrics", 7, {"effective_ber": "3E-9"}, {"effective_ber": None}):
            self.assertEqual(nr.metrics_for("mlx5.deep.ber", "", EV_BER, typed)["ber"], nr.extract_ber(EV_BER), typed)
        self.assertEqual(nr.metrics_for("generic.pcie.aer", "", "totals since boot: cor=1 nonfatal=0 fatal=0",
                                        {"cor": {"total": "1"}})["aer"], {"cor": 1, "nonfatal": 0, "fatal": 0})
        self.assertEqual(nr.metrics_for("mlx5.deep.fec", "link: X", "", {"fec": 5})["fec"], "X")

    def test_service_impact_facts_are_validated(self):
        m = nr.metrics_for("generic.link.state", "up", "operstate=up", dict(BOND_MEMBER, carrier=True))
        self.assertEqual(m, BOND_MEMBER)
        odd = {"in_use": "yes", "in_use_reasons": ["bond", 1], "bond": "", "bond_link_failures": -3, "rx_bytes": 1.5,
               "tx_bytes": {"total": True}, "in_use_reasons_complete": "no"}
        self.assertEqual(nr.metrics_for("generic.link.state", "up", "", odd), {})
        self.assertEqual(nr.metrics_for("generic.link.state", "up", "operstate=up; in use: master=bond0"), {})
        # Hostile host text: reasons only from the known tokens, bond only an interface name
        for reasons in (["bond", "[click](http://x)"], ["bond", "Bond"], [""], "bond"):
            self.assertNotIn("in_use_reasons", nr.metrics_for("generic.link.state", "", "", {"in_use_reasons": reasons}), reasons)
        self.assertEqual(nr.metrics_for("generic.link.state", "", "", {"in_use_reasons": ["bond", "upper", "bond"]}),
                         {"in_use_reasons": ["bond", "upper"]})
        for bond in ("bond 0", "a" * 16, "../x", "b:1", "b\u202ex", "b\x07", "b\nx", "", 7):
            self.assertNotIn("bond", nr.metrics_for("generic.link.state", "", "", {"bond": bond}), repr(bond))
        self.assertEqual(nr.metrics_for("generic.link.state", "", "", {"bond": "bond0.100-a_b"}), {"bond": "bond0.100-a_b"})
        self.assertEqual(nr.metrics_for("generic.link.state", "", "", {"in_use_reasons_complete": False}),
                         {"in_use_reasons_complete": False})
        # Traffic only from the window: totals since boot grow with LLDP and ARP alone
        self.assertEqual(nr.impact_facts({"rx_bytes": {"total": 9, "delta": 0}, "tx_bytes": {"total": 9, "delta": 0}}),
                         {"has_traffic": False})
        self.assertEqual(nr.impact_facts({"rx_bytes": {"total": 9, "delta": 0}, "tx_bytes": {"total": 9, "delta": 4}}),
                         {"has_traffic": True})
        self.assertEqual(nr.impact_facts({"rx_bytes": {"total": 10 ** 12}, "tx_bytes": {"total": 10 ** 12}}), {})
        # A reset counter (no delta) leaves its direction unknown: idle only when both directions were seen idle
        self.assertEqual(nr.impact_facts({"rx_bytes": {"total": 9}, "tx_bytes": {"total": 9, "delta": 0}}), {})
        self.assertEqual(nr.impact_facts({"rx_bytes": {"total": 9}, "tx_bytes": {"total": 9, "delta": 5}}),
                         {"has_traffic": True})
        self.assertEqual(nr.impact_facts({}), {})
        self.assertEqual(nr.service_label({"bond": "bond0", "in_use": True, "bond_link_failures": 1200}),
                         "bond0 member, in use, 1,200 bond link failures")
        self.assertEqual(nr.service_label({"in_use": False, "has_traffic": False}), "not in use")

    def test_judged_without_typed_flag_comes_from_the_evidence(self):
        typed = {"rx_dbm": -40, "rx_dbm_low": -11.308, "rx_dbm_high": 3.398}           # no rx_dbm_judged
        self.assertFalse(nr.metrics_for("mlx5.deep.module", "", EV_MODULE_DARK, typed)["rx"]["judged"])
        self.assertTrue(nr.metrics_for("mlx5.deep.module", "", EV_MODULE_25G, typed)["rx"]["judged"])
        self.assertTrue(nr.metrics_for("mlx5.deep.module", "", "", typed)["rx"]["judged"])   # nothing says otherwise

    def test_flap_extractor_reads_a_window_with_flaps(self):
        self.assertEqual(nr.extract_carrier_changes("carrier_changes T0=215782 T1=215788"), 215788)
        self.assertIsNone(nr.extract_carrier_changes("carrier_changes decreased (T0=5 T1=3)"))


NH_FIXTURES = os.path.join(REPO, "tests", "fixtures", "nic-health-json")


def drop_impact(v):
    """Remove the service-impact facts (P3) and the coverage counts of typed hosts from a report result, in place."""
    if isinstance(v, dict):
        v.pop("service", None)
        v.pop("hosts_with_typed_metrics", None)
        v.pop("hosts_with_impact_facts", None)
        if v.get("check_id") == nr.LINK_STATE and isinstance(v.get("metrics"), dict):
            for k in nr.IMPACT_KEYS:
                v["metrics"].pop(k, None)
        for x in v.values():
            drop_impact(x)
    elif isinstance(v, list):
        for x in v:
            drop_impact(x)
    return v


class TestRealNicHealthOutput(unittest.TestCase):
    """nic-health's own JSON (fixtures written by its test suite from mocks; make fixtures regenerates them):
    nic-report reads the same values from typed metrics as from the evidence, for every record."""

    def docs(self):
        names = sorted(f for f in os.listdir(NH_FIXTURES) if f.endswith(".json"))
        self.assertGreaterEqual(len(names), 10)
        for name in names:
            with open(os.path.join(NH_FIXTURES, name), encoding="utf-8") as fh:
                yield name, json.load(fh)

    def test_typed_equals_evidence_for_every_record(self):
        checked = collections.Counter()
        for name, doc in self.docs():
            self.assertEqual(doc["schema_version"], 2, name)
            for r in doc["results"]:
                if "metrics" not in r:
                    continue
                typed = nr.metrics_for(r["check_id"], r["value"], r["evidence"], r["metrics"])
                evidence = nr.metrics_for(r["check_id"], r["value"], r["evidence"])
                for k in nr.IMPACT_KEYS:
                    typed.pop(k, None)
                self.assertEqual(json.dumps(typed, sort_keys=True), json.dumps(evidence, sort_keys=True),
                                 f"{name}: {r['check_id']} {r['target']}")
                checked[r["check_id"]] += 1
        # every check whose evidence nic-report parses is covered
        for cid in ("mlx5.deep.module", "mlx5.phy.errors", "mlx5.frame.errors", "mlx5.nic.discards", "generic.link.flaps",
                    "generic.pcie.aer", "mlx5.deep.ber", "mlx5.deep.fec"):
            self.assertGreater(checked[cid], 0, cid)

    def test_service_impact_from_real_output(self):
        doc = dict(self.docs())["p3-link-state.json"]
        facts = {r["target"]: nr.impact_facts(nr.metrics_for(r["check_id"], r["value"], r["evidence"], r["metrics"]))
                 for r in doc["results"]}
        self.assertEqual(facts["eth0"]["bond"], "bond7")
        self.assertEqual(facts["eth1"]["bond_link_failures"], 3)
        self.assertEqual(facts["eth2"]["in_use"], False)
        self.assertEqual(facts["eth3"]["in_use_reasons"], ["bridge", "upper", "sriov_vfs", "global_address"])

    def test_reports_identical_without_metrics(self):
        for name, doc in self.docs():
            with tempfile.TemporaryDirectory() as tmp:
                res = []
                for i, d in enumerate((doc, strip_metrics(doc))):
                    path = write_sweep(os.path.join(tmp, str(i)), "SITE1", "20261026T120000Z", [("server-01", "ok", d["verdict"], d)])
                    res.append(drop_impact(nr.analyse([nr.finalize(nr.load_sweep_dir(path), None)], [])))
                self.assertEqual(json.dumps(res[0], sort_keys=True), json.dumps(res[1], sort_keys=True), name)


class TestServiceImpactAndFidelity(Phase5Base):
    """P3 facts in the report, and the Phase 6 exit criterion: the report is identical with and without
    typed metrics (P2) on the same sweep; only the coverage line saying so differs."""

    NOW = nr.datetime.datetime(2026, 10, 26, 12, 0, tzinfo=nr.datetime.timezone.utc)

    def typed_doc(self, host, ports, extra=()):
        doc = ports_doc(host, [])
        doc["schema_version"] = 2
        for r in doc["results"]:
            if r["check_id"] == "generic.pcie.link":
                r["metrics"] = {"speed_gts": 16.0, "width": 8, "slot_limited": False, "below_capability": False}
        for p in ports:
            doc["results"] += typed_port_rows(**p)
        doc["results"] += list(extra)              # after the port rows: a record here replaces the port's own
        return doc

    def fixture(self, transform=lambda doc: doc):
        """Two sites, roles, a weak bond-member port with growing errors, flaps, discards and PCIe. Always at the
        same path (the JSON report names it), so outputs of two fixtures compare as they are."""
        root = os.path.join(self.tmp.name, "sweeps")
        shutil.rmtree(root, ignore_errors=True)
        pcie = dict(rec("WARN", "asic", "0000:04:00", "generic.pcie.link", "8.0 GT/s x8", "current_link_speed=8.0 GT/s PCIe",
                        threshold="16.0 GT/s x8"), metrics={"speed_gts": 8.0, "width": 8, "expected_speed_gts": 16.0,
                                                            "slot_limited": False, "below_capability": True})
        aer = dict(rec("WARN", "asic", "0000:01:00", "generic.pcie.aer", "cor=+2 nonfatal=+0 fatal=+0",
                       "totals since boot: cor=7 nonfatal=0 fatal=0"),
                   metrics={"cor": {"total": 7, "delta": 2}, "nonfatal": {"total": 0, "delta": 0}, "fatal": {"total": 0, "delta": 0}})
        crit = [dict(rec("CRIT", "port", "eth0", "mlx5.phy.errors", "rx_symbol_err_phy=+943", EV_PHY, "Clean the optic"),
                     metrics={"rx_symbol_err_phy": {"total": 414877072, "delta": 943},
                              "rx_pcs_symbol_err_phy": {"total": 414877072, "delta": 943},
                              "rx_corrected_bits_phy": {"total": 2379976318, "delta": 9297}}),
                dict(rec("WARN", "port", "eth0", "mlx5.deep.ber", "effective 3E-9", EV_BER, "BER"),
                     metrics={"effective_ber": 3e-9, "raw_ber": 7e-7, "effective_errors": 44030843, "since_clear_min": 9387.7}),
                dict(rec("WARN", "port", "eth1", "generic.link.flaps", "+6", "carrier_changes T0=215782 T1=215788"),
                     metrics={"carrier_changes": {"total": 215788, "delta": 6}}),
                dict(rec("WARN", "port", "eth2", "mlx5.nic.discards", "tx_discards_phy=+1", "tx_discards_phy=5570 (+1)"),
                     metrics={"rx_discards_phy": {"total": 0, "delta": 0}, "tx_discards_phy": {"total": 5570, "delta": 1}})]
        for site, weak in (("SITE1", -8.5), ("SITE2", -8.0)):
            hosts = []
            for i in range(1, 5):
                ports = [{"port": f"eth{j}", "rx": round(-0.4 + 0.05 * ((i + j) % 5), 3),
                          "impact": dict(BOND_MEMBER, bond="bond0" if j < 2 else "bond1")} for j in range(4)]
                extra = [pcie, aer] if i < 3 else []
                if i == 1:
                    ports[0].update(rx=weak, sym=414877072)
                    ports[3].update(impact={"in_use": False, "in_use_reasons": [], "rx_bytes": {"total": 2048, "delta": 0},
                                            "tx_bytes": {"total": 900, "delta": 0}},
                                    discards=12818188)
                    extra = extra + crit
                hosts.append((f"acme-{site.lower()}-stop1d-0{i}", self.typed_doc(f"acme-{site.lower()}-stop1d-0{i}", ports, extra)))
            write_sweep(root, site, "20261026T100000Z", [(h, "ok", "CRIT", transform(doc)) for h, doc in hosts])
        return root

    def outputs(self, root, *argv):
        args = nr.parse_args(["-R", root, "-r", ROLE_RE, *argv])
        sites, missing = nr.load_selection(args)
        res = nr.analyse(sites, missing, args, nr.load_baseline_sites(args, sites))
        return (nr.render_md(res, sites, missing, args, self.NOW), nr.render_json(res, sites, missing, args, self.NOW), res)

    def test_findings_and_lists_carry_service_impact(self):
        md, js, res = self.outputs(self.fixture())
        self.assertIn("- **CRIT** `eth0` `mlx5.phy.errors`: rx_symbol_err_phy=+943 (bond0 member, in use, 3 bond link failures)", md)
        self.assertIn("- **WARN** `eth2` `mlx5.nic.discards`: tx_discards_phy=+1 (bond1 member, in use, 3 bond link failures)", md)
        self.assertIn("`0000:04:00` `generic.pcie.link`: 8.0 GT/s x8\n", md)               # not a port: no facts
        f = next(r for r in res["findings"] if r["check_id"] == "mlx5.phy.errors")
        self.assertEqual(f["service"], {"in_use": True, "in_use_reasons": ["bond"], "bond": "bond0",
                                        "bond_link_failures": 3, "has_traffic": True})
        out = res["baselines"]["rx_outliers"][0]
        self.assertEqual((out["port"], out["service"]["bond"]), ("eth0", "bond0"))
        unused = next(d for d in res["baselines"]["discards"] if d["port"] == "eth3")
        self.assertEqual(unused["service"], {"in_use": False, "in_use_reasons": [], "has_traffic": False})
        self.assertEqual([g["hosts_with_typed_metrics"] for g in res["coverage"]["groups"]], [4, 4])
        self.assertEqual([g["hosts_with_impact_facts"] for g in res["coverage"]["groups"]], [4, 4])
        self.assertIn("| Typed metrics / impact facts | 4 of 4 / 4 | 4 of 4 / 4 |", md)
        self.assertIn('"service": {', js)
        self.assertEqual([f["carrier_changes"] for f in res["baselines"]["flaps"]], [215788, 215788])

    def test_report_identical_without_p2(self):
        """Exit criterion (design §11 Phase 6): typed metrics change nothing but the coverage line."""
        full = self.outputs(self.fixture())
        p2_stripped = self.outputs(self.fixture(lambda d: strip_metrics(d, keep=(nr.LINK_STATE,))))
        for fmt, a, b in (("md", full[0], p2_stripped[0]), ("json", full[1], p2_stripped[1])):
            self.assertEqual(a, b, fmt)                                                 # P3 kept: byte-identical
        for argv in ((), ("-s", "SITE1")):
            md, js, _ = self.outputs(self.fixture(), *argv)
            md0, js0, _ = self.outputs(self.fixture(strip_metrics), *argv)
            # Markdown: the coverage line, and the service-impact note on port findings (P3), nothing else
            a, b = md.splitlines(), md0.splitlines()
            self.assertEqual(len(a), len(b))
            changed = [(x, y) for x, y in zip(a, b) if x != y]
            cov = [(x, y) for x, y in changed if x.startswith("| Typed metrics / impact facts |")]
            self.assertEqual(len(cov), 1, argv)
            self.assertNotIn(" 4 of 4 ", cov[0][1])
            self.assertRegex(cov[0][1], r"^\| Typed metrics / impact facts (\| 0 of 4 / 0 )+\|$")
            notes = [(x, y) for x, y in changed if (x, y) not in cov]
            self.assertTrue(notes)
            labels = {f" ({b} member, in use, 3 bond link failures)" for b in ("bond0", "bond1")} | {" (not in use)"}
            for x, y in notes:
                self.assertIn(x[len(y):], labels, (x, y))
                self.assertTrue(x.startswith(y), (x, y))
            # JSON: the same, plus the facts themselves where ports appear
            a, b = json.loads(js), json.loads(js0)
            for doc, typed in ((a, 4), (b, 0)):
                self.assertEqual({(g["hosts_with_typed_metrics"], g["hosts_with_impact_facts"]) for g in doc["coverage"]["groups"]},
                                 {(typed, typed)})
            self.assertIn('"service"', js)
            self.assertNotIn('"service"', js0)
            self.assertEqual(drop_impact(a), drop_impact(b), argv)

    def test_mixed_hosts_caveat(self):
        def half(doc):
            return strip_metrics(doc) if doc["host"].endswith(("-03", "-04")) else doc
        _, _, res = self.outputs(self.fixture(half))
        self.assertIn("Typed metrics from 4 of 8 collected host(s); the others' values were read from evidence text "
                      "(nic-health without typed metrics, or CSV import).", res["coverage"]["caveats"])
        _, _, res = self.outputs(self.fixture())
        self.assertFalse([c for c in res["coverage"]["caveats"] if c.startswith("Typed metrics")])

    def test_bad_metrics_never_crash_the_report(self):
        def vandalize(doc):
            for n, r in enumerate(doc["results"]):
                r["metrics"] = [None, "x", 7, [], {"in_use": "x", "rx_dbm": "y", "carrier_changes": {"total": -1}}][n % 5]
            return doc
        md, js, _ = self.outputs(self.fixture(vandalize))
        md0, js0, _ = self.outputs(self.fixture(strip_metrics))
        # Every value falls back to the evidence: only the count of hosts with a metrics object differs
        self.assertEqual([x for x in md.splitlines() if "Typed metrics" not in x],
                         [x for x in md0.splitlines() if "Typed metrics" not in x])

    def test_sample_with_and_without_metrics(self):
        with open(os.path.join(REPO, "samples", "nic-health-json-deep.json"), encoding="utf-8") as fh:
            doc = json.load(fh)
        self.assertEqual(doc["schema_version"], 2)
        self.assertTrue(any("metrics" in r for r in doc["results"]))
        res = []
        for d in (doc, strip_metrics(doc)):
            root = os.path.join(self.tmp.name, f"s{len(res)}")
            path = write_sweep(root, "SITE1", "20261020T174609Z", [("server-01", "ok", d["verdict"], d)])
            res.append(nr.analyse([nr.finalize(nr.load_sweep_dir(path), None)], []))
        for r, typed in zip(res, (1, 0)):
            self.assertEqual(r["coverage"]["groups"][0]["hosts_with_typed_metrics"], typed)
        self.assertEqual(json.dumps(drop_impact(res[0]), sort_keys=True), json.dumps(drop_impact(res[1]), sort_keys=True))


if __name__ == "__main__":
    unittest.main()
