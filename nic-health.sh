#!/bin/bash
#
# Script Name: nic-health.sh
# Description: Companion to nic-xray.sh. Evaluates physical NIC hardware and
#              data-path health and returns a monitoring-friendly verdict
#              (OK/WARN/CRIT/UNKNOWN) with evidence and remediation hints.
#              Passive and read-only: it never changes NIC state.
#              Design: docs/design/nic-health.md
#
# Author: Ciro Iriarte <ciro.iriarte+software@gmail.com>
# Created: 2026-10-20
#
# Requirements:
#   - Must be run as root (except --help, --version, --check-tools)
#   - Requires: ethtool, getopt, readlink
#   - Optional: lspci (NIC vendor/model names)
#
# Change Log:
#   - 2026-10-20: Phase 1 skeleton: sysfs discovery with per-ASIC grouping,
#                 result records, Nagios exit codes, table/JSON/CSV output,
#                 --check-tools, generic PCIe link check
#
# Version: 2.10.3

SCRIPT_VERSION="2.10.3"
SCRIPT_NAME="nic-health.sh"
JSON_SCHEMA_VERSION=1
DESIGN_REF="docs/design/nic-health.md"

# Runs as root: never resolve commands through a caller-controlled PATH
SAFE_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
PATH="$SAFE_PATH"
export PATH

# Nagios-compatible exit codes
EXIT_OK=0
EXIT_WARN=1
EXIT_CRIT=2
EXIT_UNKNOWN=3

# Severities
SEV_OK="OK"
SEV_WARN="WARN"
SEV_CRIT="CRIT"
SEV_UNKNOWN="UNKNOWN"
SEV_NA="N/A"
SEVERITIES=("$SEV_OK" "$SEV_WARN" "$SEV_CRIT" "$SEV_UNKNOWN" "$SEV_NA")

# Interface name pattern to skip (virtual, bond masters, etc.), as in nic-xray.sh
IFACE_SKIP_PATTERN='^(lo|vnet|virbr|br|bond|docker|tap|tun)'

SYSFS_NET="/sys/class/net"
SYSFS_PCI="/sys/bus/pci/devices"
PCI_SUBSYSTEM="pci"

# Tool catalog for --check-tools and JSON capabilities (parallel arrays)
REQUIRED_CMDS=("ethtool" "getopt" "readlink")
TOOL_NAMES=("ethtool" "getopt" "readlink" "lspci" "devlink" "mlxlink" "mstlink")
TOOL_ROLES=("required" "required" "required" "optional" "optional" "optional" "optional")
TOOL_USES=(
    "Driver and firmware identification"
    "Command-line parsing"
    "sysfs path resolution"
    "NIC vendor/model names (falls back to PCI IDs)"
    "devlink health and firmware checks (planned, Phase 2)"
    "mlx5 deep mode via NVIDIA MFT (planned, Phase 5)"
    "mlx5 deep mode via open-source mstflint (planned, Phase 5)"
)
TOOL_PACKAGES=(
    "ethtool"
    "util-linux"
    "coreutils"
    "pciutils"
    "iproute2 (iproute on RHEL)"
    "NVIDIA MFT (proprietary, install manually)"
    "mstflint"
)

# --- Defaults ---
OUTPUT_FORMAT="table"
USE_COLOR=true
CHECK_TOOLS=false
IFACE_FILTER=()

# --- Helpers ---

usage() {
    echo -e "Usage: $SCRIPT_NAME [-i|--interface IFACE]... [-O|--output table|csv|json]"
    echo -e "       [-n|--no-color] [-t|--check-tools] [-v|--version] [-h|--help]"
    echo -e ""
    echo -e "Version: $SCRIPT_VERSION"
    echo -e ""
    echo -e "Description:"
    echo -e " Evaluates physical NIC hardware and data-path health and reports a verdict"
    echo -e " per check (OK, WARN, CRIT, UNKNOWN, N/A) with evidence and remediation hints."
    echo -e " Read-only: never changes NIC, driver, or firmware state."
    echo -e " Ports of the same physical card (ASIC) are grouped; card-level checks run once."
    echo -e ""
    echo -e "Options:"
    echo -e " -i, --interface IFACE  Evaluate only IFACE (repeatable; default: all physical NICs)"
    echo -e " -O, --output TYPE      Output format: table (default), csv, or json"
    echo -e " -n, --no-color         Disable color output (auto-disabled for non-terminal)"
    echo -e " -t, --check-tools      List required/optional tools, what each enables, and exit"
    echo -e "                        (does not require root)"
    echo -e " -v, --version          Display version information"
    echo -e " -h, --help             Display this help message"
    echo -e ""
    echo -e "Checks (Phase 1):"
    echo -e " generic.pcie.link      PCIe link trained below the card's capability (WARN)"
    echo -e ""
    echo -e "Exit status (Nagios-compatible):"
    echo -e " $EXIT_OK  All checks OK or N/A"
    echo -e " $EXIT_WARN  At least one WARN, no CRIT"
    echo -e " $EXIT_CRIT  At least one CRIT"
    echo -e " $EXIT_UNKNOWN  UNKNOWN: usage error, not root, no eligible NIC, or only UNKNOWN results"
    echo -e ""
    echo -e "See also: nic-xray.sh(8) for inventory and topology."
}

# Print an error and exit UNKNOWN (never WARN: monitoring must not read a typo as a warning)
die_unknown() {
    echo -e "❌ $1" >&2
    [[ "${2:-}" == "usage" ]] && { echo >&2; usage >&2; }
    exit "$EXIT_UNKNOWN"
}

# Escape a string for JSON output (backslash, quote and all C0 control characters)
json_escape() {
    local STR="$1"
    STR="${STR//\\/\\\\}"
    STR="${STR//\"/\\\"}"
    STR="${STR//$'\n'/\\n}"
    STR="${STR//$'\r'/\\r}"
    STR="${STR//$'\t'/\\t}"
    STR="${STR//$'\b'/\\b}"
    STR="${STR//$'\f'/\\f}"
    # Remaining C0 control characters (U+0001-U+001F) must be \u-escaped
    if [[ "$STR" == *[$'\x01'-$'\x1f']* ]]; then
        local OUT="" CHAR CODE i
        for (( i = 0; i < ${#STR}; i++ )); do
            CHAR="${STR:i:1}"
            if [[ "$CHAR" == [$'\x01'-$'\x1f'] ]]; then
                printf -v CODE '%d' "'$CHAR"
                printf -v CHAR '\\u%04x' "$CODE"
            fi
            OUT+="$CHAR"
        done
        STR="$OUT"
    fi
    printf '%s' "$STR"
}

# Wrap a CSV field value in double-quotes (RFC 4180)
csv_escape() {
    local V="$1"
    V="${V//\"/\"\"}"
    printf '"%s"' "$V"
}

# Read a sysfs attribute; prints nothing if unreadable
read_attr() {
    local FILE="$1"
    [[ -r "$FILE" ]] || return 1
    local VAL
    VAL=$(<"$FILE") 2>/dev/null || return 1
    printf '%s' "$VAL"
}

# Convert a PCIe speed string ("16.0 GT/s PCIe", "8 GT/s") to tenths of GT/s
# Prints nothing for unknown/unparseable values
pcie_speed_tenths() {
    local RAW="${1%% GT/s*}"
    if [[ "$RAW" =~ ^([0-9]+)(\.([0-9]))?$ ]]; then
        printf '%d' $(( BASH_REMATCH[1] * 10 + ${BASH_REMATCH[3]:-0} ))
    fi
}

# Map a severity to its color
severity_color() {
    case "$1" in
        "$SEV_OK")      printf '%s' "$GREEN" ;;
        "$SEV_WARN")    printf '%s' "$YELLOW" ;;
        "$SEV_CRIT")    printf '%s' "$RED" ;;
        "$SEV_UNKNOWN") printf '%s' "$MAGENTA" ;;
        *)              printf '%s' "$DIM" ;;
    esac
}

# Map a severity to its icon (summary lines only; icons are never width-padded)
severity_icon() {
    case "$1" in
        "$SEV_OK")      printf '✅' ;;
        "$SEV_WARN")    printf '⚠️' ;;
        "$SEV_CRIT")    printf '❌' ;;
        "$SEV_UNKNOWN") printf '❔' ;;
        *)              printf '➖' ;;
    esac
}

# --- Argument Parsing ---
if ! command -v getopt &>/dev/null; then
    die_unknown "Required command 'getopt' is not installed or not in PATH."
fi

if ! OPTIONS=$(getopt -o hvi:O:nt --long help,version,interface:,output:,no-color,check-tools -n "$SCRIPT_NAME" -- "$@"); then
    die_unknown "Failed to parse options." usage
fi

eval set -- "$OPTIONS"

while true; do
    case "$1" in
        -i|--interface)
            [[ -n "$2" ]] || die_unknown "Empty value for --interface." usage
            IFACE_FILTER+=("$2")
            shift 2
            ;;
        -O|--output)
            OUTPUT_FORMAT="$2"
            [[ "$OUTPUT_FORMAT" =~ ^(table|csv|json)$ ]] \
                || die_unknown "Invalid --output value '$OUTPUT_FORMAT' (expected table, csv or json)." usage
            shift 2
            ;;
        -n|--no-color)
            USE_COLOR=false
            shift
            ;;
        -t|--check-tools)
            CHECK_TOOLS=true
            shift
            ;;
        -v|--version)
            echo "$SCRIPT_NAME $SCRIPT_VERSION"
            exit "$EXIT_OK"
            ;;
        -h|--help)
            usage
            exit "$EXIT_OK"
            ;;
        --)
            shift
            break
            ;;
        *)
            die_unknown "Unexpected option: $1" usage
            ;;
    esac
done

# No positional arguments are accepted; reject instead of silently ignoring them
if (( $# > 0 )); then
    die_unknown "Unexpected argument: $1" usage
fi

# --- Auto-disable colors for non-terminal output ---
[[ ! -t 1 ]] && USE_COLOR=false

# --- Color Setup ---
if $USE_COLOR; then
    RESET_COLOR=$'\033[0m'
    GREEN=$'\033[1;32m'
    YELLOW=$'\033[1;33m'
    RED=$'\033[1;31m'
    MAGENTA=$'\033[1;35m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
else
    RESET_COLOR=""
    GREEN=""
    YELLOW=""
    RED=""
    MAGENTA=""
    BOLD=""
    DIM=""
fi

# --- Tool availability ---
declare -A TOOL_PATH=()
for TOOL in "${TOOL_NAMES[@]}"; do
    TOOL_PATH["$TOOL"]=$(command -v "$TOOL" 2>/dev/null || true)
done

# Print the tool catalog; returns EXIT_UNKNOWN if a required tool is missing
check_tools_report() {
    local MISSING=0 i NAME STATUS COLOR
    printf '%b🧰 %s %s: tool check%b\n\n' "$BOLD" "$SCRIPT_NAME" "$SCRIPT_VERSION" "$RESET_COLOR"
    printf '%-9s  %-8s  %-8s  %-22s  %s\n' "TOOL" "ROLE" "STATUS" "PATH" "USED FOR"
    for i in "${!TOOL_NAMES[@]}"; do
        NAME="${TOOL_NAMES[i]}"
        if [[ -n "${TOOL_PATH[$NAME]}" ]]; then
            STATUS="found"; COLOR="$GREEN"
        else
            STATUS="missing"
            if [[ "${TOOL_ROLES[i]}" == "required" ]]; then
                COLOR="$RED"; (( ++MISSING ))
            else
                COLOR="$YELLOW"
            fi
        fi
        printf '%-9s  %-8s  %b%-8s%b  %-22s  %s\n' "$NAME" "${TOOL_ROLES[i]}" \
            "$COLOR" "$STATUS" "$RESET_COLOR" "${TOOL_PATH[$NAME]:--}" "${TOOL_USES[i]}"
        [[ "$STATUS" == "missing" ]] && printf '%-9s  %-8s  %-8s  %-22s  ↳ package: %s\n' "" "" "" "" "${TOOL_PACKAGES[i]}"
    done
    echo
    if (( MISSING > 0 )); then
        echo "❌ $MISSING required tool(s) missing."
        return "$EXIT_UNKNOWN"
    fi
    echo "✅ All required tools present. Missing optional tools only disable the checks listed."
    return "$EXIT_OK"
}

if $CHECK_TOOLS; then
    check_tools_report
    exit $?
fi

# --- Validation Section ---
if [[ $EUID -ne 0 ]]; then
    die_unknown "This script must be run as root. Please use sudo or switch to root."
fi

for CMD in "${REQUIRED_CMDS[@]}"; do
    [[ -n "${TOOL_PATH[$CMD]}" ]] || die_unknown "Required command '$CMD' is not installed or not in PATH. Run '$SCRIPT_NAME --check-tools'."
done

# --- Data: discovery ---
# Ports (parallel arrays, indexed by port number)
PORT_IFACE=()
PORT_BDF=()
PORT_ASIC=()
PORT_DRIVER=()
PORT_OPER=()
PORT_VF=()
# ASICs (physical cards): ordered list of IDs plus per-ID attributes
ASIC_IDS=()
declare -A ASIC_PORTS=()
declare -A ASIC_BDF=()
declare -A ASIC_DRIVER=()
declare -A ASIC_MODEL=()
declare -A ASIC_FW=()
# Results (parallel arrays, one row per check result)
REC_SCOPE=()
REC_TARGET=()
REC_CHECK=()
REC_VALUE=()
REC_UNIT=()
REC_THRESHOLD=()
REC_SEV=()
REC_EVIDENCE=()
REC_HINT=()
REC_REF=()

# Append one check result
# Args: scope target check_id value unit threshold severity evidence hint ref
add_record() {
    REC_SCOPE+=("$1")
    REC_TARGET+=("$2")
    REC_CHECK+=("$3")
    REC_VALUE+=("$4")
    REC_UNIT+=("$5")
    REC_THRESHOLD+=("$6")
    REC_SEV+=("$7")
    REC_EVIDENCE+=("$8")
    REC_HINT+=("$9")
    REC_REF+=("${10}")
}

# Resolve "Vendor Model" for a PCI device: lspci when available, else sysfs IDs
pci_model() {
    local BDF="$1" LINE
    if [[ -n "${TOOL_PATH[lspci]}" ]]; then
        LINE=$(LC_ALL=C lspci -s "$BDF" -mm 2>/dev/null)
        # Format: SLOT "Class" "Vendor" "Device" ...
        if [[ "$LINE" =~ ^[^\ ]+\ \"[^\"]*\"\ \"([^\"]*)\"\ \"([^\"]*)\" ]]; then
            printf '%s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
            return
        fi
    fi
    local VENDOR DEVICE
    VENDOR=$(read_attr "$SYSFS_PCI/$BDF/vendor")
    DEVICE=$(read_attr "$SYSFS_PCI/$BDF/device")
    printf 'PCI %s:%s' "${VENDOR#0x}" "${DEVICE#0x}"
}

# Discover physical NIC ports from sysfs and group them by ASIC (PCI domain:bus:device)
discover() {
    local IFACE_PATH IFACE DEV SUBSYS BDF
    local -a PCI_LINES=()
    local -A WANTED=() SEEN=()

    for IFACE in "${IFACE_FILTER[@]}"; do
        WANTED["$IFACE"]=1
    done

    for IFACE_PATH in "$SYSFS_NET"/*; do
        IFACE="${IFACE_PATH##*/}"
        DEV="$IFACE_PATH/device"
        (( ${#WANTED[@]} > 0 )) && [[ -z "${WANTED[$IFACE]:-}" ]] && continue
        if (( ${#WANTED[@]} == 0 )); then
            [[ "$IFACE" =~ $IFACE_SKIP_PATTERN ]] && continue
            [[ "$IFACE" == *.* ]] && continue
        fi
        if [[ ! -e "$DEV" ]]; then
            [[ -n "${WANTED[$IFACE]:-}" ]] && die_unknown "Interface '$IFACE' is not a physical device."
            continue
        fi
        SEEN["$IFACE"]=1

        SUBSYS=$(readlink -f "$DEV/subsystem")
        SUBSYS="${SUBSYS##*/}"
        if [[ "$SUBSYS" != "$PCI_SUBSYSTEM" ]]; then
            add_record "port" "$IFACE" "discovery.bus" "$SUBSYS" "bus" "pci" "$SEV_NA" \
                "device bus: $SUBSYS" "Not a PCI NIC (e.g. BMC USB network interface); not evaluated" "$DESIGN_REF §4.1"
            continue
        fi
        BDF=$(readlink -f "$DEV")
        BDF="${BDF##*/}"
        PCI_LINES+=("$BDF $IFACE")
    done

    for IFACE in "${!WANTED[@]}"; do
        [[ -n "${SEEN[$IFACE]:-}" ]] || die_unknown "Interface '$IFACE' not found."
    done

    # Sort by PCI address so ASICs and their ports appear in slot/function order
    local LINE ASIC IDX DRV FW
    while read -r BDF IFACE; do
        [[ -z "$BDF" ]] && continue
        ASIC="${BDF%.*}"
        IDX=${#PORT_IFACE[@]}
        DRV=$(readlink -f "$SYSFS_NET/$IFACE/device/driver")
        DRV="${DRV##*/}"
        PORT_IFACE+=("$IFACE")
        PORT_BDF+=("$BDF")
        PORT_ASIC+=("$ASIC")
        PORT_DRIVER+=("$DRV")
        PORT_OPER+=("$(read_attr "$SYSFS_NET/$IFACE/operstate")")
        if [[ -e "$SYSFS_NET/$IFACE/device/physfn" ]]; then PORT_VF+=(true); else PORT_VF+=(false); fi

        if [[ -z "${ASIC_BDF[$ASIC]:-}" ]]; then
            ASIC_IDS+=("$ASIC")
            ASIC_BDF["$ASIC"]="$BDF"
            ASIC_DRIVER["$ASIC"]="$DRV"
            ASIC_MODEL["$ASIC"]=$(pci_model "$BDF")
            FW=$(LC_ALL=C ethtool -i "$IFACE" 2>/dev/null)
            [[ "$FW" =~ firmware-version:\ ([^$'\n']*) ]] && FW="${BASH_REMATCH[1]}" || FW=""
            ASIC_FW["$ASIC"]="${FW:-unknown}"
            ASIC_PORTS["$ASIC"]="$IDX"
        else
            ASIC_PORTS["$ASIC"]+=" $IDX"
        fi
    done < <(printf '%s\n' "${PCI_LINES[@]}" | LC_ALL=C sort)
}

# --- Checks ---

# generic.pcie.link: compare trained PCIe link speed/width with the device maximum
check_pcie_link() {
    local ASIC="$1"
    local BDF="${ASIC_BDF[$ASIC]}"
    local DIR="$SYSFS_PCI/$BDF"
    local CHECK="generic.pcie.link" UNIT="GT/s xlanes" REF="$DESIGN_REF §6.1"
    local CUR_S MAX_S CUR_W MAX_W CUR_T MAX_T

    CUR_S=$(read_attr "$DIR/current_link_speed")
    MAX_S=$(read_attr "$DIR/max_link_speed")
    CUR_W=$(read_attr "$DIR/current_link_width")
    MAX_W=$(read_attr "$DIR/max_link_width")

    if [[ ! -e "$DIR/current_link_speed" && ! -e "$DIR/max_link_speed" ]]; then
        add_record "asic" "$ASIC" "$CHECK" "-" "$UNIT" "-" "$SEV_NA" \
            "no PCIe link attributes in sysfs" "No PCIe link to train: virtual function or chipset-integrated NIC" "$REF"
        return
    fi

    CUR_T=$(pcie_speed_tenths "$CUR_S")
    MAX_T=$(pcie_speed_tenths "$MAX_S")
    local VALUE="${CUR_S%% PCIe*} x${CUR_W}" THRESH="${MAX_S%% PCIe*} x${MAX_W}"
    local EVIDENCE="current_link_speed=$CUR_S current_link_width=$CUR_W max_link_speed=$MAX_S max_link_width=$MAX_W"

    if [[ -z "$CUR_T" || -z "$MAX_T" || ! "$CUR_W" =~ ^[0-9]+$ || ! "$MAX_W" =~ ^[0-9]+$ ]]; then
        add_record "asic" "$ASIC" "$CHECK" "$VALUE" "$UNIT" "$THRESH" "$SEV_UNKNOWN" \
            "$EVIDENCE" "Link attributes unreadable or unknown (link down or device in low-power state?)" "$REF"
    elif (( CUR_T < MAX_T || CUR_W < MAX_W )); then
        add_record "asic" "$ASIC" "$CHECK" "$VALUE" "$UNIT" "$THRESH" "$SEV_WARN" \
            "$EVIDENCE" "Card trained below its capability: check slot width/generation, BIOS PCIe settings, riser; reseat. A slot narrower than the card is permanent" "$REF"
    else
        add_record "asic" "$ASIC" "$CHECK" "$VALUE" "$UNIT" "$THRESH" "$SEV_OK" "$EVIDENCE" "" "$REF"
    fi
}

run_checks() {
    local ASIC
    for ASIC in "${ASIC_IDS[@]}"; do
        check_pcie_link "$ASIC"
    done
}

# --- Verdict ---
declare -A SEV_COUNT=()

# Count results per severity and derive the exit code (CRIT > WARN > UNKNOWN > OK)
compute_verdict() {
    local SEV
    for SEV in "${SEVERITIES[@]}"; do SEV_COUNT["$SEV"]=0; done
    for SEV in "${REC_SEV[@]}"; do (( ++SEV_COUNT["$SEV"] )); done

    if   (( SEV_COUNT[$SEV_CRIT] > 0 ));    then VERDICT="$SEV_CRIT";    EXIT_CODE=$EXIT_CRIT
    elif (( SEV_COUNT[$SEV_WARN] > 0 ));    then VERDICT="$SEV_WARN";    EXIT_CODE=$EXIT_WARN
    elif (( SEV_COUNT[$SEV_UNKNOWN] > 0 )); then VERDICT="$SEV_UNKNOWN"; EXIT_CODE=$EXIT_UNKNOWN
    else                                         VERDICT="$SEV_OK";      EXIT_CODE=$EXIT_OK
    fi
}

# --- Rendering ---

render_table() {
    local ASIC IDX i SEV COLOR
    printf '%b🩺 %s %s%b  host %s  %s\n\n' "$BOLD" "$SCRIPT_NAME" "$SCRIPT_VERSION" "$RESET_COLOR" "$HOSTNAME" "$COLLECTED_AT"

    printf '%bHardware%b\n' "$BOLD" "$RESET_COLOR"
    for ASIC in "${ASIC_IDS[@]}"; do
        printf '  %s  %s  (%s, fw %s)\n' "$ASIC" "${ASIC_MODEL[$ASIC]}" "${ASIC_DRIVER[$ASIC]}" "${ASIC_FW[$ASIC]}"
        local PORT_LIST=""
        for IDX in ${ASIC_PORTS[$ASIC]}; do
            PORT_LIST+="${PORT_IFACE[IDX]} (${PORT_OPER[IDX]}$(${PORT_VF[IDX]} && printf ', VF'))  "
        done
        printf '    └─ %s\n' "${PORT_LIST%  }"
    done
    echo

    local -a HEAD=("SEVERITY" "SCOPE" "TARGET" "CHECK" "VALUE" "THRESHOLD" "HINT")
    local W_SEV=${#HEAD[0]} W_SCOPE=${#HEAD[1]} W_TARGET=${#HEAD[2]} W_CHECK=${#HEAD[3]} W_VALUE=${#HEAD[4]} W_THRESH=${#HEAD[5]}
    for i in "${!REC_SEV[@]}"; do
        (( ${#REC_SEV[i]} > W_SEV ))          && W_SEV=${#REC_SEV[i]}
        (( ${#REC_SCOPE[i]} > W_SCOPE ))      && W_SCOPE=${#REC_SCOPE[i]}
        (( ${#REC_TARGET[i]} > W_TARGET ))    && W_TARGET=${#REC_TARGET[i]}
        (( ${#REC_CHECK[i]} > W_CHECK ))      && W_CHECK=${#REC_CHECK[i]}
        (( ${#REC_VALUE[i]} > W_VALUE ))      && W_VALUE=${#REC_VALUE[i]}
        (( ${#REC_THRESHOLD[i]} > W_THRESH )) && W_THRESH=${#REC_THRESHOLD[i]}
    done

    printf '%bChecks%b\n' "$BOLD" "$RESET_COLOR"
    printf "  %-${W_SEV}s  %-${W_SCOPE}s  %-${W_TARGET}s  %-${W_CHECK}s  %-${W_VALUE}s  %-${W_THRESH}s  %s\n" "${HEAD[@]}"
    for i in "${!REC_SEV[@]}"; do
        SEV="${REC_SEV[i]}"
        COLOR=$(severity_color "$SEV")
        # Pad plain text first, then wrap in color, so ANSI codes never affect alignment
        printf "  %s%-${W_SEV}s%s  %-${W_SCOPE}s  %-${W_TARGET}s  %-${W_CHECK}s  %-${W_VALUE}s  %-${W_THRESH}s  %s\n" \
            "$COLOR" "$SEV" "$RESET_COLOR" "${REC_SCOPE[i]}" "${REC_TARGET[i]}" "${REC_CHECK[i]}" \
            "${REC_VALUE[i]}" "${REC_THRESHOLD[i]}" "${REC_HINT[i]}"
    done
    echo

    printf 'Summary: '
    for SEV in "${SEVERITIES[@]}"; do
        printf '%s %d %s   ' "$(severity_icon "$SEV")" "${SEV_COUNT[$SEV]}" "$SEV"
    done
    printf '→ %b%s%b (exit %d)\n' "$(severity_color "$VERDICT")" "$VERDICT" "$RESET_COLOR" "$EXIT_CODE"
}

render_csv() {
    local i
    echo "severity,scope,target,check_id,value,unit,threshold,evidence,hint,ref"
    for i in "${!REC_SEV[@]}"; do
        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$(csv_escape "${REC_SEV[i]}")" "$(csv_escape "${REC_SCOPE[i]}")" \
            "$(csv_escape "${REC_TARGET[i]}")" "$(csv_escape "${REC_CHECK[i]}")" \
            "$(csv_escape "${REC_VALUE[i]}")" "$(csv_escape "${REC_UNIT[i]}")" \
            "$(csv_escape "${REC_THRESHOLD[i]}")" \
            "$(csv_escape "${REC_EVIDENCE[i]}")" "$(csv_escape "${REC_HINT[i]}")" \
            "$(csv_escape "${REC_REF[i]}")"
    done
}

render_json() {
    local i SEP ASIC IDX PSEP TOOL
    printf '{\n'
    printf '  "schema_version": %d,\n' "$JSON_SCHEMA_VERSION"
    printf '  "tool": "%s",\n' "$SCRIPT_NAME"
    printf '  "version": "%s",\n' "$SCRIPT_VERSION"
    printf '  "host": "%s",\n' "$(json_escape "$HOSTNAME")"
    printf '  "collected_at": "%s",\n' "$COLLECTED_AT"
    printf '  "level": "basic",\n'

    printf '  "capabilities": {'
    SEP=""
    for TOOL in "${TOOL_NAMES[@]}"; do
        printf '%s"%s": %s' "$SEP" "$TOOL" "$([[ -n "${TOOL_PATH[$TOOL]}" ]] && echo true || echo false)"
        SEP=", "
    done
    printf '},\n'

    printf '  "summary": {'
    SEP=""
    for SEV in "${SEVERITIES[@]}"; do
        printf '%s"%s": %d' "$SEP" "$SEV" "${SEV_COUNT[$SEV]}"
        SEP=", "
    done
    printf '},\n'
    printf '  "verdict": "%s",\n' "$VERDICT"
    printf '  "exit_code": %d,\n' "$EXIT_CODE"

    printf '  "asics": ['
    SEP=""
    for ASIC in "${ASIC_IDS[@]}"; do
        printf '%s\n    {\n' "$SEP"
        printf '      "id": "%s",\n' "$ASIC"
        printf '      "model": "%s",\n' "$(json_escape "${ASIC_MODEL[$ASIC]}")"
        printf '      "driver": "%s",\n' "$(json_escape "${ASIC_DRIVER[$ASIC]}")"
        printf '      "firmware": "%s",\n' "$(json_escape "${ASIC_FW[$ASIC]}")"
        printf '      "ports": ['
        PSEP=""
        for IDX in ${ASIC_PORTS[$ASIC]}; do
            printf '%s{"iface": "%s", "pci": "%s", "operstate": "%s", "virtual_function": %s}' "$PSEP" \
                "$(json_escape "${PORT_IFACE[IDX]}")" "${PORT_BDF[IDX]}" \
                "$(json_escape "${PORT_OPER[IDX]}")" "${PORT_VF[IDX]}"
            PSEP=", "
        done
        printf ']\n    }'
        SEP=","
    done
    [[ -n "$SEP" ]] && printf '\n  '
    printf '],\n'

    printf '  "results": ['
    SEP=""
    for i in "${!REC_SEV[@]}"; do
        printf '%s\n    {' "$SEP"
        printf '"severity": "%s", ' "${REC_SEV[i]}"
        printf '"scope": "%s", ' "${REC_SCOPE[i]}"
        printf '"target": "%s", ' "$(json_escape "${REC_TARGET[i]}")"
        printf '"check_id": "%s", ' "${REC_CHECK[i]}"
        printf '"value": "%s", ' "$(json_escape "${REC_VALUE[i]}")"
        printf '"unit": "%s", ' "$(json_escape "${REC_UNIT[i]}")"
        printf '"threshold": "%s", ' "$(json_escape "${REC_THRESHOLD[i]}")"
        printf '"evidence": "%s", ' "$(json_escape "${REC_EVIDENCE[i]}")"
        printf '"hint": "%s", ' "$(json_escape "${REC_HINT[i]}")"
        printf '"ref": "%s"}' "$(json_escape "${REC_REF[i]}")"
        SEP=","
    done
    [[ -n "$SEP" ]] && printf '\n  '
    printf ']\n}\n'
}

# --- Main ---
TZ=UTC0 printf -v COLLECTED_AT '%(%Y-%m-%dT%H:%M:%SZ)T' -1

discover

if (( ${#ASIC_IDS[@]} == 0 )); then
    add_record "host" "$HOSTNAME" "discovery.pci" "0" "NICs" ">=1" "$SEV_UNKNOWN" \
        "no physical PCI network interface found" "Nothing to evaluate; check -i/--interface or that NIC drivers are loaded" "$DESIGN_REF §4.3"
fi

run_checks
compute_verdict

case "$OUTPUT_FORMAT" in
    table) render_table ;;
    csv)   render_csv ;;
    json)  render_json ;;
esac

exit "$EXIT_CODE"
