# nic-health JSON fixtures

`nic-health.sh -O json` documents (schema 2, typed `metrics`) written by the nic-health test suite
(`tests/nic-health-test.sh`, function `dump_json`) from its mocks: a fake sysfs tree, stubbed
`ethtool`, `devlink`, `ip`, `mstlink`/`mlxlink` (the captures in `tests/fixtures/*.txt`) and a mocked
`/proc/net/bonding`. Host names, addresses and times are fictional; no site data.

| File | Scenario |
|---|---|
| `delta-generic.json`, `absolute-generic.json` | Generic checks with a window and without (PCIe, AER, temperature, flaps, devlink, link state) |
| `mlx5-delta.json`, `mlx5-absolute.json` | ConnectX counter rules, with and without a window |
| `mlx5-ber.json`, `mlx5-ber-estimated.json`, `mlx5-ber-pam4.json` | Pre-FEC BER from `rx_bits_phy`, estimated from link speed, and not judged on PAM4 lanes |
| `mlx5-history.json` | Errors high since boot, none in the window |
| `deep-mstlink.json`, `deep-mlxlink.json` | Deep mode, both tools (FEC mismatch, BER, module) |
| `deep-nolink.json`, `deep-qsfp28.json`, `deep-qsfp28-dark.json` | Port without link; multi-lane QSFP28 module, with and without light |
| `p3-link-state.json` | Service impact: bond members with and without link, a spare port, a bridge member with VLAN, VFs and an address |

`tests/test_nic_report.py` checks that nic-report reads the same values from the typed `metrics` as from
the evidence text, record by record, and that its report does not change when `metrics` are removed.

Every `make test` regenerates these documents and fails if they differ from the files here. After a
deliberate change to nic-health's JSON, rewrite them with `make fixtures` and review the diff.
