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
#   - Optional: lspci (NIC vendor/model names), devlink (health reporters)
#
# Change Log:
#   - 2026-10-20: Phase 1 skeleton: sysfs discovery with per-ASIC grouping,
#                 result records, Nagios exit codes, table/JSON/CSV output,
#                 --check-tools, generic PCIe link check
#   - 2026-10-20: Phase 2: counter delta engine (-I/--interval, reset
#                 detection, monotonic time), generic checks for PCIe AER,
#                 temperature (hwmon), devlink health reporters, link flaps.
#                 Script is now sourceable for unit tests (tests/)
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
PROC_UPTIME="/proc/uptime"

# Sampling window (seconds); 0 = absolute totals since boot/driver load
DEFAULT_INTERVAL=5
MAX_INTERVAL=3600
PROGRESS_WIDTH=30

# Temperature: WARN this many degrees C below the critical threshold
TEMP_WARN_MARGIN_C=10

# read(2) error text (LC_ALL=C) for a sensor the firmware lists but has no reading for
# (e.g. sfc MC_CMD_SENSOR_STATE_NO_READING); treated as N/A, other read errors as UNKNOWN
READ_EBUSY_MSG="Device or resource busy"

# PCIe AER sysfs files and their total-counter keys
AER_KINDS=("cor" "nonfatal" "fatal")
declare -A AER_FILE=([cor]="aer_dev_correctable" [nonfatal]="aer_dev_nonfatal" [fatal]="aer_dev_fatal")
declare -A AER_TOTAL=([cor]="TOTAL_ERR_COR" [nonfatal]="TOTAL_ERR_NONFATAL" [fatal]="TOTAL_ERR_FATAL")

# devlink health reporter state considered healthy
DEVLINK_HEALTHY="healthy"

# Tool catalog for --check-tools and JSON capabilities (parallel arrays)
REQUIRED_CMDS=("ethtool" "getopt" "readlink")
TOOL_NAMES=("ethtool" "getopt" "readlink" "lspci" "devlink" "mlxlink" "mstlink")
TOOL_ROLES=("required" "required" "required" "optional" "optional" "optional" "optional")
TOOL_USES=(
    "Driver and firmware identification"
    "Command-line parsing"
    "sysfs path resolution"
    "NIC vendor/model names (falls back to PCI IDs)"
    "devlink health reporter checks"
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
INTERVAL="$DEFAULT_INTERVAL"
IFACE_FILTER=()

# --- Data ---
declare -A TOOL_PATH=()
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
declare -A BDF_ASIC=()
declare -A IFACE_PORT=()
# Counter snapshots (T0 before the window, T1 after) and devlink metadata
declare -A SNAP0=()
declare -A SNAP1=()
declare -A DL_PORT_NETDEV=()
DL_ORDER=()
# Error from 'devlink port show' (port reporters cannot be mapped to netdevs)
DL_PORT_ERROR=""
# false when /proc/uptime could not be read for either snapshot
CLOCK_OK=true
# Reporter order from the T0 snapshot; only passed by name, never read
# shellcheck disable=SC2034
DL_SCRATCH=()
ELAPSED_CS=0
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
declare -A SEV_COUNT=()

# --- Helpers ---

usage() {
    echo -e "Usage: $SCRIPT_NAME [-i|--interface IFACE]... [-I|--interval SEC] [-O|--output table|csv|json]"
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
    echo -e " -I, --interval SEC     Counter sampling window in seconds (default: $DEFAULT_INTERVAL, max: $MAX_INTERVAL)"
    echo -e "                        Counters are read twice; only growth inside the window is judged."
    echo -e "                        0 = single read of totals since boot/driver load (historical;"
    echo -e "                        severity capped at WARN)"
    echo -e " -O, --output TYPE      Output format: table (default), csv, or json"
    echo -e " -n, --no-color         Disable color output (auto-disabled for non-terminal)"
    echo -e " -t, --check-tools      List required/optional tools, what each enables, and exit"
    echo -e "                        (does not require root)"
    echo -e " -v, --version          Display version information"
    echo -e " -h, --help             Display this help message"
    echo -e ""
    echo -e "Checks:"
    echo -e " generic.pcie.link      PCIe link trained below the card's capability (WARN)"
    echo -e " generic.pcie.aer       New PCIe AER errors: fatal/nonfatal (CRIT), correctable (WARN)"
    echo -e " generic.temperature    hwmon sensor within ${TEMP_WARN_MARGIN_C}C of critical or above max (WARN),"
    echo -e "                        at/over critical (CRIT)"
    echo -e " generic.devlink.health Reporter not healthy (CRIT), new errors in window (WARN)"
    echo -e " generic.link.flaps     Carrier transitions in window (WARN)"
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

# Read a sysfs attribute; prints nothing and fails if unreadable
read_attr() {
    local FILE="$1"
    [[ -r "$FILE" ]] || return 1
    local VAL
    VAL=$(<"$FILE") 2>/dev/null || return 1
    printf '%s' "$VAL"
}

# Monotonic time in centiseconds (CLOCK_BOOTTIME via /proc/uptime)
uptime_cs() {
    local UP REST
    read -r UP REST < "$PROC_UPTIME" || return 1
    if [[ "$UP" =~ ^([0-9]+)\.([0-9]{2}) ]]; then
        printf '%d' $(( BASH_REMATCH[1] * 100 + 10#${BASH_REMATCH[2]} ))
    elif [[ "$UP" =~ ^([0-9]+)$ ]]; then
        printf '%d' $(( BASH_REMATCH[1] * 100 ))
    else
        return 1
    fi
}

# Convert a PCIe speed string ("16.0 GT/s PCIe", "8 GT/s") to tenths of GT/s
# Prints nothing for unknown/unparseable values
pcie_speed_tenths() {
    local RAW="${1%% GT/s*}"
    if [[ "$RAW" =~ ^([0-9]+)(\.([0-9]))?$ ]]; then
        printf '%d' $(( BASH_REMATCH[1] * 10 + ${BASH_REMATCH[3]:-0} ))
    fi
}

# Format millidegrees C as an integer degree string
milli_to_c() {
    printf '%d' $(( $1 / 1000 ))
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

# In absolute mode (no window) totals are historical: never escalate past WARN
historical_cap() {
    if (( INTERVAL == 0 )) && [[ "$1" == "$SEV_CRIT" ]]; then
        printf '%s' "$SEV_WARN"
    else
        printf '%s' "$1"
    fi
}

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

# --- Setup ---

parse_args() {
    local OPTIONS
    if [[ -z "${TOOL_PATH[getopt]:-$(command -v getopt 2>/dev/null || true)}" ]]; then
        die_unknown "Required command 'getopt' is not installed or not in PATH."
    fi

    if ! OPTIONS=$(getopt -o hvi:I:O:nt --long help,version,interface:,interval:,output:,no-color,check-tools -n "$SCRIPT_NAME" -- "$@"); then
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
            -I|--interval)
                if [[ ! "$2" =~ ^[0-9]+$ ]] || (( 10#$2 > MAX_INTERVAL )); then
                    die_unknown "Invalid --interval value '$2' (expected 0-$MAX_INTERVAL seconds)." usage
                fi
                INTERVAL=$(( 10#$2 ))
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
}

setup_colors() {
    # Auto-disable colors for non-terminal output
    [[ ! -t 1 ]] && USE_COLOR=false

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
}

detect_tools() {
    local TOOL
    for TOOL in "${TOOL_NAMES[@]}"; do
        TOOL_PATH["$TOOL"]=$(command -v "$TOOL" 2>/dev/null || true)
    done
}

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

preflight() {
    local CMD
    if [[ $EUID -ne 0 ]]; then
        die_unknown "This script must be run as root. Please use sudo or switch to root."
    fi
    for CMD in "${REQUIRED_CMDS[@]}"; do
        [[ -n "${TOOL_PATH[$CMD]}" ]] || die_unknown "Required command '$CMD' is not installed or not in PATH. Run '$SCRIPT_NAME --check-tools'."
    done
}

# --- Discovery ---

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
    VENDOR=$(read_attr "$SYSFS_PCI/$BDF/vendor") || VENDOR=""
    DEVICE=$(read_attr "$SYSFS_PCI/$BDF/device") || DEVICE=""
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
    local ASIC IDX DRV FW
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
        PORT_OPER+=("$(read_attr "$SYSFS_NET/$IFACE/operstate" || true)")
        if [[ -e "$SYSFS_NET/$IFACE/device/physfn" ]]; then PORT_VF+=(true); else PORT_VF+=(false); fi
        BDF_ASIC["$BDF"]="$ASIC"
        IFACE_PORT["$IFACE"]="$IDX"

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

# Print the distinct PCI functions (BDFs) of an ASIC, in port order
asic_functions() {
    local -A LISTED=()
    local IDX BDF
    for IDX in ${ASIC_PORTS[$1]}; do
        BDF="${PORT_BDF[IDX]}"
        [[ -n "${LISTED[$BDF]:-}" ]] && continue
        LISTED["$BDF"]=1
        printf '%s\n' "$BDF"
    done
}

# --- Counter collection ---

# Parse "devlink health show" text into ARR[dl|HANDLE|REPORTER|{state,error,recover}]
# and append each new "HANDLE|REPORTER" to the ORDER array.
# Handles both "reporter NAME" (current) and "name NAME" (older iproute2) layouts.
# Args: assoc-array-name order-array-name (input on stdin)
parse_devlink_health() {
    local -n _DL="$1" _ORDER="$2"
    local LINE HANDLE="" REP="" i
    local -a T
    while IFS= read -r LINE; do
        if [[ "$LINE" =~ ^([^[:space:]].*):$ ]]; then
            HANDLE="${BASH_REMATCH[1]}"
            REP=""
            continue
        fi
        read -ra T <<< "$LINE"
        for (( i = 0; i < ${#T[@]}; i++ )); do
            case "${T[i]}" in
                reporter|name)
                    REP="${T[i+1]:-}"
                    if [[ -n "$HANDLE" && -n "$REP" && -z "${_DL["dl|$HANDLE|$REP|seen"]:-}" ]]; then
                        _DL["dl|$HANDLE|$REP|seen"]=1
                        _ORDER+=("$HANDLE|$REP")
                    fi
                    (( i += 1 ))
                    ;;
                state|error|recover)
                    [[ -n "$HANDLE" && -n "$REP" ]] && _DL["dl|$HANDLE|$REP|${T[i]}"]="${T[i+1]:-}"
                    (( i += 1 ))
                    ;;
            esac
        done
    done
}

# Parse "devlink port show" text into DL_PORT_NETDEV[port-handle]=netdev
parse_devlink_ports() {
    local LINE
    while IFS= read -r LINE; do
        if [[ "$LINE" =~ ^([^[:space:]]+):\ .*netdev\ ([^[:space:]]+) ]]; then
            DL_PORT_NETDEV["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
        fi
    done
}

# Take one snapshot of all cumulative counters into the named associative array
# Args: snapshot-array-name order-array-name
snapshot() {
    local -n _S="$1"
    local ORDER_NAME="$2"
    local ASIC BDF KIND FILE CONTENT IFACE IDX OUT
    local -a FUNCS
    _S=()
    _S["time"]=$(uptime_cs || true)

    for ASIC in "${ASIC_IDS[@]}"; do
        mapfile -t FUNCS < <(asic_functions "$ASIC")
        # Per PCI function, so a reset on one function cannot hide behind growth on another
        for BDF in "${FUNCS[@]}"; do
            for KIND in "${AER_KINDS[@]}"; do
                FILE="$SYSFS_PCI/$BDF/${AER_FILE[$KIND]}"
                [[ -e "$FILE" ]] || continue
                if CONTENT=$(read_attr "$FILE") && [[ "$CONTENT" =~ ${AER_TOTAL[$KIND]}\ ([0-9]+) ]]; then
                    _S["aer|$BDF|$KIND"]="${BASH_REMATCH[1]}"
                else
                    _S["aer|$BDF|$KIND"]="?"
                fi
            done
        done
    done

    for IDX in "${!PORT_IFACE[@]}"; do
        IFACE="${PORT_IFACE[IDX]}"
        FILE="$SYSFS_NET/$IFACE/carrier_changes"
        [[ -e "$FILE" ]] || continue
        _S["carrier|$IFACE"]=$(read_attr "$FILE" || printf '?')
    done

    if [[ -n "${TOOL_PATH[devlink]}" ]]; then
        if OUT=$(LC_ALL=C devlink health show 2>&1); then
            parse_devlink_health "$1" "$ORDER_NAME" <<< "$OUT"
        else
            _S["dl_error"]="${OUT//$'\n'/ }"
        fi
    fi
}

# Sleep for the sampling window, with a progress bar for table output on a TTY
sample_wait() {
    local s FILLED BAR PAD
    if [[ "$OUTPUT_FORMAT" == "table" && -t 2 ]]; then
        for (( s = 1; s <= INTERVAL; s++ )); do
            sleep 1
            FILLED=$(( s * PROGRESS_WIDTH / INTERVAL ))
            printf -v BAR '%*s' "$FILLED" ''
            printf -v PAD '%*s' $(( PROGRESS_WIDTH - FILLED )) ''
            printf '\r📊 Sampling counters: [%s%s] %d/%ds' "${BAR// /#}" "${PAD// /.}" "$s" "$INTERVAL" >&2
        done
        printf '\r%*s\r' 60 '' >&2
    else
        sleep "$INTERVAL"
    fi
}

# Set DELTA to SNAP1[key] - SNAP0[key]
# Returns 1 if either value is missing or non-numeric, 2 on a counter reset (T1 < T0)
delta() {
    local A="${SNAP0[$1]:-}" B="${SNAP1[$1]:-}"
    [[ "$A" =~ ^[0-9]+$ && "$B" =~ ^[0-9]+$ ]] || return 1
    (( B < A )) && return 2
    DELTA=$(( B - A ))
    return 0
}

# True when a counter existed at T0 but is gone at T1 (source vanished during the window)
vanished() {
    (( INTERVAL > 0 )) && [[ -n "${SNAP0[$1]+x}" && -z "${SNAP1[$1]+x}" ]]
}

# Elapsed window as "S.CC" seconds, or "?" when the monotonic clock was unreadable
elapsed_str() {
    if $CLOCK_OK; then
        printf '%d.%02d' $(( ELAPSED_CS / 100 )) $(( ELAPSED_CS % 100 ))
    else
        printf '?'
    fi
}

# --- Checks ---

# generic.pcie.link: compare trained PCIe link speed/width with the device maximum
check_pcie_link() {
    local ASIC="$1"
    local BDF="${ASIC_BDF[$ASIC]}"
    local DIR="$SYSFS_PCI/$BDF"
    local CHECK="generic.pcie.link" UNIT="" REF="$DESIGN_REF §6.1"
    local CUR_S MAX_S CUR_W MAX_W CUR_T MAX_T

    if [[ ! -e "$DIR/current_link_speed" && ! -e "$DIR/max_link_speed" ]]; then
        add_record "asic" "$ASIC" "$CHECK" "-" "$UNIT" "-" "$SEV_NA" \
            "no PCIe link attributes in sysfs" "No PCIe link to train: virtual function or chipset-integrated NIC" "$REF"
        return
    fi

    CUR_S=$(read_attr "$DIR/current_link_speed") || CUR_S=""
    MAX_S=$(read_attr "$DIR/max_link_speed") || MAX_S=""
    CUR_W=$(read_attr "$DIR/current_link_width") || CUR_W=""
    MAX_W=$(read_attr "$DIR/max_link_width") || MAX_W=""
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

# generic.pcie.aer: PCIe Advanced Error Reporting totals, summed over the ASIC's functions
check_pcie_aer() {
    local ASIC="$1"
    local CHECK="generic.pcie.aer" REF="$DESIGN_REF §6.1"
    local KIND KEY BDF RC PRESENT=false
    local -A TOT=() D=()
    local -a FUNCS

    mapfile -t FUNCS < <(asic_functions "$ASIC")
    for BDF in "${FUNCS[@]}"; do
        for KIND in "${AER_KINDS[@]}"; do
            KEY="aer|$BDF|$KIND"
            if vanished "$KEY"; then
                add_record "asic" "$ASIC" "$CHECK" "-" "" "-" "$SEV_UNKNOWN" \
                    "$BDF ${AER_FILE[$KIND]} disappeared during window" "Device removed or driver reloaded; re-run" "$REF"
                return
            fi
            [[ -n "${SNAP1[$KEY]+x}" ]] || continue
            PRESENT=true
            if [[ ! "${SNAP1[$KEY]}" =~ ^[0-9]+$ ]]; then
                add_record "asic" "$ASIC" "$CHECK" "-" "" "-" "$SEV_UNKNOWN" \
                    "$BDF ${AER_FILE[$KIND]} unreadable or without ${AER_TOTAL[$KIND]}" "AER counters exist but could not be read" "$REF"
                return
            fi
            TOT[$KIND]=$(( ${TOT[$KIND]:-0} + SNAP1[$KEY] ))
            if (( INTERVAL > 0 )); then
                RC=0; delta "$KEY" || RC=$?
                if (( RC == 2 )); then
                    add_record "asic" "$ASIC" "$CHECK" "-" "" "-" "$SEV_UNKNOWN" \
                        "$BDF ${AER_TOTAL[$KIND]} decreased during window (T0=${SNAP0[$KEY]} T1=${SNAP1[$KEY]})" "Counter reset (device reset or driver reload?); re-run" "$REF"
                    return
                elif (( RC != 0 )); then
                    add_record "asic" "$ASIC" "$CHECK" "-" "" "-" "$SEV_UNKNOWN" \
                        "$BDF ${AER_TOTAL[$KIND]} missing from first snapshot" "Counter appeared during the window; re-run" "$REF"
                    return
                fi
                D[$KIND]=$(( ${D[$KIND]:-0} + DELTA ))
            fi
        done
    done

    if ! $PRESENT; then
        add_record "asic" "$ASIC" "$CHECK" "-" "" "-" "$SEV_NA" \
            "no aer_dev_* attributes in sysfs" "Kernel does not report AER for this device (CONFIG_PCIEAER off or no AER capability)" "$REF"
        return
    fi

    local TOTALS="cor=${TOT[cor]:-0} nonfatal=${TOT[nonfatal]:-0} fatal=${TOT[fatal]:-0}"
    local THRESH="fatal/nonfatal>0 CRIT, cor>0 WARN" SEV HINT="" VALUE UNIT
    if (( INTERVAL > 0 )); then
        VALUE="cor=+${D[cor]:-0} nonfatal=+${D[nonfatal]:-0} fatal=+${D[fatal]:-0}"
        UNIT="errors/window"
        if (( ${D[fatal]:-0} > 0 || ${D[nonfatal]:-0} > 0 )); then
            SEV="$SEV_CRIT"; HINT="Uncorrectable PCIe errors during the window: check slot, riser, card seating; review kernel log for AER details"
        elif (( ${D[cor]:-0} > 0 )); then
            SEV="$SEV_WARN"; HINT="Correctable PCIe errors are recurring: signal integrity of slot or riser; reseat card"
        else
            SEV="$SEV_OK"
            [[ "$TOTALS" != "cor=0 nonfatal=0 fatal=0" ]] && HINT="No new errors; historical totals since boot: $TOTALS"
        fi
    else
        VALUE="$TOTALS"
        UNIT="errors/boot"
        if (( ${TOT[fatal]:-0} > 0 || ${TOT[nonfatal]:-0} > 0 )); then
            SEV=$(historical_cap "$SEV_CRIT"); HINT="Historical uncorrectable PCIe errors since boot; re-run with -I to see if they recur"
        elif (( ${TOT[cor]:-0} > 0 )); then
            SEV="$SEV_WARN"; HINT="Historical correctable PCIe errors since boot; re-run with -I to see if they recur"
        else
            SEV="$SEV_OK"
        fi
    fi
    add_record "asic" "$ASIC" "$CHECK" "$VALUE" "$UNIT" "$THRESH" "$SEV" "totals since boot: $TOTALS" "$HINT" "$REF"
}

# generic.temperature: hwmon sensors of the ASIC (deduplicated by label across functions)
check_temperature() {
    local ASIC="$1"
    local CHECK="generic.temperature" REF="$DESIGN_REF §6.1"
    local BDF HW INPUT_F BASE LABEL IN CRIT MAX HIGH ALARM WARN_AT SEV HINT THRESH EVIDENCE TARGET ERRMSG FOUND=false
    local -A SEEN=()
    local -a FUNCS

    mapfile -t FUNCS < <(asic_functions "$ASIC")
    for BDF in "${FUNCS[@]}"; do
        for HW in "$SYSFS_PCI/$BDF"/hwmon/hwmon*; do
            [[ -d "$HW" ]] || continue
            for INPUT_F in "$HW"/temp*_input; do
                [[ -e "$INPUT_F" ]] || continue
                BASE="${INPUT_F%_input}"
                LABEL=$(read_attr "${BASE}_label") || LABEL="${BASE##*/}"
                [[ -n "${SEEN[$LABEL]:-}" ]] && continue
                SEEN["$LABEL"]=1
                FOUND=true
                TARGET="$ASIC ($LABEL)"

                IN=$(read_attr "$INPUT_F") || IN=""
                CRIT=$(read_attr "${BASE}_crit") || CRIT=""
                MAX=$(read_attr "${BASE}_max") || MAX=""
                HIGH=$(read_attr "${BASE}_highest") || HIGH=""
                ALARM=$(read_attr "${BASE}_alarm") || ALARM=""
                EVIDENCE="label=$LABEL input=${IN:-?} crit=${CRIT:--} max=${MAX:--} highest=${HIGH:--} alarm=${ALARM:--} (millidegrees C)"

                if [[ ! "$IN" =~ ^-?[0-9]+$ ]]; then
                    # $(<file) hides read errors; the read builtin reports them
                    ERRMSG=$( { LC_ALL=C; read -r _ < "$INPUT_F"; } 2>&1 ) || true
                    if [[ "$ERRMSG" == *"$READ_EBUSY_MSG"* ]]; then
                        add_record "asic" "$TARGET" "$CHECK" "-" "C" "-" "$SEV_NA" "$EVIDENCE; read: $READ_EBUSY_MSG" \
                            "Sensor listed by firmware but reports no reading (EBUSY), e.g. not fitted on this board" "$REF"
                    else
                        add_record "asic" "$TARGET" "$CHECK" "-" "C" "-" "$SEV_UNKNOWN" "$EVIDENCE; read: ${ERRMSG:-empty value}" "Sensor present but unreadable" "$REF"
                    fi
                    continue
                fi
                [[ "$CRIT" =~ ^-?[0-9]+$ ]] || CRIT=""
                [[ "$MAX" =~ ^-?[0-9]+$ ]] || MAX=""

                # WARN point: margin below critical, or max when the driver sets it below critical.
                # Some drivers report max above crit (e.g. ixgbe); such a max is ignored.
                WARN_AT=""
                [[ -n "$CRIT" ]] && WARN_AT=$(( CRIT - TEMP_WARN_MARGIN_C * 1000 ))
                if [[ -n "$MAX" ]] && { [[ -z "$CRIT" ]] || (( MAX < CRIT )); }; then
                    [[ -z "$WARN_AT" ]] || (( MAX < WARN_AT )) && WARN_AT="$MAX"
                fi

                HINT=""
                if [[ -z "$WARN_AT" ]]; then
                    THRESH="alarm=1 WARN"
                    if [[ "$ALARM" == "1" ]]; then
                        SEV="$SEV_WARN"; HINT="Driver raised a temperature alarm for this sensor"
                    else
                        SEV="$SEV_NA"; THRESH="-"; HINT="Driver exposes no max/crit threshold for this sensor"
                    fi
                else
                    THRESH="warn>=$(milli_to_c "$WARN_AT")${CRIT:+ crit>=$(milli_to_c "$CRIT")}"
                    if [[ -n "$CRIT" ]] && (( IN >= CRIT )); then
                        SEV="$SEV_CRIT"; HINT="At or above critical temperature: check airflow, fan speed, transceiver load; risk of thermal shutdown"
                    elif (( IN >= WARN_AT )); then
                        SEV="$SEV_WARN"; HINT="Approaching critical temperature: check airflow and fan speed"
                    elif [[ "$ALARM" == "1" ]]; then
                        SEV="$SEV_WARN"; HINT="Driver raised a temperature alarm for this sensor"
                    else
                        SEV="$SEV_OK"
                    fi
                fi
                [[ "$HIGH" =~ ^[0-9]+$ && -z "$HINT" ]] && HINT="Peak since driver load: $(milli_to_c "$HIGH")C"
                add_record "asic" "$TARGET" "$CHECK" "$(milli_to_c "$IN")" "C" "$THRESH" "$SEV" "$EVIDENCE" "$HINT" "$REF"
            done
        done
    done

    if ! $FOUND; then
        add_record "asic" "$ASIC" "$CHECK" "-" "C" "-" "$SEV_NA" \
            "no hwmon temp*_input under the ASIC's PCI functions" "Driver exposes no temperature sensor" "$REF"
    fi
}

# generic.link.flaps: carrier transitions (each flap is a down+up pair)
check_link_flaps() {
    local IDX="$1"
    local IFACE="${PORT_IFACE[IDX]}" KEY="carrier|${PORT_IFACE[IDX]}"
    local CHECK="generic.link.flaps" REF="$DESIGN_REF §6.1" RC

    if vanished "$KEY"; then
        add_record "port" "$IFACE" "$CHECK" "-" "" "-" "$SEV_UNKNOWN" "carrier_changes disappeared during window" \
            "Interface removed or renamed during the window; re-run" "$REF"
        return
    fi
    if [[ -z "${SNAP1[$KEY]+x}" ]]; then
        add_record "port" "$IFACE" "$CHECK" "-" "" "-" "$SEV_NA" "no carrier_changes attribute" "" "$REF"
        return
    fi
    if (( INTERVAL == 0 )); then
        if [[ "${SNAP1[$KEY]}" =~ ^[0-9]+$ ]]; then
            add_record "port" "$IFACE" "$CHECK" "${SNAP1[$KEY]}" "transitions/driver-load" "informational" "$SEV_OK" \
                "carrier_changes=${SNAP1[$KEY]}" "Historical total, informational only; re-run with -I to detect active flapping" "$REF"
        else
            add_record "port" "$IFACE" "$CHECK" "-" "" "-" "$SEV_UNKNOWN" "carrier_changes unreadable" "" "$REF"
        fi
        return
    fi

    RC=0; delta "$KEY" || RC=$?
    if (( RC == 2 )); then
        add_record "port" "$IFACE" "$CHECK" "-" "" "-" "$SEV_UNKNOWN" \
            "carrier_changes decreased (T0=${SNAP0[$KEY]} T1=${SNAP1[$KEY]})" "Counter reset (interface re-created or driver reload?); re-run" "$REF"
    elif (( RC != 0 )); then
        add_record "port" "$IFACE" "$CHECK" "-" "" "-" "$SEV_UNKNOWN" "carrier_changes unreadable" "" "$REF"
    elif (( DELTA > 0 )); then
        add_record "port" "$IFACE" "$CHECK" "+$DELTA" "transitions/window" ">0 WARN" "$SEV_WARN" \
            "carrier_changes T0=${SNAP0[$KEY]} T1=${SNAP1[$KEY]}" "Link is flapping: check cable/transceiver, peer port, and autonegotiation/FEC settings" "$REF"
    else
        add_record "port" "$IFACE" "$CHECK" "+0" "transitions/window" ">0 WARN" "$SEV_OK" \
            "carrier_changes=${SNAP1[$KEY]} (since driver load)" "" "$REF"
    fi
}

# generic.devlink.health: device-level (pci/BDF) and port-level reporters
check_devlink() {
    local CHECK="generic.devlink.health" REF="$DESIGN_REF §6.1"
    local KEY HANDLE REP SCOPE TARGET ASIC STATE ERR RCV SEV HINT VALUE UNIT EVIDENCE NETDEV RC_E RC_R D_ERR D_RCV
    local UNMAPPED=0
    local -A ASIC_HAS=() DONE_DL=()

    if [[ -z "${TOOL_PATH[devlink]}" ]]; then
        for ASIC in "${ASIC_IDS[@]}"; do
            add_record "asic" "$ASIC" "$CHECK" "-" "" "-" "$SEV_NA" "devlink not installed" \
                "Install the devlink tool (package: iproute2) to enable this check" "$REF"
        done
        return
    fi
    if [[ -n "${SNAP1[dl_error]:-}" ]]; then
        for ASIC in "${ASIC_IDS[@]}"; do
            add_record "asic" "$ASIC" "$CHECK" "-" "" "-" "$SEV_UNKNOWN" "devlink health show failed: ${SNAP1[dl_error]}" "" "$REF"
        done
        return
    fi

    # Reporters seen at T0 but gone at T1 (driver reload/device removal), then all T1 reporters
    for KEY in "${DL_SCRATCH[@]}" "${DL_ORDER[@]}"; do
        HANDLE="${KEY%|*}"
        REP="${KEY##*|}"
        if [[ "$HANDLE" =~ ^pci/([0-9a-fA-F:.]+)$ ]]; then
            [[ -n "${BDF_ASIC[${BASH_REMATCH[1]}]:-}" ]] || continue
            SCOPE="asic"; TARGET="${BASH_REMATCH[1]}"; ASIC="${BDF_ASIC[$TARGET]}"
        else
            NETDEV="${DL_PORT_NETDEV[$HANDLE]:-}"
            if [[ -z "$NETDEV" ]]; then
                [[ -n "$DL_PORT_ERROR" ]] && (( ++UNMAPPED ))
                continue
            fi
            [[ -n "${IFACE_PORT[$NETDEV]:-}" ]] || continue
            SCOPE="port"; TARGET="$NETDEV"; ASIC="${PORT_ASIC[${IFACE_PORT[$NETDEV]}]}"
        fi
        ASIC_HAS["$ASIC"]=1

        if [[ -z "${SNAP1["dl|$KEY|seen"]:-}" ]]; then
            # Only reachable from the T0 list
            add_record "$SCOPE" "$TARGET" "$CHECK.$REP" "-" "" "-" "$SEV_UNKNOWN" \
                "$HANDLE reporter $REP present at T0, gone at T1" "Driver reloaded or device removed during the window; re-run" "$REF"
            continue
        fi
        # T1 reporters were already evaluated if also listed at T0
        [[ -n "${DONE_DL[$KEY]:-}" ]] && continue
        DONE_DL["$KEY"]=1

        STATE="${SNAP1["dl|$KEY|state"]:-}"
        ERR="${SNAP1["dl|$KEY|error"]:-}"
        RCV="${SNAP1["dl|$KEY|recover"]:-}"
        EVIDENCE="$HANDLE reporter $REP: state=${STATE:-?} error=${ERR:-?} recover=${RCV:-?}"
        HINT=""

        if [[ -z "$STATE" || ! "$ERR" =~ ^[0-9]+$ ]]; then
            add_record "$SCOPE" "$TARGET" "$CHECK.$REP" "-" "" "-" "$SEV_UNKNOWN" "$EVIDENCE" "Unparseable devlink reporter output" "$REF"
            continue
        fi

        D_ERR=0
        D_RCV=0
        if (( INTERVAL > 0 )); then
            RC_E=0; delta "dl|$KEY|error" || RC_E=$?
            (( RC_E == 0 )) && D_ERR=$DELTA
            RC_R=0; delta "dl|$KEY|recover" || RC_R=$?
            (( RC_R == 0 )) && D_RCV=$DELTA
            if (( RC_E == 2 || RC_R == 2 )); then
                add_record "$SCOPE" "$TARGET" "$CHECK.$REP" "-" "" "-" "$SEV_UNKNOWN" "$EVIDENCE (counters decreased)" "Counter reset (driver reload?); re-run" "$REF"
                continue
            elif (( RC_E != 0 )); then
                add_record "$SCOPE" "$TARGET" "$CHECK.$REP" "-" "" "-" "$SEV_UNKNOWN" "$EVIDENCE (missing from first snapshot)" "Reporter appeared during the window; re-run" "$REF"
                continue
            fi
            (( RC_R != 0 )) && D_RCV=0
            VALUE="state=$STATE error=+$D_ERR recover=+$D_RCV"
            UNIT="events/window"
        else
            VALUE="state=$STATE error=$ERR recover=${RCV:-?}"
            UNIT="events/driver-load"
        fi

        if [[ "$STATE" != "$DEVLINK_HEALTHY" ]]; then
            SEV="$SEV_CRIT"; HINT="Reporter in '$STATE' state: inspect with 'devlink health diagnose $HANDLE reporter $REP' and the kernel log"
        elif (( INTERVAL > 0 && D_ERR > 0 )); then
            SEV="$SEV_WARN"; HINT="Reporter recorded errors during the window (auto-recovered if recover grew): check kernel log"
        elif (( INTERVAL == 0 && ERR > 0 )); then
            SEV="$SEV_WARN"; HINT="Historical reporter errors since driver load; re-run with -I to see if they recur"
        else
            SEV="$SEV_OK"
            (( ERR > 0 )) && HINT="No new errors; $ERR historical error(s) since driver load"
        fi
        add_record "$SCOPE" "$TARGET" "$CHECK.$REP" "$VALUE" "$UNIT" "state!=$DEVLINK_HEALTHY CRIT, error>0 WARN" "$SEV" "$EVIDENCE" "$HINT" "$REF"
    done

    if (( UNMAPPED > 0 )); then
        add_record "host" "$HOSTNAME" "$CHECK" "$UNMAPPED" "reporters" "0" "$SEV_UNKNOWN" \
            "devlink port show failed: $DL_PORT_ERROR" "Port-level reporters could not be mapped to interfaces; their state is unknown" "$REF"
    fi
    for ASIC in "${ASIC_IDS[@]}"; do
        [[ -n "${ASIC_HAS[$ASIC]:-}" ]] && continue
        if [[ -n "$DL_PORT_ERROR" ]]; then
            add_record "asic" "$ASIC" "$CHECK" "-" "" "-" "$SEV_UNKNOWN" "no device-level reporters; devlink port show failed" \
                "Port-level reporters may exist but could not be mapped" "$REF"
        else
            add_record "asic" "$ASIC" "$CHECK" "-" "" "-" "$SEV_NA" "no devlink health reporters for this ASIC" \
                "Driver exposes no devlink health reporters (driver or kernel too old, or not implemented)" "$REF"
        fi
    done
}

run_checks() {
    local ASIC IDX
    for ASIC in "${ASIC_IDS[@]}"; do
        check_pcie_link "$ASIC"
        check_pcie_aer "$ASIC"
        check_temperature "$ASIC"
    done
    for IDX in "${!PORT_IFACE[@]}"; do
        check_link_flaps "$IDX"
    done
    check_devlink
}

# --- Verdict ---

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

# Value with its unit, as shown in the table
display_value() {
    local i="$1"
    if [[ -n "${REC_UNIT[i]}" && "${REC_VALUE[i]}" != "-" ]]; then
        printf '%s %s' "${REC_VALUE[i]}" "${REC_UNIT[i]}"
    else
        printf '%s' "${REC_VALUE[i]}"
    fi
}

render_table() {
    local ASIC IDX i SEV COLOR MODE
    if (( INTERVAL > 0 )); then
        MODE="window $(elapsed_str)s"
    else
        MODE="absolute (totals since boot/driver load)"
    fi
    printf '%b🩺 %s %s%b  host %s  %s  %s\n\n' "$BOLD" "$SCRIPT_NAME" "$SCRIPT_VERSION" "$RESET_COLOR" "$HOSTNAME" "$COLLECTED_AT" "$MODE"

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
    local -a SHOWN=()
    local W_SEV=${#HEAD[0]} W_SCOPE=${#HEAD[1]} W_TARGET=${#HEAD[2]} W_CHECK=${#HEAD[3]} W_VALUE=${#HEAD[4]} W_THRESH=${#HEAD[5]}
    for i in "${!REC_SEV[@]}"; do
        SHOWN[i]=$(display_value "$i")
        (( ${#REC_SEV[i]} > W_SEV ))          && W_SEV=${#REC_SEV[i]}
        (( ${#REC_SCOPE[i]} > W_SCOPE ))      && W_SCOPE=${#REC_SCOPE[i]}
        (( ${#REC_TARGET[i]} > W_TARGET ))    && W_TARGET=${#REC_TARGET[i]}
        (( ${#REC_CHECK[i]} > W_CHECK ))      && W_CHECK=${#REC_CHECK[i]}
        (( ${#SHOWN[i]} > W_VALUE ))          && W_VALUE=${#SHOWN[i]}
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
            "${SHOWN[i]}" "${REC_THRESHOLD[i]}" "${REC_HINT[i]}"
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
    local i SEP ASIC IDX PSEP TOOL SEV
    printf '{\n'
    printf '  "schema_version": %d,\n' "$JSON_SCHEMA_VERSION"
    printf '  "tool": "%s",\n' "$SCRIPT_NAME"
    printf '  "version": "%s",\n' "$SCRIPT_VERSION"
    printf '  "host": "%s",\n' "$(json_escape "$HOSTNAME")"
    printf '  "collected_at": "%s",\n' "$COLLECTED_AT"
    printf '  "level": "basic",\n'
    if (( INTERVAL > 0 )); then
        printf '  "mode": "delta",\n'
        printf '  "interval_s": %d,\n' "$INTERVAL"
        if $CLOCK_OK; then
            printf '  "elapsed_s": %s,\n' "$(elapsed_str)"
        else
            printf '  "elapsed_s": null,\n'
        fi
    else
        printf '  "mode": "absolute",\n'
        printf '  "interval_s": 0,\n'
        printf '  "elapsed_s": 0,\n'
    fi

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
        printf '"check_id": "%s", ' "$(json_escape "${REC_CHECK[i]}")"
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

main() {
    local T0 T1 OUT
    parse_args "$@"
    setup_colors
    detect_tools

    if $CHECK_TOOLS; then
        check_tools_report
        exit $?
    fi

    preflight
    TZ=UTC0 printf -v COLLECTED_AT '%(%Y-%m-%dT%H:%M:%SZ)T' -1

    discover

    if (( ${#ASIC_IDS[@]} == 0 )); then
        add_record "host" "$HOSTNAME" "discovery.pci" "0" "NICs" ">=1" "$SEV_UNKNOWN" \
            "no physical PCI network interface found" "Nothing to evaluate; check -i/--interface or that NIC drivers are loaded" "$DESIGN_REF §4.3"
    else
        if [[ -n "${TOOL_PATH[devlink]}" ]]; then
            if OUT=$(LC_ALL=C devlink port show 2>&1); then
                parse_devlink_ports <<< "$OUT"
            else
                DL_PORT_ERROR="${OUT//$'\n'/ }"
            fi
        fi
        if (( INTERVAL > 0 )); then
            snapshot SNAP0 DL_SCRATCH
            sample_wait
        fi
        snapshot SNAP1 DL_ORDER
        T0="${SNAP0[time]:-}"
        T1="${SNAP1[time]:-}"
        if (( INTERVAL > 0 )); then
            if [[ "$T0" =~ ^[0-9]+$ && "$T1" =~ ^[0-9]+$ ]]; then
                ELAPSED_CS=$(( T1 - T0 ))
            else
                CLOCK_OK=false
                add_record "host" "$HOSTNAME" "sampling.clock" "-" "" "-" "$SEV_UNKNOWN" \
                    "$PROC_UPTIME unreadable or malformed" "Window length unknown; counter growth is still evaluated" "$DESIGN_REF §5"
            fi
        fi
        run_checks
    fi

    compute_verdict

    case "$OUTPUT_FORMAT" in
        table) render_table ;;
        csv)   render_csv ;;
        json)  render_json ;;
    esac

    exit "$EXIT_CODE"
}

# Run only when executed, not when sourced (unit tests source this file)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
