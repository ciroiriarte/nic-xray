# nic-xray

Detailed physical network interface diagnostics for Linux.

[![Latest Release](https://img.shields.io/github/v/release/ciroiriarte/nic-xray)](https://github.com/ciroiriarte/nic-xray/releases)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

## Table of Contents

- [Description](#-description)
- [Requirements](#%EF%B8%8F-requirements)
- [Installation](#-installation)
- [Usage](#-usage)
- [Output Examples](#-output-examples)
- [License](#-license)
- [Contributing](#-contributing)
- [Authors](#%EF%B8%8F-authors)

## 📝 Description

`nic-xray.sh` is a diagnostic script that provides a detailed overview of all **physical network interfaces** on a Linux system. It displays:

- PCI slot
- Driver name
- Firmware version
- Interface name
- MAC address
- MTU
- Link status (with color)
- Negotiated speed and duplex (color-coded by speed tier)
- Bond membership (with color)
- LLDP peer information (switch and port)
- Optionally: LACP status, VLAN tagging, bond MAC address
- Real-time traffic metrics: bandwidth, packets/s, drops, errors, FIFO errors (with `--metrics`)

Supports multiple output formats: **table** (default, with dynamic column widths), **CSV**, **JSON**, and **network topology diagrams** (DOT/SVG/PNG).

Originally developed for OpenStack node deployments, it is suitable for any Linux environment.

## ⚙️ Requirements

- Must be run as **root**
- Required tools:
  - `ethtool`
  - `lldpctl`
  - `ip`, `awk`, `grep`, `cat`, `readlink`
- Optional tools:
  - `graphviz` (`dot` command) — required for `--output svg` and `--output png`; not needed for `--output dot`
- Switch configuration:
  - Switch should advertise LLDP messages
  - Cisco doesn't include VLAN information by default.
    Hint:
    ```bash
    lldp tlv-select vlan-name
    ```

## 📦 Installation

### Script

Copy to `/usr/local/sbin` for easy access:

```bash
sudo cp nic-xray.sh /usr/local/sbin/
sudo chmod +x /usr/local/sbin/nic-xray.sh
```

### Man page

A man page is available under `man/man8/` for detailed reference (section 8: system administration commands).

**Preview locally** (no installation required):

```bash
man -l man/man8/nic-xray.8
```

**Install system-wide:**

```bash
sudo make install-man
```

After installation, use `man nic-xray` to view the man page.

**Uninstall:**

```bash
sudo make uninstall-man
```

### lldpd service

Ensure lldpd is running to retrieve LLDP information:

```bash
sudo systemctl enable --now lldpd
```

## 🚀 Usage

### Basic

```bash
sudo nic-xray.sh              # Default view
sudo nic-xray.sh --all        # All optional columns at once
sudo nic-xray.sh -h           # Display help
sudo nic-xray.sh -v           # Display version
```

### Optional columns

```bash
sudo nic-xray.sh --lacp       # Show LACP peer information
sudo nic-xray.sh --vlan       # Show VLAN information
sudo nic-xray.sh --bmac       # Show bond MAC address
```

### Traffic metrics

```bash
sudo nic-xray.sh --metrics             # Sample metrics over 30s (default)
sudo nic-xray.sh --metrics=5           # Sample metrics over 5s
sudo nic-xray.sh --metrics --output csv   # Metrics as raw numeric CSV columns
sudo nic-xray.sh --metrics --output json  # Metrics as nested JSON object
```

### Filtering and sorting

```bash
sudo nic-xray.sh --filter-link up      # Only interfaces with link up
sudo nic-xray.sh --filter-link down    # Only interfaces with link down
sudo nic-xray.sh --group-bond          # Group rows by bond
sudo nic-xray.sh --group-bond --all -s # Combined example
```

### Output formats

```bash
sudo nic-xray.sh --output csv                     # CSV output
sudo nic-xray.sh --output csv --separator='|'      # Pipe-delimited CSV
sudo nic-xray.sh --output csv --separator=$'\t'    # Tab-separated CSV
sudo nic-xray.sh --output json                     # JSON output
sudo nic-xray.sh --all --output json               # All columns as JSON
```

### Topology diagrams

```bash
sudo nic-xray.sh --output dot > topology.dot                   # DOT source
sudo nic-xray.sh --output svg                                  # SVG diagram
sudo nic-xray.sh --output png --diagram-out /tmp/network.png   # PNG with custom path
```

### Formatting

```bash
sudo nic-xray.sh -s                # Table with │ column separators
sudo nic-xray.sh --separator='|'   # Table with custom separator
sudo nic-xray.sh --no-color        # Disable color output
```

## 📸 Output Examples

> MAC addresses and hostnames below are obfuscated. Full sample files are available in [`samples/`](samples/).

### Default table

```
$ sudo nic-xray.sh
Device         Driver      Firmware                 Interface   MAC Address         MTU    Link   Speed/Duplex       Parent Bond   Switch Name             Port Name
---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
0000:19:00.0   i40e        9.50 0x8000f25e 23.0.8   eno1np0     XX:XX:XX:XX:XX:01   9100   up     10000Mb/s (Full)   bond0         switch-01.example.net   ifname xe-0/0/2
0000:19:00.1   i40e        9.50 0x8000f25e 23.0.8   eno2np1     XX:XX:XX:XX:XX:02   9100   up     10000Mb/s (Full)   bond1         switch-01.example.net   ifname xe-0/0/3
0000:19:00.2   i40e        9.50 0x8000f25e 23.0.8   eno3np2     XX:XX:XX:XX:XX:03   1500   down   N/A (N/A)          None
0000:19:00.3   i40e        9.50 0x8000f25e 23.0.8   eno4np3     XX:XX:XX:XX:XX:04   1500   down   N/A (N/A)          None
0000:5e:00.0   i40e        9.50 0x8000f251 23.0.8   ens3f0np0   XX:XX:XX:XX:XX:05   9100   up     25000Mb/s (Full)   bond2         switch-01.example.net   ifname et-0/0/38
0000:5e:00.1   i40e        9.50 0x8000f251 23.0.8   ens3f1np1   XX:XX:XX:XX:XX:06   9100   up     25000Mb/s (Full)   bond3         switch-01.example.net   ifname et-0/0/39
0000:86:00.0   i40e        9.50 0x8000f25d 23.0.8   ens5f0np0   XX:XX:XX:XX:XX:07   9100   up     10000Mb/s (Full)   bond0         switch-02.example.net   ifname xe-0/0/2
0000:86:00.1   i40e        9.50 0x8000f25d 23.0.8   ens5f1np1   XX:XX:XX:XX:XX:08   9100   up     10000Mb/s (Full)   bond1         switch-02.example.net   ifname xe-0/0/3
0000:86:00.2   i40e        9.50 0x8000f25d 23.0.8   ens5f2np2   XX:XX:XX:XX:XX:09   1500   down   N/A (N/A)          None
0000:86:00.3   i40e        9.50 0x8000f25d 23.0.8   ens5f3np3   XX:XX:XX:XX:XX:0a   1500   down   N/A (N/A)          None
0000:d8:00.0   i40e        9.50 0x8000f251 23.0.8   ens8f0np0   XX:XX:XX:XX:XX:0b   9100   up     25000Mb/s (Full)   bond2         switch-02.example.net   ifname et-0/0/38
0000:d8:00.1   i40e        9.50 0x8000f251 23.0.8   ens8f1np1   XX:XX:XX:XX:XX:0c   9100   up     25000Mb/s (Full)   bond3         switch-02.example.net   ifname et-0/0/39
1-14.3:1.0     cdc_ether   CDC Ethernet Device      idrac       XX:XX:XX:XX:XX:0d   1500   up     425Mb/s (Half)     None
```

### All columns with separators

```
$ sudo nic-xray.sh --all -s
Device       │ Driver    │ Firmware               │ Interface │ MAC Address       │ MTU  │ Link │ Speed/Duplex     │ Parent Bond │ Bond MAC          │ LACP Status                    │ VLAN                │ Switch Name           │ Port Name
------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
0000:19:00.0 │ i40e      │ 9.50 0x8000f25e 23.0.8 │ eno1np0   │ XX:XX:XX:XX:XX:01 │ 9100 │ up   │ 10000Mb/s (Full) │ bond0       │ XX:XX:XX:XX:XX:01 │ AggID:1 Peer:AA:BB:CC:DD:EE:01 │ 100;101;102;110;111 │ switch-01.example.net │ ifname xe-0/0/2
0000:19:00.1 │ i40e      │ 9.50 0x8000f25e 23.0.8 │ eno2np1   │ XX:XX:XX:XX:XX:02 │ 9100 │ up   │ 10000Mb/s (Full) │ bond1       │ XX:XX:XX:XX:XX:02 │ AggID:1 Peer:AA:BB:CC:DD:EE:02 │ 200;201;202;211;212 │ switch-01.example.net │ ifname xe-0/0/3
0000:19:00.2 │ i40e      │ 9.50 0x8000f25e 23.0.8 │ eno3np2   │ XX:XX:XX:XX:XX:03 │ 1500 │ down │ N/A (N/A)        │ None        │ N/A               │ N/A                            │ N/A                 │                       │
...
```

### Filtering — link down only

```
$ sudo nic-xray.sh --filter-link down
Device         Driver   Firmware                 Interface   MAC Address         MTU    Link   Speed/Duplex   Parent Bond   Switch Name   Port Name
---------------------------------------------------------------------------------------------------------------------------------------------------
0000:19:00.2   i40e     9.50 0x8000f25e 23.0.8   eno3np2     XX:XX:XX:XX:XX:03   1500   down   N/A (N/A)      None
0000:19:00.3   i40e     9.50 0x8000f25e 23.0.8   eno4np3     XX:XX:XX:XX:XX:04   1500   down   N/A (N/A)      None
0000:86:00.2   i40e     9.50 0x8000f25d 23.0.8   ens5f2np2   XX:XX:XX:XX:XX:09   1500   down   N/A (N/A)      None
0000:86:00.3   i40e     9.50 0x8000f25d 23.0.8   ens5f3np3   XX:XX:XX:XX:XX:0a   1500   down   N/A (N/A)      None
```

### Traffic metrics table

```
$ sudo nic-xray.sh --all --metrics=2
Device         Driver      Firmware                 Interface   MAC Address         MTU    Link   Speed/Duplex       Parent Bond   Bond MAC            LACP Status                      VLAN                  Bandwidth                    Packets/s         Drops       Errors      FIFO Errors   Switch Name             Port Name
-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
0000:19:00.0   i40e        9.50 0x8000f25e 23.0.8   eno1np0     XX:XX:XX:XX:XX:01   9100   up     10000Mb/s (Full)   bond0         XX:XX:XX:XX:XX:01   AggID:1 Peer:AA:BB:CC:DD:EE:01   100;101;102;110;111   Rx:1.0 KB/s Tx:1.6 KB/s      Rx:5 Tx:9         Rx:0 Tx:0   Rx:0 Tx:0   Rx:0 Tx:0     switch-01.example.net   ifname xe-0/0/2
0000:5e:00.1   i40e        9.50 0x8000f251 23.0.8   ens3f1np1   XX:XX:XX:XX:XX:06   9100   up     25000Mb/s (Full)   bond3         XX:XX:XX:XX:XX:06   AggID:1 Peer:AA:BB:CC:DD:EE:04   502                   Rx:4.9 MB/s Tx:1.1 MB/s      Rx:2228 Tx:2084   Rx:0 Tx:0   Rx:0 Tx:0   Rx:0 Tx:0     switch-01.example.net   ifname et-0/0/39
...

📊 Metrics sampled over 2s
```

### CSV output

```
$ sudo nic-xray.sh --output csv
Device,Driver,Firmware,Interface,MAC Address,MTU,Link,Speed/Duplex,Parent Bond,Switch Name,Port Name
0000:19:00.0,i40e,9.50 0x8000f25e 23.0.8,eno1np0,XX:XX:XX:XX:XX:01,9100,up,10000Mb/s (Full),bond0,switch-01.example.net,ifname xe-0/0/2
0000:19:00.1,i40e,9.50 0x8000f25e 23.0.8,eno2np1,XX:XX:XX:XX:XX:02,9100,up,10000Mb/s (Full),bond1,switch-01.example.net,ifname xe-0/0/3
0000:19:00.2,i40e,9.50 0x8000f25e 23.0.8,eno3np2,XX:XX:XX:XX:XX:03,1500,down,N/A (N/A),None,,
...
```

### CSV with metrics

```
$ sudo nic-xray.sh --all --metrics=2 --output csv
Device,Driver,Firmware,Interface,MAC Address,MTU,Link,Speed/Duplex,Parent Bond,Bond MAC,LACP Status,VLAN,Rx Bytes/s,Tx Bytes/s,Rx Packets/s,Tx Packets/s,Rx Drops,Tx Drops,Rx Errors,Tx Errors,Rx FIFO Errors,Tx FIFO Errors,Sample Duration,Switch Name,Port Name
0000:19:00.0,i40e,9.50 0x8000f25e 23.0.8,eno1np0,XX:XX:XX:XX:XX:01,9100,up,10000Mb/s (Full),bond0,XX:XX:XX:XX:XX:01,AggID:1 Peer:AA:BB:CC:DD:EE:01,100;101;102;110;111,183,576,1,5,0,0,0,0,0,0,2,switch-01.example.net,ifname xe-0/0/2
0000:5e:00.1,i40e,9.50 0x8000f251 23.0.8,ens3f1np1,XX:XX:XX:XX:XX:06,9100,up,25000Mb/s (Full),bond3,XX:XX:XX:XX:XX:06,AggID:1 Peer:AA:BB:CC:DD:EE:04,502,2357503,1490113,1095,1089,0,0,0,0,0,0,2,switch-01.example.net,ifname et-0/0/39
...
```

### JSON output

```
$ sudo nic-xray.sh --output json --all
[
  {
    "device": "0000:19:00.0",
    "driver": "i40e",
    "firmware": "9.50 0x8000f25e 23.0.8",
    "interface": "eno1np0",
    "mac_address": "XX:XX:XX:XX:XX:01",
    "mtu": 9100,
    "link": "up",
    "speed_duplex": "10000Mb/s (Full)",
    "parent_bond": "bond0",
    "bond_mac": "XX:XX:XX:XX:XX:01",
    "lacp_status": "AggID:1 Peer:AA:BB:CC:DD:EE:01",
    "vlan": "100;101;102;110;111",
    "switch_name": "switch-01.example.net",
    "port_name": "ifname xe-0/0/2"
  },
  ...
]
```

### JSON with metrics

```
$ sudo nic-xray.sh --all --metrics=2 --output json
[
  {
    "device": "0000:19:00.0",
    ...
    "metrics": {
      "sample_duration_seconds": 2,
      "rx_bytes_per_sec": 304,
      "tx_bytes_per_sec": 658,
      "rx_packets_per_sec": 3,
      "tx_packets_per_sec": 6,
      "rx_drops": 0,
      "tx_drops": 0,
      "rx_errors": 0,
      "tx_errors": 0,
      "rx_fifo_errors": 0,
      "tx_fifo_errors": 0
    },
    "switch_name": "switch-01.example.net",
    "port_name": "ifname xe-0/0/2"
  },
  ...
]
```

### Topology diagram (DOT)

```bash
sudo nic-xray.sh --output dot > topology.dot    # Generate DOT source
sudo nic-xray.sh --output svg                    # Render SVG (requires graphviz)
sudo nic-xray.sh --output png                    # Render PNG (requires graphviz)
```

The diagram shows server NICs grouped by bond (color-coded), connected to switch ports, with MAC addresses and MTU. VLAN information appears near the NIC end of each link and negotiated speed tier near the switch port end. PVID is bold+underlined to distinguish it from tagged VLANs. Edge thickness scales with link speed.

![Topology diagram](samples/topology.png)

See also: [`samples/topology.dot`](samples/topology.dot) | [`samples/topology.svg`](samples/topology.svg)

When `--metrics` is active, each NIC node also shows real-time bandwidth (with `↓`/`↑` arrows). If any drops, errors, or FIFO errors are detected during sampling, they are shown in red.

![Topology diagram with metrics](samples/topology-metrics.png)

See also: [`samples/topology-metrics.dot`](samples/topology-metrics.dot) | [`samples/topology-metrics.svg`](samples/topology-metrics.svg)

## 📄 License

This project is licensed under the GNU General Public License v3.0. See [LICENSE](LICENSE) for details.

## 🤝 Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## ✍️ Authors

**Ciro Iriarte**

- **Created**: 2025-06-05
- **Updated**: 2026-03-01
