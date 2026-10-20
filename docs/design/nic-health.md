# 🩺 Design: `nic-health.sh` — NIC hardware health checks

| Field | Value |
|---|---|
| **Status** | 📝 Draft — approved direction, no code yet |
| **Author** | Ciro Iriarte |
| **Created** | 2026-10-19 |
| **Updated** | 2026-10-20 |
| **Reviewers** | Claude (author of first draft), Codex, Antigravity (advisor reviews in `.omc/artifacts/ask/`) |

---

## 1. 📌 Decision summary

| Question | Decision |
|---|---|
| Embed vendor health checks in `nic-xray.sh`? | ❌ No. Ship a **companion** script, `nic-health.sh`, in the same repo. |
| Separate repository? | ❌ No. Same repo, same conventions, same release tag (tandem versioning per `CLAUDE.md` §6). |
| Add a `--health` column to `nic-xray.sh`? | ❌ Not initially. Revisit only for a cheap, generic, opt-in summary with a stable schema that does not touch default or watch-mode behaviour. |
| Discovery | Own minimal sysfs + `ethtool -i` discovery. **No** dependency on `nic-xray.sh --output json` or `jq`. |
| Code layout | **v1: single file** with per-driver functions. Split into modules only when a second vendor lands, using a fixed, trusted manifest (§9.2). |
| Default behaviour | **Passive, read-only**: `ethtool -S`, sysfs, devlink health state, RDMA `hw_counters`. |
| Vendor tools | Opt-in `--level deep`; **query-only allowlist**, with timeouts. Never auto-installed or downloaded (§8). |
| Missing data | Always `UNKNOWN`, never silently `OK`. |

---

## 2. 🎯 Goals and non-goals

### Goals
- Give a pass/warn/critical verdict on NIC **hardware and data-path health**, with evidence and a remediation hint.
- Go **vendor-deep**, starting with NVIDIA/Mellanox `mlx5_core`, without hurting the speed or dependency footprint of `nic-xray.sh`.
- Plug into monitoring: Nagios-style exit codes and machine-readable JSON.
- Be safe to run on production hosts by default.

### Non-goals
- Topology, LLDP, bonding, or VLAN inventory. That stays in `nic-xray.sh`.
- Firmware updates, configuration changes, resets, link tests, or any write operation.
- Long-term time-series storage. Use Prometheus or a similar system for that; this tool takes a snapshot plus a short delta.

---

## 3. ⚖️ Why a companion script, not embedding

The two tools do overlap. `nic-xray.sh` already judges optics DOM health and bond MTU mismatches, so "inventory vs diagnosis" is not by itself enough reason to separate them. The real reasons are **operational**:

1. **Dependencies.** The health tool optionally uses `mstflint`/MFT/`niccli`. nic-xray must not grow those dependencies.
2. **Sampling delay.** Meaningful counter checks need a delta window (default 5 s). That would distort nic-xray's default run time and watch-mode refresh.
3. **Exit semantics.** Monitoring needs 0/1/2/3 verdict exit codes. nic-xray exits 1 on usage or permission errors.
4. **Safety boundary.** Vendor tool invocations need their own consent flag, allowlist, and timeouts. That is easier to audit in a dedicated script.
5. **Size.** Vendor counter catalogs grow with each vendor and driver version, and nic-xray is already about 3.5k lines.

### Alternatives considered

| Alternative | Rejected because |
|---|---|
| Embed in `nic-xray.sh` behind `--health` | All of the above. It also couples vendor counter churn to the stable tool. |
| Separate repo | Duplicates the conventions, packaging (OBS), offline ISO, and docs pipeline. Same audience, same hosts. |
| Consume `nic-xray.sh --output json` | Pays `lldpctl` latency for unneeded data. Needs `jq` or fragile Bash JSON parsing. The JSON is unversioned. `device` is a sysfs basename, not always a PCI BDF (USB/virtual). |
| Glob-sourced `health.d/*.sh` | Root plus sourcing from a possibly user-writable path means arbitrary code runs as root (§9.2). |

> ℹ️ The health tool **may** later accept nic-xray JSON as optional *enrichment* input (for example to show LLDP peers next to a failing port), never as its discovery source.

---

## 4. 🏗️ Architecture

```
nic-health.sh
├── parse_args            getopt, short+long, --help, --version
├── preflight             root check, tool capability probe (§8.1)
├── discover              /sys/class/net/* → iface, BDF, driver, operstate, ASIC group
├── collect T0            per scope (ASIC / port / RDMA), raw snapshot
├── sleep --interval      progress bar (TTY + table output only)
├── collect T1
├── evaluate              generic checks + driver dispatch (check_driver_mlx5_core, …)
├── [deep]                opt-in vendor tool queries (§7)
└── render                table | json | csv, then exit code
```

### 4.1 Discovery
- Enumerate `/sys/class/net/*`, reusing nic-xray's skip-pattern idea (lo, virtual, bridges, and so on).
- Keep only interfaces with `/sys/class/net/$IFACE/device` resolving to a **PCI** device. Skip USB and other buses with a `N/A` note.
- Driver from `readlink /sys/class/net/$IFACE/device/driver`, so `mlx5_core` and **not** `mlx5`. Firmware from `ethtool -i`.
- **ASIC grouping:** ports sharing the same PCI domain:bus:device (differing only in function) are one ASIC. ASIC-scoped checks (firmware health, temperature, PCIe link, `mlxconfig`) run **once per ASIC**, so faults are not reported twice.
- Detect VF and VM context: physical-port (`*_phy`) counters are absent in VFs and VMs, and on the PF they include VF traffic. Report as `N/A`, not `UNKNOWN`.
- Health of a link-down port: skip rate and BER checks (`N/A`). Still run module, devlink and PCIe checks, and in deep mode the `mlxlink` troubleshooting code, which explains *why* the link is down.

### 4.2 Check record (internal contract)

Each check emits exactly one record:

| Field | Example |
|---|---|
| `scope` | `asic` \| `port` \| `rdma` |
| `target` | `0000:3b:00` or `ens1f0np0` |
| `check_id` | `mlx5.rx_out_of_buffer.rate` |
| `value` / `unit` | `1520` / `pkt/s` |
| `threshold` | `warn>0, crit>1000` |
| `severity` | `OK` \| `WARN` \| `CRIT` \| `UNKNOWN` \| `N/A` |
| `evidence` | raw counter values T0/T1, elapsed seconds |
| `hint` | `Increase RX ring: ethtool -G ens1f0np0 rx 8192 (max 8192)` |
| `ref` | link to the kernel doc section or vendor KB |

### 4.3 Exit codes (Nagios-compatible)

| Code | Meaning |
|---|---|
| 0 | All checks `OK` or `N/A` |
| 1 | At least one `WARN`, no `CRIT` |
| 2 | At least one `CRIT` |
| 3 | `UNKNOWN`: usage error, not root, no eligible NICs, or a required data source failed |

> ⚠️ Usage errors and missing root exit **3**, not 1. This deliberately differs from `nic-xray.sh`, so monitoring never reads a typo as `WARNING`.

### 4.4 CLI sketch

| Option | Description |
|---|---|
| `-i`, `--interface IFACE` | Limit to one or more interfaces (repeatable) |
| `-I`, `--interval SEC` | Delta window (default 5; `0` means absolute-only snapshot) — *Phase 2* |
| `-O`, `--output table\|json\|csv` | Output format (default `table`) |
| `-t`, `--check-tools` | Report available, missing, and disabled capabilities, then exit |
| `-n`, `--no-color` | Disable ANSI colors |
| `-l`, `--level basic\|deep` | `basic` (default) is passive. `deep` adds allowlisted vendor tool queries — *planned, Phase 5* |
| `--thresholds FILE` | Threshold overrides (parsed as data, **never sourced**) — *planned* |

> Short options avoid `-o`, which means `--optics` in `nic-xray.sh`. Options are only exposed once implemented.
| `-v`, `--version` | Print `nic-health.sh <version>` |
| `-h`, `--help` | Help, including version |

---

## 5. ⏱️ Counter semantics

Most mlx5 counters are cumulative since driver load, so absolute values alone are poor evidence. Rules:

1. **Delta mode by default.** Two snapshots `--interval` seconds apart.
2. **Monotonic time.** Elapsed time comes from `/proc/uptime` (bash `read`, `CLOCK_BOOTTIME`), not wall clock.
3. **Reset and wrap detection.** If any T1 < T0, or the driver load moment changed, the check is `UNKNOWN (counter reset)` for that interval. **Never clamp negatives to zero.** (`nic-xray --metrics` clamps today; do not copy that.)
4. **Gauges are not deltas.** `outbound_pci_stalled_rd`, `outbound_pci_stalled_wr` and `outbound_pci_buffer_overflow` are *last-second percentage* gauges. Evaluate the T1 value directly. Their `*_events` siblings are cumulative.
5. **Denominators.** Error rates are normalised by traffic: BER uses `rx_bits_phy`; drop ratios use packet counters. A thousand drops in a terabit is not the same as a thousand drops in a megabit.
6. **RDMA `hw_counters` lifespan.** `/sys/class/infiniband/*/ports/*/hw_counters/lifespan` caches values (ms; 10 ms on the validation hosts). The interval must exceed the lifespan, or the check is `UNKNOWN`.
7. **Absolute-only mode** (`--interval 0`) reports totals since driver load, labelled as *historical*, with severity capped at `WARN`.

---

## 6. 📋 Check catalog (v1)

> 🔎 Counter names must be verified against the kernel's NVIDIA-authored mlx5 counter documentation for the target kernel range before implementation (Phase 1). Names drift between driver versions; an absent counter yields `N/A`, never an error.

### 6.1 Generic (any PCI NIC, no vendor tools)

| Scope | Check | Source | Severity guidance |
|---|---|---|---|
| ASIC | PCIe link degraded | sysfs `current_link_{speed,width}` vs `max_link_{speed,width}` | `WARN` (could be slot-limited; overridable). Never `CRIT` alone |
| ASIC | PCIe AER | sysfs `aer_dev_{correctable,nonfatal,fatal}` | fatal or nonfatal Δ>0 → `CRIT`; correctable Δ>0 → `WARN` |
| ASIC | devlink health reporters (device) | `devlink health show pci/<BDF>` (mlx5: `fw`, `fw_fatal`, `vnic`; discover, don't assume) | state ≠ healthy → `CRIT`; error count Δ>0 → `WARN` |
| Port | devlink health reporters (port) | `devlink health show` on the `auxiliary/mlx5_core.eth.N` instance (mlx5: `tx`, `rx`), mapped to the netdev via `devlink port show` | same as above |
| ASIC | Firmware / PSID | `devlink dev info pci/<BDF>`, fallback `ethtool -i` | informational |
| ASIC | Temperature | `device/hwmon/hwmon*/temp*_{input,crit,max,highest,alarm,label}` on every PCI function, deduplicated by label | within 10 °C of crit, or ≥`_max` when `_max` < crit → `WARN`; ≥crit → `CRIT`; `_alarm`=1 → `WARN`. A `_max` above crit is ignored (ixgbe reports 105 > 95). Read error `EBUSY` (firmware lists the sensor but has no reading, e.g. sfc) → `N/A`; other read errors → `UNKNOWN`. `_highest` shown as peak since driver load |
| Port | Link flaps | `carrier_changes` (sysfs) | Δ>0 → `WARN`. Historical totals are informational only. A counter present at T0 but gone at T1 → `UNKNOWN`. Driver `link_down_events_phy` (mlx5 `ethtool -S`) moves to the mlx5 module (Phase 3) since it is not generic |
| Port | FEC mode/stats | `ethtool --show-fec` (where supported) | mode mismatch vs speed expectation → `WARN`. ⏳ **Deferred**: no validation host exposes FEC statistics (mlx5, ice, ixgbe, sfc, e1000e all checked) |
| Port | Ring sizing context | `ethtool -g` | feeds hints only |

### 6.2 `mlx5_core` — Ethernet counters (`ethtool -S`)

| Area | Counters | Type | Interpretation |
|---|---|---|---|
| Host RX starvation | `rx_out_of_buffer`, `rx_buff_alloc_err` | cumulative | Host can't drain rings → hint `ethtool -G … rx <max>`, IRQ affinity, CPU |
| NIC buffer drops | `rx_discards_phy`, `tx_discards_phy` | cumulative | NIC buffer exhausted, often PCIe or host backpressure |
| PHY / signal | `rx_bits_phy` (denominator, **absent on ConnectX-6 Lx**), `rx_corrected_bits_phy` (pre-FEC), `rx_pcs_symbol_err_phy`, `rx_symbol_err_phy` (post-FEC), `rx_err_lane_N_phy` | cumulative | Compute pre/post-FEC BER. Without `rx_bits_phy`, fall back to `rx_bytes_phy`×8 (approximate; mark it in evidence) or deep-mode `mlxlink` BER. Post-FEC errors > 0 → `CRIT`. Per-lane skew → optic/cable suspect |
| Frame errors | `rx_crc_errors_phy`, `rx_oversize_pkts_phy`, `rx_undersize_pkts_phy`, `rx_fragments_phy`, `rx_jabbers_phy` | cumulative | CRC → cabling/optic; oversize → MTU mismatch with peer |
| PCIe path | `rx_pci_signal_integrity`, `tx_pci_signal_integrity` | cumulative | PCIe link recovery from framing/CRC faults → `WARN`, `CRIT` if sustained |
| PCIe path | `outbound_pci_stalled_rd`, `outbound_pci_stalled_wr`, `outbound_pci_buffer_overflow` (**absent on ConnectX-6 Lx**) | **gauge (%)** | Host root-complex/credit starvation. Do not delta |
| PCIe path | `outbound_pci_stalled_rd_events`, `outbound_pci_stalled_wr_events` | cumulative | Count of stall periods; Δ>0 → `WARN` |
| Datapath faults | `tx_cqe_err`, `rx_wqe_err`, `tx_recover` / RX recover counters | cumulative | Δ>0 → `CRIT` (driver/FW/DMA fault) |
| Congestion / PFC | `rx_prioN_buf_discard`, `rx_prioN_cong_discard`, `rx/tx_pause_ctrl_phy`, `rx_prioN_pause_duration` (PFC only), `rx/tx_global_pause`, `rx/tx_global_pause_duration` (global pause), `rx_buffer_passed_thres_phy` | cumulative | **Congestion evidence, not a NIC fault.** `WARN` at most, with a note listing CPU/PCIe/app/PFC-config causes |
| Pause storms | `tx_pause_storm_warning_events`, `tx_pause_storm_error_events` | cumulative | error Δ>0 → `CRIT` |
| Module | `module_unplug`, `module_bus_stuck`, `module_high_temp`, `module_bad_shorted` | cumulative | bus_stuck/bad_shorted → `CRIT`; high_temp → `WARN` |
| Steering | `rx_steer_missed_packets` | cumulative | informational; flags flow-steering misconfiguration |

**Implementation (Phase 3).** The table above is a data table in the script (`MLX5_RULE_ID`, `MLX5_RULE_COUNTERS`, `MLX5_RULE_HINT`). There is one record per port per rule:

| Check ID | Escalating counters | Context only (`INFO`) |
|---|---|---|
| `mlx5.rx.starvation` | `rx_out_of_buffer`, `rx_buff_alloc_err` → `WARN` | |
| `mlx5.nic.discards` | `rx_discards_phy`, `tx_discards_phy` → `WARN` | |
| `mlx5.phy.errors` | `rx_symbol_err_phy`, `rx_pcs_symbol_err_phy` → `CRIT`; pre-FEC BER > 1e-06 → `WARN` (only with `rx_bits_phy`) | `rx_corrected_bits_phy`, `rx_err_lane_N_phy` (lane dominance ≥90% → hint) |
| `mlx5.frame.errors` | CRC, fragments, jabbers, undersize, oversize → `WARN` | |
| `mlx5.pcie.path` | `rx/tx_pci_signal_integrity`, `outbound_pci_stalled_rd/wr_events` → `WARN` | stall gauges (% at T1, never deltaed) |
| `mlx5.datapath.faults` | `tx_cqe_err`, `rx_wqe_err`, `tx_recover`, `rx_recover` → `CRIT` | |
| `mlx5.congestion` | `rx_prioN_buf_discard`, `rx_prioN_cong_discard` → `WARN` | pause frames, global pause, `rx_buffer_passed_thres_phy` |
| `mlx5.pause.storm` | warning → `WARN`, error → `CRIT` | |
| `mlx5.module` | `module_bus_stuck`, `module_bad_shorted` → `CRIT`; `module_high_temp`, `module_unplug` → `WARN` | |
| `mlx5.link.phy_down` | `link_down_events_phy` → `WARN` | |

- Only aggregate counters are used. Per-channel `rxN_*`/`txN_*` are skipped: a 64-CPU host prints about 7,000 `ethtool -S` lines per port. Lines are parsed with parameter expansion and an exact-name lookup. A per-line regex made a 5 s run take 23 s on an 8-port host.
- When `mlx5.phy.errors` fires on a link at ≥25 Gb/s, `ethtool --show-fec` is read. If active FEC is `Off`/`None`, the hint says so.
- None of the counters listed → `N/A`. `ethtool -S` failure → one `mlx5.ethtool` `UNKNOWN` record. VFs are skipped (no `_phy` counters).
- Steering (`rx_steer_missed_packets`) is not evaluated: it is informational and grows legitimately.
- ConnectX-6 Lx observation: `tx_pci_signal_integrity` = 1 on every port after boot (link-training artifact). Absolute mode (`-I 0`) therefore WARNs on it. Delta mode does not.

### 6.3 `mlx5_core` — RDMA / RoCE (`/sys/class/infiniband/<dev>/ports/<p>/hw_counters/`)

Collected only when an IB device is bound to the netdev. These are kernel-bypass counters that `ethtool -S` does **not** show.

| Area | Counters | Interpretation |
|---|---|---|
| Transport | `local_ack_timeout_err`, `packet_seq_err`, `out_of_sequence`, `rnr_nak_retry_err`, `implied_nak_seq_err`, `req_transport_retries_exceeded`, `req_rnr_retries_exceeded` | Loss / retransmission on the RoCE fabric |
| Resources | `out_of_buffer`, `out_of_sequence` | Receiver can't keep up |
| Integrity | `rx_icrc_encapsulated` (ICRC errors), `req_cqe_error`, `resp_cqe_error` | Corruption or QP errors |
| Congestion | `np_ecn_marked_roce_packets`, `np_cnp_sent`, `rp_cnp_handled` | **Context only** (ECN/CNP is normal under DCQCN) |

---

### 6.4 `ice` — observed baseline (not yet a check catalog)

Observed on E810-XXV, SLES 15 SP6 kernel 6.4. Recorded here so the generic module and the future `ice` module tolerate it.

| Area | Observation |
|---|---|
| Counter naming | Port-level counters carry a `.nic` suffix (`rx_crc_errors.nic`, `illegal_bytes.nic`, `mac_local_faults.nic`, `mac_remote_faults.nic`, `rx_oversize.nic`, `rx_jabber.nic`, `link_xoff_rx.nic`, `tx_timeout.nic`, `tx_dropped_link_down.nic`). Newer kernels may use a different scheme, so match by an alias table, not one literal name |
| Driver-level | `rx_alloc_fail`, `rx_pg_alloc_fail`, `tx_busy`, `tx_restart`, `tx_linearize` |
| Missing on 6.4 | devlink health reporters, FEC statistics → `N/A` |
| Temperature | hwmon `temp1` (no label, crit 105 °C) on function `.0` only |
| Firmware | `devlink dev info` gives `fw.mgmt`, `fw.bundle_id`, `fw.app` (DDP package), `fw.netlist` |
| RDMA (`irdma`) | `hw_counters` use different names from mlx5 (`tcpRetransSegs`, `cnpHandled`, `RxECNMrkd`, `ip4InDiscards`, …) |

## 7. 🔬 Deep mode (`--level deep`)

Explicit consent boundary. Never runs unless requested.

### 7.1 Allowed (query-only, allowlisted argv)

| Purpose | Preferred | Fallback |
|---|---|---|
| Link/BER/FEC/troubleshooting code | `mlxlink -d <BDF> -m -c` | `mstlink -d <BDF> -m -c` |
| Config sanity (read) | `mlxconfig -d <BDF> -e q` | `mstconfig -d <BDF> -e q` |

- Address devices **by PCI BDF**. Never require `/dev/mst/*`.
- Every call: `timeout` (default 10 s), `LC_ALL=C`, fixed `PATH`, argv array (no string-built commands), stderr captured as evidence.
- One call per ASIC where the data is ASIC-scoped.

### 7.2 Forbidden (never invoked, even in deep mode)

| Action | Why |
|---|---|
| `mst start` / `mst restart` | Loads kernel modules, mutates `/dev/mst` |
| `mlxreg` (any) | Raw PRM register access; write-capable |
| `mlxfwmanager`, `mstflint` burn/query-flash | Flash semaphore contention; firmware ops |
| `mlxlink` eye scan, PRBS, `--port_state`, `--fec` set, any write flag | Can perturb or drop the link |
| `devlink health dump show`, `devlink health recover`, `devlink dev reload` | Dumps can trigger collection; recover/reload change state |
| `ethtool -t` (self-test), `ethtool -r` | Interrupts traffic |
| Unbounded `dmesg` | Noisy, leaks unrelated data, unreliable attribution |

> A future, opt-in kernel-log check must be time-bounded, BDF-correlated, and redacted.

---

## 8. 📦 Vendor tooling: distribution model

**Decision: optional dependency, detected at runtime, installed through packaging. Never embedded in the repo, never downloaded at runtime.**

| Option | Verdict | Reasons |
|---|---|---|
| Embed binaries in repo | ❌ | MFT, `niccli`, and the Intel tools are proprietary EULA software; redistributing them in a GPL-3 repo is not allowed. Builds per architecture. MFT kernel modules are DKMS-built for each kernel. Version must track firmware generation. Bloat. Supply-chain ownership |
| Download on demand | ❌ | Root fetching and running binaries is a supply-chain hole. Target hosts are often air-gapped (hence the offline ISO). EULA click-through URLs change. Silent kernel-module install on production |
| **Detect + package recommends** | ✅ | Legal, offline-friendly, auditable, admin stays in control |

### 8.1 Runtime capability probe
- Resolve each capability through a **lookup chain** held in variables (no magic strings), for example `LINK_TOOLS=(mlxlink mstlink)`.
- `--check-tools` prints a table: capability → tool found / missing → checks disabled → where to get it.
- A missing tool means the affected checks are `UNKNOWN`/`N/A`, with an install hint. The run never fails because of it.

### 8.2 Packaging
- **OBS spec / Debian control:** `Recommends:` or `Suggests: mstflint`, plus `pciutils` and `iproute2` (devlink). **Never** MFT, which distros cannot ship.
- **Offline ISO (`ci/build-offline-iso.sh`):** add `--with-vendor-tools true|false`, mirroring `--with-graphviz`. It pulls `mstflint` from the distro mirror into the ISO repo, which is allowed because mstflint is GPL/BSD.
- **Proprietary tools** (MFT, Broadcom `niccli`, Marvell QConvergeConsole): documented in README and man page only. Detected if present.

### 8.3 Vendor coverage outlook

| Vendor | Driver | Basic (no vendor tool) | Deep | Open-source path |
|---|---|---|---|---|
| NVIDIA/Mellanox | `mlx5_core` | ✅ rich | `mstlink`/`mlxlink` | ✅ mstflint |
| Intel | `ice`, `i40e` | ✅ (`ethtool -S`; devlink health/hwmon only on newer kernels) | little beyond devlink | ✅ upstream |
| Broadcom | `bnxt_en` | ✅ (`ethtool -S`, devlink) | `niccli` | ❌ detect only |
| Marvell | `qede` | ✅ (`ethtool -S`) | QConvergeConsole | ❌ detect only |

---

## 9. 🔒 Security

### 9.1 General
- `set -Eeuo pipefail`-compatible style; quote everything; arrays for argv; `printf`, not `echo`, for data.
- Thresholds file is **parsed as key=value data** with a strict regex allowlist. It is **never sourced**.
- All text that leaves the tool (vendor stderr, counter names, firmware strings) goes through a JSON escaper that handles `\`, `"` **and control characters (U+0000–U+001F)**. nic-xray's current `json_escape` only handles `\` and `"`, so it must not be copied as-is (and should be fixed upstream separately).

### 9.2 Module loading (when we split after v1)
- **No globbing.** A fixed manifest of module filenames compiled into `nic-health.sh`.
- Resolve the script's real directory (`readlink -f`), then for every module and each parent directory up to it: reject symlinks, require root ownership, reject group/other write.
- If verification fails, refuse to load the module and report `UNKNOWN` for that driver's checks. Allow a development override only via an explicit `--dev-modules` flag that prints a warning.
- Install modules through the Makefile/OBS/ISO explicitly. A module missing from packaging is a release blocker.

---

## 10. 🖥️ Output

- **Table** (default, TTY): grouped by ASIC, then ports, with severity icons and colours matching nic-xray (✅ OK, ⚠️ WARN, ❌ CRIT, ❔ UNKNOWN, ➖ N/A), a summary line, and a progress bar during the delta window.
- **JSON:** stable, versioned:

```json
{
  "schema_version": 1,
  "tool": "nic-health.sh",
  "version": "x.y.z",
  "host": "…",
  "collected_at": "2026-10-19T12:00:00Z",
  "interval_s": 5.01,
  "level": "basic",
  "capabilities": { "devlink": true, "mstlink": false, "mlxlink": false },
  "summary": { "ok": 41, "warn": 2, "crit": 0, "unknown": 1, "na": 6 },
  "exit_code": 1,
  "results": [ { "scope": "port", "target": "ens1f0np0", "check_id": "…", "severity": "WARN", "…": "…" } ]
}
```

- **CSV:** one row per result record (RFC 4180, reusing the `csv_escape` approach).

---

## 11. 📚 Repo changes

| File | Change |
|---|---|
| `nic-health.sh` | New companion script (`SCRIPT_VERSION`, `# Version:` header, `--version`, `--help`) |
| `man/man8/nic-health.8` | New man page (NAME, SYNOPSIS, DESCRIPTION, OPTIONS, EXIT STATUS, EXAMPLES, AUTHORS, SEE ALSO → `nic-xray(8)`, `ethtool(8)`, `devlink(8)`, `mstlink(1)`) |
| `man/man8/nic-xray.8` | SEE ALSO → `nic-health(8)` |
| `completions/nic-health.bash` | New completion |
| `Makefile` | install/uninstall targets for the new man page and completion |
| OBS spec / Debian control | Ship `nic-health.sh`; `Recommends: mstflint` |
| `ci/build-offline-iso.sh` | `--with-vendor-tools` |
| `README.md` | New section with requirements, recommendations, and examples |
| `CLAUDE.md` | "single-script repository" → "primary script + companion"; apply the conventions to both scripts; tandem versioning covers both |
| `samples/` | Obfuscated health outputs (table/JSON/CSV) via the existing workflow |
| `tests/fixtures/` | Captured `ethtool -S` / sysfs snapshots per driver for offline evaluation tests |

---

## 12. 🗺️ Phased plan

| Phase | Scope | Exit criteria |
|---|---|---|
| **0** | This design approved; `CLAUDE.md` updated | Doc merged |
| **1** | Skeleton: CLI, preflight, discovery + ASIC grouping, record model, exit codes, table/JSON/CSV, `--check-tools`. Verify the mlx5 counter catalog against the kernel doc for supported kernels | Runs on test host; exit code 3 paths covered ✅ |
| **2** | Generic checks (§6.1) + delta engine with reset detection | Fixtures for reset/wrap/gauge cases pass ✅ (FEC deferred, see §6.1) |
| **3** | `mlx5_core` Ethernet checks (§6.2) + hints | Validated on ConnectX hardware (test host) ✅ |
| **4** | RDMA `hw_counters` (§6.3) | Validated on a RoCE-enabled host |
| **5** | Deep mode: `mstlink`/`mlxlink` allowlist (§7) | Forbidden-list unit test: argv never contains a denied flag |
| **6** | Packaging: Makefile, OBS, offline ISO, man page, README, samples | Release with tandem version bump (on request) |
| **7+** | Second vendor (`ice` or `bnxt_en`), which triggers the module split (§9.2) | — |

---

## 13. 🧪 Validation log

| Date | Hardware | Firmware / kernel | Result |
|---|---|---|---|
| 2026-10-20 | NVIDIA ConnectX-6 Lx (MT2894), 2 hosts | 26.47.1026 (LNV0000000037) / 7.0.14-11-pve, 7.0.0-3-pve | Catalog checked against live `ethtool -S`, devlink, sysfs, hwmon and `hw_counters`. Corrections applied in §6 (`rx_bits_phy`, `outbound_pci_buffer_overflow`, `rx_prioN_pause_duration` absent; port reporters on the auxiliary devlink instance; no hwmon `_max`) |
| 2026-10-20 | Intel E810-XXV (`ice`), 1 host | 4.81 0x80020b48 1.3818.0 / SLES 15 SP6 6.4.0-150600.21 | Baseline recorded in §6.4. nic-xray itself also tested here (bash 4.4, SLES, USB `cdc_ether` interface) |
| 2026-10-20 | Phase 1 `nic-health.sh` on 5 hosts: ConnectX-6 Lx (`mlx5_core`), E810-XXV (`ice`), 82599ES (`ixgbe`), SFC9120 (`sfc`), 82574L/82579LM (`e1000e`) | Debian 12/13 (PVE/PBS), SLES 15 SP6 (bash 4.4), Unraid 7.3 | Discovery, ASIC grouping, PCIe link check, table/JSON/CSV and exit codes verified. Chipset-integrated 82579LM has no PCIe link attributes → `N/A`; USB BMC NIC → `N/A`, USB-only selection → `UNKNOWN` (exit 3) |
| 2026-10-20 | Phase 2 on the same 5 hosts | same | Delta (`-I 5`) and absolute (`-I 0`) modes; AER, temperature, devlink (device + port reporters via `devlink port show`), link flaps. sfc lists a sensor that returns `EBUSY` → `N/A`. ixgbe hwmon `_max` > `_crit`. `make test`: 77 unit tests (incl. `set -euo pipefail` sourcing) on bash 5.3 and 4.4. Codex review: 8 findings, 7 fixed (per-function AER reset detection, alarm-only sensors, `devlink port show` failure → `UNKNOWN`, vanished sources → `UNKNOWN`, bad clock → `elapsed_s: null`, `set -e`/`set -u` safety), `link_down_events_phy` moved to Phase 3 |
| 2026-10-20 | Phase 3 on pve-01..04, pbs-01 (+ non-mlx5 hosts) | CX-6 Lx fw 26.47.1026 | All 25G AOC ports (SFP-25G-AO03) run with FEC Off. pve-01 has four ports with growing `rx_symbol_err_phy`/`rx_crc_errors_phy` (up to ~15/s; 61M since boot on `ens1f0np0`) at healthy RX power → `CRIT` + FEC hint. pve-02..04 clean. Non-mlx5 hosts get no `mlx5.*` records. `make test`: 122 tests (bash 5.3 and 4.4). Codex review: 4 findings, 3 fixed (`rx_bits_phy` reset/vanish now `UNKNOWN`; overflow-safe BER, lane and `fmt_sci` math; `outbound_pci_buffer_overflow` gauge added). The gauge-delta finding was disproved by test. 20-digit (unsigned 64-bit) counters are handled in `delta()` by splitting at 18 digits (400G `rx_bits_phy` passes 2⁶³ after ~266 days) |
| — | Broadcom `bnxt_en` | — | ⏳ Pending: no host with a Broadcom NIC identified |

## 14. ❓ Open questions

1. **Default `--interval`.** 5 s is a balance between signal and run time. Should monitoring mode default lower?
2. **Threshold source of truth.** Ship defaults per driver only, or per device ID / firmware range from the start?
3. **Prometheus textfile output** (`--output prom`) as a later format, to cover trend-based alerting that a snapshot cannot?
4. **`json_escape` fix in `nic-xray.sh`.** Track as a separate `fix:` change, independent of this design.

---

## 15. 🔗 References

- Linux kernel docs: *mlx5 counters* (NVIDIA-authored), `Documentation/networking/device_drivers/ethernet/mellanox/mlx5/counters.rst`: https://docs.kernel.org/networking/device_drivers/ethernet/mellanox/mlx5/counters.html
- NVIDIA KB: *Understanding mlx5 ethtool counters*: https://enterprise-support.nvidia.com/s/article/understanding-mlx5-ethtool-counters
- NVIDIA KB: *Understanding mlx5 Linux counters and status parameters*: https://enterprise-support.nvidia.com/s/article/understanding-mlx5-linux-counters-and-status-parameters
- Linux kernel docs: devlink health: https://docs.kernel.org/networking/devlink/devlink-health.html
- mstflint (open-source NVIDIA firmware/diagnostic tools): https://github.com/Mellanox/mstflint
- Advisor reviews: `.omc/artifacts/ask/codex-you-are-reviewing-an-architecture-proposal-*.md`, `.omc/artifacts/ask/antigravity-you-are-reviewing-an-architecture-proposal-*.md`
