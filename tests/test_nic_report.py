#!/usr/bin/env python3
"""Unit tests for nic-report.py (design docs/design/nic-sweep.md §6, Phase 3).

Fixtures are generated in a temporary directory: fictional site/host names, evidence strings in the
exact formats nic-health writes. Run: python3 -m unittest discover -s tests -p 'test_nic_report.py'
"""
import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(REPO, "nic-report.py")
_spec = importlib.util.spec_from_file_location("nic_report", SCRIPT)
nr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(nr)

ROLE_RE = r"^[^-]+-[^-]+-(?P<role>[a-z]+\d+[a-z]*)-\d+"

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
        # captured before generic.link.state existed: ports from link flaps, link counts unknown
        self.assertIsNone(g["ports_with_link"])
        self.assertEqual(g["hosts_without_link_state"], ["server-01"])
        self.assertTrue(any("no link state" in c for c in res["coverage"]["caveats"]))
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


if __name__ == "__main__":
    unittest.main()
