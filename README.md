# nic-xray

Detailed physical network interface diagnostics for Linux.

## 📦 Latest Release: [v2.2](https://github.com/ciroiriarte/nic-xray/releases/tag/v2.2)

| Script | Version |
|---|---|
| `nic-xray.sh` | 2.2 |

Supports `--version` / `-v` and `--help` / `-h` flags.

---

## 📝 Description

**Author**: Ciro Iriarte
**Created**: 2025-06-05
**Updated**: 2026-02-27

`nic-xray.sh` is a diagnostic script that provides a detailed overview of all **physical network interfaces** on a Linux system. It displays:

- PCI slot
- Driver name
- Firmware version
- Interface name
- MAC address
- MTU
- Link status (with color)
- Negotiated speed and duplex (color-coded by tier: 200G magenta, 100G cyan, 25G/40G/50G white, 10G green, 1G yellow, <1G/unknown red)
- Bond membership (with color)
- LLDP peer information (switch and port)
- Optionally: LACP status, VLAN tagging, bond MAC address

Supports multiple output formats: **table** (default, with dynamic column widths), **CSV**, **JSON**, and **network topology diagrams** (DOT/SVG/PNG).

Originally developed for OpenStack node deployments, it is suitable for any Linux environment.

---

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

---

## 💡 Recommendations

- Copy the script to `/usr/local/sbin` for easy access:
  ```bash
  sudo cp nic-xray.sh /usr/local/sbin/
  sudo chmod +x /usr/local/sbin/nic-xray.sh
  ```

- Ensure lldpd service is running to retrieve LLDP information:
  ```bash
  sudo systemctl enable --now lldpd
  ```

---

## 📖 Man Page

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

---

## 🚀 Usage

Default view:

```bash
sudo nic-xray.sh
```

Show VLAN information:

```bash
sudo nic-xray.sh --vlan
```

Show LACP peer information:

```bash
sudo nic-xray.sh --lacp
```

Show bond MAC address:

```bash
sudo nic-xray.sh --bmac
```

Table output with `│` column separators:

```bash
sudo nic-xray.sh -s
sudo nic-xray.sh --separator
```

Table output with a custom separator:

```bash
sudo nic-xray.sh --separator='|'
```

CSV output:

```bash
sudo nic-xray.sh --output csv
```

Pipe-delimited CSV:

```bash
sudo nic-xray.sh --output csv --separator='|'
```

Tab-separated CSV:

```bash
sudo nic-xray.sh --output csv --separator=$'\t'
```

JSON output:

```bash
sudo nic-xray.sh --output json
```

All optional columns with JSON output:

```bash
sudo nic-xray.sh --vlan --lacp --bmac --output json
```

Generate DOT source for external rendering:

```bash
sudo nic-xray.sh --output dot > topology.dot
```

Generate an SVG network topology diagram:

```bash
sudo nic-xray.sh --output svg
```

Generate a PNG diagram with custom output path:

```bash
sudo nic-xray.sh --output png --diagram-out /tmp/network.png
```

Show all optional columns at once:

```bash
sudo nic-xray.sh --all
```

Group rows by bond (bonded interfaces first, then unbonded):

```bash
sudo nic-xray.sh --group-bond
sudo nic-xray.sh --group-bond --all -s
```

Show only interfaces with link up:

```bash
sudo nic-xray.sh --filter-link up
```

Show only interfaces with link down:

```bash
sudo nic-xray.sh --filter-link down
```

Disable color output:

```bash
sudo nic-xray.sh --no-color
```

Display version:

```bash
sudo nic-xray.sh -v
sudo nic-xray.sh --version
```

Display help:

```bash
sudo nic-xray.sh -h
sudo nic-xray.sh --help
```
