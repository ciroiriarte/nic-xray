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
#   - 2026-10-20: Phase 3: mlx5_core ethtool -S rule table (design §6.2)
#   - 2026-10-20: Table lists only WARN/CRIT/UNKNOWN rows unless -a/--all
#   - 2026-10-20: Phase 5: -l/--level deep with allowlisted mlxlink/mstlink queries (design §7)
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

# Drop functions inherited from the environment (exported BASH_FUNC_*): as root they would
# shadow the commands below regardless of PATH. Only inherited ones exist at this point
while read -r _ _ INHERITED_FN; do
    unset -f "$INHERITED_FN"
done < <(declare -F)
unset INHERITED_FN

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

# --- mlx5_core (NVIDIA ConnectX) ethtool -S rules (design §6.2) ---
# Each rule: check id, counters as NAME:SEV, and a hint. SEV is CRIT or WARN (growth escalates)
# or INFO (shown as context, never escalates). NAME may contain one [d-d] digit range, which is
# expanded once into the exact-name lookup used while parsing ethtool -S.
MLX5_DRIVER="mlx5_core"
SEV_INFO="INFO"
MLX5_RULE_ID=(
    "mlx5.rx.starvation"
    "mlx5.nic.discards"
    "mlx5.phy.errors"
    "mlx5.frame.errors"
    "mlx5.pcie.path"
    "mlx5.datapath.faults"
    "mlx5.congestion"
    "mlx5.pause.storm"
    "mlx5.module"
    "mlx5.link.phy_down"
)
MLX5_RULE_COUNTERS=(
    "rx_out_of_buffer:WARN rx_buff_alloc_err:WARN"
    "rx_discards_phy:WARN tx_discards_phy:WARN"
    "rx_symbol_err_phy:CRIT rx_pcs_symbol_err_phy:CRIT rx_corrected_bits_phy:INFO rx_err_lane_[0-9]_phy:INFO rx_bits_phy:INFO"
    "rx_crc_errors_phy:WARN rx_fragments_phy:WARN rx_jabbers_phy:WARN rx_undersize_pkts_phy:WARN rx_oversize_pkts_phy:WARN"
    "rx_pci_signal_integrity:WARN tx_pci_signal_integrity:WARN outbound_pci_stalled_rd_events:WARN outbound_pci_stalled_wr_events:WARN"
    "tx_cqe_err:CRIT rx_wqe_err:CRIT tx_recover:CRIT rx_recover:CRIT"
    "rx_prio[0-7]_buf_discard:WARN rx_prio[0-7]_cong_discard:WARN rx_pause_ctrl_phy:INFO tx_pause_ctrl_phy:INFO rx_global_pause:INFO tx_global_pause:INFO rx_buffer_passed_thres_phy:INFO"
    "tx_pause_storm_warning_events:WARN tx_pause_storm_error_events:CRIT"
    "module_bus_stuck:CRIT module_bad_shorted:CRIT module_high_temp:WARN module_unplug:WARN"
    "link_down_events_phy:WARN"
)
MLX5_RULE_HINT=(
    "Host cannot drain RX rings: raise ring size (ethtool -G IFACE rx <max>), check IRQ affinity and CPU load"
    "NIC buffer exhausted: usually PCIe or host backpressure; correlate with mlx5.pcie.path and CPU load"
    "Uncorrectable symbol errors: traffic is being lost; clean/replace the optic or cable, check peer port and FEC mode"
    "Frame errors: CRC/fragments/jabbers point to cabling or optics; oversize frames to an MTU mismatch with the peer"
    "PCIe recovery or outbound stalls: check slot, riser, BIOS PCIe settings and host root-complex load"
    "Driver/firmware datapath fault (CQE/WQE error or queue recovery): check kernel log, update driver and firmware"
    "Congestion evidence, not a NIC fault: CPU, PCIe, application load or PFC/pause configuration"
    "Pause storm: the NIC stopped sending pause frames because the host stopped draining a queue; check for a stuck host or driver"
    "Transceiver module fault: reseat or replace the module; high_temp means airflow or module overheating"
    "Physical link went down: check cable/transceiver, peer port, and autonegotiation/FEC settings"
)
# Gauges (instantaneous %, never deltaed): reported as context in the PCIe path rule
MLX5_GAUGES=("outbound_pci_stalled_rd" "outbound_pci_stalled_wr" "outbound_pci_buffer_overflow")
MLX5_GAUGE_RULE="mlx5.pcie.path"
# Pre-FEC BER: needs rx_bits_phy (absent on ConnectX-6 Lx). WARN when BER > 10^-MLX5_PRE_FEC_BER_WARN_EXP
MLX5_BER_RULE="mlx5.phy.errors"
MLX5_BITS_COUNTER="rx_bits_phy"
MLX5_CORRECTED_COUNTER="rx_corrected_bits_phy"
MLX5_LANE_COUNTER_GLOB="rx_err_lane_[0-9]_phy"
MLX5_PRE_FEC_BER_WARN_EXP=6
# Big-counter arithmetic: digits that always fit a signed 64-bit integer, and its base
BIG_DIGITS=18
BIG_BASE=1000000000000000000
BIG_MAX_HI=8
# Largest denominator fmt_sci handles without overflow (larger ones are scaled down)
SCI_MAX_DEN=90000000000000000
# Link speed (Mb/s) from which running without FEC is called out when PHY errors grow
FEC_EXPECTED_MIN_SPEED=25000
FEC_OFF_MODES=("Off" "None")
# Lane skew hint: one lane carries at least this % of corrected bits (and at least the minimum)
LANE_DOMINANCE_PCT=90
LANE_MIN_ERRORS=100

# --- Deep mode (-l deep, design §7): allowlisted vendor tool queries ---
LEVEL_BASIC="basic"
LEVEL_DEEP="deep"
# Preference order: NVIDIA MFT, then open-source mstflint (same output format)
DEEP_TOOLS=("mlxlink" "mstlink")
DEEP_TIMEOUT=10
# Seconds after the SIGTERM at timeout before SIGKILL
DEEP_KILL_AFTER=2
# Exit status of timeout(1) when the command timed out, and when it had to be killed
DEEP_TIMEOUT_RC=124
DEEP_KILLED_RC=137
DEEP_BDF_SLOT="{BDF}"
# The only argv ever passed to a deep tool: module info plus physical counters/BER (query only)
DEEP_ARGS_TEMPLATE=("-d" "$DEEP_BDF_SLOT" "-m" "-c")
# Never passed, even if the template changes: eye scan, PRBS, port/FEC/speed set, counter clear,
# error injection, register/cable access, data collection (unit-tested)
DEEP_FORBIDDEN_ARGS=("-e" "--show_eye" "-a" "--port_state" "--fec" "--fec_speed" "--speeds" "--link_mode_force"
    "--prbs" "--test_mode" "--pprt" "--pptt" "--pc" "--clear" "--loopback" "--margin" "--pcie_error_injection"
    "--amber_collect" "--rx_fec_histogram" "--cable" "--write" "--read" "--dump" "--ddm")
BDF_RE='^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$'
# Effective (post-FEC) BER above 10^-EXP is WARN; it is an average since the last counter clear,
# so it never escalates to CRIT (live growth is judged by mlx5.phy.errors)
DEEP_EFFECTIVE_BER_WARN_EXP=12
# BER at or below 10^-EXP is shown as ~0 (mstlink prints e.g. 15E-255 for no errors)
DEEP_BER_ZERO_EXP=30
# Exponent reported for a literal zero BER (e.g. 0E0)
BER_ZERO_EXPONENT=-999
# Module values printed as "VALUE [LOW..HIGH]"; outside the range is WARN
DEEP_RANGE_KEYS=("Temperature [C]" "Voltage [mV]" "Bias Current [mA]" "Rx Power Current [dBm]" "Tx Power Current [dBm]")
# Module per-lane fault flags; any non-zero lane is WARN
DEEP_FLAG_KEYS=("Tx Fault [per lane]" "Rx LOS [per lane]" "Tx CDR LOL [per lane]" "Rx CDR LOL [per lane]")
DEEP_NO_FEC="No FEC"
DEEP_MODULE_FEC_RE='[Ww]ith FEC'

# PCIe AER sysfs files and their total-counter keys
AER_KINDS=("cor" "nonfatal" "fatal")
declare -A AER_FILE=([cor]="aer_dev_correctable" [nonfatal]="aer_dev_nonfatal" [fatal]="aer_dev_fatal")
declare -A AER_TOTAL=([cor]="TOTAL_ERR_COR" [nonfatal]="TOTAL_ERR_NONFATAL" [fatal]="TOTAL_ERR_FATAL")

# devlink health reporter state considered healthy
DEVLINK_HEALTHY="healthy"

# Tool catalog for --check-tools and JSON capabilities (parallel arrays)
REQUIRED_CMDS=("ethtool" "getopt" "readlink")
TOOL_NAMES=("ethtool" "getopt" "readlink" "lspci" "devlink" "timeout" "mlxlink" "mstlink")
TOOL_ROLES=("required" "required" "required" "optional" "optional" "optional" "optional" "optional")
TOOL_USES=(
    "Driver/firmware identification, mlx5 counters (ethtool -S)"
    "Command-line parsing"
    "sysfs path resolution"
    "NIC vendor/model names (falls back to PCI IDs)"
    "devlink health reporter checks"
    "Bounds deep-mode tool runs (required for -l deep)"
    "mlx5 deep mode (-l deep) via NVIDIA MFT (preferred)"
    "mlx5 deep mode (-l deep) via open-source mstflint"
)
TOOL_PACKAGES=(
    "ethtool"
    "util-linux"
    "coreutils"
    "pciutils"
    "iproute2 (iproute on RHEL)"
    "coreutils"
    "NVIDIA MFT (proprietary, install manually)"
    "mstflint"
)

# --- Defaults ---
OUTPUT_FORMAT="table"
USE_COLOR=true
CHECK_TOOLS=false
SHOW_ALL=false
LEVEL="$LEVEL_BASIC"
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
# Deep mode results: DEEP_KV[IFACE|Key]=value, DEEP_ERR[IFACE]=failure, DEEP_TOOL_USED[IFACE]=tool
declare -A DEEP_KV=()
declare -A DEEP_ERR=()
declare -A DEEP_TOOL_USED=()
DEEP_ARGV=()
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

# Exact names of every ethtool -S counter the mlx5 rules need (rule counters, gauges, BER
# denominator). A lookup table, not a regex: mlx5 prints thousands of per-channel lines per port
declare -A MLX5_WANTED=()
build_mlx5_wanted() {
    local SPEC ITEM NAME d
    local -a NAMES=("${MLX5_GAUGES[@]}" "$MLX5_BITS_COUNTER")
    for SPEC in "${MLX5_RULE_COUNTERS[@]}"; do
        for ITEM in $SPEC; do NAMES+=("${ITEM%:*}"); done
    done
    for NAME in "${NAMES[@]}"; do
        if [[ "$NAME" =~ ^(.*)\[([0-9])-([0-9])\](.*)$ ]]; then
            for (( d = BASH_REMATCH[2]; d <= BASH_REMATCH[3]; d++ )); do
                MLX5_WANTED["${BASH_REMATCH[1]}$d${BASH_REMATCH[4]}"]=1
            done
        else
            MLX5_WANTED["$NAME"]=1
        fi
    done
}
build_mlx5_wanted

# --- Helpers ---

usage() {
    echo -e "Usage: $SCRIPT_NAME [-i|--interface IFACE]... [-I|--interval SEC] [-O|--output table|csv|json]"
    echo -e "       [-l|--level basic|deep] [-a|--all] [-n|--no-color] [-t|--check-tools] [-v|--version] [-h|--help]"
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
    echo -e " -l, --level LEVEL      basic (default): passive sysfs/ethtool/devlink reads only"
    echo -e "                        deep: also query mlx5 ports with mlxlink or mstlink (-d BDF -m -c only,"
    echo -e "                        ${DEEP_TIMEOUT}s timeout each); never eye scans, PRBS, resets, writes or flashing"
    echo -e " -a, --all              Table: also list OK and N/A rows (default: only WARN, CRIT, UNKNOWN;\n                        CSV and JSON always contain every row)"
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
    echo -e " mlx5.*                 ConnectX (mlx5_core) ethtool -S counters: RX starvation, NIC discards,"
    echo -e "                        PHY symbol errors / pre-FEC BER, frame errors, PCIe path, datapath faults,"
    echo -e "                        congestion, pause storms, module faults, PHY link-down events"
    echo -e " mlx5.deep.*            -l deep: tool troubleshooting code, module/link FEC mismatch,"
    echo -e "                        effective BER since last clear, module ranges and lane fault flags"
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
    if [[ -z "${TOOL_PATH[getopt]:-$(type -P getopt || true)}" ]]; then
        die_unknown "Required command 'getopt' is not installed or not in PATH."
    fi

    if ! OPTIONS=$(getopt -o hvi:I:O:l:ant --long help,version,interface:,interval:,output:,level:,all,no-color,check-tools -n "$SCRIPT_NAME" -- "$@"); then
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
            -l|--level)
                [[ "$2" == "$LEVEL_BASIC" || "$2" == "$LEVEL_DEEP" ]] \
                    || die_unknown "Invalid --level value '$2' (expected $LEVEL_BASIC or $LEVEL_DEEP)." usage
                LEVEL="$2"
                shift 2
                ;;
            -a|--all)
                SHOW_ALL=true
                shift
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
        # type -P: executable files only (never functions, aliases or builtins), absolute path
        TOOL_PATH["$TOOL"]=$(type -P "$TOOL" || true)
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
    if [[ "$LEVEL" == "$LEVEL_DEEP" && -z "${TOOL_PATH[timeout]}" ]]; then
        die_unknown "--level $LEVEL_DEEP requires 'timeout' (coreutils) to bound vendor tool runs."
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

    for IDX in "${!PORT_IFACE[@]}"; do
        mlx5_port_eligible "$IDX" && mlx5_snapshot "$1" "${PORT_IFACE[IDX]}"
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
# Counters are unsigned 64-bit (up to 20 digits) but bash integers are signed 64-bit:
# values beyond 18 digits are split into a high part and the low 18 digits
delta() {
    local A="${SNAP0[$1]:-}" B="${SNAP1[$1]:-}"
    [[ "$A" =~ ^[0-9]+$ && "$B" =~ ^[0-9]+$ ]] || return 1
    A="${A#"${A%%[!0]*}"}"; A="${A:-0}"
    B="${B#"${B%%[!0]*}"}"; B="${B:-0}"
    if (( ${#A} <= BIG_DIGITS && ${#B} <= BIG_DIGITS )); then
        (( B < A )) && return 2
        DELTA=$(( B - A ))
        return 0
    fi
    # Order by length, then lexically (equal length, no leading zeros)
    if (( ${#B} < ${#A} )) || { (( ${#B} == ${#A} )) && [[ "$B" < "$A" ]]; }; then
        return 2
    fi
    local AH=0 AL="$A" BH=0 BL="$B"
    if (( ${#A} > BIG_DIGITS )); then AH="${A:0:${#A}-BIG_DIGITS}"; AL="${A: -BIG_DIGITS}"; fi
    if (( ${#B} > BIG_DIGITS )); then BH="${B:0:${#B}-BIG_DIGITS}"; BL="${B: -BIG_DIGITS}"; fi
    local HI=$(( 10#$BH - 10#$AH ))
    # HI*10^18 plus the low part must stay below 2^63
    (( HI <= BIG_MAX_HI )) || return 1
    DELTA=$(( HI * BIG_BASE + 10#$BL - 10#$AL ))
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

# --- Vendor: mlx5_core ---

# mlx5 rules apply to physical functions bound to mlx5_core (VFs have no _phy counters)
mlx5_port_eligible() {
    [[ "${PORT_DRIVER[$1]}" == "$MLX5_DRIVER" ]] && ! ${PORT_VF[$1]}
}

# Store the wanted ethtool -S counters of IFACE into the snapshot as ets|IFACE|NAME,
# the kept names as ets_names|IFACE, or the failure as ets_err|IFACE
# Args: snapshot-array-name iface
mlx5_snapshot() {
    local -n _M="$1"
    local IFACE="$2" OUT LINE NAME VAL KEPT=""
    if ! OUT=$(LC_ALL=C ethtool -S "$IFACE" 2>&1); then
        _M["ets_err|$IFACE"]="${OUT//$'\n'/ }"
        return 0
    fi
    local -a LINES
    mapfile -t LINES <<< "$OUT"
    # Lines are "     name: value"; parameter expansion only, no per-line regex or subshell
    for LINE in "${LINES[@]}"; do
        LINE="${LINE#"${LINE%%[![:space:]]*}"}"
        NAME="${LINE%%:*}"
        [[ -n "${MLX5_WANTED[$NAME]:-}" ]] || continue
        # First occurrence wins if a driver ever prints a name twice
        [[ -n "${_M["ets|$IFACE|$NAME"]+x}" ]] && continue
        VAL="${LINE#*:}"
        VAL="${VAL//[[:space:]]/}"
        _M["ets|$IFACE|$NAME"]="$VAL"
        KEPT+="$NAME "
    done
    _M["ets_names|$IFACE"]="${KEPT% }"
}

# Format NUM/DEN in scientific notation with one decimal (e.g. 3.2e-07); NUM <= DEN
fmt_sci() {
    local N="$1" D="$2" E=0 M
    # Keep N*10 and N*100 inside signed 64-bit range (precision loss only affects display)
    while (( D > SCI_MAX_DEN )); do N=$(( N / 10 )); D=$(( D / 10 )); done
    if (( N == 0 )); then printf '0'; return; fi
    while (( N < D )); do N=$(( N * 10 )); E=$(( E + 1 )); done
    M=$(( N * 10 / D ))
    printf '%d.%de-%02d' $(( M / 10 )) $(( M % 10 )) "$E"
}

# Evaluate one mlx5 rule for a port
# Args: port-index rule-index
check_mlx5_rule() {
    local IDX="$1" R="$2"
    local IFACE="${PORT_IFACE[$1]}"
    local CHECK="${MLX5_RULE_ID[R]}" HINT_TXT="${MLX5_RULE_HINT[R]}" REF="$DESIGN_REF §6.2"
    local ITEM GLOB CSEV NAME KEY RC SEV="$SEV_OK" HINT="" UNIT
    local VALUE_PARTS="" CONTEXT="" EVIDENCE="" MATCHED=0 THRESH SHOWN
    # Set by mlx5_ber_eval through dynamic scoping
    local LANE_HINT="" BER_VALUE=""
    local -a NAMES1 NAMES0
    read -ra NAMES1 <<< "${SNAP1["ets_names|$IFACE"]:-}"
    read -ra NAMES0 <<< "${SNAP0["ets_names|$IFACE"]:-}"
    # Candidate names in ethtool order: T1 names, then names only seen at T0 (vanished)
    local -A IN1=()
    local -a CAND=("${NAMES1[@]}")
    for NAME in "${NAMES1[@]}"; do IN1["$NAME"]=1; done
    for NAME in "${NAMES0[@]}"; do [[ -n "${IN1[$NAME]:-}" ]] || CAND+=("$NAME"); done

    for ITEM in ${MLX5_RULE_COUNTERS[R]}; do
        GLOB="${ITEM%:*}"
        CSEV="${ITEM##*:}"
        for NAME in "${CAND[@]}"; do
            # shellcheck disable=SC2053  # GLOB is intentionally a pattern
            [[ "$NAME" == $GLOB ]] || continue
            KEY="ets|$IFACE|$NAME"
            (( ++MATCHED ))
            if vanished "$KEY"; then
                add_record "port" "$IFACE" "$CHECK" "-" "" "-" "$SEV_UNKNOWN" "$NAME present at T0, gone at T1" \
                    "Driver reloaded or interface re-created during the window; re-run" "$REF"
                return
            fi
            if [[ ! "${SNAP1[$KEY]:-}" =~ ^[0-9]+$ ]]; then
                add_record "port" "$IFACE" "$CHECK" "-" "" "-" "$SEV_UNKNOWN" "$NAME=${SNAP1[$KEY]:-?} (not a counter)" \
                    "Unparseable ethtool -S value" "$REF"
                return
            fi
            if (( INTERVAL > 0 )); then
                RC=0; delta "$KEY" || RC=$?
                if (( RC == 2 )); then
                    add_record "port" "$IFACE" "$CHECK" "-" "" "-" "$SEV_UNKNOWN" \
                        "$NAME decreased (T0=${SNAP0[$KEY]} T1=${SNAP1[$KEY]})" "Counter reset (driver reload or ethtool -S reset?); re-run" "$REF"
                    return
                elif (( RC != 0 )); then
                    add_record "port" "$IFACE" "$CHECK" "-" "" "-" "$SEV_UNKNOWN" "$NAME missing from first snapshot" \
                        "Counter appeared during the window; re-run" "$REF"
                    return
                fi
            else
                DELTA="${SNAP1[$KEY]}"
            fi
            # String tests: 20-digit counters would wrap in arithmetic
            if [[ "${SNAP1[$KEY]}" =~ [1-9] && "$NAME" != "$MLX5_BITS_COUNTER" ]]; then
                EVIDENCE+="$NAME=${SNAP1[$KEY]}"
                (( INTERVAL > 0 )) && EVIDENCE+=" (+$DELTA)"
                EVIDENCE+=" "
            fi
            [[ "$DELTA" =~ [1-9] ]] || continue
            # The BER denominator is only lifecycle-checked here; it is not an event
            [[ "$NAME" == "$MLX5_BITS_COUNTER" ]] && continue
            # Growth is signed (+N); absolute totals are not
            SHOWN="$DELTA"
            (( INTERVAL > 0 )) && SHOWN="+$DELTA"
            if [[ "$CSEV" == "$SEV_INFO" ]]; then
                CONTEXT+="$NAME $SHOWN, "
                continue
            fi
            VALUE_PARTS+="$NAME=$SHOWN "
            if [[ "$CSEV" == "$SEV_CRIT" ]]; then
                SEV="$SEV_CRIT"
            elif [[ "$SEV" != "$SEV_CRIT" ]]; then
                SEV="$SEV_WARN"
            fi
        done
    done

    if (( MATCHED == 0 )); then
        add_record "port" "$IFACE" "$CHECK" "-" "" "-" "$SEV_NA" "none of: ${MLX5_RULE_COUNTERS[R]}" \
            "Counters not exposed by this ConnectX model or firmware" "$REF"
        return
    fi

    [[ -z "$EVIDENCE" ]] && EVIDENCE="all $MATCHED counters are 0 "
    EVIDENCE="${EVIDENCE% }"
    [[ "$CHECK" == "$MLX5_GAUGE_RULE" ]] && EVIDENCE+="$(mlx5_gauge_context "$IFACE")"
    [[ "$CHECK" == "$MLX5_BER_RULE" ]] && mlx5_ber_eval "$IFACE"

    if (( INTERVAL > 0 )); then
        UNIT="per window"
    else
        UNIT="since driver load"
        SEV=$(historical_cap "$SEV")
    fi
    if [[ "$SEV" != "$SEV_OK" ]]; then
        HINT="$HINT_TXT"
        [[ "$CHECK" == "$MLX5_BER_RULE" ]] && HINT="$(fec_off_hint "$IFACE")$HINT"
        (( INTERVAL == 0 )) && HINT="Historical totals, re-run with -I to see if they grow. $HINT"
    elif [[ -n "$CONTEXT" ]]; then
        HINT="Context only: ${CONTEXT%, }"
    fi
    [[ -n "${LANE_HINT:-}" ]] && HINT="${HINT:+$HINT. }$LANE_HINT"
    VALUE_PARTS="${VALUE_PARTS% }"
    [[ -n "${BER_VALUE:-}" ]] && VALUE_PARTS="${VALUE_PARTS:+$VALUE_PARTS }$BER_VALUE"
    THRESH=">0 $(mlx5_rule_severities "$R")"
    [[ "$CHECK" == "$MLX5_BER_RULE" ]] && THRESH+=", pre-FEC BER>1e-$(printf '%02d' "$MLX5_PRE_FEC_BER_WARN_EXP") $SEV_WARN"
    if [[ -z "$VALUE_PARTS" ]]; then
        VALUE_PARTS="0"
        (( INTERVAL > 0 )) && VALUE_PARTS="+0"
    fi
    add_record "port" "$IFACE" "$CHECK" "$VALUE_PARTS" "$UNIT" "$THRESH" "$SEV" "$EVIDENCE" "$HINT" "$REF"
}

# Distinct escalating severities of a rule: CRIT, WARN, or CRIT/WARN
mlx5_rule_severities() {
    local SPEC="${MLX5_RULE_COUNTERS[$1]}" OUT=""
    [[ " $SPEC" == *":$SEV_CRIT"* ]] && OUT="$SEV_CRIT"
    [[ " $SPEC" == *":$SEV_WARN"* ]] && OUT="${OUT:+$OUT/}$SEV_WARN"
    printf '%s' "$OUT"
}

# Hint prefix when PHY errors grow on a fast link running without FEC (read only on a finding)
fec_off_hint() {
    local IFACE="$1" SPEED OUT MODE OFF
    SPEED=$(read_attr "$SYSFS_NET/$IFACE/speed") || SPEED=""
    [[ "$SPEED" =~ ^[0-9]+$ ]] || return 0
    (( SPEED >= FEC_EXPECTED_MIN_SPEED )) || return 0
    OUT=$(LC_ALL=C ethtool --show-fec "$IFACE" 2>/dev/null) || return 0
    [[ "$OUT" =~ Active\ FEC\ encoding:[[:space:]]*([^$'\n']*) ]] || return 0
    MODE="${BASH_REMATCH[1]%"${BASH_REMATCH[1]##*[![:space:]]}"}"
    for OFF in "${FEC_OFF_MODES[@]}"; do
        if [[ "$MODE" == "$OFF" ]]; then
            printf 'Active FEC is %s at %d Mb/s: links at 25G and above normally rely on RS-FEC to correct routine bit errors; check that FEC matches on both ends. ' "$MODE" "$SPEED"
            return 0
        fi
    done
}

# Instantaneous PCIe stall gauges at T1, as evidence text
mlx5_gauge_context() {
    local G OUT=""
    for G in "${MLX5_GAUGES[@]}"; do
        [[ -n "${SNAP1["ets|$1|$G"]+x}" ]] && OUT+="; $G=${SNAP1["ets|$1|$G"]}% (gauge)"
    done
    printf '%s' "$OUT"
}

# Pre-FEC BER and lane skew for the PHY rule. Sets BER_VALUE, LANE_HINT and may raise SEV to WARN
# (uses the caller's SEV and EVIDENCE through dynamic scoping)
mlx5_ber_eval() {
    local IFACE="$1" CORR BITS NAME TOTAL=0 MAX=0 MAX_LANE="" LANES=0 RC
    local BKEY="ets|$IFACE|$MLX5_BITS_COUNTER" CKEY="ets|$IFACE|$MLX5_CORRECTED_COUNTER"
    (( INTERVAL > 0 )) || return 0

    if [[ -z "${SNAP1[$BKEY]+x}" ]]; then
        EVIDENCE+="; $MLX5_BITS_COUNTER not exposed: pre-FEC BER not computed (deep mode mlxlink reports it)"
    else
        RC=0; delta "$CKEY" || RC=$?; (( RC == 0 )) && CORR=$DELTA || CORR=""
        RC=0; delta "$BKEY" || RC=$?; (( RC == 0 )) && BITS=$DELTA || BITS=""
        if [[ -n "$CORR" && -n "$BITS" ]] && (( BITS > 0 )); then
            BER_VALUE="pre-FEC BER=$(fmt_sci "$CORR" "$BITS")"
            # CORR/BITS > 10^-EXP without multiplying large counters
            if (( CORR > 0 && CORR > BITS / 10 ** MLX5_PRE_FEC_BER_WARN_EXP )) && [[ "$SEV" == "$SEV_OK" ]]; then
                SEV="$SEV_WARN"
            fi
        fi
    fi

    for NAME in "${!SNAP1[@]}"; do
        # shellcheck disable=SC2053
        [[ "$NAME" == "ets|$IFACE|"$MLX5_LANE_COUNTER_GLOB ]] || continue
        RC=0; delta "$NAME" || RC=$?
        (( RC == 0 )) || continue
        (( ++LANES ))
        TOTAL=$(( TOTAL + DELTA ))
        if (( DELTA > MAX )); then MAX=$DELTA; MAX_LANE="${NAME##*|}"; fi
    done
    # Divide first: TOTAL*PCT could overflow; the precision loss is irrelevant for a hint
    # shellcheck disable=SC2017
    if (( LANES > 1 && TOTAL >= LANE_MIN_ERRORS && MAX >= TOTAL / 100 * LANE_DOMINANCE_PCT )); then
        LANE_HINT="Corrected bits concentrated on $MAX_LANE: suspect that lane/fiber of the optic or cable"
    fi
}

check_mlx5_port() {
    local IDX="$1" R IFACE="${PORT_IFACE[$1]}"
    local ERR="${SNAP1["ets_err|$IFACE"]:-${SNAP0["ets_err|$IFACE"]:-}}"
    if [[ -n "$ERR" ]]; then
        add_record "port" "$IFACE" "mlx5.ethtool" "-" "" "-" "$SEV_UNKNOWN" "ethtool -S failed: $ERR" \
            "mlx5 counters unavailable for this port" "$DESIGN_REF §6.2"
        return
    fi
    for R in "${!MLX5_RULE_ID[@]}"; do
        check_mlx5_rule "$IDX" "$R"
    done
}

# --- Deep mode (design §7) ---

# Build the deep-tool argv for one PCI function into DEEP_ARGV
deep_build_argv() {
    local ARG
    DEEP_ARGV=()
    for ARG in "${DEEP_ARGS_TEMPLATE[@]}"; do
        if [[ "$ARG" == "$DEEP_BDF_SLOT" ]]; then DEEP_ARGV+=("$1"); else DEEP_ARGV+=("$ARG"); fi
    done
}

# Allowlist gate: tool must be a deep tool and argv must match the template exactly,
# with a well-formed BDF in the slot and no forbidden flag anywhere
# Args: tool arg...
deep_argv_allowed() {
    local TOOL="$1" T OK=false i ARG F
    shift
    for T in "${DEEP_TOOLS[@]}"; do [[ "$TOOL" == "$T" ]] && OK=true; done
    $OK || return 1
    (( $# == ${#DEEP_ARGS_TEMPLATE[@]} )) || return 1
    local -a ARGS=("$@")
    for i in "${!ARGS[@]}"; do
        ARG="${ARGS[i]}"
        for F in "${DEEP_FORBIDDEN_ARGS[@]}"; do [[ "$ARG" == "$F" ]] && return 1; done
        if [[ "${DEEP_ARGS_TEMPLATE[i]}" == "$DEEP_BDF_SLOT" ]]; then
            [[ "$ARG" =~ $BDF_RE ]] || return 1
        else
            [[ "$ARG" == "${DEEP_ARGS_TEMPLATE[i]}" ]] || return 1
        fi
    done
    return 0
}

# First available deep tool, or nothing
deep_tool() {
    local T
    for T in "${DEEP_TOOLS[@]}"; do
        if [[ -n "${TOOL_PATH[$T]:-}" ]]; then printf '%s' "$T"; return 0; fi
    done
}

# Remove ANSI color sequences (mstlink colors its output even when not on a terminal)
strip_ansi() {
    local OUT="$1" ESC=$'\e'
    local RE="${ESC}\\[[0-9;]*m"
    while [[ "$OUT" =~ $RE ]]; do OUT="${OUT//"${BASH_REMATCH[0]}"/}"; done
    printf '%s' "$OUT"
}

# Run the deep query for one port and store "Key : Value" lines as DEEP_KV[IFACE|Key],
# or the failure as DEEP_ERR[IFACE]
# Args: tool iface bdf
deep_query() {
    local TOOL="$1" IFACE="$2" BDF="$3" OUT RC=0 LINE KEY VAL
    deep_build_argv "$BDF"
    if ! deep_argv_allowed "$TOOL" "${DEEP_ARGV[@]}"; then
        DEEP_ERR["$IFACE"]="refused by allowlist: $TOOL ${DEEP_ARGV[*]}"
        return 0
    fi
    # Absolute paths from detect_tools; -k: SIGKILL if the tool ignores SIGTERM
    OUT=$(LC_ALL=C "${TOOL_PATH[timeout]}" -k "$DEEP_KILL_AFTER" "$DEEP_TIMEOUT" "${TOOL_PATH[$TOOL]}" "${DEEP_ARGV[@]}" 2>&1) || RC=$?
    OUT=$(strip_ansi "$OUT")
    if (( RC == DEEP_TIMEOUT_RC || RC == DEEP_KILLED_RC )); then
        DEEP_ERR["$IFACE"]="$TOOL timed out after ${DEEP_TIMEOUT}s"
        return 0
    elif (( RC != 0 )); then
        LINE="${OUT%%$'\n'*}"
        DEEP_ERR["$IFACE"]="$TOOL exit $RC: ${LINE:-no output}"
        return 0
    fi
    while IFS= read -r LINE; do
        [[ "$LINE" == *" : "* || "$LINE" == *": "* ]] || continue
        KEY="${LINE%%:*}"
        KEY="${KEY%"${KEY##*[![:space:]]}"}"
        VAL="${LINE#*:}"
        VAL="${VAL#"${VAL%%[![:space:]]*}"}"
        VAL="${VAL%"${VAL##*[![:space:]]}"}"
        [[ -n "$KEY" ]] && DEEP_KV["$IFACE|$KEY"]="$VAL"
    done <<< "$OUT"
    DEEP_TOOL_USED["$IFACE"]="$TOOL"
}

# Query every eligible mlx5 port, with a progress line for table output on a TTY
deep_collect() {
    local TOOL IDX N=0 DONE=0 BAR PAD FILLED
    local -a TARGETS=()
    TOOL=$(deep_tool)
    [[ -n "$TOOL" ]] || return 0
    for IDX in "${!PORT_IFACE[@]}"; do
        mlx5_port_eligible "$IDX" && TARGETS+=("$IDX")
    done
    N=${#TARGETS[@]}
    for IDX in "${TARGETS[@]}"; do
        deep_query "$TOOL" "${PORT_IFACE[IDX]}" "${PORT_BDF[IDX]}"
        DONE=$(( DONE + 1 ))
        if [[ "$OUTPUT_FORMAT" == "table" && -t 2 ]]; then
            FILLED=$(( DONE * PROGRESS_WIDTH / N ))
            printf -v BAR '%*s' "$FILLED" ''
            printf -v PAD '%*s' $(( PROGRESS_WIDTH - FILLED )) ''
            printf '\r🔬 Deep queries (%s): [%s%s] %d/%d' "$TOOL" "${BAR// /#}" "${PAD// /.}" "$DONE" "$N" >&2
        fi
    done
    if [[ "$OUTPUT_FORMAT" == "table" && -t 2 ]] && (( N > 0 )); then
        printf '\r%*s\r' 70 '' >&2
    fi
    return 0
}

# Convert a decimal string ("-0.079", "45", "3290.8") to thousandths; fails if not a number
to_milli() {
    [[ "$1" =~ ^(-?)([0-9]+)(\.([0-9]{1,3}))?[0-9]*$ ]] || return 1
    local FRAC="${BASH_REMATCH[4]}000"
    printf '%s%d' "${BASH_REMATCH[1]}" $(( 10#${BASH_REMATCH[2]} * 1000 + 10#${FRAC:0:3} ))
}

# Normalized base-10 exponent of a BER string like "5E-10", "1.2E-12", "15E-255":
# value = m * 10^k with 1 <= m < 10. Zero gives BER_ZERO_EXPONENT; unparseable fails
ber_exponent() {
    [[ "$1" =~ ^([0-9]+)(\.[0-9]+)?[eE]([-+]?)([0-9]+)$ ]] || return 1
    local INT="${BASH_REMATCH[1]}" SIGN=1 EXP=$(( 10#${BASH_REMATCH[4]} ))
    [[ "${BASH_REMATCH[3]}" == "-" ]] && SIGN=-1
    INT="${INT#"${INT%%[!0]*}"}"
    if [[ -z "$INT" ]]; then
        printf '%d' "$BER_ZERO_EXPONENT"
        return 0
    fi
    printf '%d' $(( SIGN * EXP + ${#INT} - 1 ))
}

# Display form of a BER: ~0 below the zero threshold, else as printed by the tool
ber_display() {
    local K
    K=$(ber_exponent "$1") || { printf '%s' "$1"; return 0; }
    if (( K <= -DEEP_BER_ZERO_EXP )); then printf '~0'; else printf '%s' "$1"; fi
}

check_deep_port() {
    local IDX="$1" IFACE="${PORT_IFACE[$1]}" REF="$DESIGN_REF §7"
    local SEV HINT VALUE EVIDENCE K KEY RAW LO HI V M_V M_LO M_HI FLAG
    local TOOL="${DEEP_TOOL_USED[$IFACE]:-}"

    if [[ -n "${DEEP_ERR[$IFACE]:-}" ]]; then
        add_record "port" "$IFACE" "mlx5.deep" "-" "" "-" "$SEV_UNKNOWN" "${DEEP_ERR[$IFACE]}" \
            "Deep query failed; basic checks are unaffected" "$REF"
        return 0
    fi

    # Troubleshooting code computed by the tool from link state and counters
    K="${DEEP_KV["$IFACE|Status Opcode"]:-}"
    if [[ -z "$K" ]]; then
        add_record "port" "$IFACE" "mlx5.deep.troubleshooting" "-" "" "-" "$SEV_NA" "$TOOL printed no Status Opcode" "" "$REF"
    elif [[ "$K" == "0" ]]; then
        add_record "port" "$IFACE" "mlx5.deep.troubleshooting" "opcode 0" "" "0" "$SEV_OK" \
            "$TOOL: ${DEEP_KV["$IFACE|Recommendation"]:-}" "" "$REF"
    else
        add_record "port" "$IFACE" "mlx5.deep.troubleshooting" "opcode $K" "" "0" "$SEV_WARN" \
            "$TOOL Status Opcode=$K Group Opcode=${DEEP_KV["$IFACE|Group Opcode"]:-?}" \
            "${DEEP_KV["$IFACE|Recommendation"]:-Tool reported a link issue}" "$REF"
    fi

    # FEC: module requires it but the link runs without
    local FEC="${DEEP_KV["$IFACE|FEC"]:-}" COMP="${DEEP_KV["$IFACE|Compliance"]:-}"
    if [[ -z "$FEC" ]]; then
        add_record "port" "$IFACE" "mlx5.deep.fec" "-" "" "-" "$SEV_NA" "$TOOL printed no FEC line" "" "$REF"
    elif [[ "$FEC" == "$DEEP_NO_FEC" && "$COMP" =~ $DEEP_MODULE_FEC_RE ]]; then
        add_record "port" "$IFACE" "mlx5.deep.fec" "link: $FEC" "" "module FEC = link FEC" "$SEV_WARN" \
            "FEC=$FEC; module Compliance=$COMP" \
            "Module is specified for operation with FEC but the link runs without it: enable RS-FEC on both ends (NIC and switch port)" "$REF"
    else
        add_record "port" "$IFACE" "mlx5.deep.fec" "link: $FEC" "" "module FEC = link FEC" "$SEV_OK" \
            "FEC=$FEC; module Compliance=${COMP:-n/a}" "" "$REF"
    fi

    # Effective (post-FEC) BER, averaged since the last counter clear
    RAW="${DEEP_KV["$IFACE|Effective Physical BER"]:-}"
    local SINCE="${DEEP_KV["$IFACE|Time Since Last Clear [Min]"]:-?}"
    EVIDENCE="Effective Physical BER=${RAW:-?} Raw Physical BER=${DEEP_KV["$IFACE|Raw Physical BER"]:-?} Effective Physical Errors=${DEEP_KV["$IFACE|Effective Physical Errors"]:-?} Link Down Counter=${DEEP_KV["$IFACE|Link Down Counter"]:-?} since ${SINCE} min"
    if [[ -z "$RAW" ]]; then
        add_record "port" "$IFACE" "mlx5.deep.ber" "-" "" "-" "$SEV_NA" "$TOOL printed no Effective Physical BER" "" "$REF"
    elif ! K=$(ber_exponent "$RAW"); then
        add_record "port" "$IFACE" "mlx5.deep.ber" "$RAW" "" "-" "$SEV_UNKNOWN" "$EVIDENCE" "Unparseable BER value" "$REF"
    else
        VALUE="effective $(ber_display "$RAW") raw $(ber_display "${DEEP_KV["$IFACE|Raw Physical BER"]:-?}")"
        if (( K >= -DEEP_EFFECTIVE_BER_WARN_EXP )); then
            SEV="$SEV_WARN"
            HINT="Average since the last counter clear ($SINCE min) exceeds 1E-$DEEP_EFFECTIVE_BER_WARN_EXP: clean/replace the optic or cable, check FEC; mlx5.phy.errors shows whether errors are still growing"
        else
            SEV="$SEV_OK"; HINT=""
        fi
        add_record "port" "$IFACE" "mlx5.deep.ber" "$VALUE" "" "effective<1E-$DEEP_EFFECTIVE_BER_WARN_EXP" "$SEV" "$EVIDENCE" "$HINT" "$REF"
    fi

    # Module: DOM values against the module's own ranges, and per-lane fault flags
    if [[ -z "${DEEP_KV["$IFACE|Identifier"]:-}" || "${DEEP_KV["$IFACE|Identifier"]}" == "N/A" ]]; then
        add_record "port" "$IFACE" "mlx5.deep.module" "-" "" "-" "$SEV_NA" "no module identified" "Empty cage or module without EEPROM" "$REF"
        return 0
    fi
    SEV="$SEV_OK"; HINT=""; VALUE=""; EVIDENCE=""
    for KEY in "${DEEP_RANGE_KEYS[@]}"; do
        V="${DEEP_KV["$IFACE|$KEY"]:-}"
        [[ "$V" =~ ^(-?[0-9.]+)\ \[(-?[0-9.]+)\.\.(-?[0-9.]+)\]$ ]] || continue
        RAW="${BASH_REMATCH[1]}"; LO="${BASH_REMATCH[2]}"; HI="${BASH_REMATCH[3]}"
        if ! { M_V=$(to_milli "$RAW") && M_LO=$(to_milli "$LO") && M_HI=$(to_milli "$HI"); }; then
            continue
        fi
        EVIDENCE+="$KEY=$V; "
        VALUE+="${KEY%% *}=$RAW "
        if (( M_V < M_LO || M_V > M_HI )); then
            SEV="$SEV_WARN"
            HINT+="$KEY $RAW outside [$LO..$HI]; "
        fi
    done
    for KEY in "${DEEP_FLAG_KEYS[@]}"; do
        FLAG="${DEEP_KV["$IFACE|$KEY"]:-}"
        [[ "$FLAG" =~ ^[0-9]+$ ]] || continue
        EVIDENCE+="$KEY=$FLAG; "
        if (( 10#$FLAG != 0 )); then
            SEV="$SEV_WARN"
            HINT+="${KEY% \[per lane\]} set (lane mask $FLAG); "
        fi
    done
    [[ -n "$HINT" ]] && HINT="${HINT%; }: reseat or replace the module, check the peer optic and fiber"
    EVIDENCE="${EVIDENCE%; }; module ${DEEP_KV["$IFACE|Vendor Name"]:-?} ${DEEP_KV["$IFACE|Vendor Part Number"]:-?}"
    add_record "port" "$IFACE" "mlx5.deep.module" "${VALUE% }" "" "within module ranges, no lane faults" "$SEV" "$EVIDENCE" "$HINT" "$REF"
}

check_deep() {
    local IDX TOOL
    TOOL=$(deep_tool)
    if [[ -z "$TOOL" ]]; then
        local HAS_MLX5=false
        for IDX in "${!PORT_IFACE[@]}"; do mlx5_port_eligible "$IDX" && HAS_MLX5=true; done
        $HAS_MLX5 && add_record "host" "$HOSTNAME" "mlx5.deep" "-" "" "-" "$SEV_NA" "neither mlxlink nor mstlink found" \
            "Install mstflint (distribution package) or NVIDIA MFT to enable deep mode" "$DESIGN_REF §7"
        return 0
    fi
    for IDX in "${!PORT_IFACE[@]}"; do
        mlx5_port_eligible "$IDX" && check_deep_port "$IDX"
    done
    return 0
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
    for IDX in "${!PORT_IFACE[@]}"; do
        mlx5_port_eligible "$IDX" && check_mlx5_port "$IDX"
    done
    [[ "$LEVEL" == "$LEVEL_DEEP" ]] && check_deep
    return 0
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

# WARN, CRIT and UNKNOWN rows are always shown in the table; OK and N/A only with -a/--all
is_problem() {
    [[ "$1" == "$SEV_WARN" || "$1" == "$SEV_CRIT" || "$1" == "$SEV_UNKNOWN" ]]
}

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
    [[ "$LEVEL" == "$LEVEL_DEEP" ]] && MODE+="  level $LEVEL_DEEP"
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
    local -a SHOWN=() ROWS=()
    local W_SEV=${#HEAD[0]} W_SCOPE=${#HEAD[1]} W_TARGET=${#HEAD[2]} W_CHECK=${#HEAD[3]} W_VALUE=${#HEAD[4]} W_THRESH=${#HEAD[5]}
    for i in "${!REC_SEV[@]}"; do
        is_problem "${REC_SEV[i]}" || $SHOW_ALL || continue
        ROWS+=("$i")
        SHOWN[i]=$(display_value "$i")
        (( ${#REC_SEV[i]} > W_SEV ))          && W_SEV=${#REC_SEV[i]}
        (( ${#REC_SCOPE[i]} > W_SCOPE ))      && W_SCOPE=${#REC_SCOPE[i]}
        (( ${#REC_TARGET[i]} > W_TARGET ))    && W_TARGET=${#REC_TARGET[i]}
        (( ${#REC_CHECK[i]} > W_CHECK ))      && W_CHECK=${#REC_CHECK[i]}
        (( ${#SHOWN[i]} > W_VALUE ))          && W_VALUE=${#SHOWN[i]}
        (( ${#REC_THRESHOLD[i]} > W_THRESH )) && W_THRESH=${#REC_THRESHOLD[i]}
    done
    local HIDDEN=$(( ${#REC_SEV[@]} - ${#ROWS[@]} ))

    printf '%bChecks%b\n' "$BOLD" "$RESET_COLOR"
    if (( ${#ROWS[@]} == 0 )); then
        printf '  %s No problems found in %d checks (-a/--all lists them)\n' "$(severity_icon "$SEV_OK")" "$HIDDEN"
    else
        printf "  %-${W_SEV}s  %-${W_SCOPE}s  %-${W_TARGET}s  %-${W_CHECK}s  %-${W_VALUE}s  %-${W_THRESH}s  %s\n" "${HEAD[@]}"
        for i in "${ROWS[@]}"; do
            SEV="${REC_SEV[i]}"
            COLOR=$(severity_color "$SEV")
            # Pad plain text first, then wrap in color, so ANSI codes never affect alignment
            printf "  %s%-${W_SEV}s%s  %-${W_SCOPE}s  %-${W_TARGET}s  %-${W_CHECK}s  %-${W_VALUE}s  %-${W_THRESH}s  %s\n" \
                "$COLOR" "$SEV" "$RESET_COLOR" "${REC_SCOPE[i]}" "${REC_TARGET[i]}" "${REC_CHECK[i]}" \
                "${SHOWN[i]}" "${REC_THRESHOLD[i]}" "${REC_HINT[i]}"
        done
        (( HIDDEN > 0 )) && printf '  %b%d OK/N/A rows hidden (-a/--all to show)%b\n' "$DIM" "$HIDDEN" "$RESET_COLOR"
    fi
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
    printf '  "level": "%s",\n' "$LEVEL"
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
        [[ "$LEVEL" == "$LEVEL_DEEP" ]] && deep_collect
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
