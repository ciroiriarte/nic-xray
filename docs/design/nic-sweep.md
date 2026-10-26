# 🛰️ Design: `nic-sweep.sh` + `nic-report.py` — fleet collection and multi-site analysis

| Field | Value |
|---|---|
| **Status** | 📝 Draft: direction chosen (option b, Python for the report), no code yet |
| **Author** | Ciro Iriarte |
| **Created** | 2026-10-26 |
| **Updated** | 2026-10-26 |
| **Reviewers** | Claude (author of first draft) |

---

## 1. 📌 Decision summary

| Question | Decision |
|---|---|
| Put fleet analysis inside `nic-health.sh`? | ❌ No. `nic-health.sh` stays a single-host verdict tool with Nagios exit codes. Comparing across hosts is a separate job, done off-host after the sweep. |
| How many new tools? | **Two**, each with one job: `nic-sweep.sh` (collection) and `nic-report.py` (analysis and rendering). |
| Language | `nic-sweep.sh`: **Bash**, like the rest of the repo. `nic-report.py`: **Python 3, standard library only**, a documented exception to the "Modern Bash" rule (§3). |
| Canonical per-host artefact | `nic-health -O json`: it already carries `version`, `collected_at`, `level`, `mode`, `interval_s` and `capabilities`. CSV is derived from it, never the source of truth. |
| PDF | Optional: WeasyPrint, if installed (CSS Paged Media). HTML and Markdown need nothing beyond Python. |
| Same repo and version? | ✅ Yes. Same repo, same tag, tandem `SCRIPT_VERSION` (`CLAUDE.md` §6). |
| Runs where? | `nic-sweep.sh` and `nic-report.py` run on an operator or jump host. Monitored nodes only need `nic-health` (and optionally `nic-xray`). |
| Changes to node state | None beyond what `nic-health` already does (read-only). The sweep never installs packages. Shipping a script to `/tmp` is opt-in (§5.3). |

---

## 2. 🎯 Goals and non-goals

### Goals
- **Repeatable fleet sweeps.** One command collects `nic-health` from every host in an inventory, in parallel, into a fixed, versioned directory layout with a manifest of exit codes and failures.
- **Comparable data.** Every sweep records how it was collected (tool version, level, interval, time, host uptime), so later comparisons can state their limits instead of guessing.
- **Analysis beyond single-host verdicts.** Per-site and cross-site summaries, outliers against the fleet's own baseline (an optic far weaker than its peers), recurring patterns across sites, and comparison between two sweeps.
- **Readable output.** Markdown, a self-contained HTML page and a print-quality PDF, plus JSON for automation.

### Non-goals
- Inventory discovery from MAAS, Juju, Ansible or a CMDB. The sweep takes a plain inventory file; adapters can generate it (§5.1).
- Long-term time-series storage or dashboards. Use Prometheus or similar. This tool compares snapshots.
- Remediation. Like `nic-health`, the tools report and suggest; they never change NIC, switch or host configuration.
- Replacing `nic-health` checks. A per-host rule belongs in `nic-health.sh` (§8). `nic-report` only adds what needs more than one host.

---

## 3. ⚖️ Why two tools, and why Python for one

**Why not one tool:** collecting and analysing fail differently and run at different times. A sweep must run unattended over SSH, survive unreachable hosts and record exactly what happened. A report is re-run many times over the same data, often for other audiences. Keeping them separate also lets either side change without breaking the other: the contract between them is the sweep directory (§5.4).

**Why Bash for `nic-sweep.sh`:** it is process orchestration (ssh, timeouts, parallel jobs, files), which Bash does well and the repo already standardises on.

**Why Python for `nic-report.py`:** the report has to:
- parse RFC 4180 CSV with quoted fields that contain commas (legacy imports),
- compute medians, percentiles and robust outlier scores,
- write escaped HTML and feed a paged-media PDF engine.

Doing that in Bash means re-implementing a CSV parser and floating-point statistics on top of `awk` and `jq`. A first prototype was built in Python during a five-site, 121-host comparison in 2026-10, and that is the basis for this design.

**Guard rails on the exception:**
- Python 3.9 or newer, **standard library only** (`csv`, `json`, `statistics`, `html`, `argparse`, `pathlib`). No third-party import except the optional WeasyPrint, which is imported lazily only for `-O pdf`.
- One file, `nic-report.py`, following the same CLI conventions as the Bash scripts (long and short options, `--help`, `--version` printing `nic-report.py <version>`, `SCRIPT_VERSION` near the top).
- The exception covers **this script only**. `CLAUDE.md` §2 gets one line naming it.

### Alternatives considered

| Option | Why not |
|---|---|
| Bash + `jq` for everything | Feasible for text summaries; poor fit for statistics, robust CSV import and HTML/PDF. High maintenance cost for the report half. |
| Report tooling outside this repo | Loses the shared schema: a change to `nic-health` output would silently break an external report. Keeping both in one repo lets CI test them together. |
| Analysis inside `nic-health.sh` | Breaks its single-host contract and monitoring exit codes; it cannot see other hosts. |

---

## 4. 🏗️ Architecture

```
inventory.csv ──▶ nic-sweep.sh ──ssh──▶ host: sudo -n nic-health -O json -l deep -I 30
                      │                       (optional) sudo -n nic-xray --optics --lacp --output json
                      ▼
               sweeps/<site>/<UTC>/      ◀── contract (§5.4)
                      │
legacy CSV ──import──▶│
                      ▼
               nic-report.py ──▶ report.md · report.html · report.pdf · analysis.json
```

- `nic-sweep.sh` writes one directory per (site, sweep).
- `nic-report.py` reads one or more sweep directories (and legacy CSV through `--import`), normalises them into one record model (§6.1), runs the analyses (§6.3) and renders the output (§6.4).

---

## 5. 🛰️ `nic-sweep.sh`

### 5.1 Inventory

Plain CSV, one host per line, `#` comments allowed:

```
# site,host,address[,user]
SITE1,node-ctrl-01,10.0.0.15
SITE1,node-cmp-01,10.0.0.20,ops
```

- `host` is the name used in reports. `address` is what SSH connects to (IP or DNS name).
- Every field is validated against a strict pattern (`[A-Za-z0-9._-]+`; `address` also allows `:` for IPv6) before it reaches any command line. A failing line is reported and skipped; it is never passed to a shell.
- Generating the inventory from MAAS, Juju or Ansible is out of scope; the README gives one-line examples (e.g. `juju machines --format json | jq …`).

### 5.2 CLI sketch

```
nic-sweep.sh -f|--inventory FILE [-s|--site SITE]... [-J|--jump HOST] [-u|--user USER]
             [-p|--parallel N] [-T|--timeout SEC] [-o|--output-dir DIR]
             [-l|--level basic|deep] [-I|--interval SEC] [-x|--with-xray]
             [--ship PATH] [--accept-new-hostkeys] [-n|--no-color] [-v|--version] [-h|--help]
```

| Option | Default | Meaning |
|---|---|---|
| `-f, --inventory` | required | Inventory file (§5.1) |
| `-s, --site` | all | Only sweep these sites (repeatable) |
| `-J, --jump` | none | SSH jump host (`ssh -J`) |
| `-u, --user` | current user | Default SSH user (per-host override in the inventory) |
| `-p, --parallel` | 8 | Hosts swept at once |
| `-T, --timeout` | interval + 120 s | Per-host wall-clock limit |
| `-o, --output-dir` | `./sweeps` | Root of the sweep tree (§5.4) |
| `-l, --level` / `-I, --interval` | `deep` / `30` | Passed to `nic-health`. 30 s, because shorter windows miss bursty link errors (see `nic-health.md` §5) |
| `-x, --with-xray` | off | Also collect `nic-xray --optics --lacp` (LLDP peer, DOM) per host |
| `--ship PATH` | off | Copy a local `nic-health.sh` to the host's `/tmp`, run it, delete it. For hosts without the package. Default: require `nic-health` (or `nic-health.sh`) on the remote `PATH` |
| `--accept-new-hostkeys` | off | `StrictHostKeyChecking=accept-new`. Default leaves SSH's own policy in place |

A missing `--inventory` prints the usage message (`CLAUDE.md` §3).

### 5.3 Execution per host

1. `ssh -o BatchMode=yes -o ConnectTimeout=10 [-J jump] user@address`. Never prompts.
2. Remote command, fixed and quoted (no remote `eval`):
   `sudo -n nic-health -O json -l <level> -I <interval>`; with `--ship`, the shipped path instead, removed on exit.
3. stdout → `nodes/<host>.json`, stderr → `nodes/<host>.err`, exit code and duration → `MANIFEST.tsv`.
4. Classify each host: `ok` (JSON parsed; any verdict), `ssh-fail`, `sudo-fail` (`sudo -n` refused), `tool-missing`, `timeout`, `bad-output` (not valid JSON).
5. A progress bar on stderr when stdout is a terminal (`CLAUDE.md` §3); none with `-n` or when output is redirected.

### 5.4 Output layout (the contract)

```
sweeps/<site>/<YYYYmmddTHHMMSSZ>/
├── sweep.json          # nic-sweep version, args, inventory sha256, start/end, host counts by status
├── MANIFEST.tsv        # host  address  status  exit_code  duration_s
├── merged.csv          # site,hostname,collected_at,version,level,interval_s + nic-health record columns
└── nodes/
    ├── <host>.json     # canonical: nic-health -O json, unmodified
    ├── <host>.err
    └── <host>.xray.json   # only with --with-xray
```

- `nodes/*.json` are kept byte-for-byte as returned. Everything else can be regenerated from them.
- `merged.csv` is a convenience export. It **always carries the collection metadata columns**, which plain `nic-health -O csv` does not, so a merged CSV taken out of context still says how it was collected.
- `sweep.json` has its own `schema_version`. `nic-report.py` refuses a newer major version than it knows.

### 5.5 Exit codes

| Code | Meaning |
|---|---|
| 0 | Every host collected, all verdicts OK or N/A |
| 1 | Every host collected, at least one WARN, no CRIT |
| 2 | At least one CRIT (even if some hosts failed to collect) |
| 3 | No CRIT, but at least one host not collected, or usage error |

CRIT outranks a collection failure so that a real fault is never hidden behind one unreachable host. `MANIFEST.tsv` always lists the failures.

---

## 6. 📊 `nic-report.py`

### 6.1 Normalised record model

Each `nic-health` result becomes one row, enriched with its collection context:

| Field | Source |
|---|---|
| `site`, `host` | inventory / sweep path (import: argument and file name) |
| `role` | derived from `host` with `--role-regex` (e.g. `^[^-]+-[^-]+-(?P<role>[a-z]+\d+[a-z]*)-\d+`); empty if not set |
| `collected_at`, `tool_version`, `level`, `mode`, `interval_s` | `nic-health` JSON envelope; `null` for legacy CSV |
| `uptime_s`, `boot_id` | JSON envelope once P1 lands (§7); else `null` |
| `severity`, `scope`, `target`, `check_id`, `value`, `unit`, `threshold`, `evidence`, `hint`, `ref` | the record |
| `metrics` | structured values (P2, §7); until then parsed from `evidence` by tested extractors (§6.2) |

### 6.2 Inputs and legacy import

- **Sweep directories** (§5.4): the normal input. Any number, from any sites.
- **`--import SITE PATH...`**: CSV collected by hand before `nic-sweep` existed. The importer must cope with what real collections look like:
  - one file per host with no `site`/`hostname` columns (host taken from the file name up to the first `_` or `.`),
  - merged files that already carry `site,hostname`,
  - CRLF line endings and leading blank lines (terminal captures),
  - mixed `nic-health` versions in one site.
  Imported rows get `null` collection metadata, and the report lists them under coverage caveats.
- **Evidence extractors** (interim, until P2): one small, unit-tested function per value (Rx/Tx power, module temperature, error totals since boot, carrier changes, discards, AER totals, effective/raw BER, FEC mode, module compliance). Each has fixtures taken from real `nic-health` output. A value that does not parse is `null`, never `0`.

### 6.3 Analyses

| # | Analysis | Notes |
|---|---|---|
| A1 | **Coverage and comparability** | Hosts, roles, ASICs, ports, ports with link, deep checks evaluated, FEC mix. Lists mixed tool versions, intervals and dates, and every host not collected. |
| A2 | **Verdict summary** | Per site and per role: CRIT/WARN/UNKNOWN counts, hosts clean (% of hosts). |
| A3 | **Findings** | All WARN/CRIT/UNKNOWN, grouped by site → host → target, with evidence and hint. |
| A4 | **Fleet baselines and outliers** | Per metric over **ports with link only** (dark spares read about −40 dBm and would skew everything): min, p5, median, max. Outliers by robust score (median/MAD) **and** an absolute floor, e.g. Rx ≥ 5 dB below the median for the same module compliance. Also: highest error totals since boot (with rate per hour of uptime once P1 lands), carrier changes ≥ N, discards, PCIe below capability vs slot-limited. |
| A5 | **Cross-site patterns** | Group findings and outliers by (role, check, port position such as bond member / breakout lane) across sites. Prototype example: the same low-Rx bond leg on the same storage role at two sites. |
| A6 | **Sweep comparison** | Two sweeps of one site: new, resolved and persisting findings; counter growth between sweeps, reset when `boot_id` changed (P1). |
| A7 | **Known tool issues** | Optional `--suppress FILE` (JSON list of `check_id` + match), reported in its own section so nothing is silently dropped. |

Thresholds are options with defaults (`--rx-delta-db 5`, `--flap-min 100`, …) or a JSON config file. TOML is skipped because `tomllib` needs Python 3.11.

### 6.4 Output

| `-O` | Content |
|---|---|
| `md` (default) | Report as Markdown: what an operator reads in a terminal or commits next to the data |
| `html` | One self-contained file: inline CSS, no external fonts, scripts or images (reports contain host and switch names). Light and dark theme, readable on a phone, severity badges |
| `pdf` | WeasyPrint over the same HTML plus a print stylesheet: cover page, contents with page numbers (`target-counter`), running header with the section (`string-set`), "Page N of M" footer, a page break before each section, **landscape named pages only for wide tables**. Fonts: name real installed families first and **do not name the emoji font explicitly**. Fontconfig then picks it for digits, which happened in the prototype; emoji still render through fallback |
| `json` | The computed analyses (A1–A7) for automation and tests |

- `--title`, `--classification` (footer label, e.g. "confidential site data") and `--output FILE`.
- Without WeasyPrint, `-O pdf` exits with a clear message naming the package.
- `--per-site` writes one report per site in addition to the combined one.

### 6.5 CLI sketch

```
nic-report.py [-O md|html|pdf|json] [-o|--output FILE] [--import SITE PATH...]...
              [--role-regex RE] [--rx-delta-db DB] [--flap-min N] [--config FILE]
              [--suppress FILE] [--per-site] [--compare OLD NEW]
              [--title TEXT] [--classification TEXT] [-v|--version] [-h|--help]
              [SWEEP_DIR...]
```

With no sweep directory and no `--import`, it prints the usage message.

Exit codes: `0` report written, `1` input error (unreadable or unknown schema), `3` usage error.

---

## 7. 🔧 Prerequisites in `nic-health.sh`

| ID | Change | Why | Compatibility |
|---|---|---|---|
| **P1** | Add `uptime_s` and `boot_id` (`/proc/sys/kernel/random/boot_id`) to the JSON envelope | Error rates per hour of uptime; detect counter resets between two sweeps (A6) | Additive; `schema_version` stays 1 |
| **P2** | Add an optional per-record `metrics` object with typed values, e.g. `{"rx_dbm": -8.83, "tx_dbm": -0.85, "compliance": "25GBASE-SR"}` or `{"rx_symbol_err_phy": {"total": 412180970, "delta": 5101}}` | `evidence` is human text. Parsing it with regular expressions works, but breaks quietly when wording changes | Additive in JSON (`schema_version` 2 announces it). CSV unchanged |

`nic-report.py` works without both, with lower fidelity, and says so in its coverage section.

---

## 8. 🩺 Related per-host check (belongs in `nic-health.sh`)

**Rx power relative to the host's own peers:** WARN when a linked port's module Rx power is ≥ 5 dB below the median of the same host's other linked ports with the same module compliance (needs at least 3 peers). This catches an attenuated fibre or dirty connector **before** symbol errors appear, while the value is still inside the module's own alarm range. Both low-Rx cases found during the prototype comparison read "OK" in `mlx5.deep.module` and would have been flagged by this rule. It is a per-host rule, so it goes into `nic-health.md` §7 as a deep check, not into `nic-report`.

---

## 9. 🔒 Security

- **No interactive credentials.** `ssh -o BatchMode=yes` and `sudo -n` only; a host that would prompt is recorded as `ssh-fail` / `sudo-fail`.
- **No remote `eval`, no string-built shell commands.** The remote command is a fixed array; inventory fields are validated (§5.1) before use; local variables are always quoted.
- **Host keys:** the SSH policy is left unchanged by default; `--accept-new-hostkeys` is explicit.
- **`--ship`:** copies to a `mktemp`-named path under `/tmp`, mode 0700, removed by a remote `trap`. It never writes outside `/tmp` and never touches the package manager.
- **Reports hold sensitive inventory** (host names, switch ports, addresses). HTML and PDF embed no remote resources, and the classification label is printed on every PDF page. Sweep directories are created with mode 0750.
- **`nic-report.py` never makes network calls.**

---

## 10. 📚 Repo changes

| File | Change |
|---|---|
| `nic-sweep.sh` | New companion script (`SCRIPT_VERSION`, `# Version:` header, `--version`, `--help`) |
| `nic-report.py` | New companion script, Python 3.9+, standard library only (WeasyPrint optional) |
| `man/man8/nic-sweep.8`, `man/man8/nic-report.8` | New man pages (NAME, SYNOPSIS, DESCRIPTION, OPTIONS, EXIT STATUS, EXAMPLES, AUTHORS, SEE ALSO → `nic-health(8)`, `nic-xray(8)`) |
| `completions/nic-sweep.bash`, `completions/nic-report.bash` | New completions |
| `Makefile` | install targets; `make test` runs `tests/nic-sweep-test.sh` and `python3 -m unittest tests/test_nic_report.py`; `make lint` adds `python3 -m py_compile` (and `ruff` if present) |
| `.github/workflows/ci.yml` | Python job (lowest supported version, 3.9) |
| OBS spec / Debian control | Ship both scripts; `Recommends: python3`, `Suggests: python3-weasyprint` |
| `README.md` | Fleet sweep and report section with examples |
| `CLAUDE.md` | §1 list the new companions; §2 one line: "`nic-report.py` is Python 3 (stdlib only), see `docs/design/nic-sweep.md` §3" |
| `tests/fixtures/sweeps/` | Obfuscated sweep trees plus legacy CSV variants (per-host, merged, CRLF with leading blank line) |
| `samples/` | Obfuscated report outputs (md, html, pdf first page as PNG) |

---

## 11. 🗺️ Phased plan

| Phase | Scope | Exit criteria |
|---|---|---|
| **0** | This design approved; `CLAUDE.md` §1–§2 updated | Doc merged |
| **1** | `nic-health` P1 (`uptime_s`, `boot_id`) | Fixture tests; samples regenerated |
| **2** | `nic-sweep.sh`: inventory, parallel SSH, layout §5.4, manifest, exit codes, progress bar | Test suite with a stubbed `ssh` covers every host status; real sweep on a lab fleet |
| **3** | `nic-report.py` core: loaders (sweep + legacy import), record model, extractors, A1–A3, Markdown and JSON | Unit tests over fixtures, including the CRLF/blank-line import |
| **4** | A4–A5 (baselines, outliers, cross-site patterns), HTML | Reproduces the prototype's findings on its obfuscated data |
| **5** | PDF (WeasyPrint print stylesheet), `--per-site`, `--suppress` | Visual check of cover, contents page numbers, landscape pages |
| **6** | `nic-health` P2 (`metrics`); extractors become a fallback for older JSON | Report output identical with and without P2 on the same sweep |
| **7** | A6 sweep comparison | Fixture pair with a reboot between sweeps |
| **8** | Packaging, man pages, completions, README, samples; release on request | Tandem version bump |

The per-host Rx check (§8) is tracked in `nic-health.md` and can land at any phase.

---

## 12. ❓ Open questions

1. Names: `nic-sweep.sh` / `nic-report.py`, or `nic-fleet.sh` / `nic-fleet-report.py`?
2. Should the installed command keep the `.py` suffix? The packages already install `nic-health.sh` as `/usr/bin/nic-health`; the same pattern would give `/usr/bin/nic-report`.
3. Minimum Python: 3.9 covers Rocky 9, Debian 12/13, Ubuntu 22.04/24.04 and openSUSE. SLES 15's default `python3` is 3.6, but `python311` is available there. Is that acceptable for a tool that runs on the operator host?
4. Should `nic-sweep.sh` optionally sweep `nic-xray --optics --lacp` by default when `nic-xray` is present, since LLDP peer names make findings directly actionable?
5. Retention: should the sweep tree get a `--keep N` pruning option, or stay out of scope?

---

## 13. 🔗 References

- `docs/design/nic-health.md`: check catalog, counter semantics (§5), deep mode (§7), output schema (§10)
- RFC 4180: CSV format
- WeasyPrint: CSS Paged Media (`@page`, named pages, `target-counter`, `string-set`), https://doc.courtbouillon.org/weasyprint/
- Python `statistics` module: `median`, `quantiles`
