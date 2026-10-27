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
| `-L`, `--lookback MIN` | Link-down look-back in the kernel journal (default 60, max 1440, `0` = off; current boot only) — #9 |
| `-O`, `--output table\|json\|csv` | Output format (default `table`) |
| `-t`, `--check-tools` | Report available, missing, and disabled capabilities, then exit |
| `-a`, `--all` | Table also lists OK and N/A rows (default: WARN/CRIT/UNKNOWN only, plus a hidden-row count). CSV/JSON always contain every row |
| `-n`, `--no-color` | Disable ANSI colors |
| `-l`, `--level basic\|deep` | `basic` (default) is passive. `deep` adds allowlisted vendor tool queries (§7) |
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
8. **History floor (#15).** Bursty errors can fall between two snapshots: one 5 s run gave `CRIT`, the next `OK`, on a port with 160M symbol/CRC errors in 7 weeks. In delta mode, when no escalating counter of `mlx5.phy.errors` or `mlx5.frame.errors` grows, a counter whose total is ≥1000 and averages ≥60/h over host uptime is `WARN` ("history: NAME ~N/h"). Uptime ≥ time since driver load, so the average is a lower bound. History alone never gives `CRIT`, as in absolute mode. Context-only counters (`rx_corrected_bits_phy`) do not count. Trade-off: `_phy` counters cannot be cleared, so a link fixed after an incident keeps the `WARN` until a driver reload, reboot, or the average dropping below 60/h; the hint says so. Assumes the counters restart with the boot (unverified for kexec or a warm reboot that keeps the NIC powered). The default window stays 5 s for sweeps and monitoring; `--help`, the man page and the README recommend `-I 30` or longer for troubleshooting.

---

## 6. 📋 Check catalog (v1)

> 🔎 Counter names must be verified against the kernel's NVIDIA-authored mlx5 counter documentation for the target kernel range before implementation (Phase 1). Names drift between driver versions; an absent counter yields `N/A`, never an error.

### 6.1 Generic (any PCI NIC, no vendor tools)

| Scope | Check | Source | Severity guidance |
|---|---|---|---|
| ASIC | PCIe link degraded | sysfs `current_link_{speed,width}` vs the lower of the device `max_link_{speed,width}` and the upstream port's (parent directory of the resolved device path) | Below that → `WARN`. Equal to it but below the device maxima → `OK`, "slot-limited" in evidence (#14: on-board BCM5720, x2-capable, wired to an x1 root port on every Dell EPYC node). No upstream attributes → device maxima. Never `CRIT` alone |
| ASIC | PCIe AER | sysfs `aer_dev_{correctable,nonfatal,fatal}` | fatal or nonfatal Δ>0 → `CRIT`; correctable Δ>0 → `WARN` |
| ASIC | devlink health reporters (device) | `devlink health show pci/<BDF>` (mlx5: `fw`, `fw_fatal`, `vnic`; discover, don't assume) | state ≠ healthy → `CRIT`; error count Δ>0 → `WARN` |
| Port | devlink health reporters (port) | `devlink health show` on the `auxiliary/mlx5_core.eth.N` instance (mlx5: `tx`, `rx`), mapped to the netdev via `devlink port show` | same as above |
| ASIC | Firmware / PSID | `devlink dev info pci/<BDF>`, fallback `ethtool -i` | informational |
| ASIC | Temperature | `device/hwmon/hwmon*/temp*_{input,crit,max,highest,alarm,label}` on every PCI function, deduplicated by label | within 10 °C of crit, or ≥`_max` when `_max` < crit → `WARN`; ≥crit → `CRIT`; `_alarm`=1 → `WARN`. A `_max` above crit is ignored (ixgbe reports 105 > 95). A `_crit`/`_max` ≤ 0 is no threshold (mlx5 empty module cage reports `input=0 crit=0`, which read as CRIT before) → `N/A` unless `_alarm`=1. Read error `EBUSY` (firmware lists the sensor but has no reading, e.g. sfc) → `N/A`; other read errors → `UNKNOWN`. `_highest` shown as peak since driver load |
| Port | Link flaps | `carrier_changes` (sysfs) | Δ>0 → `WARN`. Historical totals are informational only. A counter present at T0 but gone at T1 → `UNKNOWN`. Driver `link_down_events_phy` (mlx5 `ethtool -S`) moves to the mlx5 module (Phase 3) since it is not generic |
| Port | Link state | sysfs `carrier`/`operstate`, `flags` (IFF_UP), `master`, `upper_*`, `device/sriov_numvfs`, `carrier_up_count`; `ip -o addr show dev IFACE scope global` | No carrier on a port in use (master, upper device, SR-IOV VFs or global address) → `WARN`; bond master also down → `CRIT` (admin-down bond → `N/A`). Spare port without link or admin down → `N/A`. Never spare by default: `ip` missing/failed → `UNKNOWN`; `carrier_up_count` > 1 with no use found → `WARN`. Carrier with operstate dormant/lowerlayerdown/testing → `WARN`. Admin state alone cannot separate spare from used ports: provisioning brings every port up, and spare ports show `carrier_up_count=1`/`carrier_down_count=1` from driver init (#12) |
| Port | Link-down look-back | `journalctl -k --since -<MIN>min` (one query per run, bounded by `timeout`); driver lines whose interface word is followed by a link-down phrase (mlx5 `Link down`, ice/i40e/ixgbe/igb/bnxt_en `NIC Link is Down`, tg3 `Link is down.`); `carrier_down_count` as context | ≥1 → `WARN`; ≥3 while `carrier_changes` also grows in the window → `CRIT`. History alone never exceeds `WARN`. Bond/bridge lines (`(slave IFACE):`, `port N(IFACE)`) are not counted. Link-up lines are ignored (kernel rate-limiting makes downs the reliable floor). `journalctl` missing or no kernel journal for this boot → one host `N/A` row; failed or timed-out query → host `UNKNOWN`; never `0` on failure (#9) |
| Port | FEC mode/stats | `ethtool --show-fec` (where supported) | mode mismatch vs speed expectation → `WARN`. ⏳ **Deferred**: no validation host exposes FEC statistics (mlx5, ice, ixgbe, sfc, e1000e all checked) |
| Port | Ring sizing context | `ethtool -g` | feeds hints only |

### 6.2 `mlx5_core` — Ethernet counters (`ethtool -S`)

| Area | Counters | Type | Interpretation |
|---|---|---|---|
| Host RX starvation | `rx_out_of_buffer`, `rx_buff_alloc_err` | cumulative | Host can't drain rings → hint `ethtool -G … rx <max>`, IRQ affinity, CPU |
| NIC buffer drops | `rx_discards_phy`, `tx_discards_phy` | cumulative | NIC buffer exhausted, often PCIe or host backpressure |
| PHY / signal | `rx_bits_phy` (denominator, **absent on ConnectX-6 Lx**), `rx_corrected_bits_phy` (pre-FEC), `rx_pcs_symbol_err_phy`, `rx_symbol_err_phy` (post-FEC), `rx_err_lane_N_phy` | cumulative | Compute pre/post-FEC BER. Without `rx_bits_phy`, estimate the bits as link speed × window (the PHY counts idle bits too, so `rx_bytes_phy`×8 would overstate the BER on a quiet link), shown as `BER~` and marked in evidence (#15). The data rate is a few % below the line rate, so the estimate reads slightly high. It is judged only when every lane is NRZ (≤25G per lane; lanes unknown above 25G → not judged), since PAM4 runs a far higher pre-FEC BER by design; deep-mode `mlxlink` reports the measured BER. Post-FEC errors > 0 → `CRIT`. Per-lane skew → optic/cable suspect (only the lanes the link uses: mlx5 exposes 4 lane counters even on a single-lane 25G link, #16) |
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
| `mlx5.phy.errors` | `rx_symbol_err_phy`, `rx_pcs_symbol_err_phy` → `CRIT`; pre-FEC BER > 1e-06 → `WARN` (`rx_bits_phy`, else estimated from link speed × window, NRZ lanes only); history floor (§5.8) → `WARN` | `rx_corrected_bits_phy`, `rx_err_lane_N_phy` (lane dominance ≥90% among the lanes in use → hint; lanes from `ethtool IFACE` "Lanes:", else ≤25G = 1 lane, else all) |
| `mlx5.frame.errors` | CRC, fragments, jabbers, undersize, oversize → `WARN`; history floor (§5.8) → `WARN` | |
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

### 7.3 Implementation (Phase 5)

- **Gate.** `deep_argv_allowed()` runs before every call. The tool must be `mlxlink` or `mstlink`. The argv must equal `DEEP_ARGS_TEMPLATE` (`-d {BDF} -m -c`) element by element. The BDF must match `^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$`. No element may appear in `DEEP_FORBIDDEN_ARGS`, a check that still applies if the template is ever edited. A refused call becomes `UNKNOWN` and is never executed.
- **Tests.** A `timeout(1)` stub logs every executed argv. The suite asserts the exact calls (one per mlx5 PF) and that no forbidden flag is ever executed. Mutation testing shows that removing each guard fails at least one test.
- **Execution.** Calls run as `LC_ALL=C <abs timeout> -k 2 10 <abs tool> <argv>` (`timeout` is required for `-l deep`), once per mlx5 physical function, after the T1 snapshot. `-k` sends SIGKILL if the tool ignores SIGTERM: exit 124 or 137 → `UNKNOWN`.
- **Command hijack hardening** (applies to every command, not only deep mode): functions inherited from the environment (`BASH_FUNC_*`) are unset at load, and tools are resolved with `type -P` (executable files only, absolute paths). Codex review of Phase 5: 2 findings, both fixed. Output is ANSI-stripped: mstlink colors its output even when piped.
- **Checks** (port scope):
  - `mlx5.deep.troubleshooting`: Status Opcode ≠ 0 → `WARN`, with the tool's recommendation as the hint.
  - `mlx5.deep.fec`: the module's Compliance says "with FEC" but the link runs "No FEC" → `WARN`.
  - `mlx5.deep.ber`: effective BER ≥ 1E-12 → `WARN`. This is an average since the last counter clear, so it is never `CRIT`. Evidence always lists effective/raw BER and effective errors (`?` if missing); `Raw Physical Errors Per Lane` and `Link Down Counter` only when printed (absent in mstflint 4.26, present in MFT and mstflint 4.31; #13).
  - `mlx5.deep.module`: DOM values outside the module's own `[low..high]`, or any lane with Tx Fault, Rx LOS or CDR LOL → `WARN`. Multi-lane modules (QSFP28 SR4) print bias, Rx and Tx power and the fault flags once per lane (`-1.4,-0.4,-0.37,-1.28 [-14.089..3.398]`, `0,0,1,0`): every lane is judged, the hint names the lane, the value shows the lowest..highest lane and the evidence keeps every lane. Before 2.13.0 such values were skipped, so 100G modules had no power or lane-fault check.
  - `mlx5.deep.rx_peers`: the port's Rx (lowest lane) ≥ 5 dB (`DEEP_RX_PEERS_DELTA_DB`) below the median of the host's other **linked** ports with the same module Compliance → `WARN`; judged with at least 3 such peers (`DEEP_RX_PEERS_MIN`), else `N/A`, and `N/A` without link. It catches an attenuated fibre or dirty connector before symbol errors appear, while Rx is still inside the module's own range (both low-Rx cases of the prototype comparison read `OK` in `mlx5.deep.module`; `docs/design/nic-sweep.md` §8). The value is the difference in dB, and the evidence lists the peers. `nic-report` computes the same comparison itself (`rx_delta_host_db`), so older JSON loses nothing.
- **Failures.** No tool → one host `N/A` with an install hint. Timeout or tool error → `UNKNOWN`.
- **`mlxconfig`/`mstconfig` dropped from deep mode.** On a ConnectX-6 Lx (mstflint 4.31, no `mstflint_access` module), `mstconfig -d BDF q` took 6 s per device, almost all of it kernel time. `-e q` exceeded 10 s and was killed by `timeout`. The device was verified unaffected afterwards. That query reports configuration, not health, so the cost isn't justified.
- **Measured on pve-01.** `mstlink -d BDF -m -c` takes 0.5 s per port, so deep mode adds about 4 s on 8 ports. No link or carrier change was caused.

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

**Implementation (Phase 6).**
- Shipped inside the existing `nic-xray` package as `/usr/bin/nic-health`, with `nic-health.8` and a bash completion. The completion registers both the packaged name and `nic-health.sh`.
- The spec and `debian.control` gain `Recommends: pciutils, mstflint`. The patch is prepared, not committed: OBS builds from the release tag, so it has to land together with the release that first contains `nic-health.sh`. A local `rpmbuild` from the patched spec succeeds.
- The ISO builder gains `--with-vendor-tools` (default `false`; deep mode is opt-in), which adds `mstflint` to the install set. `mstflint` is available in every ISO target: Debian 12 (4.21) and 13 (4.31), Ubuntu 22.04 (4.17/4.21) and 24.04 (4.26), Leap 15.6 (4.21), Tumbleweed and Slowroll (4.33), Rocky 9 and 10 (4.34, BaseOS). Only 4.31 output is validated; older `mstlink` output that lacks a key yields `N/A`.

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
  "schema_version": 2,
  "tool": "nic-health.sh",
  "version": "x.y.z",
  "host": "…",
  "collected_at": "2026-10-19T12:00:00Z",
  "uptime_s": 4844149,
  "boot_id": "3f2a6c1e-8b4d-4e7f-9a10-5c6d7e8f9a0b",
  "interval_s": 5.01,
  "level": "basic",
  "lookback_min": 60,
  "capabilities": { "devlink": true, "mstlink": false, "mlxlink": false },
  "summary": { "ok": 41, "warn": 2, "crit": 0, "unknown": 1, "na": 6 },
  "exit_code": 1,
  "results": [ { "scope": "port", "target": "ens1f0np0", "check_id": "…", "severity": "WARN", "…": "…",
                  "metrics": { "rx_dbm": -8.827, "rx_dbm_low": -11.308, "rx_dbm_high": 3.398, "…": "…" } } ]
}
```

- **`uptime_s` / `boot_id`:** host uptime in whole seconds and the kernel boot ID (`/proc/sys/kernel/random/boot_id`), both read at `collected_at`, `null` when unreadable or malformed. They let a later comparison turn since-boot totals into rates and tell a counter reset (new `boot_id`) from counter growth (`docs/design/nic-sweep.md` §7, P1). Additive: they kept `schema_version` 1; `metrics` (P2) raised it to 2.
- **`metrics` (`schema_version` 2):** an optional object per result with the values behind its evidence as typed JSON, so a consumer such as `nic-report.py` does not parse human text with regular expressions (`docs/design/nic-sweep.md` §7, P2 and P3). JSON only: the evidence text stays byte-for-byte the same, and the table and CSV are unchanged. Rules:
  - **Sampled counters** are the values read at both ends of the sampling window (T0 and T1), written as `{"total": N, "delta": N}`: the total at T1 since driver load (or boot) and the growth in the window. `delta` only with a window (`-I` > 0), and left out when it cannot be computed (counter reset, or new at T1). They are: every `mlx5.*` rule counter, `generic.pcie.aer` `cor`/`nonfatal`/`fatal`, `generic.link.flaps` `carrier_changes`, and `generic.link.state` `rx_bytes`/`tx_bytes`. Totals keep all 20 digits of a 64-bit counter.
  - **Plain integers** are read once, at T1 or from the deep tool: `carrier_up_count`, `carrier_down_count`, `bond_link_failures`, `link_downs`, `carrier_down_count` of the look-back, `window_min`, `effective_errors`, `link_down_counter`, `raw_errors_per_lane`, the opcodes and the `*_pct` gauges.
  - **Measurements** are JSON numbers copied from the text they were read from (sysfs, `ethtool`, the deep tool) after a strict check, so they are exact, finite and independent of the locale: never `nan` or `inf`. A scientific value whose exponent could overflow a double is left out.
  - **Text** goes through the JSON escaper, like every other string.
  - **Absent or unparseable values are left out**, never written as 0 (e.g. a deep tool's `N/A`, mstflint 4.26 without `Link Down Counter`). Results without a reading carry no `metrics` (most N/A results, and UNKNOWN for a vanished, reset or unparseable value). An N/A result that has a reading does carry them: a temperature sensor with no threshold, and `generic.link.state` of an administratively down or spare port, which always carries its service-impact facts.

| `check_id` | `metrics` keys |
|---|---|
| `generic.pcie.link` | `speed_gts`, `width` (trained); `max_speed_gts`, `max_width` (card); `upstream_max_speed_gts`, `upstream_max_width` (slot, when readable); `expected_speed_gts`, `expected_width` (what both support); `slot_limited`, `below_capability` (bool) |
| `generic.pcie.aer` | `cor`, `nonfatal`, `fatal`: counters summed over the card's functions (a kind without a sysfs file is left out) |
| `generic.temperature` | `label`; `temp_c`, `warn_c`, `crit_c`, `max_c`, `highest_c` (degrees, exact from millidegrees; thresholds at or below 0 are no thresholds and left out); `alarm` (bool) |
| `generic.link.state` | `carrier` (bool), `operstate`, `carrier_up_count`, `carrier_down_count`; service impact (P3): `in_use` (bool) and `in_use_reasons` (subset of `bond`, `bridge`, `upper`, `sriov_vfs`, `global_address`, in that order), `in_use_reasons_complete` (only `false`, when addresses could not be checked), `bond`, `bond_link_failures`, `rx_bytes`, `tx_bytes` (sampled counters) |
| `generic.link.flaps` | `carrier_changes` (counter) |
| `generic.link.lookback` | `link_downs`, `window_min`, `carrier_down_count` |
| `mlx5.*` (§6.2 rules) | every counter of the rule the driver exposes, by its `ethtool -S` name (counter; zeros included, INFO counters and `rx_bits_phy` too); `mlx5.pcie.path`: `outbound_pci_stalled_rd_pct`, `outbound_pci_stalled_wr_pct`, `outbound_pci_buffer_overflow_pct` (gauges); `mlx5.phy.errors`: `pre_fec_ber`, `pre_fec_ber_estimated` (from link speed × window), `pre_fec_ber_judged` (false on PAM4 lanes) |
| `mlx5.deep.troubleshooting` | `status_opcode`, `group_opcode` (integers), `recommendation` |
| `mlx5.deep.fec` | `fec`, `compliance`, `fec_mismatch` (bool) |
| `mlx5.deep.ber` | `effective_ber`, `raw_ber` (as printed, e.g. `15e-255` for "no errors"), `effective_errors`, `raw_errors_per_lane` (list), `link_down_counter`, `since_clear_min` |
| `mlx5.deep.module` | `temperature_c`, `voltage_mv`, `bias_ma`, `rx_dbm`, `tx_dbm`, each with `_low`/`_high` (the module's own range) and, on multi-lane modules, `_lanes` (then the value is the lowest lane); `rx_dbm_judged` (false without link); `tx_fault`, `rx_los`, `tx_cdr_lol`, `rx_cdr_lol` (lists: one flag per lane, or the tool's lane mask on single-lane modules); `vendor`, `part_number`, `compliance` |
| `mlx5.deep.rx_peers` | `rx_dbm`, `peers_median_dbm`, `delta_db`, `peers` (how many), `compliance` |

`generic.devlink.health.*` has no `metrics`: its value already carries the state and counters, and no consumer needs them typed yet.

- **Service impact (P3) on `generic.link.state`:** why the port counts as in use comes from the same scan that judges a port without link (#12): its master (`bond` when the master has `bonding/`, `bridge` when it has `bridge/`, else `upper`, e.g. OVS or team), its other upper devices (`upper`, e.g. a VLAN; not the master's own `upper_*` link), SR-IOV VFs (`sriov_vfs`) and a global address (`global_address`; one `ip -o addr show scope global` per run, first address per interface). The evidence of a port without link still names the first reason only. `in_use`/`in_use_reasons` are left out when the scan cannot tell (no reason found and `ip` missing or failing); when it found a reason but could not check addresses, the reasons may be incomplete and `in_use_reasons_complete` is `false`. `bond_link_failures` is the slave's `Link Failure Count` in `/proc/net/bonding/<bond>`. `rx_bytes`/`tx_bytes` are the `statistics/` byte counters sampled with the others: their `delta` says whether the port carries traffic now, which totals since boot cannot (LLDP and ARP alone make them grow). All read with Bash only.
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
| **5** | Deep mode: `mstlink`/`mlxlink` allowlist (§7) | Forbidden-list unit test: argv never contains a denied flag ✅ |
| **6** | Packaging: Makefile, OBS, offline ISO, man page, README, samples | Release with tandem version bump (on request). In repo ✅; OBS patch pending the release |
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
| 2026-10-20 | Phase 5 deep mode on pve-01 (mstflint 4.31.0 installed from Debian for this) | CX-6 Lx fw 26.47.1026 | All 8 ports: the module Compliance says "25GAUI C2M AOC with FEC" but the link runs "No FEC" → `mlx5.deep.fec` `WARN`. Effective BER since the last clear: 5E-10, 8E-11, 3E-11 and 6E-12 on the erroring ports (`WARN`); a clean port prints `15E-255`, shown as `~0`. mstlink's own troubleshooting says "No issue was observed" (opcode 0). pbs-01 (no tool) → `N/A`; non-mlx5 hosts → no deep records. `make test`: 235 tests (bash 5.3 and 4.4) |
| 2026-10-20 | Deep mode, both backends, on one host: 2× ConnectX-6 Dx (100G SR4) + 2× ConnectX-6 Lx (25G SR), 8 ports | CX-6 Dx fw 22.49.1014, CX-6 Lx fw 26.49.1014 / Ubuntu 24.04, 7.0.0-30-generic | **mstflint 4.26.0** (Ubuntu package) and **NVIDIA MFT 4.34.1-25** (LTS, `install.sh --without-kernel`: no `kernel-mft-dkms`, no `mst start`; `mlxlink -d <BDF>` works through `mft-mlx5`). Same 32 deep rows with identical severities on both; values differ only by gauge noise. Every key the parser reads is present under the same name in both. MFT adds `Link Down Counter` (331, equal to `link_down_events_phy`) and `Link Error Recovery Counter`; mstflint 4.26 prints neither (4.31.0 does print `Link Down Counter`). Found a 25G link with effective BER 3E-9 (`WARN`) and growing symbol errors (`mlx5.phy.errors` `CRIT`) from a dirty fiber (Rx -7.75 dBm). Unused no-link ports give opcode 2 / `N/A` BER / Rx -40 dBm (#12). Fixtures `mlxlink-cx6lx-25g-sr-*.txt` and `mstlink-4.26-cx6lx-25g-sr-ber-errors.txt` (same port, both tools) added. Look-back (`-L`) validated here too: whole-boot count = `carrier_down_count` (345) |
| — | Broadcom `bnxt_en` | — | ⏳ Pending: no host with a Broadcom NIC identified |

## 14. ❓ Open questions

1. **Default `--interval`.** 5 s is a balance between signal and run time. Should monitoring mode default lower? Bursty errors miss short windows (#15): the history floor (§5.8) covers the worst case, and the docs recommend `-I 30`+ for troubleshooting.
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
