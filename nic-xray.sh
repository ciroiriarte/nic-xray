#!/bin/bash
#
# Script Name: nic-xray.sh
# Description: This script lists all physical network interfaces on the system,
#              showing PCI slot, firmware version, MAC address, MTU, link status,
#              negotiated speed/duplex, bond membership, and LLDP peer info.
#              It uses color to highlight link status, speed tiers, and bond groupings.
#              Created initially to deploy Openstack nodes, but should work
#              with any Linux machine.
#
# Author: Ciro Iriarte <ciro.iriarte+software@gmail.com>
# Created: 2025-06-05
#
# Requirements:
#   - Must be run as root
#   - Requires: ethtool, lldpctl, awk, grep, cat, readlink
#   - Optional: dmidecode (for --physical slot names), lspci (for NIC vendor/model)
#
# Change Log:
#   - 2025-06-05: Initial version
#   - 2025-06-06: Added color for bond names and link status
#                 Fixed alignment issues with ANSI color codes
#                 Changed variables to uppercase
#                 Added  LACP peer info (requires LLDP)
#                 Added  VLAN peer info (requires LLDP)
#   - 2025-06-23: Fixed MAC extraction for bond slaves
#                 Added support for CSV output
#   - 2026-02-17: Speed column coloring for table output
#                 --separator redesigned as optional-value flag (applies to CSV too)
#                 Added --group-bond flag for bond-grouped output
#   - 2026-02-27: v1.4 - Fixed --separator shift bug when used without a value
#   - 2026-02-27: v1.5 - Added --no-color, --all, --filter-link flags
#                        Added Driver column from ethtool -i
#                        Auto-disable colors when stdout is not a terminal
#                        Optimized ethtool calls (single invocation per interface)
#                        Graceful message when no interfaces are found
#   - 2026-02-27: v2.1 - Added network topology diagram output (dot/svg/png)
#                        New --diagram-out flag for custom output file path
#                        Optional graphviz dependency for svg/png rendering
#   - 2026-02-27: v2.2 - Moved man page from section 1 to section 8
#                        (system administration commands)
#   - 2026-02-27: v2.2.1 - README restructured for improved readability
#   - 2026-02-28: v2.4.0 - Fixed false LACP "Partial" status (bitmask check
#                           instead of exact port state comparison)
#                         - Added bond-level LACP consistency validation:
#                           Peer Mismatch and AE Mismatch detection
#                         - Extracted LLDP PortAggregID for cross-member checks
#   - 2026-02-28: v2.4.1 - Added watermark to DOT topology diagram
#                           (tool name, version, copyright)
#   - 2026-03-01: v2.5.0 - Added --metrics flag for real-time traffic metrics:
#                           bandwidth, packets/s, drops, errors, FIFO errors
#                         - Metrics supported across all output formats
#                           (table, CSV, JSON, DOT/SVG/PNG)
#                         - Bond variance detection: flags imbalanced members
#                           in non-active-backup bonds (< 70% of max → red)
#                         - Progress bar during sampling window (table + TTY)
#   - 2026-03-02: v2.6.0 - Added --optics flag for SFP/QSFP transceiver diagnostics:
#                           Tx/Rx optical power levels (dBm) with health status
#                         - DOM threshold evaluation (vendor EEPROM or static fallback)
#                         - Multi-lane (QSFP+/QSFP28) support with per-lane detail
#                         - Lane variance detection (>2dB flags outlier channel)
#                         - Optics supported across all output formats
#                           (table, CSV, JSON, DOT/SVG/PNG)
#   - 2026-03-03: v2.9.0 - Enhanced DOT diagram nodes with hardware/software
#                         descriptions, serial numbers, and generation timestamp
#   - 2026-03-03: v2.8.0 - Added --watch mode for continuous refresh during
#                         recabling (alternate screen buffer, clean Ctrl-C exit)
#                       - Combines with --metrics: sampling duration = watch interval
#   - 2026-03-02: v2.7.0 - Internal refactoring for maintainability:
#                         - Extracted collect_data(), compute_layout(), render_output()
#                           functions (enables future --watch mode)
#                         - Deduplicated DOT diagram generation with helper functions:
#                           _dot_nic_node(), _dot_metrics_rows(), _dot_link_color(),
#                           _dot_edge_color()
#                         - Extracted IFACE_SKIP_PATTERN, read_sysfs(),
#                           colorize_nonzero() helpers
#                         - Delta clamping via nameref loop
#
# Version: 2.10.0

SCRIPT_VERSION="2.10.0"
SCRIPT_YEAR="2026"

# Interface name pattern to skip (virtual, bond masters, etc.)
IFACE_SKIP_PATTERN='^(lo|vnet|virbr|br|bond|docker|tap|tun)'

# LOCALE setup, we expect output in English for proper parsing
LANG=en_US.UTF-8

# --- Argument Parsing ---
SHOW_LACP=false
SHOW_VLAN=false
SHOW_BMAC=false
FIELD_SEP=""
OUTPUT_FORMAT="table"
SORT_BY_BOND=false
USE_COLOR=true
FILTER_LINK=""
DIAGRAM_OUTPUT_FILE=""
SHOW_METRICS=false
METRICS_DURATION=30
SHOW_OPTICS=false
SHOW_PHYSICAL=false
CLUSTER_MODE="bond"
WATCH_MODE=false
WATCH_INTERVAL=5


# Parse options using getopt
if ! OPTIONS=$(getopt -o hvs::m::ow::p --long help,version,lacp,vlan,bmac,optics,physical,separator::,group-bond,output:,no-color,all,filter-link:,diagram-out:,metrics::,watch::,cluster: -n "$0" -- "$@"); then
	echo "Failed to parse options." >&2
	exit 1
fi


# Reorder the positional parameters according to getopt's output
eval set -- "$OPTIONS"

# Process options
while true; do
	case "$1" in
		--lacp)
			SHOW_LACP=true
			shift
			;;
		--vlan)
			SHOW_VLAN=true
			shift
			;;
		--bmac)
			SHOW_BMAC=true
			shift
			;;
		-o|--optics)
			SHOW_OPTICS=true
			shift
			;;
		-p|--physical)
			SHOW_PHYSICAL=true
			shift
			;;
		-s|--separator)
			if [[ -n "$2" ]]; then
				FIELD_SEP="$2"
				shift 2
			else
				FIELD_SEP="│"
				shift 2
			fi
			;;
		--no-color)
			USE_COLOR=false
			shift
			;;
		--all)
			SHOW_LACP=true
			SHOW_VLAN=true
			SHOW_BMAC=true
			SHOW_OPTICS=true
			SHOW_PHYSICAL=true
			shift
			;;
		--filter-link)
			case "$2" in
				up|down)
					FILTER_LINK="$2"
					;;
				*)
					echo "Invalid filter-link value: $2. Choose 'up' or 'down'." >&2
					exit 1
					;;
			esac
			shift 2
			;;
		-m|--metrics)
			SHOW_METRICS=true
			if [[ -n "$2" ]]; then
				if [[ "$2" =~ ^[0-9]+$ ]] && (( $2 >= 1 && $2 <= 3600 )); then
					METRICS_DURATION="$2"
				else
					echo "Invalid metrics duration: $2. Must be an integer between 1 and 3600." >&2
					exit 1
				fi
			fi
			shift 2
			;;
		-w|--watch)
			WATCH_MODE=true
			if [[ -n "$2" ]]; then
				if [[ "$2" =~ ^[0-9]+$ ]] && (( $2 >= 1 && $2 <= 3600 )); then
					WATCH_INTERVAL="$2"
				else
					echo "Invalid watch interval: $2. Must be an integer between 1 and 3600." >&2
					exit 1
				fi
			fi
			shift 2
			;;
		--group-bond)
			SORT_BY_BOND=true
			shift
			;;
		--cluster)
			case "$2" in
				bond|nic)
					CLUSTER_MODE="$2"
					;;
				*)
					echo "Invalid cluster mode: $2. Choose 'bond' or 'nic'." >&2
					exit 1
					;;
			esac
			shift 2
			;;
		--diagram-out)
			DIAGRAM_OUTPUT_FILE="$2"
			shift 2
			;;
		--output)
			case "$2" in
				table|csv|json|dot|svg|png)
				OUTPUT_FORMAT="$2"
				;;
			*)
				echo "Invalid output format: $2. Choose from table, csv, json, dot, svg, or png." >&2
				exit 1
				;;
			esac
			shift 2
			;;
		-v|--version)
			echo "$0 $SCRIPT_VERSION"
			exit 0
			;;
		-h|--help)
			echo -e "Usage: $0 [--lacp] [--vlan] [--bmac] [-o|--optics] [-p|--physical] [--all]"
			echo -e "       [--no-color] [--filter-link up|down] [-s[SEP]|--separator[=SEP]]"
			echo -e "       [--group-bond] [--cluster bond|nic] [-m[SEC]|--metrics[=SEC]]"
			echo -e "       [-w[SEC]|--watch[=SEC]] [--output FORMAT] [--diagram-out FILE] [--help]"
			echo -e ""
			echo -e "Version: $SCRIPT_VERSION"
			echo -e ""
			echo -e "Description:"
			echo -e " Lists physical network interfaces with detailed information including:"
			echo -e " PCI slot, driver, firmware, MAC, MTU, link, speed/duplex, bond membership,"
			echo -e " LLDP peer info, and optionally LACP status, VLAN tagging, SFP optics,"
			echo -e " and physical topology (NUMA node, PCI slot, NIC vendor/model)."
			echo -e ""
			echo -e "Options:"
			echo -e " --lacp              Show LACP Aggregator ID and Partner MAC per interface"
			echo -e " --vlan              Show VLAN tagging information (from LLDP)"
			echo -e " --bmac              Show bridge MAC address"
			echo -e " -o, --optics        Show SFP/QSFP transceiver diagnostics (Tx/Rx power, health)"
			echo -e "                     Health status: OK (green), WARN (yellow), ALARM (red),"
			echo -e "                     N/DOM (no DOM data), N/A (no SFP or copper)"
			echo -e " -p, --physical      Show physical topology: NUMA node, PCI slot, NIC vendor/model"
			echo -e "                     Useful for NUMA affinity analysis and PCIe placement"
			echo -e " --all               Enable all optional columns (--lacp --vlan --bmac --optics --physical)"
			echo -e " --no-color          Disable color output (auto-disabled for non-terminal)"
			echo -e " --filter-link TYPE  Show only interfaces with link up or down"
			echo -e " -s, --separator     Show │ column separators in table output; applies to CSV too"
			echo -e " -sSEP, --separator=SEP"
			echo -e "                     Use SEP as column separator in table and CSV output"
			echo -e " --group-bond        Sort rows by bond group, then by interface name"
			echo -e " --cluster MODE      Diagram clustering mode: bond (default) or nic"
			echo -e "                     bond: group interfaces by bond membership"
			echo -e "                     nic: group by NUMA node and PCI slot (auto-enables -p)"
			echo -e " -w, --watch         Watch mode: refresh display continuously (default: 5s)"
			echo -e " -wSEC, --watch=SEC  Set refresh interval in seconds (1-3600)"
			echo -e "                     Combines with --metrics: sampling duration = watch interval"
			echo -e "                     Table output only; requires a terminal"
			echo -e " -m, --metrics       Sample interface traffic metrics (default: 30s)"
			echo -e " -mSEC, --metrics=SEC"
			echo -e "                     Set sampling duration in seconds (1-3600)"
			echo -e " --output TYPE       Output format: table (default), csv, json, dot, svg, or png"
			echo -e "                     dot/svg/png generate a network topology diagram"
			echo -e "                     svg/png require graphviz (dot command)"
			echo -e " --diagram-out FILE  Output file path for svg/png diagrams"
			echo -e "                     Default: /tmp/nic-xray-<hostname>.{svg,png}"
			echo -e " -v, --version       Display version information"
			echo -e " -h, --help          Display this help message"
			exit 0
			;;
		--)
			shift
			break
			;;
		*)
			echo "Unexpected option: $1" >&2
			exit 1
			;;
	esac
done


# --- Auto-disable colors for non-terminal output ---
[[ ! -t 1 ]] && USE_COLOR=false

# --- Watch mode validation ---
if $WATCH_MODE; then
    if [[ "$OUTPUT_FORMAT" != "table" ]]; then
        echo "Watch mode is only supported with table output format." >&2
        exit 1
    fi
    if [[ ! -t 1 ]]; then
        echo "Watch mode requires a terminal (stdout must be a TTY)." >&2
        exit 1
    fi
fi

# When watch + metrics combined, use watch interval as metrics duration
if $WATCH_MODE && $SHOW_METRICS; then
    METRICS_DURATION="$WATCH_INTERVAL"
fi

# --cluster nic auto-enables --physical data collection
if [[ "$CLUSTER_MODE" == "nic" ]]; then
    SHOW_PHYSICAL=true
fi

# --- Diagram format setup ---
if [[ "$OUTPUT_FORMAT" =~ ^(dot|svg|png)$ ]]; then
    # Auto-enable all optional data for diagram completeness
    SHOW_LACP=true
    SHOW_VLAN=true
    SHOW_BMAC=true
    SHOW_OPTICS=true
    SHOW_PHYSICAL=true

    # Check graphviz availability for rendered formats
    if [[ "$OUTPUT_FORMAT" != "dot" ]] && ! command -v dot &>/dev/null; then
        echo "graphviz is required for --output $OUTPUT_FORMAT but 'dot' command was not found." >&2
        echo "Install graphviz or use --output dot to generate raw DOT source." >&2
        exit 1
    fi
fi

# --- Validation Section ---
if [[ $EUID -ne 0 ]]; then
    echo -e "❌ This script must be run as root. Please use sudo or switch to root."
    exit 1
fi

REQUIRED_CMDS=("ethtool" "lldpctl" "readlink" "awk" "grep" "cat" "ip")

for CMD in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$CMD" &>/dev/null; then
        echo -e "❌ Required command '$CMD' is not installed or not in PATH."
        exit 1
    fi
done

# --- Color Setup ---
declare -A BOND_COLORS

if [[ "$USE_COLOR" == true ]]; then
    COLOR_CODES=(
        "\033[1;34m"  # Blue
        "\033[1;36m"  # Cyan
        "\033[1;33m"  # Yellow
        "\033[1;35m"  # Magenta
        "\033[1;37m"  # White
    )
    RESET_COLOR="\033[0m"

    GREEN="\033[1;32m"
    RED="\033[1;31m"
    YELLOW="\033[1;33m"
    BOLD_GREEN="\033[1;32m"
    BOLD_CYAN="\033[1;36m"
    BOLD_MAGENTA="\033[1;35m"
    BOLD_WHITE="\033[1;37m"
else
    COLOR_CODES=("" "" "" "" "")
    RESET_COLOR=""

    GREEN=""
    RED=""
    YELLOW=""
    BOLD_GREEN=""
    BOLD_CYAN=""
    BOLD_MAGENTA=""
    BOLD_WHITE=""
fi
COLOR_INDEX=0

strip_ansi() {
    echo -e "$1" | sed -r 's/\x1B\[[0-9;]*[mK]//g'
}

pad_color() {
    local TEXT="$1"
    local WIDTH="$2"
    local STRIPPED
    STRIPPED=$(strip_ansi "$TEXT")
    local PAD=$((WIDTH - ${#STRIPPED}))
    printf "%b%*s" "$TEXT" "$PAD" ""
}

# --- Helper: escape string for JSON output ---
json_escape() {
    local STR="$1"
    STR="${STR//\\/\\\\}"
    STR="${STR//\"/\\\"}"
    printf '%s' "$STR"
}

# --- Helper: compute max width from header label and data values ---
max_width() {
    local HEADER="$1"
    shift
    local MAX=${#HEADER}
    for VAL in "$@"; do
        (( ${#VAL} > MAX )) && MAX=${#VAL}
    done
    echo "$MAX"
}

# --- Helper: apply ANSI color to speed/duplex string based on speed tier ---
colorize_speed() {
    local RAW="$1"

    if [[ "$USE_COLOR" != true ]]; then
        printf "%s" "$RAW"
        return
    fi

    local NUM="${RAW%%[^0-9]*}"
    local COLOR

    if [[ "$NUM" =~ ^[0-9]+$ ]]; then
        if (( NUM >= 200000 )); then
            COLOR="${BOLD_MAGENTA}"  # 200G+
        elif (( NUM >= 100000 )); then
            COLOR="${BOLD_CYAN}"     # 100G
        elif (( NUM >= 25000 )); then
            COLOR="${BOLD_WHITE}"    # 25G / 40G / 50G
        elif (( NUM >= 10000 )); then
            COLOR="${BOLD_GREEN}"    # 10G
        elif (( NUM >= 1000 )); then
            COLOR="${YELLOW}"        # 1G
        else
            COLOR="${RED}"           # < 1G
        fi
    else
        COLOR="${RED}"               # N/A or unknown
    fi

    printf "%b%s%b" "$COLOR" "$RAW" "$RESET_COLOR"
}

# --- Metrics Helpers ---

# Read interface counters from /sys/class/net into associative arrays
# Usage: read_iface_stats PREFIX IFACE_LIST...
# Sets PREFIX_rx_bytes[IFACE], PREFIX_tx_bytes[IFACE], etc.
read_iface_stats() {
    local PREFIX="$1"
    shift
    local STATS_DIR IFACE VAL
    for IFACE in "$@"; do
        STATS_DIR="/sys/class/net/${IFACE}/statistics"
        [[ ! -d "$STATS_DIR" ]] && continue
        for COUNTER in rx_bytes tx_bytes rx_packets tx_packets \
                       rx_dropped tx_dropped rx_errors tx_errors \
                       rx_fifo_errors tx_fifo_errors; do
            VAL=$(<"${STATS_DIR}/${COUNTER}") || VAL=0
            eval "${PREFIX}_${COUNTER}[\"${IFACE}\"]=${VAL}"
        done
    done
}

# Countdown sleep for watch mode (non-metrics only)
watch_sleep() {
    local _SECS="$1"
    for (( _s = _SECS; _s > 0; _s-- )); do
        printf '\r\u23f3 Refreshing in %ds...  ' "$_s" >&2
        sleep 1
    done
    printf '\r%*s\r' 30 '' >&2
}

# Convert bytes/s to human-readable bitrate with SI decimal prefixes (pure bash)
# Input: bytes/s (raw sysfs value); output: bits/s with Gbps/Mbps/Kbps/bps labels
human_bitrate() {
    local BYTES_PS="$1"
    local BITS_PS=$(( BYTES_PS * 8 ))
    if (( BITS_PS >= 1000000000 )); then
        local INT=$((BITS_PS / 1000000000))
        local FRAC=$(( (BITS_PS % 1000000000) * 10 / 1000000000 ))
        printf '%d.%d Gbps' "$INT" "$FRAC"
    elif (( BITS_PS >= 1000000 )); then
        local INT=$((BITS_PS / 1000000))
        local FRAC=$(( (BITS_PS % 1000000) * 10 / 1000000 ))
        printf '%d.%d Mbps' "$INT" "$FRAC"
    elif (( BITS_PS >= 1000 )); then
        local INT=$((BITS_PS / 1000))
        local FRAC=$(( (BITS_PS % 1000) * 10 / 1000 ))
        printf '%d.%d Kbps' "$INT" "$FRAC"
    else
        printf '%d bps' "$BITS_PS"
    fi
}

# Check if a bond is in active-backup mode
is_active_backup() {
    [[ "${BOND_MODE_MAP[$1]}" == *"active-backup"* ]]
}

# Read a sysfs attribute for a network interface
read_sysfs() { cat "/sys/class/net/${1}/${2}" 2>/dev/null; }

# Wrap a counter value with RED color if nonzero (for metrics display)
colorize_nonzero() {
    if (( $1 > 0 )); then
        printf '%b%s%b' "$RED" "$1" "$RESET_COLOR"
    else
        printf '%s' "$1"
    fi
}

# --- SFP/QSFP Optics Diagnostics ---

# Fallback DOM thresholds (dBm) when SFP EEPROM thresholds are unavailable
# Format: "tx_low_alarm tx_low_warn tx_high_warn tx_high_alarm rx_low_alarm rx_low_warn rx_high_warn rx_high_alarm"
# Sources: Cisco, Juniper, FS.com datasheets (SFF-8472/SFF-8636 typical ranges)
declare -A SFP_FALLBACK_THRESHOLDS=(
    # 1G SFP
    ["1000BASE-SX"]="-11.0 -9.5 -2.5 -1.0 -17.0 -16.0 -0.5 0.0"
    ["1000BASE-LX"]="-11.0 -9.5 -2.5 -1.0 -20.0 -19.0 -3.5 -3.0"
    ["1000BASE-EX"]="-2.0 -1.0 2.5 3.0 -22.0 -21.0 0.5 1.0"
    ["1000BASE-ZX"]="-1.0 0.0 4.5 5.0 -23.0 -22.0 -3.5 -3.0"
    # 10G SFP+
    ["10GBASE-SR"]="-9.0 -7.3 -0.5 0.0 -12.0 -10.0 -0.5 0.0"
    ["10GBASE-LR"]="-9.5 -8.2 0.0 0.5 -14.4 -12.0 0.0 0.5"
    ["10GBASE-LRM"]="-8.0 -6.5 0.0 0.5 -10.0 -8.4 0.0 0.5"
    ["10GBASE-ER"]="-6.0 -4.7 3.5 4.0 -15.8 -14.0 -1.5 -1.0"
    ["10GBASE-ZR"]="-1.0 0.0 3.5 4.0 -24.0 -22.0 -7.5 -7.0"
    # 25G SFP28
    ["25GBASE-SR"]="-10.0 -8.4 1.9 2.4 -12.0 -10.3 1.9 2.4"
    ["25GBASE-LR"]="-8.5 -7.0 1.5 2.0 -14.4 -13.3 1.5 2.0"
    ["25GBASE-ER"]="-4.0 -3.0 5.5 6.0 -21.0 -20.0 -4.5 -4.0"
    # 40G QSFP+ (per-lane)
    ["40GBASE-SR4"]="-9.0 -7.5 1.9 2.4 -10.5 -9.0 1.9 2.4"
    ["40GBASE-LR4"]="-8.5 -7.0 1.8 2.3 -14.0 -12.5 1.8 2.3"
    # 100G QSFP28 (per-lane)
    ["100GBASE-SR4"]="-10.0 -8.4 1.9 2.4 -12.0 -10.3 1.9 2.4"
    ["100GBASE-LR4"]="-5.5 -4.3 4.0 4.5 -14.0 -12.5 4.0 4.5"
    ["100GBASE-CWDM4"]="-8.0 -6.5 2.0 2.5 -13.0 -11.5 2.0 2.5"
)

# Evaluate a dBm value against thresholds and return health status
# Args: $1=dBm value, $2=low_alarm, $3=low_warn, $4=high_warn, $5=high_alarm
# Returns: OK, WARN, or ALARM
evaluate_optics_health() {
    local DBM="$1" LOW_ALARM="$2" LOW_WARN="$3" HIGH_WARN="$4" HIGH_ALARM="$5"

    # -inf or -40 dBm → always ALARM (zero optical power)
    if [[ "$DBM" == "-inf" || "$DBM" == "-inf"* ]]; then
        echo "ALARM"
        return
    fi

    awk -v dbm="$DBM" -v la="$LOW_ALARM" -v lw="$LOW_WARN" -v hw="$HIGH_WARN" -v ha="$HIGH_ALARM" \
        'BEGIN {
            if (dbm+0 <= -40.0) { print "ALARM"; exit }
            if (dbm+0 < la+0 || dbm+0 > ha+0) { print "ALARM"; exit }
            if (dbm+0 < lw+0 || dbm+0 > hw+0) { print "WARN"; exit }
            print "OK"
        }'
}

# Parse SFP/QSFP optics data for an interface
# Sets caller variables: OPTICS_TYPE, OPTICS_VENDOR, OPTICS_WAVELENGTH,
#   OPTICS_TX_DBM, OPTICS_RX_DBM, OPTICS_TX_STATUS, OPTICS_RX_STATUS,
#   OPTICS_LANE_COUNT, OPTICS_TX_LANES, OPTICS_RX_LANES
parse_optics() {
    local IFACE="$1"

    # Defaults
    OPTICS_TYPE="N/A"
    OPTICS_TYPE_ALL=""
    OPTICS_BAUD=""
    OPTICS_VENDOR=""
    OPTICS_WAVELENGTH=""
    OPTICS_TX_DBM="N/A"
    OPTICS_RX_DBM="N/A"
    OPTICS_TX_STATUS="N/A"
    OPTICS_RX_STATUS="N/A"
    OPTICS_LANE_COUNT=0
    OPTICS_TX_LANES=""
    OPTICS_RX_LANES=""

    # Run ethtool -m; if it fails, module is absent / copper
    local ETH_M
    ETH_M=$(ethtool -m "$IFACE" 2>/dev/null) || return

    # Empty output means no module data
    [[ -z "$ETH_M" ]] && return

    # Extract module metadata
    # Collect ALL Transceiver type lines (modules may advertise multiple standards)
    OPTICS_TYPE=$(echo "$ETH_M" | awk '/Transceiver type/ { sub(/.*Transceiver type[[:space:]]*:[[:space:]]*/,""); print; exit }')
    OPTICS_TYPE_ALL=$(echo "$ETH_M" | awk '/Transceiver type/ { sub(/.*Transceiver type[[:space:]]*:[[:space:]]*/,""); print }')
    OPTICS_VENDOR=$(echo "$ETH_M" | awk -F' *: *' '/Vendor name[ ]*:/ {print $2; exit}')
    OPTICS_WAVELENGTH=$(echo "$ETH_M" | awk -F' *: *' '/Laser wavelength[ ]*:/ {print $2; exit}')
    # BR, Nominal gives the actual signaling rate of the module (most reliable speed indicator)
    OPTICS_BAUD=$(echo "$ETH_M" | awk -F' *: *' '/BR, Nominal/ {print $2; exit}')

    # Trim whitespace
    OPTICS_TYPE="${OPTICS_TYPE## }"
    OPTICS_TYPE="${OPTICS_TYPE%% }"
    OPTICS_VENDOR="${OPTICS_VENDOR## }"
    OPTICS_VENDOR="${OPTICS_VENDOR%% }"
    OPTICS_WAVELENGTH="${OPTICS_WAVELENGTH## }"
    OPTICS_WAVELENGTH="${OPTICS_WAVELENGTH%% }"

    [[ -z "$OPTICS_TYPE" ]] && OPTICS_TYPE="N/A"

    # Detect multi-lane (QSFP) vs single-lane (SFP)
    local IS_MULTI=false
    if echo "$ETH_M" | grep -q "Channel 1"; then
        IS_MULTI=true
    fi

    # Extract DOM alarm/warning thresholds from ethtool -m
    local TX_LA TX_LW TX_HW TX_HA RX_LA RX_LW RX_HW RX_HA
    TX_LA=$(echo "$ETH_M" | awk '/Laser output power low alarm threshold/ { for(i=1;i<=NF;i++) if($i=="dBm") print $(i-1); exit }')
    TX_LW=$(echo "$ETH_M" | awk '/Laser output power low warning threshold/ { for(i=1;i<=NF;i++) if($i=="dBm") print $(i-1); exit }')
    TX_HW=$(echo "$ETH_M" | awk '/Laser output power high warning threshold/ { for(i=1;i<=NF;i++) if($i=="dBm") print $(i-1); exit }')
    TX_HA=$(echo "$ETH_M" | awk '/Laser output power high alarm threshold/ { for(i=1;i<=NF;i++) if($i=="dBm") print $(i-1); exit }')
    RX_LA=$(echo "$ETH_M" | awk '/Laser rx power low alarm threshold/ { for(i=1;i<=NF;i++) if($i=="dBm") print $(i-1); exit }')
    RX_LW=$(echo "$ETH_M" | awk '/Laser rx power low warning threshold/ { for(i=1;i<=NF;i++) if($i=="dBm") print $(i-1); exit }')
    RX_HW=$(echo "$ETH_M" | awk '/Laser rx power high warning threshold/ { for(i=1;i<=NF;i++) if($i=="dBm") print $(i-1); exit }')
    RX_HA=$(echo "$ETH_M" | awk '/Laser rx power high alarm threshold/ { for(i=1;i<=NF;i++) if($i=="dBm") print $(i-1); exit }')

    # Check if DOM thresholds are valid (present and not all zero)
    local HAS_DOM_THRESHOLDS=true
    if [[ -z "$TX_LA" || -z "$TX_LW" || -z "$TX_HW" || -z "$TX_HA" || \
          -z "$RX_LA" || -z "$RX_LW" || -z "$RX_HW" || -z "$RX_HA" ]]; then
        HAS_DOM_THRESHOLDS=false
    else
        # Check if all thresholds are zero (broken DOM)
        local ALL_ZERO
        ALL_ZERO=$(awk -v a="$TX_LA" -v b="$TX_LW" -v c="$TX_HW" -v d="$TX_HA" \
                       -v e="$RX_LA" -v f="$RX_LW" -v g="$RX_HW" -v h="$RX_HA" \
            'BEGIN { if (a+0==0 && b+0==0 && c+0==0 && d+0==0 && e+0==0 && f+0==0 && g+0==0 && h+0==0) print "yes"; else print "no" }')
        [[ "$ALL_ZERO" == "yes" ]] && HAS_DOM_THRESHOLDS=false
    fi

    # Fall back to static table if DOM thresholds unavailable
    if [[ "$HAS_DOM_THRESHOLDS" == false ]]; then
        local KEY="$OPTICS_TYPE"
        if [[ -n "${SFP_FALLBACK_THRESHOLDS[$KEY]+x}" ]]; then
            read -r TX_LA TX_LW TX_HW TX_HA RX_LA RX_LW RX_HW RX_HA <<< "${SFP_FALLBACK_THRESHOLDS[$KEY]}"
            HAS_DOM_THRESHOLDS=true
        else
            # Normalize type: extract standard name from verbose format
            # e.g., "10G Ethernet: 10G Base-SR" → "10GBASE-SR"
            #        "Extended: 100G Base-SR4 or 25GBase-SR" → try "100GBASE-SR4", then "25GBASE-SR"
            local NORM_KEYS=()
            local _FB_AFTER="${OPTICS_TYPE#*: }"
            if [[ "$_FB_AFTER" != "$OPTICS_TYPE" ]]; then
                # Split on " or " for multi-standard types
                local _FB_REM="$_FB_AFTER" _FB_PART
                while [[ "$_FB_REM" == *" or "* ]]; do
                    _FB_PART="${_FB_REM%% or *}"
                    _FB_REM="${_FB_REM#* or }"
                    _FB_PART="${_FB_PART// /}"
                    _FB_PART="${_FB_PART^^}"
                    NORM_KEYS+=("$_FB_PART")
                done
                _FB_REM="${_FB_REM// /}"
                _FB_REM="${_FB_REM^^}"
                NORM_KEYS+=("$_FB_REM")
            fi
            for NK in "${NORM_KEYS[@]}"; do
                if [[ -n "${SFP_FALLBACK_THRESHOLDS[$NK]+x}" ]]; then
                    read -r TX_LA TX_LW TX_HW TX_HA RX_LA RX_LW RX_HW RX_HA <<< "${SFP_FALLBACK_THRESHOLDS[$NK]}"
                    HAS_DOM_THRESHOLDS=true
                    break
                fi
            done
        fi
    fi

    if [[ "$IS_MULTI" == true ]]; then
        # --- Multi-lane (QSFP+/QSFP28) ---
        local -a TX_VALS=() RX_VALS=()
        local CH TX_V RX_V
        for CH in 1 2 3 4; do
            TX_V=$(echo "$ETH_M" | awk -v ch="$CH" '
                $0 ~ "Transmit avg optical power.*Channel "ch")" {
                    for(i=1;i<=NF;i++) if($i=="dBm") { print $(i-1); exit }
                }')
            RX_V=$(echo "$ETH_M" | awk -v ch="$CH" '
                $0 ~ "Receiver signal average optical power.*Channel "ch")" {
                    for(i=1;i<=NF;i++) if($i=="dBm") { print $(i-1); exit }
                }')
            [[ -z "$TX_V" ]] && TX_V="N/A"
            [[ -z "$RX_V" ]] && RX_V="N/A"
            TX_VALS+=("$TX_V")
            RX_VALS+=("$RX_V")
        done

        OPTICS_LANE_COUNT=${#TX_VALS[@]}
        OPTICS_TX_LANES=$(IFS=':'; echo "${TX_VALS[*]}")
        OPTICS_RX_LANES=$(IFS=':'; echo "${RX_VALS[*]}")

        # Check if any lane has actual power data
        local HAS_TX_DATA=false HAS_RX_DATA=false
        for V in "${TX_VALS[@]}"; do [[ "$V" != "N/A" ]] && HAS_TX_DATA=true && break; done
        for V in "${RX_VALS[@]}"; do [[ "$V" != "N/A" ]] && HAS_RX_DATA=true && break; done

        if [[ "$HAS_TX_DATA" == false && "$HAS_RX_DATA" == false ]]; then
            # Module present but no DOM power data (e.g., DAC)
            OPTICS_TX_STATUS="N/DOM"
            OPTICS_RX_STATUS="N/DOM"
            return
        fi

        # Find worst-case Tx (minimum across lanes)
        if [[ "$HAS_TX_DATA" == true ]]; then
            OPTICS_TX_DBM=$(printf '%s\n' "${TX_VALS[@]}" | grep -v 'N/A' | awk 'BEGIN{m=999} {if($1+0<m) m=$1+0} END{printf "%.2f",m}')
            if [[ "$HAS_DOM_THRESHOLDS" == true ]]; then
                OPTICS_TX_STATUS=$(evaluate_optics_health "$OPTICS_TX_DBM" "$TX_LA" "$TX_LW" "$TX_HW" "$TX_HA")
            else
                OPTICS_TX_STATUS="N/DOM"
            fi
        fi

        # Find worst-case Rx (minimum across lanes)
        if [[ "$HAS_RX_DATA" == true ]]; then
            OPTICS_RX_DBM=$(printf '%s\n' "${RX_VALS[@]}" | grep -v 'N/A' | awk 'BEGIN{m=999} {if($1+0<m) m=$1+0} END{printf "%.2f",m}')
            if [[ "$HAS_DOM_THRESHOLDS" == true ]]; then
                OPTICS_RX_STATUS=$(evaluate_optics_health "$OPTICS_RX_DBM" "$RX_LA" "$RX_LW" "$RX_HW" "$RX_HA")
            else
                OPTICS_RX_STATUS="N/DOM"
            fi
        fi

        # Lane variance detection: if max - min > 2 dBm, flag outlier
        # (Appended to the table display string later in colorize_optics)
    else
        # --- Single-lane (SFP/SFP+/SFP28) ---
        OPTICS_LANE_COUNT=1
        OPTICS_TX_DBM=$(echo "$ETH_M" | awk '/Laser output power[ ]*:/ && !/threshold/ { for(i=1;i<=NF;i++) if($i=="dBm") { print $(i-1); exit } }')
        OPTICS_RX_DBM=$(echo "$ETH_M" | awk '/Receiver signal average optical power[ ]*:/ && !/threshold/ { for(i=1;i<=NF;i++) if($i=="dBm") { print $(i-1); exit } }')

        if [[ -z "$OPTICS_TX_DBM" && -z "$OPTICS_RX_DBM" ]]; then
            # Module present but no DOM power data (e.g., DAC cable)
            OPTICS_TX_DBM="N/A"
            OPTICS_RX_DBM="N/A"
            OPTICS_TX_STATUS="N/DOM"
            OPTICS_RX_STATUS="N/DOM"
            return
        fi

        [[ -z "$OPTICS_TX_DBM" ]] && OPTICS_TX_DBM="N/A"
        [[ -z "$OPTICS_RX_DBM" ]] && OPTICS_RX_DBM="N/A"

        if [[ "$OPTICS_TX_DBM" != "N/A" && "$HAS_DOM_THRESHOLDS" == true ]]; then
            OPTICS_TX_STATUS=$(evaluate_optics_health "$OPTICS_TX_DBM" "$TX_LA" "$TX_LW" "$TX_HW" "$TX_HA")
        elif [[ "$OPTICS_TX_DBM" != "N/A" ]]; then
            OPTICS_TX_STATUS="N/DOM"
        fi

        if [[ "$OPTICS_RX_DBM" != "N/A" && "$HAS_DOM_THRESHOLDS" == true ]]; then
            OPTICS_RX_STATUS=$(evaluate_optics_health "$OPTICS_RX_DBM" "$RX_LA" "$RX_LW" "$RX_HW" "$RX_HA")
        elif [[ "$OPTICS_RX_DBM" != "N/A" ]]; then
            OPTICS_RX_STATUS="N/DOM"
        fi
    fi
}

# Normalize verbose SFP transceiver type to concise IEEE standard name
# Uses BR, Nominal (module baud rate) as primary speed signal, negotiated speed as fallback.
# Args: $1=all transceiver type lines (newline-separated), $2=BR Nominal (e.g., "25750MBd"),
#       $3=negotiated speed (e.g., "25000Mb/s")
# Sets caller variable: OPTICS_TYPE (overwritten with normalized value)
normalize_sfp_type() {
    local TYPE_ALL="$1" BAUD="$2" SPEED="$3"
    [[ -z "$TYPE_ALL" ]] && return

    # Collect all normalized candidates from ALL Transceiver type lines
    local -a CANDIDATES=()
    while IFS= read -r _LINE; do
        [[ -z "$_LINE" ]] && continue
        # Skip non-Ethernet types (FC: Fibre Channel, etc.)
        [[ "$_LINE" == FC:* ]] && continue

        # Strip category prefix: "10G Ethernet: 10G Base-SR" → "10G Base-SR"
        local _AFTER="${_LINE#*: }"
        [[ "$_AFTER" == "$_LINE" ]] && _AFTER="$_LINE"

        # Split on " or " for multi-standard types
        local _REM="$_AFTER" _P
        while [[ "$_REM" == *" or "* ]]; do
            _P="${_REM%% or *}"
            _REM="${_REM#* or }"
            _P="${_P// /}"
            _P="${_P^^}"
            CANDIDATES+=("$_P")
        done
        _REM="${_REM// /}"
        _REM="${_REM^^}"
        CANDIDATES+=("$_REM")
    done <<< "$TYPE_ALL"

    [[ ${#CANDIDATES[@]} -eq 0 ]] && return

    if [[ ${#CANDIDATES[@]} -eq 1 ]]; then
        OPTICS_TYPE="${CANDIDATES[0]}"
        return
    fi

    # Determine module speed class from BR, Nominal (MBd)
    # BR, Nominal is the most reliable indicator of actual module speed.
    # Map BR ranges to standard speed classes (MBd values have overhead):
    #   ~1000-1300 → 1G, ~10000-10500 → 10G, ~25000-28000 → 25G,
    #   ~40000-42000 → 40G, ~100000-112000 → 100G
    local BR_SPEED_G=0
    if [[ -n "$BAUD" ]]; then
        local BR_NUM="${BAUD%%MBd*}"
        if [[ "$BR_NUM" =~ ^[0-9]+$ ]]; then
            if   (( BR_NUM >= 90000 )); then BR_SPEED_G=100
            elif (( BR_NUM >= 35000 )); then BR_SPEED_G=40
            elif (( BR_NUM >= 20000 )); then BR_SPEED_G=25
            elif (( BR_NUM >= 8000 ));  then BR_SPEED_G=10
            elif (( BR_NUM >= 500 ));   then BR_SPEED_G=1
            fi
        fi
    fi

    # Try to match BR speed class against candidates
    if [[ $BR_SPEED_G -gt 0 ]]; then
        for C in "${CANDIDATES[@]}"; do
            local C_NUM="${C%%GBASE*}"
            if [[ "$C_NUM" =~ ^[0-9]+$ && "$C_NUM" -eq "$BR_SPEED_G" ]]; then
                OPTICS_TYPE="$C"
                return
            fi
        done
    fi

    # Fallback: try negotiated link speed (Mb/s → speed class)
    local SPEED_NUM="${SPEED%%Mb/s*}"
    if [[ "$SPEED_NUM" =~ ^[0-9]+$ ]]; then
        local SPEED_G=0
        if   (( SPEED_NUM >= 90000 )); then SPEED_G=100
        elif (( SPEED_NUM >= 35000 )); then SPEED_G=40
        elif (( SPEED_NUM >= 20000 )); then SPEED_G=25
        elif (( SPEED_NUM >= 8000 ));  then SPEED_G=10
        elif (( SPEED_NUM >= 500 ));   then SPEED_G=1
        fi
        if [[ $SPEED_G -gt 0 ]]; then
            for C in "${CANDIDATES[@]}"; do
                local C_NUM="${C%%GBASE*}"
                if [[ "$C_NUM" =~ ^[0-9]+$ && "$C_NUM" -eq "$SPEED_G" ]]; then
                    OPTICS_TYPE="$C"
                    return
                fi
            done
        fi
    fi

    # No match — use the first Ethernet candidate
    OPTICS_TYPE="${CANDIDATES[0]}"
}

# Colorize optics value+status for table display
# Args: $1=dBm value, $2=status, $3=lane_info (optional, for multi-lane variance suffix)
# Outputs: plain string and color string (via OPTICS_CLR_PLAIN, OPTICS_CLR_COLOR)
colorize_optics() {
    local DBM="$1" STATUS="$2" LANE_SUFFIX="${3:-}"

    if [[ "$STATUS" == "N/A" || "$STATUS" == "N/DOM" ]]; then
        OPTICS_CLR_PLAIN="${DBM} ${STATUS}${LANE_SUFFIX}"
        OPTICS_CLR_COLOR="${DBM} ${STATUS}${LANE_SUFFIX}"
        return
    fi

    OPTICS_CLR_PLAIN="${DBM} ${STATUS}${LANE_SUFFIX}"

    case "$STATUS" in
        OK)
            OPTICS_CLR_COLOR="${DBM} ${GREEN}${STATUS}${RESET_COLOR}${LANE_SUFFIX}"
            ;;
        WARN)
            OPTICS_CLR_COLOR="${DBM} ${YELLOW}${STATUS}${RESET_COLOR}${LANE_SUFFIX}"
            ;;
        ALARM)
            OPTICS_CLR_COLOR="${RED}${DBM} ${STATUS}${LANE_SUFFIX}${RESET_COLOR}"
            ;;
        *)
            OPTICS_CLR_COLOR="${DBM} ${STATUS}${LANE_SUFFIX}"
            ;;
    esac
}

# Detect multi-lane variance and return suffix string (e.g., " Ch3↓2dB")
# Args: $1=colon-separated lane values
# Returns suffix string on stdout, empty if no variance
optics_lane_variance() {
    local LANES_STR="$1"
    [[ -z "$LANES_STR" ]] && return

    local IFS_SAVE="$IFS"
    IFS=':' read -ra VALS <<< "$LANES_STR"
    IFS="$IFS_SAVE"

    # Filter out N/A values
    local -a NUMERIC=()
    local -a INDICES=()
    local I=0
    for V in "${VALS[@]}"; do
        ((I++))
        [[ "$V" == "N/A" ]] && continue
        NUMERIC+=("$V")
        INDICES+=("$I")
    done

    [[ ${#NUMERIC[@]} -lt 2 ]] && return

    # Find min and max
    local RESULT
    RESULT=$({ printf '%s\n' "${NUMERIC[@]}"; printf '%s\n' "${INDICES[@]}"; } | awk -v n="${#NUMERIC[@]}" '
        BEGIN { min_v=999; max_v=-999 }
        NR <= n { vals[NR] = $1+0 }
        NR > n { idxs[NR-n] = $1 }
        END {
            for (i=1; i<=n; i++) {
                if (vals[i] < min_v) { min_v = vals[i]; min_i = idxs[i] }
                if (vals[i] > max_v) { max_v = vals[i] }
            }
            diff = max_v - min_v
            if (diff > 2.0) {
                printf " Ch%d↓%ddB", min_i, int(diff+0.5)
            }
        }
    ')
    printf '%s' "$RESULT"
}

# --- Data Collection Arrays ---
declare -a DATA_DEVICE DATA_DRIVER DATA_FIRMWARE DATA_IFACE DATA_MAC DATA_MTU
declare -a DATA_LINK_PLAIN DATA_LINK_COLOR
declare -a DATA_SPEED_PLAIN DATA_SPEED_COLOR
declare -a DATA_BOND_PLAIN DATA_BOND_COLOR
declare -a DATA_BMAC
declare -a DATA_LACP_PLAIN DATA_LACP_COLOR DATA_LACP_PEER
declare -a DATA_LLDP_AGGID
declare -a DATA_VLAN DATA_SWITCH DATA_PORT DATA_PORT_DESCR
declare -a DATA_OPTICS_TYPE
declare -a DATA_OPTICS_TX_PLAIN DATA_OPTICS_TX_COLOR
declare -a DATA_OPTICS_RX_PLAIN DATA_OPTICS_RX_COLOR
declare -a DATA_OPTICS_TX_DBM DATA_OPTICS_RX_DBM
declare -a DATA_OPTICS_TX_STATUS DATA_OPTICS_RX_STATUS
declare -a DATA_OPTICS_VENDOR DATA_OPTICS_WAVELENGTH
declare -a DATA_OPTICS_TX_LANES DATA_OPTICS_RX_LANES
declare -a DATA_OPTICS_LANE_COUNT
declare -a DATA_MET_BW_PLAIN DATA_MET_BW_COLOR
declare -a DATA_MET_PPS_PLAIN DATA_MET_PPS_COLOR
declare -a DATA_MET_DROP_PLAIN DATA_MET_DROP_COLOR
declare -a DATA_MET_ERR_PLAIN DATA_MET_ERR_COLOR
declare -a DATA_MET_FIFO_PLAIN DATA_MET_FIFO_COLOR
declare -a DATA_MET_RX_BPS DATA_MET_TX_BPS
declare -a DATA_MET_RX_PPS DATA_MET_TX_PPS
declare -a DATA_MET_RX_DROP DATA_MET_TX_DROP
declare -a DATA_MET_RX_ERR DATA_MET_TX_ERR
declare -a DATA_MET_RX_FIFO DATA_MET_TX_FIFO
declare -a DATA_NUMA DATA_PCI_SLOT DATA_NIC_VENDOR DATA_NIC_MODEL
declare -A BOND_MODE_MAP
declare -A DATA_SWITCH_DESCR
declare -A DATA_SWITCH_SERIAL
declare -a RENDER_ORDER
ROW_COUNT=0

# --- Data collection: metrics snapshots, interface enumeration, LACP validation ---
collect_data() {
    ROW_COUNT=0
    # Reset arrays for watch mode (prevent stale data accumulation)
    DATA_DEVICE=(); DATA_DRIVER=(); DATA_FIRMWARE=(); DATA_IFACE=(); DATA_MAC=(); DATA_MTU=()
    DATA_LINK_PLAIN=(); DATA_LINK_COLOR=(); DATA_SPEED_PLAIN=(); DATA_SPEED_COLOR=()
    DATA_BOND_PLAIN=(); DATA_BOND_COLOR=(); DATA_BMAC=()
    DATA_LACP_PLAIN=(); DATA_LACP_COLOR=(); DATA_LACP_PEER=(); DATA_LLDP_AGGID=()
    DATA_VLAN=(); DATA_SWITCH=(); DATA_PORT=(); DATA_PORT_DESCR=()
    DATA_OPTICS_TYPE=(); DATA_OPTICS_TX_PLAIN=(); DATA_OPTICS_TX_COLOR=()
    DATA_OPTICS_RX_PLAIN=(); DATA_OPTICS_RX_COLOR=()
    DATA_OPTICS_TX_DBM=(); DATA_OPTICS_RX_DBM=()
    DATA_OPTICS_TX_STATUS=(); DATA_OPTICS_RX_STATUS=()
    DATA_OPTICS_VENDOR=(); DATA_OPTICS_WAVELENGTH=()
    DATA_OPTICS_TX_LANES=(); DATA_OPTICS_RX_LANES=(); DATA_OPTICS_LANE_COUNT=()
    DATA_NUMA=(); DATA_PCI_SLOT=(); DATA_NIC_VENDOR=(); DATA_NIC_MODEL=()
    BOND_MODE_MAP=()
    DATA_SWITCH_DESCR=()
    DATA_SWITCH_SERIAL=()

    # --- Server hardware & OS info (for diagram) ---
    SERVER_VENDOR=""
    SERVER_MODEL=""
    SERVER_SERIAL=""
    SERVER_OS=""
    [[ -r /sys/devices/virtual/dmi/id/sys_vendor ]] && \
        SERVER_VENDOR=$(< /sys/devices/virtual/dmi/id/sys_vendor)
    [[ -r /sys/devices/virtual/dmi/id/product_name ]] && \
        SERVER_MODEL=$(< /sys/devices/virtual/dmi/id/product_name)
    [[ -r /sys/devices/virtual/dmi/id/product_serial ]] && \
        SERVER_SERIAL=$(< /sys/devices/virtual/dmi/id/product_serial)
    if [[ -r /etc/os-release ]]; then
        SERVER_OS=$(. /etc/os-release 2>/dev/null && printf '%s' "$PRETTY_NAME")
    fi

    # --- Physical topology: caches (keyed by PCI bus address without function) ---
    declare -A _LSPCI_VENDOR_CACHE _LSPCI_MODEL_CACHE
    declare -A _DMI_SLOT_CACHE  # bus_addr_no_func -> friendly slot name
    local _HAS_LSPCI=false
    if $SHOW_PHYSICAL; then
        command -v lspci &>/dev/null && _HAS_LSPCI=true
        # Build dmidecode slot designation mapping: bus address -> friendly name
        if command -v dmidecode &>/dev/null; then
            local _DMI_DESIG="" _DMI_BUS=""
            while IFS= read -r _DMI_LINE; do
                if [[ "$_DMI_LINE" =~ Designation:\ (.*) ]]; then
                    _DMI_DESIG="${BASH_REMATCH[1]}"
                elif [[ "$_DMI_LINE" =~ Bus\ Address:\ ([0-9a-fA-F:]+)\.[0-9]+ ]]; then
                    _DMI_BUS="${BASH_REMATCH[1]}"
                    [[ -n "$_DMI_DESIG" && -n "$_DMI_BUS" ]] && \
                        _DMI_SLOT_CACHE["$_DMI_BUS"]="$_DMI_DESIG"
                    _DMI_DESIG=""
                    _DMI_BUS=""
                fi
            done < <(dmidecode -t slot 2>/dev/null)
        fi
    fi

    # --- Metrics: Snapshot 1 (before data collection) ---
if $SHOW_METRICS; then
    declare -A S1_rx_bytes S1_tx_bytes S1_rx_packets S1_tx_packets
    declare -A S1_rx_dropped S1_tx_dropped S1_rx_errors S1_tx_errors
    declare -A S1_rx_fifo_errors S1_tx_fifo_errors
    METRICS_IFACES=()
    for _IFACE in /sys/class/net/*; do
        _IFACE="${_IFACE##*/}"
        [[ "$_IFACE" =~ $IFACE_SKIP_PATTERN ]] && continue
        [[ "$_IFACE" == *.* ]] && continue
        [[ ! -e "/sys/class/net/$_IFACE/device" ]] && continue
        METRICS_IFACES+=("$_IFACE")
    done
    read_iface_stats "S1" "${METRICS_IFACES[@]}"
    METRICS_START=$(date +%s)
fi

# --- Data Collection ---
for _IFACE_PATH in /sys/class/net/*; do
    IFACE="${_IFACE_PATH##*/}"
    [[ "$IFACE" =~ $IFACE_SKIP_PATTERN ]] && continue
    [[ "$IFACE" == *.* ]] && continue

    DEVICE_PATH="/sys/class/net/$IFACE/device"
    [[ ! -e "$DEVICE_PATH" ]] && continue

    DEVICE=$(basename "$(readlink -f "$DEVICE_PATH")")

    # Physical topology: NUMA node, PCI slot, NIC vendor/model
    if $SHOW_PHYSICAL; then
        local _NUMA_RAW=""
        [[ -r "$DEVICE_PATH/numa_node" ]] && _NUMA_RAW=$(< "$DEVICE_PATH/numa_node")
        if [[ "$_NUMA_RAW" =~ ^-?[0-9]+$ && "$_NUMA_RAW" -ge 0 ]]; then
            PHYS_NUMA="$_NUMA_RAW"
        else
            PHYS_NUMA="N/A"
        fi
        local _PCI_BUS_ADDR="${DEVICE%.*}"
        # Resolve friendly slot name: sysfs label (onboard) -> dmidecode -> raw bus address
        if [[ -r "$DEVICE_PATH/label" ]]; then
            PHYS_PCI_SLOT="Embedded"
        elif [[ -n "${_DMI_SLOT_CACHE[$_PCI_BUS_ADDR]+x}" ]]; then
            PHYS_PCI_SLOT="${_DMI_SLOT_CACHE[$_PCI_BUS_ADDR]}"
        else
            PHYS_PCI_SLOT="$_PCI_BUS_ADDR"
        fi
        # NIC vendor/model: use lspci cache (keyed by bus addr), fallback to sysfs PCI IDs
        if [[ -n "${_LSPCI_VENDOR_CACHE[$_PCI_BUS_ADDR]+x}" ]]; then
            PHYS_NIC_VENDOR="${_LSPCI_VENDOR_CACHE[$_PCI_BUS_ADDR]}"
            PHYS_NIC_MODEL="${_LSPCI_MODEL_CACHE[$_PCI_BUS_ADDR]}"
        elif $_HAS_LSPCI; then
            local _LSPCI_OUT
            _LSPCI_OUT=$(lspci -s "$DEVICE" -mm 2>/dev/null)
            PHYS_NIC_VENDOR=$(echo "$_LSPCI_OUT" | awk -F'"' '/^[^#]/ {print $4; exit}')
            PHYS_NIC_MODEL=$(echo "$_LSPCI_OUT" | awk -F'"' '/^[^#]/ {print $6; exit}')
            [[ -z "$PHYS_NIC_VENDOR" ]] && PHYS_NIC_VENDOR="Unknown"
            [[ -z "$PHYS_NIC_MODEL" ]] && PHYS_NIC_MODEL="Unknown"
            _LSPCI_VENDOR_CACHE["$_PCI_BUS_ADDR"]="$PHYS_NIC_VENDOR"
            _LSPCI_MODEL_CACHE["$_PCI_BUS_ADDR"]="$PHYS_NIC_MODEL"
        else
            # Fallback: raw PCI IDs from sysfs
            local _PCI_VID="" _PCI_DID=""
            [[ -r "$DEVICE_PATH/vendor" ]] && _PCI_VID=$(< "$DEVICE_PATH/vendor")
            [[ -r "$DEVICE_PATH/device" ]] && _PCI_DID=$(< "$DEVICE_PATH/device")
            PHYS_NIC_VENDOR="${_PCI_VID:-Unknown}"
            PHYS_NIC_MODEL="${_PCI_DID:-Unknown}"
            _LSPCI_VENDOR_CACHE["$_PCI_BUS_ADDR"]="$PHYS_NIC_VENDOR"
            _LSPCI_MODEL_CACHE["$_PCI_BUS_ADDR"]="$PHYS_NIC_MODEL"
        fi
    fi

    ETHTOOL_I=$(ethtool -i "$IFACE" 2>/dev/null)
    FIRMWARE=$(echo "$ETHTOOL_I" | awk -F': ' '/firmware-version/ {print $2}')
    DRIVER=$(echo "$ETHTOOL_I" | awk -F': ' '/^driver:/ {print $2}')
    MTU=$(read_sysfs "$IFACE" mtu)

    LINK_RAW=$(read_sysfs "$IFACE" operstate)
    if [[ "$LINK_RAW" == "up" ]]; then
        LINK_PLAIN="up"
        LINK_COLOR="${GREEN}up${RESET_COLOR}"
    else
        LINK_PLAIN="down"
        LINK_COLOR="${RED}down${RESET_COLOR}"
    fi

    # Filter by link state if requested
    if [[ -n "$FILTER_LINK" && "$LINK_PLAIN" != "$FILTER_LINK" ]]; then
        continue
    fi

    ETHTOOL_OUT=$(ethtool "$IFACE" 2>/dev/null)
    SPEED=$(echo "$ETHTOOL_OUT" | awk -F': ' '/Speed:/ {print $2}' | sed 's/Unknown.*/N\/A/')
    DUPLEX=$(echo "$ETHTOOL_OUT" | awk -F': ' '/Duplex:/ {print $2}' | sed 's/Unknown.*/N\/A/')
    SPEED_DUPLEX="${SPEED:-N/A} (${DUPLEX:-N/A})"

    if [[ -L "/sys/class/net/$IFACE/master" ]]; then
        BOND_MASTER=$(basename "$(readlink -f "/sys/class/net/$IFACE/master")")
    else
        BOND_MASTER="None"
    fi

    if [[ "$BOND_MASTER" != "None" ]]; then
        if [[ -z "${BOND_COLORS[$BOND_MASTER]}" ]]; then
            BOND_COLORS[$BOND_MASTER]=${COLOR_CODES[$COLOR_INDEX]}
            ((COLOR_INDEX=(COLOR_INDEX+1)%${#COLOR_CODES[@]}))
        fi
        # Detect bond mode (once per bond)
        if [[ -z "${BOND_MODE_MAP[$BOND_MASTER]+x}" ]]; then
            BOND_MODE_MAP["$BOND_MASTER"]=$(awk '/^Bonding Mode:/{$1=$2=""; sub(/^ +/,""); print}' "/proc/net/bonding/${BOND_MASTER}")
        fi
        BOND_COLOR="${BOND_COLORS[$BOND_MASTER]}${BOND_MASTER}${RESET_COLOR}"
        BOND_PLAIN="$BOND_MASTER"
        MAC=$(grep -E "Slave Interface: ${IFACE}|Permanent HW addr" "/proc/net/bonding/${BOND_MASTER}" |grep -A1 "Slave Interface: ${IFACE}"|tail -1|awk '{ print $4}' 2>/dev/null)
        BMAC=$(grep "System MAC address" "/proc/net/bonding/${BOND_MASTER}"|awk '{ print $4 }' 2>/dev/null)
    else
        BOND_COLOR="$BOND_MASTER"
        BOND_PLAIN="$BOND_MASTER"
        MAC=$(read_sysfs "$IFACE" address)
        BMAC="N/A"
    fi

    # LACP Status
    LACP_PLAIN="N/A"
    LACP_COLOR="N/A"
    LACP_PEER=""
    if $SHOW_LACP && [[ "$BOND_MASTER" != "None" && -f /proc/net/bonding/$BOND_MASTER ]]; then
        # Extract aggregator ID, actor port state, and partner MAC
        # Essential LACP bits (mask 0x3D = 61):
        #   Bit 0: Activity, Bit 2: Aggregation, Bit 3: Synchronization,
        #   Bit 4: Collecting, Bit 5: Distributing
        # Bit 1 (Timeout) is intentionally ignored — short vs long is not an error
        LACP_PLAIN=$(awk -v IFACE="$IFACE" '
            BEGIN { in_iface=0; in_actor=0; in_partner=0; agg=""; peer=""; state="" }
            $0 ~ "^Slave Interface: "IFACE"$" { in_iface=1; next }
            in_iface && /^Slave Interface:/ { in_iface=0 }
            in_iface && /Aggregator ID:/ { agg=$3 }
            in_iface && /details actor lacp pdu:/ { in_actor=1; next }
            in_actor && /^[[:space:]]*port state:/ { state=$3; in_actor=0 }
            in_iface && /details partner lacp pdu:/ { in_partner=1; next }
            in_partner && /^[[:space:]]*system mac address:/ { peer=$4; in_partner=0 }
            END {
                if (agg && peer && and(state+0, 61) == 61)
                    printf "AggID:%s Peer:%s", agg, peer
                else if (agg && peer)
                    printf "AggID:%s Peer:%s (Partial)", agg, peer
                else
                    print "Pending"
            }
        ' "/proc/net/bonding/$BOND_MASTER")

        # Extract raw partner MAC for bond-level validation
        LACP_PEER=$(awk -v IFACE="$IFACE" '
            BEGIN { in_iface=0; in_partner=0 }
            $0 ~ "^Slave Interface: "IFACE"$" { in_iface=1; next }
            in_iface && /^Slave Interface:/ { in_iface=0 }
            in_iface && /details partner lacp pdu:/ { in_partner=1; next }
            in_partner && /^[[:space:]]*system mac address:/ { print $4; exit }
        ' "/proc/net/bonding/$BOND_MASTER")

        if [[ "$LACP_PLAIN" == *"(Partial)"* ]]; then
            LACP_COLOR="${YELLOW}${LACP_PLAIN}${RESET_COLOR}"
        elif [[ "$LACP_PLAIN" == AggID* ]]; then
            LACP_COLOR="${GREEN}${LACP_PLAIN}${RESET_COLOR}"
        else
            LACP_COLOR="${RED}${LACP_PLAIN}${RESET_COLOR}"
        fi
    fi

    # LLDP Info
    LLDP_OUTPUT=$(lldpctl "$IFACE" 2>/dev/null)
    SWITCH_NAME=$(echo "$LLDP_OUTPUT" | awk -F'SysName: ' '/SysName:/ {print $2}' | xargs)
    PORT_NAME=$(echo "$LLDP_OUTPUT" | awk -F'PortID: ' '/PortID:/ {print $2}' | xargs)

    # LLDP PortDescr
    PORT_DESCR=$(echo "$LLDP_OUTPUT" | awk -F'PortDescr: ' '/PortDescr:/ {print $2}' | xargs)
    # ACI topology paths: extract policy name from pathep-[POLICY_NAME]
    if [[ "$PORT_DESCR" =~ pathep-\[([^]]+)\] ]]; then
        PORT_DESCR="VPC: ${BASH_REMATCH[1]}"
    fi
    [[ -z "$PORT_DESCR" ]] && PORT_DESCR="N/A"

    # LLDP PortAggregID (link aggregation group on the switch side)
    LLDP_AGGID=$(echo "$LLDP_OUTPUT" | awk '/PortAggregID:/ {print $NF}')
    [[ -z "$LLDP_AGGID" ]] && LLDP_AGGID="N/A"

    # Switch SysDescr & serial (for diagram — deduplicated by switch name)
    if [[ -n "$SWITCH_NAME" && -z "${DATA_SWITCH_DESCR[$SWITCH_NAME]+x}" ]]; then
        local _RAW_DESCR
        _RAW_DESCR=$(echo "$LLDP_OUTPUT" | awk -F'SysDescr:' '/SysDescr:/ {sub(/^[ \t]+/, "", $2); print $2; exit}')

        # Cisco ACI: SysDescr is "topology/pod-N/node-NNN" — useless for
        # brand/model/software.  Extract from vendor TLVs instead and build
        # a synthetic SysDescr the parser can handle.
        if [[ "$_RAW_DESCR" == topology/pod-* ]]; then
            local _ACI_MODEL _ACI_FW
            _ACI_MODEL=$(_extract_lldp_tlv "$LLDP_OUTPUT" "00,01,42" "214")
            _ACI_FW=$(_extract_lldp_tlv "$LLDP_OUTPUT" "00,01,42" "210")
            if [[ -n "$_ACI_MODEL" && -n "$_ACI_FW" ]]; then
                _RAW_DESCR="Cisco ACI ${_ACI_MODEL}, ${_ACI_FW}"
            elif [[ -n "$_ACI_MODEL" ]]; then
                _RAW_DESCR="Cisco ACI ${_ACI_MODEL}"
            else
                _RAW_DESCR="Cisco ACI"
            fi
        fi

        DATA_SWITCH_DESCR["$SWITCH_NAME"]="$_RAW_DESCR"
        DATA_SWITCH_SERIAL["$SWITCH_NAME"]=$(parse_lldp_serial "$LLDP_OUTPUT")
    fi

    # VLAN Info from LLDP
    VLAN_INFO=""
    if $SHOW_VLAN; then
        while IFS= read -r LINE; do
            VLAN_ID=$(echo "$LINE" | awk -F'VLAN: ' '{print $2}' | awk -F', ' '{print $1}'|awk '{ print $1 }')
            PVID=$(echo "$LINE" | awk -F'pvid: ' '{print $2}' | awk '{print $1}')
            [[ $PVID == "yes" ]] && VLAN_INFO+="${VLAN_ID}[P];" || VLAN_INFO+="${VLAN_ID};"
        done <<< "$(echo "$LLDP_OUTPUT" | grep -E 'VLAN:\s+[0-9]')"
        VLAN_INFO=${VLAN_INFO%, }
	VLAN_INFO="${VLAN_INFO%;}"
	if [[ -z "$VLAN_INFO" ]]; then
		VLAN_INFO="N/A"
	fi
    fi

    # Optics data collection
    if $SHOW_OPTICS; then
        parse_optics "$IFACE"
        normalize_sfp_type "$OPTICS_TYPE_ALL" "$OPTICS_BAUD" "$SPEED"

        # Build display strings with color
        TX_SUFFIX=""
        RX_SUFFIX=""
        if [[ $OPTICS_LANE_COUNT -gt 1 ]]; then
            TX_SUFFIX=$(optics_lane_variance "$OPTICS_TX_LANES")
            RX_SUFFIX=$(optics_lane_variance "$OPTICS_RX_LANES")
        fi

        colorize_optics "$OPTICS_TX_DBM" "$OPTICS_TX_STATUS" "$TX_SUFFIX"
        OPT_TX_PLAIN="$OPTICS_CLR_PLAIN"
        OPT_TX_COLOR="$OPTICS_CLR_COLOR"

        colorize_optics "$OPTICS_RX_DBM" "$OPTICS_RX_STATUS" "$RX_SUFFIX"
        OPT_RX_PLAIN="$OPTICS_CLR_PLAIN"
        OPT_RX_COLOR="$OPTICS_CLR_COLOR"
    fi

    # Store collected data
    DATA_DEVICE[ROW_COUNT]="$DEVICE"
    DATA_DRIVER[ROW_COUNT]="$DRIVER"
    DATA_FIRMWARE[ROW_COUNT]="$FIRMWARE"
    DATA_IFACE[ROW_COUNT]="$IFACE"
    DATA_MAC[ROW_COUNT]="$MAC"
    DATA_MTU[ROW_COUNT]="$MTU"
    DATA_LINK_PLAIN[ROW_COUNT]="$LINK_PLAIN"
    DATA_LINK_COLOR[ROW_COUNT]="$LINK_COLOR"
    DATA_SPEED_PLAIN[ROW_COUNT]="$SPEED_DUPLEX"
    DATA_SPEED_COLOR[ROW_COUNT]="$(colorize_speed "$SPEED_DUPLEX")"
    DATA_BOND_PLAIN[ROW_COUNT]="$BOND_PLAIN"
    DATA_BOND_COLOR[ROW_COUNT]="$BOND_COLOR"
    DATA_BMAC[ROW_COUNT]="$BMAC"
    DATA_LACP_PLAIN[ROW_COUNT]="$LACP_PLAIN"
    DATA_LACP_COLOR[ROW_COUNT]="$LACP_COLOR"
    DATA_LACP_PEER[ROW_COUNT]="$LACP_PEER"
    DATA_LLDP_AGGID[ROW_COUNT]="$LLDP_AGGID"
    DATA_VLAN[ROW_COUNT]="$VLAN_INFO"
    DATA_SWITCH[ROW_COUNT]="$SWITCH_NAME"
    DATA_PORT[ROW_COUNT]="$PORT_NAME"
    DATA_PORT_DESCR[ROW_COUNT]="$PORT_DESCR"
    if $SHOW_OPTICS; then
        DATA_OPTICS_TYPE[ROW_COUNT]="$OPTICS_TYPE"
        DATA_OPTICS_VENDOR[ROW_COUNT]="$OPTICS_VENDOR"
        DATA_OPTICS_WAVELENGTH[ROW_COUNT]="$OPTICS_WAVELENGTH"
        DATA_OPTICS_TX_DBM[ROW_COUNT]="$OPTICS_TX_DBM"
        DATA_OPTICS_RX_DBM[ROW_COUNT]="$OPTICS_RX_DBM"
        DATA_OPTICS_TX_STATUS[ROW_COUNT]="$OPTICS_TX_STATUS"
        DATA_OPTICS_RX_STATUS[ROW_COUNT]="$OPTICS_RX_STATUS"
        DATA_OPTICS_TX_PLAIN[ROW_COUNT]="$OPT_TX_PLAIN"
        DATA_OPTICS_TX_COLOR[ROW_COUNT]="$OPT_TX_COLOR"
        DATA_OPTICS_RX_PLAIN[ROW_COUNT]="$OPT_RX_PLAIN"
        DATA_OPTICS_RX_COLOR[ROW_COUNT]="$OPT_RX_COLOR"
        DATA_OPTICS_TX_LANES[ROW_COUNT]="$OPTICS_TX_LANES"
        DATA_OPTICS_RX_LANES[ROW_COUNT]="$OPTICS_RX_LANES"
        DATA_OPTICS_LANE_COUNT[ROW_COUNT]="$OPTICS_LANE_COUNT"
    fi
    if $SHOW_PHYSICAL; then
        DATA_NUMA[ROW_COUNT]="$PHYS_NUMA"
        DATA_PCI_SLOT[ROW_COUNT]="$PHYS_PCI_SLOT"
        DATA_NIC_VENDOR[ROW_COUNT]="$PHYS_NIC_VENDOR"
        DATA_NIC_MODEL[ROW_COUNT]="$PHYS_NIC_MODEL"
    fi
    ((ROW_COUNT++))
done

# --- Guard: no interfaces found ---
if [[ $ROW_COUNT -eq 0 ]]; then
    echo "No physical network interfaces found." >&2
    exit 0
fi

# --- Bond-level LACP consistency validation ---
if $SHOW_LACP; then
    # Collect unique bonds and their member indices
    declare -A BOND_MEMBER_INDICES
    for ((i = 0; i < ROW_COUNT; i++)); do
        local_bond="${DATA_BOND_PLAIN[$i]}"
        [[ "$local_bond" == "None" ]] && continue
        BOND_MEMBER_INDICES["$local_bond"]+="$i "
    done

    for BOND_NAME in "${!BOND_MEMBER_INDICES[@]}"; do
        read -ra MEMBERS <<< "${BOND_MEMBER_INDICES[$BOND_NAME]}"
        [[ ${#MEMBERS[@]} -lt 2 ]] && continue

        # --- Check 1: Partner MAC consistency across all bond members ---
        declare -A PEER_MACS
        for IDX in "${MEMBERS[@]}"; do
            PEER="${DATA_LACP_PEER[$IDX]}"
            [[ -n "$PEER" ]] && PEER_MACS["$PEER"]=1
        done
        PEER_MAC_COUNT=${#PEER_MACS[@]}
        unset PEER_MACS

        if [[ $PEER_MAC_COUNT -gt 1 ]]; then
            for IDX in "${MEMBERS[@]}"; do
                DATA_LACP_PLAIN[IDX]="${DATA_LACP_PLAIN[IDX]} [Peer Mismatch]"
                DATA_LACP_COLOR[IDX]="${RED}${DATA_LACP_PLAIN[IDX]}${RESET_COLOR}"
            done
        fi

        # --- Check 2: Same-switch PortAggregID consistency ---
        # Group members by switch, then check for AggID mismatches
        declare -A SWITCH_AGGIDS
        for IDX in "${MEMBERS[@]}"; do
            SW="${DATA_SWITCH[IDX]}"
            AGGID="${DATA_LLDP_AGGID[IDX]}"
            [[ -z "$SW" || "$AGGID" == "N/A" ]] && continue
            if [[ -n "${SWITCH_AGGIDS[$SW]}" ]]; then
                SWITCH_AGGIDS["$SW"]+=" $AGGID"
            else
                SWITCH_AGGIDS["$SW"]="$AGGID"
            fi
        done

        for SW in "${!SWITCH_AGGIDS[@]}"; do
            read -ra AGGID_LIST <<< "${SWITCH_AGGIDS[$SW]}"
            declare -A UNIQUE_AGGIDS
            for AID in "${AGGID_LIST[@]}"; do
                UNIQUE_AGGIDS["$AID"]=1
            done
            if [[ ${#UNIQUE_AGGIDS[@]} -gt 1 ]]; then
                for IDX in "${MEMBERS[@]}"; do
                    [[ "${DATA_SWITCH[IDX]}" != "$SW" ]] && continue
                    # Only tag if not already flagged with Peer Mismatch
                    if [[ "${DATA_LACP_PLAIN[IDX]}" != *"Mismatch"* ]]; then
                        DATA_LACP_PLAIN[IDX]="${DATA_LACP_PLAIN[IDX]} [AE Mismatch on ${SW}]"
                        DATA_LACP_COLOR[IDX]="${RED}${DATA_LACP_PLAIN[IDX]}${RESET_COLOR}"
                    fi
                done
            fi
            unset UNIQUE_AGGIDS
        done
        unset SWITCH_AGGIDS
    done
    unset BOND_MEMBER_INDICES
fi

# --- Metrics: Sleep, Snapshot 2, Delta Computation ---
if $SHOW_METRICS; then
    # Compute remaining sleep time
    METRICS_NOW=$(date +%s)
    METRICS_ELAPSED_SO_FAR=$((METRICS_NOW - METRICS_START))
    METRICS_REMAINING=$((METRICS_DURATION - METRICS_ELAPSED_SO_FAR))
    (( METRICS_REMAINING < 0 )) && METRICS_REMAINING=0

    # Sleep with progress bar (table format + TTY on stderr only)
    if (( METRICS_REMAINING > 0 )); then
        if [[ "$OUTPUT_FORMAT" == "table" && -t 2 ]]; then
            for ((s = 1; s <= METRICS_REMAINING; s++)); do
                TOTAL_ELAPSED=$((METRICS_ELAPSED_SO_FAR + s))
                FILLED=$((TOTAL_ELAPSED * 30 / METRICS_DURATION))
                EMPTY=$((30 - FILLED))
                BAR=$(printf '%*s' "$FILLED" '' | tr ' ' '#')
                BAR+=$(printf '%*s' "$EMPTY" '' | tr ' ' '.')
                printf '\r📊 Sampling metrics: [%s] %d/%ds' "$BAR" "$TOTAL_ELAPSED" "$METRICS_DURATION" >&2
                sleep 1
            done
            printf '\r%*s\r' 60 '' >&2
        else
            sleep "$METRICS_REMAINING"
        fi
    fi

    # Snapshot 2
    declare -A S2_rx_bytes S2_tx_bytes S2_rx_packets S2_tx_packets
    declare -A S2_rx_dropped S2_tx_dropped S2_rx_errors S2_tx_errors
    declare -A S2_rx_fifo_errors S2_tx_fifo_errors
    read_iface_stats "S2" "${METRICS_IFACES[@]}"
    METRICS_END=$(date +%s)
    METRICS_ELAPSED=$((METRICS_END - METRICS_START))
    (( METRICS_ELAPSED < 1 )) && METRICS_ELAPSED=1

    # Delta computation per row
    for ((i = 0; i < ROW_COUNT; i++)); do
        local_iface="${DATA_IFACE[i]}"

        # Compute raw deltas (clamp negative to 0 for 32-bit counter wraps)
        D_RX_BYTES=$(( S2_rx_bytes["$local_iface"] - S1_rx_bytes["$local_iface"] ))
        D_TX_BYTES=$(( S2_tx_bytes["$local_iface"] - S1_tx_bytes["$local_iface"] ))
        D_RX_PKTS=$(( S2_rx_packets["$local_iface"] - S1_rx_packets["$local_iface"] ))
        D_TX_PKTS=$(( S2_tx_packets["$local_iface"] - S1_tx_packets["$local_iface"] ))
        D_RX_DROP=$(( S2_rx_dropped["$local_iface"] - S1_rx_dropped["$local_iface"] ))
        D_TX_DROP=$(( S2_tx_dropped["$local_iface"] - S1_tx_dropped["$local_iface"] ))
        D_RX_ERR=$(( S2_rx_errors["$local_iface"] - S1_rx_errors["$local_iface"] ))
        D_TX_ERR=$(( S2_tx_errors["$local_iface"] - S1_tx_errors["$local_iface"] ))
        D_RX_FIFO=$(( S2_rx_fifo_errors["$local_iface"] - S1_rx_fifo_errors["$local_iface"] ))
        D_TX_FIFO=$(( S2_tx_fifo_errors["$local_iface"] - S1_tx_fifo_errors["$local_iface"] ))

        # Clamp negative deltas (counter wrap)
        for _VAR in D_RX_BYTES D_TX_BYTES D_RX_PKTS D_TX_PKTS \
                    D_RX_DROP D_TX_DROP D_RX_ERR D_TX_ERR \
                    D_RX_FIFO D_TX_FIFO; do
            declare -n _REF="$_VAR"
            (( _REF < 0 )) && _REF=0
        done
        unset -n _REF

        # Rates (per second)
        RX_BPS=$((D_RX_BYTES / METRICS_ELAPSED))
        TX_BPS=$((D_TX_BYTES / METRICS_ELAPSED))
        RX_PPS=$((D_RX_PKTS / METRICS_ELAPSED))
        TX_PPS=$((D_TX_PKTS / METRICS_ELAPSED))

        # Store raw values
        DATA_MET_RX_BPS[i]=$RX_BPS
        DATA_MET_TX_BPS[i]=$TX_BPS
        DATA_MET_RX_PPS[i]=$RX_PPS
        DATA_MET_TX_PPS[i]=$TX_PPS
        DATA_MET_RX_DROP[i]=$D_RX_DROP
        DATA_MET_TX_DROP[i]=$D_TX_DROP
        DATA_MET_RX_ERR[i]=$D_RX_ERR
        DATA_MET_TX_ERR[i]=$D_TX_ERR
        DATA_MET_RX_FIFO[i]=$D_RX_FIFO
        DATA_MET_TX_FIFO[i]=$D_TX_FIFO

        # Plain compound strings for table display
        RX_BW_STR=$(human_bitrate "$RX_BPS")
        TX_BW_STR=$(human_bitrate "$TX_BPS")
        DATA_MET_BW_PLAIN[i]="Rx:${RX_BW_STR} Tx:${TX_BW_STR}"

        DATA_MET_PPS_PLAIN[i]="Rx:${RX_PPS} Tx:${TX_PPS}"

        DATA_MET_DROP_PLAIN[i]="Rx:${D_RX_DROP} Tx:${D_TX_DROP}"
        DATA_MET_ERR_PLAIN[i]="Rx:${D_RX_ERR} Tx:${D_TX_ERR}"
        DATA_MET_FIFO_PLAIN[i]="Rx:${D_RX_FIFO} Tx:${D_TX_FIFO}"

        # Color strings — drops/errors/fifo: RED if > 0
        RX_BW_CLR="${RX_BW_STR}"
        TX_BW_CLR="${TX_BW_STR}"
        RX_PPS_CLR="${RX_PPS}"
        TX_PPS_CLR="${TX_PPS}"

        RX_DROP_CLR=$(colorize_nonzero "$D_RX_DROP")
        TX_DROP_CLR=$(colorize_nonzero "$D_TX_DROP")
        DATA_MET_DROP_COLOR[i]="Rx:${RX_DROP_CLR} Tx:${TX_DROP_CLR}"

        RX_ERR_CLR=$(colorize_nonzero "$D_RX_ERR")
        TX_ERR_CLR=$(colorize_nonzero "$D_TX_ERR")
        DATA_MET_ERR_COLOR[i]="Rx:${RX_ERR_CLR} Tx:${TX_ERR_CLR}"

        RX_FIFO_CLR=$(colorize_nonzero "$D_RX_FIFO")
        TX_FIFO_CLR=$(colorize_nonzero "$D_TX_FIFO")
        DATA_MET_FIFO_COLOR[i]="Rx:${RX_FIFO_CLR} Tx:${TX_FIFO_CLR}"

        # Bandwidth and PPS color (initially no color; bond variance applied next)
        DATA_MET_BW_COLOR[i]="Rx:${RX_BW_CLR} Tx:${TX_BW_CLR}"
        DATA_MET_PPS_COLOR[i]="Rx:${RX_PPS_CLR} Tx:${TX_PPS_CLR}"
    done

    # --- Bond variance check ---
    # For non-active-backup bonds with >=2 members, flag if min < 70% of max
    declare -A MET_BOND_MEMBERS
    for ((i = 0; i < ROW_COUNT; i++)); do
        local_bond="${DATA_BOND_PLAIN[i]}"
        [[ "$local_bond" == "None" ]] && continue
        MET_BOND_MEMBERS["$local_bond"]+="$i "
    done

    # Helper: get metric value for a given index
    _met_val() {
        local metric="$1" idx="$2"
        case "$metric" in
            RX_BPS) echo "${DATA_MET_RX_BPS[idx]}" ;;
            TX_BPS) echo "${DATA_MET_TX_BPS[idx]}" ;;
            RX_PPS) echo "${DATA_MET_RX_PPS[idx]}" ;;
            TX_PPS) echo "${DATA_MET_TX_PPS[idx]}" ;;
        esac
    }

    for BOND_NAME in "${!MET_BOND_MEMBERS[@]}"; do
        is_active_backup "$BOND_NAME" && continue
        read -ra MBR_INDICES <<< "${MET_BOND_MEMBERS[$BOND_NAME]}"
        [[ ${#MBR_INDICES[@]} -lt 2 ]] && continue

        # Check 4 metrics: RX_BPS, TX_BPS, RX_PPS, TX_PPS
        for METRIC in RX_BPS TX_BPS RX_PPS TX_PPS; do
            MIN_VAL=999999999999999 MAX_VAL=0
            for IDX in "${MBR_INDICES[@]}"; do
                MVAL=$(_met_val "$METRIC" "$IDX")
                (( MVAL < MIN_VAL )) && MIN_VAL=$MVAL
                (( MVAL > MAX_VAL )) && MAX_VAL=$MVAL
            done

            # Skip if max is 0 (no traffic)
            (( MAX_VAL == 0 )) && continue

            # Check if min < 70% of max
            THRESHOLD=$(( MAX_VAL * 70 / 100 ))
            (( MIN_VAL >= THRESHOLD )) && continue

            # Flag minimum value(s) with RED
            for IDX in "${MBR_INDICES[@]}"; do
                MVAL=$(_met_val "$METRIC" "$IDX")
                (( MVAL > THRESHOLD )) && continue

                # Rebuild the color string for this index
                case "$METRIC" in
                    RX_BPS)
                        RX_STR="${RED}$(human_bitrate "${DATA_MET_RX_BPS[IDX]}")${RESET_COLOR}"
                        TX_STR=$(human_bitrate "${DATA_MET_TX_BPS[IDX]}")
                        # Preserve TX color if it was already flagged
                        if [[ "${DATA_MET_BW_COLOR[IDX]}" == *$'\033'*"Tx:"* ]]; then
                            TX_PART="${DATA_MET_BW_COLOR[IDX]#*Tx:}"
                            DATA_MET_BW_COLOR[IDX]="Rx:${RX_STR} Tx:${TX_PART}"
                        else
                            DATA_MET_BW_COLOR[IDX]="Rx:${RX_STR} Tx:${TX_STR}"
                        fi
                        ;;
                    TX_BPS)
                        RX_PART="${DATA_MET_BW_COLOR[IDX]%%Tx:*}"
                        TX_STR="${RED}$(human_bitrate "${DATA_MET_TX_BPS[IDX]}")${RESET_COLOR}"
                        DATA_MET_BW_COLOR[IDX]="${RX_PART}Tx:${TX_STR}"
                        ;;
                    RX_PPS)
                        RX_STR="${RED}${DATA_MET_RX_PPS[IDX]}${RESET_COLOR}"
                        TX_STR="${DATA_MET_TX_PPS[IDX]}"
                        if [[ "${DATA_MET_PPS_COLOR[IDX]}" == *$'\033'*"Tx:"* ]]; then
                            TX_PART="${DATA_MET_PPS_COLOR[IDX]#*Tx:}"
                            DATA_MET_PPS_COLOR[IDX]="Rx:${RX_STR} Tx:${TX_PART}"
                        else
                            DATA_MET_PPS_COLOR[IDX]="Rx:${RX_STR} Tx:${TX_STR}"
                        fi
                        ;;
                    TX_PPS)
                        RX_PART="${DATA_MET_PPS_COLOR[IDX]%%Tx:*}"
                        TX_STR="${RED}${DATA_MET_TX_PPS[IDX]}${RESET_COLOR}"
                        DATA_MET_PPS_COLOR[IDX]="${RX_PART}Tx:${TX_STR}"
                        ;;
                esac
            done
        done
    done
    unset MET_BOND_MEMBERS
fi
}

# --- Layout computation: column widths and render order ---
compute_layout() {

# --- Compute Dynamic Column Widths ---
COL_W_DEVICE=$(max_width "Device" "${DATA_DEVICE[@]}")
COL_W_DRIVER=$(max_width "Driver" "${DATA_DRIVER[@]}")
COL_W_FIRMWARE=$(max_width "Firmware" "${DATA_FIRMWARE[@]}")
COL_W_IFACE=$(max_width "Interface" "${DATA_IFACE[@]}")
COL_W_MAC=$(max_width "MAC Address" "${DATA_MAC[@]}")
COL_W_MTU=$(max_width "MTU" "${DATA_MTU[@]}")
COL_W_LINK=$(max_width "Link" "${DATA_LINK_PLAIN[@]}")
COL_W_SPEED=$(max_width "Speed/Duplex" "${DATA_SPEED_PLAIN[@]}")
COL_W_BOND=$(max_width "Parent Bond" "${DATA_BOND_PLAIN[@]}")
COL_W_BMAC=$(max_width "Bond MAC" "${DATA_BMAC[@]}")
COL_W_LACP=$(max_width "LACP Status" "${DATA_LACP_PLAIN[@]}")
COL_W_VLAN=$(max_width "VLAN" "${DATA_VLAN[@]}")
COL_W_SWITCH=$(max_width "Switch Name" "${DATA_SWITCH[@]}")
COL_W_PORT=$(max_width "Port Name" "${DATA_PORT[@]}")
COL_W_PORT_DESCR=$(max_width "Port Descr" "${DATA_PORT_DESCR[@]}")

if $SHOW_PHYSICAL; then
    COL_W_NUMA=$(max_width "NUMA" "${DATA_NUMA[@]}")
    COL_W_PCI_SLOT=$(max_width "PCI Slot" "${DATA_PCI_SLOT[@]}")
    COL_W_NIC_VENDOR=$(max_width "NIC Vendor" "${DATA_NIC_VENDOR[@]}")
    COL_W_NIC_MODEL=$(max_width "NIC Model" "${DATA_NIC_MODEL[@]}")
fi

if $SHOW_OPTICS; then
    COL_W_OPT_TYPE=$(max_width "SFP Type" "${DATA_OPTICS_TYPE[@]}")
    COL_W_OPT_TX=$(max_width "Optics Tx" "${DATA_OPTICS_TX_PLAIN[@]}")
    COL_W_OPT_RX=$(max_width "Optics Rx" "${DATA_OPTICS_RX_PLAIN[@]}")
fi

if $SHOW_METRICS; then
    COL_W_MET_BW=$(max_width "Throughput" "${DATA_MET_BW_PLAIN[@]}")
    COL_W_MET_PPS=$(max_width "Packets/s" "${DATA_MET_PPS_PLAIN[@]}")
    COL_W_MET_DROP=$(max_width "Drops" "${DATA_MET_DROP_PLAIN[@]}")
    COL_W_MET_ERR=$(max_width "Errors" "${DATA_MET_ERR_PLAIN[@]}")
    COL_W_MET_FIFO=$(max_width "FIFO Errors" "${DATA_MET_FIFO_PLAIN[@]}")
fi

# --- Column Gap ---
if [[ -n "${FIELD_SEP}" ]]; then
    COL_GAP=" ${FIELD_SEP} "
else
    COL_GAP="   "
fi
COL_GAP_WIDTH=${#COL_GAP}

# --- Build Render Order ---
RENDER_ORDER=()
if $SORT_BY_BOND; then
    # Collect unique bond names (excluding None)
    declare -A SEEN_BONDS
    declare -a UNIQUE_BONDS
    for ((i = 0; i < ROW_COUNT; i++)); do
        B="${DATA_BOND_PLAIN[$i]}"
        if [[ "$B" != "None" && -z "${SEEN_BONDS[$B]+x}" ]]; then
            SEEN_BONDS[$B]=1
            UNIQUE_BONDS+=("$B")
        fi
    done
    # Sort bond names
    mapfile -t SORTED_BONDS < <(printf '%s\n' "${UNIQUE_BONDS[@]}" | sort)

    # Append indices for each bond, sub-sorted by physical topology when enabled
    for BOND in "${SORTED_BONDS[@]}"; do
        if $SHOW_PHYSICAL; then
            declare -a _BOND_PAIRS=()
            for ((i = 0; i < ROW_COUNT; i++)); do
                [[ "${DATA_BOND_PLAIN[$i]}" == "$BOND" ]] && \
                    _BOND_PAIRS+=("$(printf '%s|%s|%s|%d' "${DATA_NUMA[$i]}" "${DATA_PCI_SLOT[$i]}" "${DATA_IFACE[$i]}" "$i")")
            done
            mapfile -t _BOND_PAIRS < <(printf '%s\n' "${_BOND_PAIRS[@]}" | sort -t'|' -k1,1 -k2,2 -k3,3)
            for ENTRY in "${_BOND_PAIRS[@]}"; do
                RENDER_ORDER+=("${ENTRY##*|}")
            done
            unset _BOND_PAIRS
        else
            for ((i = 0; i < ROW_COUNT; i++)); do
                [[ "${DATA_BOND_PLAIN[$i]}" == "$BOND" ]] && RENDER_ORDER+=("$i")
            done
        fi
    done

    # Append unbonded interfaces sorted by physical topology or name
    declare -a UNBONDED_PAIRS
    for ((i = 0; i < ROW_COUNT; i++)); do
        if [[ "${DATA_BOND_PLAIN[$i]}" == "None" ]]; then
            if $SHOW_PHYSICAL; then
                UNBONDED_PAIRS+=("$(printf '%s|%s|%s|%d' "${DATA_NUMA[$i]}" "${DATA_PCI_SLOT[$i]}" "${DATA_IFACE[$i]}" "$i")")
            else
                UNBONDED_PAIRS+=("${DATA_IFACE[$i]} $i")
            fi
        fi
    done
    if [[ ${#UNBONDED_PAIRS[@]} -gt 0 ]]; then
        if $SHOW_PHYSICAL; then
            mapfile -t UNBONDED_PAIRS < <(printf '%s\n' "${UNBONDED_PAIRS[@]}" | sort -t'|' -k1,1 -k2,2 -k3,3)
            for ENTRY in "${UNBONDED_PAIRS[@]}"; do
                RENDER_ORDER+=("${ENTRY##*|}")
            done
        else
            mapfile -t UNBONDED_PAIRS < <(printf '%s\n' "${UNBONDED_PAIRS[@]}" | sort)
            for ENTRY in "${UNBONDED_PAIRS[@]}"; do
                RENDER_ORDER+=("${ENTRY##* }")
            done
        fi
    fi
elif $SHOW_PHYSICAL; then
    # Sort by NUMA -> PCI Slot -> interface name
    declare -a _PHYS_PAIRS
    for ((i = 0; i < ROW_COUNT; i++)); do
        _PHYS_PAIRS+=("$(printf '%s|%s|%s|%d' "${DATA_NUMA[$i]}" "${DATA_PCI_SLOT[$i]}" "${DATA_IFACE[$i]}" "$i")")
    done
    mapfile -t _PHYS_PAIRS < <(printf '%s\n' "${_PHYS_PAIRS[@]}" | sort -t'|' -k1,1 -k2,2 -k3,3)
    for ENTRY in "${_PHYS_PAIRS[@]}"; do
        RENDER_ORDER+=("${ENTRY##*|}")
    done
    unset _PHYS_PAIRS
else
    for ((i = 0; i < ROW_COUNT; i++)); do
        RENDER_ORDER+=("$i")
    done
fi
}

# --- DOT Diagram Helpers ---

# Sanitize a string to a valid DOT identifier
dot_id() {
    local STR="$1"
    STR="${STR//[^a-zA-Z0-9_]/_}"
    printf '%s' "$STR"
}

# Escape HTML entities for DOT HTML labels
dot_escape() {
    local STR="$1"
    STR="${STR//&/&amp;}"
    STR="${STR//</&lt;}"
    STR="${STR//>/&gt;}"
    STR="${STR//\"/&quot;}"
    printf '%s' "$STR"
}

# Decode comma-separated hex bytes to an ASCII string.
# Example: "58,48,33,31" → "XH31"
_decode_hex_ascii() {
    local _HEX="$1" _OUT="" _BYTE
    local _IFS_SAVE="$IFS"
    IFS=',' read -ra _BYTES <<< "$_HEX"
    IFS="$_IFS_SAVE"
    for _BYTE in "${_BYTES[@]}"; do
        _BYTE="${_BYTE// /}"
        [[ -z "$_BYTE" ]] && continue
        printf -v _CH '\\x%s' "$_BYTE"
        printf -v _CH '%b' "$_CH"
        _OUT+="$_CH"
    done
    printf '%s' "$_OUT"
}

# Extract a value from LLDP vendor-specific TLVs by OUI and SubType.
# Usage: _extract_lldp_tlv "LLDP_OUTPUT" "OUI" "SUBTYPE"
# Example: _extract_lldp_tlv "$LLDP_OUTPUT" "00,01,42" "214"
# Returns the decoded ASCII string, or empty if not found.
_extract_lldp_tlv() {
    local _LLDP="$1" _OUI="$2" _SUBTYPE="$3" _LINE _HEX
    _LINE=$(echo "$_LLDP" | grep "OUI: ${_OUI}, SubType: ${_SUBTYPE}," | head -1)
    [[ -z "$_LINE" ]] && return
    _HEX="${_LINE##*Len: }"
    _HEX="${_HEX#* }"
    _decode_hex_ascii "$_HEX"
}

# Extract switch serial number from LLDP vendor-specific TLVs.
# Supports multiple vendors via OUI matching; extensible by adding new
# OUI/SubType patterns below. Returns empty string if no match.
#
# Vendor support:
#   Cisco ACI — OUI 00,01,42  SubType 212 (ASCII-encoded serial)
#   Juniper   — OUI 00,90,69  SubType 1   (ASCII-encoded serial)
#   Cisco     — OUI 00,01,42  SubType 11  (ASCII-encoded serial)
#   HPE       — OUI 00,12,0F  SubType 5   (binary; serial SubType unknown)
parse_lldp_serial() {
    local _LLDP="$1" _RESULT

    # Cisco ACI: OUI 00,01,42, SubType: 212 (more specific, checked first)
    _RESULT=$(_extract_lldp_tlv "$_LLDP" "00,01,42" "212")
    [[ -n "$_RESULT" ]] && { printf '%s' "$_RESULT"; return; }

    # Juniper: OUI 00,90,69, SubType: 1
    _RESULT=$(_extract_lldp_tlv "$_LLDP" "00,90,69" "1")
    [[ -n "$_RESULT" ]] && { printf '%s' "$_RESULT"; return; }

    # Cisco: OUI 00,01,42, SubType: 11
    _RESULT=$(_extract_lldp_tlv "$_LLDP" "00,01,42" "11")
    [[ -n "$_RESULT" ]] && { printf '%s' "$_RESULT"; return; }

    # HPE: OUI 00,12,0F — known SubType 5 carries binary data (not serial).
    # Serial SubType is currently undocumented; add extraction here when known.
}

# Parse switch SysDescr into brand, model, and software components.
# Uses nameref variables: sets _BRAND, _MODEL, _SOFTWARE in the caller.
# Falls back to truncated raw string if no known vendor pattern matches.
parse_switch_descr() {
    local _DESCR="$1"
    local -n _BRAND="$2" _MODEL="$3" _SOFTWARE="$4"
    _BRAND="" _MODEL="" _SOFTWARE=""

    [[ -z "$_DESCR" ]] && return

    # Cisco ACI: synthetic "Cisco ACI N9K-C93180YC-FX, n9000-16.0(8f)"
    if [[ "$_DESCR" == "Cisco ACI"* ]]; then
        _BRAND="Cisco ACI"
        if [[ "$_DESCR" =~ Cisco\ ACI\ ([^,]+),\ (.+) ]]; then
            _MODEL="${BASH_REMATCH[1]}"
            _SOFTWARE="${BASH_REMATCH[2]}"
        elif [[ "$_DESCR" =~ Cisco\ ACI\ ([^,]+) ]]; then
            _MODEL="${BASH_REMATCH[1]}"
        fi
        return
    fi

    # Juniper: "Juniper Networks, Inc. qfx5120-48y-8c Ethernet Switch, kernel JUNOS 23.4R2-S4.11, ..."
    if [[ "$_DESCR" == "Juniper Networks"* ]]; then
        _BRAND="Juniper"
        if [[ "$_DESCR" =~ Juniper\ Networks,\ Inc\.\ ([^ ]+) ]]; then
            _MODEL="${BASH_REMATCH[1]}"
        fi
        if [[ "$_DESCR" =~ JUNOS\ ([^,]+) ]]; then
            _SOFTWARE="JUNOS ${BASH_REMATCH[1]}"
        fi
        return
    fi

    # Cisco NX-OS: "Cisco NX-OS(tm) n9000, Software (n9000-dk9), Version 9.3(8), ..."
    if [[ "$_DESCR" == "Cisco NX-OS"* ]]; then
        _BRAND="Cisco"
        if [[ "$_DESCR" =~ NX-OS\(tm\)\ ([^,]+) ]]; then
            _MODEL="${BASH_REMATCH[1]}"
        fi
        if [[ "$_DESCR" =~ Version\ ([^,]+) ]]; then
            _SOFTWARE="NX-OS ${BASH_REMATCH[1]}"
        fi
        return
    fi

    # Cisco IOS: "Cisco IOS Software, ... (cat3k_caa-universalk9), Version 16.12.3a, ..."
    if [[ "$_DESCR" == "Cisco IOS"* ]]; then
        _BRAND="Cisco"
        local _PAREN_RE='[(]([^)]+)[)]'
        if [[ "$_DESCR" =~ $_PAREN_RE ]]; then
            _MODEL="${BASH_REMATCH[1]}"
        fi
        if [[ "$_DESCR" =~ Version\ ([^,]+) ]]; then
            _SOFTWARE="IOS ${BASH_REMATCH[1]}"
        fi
        return
    fi

    # Arista: "Arista Networks EOS version 4.23.0F running on an Arista Networks DCS-7050CX3-32S"
    if [[ "$_DESCR" == "Arista"* ]]; then
        _BRAND="Arista"
        if [[ "$_DESCR" =~ (DCS-[^ ]+) ]]; then
            _MODEL="${BASH_REMATCH[1]}"
        fi
        if [[ "$_DESCR" =~ EOS\ version\ ([^ ]+) ]]; then
            _SOFTWARE="EOS ${BASH_REMATCH[1]}"
        fi
        return
    fi

    # HPE: "HPE Networking Instant On Switch 24p Gigabit 4p SFP+ 1930 JL682A, InstantOn_1930_3.0.0.0 (12)"
    if [[ "$_DESCR" == "HPE "* ]]; then
        _BRAND="HPE"
        if [[ "$_DESCR" =~ ,\ (.+) ]]; then
            _SOFTWARE="${BASH_REMATCH[1]}"
        fi
        # Extract HPE product number (e.g., JL682A, JG932A)
        if [[ "$_DESCR" =~ ([A-Z][A-Z][0-9]+[A-Z]),? ]]; then
            _MODEL="${BASH_REMATCH[1]}"
        fi
        return
    fi

    # Fallback: truncate to 60 chars, show as brand (no model/software split)
    if (( ${#_DESCR} > 60 )); then
        _BRAND="${_DESCR:0:57}..."
    else
        _BRAND="$_DESCR"
    fi
}

# Map speed (Mb/s) to edge pen width
dot_penwidth() {
    local RAW="$1"
    local NUM="${RAW%%[^0-9]*}"
    if [[ "$NUM" =~ ^[0-9]+$ ]]; then
        if (( NUM >= 800000 )); then
            echo "6.0"
        elif (( NUM >= 400000 )); then
            echo "5.0"
        elif (( NUM >= 100000 )); then
            echo "4.0"
        elif (( NUM >= 25000 )); then
            echo "3.0"
        elif (( NUM >= 10000 )); then
            echo "2.5"
        elif (( NUM >= 1000 )); then
            echo "2.0"
        else
            echo "1.5"
        fi
    else
        echo "1.0"
    fi
}

# Map speed (Mb/s) to human-readable tier label
dot_speed_tier() {
    local RAW="$1"
    local NUM="${RAW%%[^0-9]*}"
    if [[ "$NUM" =~ ^[0-9]+$ ]]; then
        if (( NUM >= 800000 )); then
            echo "800GbE"
        elif (( NUM >= 400000 )); then
            echo "400GbE"
        elif (( NUM >= 100000 )); then
            echo "100GbE"
        elif (( NUM >= 25000 )); then
            echo "25GbE"
        elif (( NUM >= 10000 )); then
            echo "10GbE"
        elif (( NUM >= 1000 )); then
            echo "1GbE"
        else
            echo "Fast"
        fi
    fi
}

# Generate DOT graph source from collected data
generate_dot() {
    local HOSTNAME
    HOSTNAME=$(hostname -f 2>/dev/null || hostname)

    # --- Catppuccin Mocha-inspired dark theme colors ---
    local BG_COLOR="#1e1e2e"
    local FG_COLOR="#cdd6f4"
    local SURFACE_COLOR="#313244"
    local BORDER_COLOR="#585b70"
    local GREEN_COLOR="#a6e3a1"
    local RED_COLOR="#f38ba8"
    local PEACH_COLOR="#fab387"
    local MAUVE_COLOR="#cba6f7"
    local GRAY_COLOR="#6c7086"
    local TEXT_COLOR="#cdd6f4"
    local SUBTEXT_COLOR="#a6adc8"
    local RX_ARROW_COLOR="#a6e3a1"   # Green — receive
    local TX_ARROW_COLOR="#89b4fa"   # Blue — transmit
    local NUMA_COLOR="#cba6f7"       # Mauve — NUMA nodes
    local NIC_CARD_COLOR="#94e2d5"   # Teal — NIC card nodes

    # Per-bond color palette (Catppuccin Mocha accents)
    local -a DOT_BOND_COLORS=(
        "#89b4fa"   # Blue
        "#f9e2af"   # Yellow
        "#94e2d5"   # Teal
        "#f5c2e7"   # Pink
        "#b4befe"   # Lavender
        "#eba0ac"   # Maroon
        "#74c7ec"   # Sapphire
        "#fab387"   # Peach
    )

    # Categorize interfaces: bond members vs standalone
    declare -A BOND_MEMBERS  # bond_name -> space-separated row indices
    declare -a STANDALONE_INDICES
    declare -A SEEN_SWITCHES  # switch_name -> 1
    declare -A BOND_COLOR_MAP # bond_name -> color

    for ((i = 0; i < ROW_COUNT; i++)); do
        local BOND="${DATA_BOND_PLAIN[$i]}"
        if [[ "$BOND" != "None" ]]; then
            BOND_MEMBERS["$BOND"]+="$i "
        else
            STANDALONE_INDICES+=("$i")
        fi

        local SW="${DATA_SWITCH[$i]}"
        if [[ -n "$SW" ]]; then
            SEEN_SWITCHES["$SW"]=1
        fi
    done

    # Assign colors to bonds in sorted order
    local COLOR_IDX=0
    for BOND_NAME in $(printf '%s\n' "${!BOND_MEMBERS[@]}" | sort); do
        BOND_COLOR_MAP["$BOND_NAME"]="${DOT_BOND_COLORS[$((COLOR_IDX % ${#DOT_BOND_COLORS[@]}))]}"
        ((COLOR_IDX++))
    done

    # --- Emit DOT source ---
    cat <<DOTHEADER
digraph nic_xray {
    rankdir=LR;
    bgcolor="$BG_COLOR";
    fontname="Helvetica,Arial,sans-serif";
    fontcolor="$FG_COLOR";
    pad="0.5";
    nodesep="0.6";
    ranksep="1.5";
    node [fontname="Helvetica,Arial,sans-serif", fontcolor="$TEXT_COLOR", fontsize=11];
    edge [fontname="Helvetica,Arial,sans-serif", fontcolor="$SUBTEXT_COLOR", fontsize=10];
    label=<<FONT POINT-SIZE="9" COLOR="$GRAY_COLOR">Generated by nic-xray v$SCRIPT_VERSION &mdash; &copy; $SCRIPT_YEAR Ciro Iriarte<BR/>$(date '+%Y-%m-%d %H:%M:%S %:z')</FONT>>;
    labeljust=r;
    labelloc=b;

DOTHEADER

    # --- Server node ---
    printf '    server [shape=plain, label=<\n'
    printf '        <TABLE BORDER="1" CELLBORDER="0" CELLSPACING="4" CELLPADDING="6" '
    printf 'BGCOLOR="%s" COLOR="%s">\n' "$SURFACE_COLOR" "$BORDER_COLOR"
    printf '        <TR><TD COLSPAN="2"><FONT POINT-SIZE="14" COLOR="%s"><B>%s</B></FONT></TD></TR>\n' \
        "$MAUVE_COLOR" "$(dot_escape "$HOSTNAME")"
    if [[ -n "$SERVER_VENDOR" || -n "$SERVER_MODEL" ]]; then
        local _SERVER_HW="${SERVER_VENDOR}${SERVER_MODEL:+ $SERVER_MODEL}"
        printf '        <TR><TD COLSPAN="2"><FONT POINT-SIZE="9" COLOR="%s">%s</FONT></TD></TR>\n' \
            "$SUBTEXT_COLOR" "$(dot_escape "$_SERVER_HW")"
    fi
    if [[ -n "$SERVER_SERIAL" ]]; then
        printf '        <TR><TD COLSPAN="2"><FONT POINT-SIZE="9" COLOR="%s">[%s]</FONT></TD></TR>\n' \
            "$SUBTEXT_COLOR" "$(dot_escape "$SERVER_SERIAL")"
    fi
    if [[ -n "$SERVER_OS" ]]; then
        printf '        <TR><TD COLSPAN="2"><FONT POINT-SIZE="9" COLOR="%s">%s</FONT></TD></TR>\n' \
            "$SUBTEXT_COLOR" "$(dot_escape "$SERVER_OS")"
    elif [[ -z "$SERVER_VENDOR" && -z "$SERVER_MODEL" ]]; then
        printf '        <TR><TD COLSPAN="2"><FONT COLOR="%s">Server</FONT></TD></TR>\n' "$SUBTEXT_COLOR"
    fi
    printf '        </TABLE>\n'
    printf '    >];\n\n'

    # --- Helper: emit optics rows for a NIC node in DOT ---
    # Args: $1=row index, $2=indent prefix
    _dot_optics_rows() {
        local _IDX="$1" _INDENT="$2"
        local _TYPE="${DATA_OPTICS_TYPE[$_IDX]}"
        local _TX_S="${DATA_OPTICS_TX_STATUS[$_IDX]}"
        local _RX_S="${DATA_OPTICS_RX_STATUS[$_IDX]}"
        local _TX_D="${DATA_OPTICS_TX_DBM[$_IDX]}"
        local _RX_D="${DATA_OPTICS_RX_DBM[$_IDX]}"
        local _LANES="${DATA_OPTICS_LANE_COUNT[$_IDX]:-0}"

        # Skip if N/A (no SFP)
        [[ "$_TYPE" == "N/A" && "$_TX_S" == "N/A" ]] && return

        # Map status to DOT color
        _optics_dot_color() {
            case "$1" in
                OK)    echo "$GREEN_COLOR" ;;
                WARN)  echo "#f9e2af" ;;  # Catppuccin Yellow
                ALARM) echo "$RED_COLOR" ;;
                *)     echo "$SUBTEXT_COLOR" ;;
            esac
        }

        # SFP type label
        printf '%s<TR><TD><FONT POINT-SIZE="8" COLOR="%s">%s</FONT></TD></TR>\n' \
            "$_INDENT" "$SUBTEXT_COLOR" "$(dot_escape "$_TYPE")"

        if [[ $_LANES -gt 1 && -n "${DATA_OPTICS_TX_LANES[$_IDX]}" ]]; then
            # Multi-lane: one row per channel
            local _IFS_SAVE="$IFS"
            IFS=':' read -ra _TX_L <<< "${DATA_OPTICS_TX_LANES[$_IDX]}"
            IFS=':' read -ra _RX_L <<< "${DATA_OPTICS_RX_LANES[$_IDX]}"
            IFS="$_IFS_SAVE"
            local _CH
            for ((_CH=0; _CH<${#_TX_L[@]}; _CH++)); do
                local _TV="${_TX_L[$_CH]}" _RV="${_RX_L[$_CH]}"
                local _TC _RC
                # Evaluate each lane independently
                if [[ "$_TV" != "N/A" && "$_TX_S" != "N/DOM" && "$_TX_S" != "N/A" ]]; then
                    _TC=$(_optics_dot_color "$(evaluate_optics_health "$_TV" "" "" "" "" 2>/dev/null || echo "$_TX_S")")
                    # Use overall status color for simplicity (thresholds evaluated per lane would need passing them through)
                    _TC=$(_optics_dot_color "$_TX_S")
                else
                    _TC="$SUBTEXT_COLOR"
                fi
                if [[ "$_RV" != "N/A" && "$_RX_S" != "N/DOM" && "$_RX_S" != "N/A" ]]; then
                    _RC=$(_optics_dot_color "$_RX_S")
                else
                    _RC="$SUBTEXT_COLOR"
                fi
                printf '%s<TR><TD><FONT POINT-SIZE="8" COLOR="%s">Ch%d:</FONT> <FONT POINT-SIZE="8" COLOR="%s">Tx:%s</FONT> <FONT POINT-SIZE="8" COLOR="%s">Rx:%s</FONT></TD></TR>\n' \
                    "$_INDENT" "$SUBTEXT_COLOR" "$((_CH+1))" "$_TC" "$(dot_escape "$_TV")" "$_RC" "$(dot_escape "$_RV")"
            done
        else
            # Single-lane or N/DOM: one row with Tx/Rx
            if [[ "$_TX_S" == "N/DOM" || "$_RX_S" == "N/DOM" ]]; then
                printf '%s<TR><TD><FONT POINT-SIZE="8" COLOR="%s">Tx:%s Rx:%s (N/DOM)</FONT></TD></TR>\n' \
                    "$_INDENT" "$SUBTEXT_COLOR" "$(dot_escape "$_TX_D")" "$(dot_escape "$_RX_D")"
            elif [[ "$_TX_S" != "N/A" ]]; then
                local _TC _RC
                _TC=$(_optics_dot_color "$_TX_S")
                _RC=$(_optics_dot_color "$_RX_S")
                printf '%s<TR><TD><FONT POINT-SIZE="8" COLOR="%s">Tx:%s</FONT> <FONT POINT-SIZE="8" COLOR="%s">Rx:%s</FONT></TD></TR>\n' \
                    "$_INDENT" "$_TC" "$(dot_escape "$_TX_D dBm")" "$_RC" "$(dot_escape "$_RX_D dBm")"
            fi
        fi
    }

    # --- Helper: map link state to DOT border color ---
    _dot_link_color() {
        [[ "$1" == "up" ]] && printf '%s' "$GREEN_COLOR" || printf '%s' "$RED_COLOR"
    }

    # --- Helper: emit DOT metrics rows for a NIC node ---
    # Args: $1=row index, $2=indent prefix
    _dot_metrics_rows() {
        local _IDX="$1" _INDENT="$2"
        local _RX_BW _TX_BW _RX_CLR="$SUBTEXT_COLOR" _TX_CLR="$SUBTEXT_COLOR"
        _RX_BW=$(human_bitrate "${DATA_MET_RX_BPS[$_IDX]}")
        _TX_BW=$(human_bitrate "${DATA_MET_TX_BPS[$_IDX]}")
        # Bond variance detection (harmless for standalone — never contains RED)
        [[ "${DATA_MET_BW_COLOR[$_IDX]}" == *$'\033[1;31m'*"Rx:"* ]] && _RX_CLR="$RED_COLOR"
        [[ "${DATA_MET_BW_COLOR[$_IDX]}" == *"Tx:"*$'\033[1;31m'* ]] && _TX_CLR="$RED_COLOR"
        printf '%s<TR><TD><FONT POINT-SIZE="11" COLOR="%s"><B>↓</B></FONT><FONT POINT-SIZE="9" COLOR="%s">%s</FONT> <FONT POINT-SIZE="11" COLOR="%s"><B>↑</B></FONT><FONT POINT-SIZE="9" COLOR="%s">%s</FONT></TD></TR>\n' \
            "$_INDENT" "$RX_ARROW_COLOR" "$_RX_CLR" "$(dot_escape "$_RX_BW")" "$TX_ARROW_COLOR" "$_TX_CLR" "$(dot_escape "$_TX_BW")"
        # Error summary row (only if any > 0)
        local _TOTAL=$(( DATA_MET_RX_DROP[_IDX] + DATA_MET_TX_DROP[_IDX] + DATA_MET_RX_ERR[_IDX] + DATA_MET_TX_ERR[_IDX] + DATA_MET_RX_FIFO[_IDX] + DATA_MET_TX_FIFO[_IDX] ))
        if (( _TOTAL > 0 )); then
            printf '%s<TR><TD><FONT POINT-SIZE="8" COLOR="%s">Drop:%d/Err:%d/FIFO:%d</FONT></TD></TR>\n' \
                "$_INDENT" "$RED_COLOR" \
                "$(( DATA_MET_RX_DROP[_IDX] + DATA_MET_TX_DROP[_IDX] ))" \
                "$(( DATA_MET_RX_ERR[_IDX] + DATA_MET_TX_ERR[_IDX] ))" \
                "$(( DATA_MET_RX_FIFO[_IDX] + DATA_MET_TX_FIFO[_IDX] ))"
        fi
    }

    # --- Helper: emit a NIC node (HTML table) for the DOT diagram ---
    # Args: $1=row index, $2=indent prefix
    _dot_nic_node() {
        local _IDX="$1" _INDENT="$2"
        local _INDENT2="${_INDENT}    "
        local _IFACE="${DATA_IFACE[$_IDX]}"
        local _MAC="${DATA_MAC[$_IDX]}"
        local _LINK="${DATA_LINK_PLAIN[$_IDX]}"
        local _MTU="${DATA_MTU[$_IDX]}"
        local _NODE_ID
        _NODE_ID=$(dot_id "$_IFACE")
        local _BORDER
        _BORDER=$(_dot_link_color "$_LINK")

        printf '%s%s [shape=plain, label=<\n' "$_INDENT" "$_NODE_ID"
        printf '%s<TABLE BORDER="1" CELLBORDER="0" CELLSPACING="2" CELLPADDING="4" ' "$_INDENT2"
        printf 'BGCOLOR="%s" COLOR="%s">\n' "$SURFACE_COLOR" "$_BORDER"
        printf '%s<TR><TD><FONT COLOR="%s"><B>%s</B></FONT></TD></TR>\n' \
            "$_INDENT2" "$TEXT_COLOR" "$(dot_escape "$_IFACE")"
        printf '%s<TR><TD><FONT POINT-SIZE="9" COLOR="%s">%s</FONT></TD></TR>\n' \
            "$_INDENT2" "$SUBTEXT_COLOR" "$(dot_escape "$_MAC")"
        printf '%s<TR><TD><FONT POINT-SIZE="9" COLOR="%s">MTU: %s</FONT></TD></TR>\n' \
            "$_INDENT2" "$SUBTEXT_COLOR" "$(dot_escape "$_MTU")"
        if $SHOW_PHYSICAL && [[ "$CLUSTER_MODE" == "bond" ]]; then
            local _NIC_M="${DATA_NIC_MODEL[$_IDX]}"
            local _NIC_S="${DATA_PCI_SLOT[$_IDX]}"
            [[ -n "$_NIC_M" ]] && printf '%s<TR><TD><FONT POINT-SIZE="8" COLOR="%s">%s</FONT></TD></TR>\n' \
                "$_INDENT2" "$SUBTEXT_COLOR" "$(dot_escape "$_NIC_M")"
            [[ -n "$_NIC_S" ]] && printf '%s<TR><TD><FONT POINT-SIZE="8" COLOR="%s">%s</FONT></TD></TR>\n' \
                "$_INDENT2" "$SUBTEXT_COLOR" "$(dot_escape "$_NIC_S")"
        fi
        if $SHOW_OPTICS; then
            _dot_optics_rows "$_IDX" "$_INDENT2"
        fi
        if $SHOW_METRICS; then
            _dot_metrics_rows "$_IDX" "$_INDENT2"
        fi
        printf '%s</TABLE>\n' "$_INDENT2"
        printf '%s>];\n' "$_INDENT"
    }

    # --- Helper: determine edge color (bond color or link state) ---
    # Args: $1=bond name, $2=link state
    _dot_edge_color() {
        if [[ "$1" != "None" && -n "${BOND_COLOR_MAP[$1]+x}" ]]; then
            printf '%s' "${BOND_COLOR_MAP[$1]}"
        elif [[ "$2" == "up" ]]; then
            printf '%s' "$GREEN_COLOR"
        else
            printf '%s' "$RED_COLOR"
        fi
    }

    if [[ "$CLUSTER_MODE" == "bond" ]]; then
        # --- Bond clusters with member interface nodes ---
        local CLUSTER_IDX=0
        for BOND_NAME in $(printf '%s\n' "${!BOND_MEMBERS[@]}" | sort); do
            local -a MEMBERS_ARR
            read -ra MEMBERS_ARR <<< "${BOND_MEMBERS[$BOND_NAME]}"
            local BOND_CLR="${BOND_COLOR_MAP[$BOND_NAME]}"

            # Determine LACP status label for the bond
            local LACP_LABEL=""
            for IDX in "${MEMBERS_ARR[@]}"; do
                local LACP="${DATA_LACP_PLAIN[$IDX]}"
                if [[ "$LACP" == *"Mismatch"* ]]; then
                    LACP_LABEL="LACP Mismatch"
                    break
                elif [[ "$LACP" == AggID* && "$LACP" != *"Partial"* ]]; then
                    LACP_LABEL="LACP Active"
                elif [[ "$LACP" == *"Partial"* && "$LACP_LABEL" != "LACP Active" ]]; then
                    LACP_LABEL="LACP Partial"
                elif [[ "$LACP" == "Pending" && -z "$LACP_LABEL" ]]; then
                    LACP_LABEL="LACP Pending"
                fi
            done
            [[ -z "$LACP_LABEL" ]] && LACP_LABEL="Bonded"

            printf '    subgraph cluster_bond_%d {\n' "$CLUSTER_IDX"
            printf '        style=dashed;\n'
            printf '        color="%s";\n' "$BOND_CLR"
            printf '        bgcolor="%s";\n' "${BG_COLOR}cc"
            printf '        fontcolor="%s";\n' "$BOND_CLR"
            printf '        label=<<FONT POINT-SIZE="12"><B>%s</B> (%s)</FONT>>;\n' \
                "$(dot_escape "$BOND_NAME")" "$(dot_escape "$LACP_LABEL")"
            printf '        penwidth=1.5;\n\n'

            for IDX in "${MEMBERS_ARR[@]}"; do
                _dot_nic_node "$IDX" "        "
            done

            printf '    }\n\n'
            ((CLUSTER_IDX++))
        done

        # --- Standalone interface nodes ---
        for IDX in "${STANDALONE_INDICES[@]}"; do
            _dot_nic_node "$IDX" "    "
            printf '\n'
        done

    else
        # --- NIC clustering: NUMA -> PCI Slot -> NIC card -> interface port nodes ---
        # Collect PCI slot -> row indices and PCI slot -> NUMA mappings
        declare -A _SLOT_INDICES   # pci_slot -> space-separated row indices
        declare -A _SLOT_NUMA      # pci_slot -> numa_id
        declare -A _NUMA_SET       # numa_id -> 1 (unique NUMA tracker)

        for ((i = 0; i < ROW_COUNT; i++)); do
            local _N="${DATA_NUMA[$i]}"
            local _S="${DATA_PCI_SLOT[$i]}"
            _SLOT_INDICES["$_S"]+="$i "
            _SLOT_NUMA["$_S"]="$_N"
            _NUMA_SET["$_N"]=1
        done

        # Pre-sort all PCI slots (space-safe via mapfile)
        local -a _ALL_SORTED_SLOTS
        mapfile -t _ALL_SORTED_SLOTS < <(printf '%s\n' "${!_SLOT_INDICES[@]}" | sort)

        # Emit NUMA clusters containing PCI slot clusters with NIC card nodes
        local _PCI_CLUSTER_IDX=0
        local -a _SORTED_NUMAS
        mapfile -t _SORTED_NUMAS < <(printf '%s\n' "${!_NUMA_SET[@]}" | sort)
        for _NUMA_ID in "${_SORTED_NUMAS[@]}"; do
            printf '    subgraph cluster_numa_%s {\n' "$(dot_id "$_NUMA_ID")"
            printf '        style=dashed;\n'
            printf '        color="%s";\n' "$NUMA_COLOR"
            printf '        bgcolor="%s";\n' "${BG_COLOR}88"
            printf '        fontcolor="%s";\n' "$NUMA_COLOR"
            printf '        label=<<FONT POINT-SIZE="11"><B>NUMA %s</B></FONT>>;\n' \
                "$(dot_escape "$_NUMA_ID")"
            printf '        penwidth=1.5;\n\n'

            # Iterate all sorted slots, emit only those belonging to this NUMA
            for _PCI_SLOT in "${_ALL_SORTED_SLOTS[@]}"; do
                [[ "${_SLOT_NUMA[$_PCI_SLOT]}" != "$_NUMA_ID" ]] && continue
                local -a _SLOT_ROWS
                read -ra _SLOT_ROWS <<< "${_SLOT_INDICES[$_PCI_SLOT]}"
                local _FIRST_IDX="${_SLOT_ROWS[0]}"
                local _NIC_VENDOR="${DATA_NIC_VENDOR[$_FIRST_IDX]}"
                local _NIC_MODEL="${DATA_NIC_MODEL[$_FIRST_IDX]}"
                local _NIC_FW="${DATA_FIRMWARE[$_FIRST_IDX]}"
                local _NIC_CARD_ID
                _NIC_CARD_ID=$(dot_id "nic_${_PCI_SLOT}")

                printf '        subgraph cluster_pci_%d {\n' "$_PCI_CLUSTER_IDX"
                printf '            style=dashed;\n'
                printf '            color="%s";\n' "$NIC_CARD_COLOR"
                printf '            bgcolor="%s";\n' "${BG_COLOR}cc"
                printf '            fontcolor="%s";\n' "$NIC_CARD_COLOR"
                printf '            label=<<FONT POINT-SIZE="10">%s</FONT>>;\n' \
                    "$(dot_escape "$_PCI_SLOT")"
                printf '            penwidth=1.0;\n\n'

                # NIC card node inside cluster
                printf '            %s [shape=plain, label=<\n' "$_NIC_CARD_ID"
                printf '                <TABLE BORDER="1" CELLBORDER="0" CELLSPACING="2" CELLPADDING="4" '
                printf 'BGCOLOR="%s" COLOR="%s">\n' "$SURFACE_COLOR" "$NIC_CARD_COLOR"
                printf '                <TR><TD><FONT COLOR="%s"><B>%s</B></FONT></TD></TR>\n' \
                    "$TEXT_COLOR" "$(dot_escape "$_NIC_MODEL")"
                printf '                <TR><TD><FONT POINT-SIZE="9" COLOR="%s">%s</FONT></TD></TR>\n' \
                    "$SUBTEXT_COLOR" "$(dot_escape "$_NIC_VENDOR")"
                if [[ -n "$_NIC_FW" ]]; then
                    printf '                <TR><TD><FONT POINT-SIZE="9" COLOR="%s">FW: %s</FONT></TD></TR>\n' \
                        "$SUBTEXT_COLOR" "$(dot_escape "$_NIC_FW")"
                fi
                printf '                </TABLE>\n'
                printf '            >];\n\n'

                # Interface port nodes inside NIC cluster
                for IDX in "${_SLOT_ROWS[@]}"; do
                    _dot_nic_node "$IDX" "            "
                done

                printf '        }\n\n'
                ((_PCI_CLUSTER_IDX++))
            done

            printf '    }\n\n'
        done
    fi

    # --- Switch port nodes ---
    declare -A EMITTED_PORTS
    for ((j = 0; j < ROW_COUNT; j++)); do
        local SW_NAME="${DATA_SWITCH[$j]}"
        [[ -z "$SW_NAME" ]] && continue
        local PORT_NAME="${DATA_PORT[$j]}"
        [[ -z "$PORT_NAME" ]] && continue
        local PORT_ID
        PORT_ID=$(dot_id "swport_${SW_NAME}_${PORT_NAME}")
        [[ -n "${EMITTED_PORTS[$PORT_ID]+x}" ]] && continue
        EMITTED_PORTS["$PORT_ID"]=1

        printf '    %s [shape=plain, label=<\n' "$PORT_ID"
        printf '        <TABLE BORDER="1" CELLBORDER="0" CELLSPACING="2" CELLPADDING="4" '
        printf 'BGCOLOR="%s" COLOR="%s">\n' "$SURFACE_COLOR" "$PEACH_COLOR"
        printf '        <TR><TD><FONT COLOR="%s"><B>%s</B></FONT></TD></TR>\n' \
            "$TEXT_COLOR" "$(dot_escape "$PORT_NAME")"
        local PORT_DESCR_VAL="${DATA_PORT_DESCR[$j]}"
        if [[ -n "$PORT_DESCR_VAL" && "$PORT_DESCR_VAL" != "N/A" ]]; then
            printf '        <TR><TD><FONT POINT-SIZE="9" COLOR="%s">%s</FONT></TD></TR>\n' \
                "$SUBTEXT_COLOR" "$(dot_escape "$PORT_DESCR_VAL")"
        fi
        printf '        </TABLE>\n'
        printf '    >];\n\n'
    done
    unset EMITTED_PORTS

    # --- Switch nodes ---
    for SW_NAME in $(printf '%s\n' "${!SEEN_SWITCHES[@]}" | sort); do
        local SW_ID
        SW_ID=$(dot_id "sw_${SW_NAME}")
        printf '    %s [shape=plain, label=<\n' "$SW_ID"
        printf '        <TABLE BORDER="1" CELLBORDER="0" CELLSPACING="4" CELLPADDING="6" '
        printf 'BGCOLOR="%s" COLOR="%s" STYLE="ROUNDED">\n' "$SURFACE_COLOR" "$PEACH_COLOR"
        printf '        <TR><TD><FONT POINT-SIZE="14" COLOR="%s"><B>%s</B></FONT></TD></TR>\n' \
            "$PEACH_COLOR" "$(dot_escape "$SW_NAME")"

        local _SW_DESCR="${DATA_SWITCH_DESCR[$SW_NAME]:-}"
        local _SW_SER="${DATA_SWITCH_SERIAL[$SW_NAME]:-}"
        if [[ -n "$_SW_DESCR" ]]; then
            local _SW_BRAND="" _SW_MODEL="" _SW_SOFT=""
            parse_switch_descr "$_SW_DESCR" _SW_BRAND _SW_MODEL _SW_SOFT
            if [[ -n "$_SW_MODEL" ]]; then
                # Parsed successfully: brand + model, then serial, then software
                printf '        <TR><TD><FONT POINT-SIZE="9" COLOR="%s">%s %s</FONT></TD></TR>\n' \
                    "$SUBTEXT_COLOR" "$(dot_escape "$_SW_BRAND")" "$(dot_escape "$_SW_MODEL")"
                [[ -n "$_SW_SER" ]] && \
                    printf '        <TR><TD><FONT POINT-SIZE="9" COLOR="%s">[%s]</FONT></TD></TR>\n' \
                        "$SUBTEXT_COLOR" "$(dot_escape "$_SW_SER")"
                [[ -n "$_SW_SOFT" ]] && \
                    printf '        <TR><TD><FONT POINT-SIZE="9" COLOR="%s">%s</FONT></TD></TR>\n' \
                        "$SUBTEXT_COLOR" "$(dot_escape "$_SW_SOFT")"
            elif [[ -n "$_SW_BRAND" ]]; then
                # Fallback: truncated SysDescr as single row
                printf '        <TR><TD><FONT POINT-SIZE="9" COLOR="%s">%s</FONT></TD></TR>\n' \
                    "$SUBTEXT_COLOR" "$(dot_escape "$_SW_BRAND")"
                [[ -n "$_SW_SER" ]] && \
                    printf '        <TR><TD><FONT POINT-SIZE="9" COLOR="%s">[%s]</FONT></TD></TR>\n' \
                        "$SUBTEXT_COLOR" "$(dot_escape "$_SW_SER")"
            else
                printf '        <TR><TD><FONT COLOR="%s">Switch</FONT></TD></TR>\n' "$SUBTEXT_COLOR"
            fi
        else
            printf '        <TR><TD><FONT COLOR="%s">Switch</FONT></TD></TR>\n' "$SUBTEXT_COLOR"
        fi

        printf '        </TABLE>\n'
        printf '    >];\n\n'
    done

    # --- "No LLDP peer" stub node ---
    local HAS_DISCONNECTED=false
    for ((i = 0; i < ROW_COUNT; i++)); do
        if [[ -z "${DATA_SWITCH[$i]}" ]]; then
            HAS_DISCONNECTED=true
            break
        fi
    done

    if [[ "$HAS_DISCONNECTED" == true ]]; then
        printf '    no_lldp_peer [shape=plain, label=<\n'
        printf '        <TABLE BORDER="1" CELLBORDER="0" CELLSPACING="2" CELLPADDING="4" '
        printf 'BGCOLOR="%s" COLOR="%s" STYLE="ROUNDED">\n' "$SURFACE_COLOR" "$GRAY_COLOR"
        printf '        <TR><TD><FONT COLOR="%s"><I>No LLDP peer</I></FONT></TD></TR>\n' "$GRAY_COLOR"
        printf '        </TABLE>\n'
        printf '    >];\n\n'
    fi

    # --- Edges: server -> interfaces (or server -> NIC -> interfaces when --cluster nic) ---
    if [[ "$CLUSTER_MODE" == "nic" ]]; then
        # Server -> NIC card nodes (deduplicated per PCI slot)
        declare -A _EMITTED_SERVER_NIC_EDGES
        for ((i = 0; i < ROW_COUNT; i++)); do
            local _S="${DATA_PCI_SLOT[$i]}"
            if [[ -z "${_EMITTED_SERVER_NIC_EDGES[$_S]+x}" ]]; then
                _EMITTED_SERVER_NIC_EDGES["$_S"]=1
                local _NIC_CARD_ID
                _NIC_CARD_ID=$(dot_id "nic_${_S}")
                printf '    server -> %s [color="%s", penwidth=1.0, arrowsize=0.6];\n' \
                    "$_NIC_CARD_ID" "$BORDER_COLOR"
            fi
        done
        printf '\n'

        # NIC card -> interface port nodes
        for ((i = 0; i < ROW_COUNT; i++)); do
            local _S="${DATA_PCI_SLOT[$i]}"
            local _NIC_CARD_ID
            _NIC_CARD_ID=$(dot_id "nic_${_S}")
            local IFACE="${DATA_IFACE[$i]}"
            local NODE_ID
            NODE_ID=$(dot_id "$IFACE")
            printf '    %s -> %s [color="%s", penwidth=1.0, arrowsize=0.6];\n' \
                "$_NIC_CARD_ID" "$NODE_ID" "$BORDER_COLOR"
        done
        printf '\n'
    else
        for ((i = 0; i < ROW_COUNT; i++)); do
            local IFACE="${DATA_IFACE[$i]}"
            local NODE_ID
            NODE_ID=$(dot_id "$IFACE")
            printf '    server -> %s [color="%s", penwidth=1.0, arrowsize=0.6];\n' \
                "$NODE_ID" "$BORDER_COLOR"
        done
        printf '\n'
    fi

    # --- Edges: interfaces -> switch ports / stubs ---
    for ((i = 0; i < ROW_COUNT; i++)); do
        local IFACE="${DATA_IFACE[$i]}"
        local NODE_ID
        NODE_ID=$(dot_id "$IFACE")
        local SW="${DATA_SWITCH[$i]}"
        local PORT="${DATA_PORT[$i]}"
        local SPEED_RAW="${DATA_SPEED_PLAIN[$i]}"
        local LINK="${DATA_LINK_PLAIN[$i]}"
        local VLAN="${DATA_VLAN[$i]}"
        local BOND="${DATA_BOND_PLAIN[$i]}"

        local PW
        PW=$(dot_penwidth "$SPEED_RAW")

        if [[ -n "$SW" && -n "$PORT" ]]; then
            local PORT_ID
            PORT_ID=$(dot_id "swport_${SW}_${PORT}")

            local EDGE_COLOR
            EDGE_COLOR=$(_dot_edge_color "$BOND" "$LINK")

            # Build centered edge label: VLAN on top, speed below
            local EDGE_LABEL=""
            if [[ -n "$VLAN" && "$VLAN" != "N/A" ]]; then
                # Format VLANs: bold+underline PVID entries, plain tagged
                local VLAN_TEXT=""
                local IFS_SAVE="$IFS"
                IFS=';' read -ra VLAN_PARTS <<< "$VLAN"
                IFS="$IFS_SAVE"
                for V in "${VLAN_PARTS[@]}"; do
                    [[ -z "$V" ]] && continue
                    [[ -n "$VLAN_TEXT" ]] && VLAN_TEXT+=";"
                    if [[ "$V" == *"[P]"* ]]; then
                        local VID="${V%%\[P\]*}"
                        VLAN_TEXT+="<B><U>$(dot_escape "$VID")</U></B>"
                    else
                        VLAN_TEXT+="$(dot_escape "$V")"
                    fi
                done
                EDGE_LABEL="VLAN ${VLAN_TEXT}"
            fi

            local TIER
            TIER=$(dot_speed_tier "$SPEED_RAW")
            if [[ -n "$TIER" ]]; then
                [[ -n "$EDGE_LABEL" ]] && EDGE_LABEL+="<BR/>"
                EDGE_LABEL+="$TIER"
            fi

            printf '    %s -> %s [label=<%s>, penwidth=%s, color="%s", fontcolor="%s"];\n' \
                "$NODE_ID" "$PORT_ID" \
                "$EDGE_LABEL" \
                "$PW" "$EDGE_COLOR" "$SUBTEXT_COLOR"
        elif [[ -n "$SW" ]]; then
            # Has switch but no port info — connect to an invisible anchor
            local SW_ID
            SW_ID=$(dot_id "sw_${SW}")
            local EDGE_COLOR
            EDGE_COLOR=$(_dot_edge_color "$BOND" "$LINK")
            printf '    %s -> %s [penwidth=%s, color="%s"];\n' \
                "$NODE_ID" "$SW_ID" "$PW" "$EDGE_COLOR"
        else
            printf '    %s -> no_lldp_peer [style=dashed, color="%s", fontcolor="%s", penwidth=1.0];\n' \
                "$NODE_ID" "$GRAY_COLOR" "$GRAY_COLOR"
        fi
    done

    # --- Edges: switch ports -> switch nodes ---
    declare -A EMITTED_SW_EDGES
    for ((j = 0; j < ROW_COUNT; j++)); do
        local E_SW="${DATA_SWITCH[$j]}"
        local E_PORT="${DATA_PORT[$j]}"
        [[ -z "$E_SW" || -z "$E_PORT" ]] && continue
        local E_PORT_ID
        E_PORT_ID=$(dot_id "swport_${E_SW}_${E_PORT}")
        [[ -n "${EMITTED_SW_EDGES[$E_PORT_ID]+x}" ]] && continue
        EMITTED_SW_EDGES["$E_PORT_ID"]=1
        local E_SW_ID
        E_SW_ID=$(dot_id "sw_${E_SW}")
        printf '    %s -> %s [color="%s", penwidth=1.0, arrowsize=0.6];\n' \
            "$E_PORT_ID" "$E_SW_ID" "$BORDER_COLOR"
    done
    unset EMITTED_SW_EDGES
    printf '\n'

    # --- Rank constraints ---
    printf '    { rank=min; server; }\n'

    # Switch nodes on the right
    if [[ ${#SEEN_SWITCHES[@]} -gt 0 || "$HAS_DISCONNECTED" == true ]]; then
        printf '    { rank=max;'
        for SW_NAME in $(printf '%s\n' "${!SEEN_SWITCHES[@]}" | sort); do
            printf ' %s;' "$(dot_id "sw_${SW_NAME}")"
        done
        if [[ "$HAS_DISCONNECTED" == true ]]; then
            printf ' no_lldp_peer;'
        fi
        printf ' }\n'
    fi

    printf '}\n'
}

# --- Output rendering: table, CSV, JSON, DOT/SVG/PNG ---
render_output() {

if [[ "${OUTPUT_FORMAT}" == "table" ]]; then
    # Header
    if ${SHOW_PHYSICAL}; then
        printf "%-${COL_W_NUMA}s${COL_GAP}%-${COL_W_PCI_SLOT}s${COL_GAP}%-${COL_W_NIC_VENDOR}s${COL_GAP}%-${COL_W_NIC_MODEL}s${COL_GAP}" \
            "NUMA" "PCI Slot" "NIC Vendor" "NIC Model"
    fi
    printf "%-${COL_W_DEVICE}s${COL_GAP}%-${COL_W_DRIVER}s${COL_GAP}%-${COL_W_FIRMWARE}s${COL_GAP}%-${COL_W_IFACE}s${COL_GAP}%-${COL_W_MAC}s${COL_GAP}%-${COL_W_MTU}s${COL_GAP}%-${COL_W_LINK}s${COL_GAP}%-${COL_W_SPEED}s${COL_GAP}%-${COL_W_BOND}s" \
        "Device" "Driver" "Firmware" "Interface" "MAC Address" "MTU" "Link" "Speed/Duplex" "Parent Bond"
    ${SHOW_BMAC} && printf "${COL_GAP}%-${COL_W_BMAC}s" "Bond MAC"
    ${SHOW_LACP} && printf "${COL_GAP}%-${COL_W_LACP}s" "LACP Status"
    ${SHOW_VLAN} && printf "${COL_GAP}%-${COL_W_VLAN}s" "VLAN"
    if ${SHOW_OPTICS}; then
        printf "${COL_GAP}%-${COL_W_OPT_TYPE}s" "SFP Type"
        printf "${COL_GAP}%-${COL_W_OPT_TX}s" "Optics Tx"
        printf "${COL_GAP}%-${COL_W_OPT_RX}s" "Optics Rx"
    fi
    if ${SHOW_METRICS}; then
        printf "${COL_GAP}%-${COL_W_MET_BW}s" "Throughput"
        printf "${COL_GAP}%-${COL_W_MET_PPS}s" "Packets/s"
        printf "${COL_GAP}%-${COL_W_MET_DROP}s" "Drops"
        printf "${COL_GAP}%-${COL_W_MET_ERR}s" "Errors"
        printf "${COL_GAP}%-${COL_W_MET_FIFO}s" "FIFO Errors"
    fi
    printf "${COL_GAP}%-${COL_W_SWITCH}s${COL_GAP}%-${COL_W_PORT}s${COL_GAP}%s\n" "Switch Name" "Port Name" "Port Descr"
    # Separator line
    SEP_WIDTH=0
    if ${SHOW_PHYSICAL}; then
        SEP_WIDTH=$((COL_W_NUMA + COL_GAP_WIDTH + COL_W_PCI_SLOT + COL_GAP_WIDTH + COL_W_NIC_VENDOR + COL_GAP_WIDTH + COL_W_NIC_MODEL + COL_GAP_WIDTH))
    fi
    SEP_WIDTH=$((SEP_WIDTH + COL_W_DEVICE + COL_GAP_WIDTH + COL_W_DRIVER + COL_GAP_WIDTH + COL_W_FIRMWARE + COL_GAP_WIDTH + COL_W_IFACE + COL_GAP_WIDTH + COL_W_MAC + COL_GAP_WIDTH + COL_W_MTU + COL_GAP_WIDTH + COL_W_LINK + COL_GAP_WIDTH + COL_W_SPEED + COL_GAP_WIDTH + COL_W_BOND))
    ${SHOW_BMAC} && SEP_WIDTH=$((SEP_WIDTH + COL_GAP_WIDTH + COL_W_BMAC))
    ${SHOW_LACP} && SEP_WIDTH=$((SEP_WIDTH + COL_GAP_WIDTH + COL_W_LACP))
    ${SHOW_VLAN} && SEP_WIDTH=$((SEP_WIDTH + COL_GAP_WIDTH + COL_W_VLAN))
    if ${SHOW_OPTICS}; then
        SEP_WIDTH=$((SEP_WIDTH + COL_GAP_WIDTH + COL_W_OPT_TYPE + COL_GAP_WIDTH + COL_W_OPT_TX + COL_GAP_WIDTH + COL_W_OPT_RX))
    fi
    if ${SHOW_METRICS}; then
        SEP_WIDTH=$((SEP_WIDTH + COL_GAP_WIDTH + COL_W_MET_BW + COL_GAP_WIDTH + COL_W_MET_PPS + COL_GAP_WIDTH + COL_W_MET_DROP + COL_GAP_WIDTH + COL_W_MET_ERR + COL_GAP_WIDTH + COL_W_MET_FIFO))
    fi
    SEP_WIDTH=$((SEP_WIDTH + COL_GAP_WIDTH + COL_W_SWITCH + COL_GAP_WIDTH + COL_W_PORT + COL_GAP_WIDTH + COL_W_PORT_DESCR))
    printf '%*s\n' "$SEP_WIDTH" '' | tr ' ' '-'
    # Data rows (suppress repeated physical columns for visual grouping)
    local _PREV_NUMA="" _PREV_SLOT="" _PREV_VENDOR="" _PREV_MODEL=""
    for i in "${RENDER_ORDER[@]}"; do
        if ${SHOW_PHYSICAL}; then
            local _CUR_NUMA="${DATA_NUMA[$i]}" _CUR_SLOT="${DATA_PCI_SLOT[$i]}"
            local _CUR_VENDOR="${DATA_NIC_VENDOR[$i]}" _CUR_MODEL="${DATA_NIC_MODEL[$i]}"
            local _SHOW_NUMA="$_CUR_NUMA" _SHOW_SLOT="$_CUR_SLOT"
            local _SHOW_VENDOR="$_CUR_VENDOR" _SHOW_MODEL="$_CUR_MODEL"
            if [[ "$_CUR_NUMA" != "$_PREV_NUMA" ]]; then
                # New NUMA boundary: show all values
                _PREV_NUMA="$_CUR_NUMA"; _PREV_SLOT="$_CUR_SLOT"
                _PREV_VENDOR="$_CUR_VENDOR"; _PREV_MODEL="$_CUR_MODEL"
            elif [[ "$_CUR_SLOT" != "$_PREV_SLOT" ]]; then
                # New slot boundary: suppress NUMA, show slot/vendor/model
                _SHOW_NUMA=""
                _PREV_SLOT="$_CUR_SLOT"
                _PREV_VENDOR="$_CUR_VENDOR"; _PREV_MODEL="$_CUR_MODEL"
            else
                # Same slot: suppress NUMA/slot/vendor/model
                _SHOW_NUMA=""; _SHOW_SLOT=""
                _SHOW_VENDOR=""; _SHOW_MODEL=""
            fi
            printf "%-${COL_W_NUMA}s${COL_GAP}%-${COL_W_PCI_SLOT}s${COL_GAP}%-${COL_W_NIC_VENDOR}s${COL_GAP}%-${COL_W_NIC_MODEL}s${COL_GAP}" \
                "$_SHOW_NUMA" "$_SHOW_SLOT" "$_SHOW_VENDOR" "$_SHOW_MODEL"
        fi
        printf "%-${COL_W_DEVICE}s${COL_GAP}%-${COL_W_DRIVER}s${COL_GAP}%-${COL_W_FIRMWARE}s${COL_GAP}%-${COL_W_IFACE}s${COL_GAP}%-${COL_W_MAC}s${COL_GAP}%-${COL_W_MTU}s${COL_GAP}" \
            "${DATA_DEVICE[$i]}" "${DATA_DRIVER[$i]}" "${DATA_FIRMWARE[$i]}" "${DATA_IFACE[$i]}" "${DATA_MAC[$i]}" "${DATA_MTU[$i]}"
        pad_color "${DATA_LINK_COLOR[$i]}" "$COL_W_LINK"
        printf '%s' "${COL_GAP}"
        pad_color "${DATA_SPEED_COLOR[$i]}" "$COL_W_SPEED"
        printf '%s' "${COL_GAP}"
        pad_color "${DATA_BOND_COLOR[$i]}" "$COL_W_BOND"
        if ${SHOW_BMAC}; then
            printf "${COL_GAP}%-${COL_W_BMAC}s" "${DATA_BMAC[$i]}"
        fi
        if ${SHOW_LACP}; then
            printf '%s' "${COL_GAP}"
            pad_color "${DATA_LACP_COLOR[$i]}" "$COL_W_LACP"
        fi
        ${SHOW_VLAN} && printf "${COL_GAP}%-${COL_W_VLAN}s" "${DATA_VLAN[$i]}"
        if ${SHOW_OPTICS}; then
            printf "${COL_GAP}%-${COL_W_OPT_TYPE}s" "${DATA_OPTICS_TYPE[$i]}"
            printf '%s' "${COL_GAP}"
            pad_color "${DATA_OPTICS_TX_COLOR[$i]}" "$COL_W_OPT_TX"
            printf '%s' "${COL_GAP}"
            pad_color "${DATA_OPTICS_RX_COLOR[$i]}" "$COL_W_OPT_RX"
        fi
        if ${SHOW_METRICS}; then
            printf '%s' "${COL_GAP}"
            pad_color "${DATA_MET_BW_COLOR[$i]}" "$COL_W_MET_BW"
            printf '%s' "${COL_GAP}"
            pad_color "${DATA_MET_PPS_COLOR[$i]}" "$COL_W_MET_PPS"
            printf '%s' "${COL_GAP}"
            pad_color "${DATA_MET_DROP_COLOR[$i]}" "$COL_W_MET_DROP"
            printf '%s' "${COL_GAP}"
            pad_color "${DATA_MET_ERR_COLOR[$i]}" "$COL_W_MET_ERR"
            printf '%s' "${COL_GAP}"
            pad_color "${DATA_MET_FIFO_COLOR[$i]}" "$COL_W_MET_FIFO"
        fi
        printf "${COL_GAP}%-${COL_W_SWITCH}s${COL_GAP}%-${COL_W_PORT}s${COL_GAP}%s\n" "${DATA_SWITCH[$i]}" "${DATA_PORT[$i]}" "${DATA_PORT_DESCR[$i]}"
    done
    if ${SHOW_METRICS}; then
        printf '\n📊 Metrics sampled over %ds\n' "$METRICS_ELAPSED"
    fi
elif [[ "${OUTPUT_FORMAT}" == "csv" ]]; then
    FS="${FIELD_SEP:-,}"
    # CSV Header
    if ${SHOW_PHYSICAL}; then
        printf "%s${FS}%s${FS}%s${FS}%s${FS}" "NUMA" "PCI Slot" "NIC Vendor" "NIC Model"
    fi
    printf "%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s" "Device" "Driver" "Firmware" "Interface" "MAC Address" "MTU" "Link" "Speed/Duplex" "Parent Bond"
    ${SHOW_BMAC} && printf "${FS}%s" "Bond MAC"
    ${SHOW_LACP} && printf "${FS}%s" "LACP Status"
    ${SHOW_VLAN} && printf "${FS}%s" "VLAN"
    if ${SHOW_OPTICS}; then
        printf "${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s" \
            "SFP Type" "SFP Vendor" "Wavelength" "Tx Power (dBm)" "Tx Status" \
            "Rx Power (dBm)" "Rx Status" "Lane Count"
    fi
    if ${SHOW_METRICS}; then
        printf "${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s" \
            "Rx Bits/s" "Tx Bits/s" "Rx Packets/s" "Tx Packets/s" \
            "Rx Drops" "Tx Drops" "Rx Errors" "Tx Errors" \
            "Rx FIFO Errors" "Tx FIFO Errors" "Sample Duration"
    fi
    printf "${FS}%s${FS}%s${FS}%s\n" "Switch Name" "Port Name" "Port Descr"
    # CSV Data rows
    for i in "${RENDER_ORDER[@]}"; do
        if ${SHOW_PHYSICAL}; then
            printf "%s${FS}%s${FS}%s${FS}%s${FS}" \
                "${DATA_NUMA[$i]}" "${DATA_PCI_SLOT[$i]}" "${DATA_NIC_VENDOR[$i]}" "${DATA_NIC_MODEL[$i]}"
        fi
        printf "%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s" \
            "${DATA_DEVICE[$i]}" "${DATA_DRIVER[$i]}" "${DATA_FIRMWARE[$i]}" "${DATA_IFACE[$i]}" "${DATA_MAC[$i]}" \
            "${DATA_MTU[$i]}" "${DATA_LINK_PLAIN[$i]}" "${DATA_SPEED_PLAIN[$i]}" "${DATA_BOND_PLAIN[$i]}"
        ${SHOW_BMAC} && printf "${FS}%s" "${DATA_BMAC[$i]}"
        ${SHOW_LACP} && printf "${FS}%s" "${DATA_LACP_PLAIN[$i]}"
        ${SHOW_VLAN} && printf "${FS}%s" "${DATA_VLAN[$i]}"
        if ${SHOW_OPTICS}; then
            printf "${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s" \
                "${DATA_OPTICS_TYPE[$i]}" "${DATA_OPTICS_VENDOR[$i]}" \
                "${DATA_OPTICS_WAVELENGTH[$i]}" "${DATA_OPTICS_TX_DBM[$i]}" \
                "${DATA_OPTICS_TX_STATUS[$i]}" "${DATA_OPTICS_RX_DBM[$i]}" \
                "${DATA_OPTICS_RX_STATUS[$i]}" "${DATA_OPTICS_LANE_COUNT[$i]}"
        fi
        if ${SHOW_METRICS}; then
            printf "${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s" \
                "$((DATA_MET_RX_BPS[$i] * 8))" "$((DATA_MET_TX_BPS[$i] * 8))" \
                "${DATA_MET_RX_PPS[$i]}" "${DATA_MET_TX_PPS[$i]}" \
                "${DATA_MET_RX_DROP[$i]}" "${DATA_MET_TX_DROP[$i]}" \
                "${DATA_MET_RX_ERR[$i]}" "${DATA_MET_TX_ERR[$i]}" \
                "${DATA_MET_RX_FIFO[$i]}" "${DATA_MET_TX_FIFO[$i]}" \
                "${METRICS_ELAPSED}"
        fi
        printf "${FS}%s${FS}%s${FS}%s\n" "${DATA_SWITCH[$i]}" "${DATA_PORT[$i]}" "${DATA_PORT_DESCR[$i]}"
    done
elif [[ "${OUTPUT_FORMAT}" == "json" ]]; then
    printf '[\n'
    LAST_IDX="${RENDER_ORDER[-1]}"
    for i in "${RENDER_ORDER[@]}"; do
        printf '  {\n'
        if ${SHOW_PHYSICAL}; then
            printf '    "numa_node": "%s",\n' "$(json_escape "${DATA_NUMA[$i]}")"
            printf '    "pci_slot": "%s",\n' "$(json_escape "${DATA_PCI_SLOT[$i]}")"
            printf '    "nic_vendor": "%s",\n' "$(json_escape "${DATA_NIC_VENDOR[$i]}")"
            printf '    "nic_model": "%s",\n' "$(json_escape "${DATA_NIC_MODEL[$i]}")"
        fi
        printf '    "device": "%s",\n' "$(json_escape "${DATA_DEVICE[$i]}")"
        printf '    "driver": "%s",\n' "$(json_escape "${DATA_DRIVER[$i]}")"
        printf '    "firmware": "%s",\n' "$(json_escape "${DATA_FIRMWARE[$i]}")"
        printf '    "interface": "%s",\n' "$(json_escape "${DATA_IFACE[$i]}")"
        printf '    "mac_address": "%s",\n' "$(json_escape "${DATA_MAC[$i]}")"
        printf '    "mtu": %s,\n' "${DATA_MTU[$i]:-0}"
        printf '    "link": "%s",\n' "$(json_escape "${DATA_LINK_PLAIN[$i]}")"
        printf '    "speed_duplex": "%s",\n' "$(json_escape "${DATA_SPEED_PLAIN[$i]}")"
        printf '    "parent_bond": "%s"' "$(json_escape "${DATA_BOND_PLAIN[$i]}")"
        if ${SHOW_BMAC}; then
            printf ',\n    "bond_mac": "%s"' "$(json_escape "${DATA_BMAC[$i]}")"
        fi
        if ${SHOW_LACP}; then
            printf ',\n    "lacp_status": "%s"' "$(json_escape "${DATA_LACP_PLAIN[$i]}")"
        fi
        if ${SHOW_VLAN}; then
            printf ',\n    "vlan": "%s"' "$(json_escape "${DATA_VLAN[$i]}")"
        fi
        if ${SHOW_OPTICS}; then
            printf ',\n    "optics": {\n'
            printf '      "sfp_type": "%s",\n' "$(json_escape "${DATA_OPTICS_TYPE[$i]}")"
            printf '      "vendor": "%s",\n' "$(json_escape "${DATA_OPTICS_VENDOR[$i]}")"
            printf '      "wavelength": "%s",\n' "$(json_escape "${DATA_OPTICS_WAVELENGTH[$i]}")"
            # Tx power: numeric or string
            if [[ "${DATA_OPTICS_TX_DBM[$i]}" == "N/A" ]]; then
                printf '      "tx_power_dbm": null,\n'
            else
                printf '      "tx_power_dbm": %s,\n' "${DATA_OPTICS_TX_DBM[$i]}"
            fi
            printf '      "tx_status": "%s",\n' "$(json_escape "${DATA_OPTICS_TX_STATUS[$i]}")"
            # Rx power: numeric or string
            if [[ "${DATA_OPTICS_RX_DBM[$i]}" == "N/A" ]]; then
                printf '      "rx_power_dbm": null,\n'
            else
                printf '      "rx_power_dbm": %s,\n' "${DATA_OPTICS_RX_DBM[$i]}"
            fi
            printf '      "rx_status": "%s",\n' "$(json_escape "${DATA_OPTICS_RX_STATUS[$i]}")"
            printf '      "lanes": %s' "${DATA_OPTICS_LANE_COUNT[$i]:-0}"
            # Multi-lane per-channel detail
            if [[ ${DATA_OPTICS_LANE_COUNT[$i]:-0} -gt 1 && -n "${DATA_OPTICS_TX_LANES[$i]}" ]]; then
                # Tx lanes array
                printf ',\n      "tx_lanes_dbm": ['
                IFS_SAVE="$IFS"
                IFS=':' read -ra _TX_L <<< "${DATA_OPTICS_TX_LANES[$i]}"
                IFS="$IFS_SAVE"
                for ((li=0; li<${#_TX_L[@]}; li++)); do
                    (( li > 0 )) && printf ','
                    if [[ "${_TX_L[$li]}" == "N/A" ]]; then
                        printf 'null'
                    else
                        printf '%s' "${_TX_L[$li]}"
                    fi
                done
                printf ']'
                # Rx lanes array
                printf ',\n      "rx_lanes_dbm": ['
                IFS=':' read -ra _RX_L <<< "${DATA_OPTICS_RX_LANES[$i]}"
                IFS="$IFS_SAVE"
                for ((li=0; li<${#_RX_L[@]}; li++)); do
                    (( li > 0 )) && printf ','
                    if [[ "${_RX_L[$li]}" == "N/A" ]]; then
                        printf 'null'
                    else
                        printf '%s' "${_RX_L[$li]}"
                    fi
                done
                printf ']'
            fi
            printf '\n    }'
        fi
        if ${SHOW_METRICS}; then
            printf ',\n    "metrics": {\n'
            printf '      "sample_duration_seconds": %s,\n' "$METRICS_ELAPSED"
            printf '      "rx_bits_per_sec": %s,\n' "$((DATA_MET_RX_BPS[$i] * 8))"
            printf '      "tx_bits_per_sec": %s,\n' "$((DATA_MET_TX_BPS[$i] * 8))"
            printf '      "rx_packets_per_sec": %s,\n' "${DATA_MET_RX_PPS[$i]}"
            printf '      "tx_packets_per_sec": %s,\n' "${DATA_MET_TX_PPS[$i]}"
            printf '      "rx_drops": %s,\n' "${DATA_MET_RX_DROP[$i]}"
            printf '      "tx_drops": %s,\n' "${DATA_MET_TX_DROP[$i]}"
            printf '      "rx_errors": %s,\n' "${DATA_MET_RX_ERR[$i]}"
            printf '      "tx_errors": %s,\n' "${DATA_MET_TX_ERR[$i]}"
            printf '      "rx_fifo_errors": %s,\n' "${DATA_MET_RX_FIFO[$i]}"
            printf '      "tx_fifo_errors": %s\n' "${DATA_MET_TX_FIFO[$i]}"
            printf '    }'
        fi
        printf ',\n    "switch_name": "%s"' "$(json_escape "${DATA_SWITCH[$i]}")"
        printf ',\n    "port_name": "%s"' "$(json_escape "${DATA_PORT[$i]}")"
        printf ',\n    "port_descr": "%s"' "$(json_escape "${DATA_PORT_DESCR[$i]}")"
        printf '\n  }'
        if [[ "$i" != "$LAST_IDX" ]]; then
            printf ','
        fi
        printf '\n'
    done
    printf ']\n'
elif [[ "$OUTPUT_FORMAT" == "dot" ]]; then
    generate_dot
elif [[ "$OUTPUT_FORMAT" == "svg" || "$OUTPUT_FORMAT" == "png" ]]; then
    if [[ -z "$DIAGRAM_OUTPUT_FILE" ]]; then
        DIAGRAM_OUTPUT_FILE="/tmp/nic-xray-$(hostname -s 2>/dev/null || hostname).${OUTPUT_FORMAT}"
    fi

    if generate_dot | dot -T"$OUTPUT_FORMAT" -o "$DIAGRAM_OUTPUT_FILE" 2>/dev/null; then
        echo "Diagram saved to: $DIAGRAM_OUTPUT_FILE" >&2
    else
        echo "Failed to render diagram. Check that graphviz is working correctly." >&2
        exit 1
    fi
fi
}

# --- Main Flow ---
if $WATCH_MODE; then
    # Use alternate screen buffer for clean refresh
    tput smcup 2>/dev/null
    trap 'tput rmcup 2>/dev/null; exit 0' INT TERM

    while true; do
        collect_data
        compute_layout
        tput cup 0 0 2>/dev/null
        render_output
        # Clear any leftover lines from previous iteration
        tput ed 2>/dev/null
        if ! $SHOW_METRICS; then
            watch_sleep "$WATCH_INTERVAL"
        fi
    done
else
    collect_data
    compute_layout
    render_output
fi
