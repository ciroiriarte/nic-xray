# 🩺 NIC Health: cross-site comparison (SITE1 · SITE2)

- **Prepared:** 2026-10-27 · **Sites:** 2 · **Hosts:** 6
- **Data:** SITE1 sweep 20261027T143057Z; SITE2 sweep 20261027T143057Z
- **Classification:** Fictional sample data

## 1. Executive summary

| Site | Hosts | Clean (of collected) | Hosts CRIT / WARN / UNKNOWN | Status | Actions P1 / P2 / P3 / P4 |
|---|---|---|---|---|---|
| SITE1 | 3 | 2 (66.7%) | 1 / 0 / 0 | 🔴 **CRIT** | 1 / 0 / 0 / 0 |
| SITE2 | 3 | 0 (0.0%) | 0 / 2 / 0 | 🟡 **WARN** | 0 / 1 / 0 / 0 |

**Top recommendations** (all 2 in section 7, with their rules)

- 🔴 **R1 · P1** SITE1 acme-s1-cmp1-01 `eth0` ↔ `acme-s1-leaf-01.example.net et-0/0/2:0`: Attenuated optical path: Rx -8.6 dBm is -7.86 dB from its peers' median, and the link is failing now (3 link-down messages in the look-back window, 1 carrier changes since driver load, 943 symbol errors in the window).
- 🟠 **R2 · P2** SITE2 acme-s2-stor1-01, acme-s2-stor1-02 `0000:01:00`: PCIe link trained at 2.5 GT/s x4 where card and slot support 16.0 GT/s x4 (slot), on 2 of 2 hosts of the role: a shared cause.

Every finding is explained by a recommendation.

## 2. Coverage and comparability

|  | SITE1 | SITE2 |
|---|---|---|
| Hosts | 3 | 3 |
| Collected | 3 | 2 |
| Roles | cmp1×2, ctrl1×1 | stor1×3 |
| NIC ASICs / ports | 3 / 12 | 2 / 8 |
| Ports with link | 12 | 8 |
| Deep checks evaluated | 24 | 16 |
| FEC in use | Firecode FEC 12 | Firecode FEC 8 |
| nic-health version | 2.14.0 | 2.14.0 |
| Typed metrics / impact facts | 3 of 3 / 3 | 2 of 2 / 2 |
| Hosts with nic-xray | 3 | 2 |
| Optics from deep / nic-xray / none | 12 / 0 / 0 | 8 / 0 / 0 |
| Window | 30 s | 30 s |
| Collected on | 2026-10-27 | 2026-10-27 |

**Hosts not collected**

| Site | Host | Status | Exit | Problem |
|---|---|---|---|---|
| SITE2 | acme-s2-stor1-03 | ssh-fail | 255 | — |

## 3. Verdicts

| Site | Hosts | Collected | OK | WARN | CRIT | UNKNOWN | Clean (of collected) | CRIT / WARN / UNKNOWN rows |
|---|---|---|---|---|---|---|---|---|
| SITE1 | 3 | 3 | 2 | 0 | 1 | 0 | 66.7% | 1 / 1 / 0 |
| SITE2 | 3 | 2 | 0 | 2 | 0 | 0 | 0.0% | 0 / 4 / 0 |

### SITE1 by role

| Role | Hosts | OK | WARN | CRIT | UNKNOWN | Clean (of collected) |
|---|---|---|---|---|---|---|
| cmp1 | 2 | 1 | 0 | 1 | 0 | 50.0% |
| ctrl1 | 1 | 1 | 0 | 0 | 0 | 100.0% |

### SITE2 by role

| Role | Hosts | OK | WARN | CRIT | UNKNOWN | Clean (of collected) |
|---|---|---|---|---|---|---|
| stor1 | 3 | 0 | 2 | 0 | 0 | 0.0% |

## 4. Findings

### SITE1 · acme-s1-cmp1-01

- **CRIT** `eth0` `mlx5.phy.errors`: rx_symbol_err_phy=+943 (bond0 member, in use, 7 bond link failures)
  - Evidence: rx_symbol_err_phy=414877072 (+943) rx_pcs_symbol_err_phy=414877072 (+943) rx_corrected_bits_phy=2379976318 (+9297); rx_bits_phy not exposed
  - Hint: Uncorrectable symbol errors
- **WARN** `eth0` `generic.link.lookback`: 3 (bond0 member, in use, 7 bond link failures)
  - Evidence: 3 link-downs

### SITE2 · acme-s2-stor1-01

- **WARN** `0000:01:00` `generic.pcie.link`: 2.5 GT/s x4
- **WARN** `eth0` `mlx5.nic.discards`: rx_discards_phy=+1 (bond0 member, in use)
  - Evidence: rx_discards_phy=12818188 (+1)

### SITE2 · acme-s2-stor1-02

- **WARN** `0000:01:00` `generic.pcie.link`: 2.5 GT/s x4
- **WARN** `eth0` `mlx5.nic.discards`: rx_discards_phy=+1 (bond0 member, in use)
  - Evidence: rx_discards_phy=9132210 (+1)

## 5. Baselines and outliers

Over ports with link. Baseline: the sites in this report (SITE1, SITE2; 20 ports with an Rx reading).

### 5.1 Receive power by module type

| Module type | Ports | Min | p5 | Median | Max |
|---|---|---|---|---|---|
| 100GBASE-SR4 or 25GBASE-SR | 20 | -8.60 | -0.81 | -0.74 | -0.60 |

### 5.2 Receive power outliers

At least the configured margin below the median for the module type, with a robust score (median/MAD) of at least 3.5.

| Host | Port | Role | Module type | Rx dBm | Median | Δ dB | Robust z |
|---|---|---|---|---|---|---|---|
| SITE1 acme-s1-cmp1-01 | eth0 | cmp1 | 100GBASE-SR4 or 25GBASE-SR | -8.60 | -0.74 | -7.9 | -75.7 |

Within 3 dB of the module's own low limit: SITE1 acme-s1-cmp1-01 eth0 (-8.60 dBm, limit -11.3).

### 5.3 Transmit power by module type

| Module type | Ports | Min | Median | Max |
|---|---|---|---|---|
| 100GBASE-SR4 or 25GBASE-SR | 20 | -1.00 | -1.00 | -1.00 |

### 5.4 Link errors since boot

Uncorrectable symbol errors (rx_symbol_err_phy) since boot.

| Host | Port | Role | Symbol errors | In window | Per hour of uptime |
|---|---|---|---|---|---|
| SITE1 acme-s1-cmp1-01 | eth0 | cmp1 | 414,877,072 | 943 | 750,000 |

### 5.5 Link stability

No port above the carrier-change threshold.

### 5.6 Receive discards since boot

| Host | Port | Role | Discards | In window |
|---|---|---|---|---|
| SITE2 acme-s2-stor1-01 | eth0 | stor1 | 12,818,188 | 1 |
| SITE2 acme-s2-stor1-02 | eth0 | stor1 | 9,132,210 | 1 |

### 5.7 Module temperature and PCIe

Hottest modules: SITE1 acme-s1-cmp1-01 eth0 40 °C, SITE1 acme-s1-cmp1-01 eth1 40 °C, SITE1 acme-s1-cmp1-01 eth2 40 °C, SITE1 acme-s1-cmp1-01 eth3 40 °C, SITE1 acme-s1-cmp1-02 eth0 40 °C. No module within 10 °C of its own high limit.

| Host | ASIC | Role | Trained | Supported |
|---|---|---|---|---|
| SITE2 acme-s2-stor1-01 | 0000:01:00 | stor1 | 2.5 GT/s x4 | 16.0 GT/s x4 (slot) |
| SITE2 acme-s2-stor1-02 | 0000:01:00 | stor1 | 2.5 GT/s x4 | 16.0 GT/s x4 (slot) |

## 6. Patterns

**Within a site:** the same issue on the same port or ASIC in two or more hosts of a role.

| Site | Role | Issue | Port / ASIC | Hosts |
|---|---|---|---|---|
| SITE2 | stor1 | generic.pcie.link | 0000:01:00 | 2 of 2: acme-s2-stor1-01, acme-s2-stor1-02 |
| SITE2 | stor1 | mlx5.nic.discards | eth0 | 2 of 2: acme-s2-stor1-01, acme-s2-stor1-02 |

No issue repeats on the same role at two or more sites.

## 7. Recommended actions (priority order)

Rule catalogs: nic-report-rules.json (catalog 2026.10.1, 17 rules). Ranked by priority (P1 act now … P4 informational) after modifiers and service impact, then activity in the window, number of hosts and place. Matches on one target are merged into one recommendation that cites every rule.

- 🔴 **R1 · P1** SITE1 acme-s1-cmp1-01 `eth0` ↔ `acme-s1-leaf-01.example.net et-0/0/2:0`
  - Diagnosis: Attenuated optical path: Rx -8.6 dBm is -7.86 dB from its peers' median, and the link is failing now (3 link-down messages in the look-back window, 1 carrier changes since driver load, 943 symbol errors in the window).
  - Action: Clean or inspect both fibre ends, then replace the optic and the cable leg to acme-s1-leaf-01.example.net et-0/0/2:0; check the switch side's Tx and DOM for that lane.
  - Rules: OPT-ATTEN-ACTIVE (P1) · base P1; raised half a level: bond0 member with 7 bond link failures
- 🟠 **R2 · P2** SITE2 acme-s2-stor1-01, acme-s2-stor1-02 `0000:01:00`
  - Diagnosis: PCIe link trained at 2.5 GT/s x4 where card and slot support 16.0 GT/s x4 (slot), on 2 of 2 hosts of the role: a shared cause.
  - Action: Check the BIOS PCIe slot speed and bifurcation profile of Slot 2 before replacing hardware; then reseat the card or riser.
  - Also: The bus is a bottleneck: receive buffer discards keep growing on eth0. Fixing the PCIe link speed should stop the discards; re-check them afterwards.
  - Rules: PCIE-SHARED (P3), PCIE-DISCARDS (modifier) · base P3; raised 1 level(s) by PCIE-DISCARDS

### 7.1 Unexplained, needs review

None: every finding is covered by a recommendation.

---

Generated by nic-report v2.14.0 — © 2026 Ciro Iriarte · 2026-10-27 14:31:27 +00:00
