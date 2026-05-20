# Virtual Interfaces Implementation Plan (`--virtual` flag)

> **Status**: Design — pending implementation  
> **Branch**: `feature/physical-topology` → new branch `feature/virtual-interfaces`  
> **Produced by**: CCG tri-model analysis (Codex + Gemini + Claude synthesis)

---

## 1. Scope & Interface Taxonomy

The `--virtual` flag exposes all logical network devices currently excluded by
`IFACE_SKIP_PATTERN` and the `/sys/class/net/$IFACE/device` physical gate.

### 1.1 Complete Type Table

| Type code  | Display  | Icon (help/prose only) | Detection                                                                 | Encap overhead |
|------------|----------|------------------------|---------------------------------------------------------------------------|----------------|
| `physical` | `PHY`    | —                      | `/sys/class/net/$IFACE/device` symlink exists                             | 0 B            |
| `vlan`     | `VLAN`   | 🏷                     | `/proc/net/vlan/$IFACE` exists, or uevent `DEVTYPE=vlan`                  | 4 B            |
| `bridge`   | `BR`     | 🌉                     | `/sys/class/net/$IFACE/bridge/` dir exists (not OvS)                      | 0 B            |
| `ovs-br`   | `OVS`    | 🔀                     | bridge dir + `ovs-vsctl list-br` lists the interface                      | 0 B            |
| `vxlan`    | `VXLAN`  | 🌌                     | `/sys/class/net/$IFACE/vxlan/` dir, or uevent `DEVTYPE=vxlan`             | 50 B           |
| `geneve`   | `GENEVE` | 🧬                     | `/sys/class/net/$IFACE/geneve/` dir, or uevent `DEVTYPE=geneve`           | 50 B (min)     |
| `gre`      | `GRE`    | 🚇                     | sysfs `type`=778 (GRE), 779 (GRETAP), 776 (IPIP), 768, 769               | 24 B (worst)   |
| `tap`      | `TAP`    | 💻                     | `/sys/class/net/$IFACE/tun_flags` & flags bit 0 set (0x0001)              | 0 B            |
| `tun`      | `TUN`    | 🔌                     | `/sys/class/net/$IFACE/tun_flags` & flags bit 1 set (0x0002)              | 0 B            |
| `veth`     | `VETH`   | 🔗                     | `/sys/class/net/$IFACE/peer_ifindex` exists                               | 0 B            |
| `wireguard`| `WG`     | 🔐                     | uevent `DEVTYPE=wireguard` or `/sys/class/net/$IFACE/wireguard/` dir      | 60 B           |
| `vpn`      | `VPN`    | 🛡                     | name matches `^zt[0-9a-zA-Z]{10}$` (ZeroTier)                            | ~80 B (approx) |
| `bond`     | `BOND`   | ⛓                     | `/proc/net/bonding/$IFACE` exists                                         | 0 B            |
| `dummy`    | `DUMMY`  | —                      | uevent `DEVTYPE=dummy`                                                    | 0 B            |

Icons appear only in `--help` text and documentation, not in table cells — consistent
with the existing script style.

### 1.2 Platform-Specific Naming Families

| Platform            | Interface name pattern    | Classified as                          |
|---------------------|---------------------------|----------------------------------------|
| Proxmox VE          | `vmbr*`                   | `bridge`                               |
| Proxmox VE          | `tap<vmid>i<n>`           | `tap` (VM tap, parent = vmbr)          |
| Proxmox VE          | `fwbr<vmid>i<n>`          | `bridge` (PVE firewall bridge)         |
| Proxmox VE          | `fwln<vmid>i<n>`          | `veth` (PVE firewall link)             |
| Proxmox VE          | `veth<vmid>.<port>`       | `veth` (LXC container)                 |
| ZeroTier            | `zt[0-9a-zA-Z]{10}`       | `vpn` (no parent — UDP overlay)        |
| OvS / OpenStack     | `br-int`, `br-ex`, `br-tun`, `br-provider` | `ovs-br`              |
| OvS / OpenStack     | `ovs-system`              | **always skip**                        |
| OvS / OpenStack     | `patch-*`                 | `veth` (OvS patch port)                |
| Docker              | `docker0`, `br-<id>`      | `bridge` (skipped unless `--virtual`)  |
| libvirt / KVM       | `virbr*`, `vnet*`         | `bridge` / `tap` (skipped unless `--virtual`) |

### 1.3 Known Scope Limitation: Network Namespaces

OpenStack Neutron places `qr-*`, `qg-*`, `ha-*` interfaces inside per-router and
per-DHCP network namespaces (`qrouter-<UUID>`, `qdhcp-<UUID>`). These are not
visible from the root namespace `/sys/class/net/` and are **out of scope** for this
implementation. Document this clearly in `--help` and the man page.

---

## 2. Flag Definition

```bash
# Default (near line 106, with other flag defaults):
SHOW_VIRTUAL=false

# Skip pattern used when --virtual is active — much shorter than the physical default:
VIRTUAL_SKIP_PATTERN='^(lo|ovs-system)$'
```

### 2.1 Argument Parsing Changes

In the `getopt` string add `-V` (short) and `--virtual` (long, no argument):

```bash
# getopt line: add ,virtual to --long list; add V to short opts
if ! OPTIONS=$(getopt -o hvs::m::ow::pV \
    --long help,version,lacp,vlan,bmac,optics,physical,virtual,separator::,...
```

In the `case` block:

```bash
-V|--virtual)
    SHOW_VIRTUAL=true
    shift
    ;;
```

`--all` does **not** auto-enable `--virtual`. Virtual stacks on hypervisors can be
very large; opt-in is deliberate.

---

## 3. New Data Arrays

Append after the existing `DATA_NUMA`/`DATA_PCI_SLOT` declarations (line ~972):

```bash
declare -a DATA_VIRT_TYPE           # type code: vlan, bridge, ovs-br, vxlan, tap, tun,
                                    #   veth, gre, wireguard, vpn, bond, physical
declare -a DATA_VIRT_PARENT         # parent iface name, or "—" if root
declare -a DATA_VIRT_ENCAP_OVERHEAD # integer bytes of encapsulation overhead this layer adds
declare -a DATA_MTU_WARN            # "" = OK | "FRAG" = fragmentation risk | "DROP" = likely broken
declare -a DATA_VIRT_DEPTH          # integer tree depth (0 = physical/root, 1 = direct child, …)
declare -a DATA_IS_PHYSICAL         # "true"/"false" — gates ethtool, optics, LLDP, --physical blocks
```

Internal maps (not rendered, used for MTU computation):

```bash
declare -A IFACE_MTU_MAP            # iface → MTU integer
declare -A IFACE_OVERHEAD_MAP       # iface → encap overhead integer
declare -A IFACE_PARENT_MAP         # iface → parent iface name
declare -A IFACE_EFFECTIVE_MTU      # iface → computed effective payload MTU (memoized)
```

Reset all new arrays in the reset block at the top of `collect_data()` (~line 983).

---

## 4. New Helper Functions

### 4.1 `enumerate_ifaces()`

Single source of truth for both the metrics snapshot loop and the main collection
loop. Replaces all open-coded `/sys/class/net/*` scans.

```bash
enumerate_ifaces() {
    ENUM_IFACES=()
    local _SKIP_PAT
    if $SHOW_VIRTUAL; then
        _SKIP_PAT="$VIRTUAL_SKIP_PATTERN"
    else
        _SKIP_PAT="$IFACE_SKIP_PATTERN"
    fi

    for _IFACE_PATH in /sys/class/net/*; do
        local _IFACE="${_IFACE_PATH##*/}"
        [[ "$_IFACE" =~ $_SKIP_PAT ]] && continue

        if ! $SHOW_VIRTUAL; then
            # Physical-only gates (existing behavior)
            [[ "$_IFACE" == *.* ]] && continue
            [[ ! -e "/sys/class/net/$_IFACE/device" ]] && continue
        fi
        ENUM_IFACES+=("$_IFACE")
    done
}
```

Call once before snapshot 1. The metrics snapshot uses
`METRICS_IFACES=("${ENUM_IFACES[@]}")` — no separate scan.

### 4.2 `detect_virtual_type()`

Sets globals `VIRT_TYPE` and `IS_PHYSICAL`.

```bash
detect_virtual_type() {
    local IFACE="$1"
    IS_PHYSICAL=false
    VIRT_TYPE="unknown"

    # Physical gate
    if [[ -e "/sys/class/net/$IFACE/device" ]]; then
        IS_PHYSICAL=true
        VIRT_TYPE="physical"
        return
    fi

    # Bond master
    [[ -f "/proc/net/bonding/$IFACE" ]] && { VIRT_TYPE="bond"; return; }

    # VLAN
    if [[ -r "/proc/net/vlan/$IFACE" ]]; then
        VIRT_TYPE="vlan"; return
    fi
    local _DEVTYPE=""
    [[ -r "/sys/class/net/$IFACE/uevent" ]] && \
        _DEVTYPE=$(awk -F= '/^DEVTYPE=/{print $2}' "/sys/class/net/$IFACE/uevent")
    [[ "$_DEVTYPE" == "vlan" ]] && { VIRT_TYPE="vlan"; return; }

    # OvS bridge (check before plain bridge — OvS bridges also have bridge/ dir)
    if [[ -d "/sys/class/net/$IFACE/bridge" ]] && command -v ovs-vsctl &>/dev/null; then
        if ovs-vsctl list-br 2>/dev/null | grep -qx "$IFACE"; then
            VIRT_TYPE="ovs-br"; return
        fi
    fi

    # Linux bridge
    [[ -d "/sys/class/net/$IFACE/bridge" ]] && { VIRT_TYPE="bridge"; return; }

    # Tun/Tap
    if [[ -r "/sys/class/net/$IFACE/tun_flags" ]]; then
        local _FLAGS
        _FLAGS=$(< "/sys/class/net/$IFACE/tun_flags")
        _FLAGS=$(( 16#${_FLAGS#0x} ))
        (( (_FLAGS & 0x0001) != 0 )) && { VIRT_TYPE="tap"; return; }
        VIRT_TYPE="tun"; return
    fi

    # VXLAN
    if [[ -d "/sys/class/net/$IFACE/vxlan" || "$_DEVTYPE" == "vxlan" ]]; then
        VIRT_TYPE="vxlan"; return
    fi

    # Geneve
    if [[ -d "/sys/class/net/$IFACE/geneve" || "$_DEVTYPE" == "geneve" ]]; then
        VIRT_TYPE="geneve"; return
    fi

    # GRE / IPIP via sysfs type number
    local _SYSFS_TYPE=0
    [[ -r "/sys/class/net/$IFACE/type" ]] && _SYSFS_TYPE=$(< "/sys/class/net/$IFACE/type")
    case "$_SYSFS_TYPE" in
        778|779|11|768|769|776) VIRT_TYPE="gre"; return ;;
    esac

    # WireGuard
    if [[ "$_DEVTYPE" == "wireguard" || -d "/sys/class/net/$IFACE/wireguard" ]]; then
        VIRT_TYPE="wireguard"; return
    fi

    # ZeroTier: name = zt + exactly 10 alphanumeric chars
    if [[ "$IFACE" =~ ^zt[0-9a-zA-Z]{10}$ ]]; then
        VIRT_TYPE="vpn"; return
    fi

    # veth
    [[ -r "/sys/class/net/$IFACE/peer_ifindex" ]] && { VIRT_TYPE="veth"; return; }

    # Dummy
    [[ "$_DEVTYPE" == "dummy" ]] && { VIRT_TYPE="dummy"; return; }

    VIRT_TYPE="virtual"  # unknown virtual — still collect stats
}
```

### 4.3 `detect_virtual_parent()`

Sets global `VIRT_PARENT` (iface name or `"—"`).

```bash
detect_virtual_parent() {
    local IFACE="$1"
    local TYPE="$2"
    VIRT_PARENT="—"

    # VLAN: preferred source is /proc/net/vlan/config
    if [[ "$TYPE" == "vlan" && -r "/proc/net/vlan/config" ]]; then
        local _P
        _P=$(awk -v iface="$IFACE" '$1==iface {print $NF}' /proc/net/vlan/config)
        [[ -n "$_P" ]] && { VIRT_PARENT="$_P"; return; }
    fi

    # master symlink (works for bridge members, bond members)
    if [[ -L "/sys/class/net/$IFACE/master" ]]; then
        local _MASTER
        _MASTER=$(basename "$(readlink -f "/sys/class/net/$IFACE/master")")
        # Accept master only if it is a bond (not a bridge — bridge membership
        # is captured separately via VIRT_PARENT for the tap/veth child)
        VIRT_PARENT="$_MASTER"; return
    fi

    # Generic: first lower_* symlink
    local _LOWER
    for _LOWER in /sys/class/net/"$IFACE"/lower_*; do
        [[ -e "$_LOWER" ]] || continue
        VIRT_PARENT="${_LOWER##*/lower_}"
        return
    done

    # ZeroTier and WireGuard have no sysfs parent — leave as "—"
}
```

### 4.4 `compute_encap_overhead()`

Sets global `VIRT_ENCAP` (integer bytes).

```bash
compute_encap_overhead() {
    local TYPE="$1"
    case "$TYPE" in
        vlan)       VIRT_ENCAP=4  ;;    # 802.1Q tag
        vxlan)      VIRT_ENCAP=50 ;;    # 14 ETH + 20 IP + 8 UDP + 8 VXLAN
        geneve)     VIRT_ENCAP=50 ;;    # minimum; options make it larger
        gre)        VIRT_ENCAP=24 ;;    # worst-case: 20 IP + 4 GRE min + flags
        wireguard)  VIRT_ENCAP=60 ;;    # 20 IP + 8 UDP + 32 WireGuard header
        vpn)        VIRT_ENCAP=80 ;;    # ZeroTier approx; documented as estimate
        bridge|tap|tun|veth|bond|ovs-br|dummy|virtual|physical) VIRT_ENCAP=0 ;;
        *)          VIRT_ENCAP=0 ;;
    esac
}
```

### 4.5 `compute_effective_mtu()`

Recursive, memoized. Walk the lower chain to compute the effective payload MTU
visible to traffic at each layer.

```bash
# Output: effective payload MTU integer via stdout
# Side-effect: populates IFACE_EFFECTIVE_MTU[$IFACE]
compute_effective_mtu() {
    local IFACE="$1"

    # Memoized
    [[ -n "${IFACE_EFFECTIVE_MTU[$IFACE]+x}" ]] && {
        printf '%s' "${IFACE_EFFECTIVE_MTU[$IFACE]}"
        return
    }

    local MY_MTU="${IFACE_MTU_MAP[$IFACE]:-1500}"
    local PARENT="${IFACE_PARENT_MAP[$IFACE]:-}"
    local OVERHEAD="${IFACE_OVERHEAD_MAP[$IFACE]:-0}"

    if [[ -z "$PARENT" || "$PARENT" == "—" ]]; then
        IFACE_EFFECTIVE_MTU[$IFACE]="$MY_MTU"
    else
        local PARENT_EFF
        PARENT_EFF=$(compute_effective_mtu "$PARENT")
        local EFF=$(( PARENT_EFF - OVERHEAD ))
        (( EFF < MY_MTU )) && MY_MTU="$EFF"
        IFACE_EFFECTIVE_MTU[$IFACE]="$MY_MTU"
    fi
    printf '%s' "${IFACE_EFFECTIVE_MTU[$IFACE]}"
}
```

Warning thresholds (set in the post-collection pass):

- `EFF < 576` → `DATA_MTU_WARN="DROP"` — below minimum IP datagram; communication
  likely broken
- `EFF < 1500` → `DATA_MTU_WARN="FRAG"` — fragmentation risk for standard-MTU peers
- Otherwise → `DATA_MTU_WARN=""`

**ZeroTier exception**: suppress `FRAG` for `vpn` type interfaces unless `EFF < 576`.
ZeroTier intentionally configures MTU 2800 (ZT handles fragmentation internally);
this is expected behavior, not a misconfiguration.

---

## 5. Modifications to `collect_data()`

### 5.1 Replace the metrics snapshot loop (line ~1039)

Before:
```bash
for _IFACE in /sys/class/net/*; do
    _IFACE="${_IFACE##*/}"
    [[ "$_IFACE" =~ $IFACE_SKIP_PATTERN ]] && continue
    [[ "$_IFACE" == *.* ]] && continue
    [[ ! -e "/sys/class/net/$_IFACE/device" ]] && continue
    METRICS_IFACES+=("$_IFACE")
done
```

After:
```bash
enumerate_ifaces
METRICS_IFACES=("${ENUM_IFACES[@]}")
```

### 5.2 Replace the main enumeration loop header (line ~1055)

Replace `for _IFACE_PATH in /sys/class/net/*; do` and its gates with:

```bash
for IFACE in "${ENUM_IFACES[@]}"; do
    detect_virtual_type "$IFACE"
    [[ "$VIRT_TYPE" == "skip" ]] && continue

    detect_virtual_parent "$IFACE" "$VIRT_TYPE"
    compute_encap_overhead "$VIRT_TYPE"

    # Populate internal maps for deferred MTU computation
    IFACE_MTU_MAP[$IFACE]=$(read_sysfs "$IFACE" mtu)
    IFACE_PARENT_MAP[$IFACE]="$VIRT_PARENT"
    IFACE_OVERHEAD_MAP[$IFACE]="$VIRT_ENCAP"
```

### 5.3 Gate physical-only blocks on `IS_PHYSICAL`

**Physical topology block** (line ~1066):
```bash
if $SHOW_PHYSICAL && $IS_PHYSICAL; then
    # ... existing NUMA / PCI slot / NIC vendor block unchanged ...
else
    PHYS_NUMA="N/A"; PHYS_PCI_SLOT="N/A"
    PHYS_NIC_VENDOR="N/A"; PHYS_NIC_MODEL="N/A"
fi
```

**`DEVICE` path** (line ~1063):
```bash
if $IS_PHYSICAL; then
    DEVICE=$(basename "$(readlink -f "/sys/class/net/$IFACE/device")")
else
    DEVICE="virtual"
fi
```

**ethtool** (lines ~1108, ~1127): use a safe wrapper — virtual ifaces may return
nothing or error:
```bash
ETHTOOL_I=""
if $IS_PHYSICAL || ethtool -i "$IFACE" &>/dev/null; then
    ETHTOOL_I=$(ethtool -i "$IFACE" 2>/dev/null)
fi
FIRMWARE=$(echo "$ETHTOOL_I" | awk -F': ' '/firmware-version/ {print $2}')
FIRMWARE="${FIRMWARE:-N/A}"
DRIVER=$(echo "$ETHTOOL_I" | awk -F': ' '/^driver:/ {print $2}')
DRIVER="${DRIVER:-N/A}"

ETHTOOL_OUT=""
$IS_PHYSICAL && ETHTOOL_OUT=$(ethtool "$IFACE" 2>/dev/null)
SPEED=$(echo "$ETHTOOL_OUT" | awk -F': ' '/Speed:/ {print $2}' | sed 's/Unknown.*/N\/A/')
DUPLEX=$(echo "$ETHTOOL_OUT" | awk -F': ' '/Duplex:/ {print $2}' | sed 's/Unknown.*/N\/A/')
SPEED_DUPLEX="${SPEED:-N/A} (${DUPLEX:-N/A})"
```

**Optics**: gate on `$IS_PHYSICAL`:
```bash
if $SHOW_OPTICS && $IS_PHYSICAL; then
    # ... existing optics block unchanged ...
else
    OPTICS_TYPE="N/A"
    OPT_TX_PLAIN="N/A"; OPT_TX_COLOR="N/A"
    OPT_RX_PLAIN="N/A"; OPT_RX_COLOR="N/A"
    # ... zero other OPTICS_* vars ...
fi
```

**LLDP**: virtual ifaces have no LLDP peers:
```bash
if $IS_PHYSICAL; then
    # ... existing LLDP block unchanged ...
else
    SWITCH_NAME=""; PORT_NAME=""; PORT_DESCR="N/A"
    LLDP_AGGID="N/A"; VLAN_INFO="N/A"
fi
```

**Bond/master logic** (line ~1132): `master` may now be a bridge, not a bond.
Distinguish them:
```bash
BOND_MASTER="None"
if [[ -L "/sys/class/net/$IFACE/master" ]]; then
    local _MASTER
    _MASTER=$(basename "$(readlink -f "/sys/class/net/$IFACE/master")")
    # Only treat as bond master if it is actually a bond
    [[ -f "/proc/net/bonding/$_MASTER" ]] && BOND_MASTER="$_MASTER"
fi
```

### 5.4 Store new arrays (line ~1285)

```bash
DATA_VIRT_TYPE[ROW_COUNT]="$VIRT_TYPE"
DATA_VIRT_PARENT[ROW_COUNT]="$VIRT_PARENT"
DATA_VIRT_ENCAP_OVERHEAD[ROW_COUNT]="$VIRT_ENCAP"
DATA_IS_PHYSICAL[ROW_COUNT]="$IS_PHYSICAL"
# DATA_MTU_WARN set in post-collection pass below
```

### 5.5 Post-collection MTU warning pass

After the main loop closes, before sort/render:

```bash
if $SHOW_VIRTUAL; then
    for (( i = 0; i < ROW_COUNT; i++ )); do
        local _EFF
        _EFF=$(compute_effective_mtu "${DATA_IFACE[$i]}")
        local _TYPE="${DATA_VIRT_TYPE[$i]}"
        if (( _EFF < 576 )); then
            DATA_MTU_WARN[$i]="DROP"
        elif (( _EFF < 1500 )) && [[ "$_TYPE" != "vpn" ]]; then
            DATA_MTU_WARN[$i]="FRAG"
        else
            DATA_MTU_WARN[$i]=""
        fi
    done
fi
```

### 5.6 No-interface guard (line ~1332)

Change message to:
```bash
echo "No matching network interfaces found." >&2
```

---

## 6. Render-Side Changes

### 6.1 Table Output

**New columns** (active only when `--virtual` is set):

| Column   | Header   | Width    | Notes |
|----------|----------|----------|-------|
| `Type`   | `Type`   | 6        | `PHY`, `VLAN`, `BR`, `OVS`, `VXLAN`, `GENEVE`, `GRE`, `TAP`, `TUN`, `VETH`, `WG`, `VPN`, `BOND` |
| `Parent` | `Parent` | dynamic  | Always in CSV/JSON; table only with `--virtual` |
| `Encap`  | `Encap`  | 5        | bytes; `0` shown as `—` to reduce noise |
| `W`      | `W`      | 1        | MTU warning: `!` (FRAG, yellow), `✗` (DROP, red), ` ` (OK) |

**Tree indentation in the Interface column** (table only):

Build a depth map before rendering by walking `IFACE_PARENT_MAP`. Root interfaces
(no parent or parent not in the dataset) = depth 0. Use UTF-8 tree characters:

```
Interface
eth0               ← depth 0 (physical)
├─ eth0.100        ← depth 1
│  └─ br0          ← depth 2
│     ├─ tap100i0  ← depth 3
│     └─ tap101i0  ← depth 3
└─ vxlan0  !       ← depth 1, FRAG warning in W column
```

`max_width()` already counts visible characters after strip_ansi; UTF-8 tree
characters are multi-byte but single-column — account for this when computing
column width by measuring display columns, not byte length.

**MTU column coloring** (existing column, enhanced):

- `DATA_MTU_WARN == "FRAG"` → render MTU value in `$YELLOW`
- `DATA_MTU_WARN == "DROP"` → render MTU value in `$RED` (bold)

**CSV/JSON**: add fields `type`, `parent`, `encap_overhead_bytes`, `mtu_warn`.

### 6.2 DOT Diagram

#### Colors (Catppuccin Mocha)

Declare near the top of `generate_dot()`:

```bash
local VIRT_COLOR_VLAN="#fab387"      # Peach
local VIRT_COLOR_BRIDGE="#cba6f7"    # Mauve
local VIRT_COLOR_OVS="#b4befe"       # Lavender (distinct from bridge)
local VIRT_COLOR_VXLAN="#74c7ec"     # Sapphire
local VIRT_COLOR_GENEVE="#89b4fa"    # Blue
local VIRT_COLOR_GRE="#f2cdcd"       # Flamingo
local VIRT_COLOR_TAP="#94e2d5"       # Teal
local VIRT_COLOR_TUN="#89dceb"       # Sky
local VIRT_COLOR_VETH="#a6e3a1"      # Green
local VIRT_COLOR_WG="#cdd6f4"        # Text (WireGuard neutral)
local VIRT_COLOR_VPN="#eba0ac"       # Maroon (ZeroTier, distinct overlay)
local VIRT_EDGE_COLOR="#585b70"      # Surface2 (logical edges)
local VIRT_WARN_COLOR="#f38ba8"      # Red (MTU warning edges/nodes)
```

#### Node Shapes

| Type          | `shape`           | `style`              |
|---------------|-------------------|----------------------|
| bridge/ovs-br | `rectangle`       | `rounded,dashed`     |
| vlan          | `hexagon`         | `filled`             |
| vxlan/geneve  | `diamond`         | `filled`             |
| tap/tun       | `folder`          | `filled`             |
| veth          | `parallelogram`   | `filled`             |
| wireguard/vpn | `doubleoctagon`   | `filled`             |

#### Edges

- Physical NIC → child virtual: `style=dotted`, `color=VIRT_EDGE_COLOR`, `penwidth=1`
- Virtual → child virtual: `style=dashed`, `color=VIRT_EDGE_COLOR`, `penwidth=1`
- Any edge leading **to** an interface with `DATA_MTU_WARN != ""`:
  `color=VIRT_WARN_COLOR`, `penwidth=2`

#### Virtual Subgraph

When `--virtual` is active in DOT mode, wrap virtual children of each physical NIC
in a subgraph:

```dot
subgraph cluster_virt_eth0 {
    label="Virtual Stack (eth0)"
    style=dashed
    color="#45475a"       // Surface1
    fontcolor="#cdd6f4"   // Text
    ...
}
```

---

## 7. High-Cardinality Collapsing (Proxmox VE and Similar Hypervisors)

On a busy Proxmox host, `vmbr0` may have 60 or more `tap*` children. Rendering each
as an individual DOT node produces an unreadable diagram.

### Collapsing Rule

**Collapse a group of same-type children only when all members share
`DATA_MTU_WARN == ""`.**

If any member has a non-empty `DATA_MTU_WARN`, that interface is **always** rendered
as an individual node regardless of group size. The healthy remainder is collapsed.

Example with one bad tap out of 60:

```dot
"tap42i0\nMTU 1450 ⚠ FRAG"   [shape=folder, color="#f38ba8"]   ← individual, red border
"59 VM taps (OK)"              [shape=folder, color="#94e2d5"]   ← collapsed, teal
```

Both nodes are children of `vmbr0` in the diagram. The anomaly is immediately
visible without wading through 60 nodes.

### Finding the Anomaly in Table Mode

The DOT diagram is a topology overview. For operational audit (e.g., identifying
which of 60 taps has the wrong MTU), use **table mode**:

```bash
nic-xray.sh --virtual --output table
```

Every interface appears as an individual row with tree indentation and the `W` column
(`!` or `✗`). Pipe through `grep` to filter:

```bash
nic-xray.sh --virtual --output table | grep -E 'W|[!✗]'
```

The two output modes serve distinct purposes: DOT for topology/visual, table for
operational audit. The collapsing heuristic applies only to DOT rendering.

### Collapse Threshold

Collapse when a group of same-type, same-parent, all-OK interfaces exceeds **5**
members. This threshold avoids collapsing small groups that are still readable.

---

## 8. OvS-Specific Enrichment (Optional)

When `ovs-vsctl` is available and `--virtual` is active, enrich `ovs-br` type
interfaces with per-port type information:

```bash
if [[ "$VIRT_TYPE" == "ovs-br" ]] && command -v ovs-vsctl &>/dev/null; then
    # List ports and their OvS types (internal, vxlan, geneve, patch, system)
    ovs-vsctl list-ports "$IFACE" 2>/dev/null | while read -r _PORT; do
        _PORT_TYPE=$(ovs-vsctl get interface "$_PORT" type 2>/dev/null)
        # Use _PORT_TYPE to refine VIRT_TYPE for the child interface if present
        # in ENUM_IFACES (i.e., visible in root namespace)
    done
fi
```

This is opt-in enrichment; the base implementation works without `ovs-vsctl`.
OvS patch ports and internal ports that do NOT appear in `/sys/class/net/` (because
they are in a namespace) remain out of scope.

---

## 9. ZeroTier-Specific Notes

- MTU is typically 2800 — intentionally larger than underlay MTU; ZeroTier handles
  fragmentation and reassembly internally. **Do not flag as FRAG** (see MTU exception
  in section 5.5).
- Parent shown as `—`: ZeroTier is an overlay with no fixed sysfs underlay link.
- Encap overhead (~80 B) is shown for informational purposes only; it is an
  approximation documented in `--help`.
- The ZeroTier daemon creates the interface; no special sysfs directory exists beyond
  the standard `tun_flags` or type=1 Ethernet attributes.

---

## 10. Implementation Sequence

1. **Flag**: `SHOW_VIRTUAL`, `VIRTUAL_SKIP_PATTERN`, argument parsing, reset in
   `collect_data()`
2. **New helpers**: `enumerate_ifaces()`, `detect_virtual_type()`,
   `detect_virtual_parent()`, `compute_encap_overhead()`
3. **Refactor `collect_data()` loop**: use `ENUM_IFACES`, add IS_PHYSICAL gates
4. **New arrays**: declare + reset + store in collection loop
5. **MTU post-pass**: `compute_effective_mtu()` + `DATA_MTU_WARN` population
6. **Table render**: Type column, tree indentation, MTU coloring, W column
7. **CSV/JSON render**: new fields
8. **DOT render**: virtual nodes (shapes/colors), dotted edges, MTU warning edges,
   subgraph per physical NIC, collapsing with anomaly breakout
9. **Help + man page**: document `--virtual`, root-netns scope limitation, ZeroTier
   MTU note, OvS namespace note, Proxmox high-cardinality note
10. **Bash completion**: add `--virtual` / `-V` to `completions/nic-xray.bash`

---

## 11. Testing Targets

| Scenario                    | What to verify |
|-----------------------------|----------------|
| Proxmox VE host (60 VMs)    | Collapsing fires at >5 taps; bad MTU tap breaks out individually |
| ZeroTier active (`zt*`)     | Classified as `vpn`; MTU 2800 not flagged FRAG |
| OpenStack/OvS controller    | `br-int`/`br-ex` classified `ovs-br`; `ovs-system` skipped |
| OvS VXLAN port              | `vxlan-*` child of `br-tun` shows encap 50B |
| VLAN over bond              | `bond0.100` → VLAN parent=`bond0`; depth renders correctly |
| WireGuard (`wg0`)           | Classified `wireguard`; encap 60B; no LLDP/ethtool errors |
| Nested tunnel (VXLAN/VLAN)  | Effective MTU chain computed correctly: 1500-4-50=1446 → FRAG |
| No virtual ifaces           | `--virtual` on plain server shows only physical (same as default) |
| `--virtual --output dot`    | Virtual nodes present; `--virtual` without dot → table works |
