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
#
# Version: 2.1

SCRIPT_VERSION="2.1"

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


# Parse options using getopt
OPTIONS=$(getopt -o hvs:: --long help,version,lacp,vlan,bmac,separator::,group-bond,output:,no-color,all,filter-link:,diagram-out: -n "$0" -- "$@")
if [ $? -ne 0 ]; then
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
		--group-bond)
			SORT_BY_BOND=true
			shift
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
			echo -e "Usage: $0 [--lacp] [--vlan] [--bmac] [--all] [--no-color]"
			echo -e "       [--filter-link up|down] [-s[SEP]|--separator[=SEP]]"
			echo -e "       [--group-bond] [--output FORMAT] [--diagram-out FILE]"
			echo -e "       [--help]"
			echo -e ""
			echo -e "Version: $SCRIPT_VERSION"
			echo -e ""
			echo -e "Description:"
			echo -e " Lists physical network interfaces with detailed information including:"
			echo -e " PCI slot, driver, firmware, MAC, MTU, link, speed/duplex, bond membership,"
			echo -e " LLDP peer info, and optionally LACP status and VLAN tagging (via LLDP)."
			echo -e ""
			echo -e "Options:"
			echo -e " --lacp              Show LACP Aggregator ID and Partner MAC per interface"
			echo -e " --vlan              Show VLAN tagging information (from LLDP)"
			echo -e " --bmac              Show bridge MAC address"
			echo -e " --all               Enable all optional columns (--lacp --vlan --bmac)"
			echo -e " --no-color          Disable color output (auto-disabled for non-terminal)"
			echo -e " --filter-link TYPE  Show only interfaces with link up or down"
			echo -e " -s, --separator     Show │ column separators in table output; applies to CSV too"
			echo -e " -sSEP, --separator=SEP"
			echo -e "                     Use SEP as column separator in table and CSV output"
			echo -e " --group-bond        Sort rows by bond group, then by interface name"
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

# --- Diagram format setup ---
if [[ "$OUTPUT_FORMAT" =~ ^(dot|svg|png)$ ]]; then
    # Auto-enable all optional data for diagram completeness
    SHOW_LACP=true
    SHOW_VLAN=true
    SHOW_BMAC=true

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
    local STRIPPED=$(strip_ansi "$TEXT")
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

# --- Data Collection Arrays ---
declare -a DATA_DEVICE DATA_DRIVER DATA_FIRMWARE DATA_IFACE DATA_MAC DATA_MTU
declare -a DATA_LINK_PLAIN DATA_LINK_COLOR
declare -a DATA_SPEED_PLAIN DATA_SPEED_COLOR
declare -a DATA_BOND_PLAIN DATA_BOND_COLOR
declare -a DATA_BMAC
declare -a DATA_LACP_PLAIN DATA_LACP_COLOR
declare -a DATA_VLAN DATA_SWITCH DATA_PORT
ROW_COUNT=0

# --- Data Collection ---
for IFACE in $(ls /sys/class/net/ | grep -vE 'lo|vnet|virbr|br|bond|docker|tap|tun'); do
    [[ "$IFACE" == *.* ]] && continue

    DEVICE_PATH="/sys/class/net/$IFACE/device"
    [[ ! -e "$DEVICE_PATH" ]] && continue

    DEVICE=$(basename "$(readlink -f "$DEVICE_PATH")")
    ETHTOOL_I=$(ethtool -i "$IFACE" 2>/dev/null)
    FIRMWARE=$(echo "$ETHTOOL_I" | awk -F': ' '/firmware-version/ {print $2}')
    DRIVER=$(echo "$ETHTOOL_I" | awk -F': ' '/^driver:/ {print $2}')
    MTU=$(cat /sys/class/net/$IFACE/mtu 2>/dev/null)

    LINK_RAW=$(cat /sys/class/net/$IFACE/operstate 2>/dev/null)
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

    if [[ -L /sys/class/net/$IFACE/master ]]; then
        BOND_MASTER=$(basename "$(readlink -f /sys/class/net/$IFACE/master)")
    else
        BOND_MASTER="None"
    fi

    if [[ "$BOND_MASTER" != "None" ]]; then
        if [[ -z "${BOND_COLORS[$BOND_MASTER]}" ]]; then
            BOND_COLORS[$BOND_MASTER]=${COLOR_CODES[$COLOR_INDEX]}
            ((COLOR_INDEX=(COLOR_INDEX+1)%${#COLOR_CODES[@]}))
        fi
        BOND_COLOR="${BOND_COLORS[$BOND_MASTER]}${BOND_MASTER}${RESET_COLOR}"
        BOND_PLAIN="$BOND_MASTER"
        MAC=$(grep -E "Slave Interface: ${IFACE}|Permanent HW addr" /proc/net/bonding/${BOND_MASTER} |grep -A1 "Slave Interface: ${IFACE}"|tail -1|awk '{ print $4}' 2>/dev/null)
        BMAC=$(grep "System MAC address" /proc/net/bonding/${BOND_MASTER}|awk '{ print $4 }' 2>/dev/null)
    else
        BOND_COLOR="$BOND_MASTER"
        BOND_PLAIN="$BOND_MASTER"
        MAC=$(cat /sys/class/net/${IFACE}/address 2>/dev/null)
        BMAC="N/A"
    fi

    # LACP Status
    LACP_PLAIN="N/A"
    LACP_COLOR="N/A"
    if $SHOW_LACP && [[ "$BOND_MASTER" != "None" && -f /proc/net/bonding/$BOND_MASTER ]]; then
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
                if (agg && peer && state == "63")
                    printf "AggID:%s Peer:%s", agg, peer
                else if (agg && peer)
                    printf "AggID:%s Peer:%s (Partial)", agg, peer
                else
                    print "Pending"
            }
        ' /proc/net/bonding/$BOND_MASTER)

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

    # VLAN Info from LLDP
    VLAN_INFO=""
    if $SHOW_VLAN; then
        while IFS= read -r LINE; do
            VLAN_ID=$(echo "$LINE" | awk -F'VLAN: ' '{print $2}' | awk -F', ' '{print $1}'|awk '{ print $1 }')
            PVID=$(echo "$LINE" | awk -F'pvid: ' '{print $2}' | awk '{print $1}')
            [[ $PVID == "yes" ]] && VLAN_INFO+="${VLAN_ID}[P];" || VLAN_INFO+="${VLAN_ID};"
        done <<< "$(echo "$LLDP_OUTPUT" | grep 'VLAN:')"
        VLAN_INFO=${VLAN_INFO%, }
	VLAN_INFO=$(echo ${VLAN_INFO}|sed 's/;$//g')
	if [ "${VLAN_INFO}x" == "x" ]
	then
		VLAN_INFO="N/A"
	fi
    fi

    # Store collected data
    DATA_DEVICE[$ROW_COUNT]="$DEVICE"
    DATA_DRIVER[$ROW_COUNT]="$DRIVER"
    DATA_FIRMWARE[$ROW_COUNT]="$FIRMWARE"
    DATA_IFACE[$ROW_COUNT]="$IFACE"
    DATA_MAC[$ROW_COUNT]="$MAC"
    DATA_MTU[$ROW_COUNT]="$MTU"
    DATA_LINK_PLAIN[$ROW_COUNT]="$LINK_PLAIN"
    DATA_LINK_COLOR[$ROW_COUNT]="$LINK_COLOR"
    DATA_SPEED_PLAIN[$ROW_COUNT]="$SPEED_DUPLEX"
    DATA_SPEED_COLOR[$ROW_COUNT]="$(colorize_speed "$SPEED_DUPLEX")"
    DATA_BOND_PLAIN[$ROW_COUNT]="$BOND_PLAIN"
    DATA_BOND_COLOR[$ROW_COUNT]="$BOND_COLOR"
    DATA_BMAC[$ROW_COUNT]="$BMAC"
    DATA_LACP_PLAIN[$ROW_COUNT]="$LACP_PLAIN"
    DATA_LACP_COLOR[$ROW_COUNT]="$LACP_COLOR"
    DATA_VLAN[$ROW_COUNT]="$VLAN_INFO"
    DATA_SWITCH[$ROW_COUNT]="$SWITCH_NAME"
    DATA_PORT[$ROW_COUNT]="$PORT_NAME"
    ((ROW_COUNT++))
done

# --- Guard: no interfaces found ---
if [[ $ROW_COUNT -eq 0 ]]; then
    echo "No physical network interfaces found." >&2
    exit 0
fi

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

# --- Column Gap ---
if [[ -n "${FIELD_SEP}" ]]; then
    COL_GAP=" ${FIELD_SEP} "
else
    COL_GAP="   "
fi
COL_GAP_WIDTH=${#COL_GAP}

# --- Build Render Order ---
declare -a RENDER_ORDER
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
    IFS=$'\n' SORTED_BONDS=($(sort <<< "${UNIQUE_BONDS[*]}")); unset IFS

    # Append indices for each bond (sorted)
    for BOND in "${SORTED_BONDS[@]}"; do
        for ((i = 0; i < ROW_COUNT; i++)); do
            [[ "${DATA_BOND_PLAIN[$i]}" == "$BOND" ]] && RENDER_ORDER+=("$i")
        done
    done

    # Append unbonded interfaces sorted by interface name
    declare -a UNBONDED_PAIRS
    for ((i = 0; i < ROW_COUNT; i++)); do
        [[ "${DATA_BOND_PLAIN[$i]}" == "None" ]] && UNBONDED_PAIRS+=("${DATA_IFACE[$i]} $i")
    done
    if [[ ${#UNBONDED_PAIRS[@]} -gt 0 ]]; then
        IFS=$'\n' UNBONDED_PAIRS=($(sort <<< "${UNBONDED_PAIRS[*]}")); unset IFS
        for ENTRY in "${UNBONDED_PAIRS[@]}"; do
            RENDER_ORDER+=("${ENTRY##* }")
        done
    fi
else
    for ((i = 0; i < ROW_COUNT; i++)); do
        RENDER_ORDER+=("$i")
    done
fi

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

# Map speed (Mb/s) to edge pen width
dot_penwidth() {
    local RAW="$1"
    local NUM="${RAW%%[^0-9]*}"
    if [[ "$NUM" =~ ^[0-9]+$ ]]; then
        if (( NUM >= 100000 )); then
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
    local BLUE_COLOR="#89b4fa"
    local PEACH_COLOR="#fab387"
    local MAUVE_COLOR="#cba6f7"
    local GRAY_COLOR="#6c7086"
    local TEXT_COLOR="#cdd6f4"
    local SUBTEXT_COLOR="#a6adc8"

    # Categorize interfaces: bond members vs standalone
    declare -A BOND_MEMBERS  # bond_name -> space-separated row indices
    declare -a STANDALONE_INDICES
    declare -A SEEN_SWITCHES  # switch_name -> 1

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

DOTHEADER

    # --- Server node ---
    printf '    server [shape=plain, label=<\n'
    printf '        <TABLE BORDER="1" CELLBORDER="0" CELLSPACING="4" CELLPADDING="6" '
    printf 'BGCOLOR="%s" COLOR="%s">\n' "$SURFACE_COLOR" "$BORDER_COLOR"
    printf '        <TR><TD COLSPAN="2"><FONT POINT-SIZE="14" COLOR="%s"><B>%s</B></FONT></TD></TR>\n' \
        "$MAUVE_COLOR" "$(dot_escape "$HOSTNAME")"
    printf '        <TR><TD COLSPAN="2"><FONT COLOR="%s">Server</FONT></TD></TR>\n' "$SUBTEXT_COLOR"
    printf '        </TABLE>\n'
    printf '    >];\n\n'

    # --- Bond clusters with member interface nodes ---
    local CLUSTER_IDX=0
    for BOND_NAME in $(printf '%s\n' "${!BOND_MEMBERS[@]}" | sort); do
        local MEMBERS="${BOND_MEMBERS[$BOND_NAME]}"

        # Determine LACP status label for the bond
        local LACP_LABEL=""
        for IDX in $MEMBERS; do
            local LACP="${DATA_LACP_PLAIN[$IDX]}"
            if [[ "$LACP" == AggID* && "$LACP" != *"Partial"* ]]; then
                LACP_LABEL="LACP Active"
                break
            elif [[ "$LACP" == *"Partial"* ]]; then
                LACP_LABEL="LACP Partial"
            elif [[ "$LACP" == "Pending" && -z "$LACP_LABEL" ]]; then
                LACP_LABEL="LACP Pending"
            fi
        done
        [[ -z "$LACP_LABEL" ]] && LACP_LABEL="Bonded"

        printf '    subgraph cluster_bond_%d {\n' "$CLUSTER_IDX"
        printf '        style=dashed;\n'
        printf '        color="%s";\n' "$BLUE_COLOR"
        printf '        bgcolor="%s";\n' "${BG_COLOR}cc"
        printf '        fontcolor="%s";\n' "$BLUE_COLOR"
        printf '        label=<<FONT POINT-SIZE="12"><B>%s</B> (%s)</FONT>>;\n' \
            "$(dot_escape "$BOND_NAME")" "$(dot_escape "$LACP_LABEL")"
        printf '        penwidth=1.5;\n\n'

        for IDX in $MEMBERS; do
            local IFACE="${DATA_IFACE[$IDX]}"
            local DRIVER="${DATA_DRIVER[$IDX]}"
            local LINK="${DATA_LINK_PLAIN[$IDX]}"
            local NODE_ID
            NODE_ID=$(dot_id "$IFACE")

            local NODE_BORDER
            if [[ "$LINK" == "up" ]]; then
                NODE_BORDER="$GREEN_COLOR"
            else
                NODE_BORDER="$RED_COLOR"
            fi

            printf '        %s [shape=plain, label=<\n' "$NODE_ID"
            printf '            <TABLE BORDER="1" CELLBORDER="0" CELLSPACING="2" CELLPADDING="4" '
            printf 'BGCOLOR="%s" COLOR="%s">\n' "$SURFACE_COLOR" "$NODE_BORDER"
            printf '            <TR><TD><FONT COLOR="%s"><B>%s</B></FONT></TD></TR>\n' \
                "$TEXT_COLOR" "$(dot_escape "$IFACE")"
            printf '            <TR><TD><FONT POINT-SIZE="9" COLOR="%s">%s | %s</FONT></TD></TR>\n' \
                "$SUBTEXT_COLOR" "$(dot_escape "$DRIVER")" "$(dot_escape "${LINK^^}")"
            printf '            </TABLE>\n'
            printf '        >];\n'
        done

        printf '    }\n\n'
        ((CLUSTER_IDX++))
    done

    # --- Standalone interface nodes ---
    for IDX in "${STANDALONE_INDICES[@]}"; do
        local IFACE="${DATA_IFACE[$IDX]}"
        local DRIVER="${DATA_DRIVER[$IDX]}"
        local LINK="${DATA_LINK_PLAIN[$IDX]}"
        local NODE_ID
        NODE_ID=$(dot_id "$IFACE")

        local NODE_BORDER
        if [[ "$LINK" == "up" ]]; then
            NODE_BORDER="$GREEN_COLOR"
        else
            NODE_BORDER="$RED_COLOR"
        fi

        printf '    %s [shape=plain, label=<\n' "$NODE_ID"
        printf '        <TABLE BORDER="1" CELLBORDER="0" CELLSPACING="2" CELLPADDING="4" '
        printf 'BGCOLOR="%s" COLOR="%s">\n' "$SURFACE_COLOR" "$NODE_BORDER"
        printf '        <TR><TD><FONT COLOR="%s"><B>%s</B></FONT></TD></TR>\n' \
            "$TEXT_COLOR" "$(dot_escape "$IFACE")"
        printf '        <TR><TD><FONT POINT-SIZE="9" COLOR="%s">%s | %s</FONT></TD></TR>\n' \
            "$SUBTEXT_COLOR" "$(dot_escape "$DRIVER")" "$(dot_escape "${LINK^^}")"
        printf '        </TABLE>\n'
        printf '    >];\n\n'
    done

    # --- Switch nodes ---
    for SW_NAME in $(printf '%s\n' "${!SEEN_SWITCHES[@]}" | sort); do
        local SW_ID
        SW_ID=$(dot_id "sw_${SW_NAME}")
        printf '    %s [shape=plain, label=<\n' "$SW_ID"
        printf '        <TABLE BORDER="1" CELLBORDER="0" CELLSPACING="2" CELLPADDING="6" '
        printf 'BGCOLOR="%s" COLOR="%s" STYLE="ROUNDED">\n' "$SURFACE_COLOR" "$PEACH_COLOR"
        printf '        <TR><TD><FONT POINT-SIZE="13" COLOR="%s"><B>%s</B></FONT></TD></TR>\n' \
            "$PEACH_COLOR" "$(dot_escape "$SW_NAME")"
        printf '        <TR><TD><FONT COLOR="%s">Switch</FONT></TD></TR>\n' "$SUBTEXT_COLOR"
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

    # --- Edges: server -> interfaces ---
    for ((i = 0; i < ROW_COUNT; i++)); do
        local IFACE="${DATA_IFACE[$i]}"
        local NODE_ID
        NODE_ID=$(dot_id "$IFACE")
        printf '    server -> %s [style=invis, weight=10];\n' "$NODE_ID"
    done
    printf '\n'

    # --- Edges: interfaces -> switches/stubs ---
    for ((i = 0; i < ROW_COUNT; i++)); do
        local IFACE="${DATA_IFACE[$i]}"
        local NODE_ID
        NODE_ID=$(dot_id "$IFACE")
        local SW="${DATA_SWITCH[$i]}"
        local PORT="${DATA_PORT[$i]}"
        local SPEED_RAW="${DATA_SPEED_PLAIN[$i]}"
        local LINK="${DATA_LINK_PLAIN[$i]}"
        local VLAN="${DATA_VLAN[$i]}"

        # Build edge label
        local LABEL_PARTS=()
        [[ -n "$PORT" ]] && LABEL_PARTS+=("$(dot_escape "$PORT")")

        local SPEED_NUM="${SPEED_RAW%%[^0-9]*}"
        if [[ "$SPEED_NUM" =~ ^[0-9]+$ ]]; then
            LABEL_PARTS+=("$(dot_escape "$SPEED_RAW")")
        fi

        if [[ -n "$VLAN" && "$VLAN" != "N/A" ]]; then
            LABEL_PARTS+=("VLAN $(dot_escape "$VLAN")")
        fi

        local EDGE_LABEL=""
        if [[ ${#LABEL_PARTS[@]} -gt 0 ]]; then
            EDGE_LABEL=$(printf '%s\n' "${LABEL_PARTS[@]}" | paste -sd '\n' -)
        fi

        local PW
        PW=$(dot_penwidth "$SPEED_RAW")

        if [[ -n "$SW" ]]; then
            local SW_ID
            SW_ID=$(dot_id "sw_${SW}")
            local EDGE_COLOR
            if [[ "$LINK" == "up" ]]; then
                EDGE_COLOR="$GREEN_COLOR"
            else
                EDGE_COLOR="$RED_COLOR"
            fi
            printf '    %s -> %s [label=<%s>, penwidth=%s, color="%s", fontcolor="%s"];\n' \
                "$NODE_ID" "$SW_ID" \
                "$(printf '%s' "$EDGE_LABEL" | sed 's/\\n/<BR\/>/g')" \
                "$PW" "$EDGE_COLOR" "$SUBTEXT_COLOR"
        else
            printf '    %s -> no_lldp_peer [style=dashed, color="%s", fontcolor="%s", penwidth=1.0];\n' \
                "$NODE_ID" "$GRAY_COLOR" "$GRAY_COLOR"
        fi
    done

    # --- Rank constraints ---
    printf '\n    { rank=min; server; }\n'

    # Switch nodes on the right
    local SW_NAMES
    SW_NAMES=$(printf '%s\n' "${!SEEN_SWITCHES[@]}" | sort)
    if [[ -n "$SW_NAMES" ]]; then
        printf '    { rank=max;'
        while IFS= read -r SW_NAME; do
            printf ' %s;' "$(dot_id "sw_${SW_NAME}")"
        done <<< "$SW_NAMES"
        if [[ "$HAS_DISCONNECTED" == true ]]; then
            printf ' no_lldp_peer;'
        fi
        printf ' }\n'
    elif [[ "$HAS_DISCONNECTED" == true ]]; then
        printf '    { rank=max; no_lldp_peer; }\n'
    fi

    printf '}\n'
}

# --- Output ---
if [[ "${OUTPUT_FORMAT}" == "table" ]]; then
    # Header
    printf "%-${COL_W_DEVICE}s${COL_GAP}%-${COL_W_DRIVER}s${COL_GAP}%-${COL_W_FIRMWARE}s${COL_GAP}%-${COL_W_IFACE}s${COL_GAP}%-${COL_W_MAC}s${COL_GAP}%-${COL_W_MTU}s${COL_GAP}%-${COL_W_LINK}s${COL_GAP}%-${COL_W_SPEED}s${COL_GAP}%-${COL_W_BOND}s" \
        "Device" "Driver" "Firmware" "Interface" "MAC Address" "MTU" "Link" "Speed/Duplex" "Parent Bond"
    ${SHOW_BMAC} && printf "${COL_GAP}%-${COL_W_BMAC}s" "Bond MAC"
    ${SHOW_LACP} && printf "${COL_GAP}%-${COL_W_LACP}s" "LACP Status"
    ${SHOW_VLAN} && printf "${COL_GAP}%-${COL_W_VLAN}s" "VLAN"
    printf "${COL_GAP}%-${COL_W_SWITCH}s${COL_GAP}%s\n" "Switch Name" "Port Name"
    # Separator line
    SEP_WIDTH=$((COL_W_DEVICE + COL_GAP_WIDTH + COL_W_DRIVER + COL_GAP_WIDTH + COL_W_FIRMWARE + COL_GAP_WIDTH + COL_W_IFACE + COL_GAP_WIDTH + COL_W_MAC + COL_GAP_WIDTH + COL_W_MTU + COL_GAP_WIDTH + COL_W_LINK + COL_GAP_WIDTH + COL_W_SPEED + COL_GAP_WIDTH + COL_W_BOND))
    ${SHOW_BMAC} && SEP_WIDTH=$((SEP_WIDTH + COL_GAP_WIDTH + COL_W_BMAC))
    ${SHOW_LACP} && SEP_WIDTH=$((SEP_WIDTH + COL_GAP_WIDTH + COL_W_LACP))
    ${SHOW_VLAN} && SEP_WIDTH=$((SEP_WIDTH + COL_GAP_WIDTH + COL_W_VLAN))
    SEP_WIDTH=$((SEP_WIDTH + COL_GAP_WIDTH + COL_W_SWITCH + COL_GAP_WIDTH + COL_W_PORT))
    printf '%*s\n' "$SEP_WIDTH" '' | tr ' ' '-'
    # Data rows
    for i in "${RENDER_ORDER[@]}"; do
        printf "%-${COL_W_DEVICE}s${COL_GAP}%-${COL_W_DRIVER}s${COL_GAP}%-${COL_W_FIRMWARE}s${COL_GAP}%-${COL_W_IFACE}s${COL_GAP}%-${COL_W_MAC}s${COL_GAP}%-${COL_W_MTU}s${COL_GAP}" \
            "${DATA_DEVICE[$i]}" "${DATA_DRIVER[$i]}" "${DATA_FIRMWARE[$i]}" "${DATA_IFACE[$i]}" "${DATA_MAC[$i]}" "${DATA_MTU[$i]}"
        pad_color "${DATA_LINK_COLOR[$i]}" "$COL_W_LINK"
        printf "${COL_GAP}"
        pad_color "${DATA_SPEED_COLOR[$i]}" "$COL_W_SPEED"
        printf "${COL_GAP}"
        pad_color "${DATA_BOND_COLOR[$i]}" "$COL_W_BOND"
        if ${SHOW_BMAC}; then
            printf "${COL_GAP}%-${COL_W_BMAC}s" "${DATA_BMAC[$i]}"
        fi
        if ${SHOW_LACP}; then
            printf "${COL_GAP}"
            pad_color "${DATA_LACP_COLOR[$i]}" "$COL_W_LACP"
        fi
        ${SHOW_VLAN} && printf "${COL_GAP}%-${COL_W_VLAN}s" "${DATA_VLAN[$i]}"
        printf "${COL_GAP}%-${COL_W_SWITCH}s${COL_GAP}%s\n" "${DATA_SWITCH[$i]}" "${DATA_PORT[$i]}"
    done
elif [[ "${OUTPUT_FORMAT}" == "csv" ]]; then
    FS="${FIELD_SEP:-,}"
    # CSV Header
    printf "%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s" "Device" "Driver" "Firmware" "Interface" "MAC Address" "MTU" "Link" "Speed/Duplex" "Parent Bond"
    ${SHOW_BMAC} && printf "${FS}%s" "Bond MAC"
    ${SHOW_LACP} && printf "${FS}%s" "LACP Status"
    ${SHOW_VLAN} && printf "${FS}%s" "VLAN"
    printf "${FS}%s${FS}%s\n" "Switch Name" "Port Name"
    # CSV Data rows
    for i in "${RENDER_ORDER[@]}"; do
        printf "%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s" \
            "${DATA_DEVICE[$i]}" "${DATA_DRIVER[$i]}" "${DATA_FIRMWARE[$i]}" "${DATA_IFACE[$i]}" "${DATA_MAC[$i]}" \
            "${DATA_MTU[$i]}" "${DATA_LINK_PLAIN[$i]}" "${DATA_SPEED_PLAIN[$i]}" "${DATA_BOND_PLAIN[$i]}"
        ${SHOW_BMAC} && printf "${FS}%s" "${DATA_BMAC[$i]}"
        ${SHOW_LACP} && printf "${FS}%s" "${DATA_LACP_PLAIN[$i]}"
        ${SHOW_VLAN} && printf "${FS}%s" "${DATA_VLAN[$i]}"
        printf "${FS}%s${FS}%s\n" "${DATA_SWITCH[$i]}" "${DATA_PORT[$i]}"
    done
elif [[ "${OUTPUT_FORMAT}" == "json" ]]; then
    printf '[\n'
    LAST_IDX="${RENDER_ORDER[-1]}"
    for i in "${RENDER_ORDER[@]}"; do
        printf '  {\n'
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
        printf ',\n    "switch_name": "%s"' "$(json_escape "${DATA_SWITCH[$i]}")"
        printf ',\n    "port_name": "%s"' "$(json_escape "${DATA_PORT[$i]}")"
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
