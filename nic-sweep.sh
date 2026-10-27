#!/bin/bash
#
# Script Name: nic-sweep.sh
# Description: Companion to nic-xray.sh and nic-health.sh. Runs nic-health (and nic-xray
#              where installed) on every host of an inventory over SSH, in parallel, and
#              writes one sweep directory per site: the per-host JSON verbatim, a manifest
#              of what happened on each host, and a merged CSV that records how the data
#              was collected. Read-only on the hosts: it never installs or changes anything.
#              Design: docs/design/nic-sweep.md
#
# Author: Ciro Iriarte <ciro.iriarte+software@gmail.com>
# Created: 2026-10-26
#
# Requirements:
#   - Runs as an unprivileged user on an operator or jump host
#   - Requires: ssh, timeout, jq, sha256sum, getopt
#   - On each host: nic-health (package) or --ship; sudo -n for that user; nic-xray optional
#
# Change Log:
#   - 2026-10-26: Phase 2 of docs/design/nic-sweep.md: inventory, parallel SSH, sweep layout,
#                 manifest, merged CSV with collection metadata, exit codes, progress bar
#   - 2026-10-27: -L/--lookback passed to nic-health (link-down look-back, e.g. 1440 for 24 h)
#
# Version: 2.15.0

SCRIPT_VERSION="2.15.0"
SCRIPT_NAME="nic-sweep.sh"
SWEEP_SCHEMA_VERSION=1
DESIGN_REF="docs/design/nic-sweep.md"

# --- Exit codes (design §5.5): CRIT outranks a collection failure ---
EXIT_OK=0
EXIT_WARN=1
EXIT_CRIT=2
EXIT_UNKNOWN=3

# --- Defaults and limits ---
DEFAULT_LEVEL="deep"
LEVELS=("basic" "deep")
DEFAULT_INTERVAL=30
MAX_INTERVAL=3600
# nic-health's own limit; empty LOOKBACK = do not pass -L (nic-health default applies)
MAX_LOOKBACK=1440
DEFAULT_PARALLEL=8
MAX_PARALLEL=256
# Per-host limit = sampling interval + margin; deep mode queries each mlx5 port (10 s cap each)
TIMEOUT_MARGIN_BASIC=120
TIMEOUT_MARGIN_DEEP=300
MAX_TIMEOUT=7200
# Seconds before timeout(1) escalates to SIGKILL
KILL_AFTER=10
CONNECT_TIMEOUT=10
XRAY_TIMEOUT=120
DEFAULT_OUTPUT_DIR="./sweeps"
# Sweep directories 0750, files 0640: sweeps hold host names, addresses and switch ports
SWEEP_UMASK=027
PROGRESS_WIDTH=30

# jq filter: no non-finite number anywhere. JSON forbids inf/-inf/nan but jq accepts -inf (1.6, 1.7)
# and nan (1.7); nic-xray < 2.13.0 wrote -inf for optics without light (#24)
JQ_ALL_FINITE='([.. | numbers | select(isinfinite or isnan)] | length == 0)'

# Inventory fields reach command lines only after matching these
# The first character must be alphanumeric: rules out ".", "..", and option-like "-x" values
FIELD_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
ADDRESS_RE='^[A-Za-z0-9][A-Za-z0-9._:-]*$'
JUMP_RE='^([A-Za-z0-9][A-Za-z0-9._-]*@)?[A-Za-z0-9][A-Za-z0-9._-]*(:[0-9]+)?$'
# nodes/<host>.xray.json would collide with the canonical file of a host named "<host>.xray"
XRAY_SUFFIX=".xray"
INVENTORY_HEADER_RE='^site,host,address(,user)?$'

# Host status (design §5.3); the order is the manifest/summary order
STATUSES=("ok" "ssh-fail" "sudo-fail" "tool-missing" "timeout" "bad-output")
ST_OK="ok"
ST_SSH="ssh-fail"
ST_SUDO="sudo-fail"
ST_MISSING="tool-missing"
ST_TIMEOUT="timeout"
ST_BAD="bad-output"
XRAY_STATUSES=("ok" "absent" "failed" "skipped")
VERDICTS=("OK" "WARN" "CRIT" "UNKNOWN")
# ssh exits 255 on connection/auth errors; the remote wrapper exits 127 when the tool is absent;
# timeout(1) exits 124 on expiry, 137 when it had to SIGKILL
RC_SSH=255
RC_MISSING=127
RC_TIMEOUT=124
RC_KILLED=137
# Remote text runs with LC_ALL=C so these are English; sudo prints some with a "sudo: " prefix, some without
SUDO_DENIED_RE='a password is required|a terminal is required|Sorry, user .* (is not allowed to execute|may not run sudo)|is not in the sudoers file|nic-sweep: sudo not found'
# The remote side stops a little before the local limit, so a dropped ssh leaves no long-running root process
REMOTE_LIMIT_MARGIN=5
# Remote tool names: packaged command first, then the script name (manual installs)
HEALTH_TOOLS=("nic-health" "nic-health.sh")
XRAY_TOOLS=("nic-xray" "nic-xray.sh")
REQUIRED_CMDS=("ssh" "timeout" "jq" "sha256sum" "getopt")
# nic-health -O json fields copied into every merged.csv row (design §5.4)
CSV_META_COLS=("site" "hostname" "collected_at" "version" "level" "interval_s" "uptime_s" "boot_id")
CSV_RECORD_COLS=("severity" "scope" "target" "check_id" "value" "unit" "threshold" "evidence" "hint" "ref")

# --- Settings (from options) ---
INVENTORY=""
SITE_FILTER=()
JUMP=""
SSH_USER=""
PARALLEL="$DEFAULT_PARALLEL"
TIMEOUT=""
OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
LEVEL="$DEFAULT_LEVEL"
INTERVAL="$DEFAULT_INTERVAL"
LOOKBACK=""
COLLECT_XRAY=true
SHIP=""
ACCEPT_NEW_HOSTKEYS=false
USE_COLOR=true

# --- Runtime state ---
INV_SITE=()
INV_HOST=()
INV_ADDR=()
INV_USER=()
INV_SKIPPED=0
INV_SHA=""
RUN_TS=""
STARTED_AT=""
WORK_DIR=""
REMOTE_HEALTH=""
REMOTE_XRAY=""

# --- Helpers ---

usage() {
    echo -e "Usage: $SCRIPT_NAME -f|--inventory FILE [-s|--site SITE]... [-J|--jump HOST] [-u|--user USER]"
    echo -e "       [-p|--parallel N] [-T|--timeout SEC] [-o|--output-dir DIR] [-l|--level basic|deep]"
    echo -e "       [-I|--interval SEC] [-L|--lookback MIN] [--no-xray] [--ship PATH]"
    echo -e "       [--accept-new-hostkeys] [-n|--no-color] [-v|--version] [-h|--help]"
    echo -e ""
    echo -e "Version: $SCRIPT_VERSION"
    echo -e ""
    echo -e "Description:"
    echo -e " Runs nic-health on every host of an inventory over SSH, in parallel, and writes one"
    echo -e " sweep per site under DIR/<site>/<UTC time>/: nodes/<host>.json (nic-health -O json,"
    echo -e " verbatim), nodes/<host>.xray.json (nic-xray --all, where installed), nodes/<host>.err,"
    echo -e " MANIFEST.tsv (status per host), merged.csv (all results plus collection metadata)"
    echo -e " and sweep.json (how the sweep ran). Never prompts: ssh BatchMode and sudo -n only."
    echo -e ""
    echo -e "Options:"
    echo -e " -f, --inventory FILE    Hosts to sweep, one per line: site,host,address[,user]"
    echo -e "                         (# comments and a 'site,host,address,user' header allowed)"
    echo -e " -s, --site SITE         Only sweep this site (repeatable; default: every site)"
    echo -e " -J, --jump HOST         SSH jump host ([user@]host[:port], passed to ssh -J)"
    echo -e " -u, --user USER         SSH user when the inventory line has none (default: ssh config)"
    echo -e " -p, --parallel N        Hosts swept at once (default: $DEFAULT_PARALLEL, max: $MAX_PARALLEL)"
    echo -e " -T, --timeout SEC       Per-host limit for nic-health (default: interval + $TIMEOUT_MARGIN_DEEP s"
    echo -e "                         in deep mode, + $TIMEOUT_MARGIN_BASIC s in basic; max: $MAX_TIMEOUT)"
    echo -e " -o, --output-dir DIR    Root of the sweep tree (default: $DEFAULT_OUTPUT_DIR)"
    echo -e " -l, --level LEVEL       nic-health level: basic or deep (default: $DEFAULT_LEVEL)"
    echo -e " -I, --interval SEC      nic-health sampling window (default: $DEFAULT_INTERVAL, max: $MAX_INTERVAL)."
    echo -e "                         30 s or longer catches bursty link errors that 5 s misses"
    echo -e " -L, --lookback MIN      nic-health link-down look-back in the kernel journal (0-$MAX_LOOKBACK,"
    echo -e "                         0 = off; default: nic-health's own, 60). 1440 covers 24 h"
    echo -e "     --no-xray           Do not collect nic-xray --all --output json"
    echo -e "     --ship PATH         Send this local nic-health.sh to each host over ssh, run it from a"
    echo -e "                         temporary file and delete it (for hosts without the package)."
    echo -e "                         Needs sudo for 'bash /tmp/nic-health.*', which amounts to full root"
    echo -e "     --accept-new-hostkeys  Trust unknown host keys on first contact"
    echo -e "                         (ssh StrictHostKeyChecking=accept-new; default: your ssh policy)"
    echo -e " -n, --no-color          Disable color and the progress bar"
    echo -e " -v, --version           Display version information"
    echo -e " -h, --help              Display this help message"
    echo -e ""
    echo -e "Exit status:"
    echo -e " 0  Every host collected, all verdicts OK"
    echo -e " 1  Every host collected, at least one WARN, no CRIT"
    echo -e " 2  At least one CRIT (even if some hosts could not be collected)"
    echo -e " 3  No CRIT, but a host was not collected; or no WARN and a host reported UNKNOWN;"
    echo -e "    or a usage error"
    echo -e ""
    echo -e "See also: nic-health.sh(8), nic-xray.sh(8). Design: $DESIGN_REF"
}

die_unknown() {
    echo -e "❌ $1" >&2
    [[ "${2:-}" == "usage" ]] && { echo >&2; usage >&2; }
    exit "$EXIT_UNKNOWN"
}

warn() {
    echo -e "⚠️  $1" >&2
}

# Unsigned integer in [MIN..MAX] without leading zeros; fails otherwise (no arithmetic on raw input)
bounded_uint() {
    local V="$1" MIN="$2" MAX="$3"
    [[ "$V" =~ ^[0-9]+$ ]] || return 1
    V="${V#"${V%%[!0]*}"}"
    V="${V:-0}"
    (( ${#V} <= ${#MAX} && V >= MIN && V <= MAX )) || return 1
    printf '%d' "$V"
}

trim() {
    local V="$1"
    V="${V#"${V%%[![:space:]]*}"}"
    V="${V%"${V##*[![:space:]]}"}"
    printf '%s' "$V"
}

setup_colors() {
    [[ ! -t 1 ]] && USE_COLOR=false
    if $USE_COLOR; then
        RESET_COLOR=$'\033[0m'
        GREEN=$'\033[1;32m'
        YELLOW=$'\033[1;33m'
        RED=$'\033[1;31m'
        BOLD=$'\033[1m'
    else
        RESET_COLOR=""
        GREEN=""
        YELLOW=""
        RED=""
        BOLD=""
    fi
}

check_requirements() {
    local CMD MISSING=()
    for CMD in "${REQUIRED_CMDS[@]}"; do
        type -P "$CMD" >/dev/null || MISSING+=("$CMD")
    done
    (( ${#MISSING[@]} == 0 )) || die_unknown "Required command(s) not found: ${MISSING[*]}"
}

# --- Setup ---

parse_args() {
    local OPTIONS
    if ! OPTIONS=$(getopt -o hvf:s:J:u:p:T:o:l:I:L:n \
        --long help,version,inventory:,site:,jump:,user:,parallel:,timeout:,output-dir:,level:,interval:,lookback:,no-xray,ship:,accept-new-hostkeys,no-color \
        -n "$SCRIPT_NAME" -- "$@"); then
        die_unknown "Failed to parse options." usage
    fi
    eval set -- "$OPTIONS"

    while true; do
        case "$1" in
            -f|--inventory) INVENTORY="$2"; shift 2 ;;
            -s|--site)
                [[ "$2" =~ $FIELD_RE ]] || die_unknown "Invalid --site value '$2'." usage
                SITE_FILTER+=("$2"); shift 2 ;;
            -J|--jump)
                [[ "$2" =~ $JUMP_RE ]] || die_unknown "Invalid --jump value '$2' (expected [user@]host[:port])." usage
                JUMP="$2"; shift 2 ;;
            -u|--user)
                [[ "$2" =~ $FIELD_RE ]] || die_unknown "Invalid --user value '$2'." usage
                SSH_USER="$2"; shift 2 ;;
            -p|--parallel)
                PARALLEL=$(bounded_uint "$2" 1 "$MAX_PARALLEL") \
                    || die_unknown "Invalid --parallel value '$2' (expected 1-$MAX_PARALLEL)." usage
                shift 2 ;;
            -T|--timeout)
                TIMEOUT=$(bounded_uint "$2" 1 "$MAX_TIMEOUT") \
                    || die_unknown "Invalid --timeout value '$2' (expected 1-$MAX_TIMEOUT seconds)." usage
                shift 2 ;;
            -o|--output-dir)
                [[ -n "$2" ]] || die_unknown "Empty value for --output-dir." usage
                OUTPUT_DIR="$2"; shift 2 ;;
            -l|--level)
                [[ " ${LEVELS[*]} " == *" $2 "* ]] || die_unknown "Invalid --level value '$2' (expected: ${LEVELS[*]})." usage
                LEVEL="$2"; shift 2 ;;
            -I|--interval)
                INTERVAL=$(bounded_uint "$2" 0 "$MAX_INTERVAL") \
                    || die_unknown "Invalid --interval value '$2' (expected 0-$MAX_INTERVAL seconds)." usage
                shift 2 ;;
            -L|--lookback)
                LOOKBACK=$(bounded_uint "$2" 0 "$MAX_LOOKBACK") \
                    || die_unknown "Invalid --lookback value '$2' (expected 0-$MAX_LOOKBACK minutes)." usage
                shift 2 ;;
            --no-xray) COLLECT_XRAY=false; shift ;;
            --ship)
                [[ -f "$2" && -r "$2" ]] || die_unknown "--ship file '$2' is not a readable file." usage
                SHIP="$2"; shift 2 ;;
            --accept-new-hostkeys) ACCEPT_NEW_HOSTKEYS=true; shift ;;
            -n|--no-color) USE_COLOR=false; shift ;;
            -v|--version) echo "$SCRIPT_NAME $SCRIPT_VERSION"; exit "$EXIT_OK" ;;
            -h|--help) usage; exit "$EXIT_OK" ;;
            --) shift; break ;;
            *) die_unknown "Unexpected option '$1'." usage ;;
        esac
    done
    (( $# == 0 )) || die_unknown "Unexpected argument '$1'." usage
    [[ -n "$INVENTORY" ]] || die_unknown "Missing required option --inventory." usage
    [[ -f "$INVENTORY" && -r "$INVENTORY" ]] || die_unknown "Inventory '$INVENTORY' is not a readable file." usage
    if [[ -z "$TIMEOUT" ]]; then
        if [[ "$LEVEL" == "deep" ]]; then
            TIMEOUT=$(( INTERVAL + TIMEOUT_MARGIN_DEEP ))
        else
            TIMEOUT=$(( INTERVAL + TIMEOUT_MARGIN_BASIC ))
        fi
    fi
}

# Read the inventory into INV_* arrays: every field validated, bad or duplicate lines skipped
load_inventory() {
    local LINE LN=0 N SITE HOST ADDR USR KEY
    local -a F
    local -A SEEN=()
    while IFS= read -r LINE || [[ -n "$LINE" ]]; do
        (( ++LN ))
        LINE=$(trim "${LINE%$'\r'}")
        [[ -z "$LINE" || "$LINE" == \#* ]] && continue
        [[ "${LINE,,}" =~ $INVENTORY_HEADER_RE ]] && continue
        IFS=',' read -r -a F <<< "$LINE"
        N=${#F[@]}
        if (( N < 3 || N > 4 )); then
            warn "inventory line $LN: expected site,host,address[,user]; skipped"
            (( ++INV_SKIPPED )); continue
        fi
        SITE=$(trim "${F[0]}"); HOST=$(trim "${F[1]}"); ADDR=$(trim "${F[2]}"); USR=$(trim "${F[3]:-}")
        if ! [[ "$SITE" =~ $FIELD_RE && "$HOST" =~ $FIELD_RE && "$ADDR" =~ $ADDRESS_RE && "$ADDR" != -* ]] \
            || [[ -n "$USR" && ! "$USR" =~ $FIELD_RE ]]; then
            warn "inventory line $LN: invalid characters in a field; skipped"
            (( ++INV_SKIPPED )); continue
        fi
        if [[ "$HOST" == *"$XRAY_SUFFIX" ]]; then
            warn "inventory line $LN: host name may not end in '$XRAY_SUFFIX'; skipped"
            (( ++INV_SKIPPED )); continue
        fi
        KEY="$SITE|$HOST"
        if [[ -n "${SEEN[$KEY]:-}" ]]; then
            warn "inventory line $LN: duplicate host '$HOST' in site '$SITE' (first on line ${SEEN[$KEY]}); skipped"
            (( ++INV_SKIPPED )); continue
        fi
        SEEN[$KEY]=$LN
        if (( ${#SITE_FILTER[@]} > 0 )) && [[ " ${SITE_FILTER[*]} " != *" $SITE "* ]]; then
            continue
        fi
        INV_SITE+=("$SITE"); INV_HOST+=("$HOST"); INV_ADDR+=("$ADDR"); INV_USER+=("${USR:-$SSH_USER}")
    done < "$INVENTORY"
    INV_SHA=$(sha256sum < "$INVENTORY"); INV_SHA="${INV_SHA%% *}"
    (( ${#INV_HOST[@]} > 0 )) || die_unknown "No host to sweep in '$INVENTORY'$( (( ${#SITE_FILTER[@]} )) && printf ' for site(s) %s' "${SITE_FILTER[*]}")."
}

# Remote commands: constant text plus values already validated (level from a list, digits), run by
# the remote login shell (may be POSIX sh). LC_ALL=C keeps sudo messages in English; signal traps make
# --ship remove its file on HUP/INT/TERM too; a remote timeout(1), when present, bounds the root process
build_remote_commands() {
    local ARGS FIND_HEALTH="" FIND_XRAY="" T PREFIX LIMIT_H LIMIT_X
    printf -v ARGS '%q ' -O json -l "$LEVEL" -I "$INTERVAL"
    [[ -n "$LOOKBACK" ]] && printf -v ARGS '%s-L %q ' "$ARGS" "$LOOKBACK"
    ARGS="${ARGS% }"
    for T in "${HEALTH_TOOLS[@]}"; do FIND_HEALTH+="command -v $T || "; done
    for T in "${XRAY_TOOLS[@]}"; do FIND_XRAY+="command -v $T || "; done
    LIMIT_H=$(( TIMEOUT > REMOTE_LIMIT_MARGIN ? TIMEOUT - REMOTE_LIMIT_MARGIN : 1 ))
    LIMIT_X=$(( XRAY_TIMEOUT - REMOTE_LIMIT_MARGIN ))
    PREFIX="LC_ALL=C; export LC_ALL; command -v sudo >/dev/null 2>&1 || { echo 'nic-sweep: sudo not found' >&2; exit 1; }; "
    # remote_run LIMIT CMD...: CMD under timeout(1) when the host has it
    local RUN_H="if command -v timeout >/dev/null 2>&1; then exec timeout -k $KILL_AFTER $LIMIT_H"
    local RUN_X="if command -v timeout >/dev/null 2>&1; then exec timeout -k $KILL_AFTER $LIMIT_X"
    if [[ -n "$SHIP" ]]; then
        # Script arrives on stdin; written to a private temp file (mktemp: 0600, O_EXCL), removed on exit
        REMOTE_HEALTH="${PREFIX}T=\$(mktemp /tmp/nic-health.XXXXXX) || exit 1; trap 'rm -f \"\$T\"' EXIT; trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM; cat > \"\$T\" || exit 1; if command -v timeout >/dev/null 2>&1; then timeout -k $KILL_AFTER $LIMIT_H sudo -n bash \"\$T\" $ARGS; else sudo -n bash \"\$T\" $ARGS; fi"
    else
        REMOTE_HEALTH="${PREFIX}T=\$(${FIND_HEALTH}exit $RC_MISSING) || exit $RC_MISSING; $RUN_H sudo -n \"\$T\" $ARGS; else exec sudo -n \"\$T\" $ARGS; fi"
    fi
    REMOTE_XRAY="${PREFIX}T=\$(${FIND_XRAY}exit $RC_MISSING) || exit $RC_MISSING; $RUN_X sudo -n \"\$T\" --all --output json; else exec sudo -n \"\$T\" --all --output json; fi"
}

# --- Per-host collection ---

# ssh argv for inventory entry IDX (no remote command)
ssh_argv() {
    local IDX="$1"
    SSH_ARGV=(ssh -o BatchMode=yes -o "ConnectTimeout=$CONNECT_TIMEOUT")
    $ACCEPT_NEW_HOSTKEYS && SSH_ARGV+=(-o StrictHostKeyChecking=accept-new)
    [[ -n "$JUMP" ]] && SSH_ARGV+=(-J "$JUMP")
    [[ -n "${INV_USER[IDX]}" ]] && SSH_ARGV+=(-l "${INV_USER[IDX]}")
    SSH_ARGV+=(-- "${INV_ADDR[IDX]}")
}

# Strict JSON of the expected shape (jq filter printing true/false). jq 1.6 exits 0 on empty input
# even with -e, and jq accepts non-finite numbers that strict parsers reject: check both
strict_json() {
    local FILE="$1" SHAPE="$2"
    [[ -s "$FILE" ]] || return 1
    [[ "$(jq -r "($SHAPE) and $JQ_ALL_FINITE" "$FILE" 2>/dev/null)" == "true" ]]
}

# A nic-health JSON document: an object with a known verdict and a results array. The verdict is
# written into the manifest, so anything else (another value, embedded tabs/newlines) is rejected
valid_health_json() {
    strict_json "$1" 'type == "object" and (.results | type == "array") and
        (.verdict | type == "string" and (. == "OK" or . == "WARN" or . == "CRIT" or . == "UNKNOWN"))'
}

# True when FILE parses (leniently, as jq does) but holds a non-finite number
has_nonfinite() {
    [[ "$(jq -r "$JQ_ALL_FINITE | not" "$1" 2>/dev/null)" == "true" ]]
}

# A nic-xray JSON document: an array of interfaces
valid_xray_json() {
    strict_json "$1" 'type == "array"'
}

# Status of one collection from its exit code, output and stderr (design §5.3)
classify() {
    local RC="$1" OUT="$2" ERR="$3"
    if valid_health_json "$OUT"; then
        echo "$ST_OK"
    elif (( RC == RC_TIMEOUT || RC == RC_KILLED )); then
        echo "$ST_TIMEOUT"
    elif (( RC == RC_SSH )); then
        echo "$ST_SSH"
    elif (( RC == RC_MISSING )); then
        echo "$ST_MISSING"
    elif grep -Eq "$SUDO_DENIED_RE" "$ERR" 2>/dev/null; then
        echo "$ST_SUDO"
    else
        echo "$ST_BAD"
    fi
}

# run_limited LIMIT IN OUT ERR CMD...: CMD under timeout(1) in the background, so a TERM to this worker
# can be forwarded (timeout puts itself in its own process group and would not see it otherwise)
run_limited() {
    local LIMIT="$1" IN="$2" OUTF="$3" ERRF="$4" RC
    shift 4
    timeout -k "$KILL_AFTER" "$LIMIT" "$@" < "$IN" > "$OUTF" 2> "$ERRF" &
    CHILD_PID=$!
    wait "$CHILD_PID"
    RC=$?
    CHILD_PID=""
    return "$RC"
}

# Sweep inventory entry IDX; writes its files and one result line to WORK_DIR/IDX
sweep_host() {
    local IDX="$1" DIR="$2"
    local HOST="${INV_HOST[IDX]}" OUT ERR XOUT RC XRC START STATUS XSTATUS="skipped" VERDICT="-"
    CHILD_PID=""
    trap '[[ -n "$CHILD_PID" ]] && kill -TERM "$CHILD_PID" 2>/dev/null; exit 143' TERM
    OUT="$DIR/nodes/$HOST.json"; ERR="$DIR/nodes/$HOST.err"; XOUT="$DIR/nodes/$HOST.xray.json"
    ssh_argv "$IDX"
    START=$SECONDS
    run_limited "$TIMEOUT" "${SHIP:-/dev/null}" "$OUT" "$ERR" "${SSH_ARGV[@]}" "$REMOTE_HEALTH"
    RC=$?
    STATUS=$(classify "$RC" "$OUT" "$ERR")
    [[ "$STATUS" == "$ST_OK" ]] && VERDICT=$(jq -r '.verdict' "$OUT")

    # nic-xray: optional, never a failure of the host; not attempted when the host was unreachable
    if $COLLECT_XRAY && [[ "$STATUS" != "$ST_SSH" && "$STATUS" != "$ST_TIMEOUT" ]]; then
        run_limited "$XRAY_TIMEOUT" /dev/null "$XOUT" "$ERR.xray" "${SSH_ARGV[@]}" "$REMOTE_XRAY"
        XRC=$?
        if (( XRC == 0 )) && valid_xray_json "$XOUT"; then
            XSTATUS="ok"
        elif (( XRC == RC_MISSING )); then
            XSTATUS="absent"; rm -f "$XOUT"
        else
            XSTATUS="failed"
            has_nonfinite "$XOUT" \
                && echo "# nic-sweep: nic-xray output has non-finite numbers (-inf/nan), not valid JSON; fixed in nic-xray 2.13.0 (#24)" >> "$ERR.xray"
        fi
        if [[ -s "$ERR.xray" ]]; then
            { echo "# nic-xray (exit $XRC):"; cat "$ERR.xray"; } >> "$ERR"
        fi
        rm -f "$ERR.xray"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$HOST" "${INV_ADDR[IDX]}" "$STATUS" "$RC" "$(( SECONDS - START ))" \
        "$XSTATUS" "$VERDICT" > "$WORK_DIR/$IDX"
}

progress() {
    local DONE="$1" TOTAL="$2" FILLED BAR PAD
    $USE_COLOR && [[ -t 2 ]] || return 0
    FILLED=$(( DONE * PROGRESS_WIDTH / TOTAL ))
    printf -v BAR '%*s' "$FILLED" ''
    printf -v PAD '%*s' $(( PROGRESS_WIDTH - FILLED )) ''
    printf '\r🛰️  Sweeping: [%s%s] %d/%d hosts' "${BAR// /#}" "${PAD// /.}" "$DONE" "$TOTAL" >&2
    (( DONE == TOTAL )) && printf '\r%*s\r' 60 '' >&2
    return 0
}

# Run every host, at most PARALLEL at once
run_sweep() {
    local IDX RUNNING=0 DONE=0 TOTAL=${#INV_HOST[@]}
    progress 0 "$TOTAL"
    for IDX in "${!INV_HOST[@]}"; do
        sweep_host "$IDX" "$OUTPUT_DIR/${INV_SITE[IDX]}/$RUN_TS" &
        (( ++RUNNING ))
        if (( RUNNING >= PARALLEL )); then
            wait -n
            (( RUNNING--, ++DONE ))
            progress "$DONE" "$TOTAL"
        fi
    done
    while (( RUNNING > 0 )); do
        wait -n
        (( RUNNING--, ++DONE ))
        progress "$DONE" "$TOTAL"
    done
}

# --- Per-site outputs ---

# Lines of WORK_DIR results for SITE (host-sorted). A worker that died before writing its line (killed,
# disk full) still gets one: bad-output with exit "-", so the host is never silently dropped
site_results() {
    local SITE="$1" IDX
    for IDX in "${!INV_HOST[@]}"; do
        [[ "${INV_SITE[IDX]}" == "$SITE" ]] || continue
        if [[ -s "$WORK_DIR/$IDX" ]]; then
            cat "$WORK_DIR/$IDX"
        else
            printf '%s\t%s\t%s\t-\t-\tskipped\t-\n' "${INV_HOST[IDX]}" "${INV_ADDR[IDX]}" "$ST_BAD"
        fi
    done | sort
}

write_manifest() {
    local DIR="$1" SITE="$2"
    {
        printf 'host\taddress\tstatus\texit_code\tduration_s\txray\tverdict\n'
        site_results "$SITE"
    } > "$DIR/MANIFEST.tsv"
}

# merged.csv: every nic-health result of the site's collected hosts, prefixed with how it was collected
write_merged_csv() {
    local DIR="$1" SITE="$2" HOST STATUS JQ_PROG COL
    # shellcheck disable=SC2016  # $site/$host/$m are jq variables, not shell expansions
    JQ_PROG='[$site, $host, .collected_at, .version, .level, .interval_s, .uptime_s, .boot_id] as $m | .results[] | $m + ['
    for COL in "${CSV_RECORD_COLS[@]}"; do JQ_PROG+=".$COL,"; done
    JQ_PROG="${JQ_PROG%,}] | @csv"
    {
        (IFS=','; printf '%s\n' "${CSV_META_COLS[*]},${CSV_RECORD_COLS[*]}")
        while IFS=$'\t' read -r HOST _ STATUS _; do
            [[ "$STATUS" == "$ST_OK" ]] || continue
            if ! jq -r --arg site "$SITE" --arg host "$HOST" "$JQ_PROG" "$DIR/nodes/$HOST.json" 2>> "$DIR/nodes/$HOST.err"; then
                warn "$SITE/$HOST: results not exported to merged.csv (see nodes/$HOST.err)"
                echo "# nic-sweep: merged.csv export failed for this host" >> "$DIR/nodes/$HOST.err"
            fi
        done < <(site_results "$SITE")
    } > "$DIR/merged.csv"
}

# Count of result lines (stdin) whose column COL (1-based) equals VALUE; pure Bash, so a host without
# awk cannot turn every count into 0. Result fields are never empty (placeholders use "-")
count_col() {
    local COL="$1" VALUE="$2" LINE N=0
    local -a F
    while IFS= read -r LINE; do
        [[ -n "$LINE" ]] || continue
        IFS=$'\t' read -r -a F <<< "$LINE"
        [[ "${F[COL - 1]:-}" == "$VALUE" ]] && (( ++N ))
    done
    echo "$N"
}

# Result lines (stdin) whose host was not collected
not_collected() {
    local LINE
    local -a F
    while IFS= read -r LINE; do
        [[ -n "$LINE" ]] || continue
        IFS=$'\t' read -r -a F <<< "$LINE"
        [[ "${F[2]}" != "$ST_OK" ]] && printf '%s\n' "$LINE"
    done
    return 0
}

# JSON object of counts for column COL over the given values
counts_json() {
    local RESULTS="$1" COL="$2" V SEP=""
    shift 2
    printf '{'
    for V in "$@"; do
        printf '%s"%s": %d' "$SEP" "$V" "$(count_col "$COL" "$V" <<< "$RESULTS")"
        SEP=", "
    done
    printf '}'
}

# Exit code for a set of result lines (design §5.5): CRIT > a host not collected > WARN > UNKNOWN
# verdict > OK. Among verdicts this is nic-health's own order; an empty set is UNKNOWN
results_exit_code() {
    local RESULTS="$1"
    if [[ -z "${RESULTS//[[:space:]]/}" ]]; then
        echo "$EXIT_UNKNOWN"
    elif (( $(count_col 7 "CRIT" <<< "$RESULTS") > 0 )); then
        echo "$EXIT_CRIT"
    elif [[ -n "$(not_collected <<< "$RESULTS")" ]]; then
        echo "$EXIT_UNKNOWN"
    elif (( $(count_col 7 "WARN" <<< "$RESULTS") > 0 )); then
        echo "$EXIT_WARN"
    elif (( $(count_col 7 "UNKNOWN" <<< "$RESULTS") > 0 )); then
        echo "$EXIT_UNKNOWN"
    else
        echo "$EXIT_OK"
    fi
}

write_sweep_json() {
    local DIR="$1" SITE="$2" FINISHED_AT="$3" RESULTS TOTAL
    RESULTS=$(site_results "$SITE")
    TOTAL=$(grep -c . <<< "$RESULTS" || true)
    jq -n --argjson schema "$SWEEP_SCHEMA_VERSION" --arg tool "$SCRIPT_NAME" --arg version "$SCRIPT_VERSION" \
        --arg site "$SITE" --arg started "$STARTED_AT" --arg finished "$FINISHED_AT" \
        --arg inv_file "${INVENTORY##*/}" --arg inv_sha "$INV_SHA" --argjson inv_skipped "$INV_SKIPPED" \
        --arg level "$LEVEL" --argjson interval "$INTERVAL" --argjson lookback "${LOOKBACK:-null}" \
        --argjson parallel "$PARALLEL" \
        --argjson timeout "$TIMEOUT" --arg jump "$JUMP" --argjson ship "$([[ -n "$SHIP" ]] && echo true || echo false)" \
        --argjson xray "$COLLECT_XRAY" --argjson accept_new "$ACCEPT_NEW_HOSTKEYS" --argjson total "$TOTAL" \
        --argjson by_status "$(counts_json "$RESULTS" 3 "${STATUSES[@]}")" \
        --argjson by_verdict "$(counts_json "$RESULTS" 7 "${VERDICTS[@]}")" \
        --argjson by_xray "$(counts_json "$RESULTS" 6 "${XRAY_STATUSES[@]}")" \
        --argjson exit_code "$(results_exit_code "$RESULTS")" \
        '{schema_version: $schema, tool: $tool, version: $version, site: $site,
          started_at: $started, finished_at: $finished,
          inventory: {file: $inv_file, sha256: $inv_sha, skipped_lines: $inv_skipped},
          options: {level: $level, interval_s: $interval, lookback_min: $lookback, parallel: $parallel, timeout_s: $timeout,
                    jump: (if $jump == "" then null else $jump end), ship: $ship, xray: $xray,
                    accept_new_hostkeys: $accept_new},
          hosts: {total: $total, by_status: $by_status, by_verdict: $by_verdict, xray: $by_xray},
          exit_code: $exit_code}' > "$DIR/sweep.json"
}

print_site_summary() {
    local DIR="$1" SITE="$2" RESULTS TOTAL OKN S N LINE="" VLINE="" XLINE="" V COLOR H A X
    RESULTS=$(site_results "$SITE")
    TOTAL=$(grep -c . <<< "$RESULTS" || true)
    OKN=$(count_col 3 "$ST_OK" <<< "$RESULTS")
    for S in "${STATUSES[@]:1}"; do
        N=$(count_col 3 "$S" <<< "$RESULTS")
        (( N > 0 )) && LINE+=", ${RED}$N $S${RESET_COLOR}"
    done
    for V in "${VERDICTS[@]}"; do
        N=$(count_col 7 "$V" <<< "$RESULTS")
        (( N == 0 )) && continue
        case "$V" in OK) COLOR="$GREEN" ;; WARN) COLOR="$YELLOW" ;; *) COLOR="$RED" ;; esac
        VLINE+=" ${COLOR}$V $N${RESET_COLOR}"
    done
    for S in "${XRAY_STATUSES[@]}"; do
        N=$(count_col 6 "$S" <<< "$RESULTS")
        (( N > 0 )) && XLINE+=" $S $N"
    done
    printf '%b📁 %s%b  %d hosts: %d collected%b · verdicts:%b · nic-xray:%s\n' "$BOLD" "$SITE" "$RESET_COLOR" \
        "$TOTAL" "$OKN" "$LINE" "${VLINE:- none}" "${XLINE:- none}"
    while IFS=$'\t' read -r H A S X _; do
        printf '   %s (%s): %s, exit %s\n' "$H" "$A" "$S" "$X"
    done < <(not_collected <<< "$RESULTS")
    printf '   %s\n' "$DIR"
}

cleanup() {
    [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
}

on_interrupt() {
    warn "Interrupted: stopping running collections."
    local -a PIDS
    trap '' INT TERM
    mapfile -t PIDS < <(jobs -p)
    # Workers forward TERM to their timeout(1), which signals ssh
    (( ${#PIDS[@]} > 0 )) && kill -TERM "${PIDS[@]}" 2>/dev/null
    wait
    cleanup
    exit "$EXIT_UNKNOWN"
}

main() {
    local SITE DIR FINISHED_AT RC ALL_RESULTS
    local -a SITES
    parse_args "$@"
    setup_colors
    check_requirements
    load_inventory
    build_remote_commands
    umask "$SWEEP_UMASK"

    TZ=UTC0 printf -v RUN_TS '%(%Y%m%dT%H%M%SZ)T' -1
    TZ=UTC0 printf -v STARTED_AT '%(%Y-%m-%dT%H:%M:%SZ)T' -1
    mapfile -t SITES < <(printf '%s\n' "${INV_SITE[@]}" | sort -u)
    for SITE in "${SITES[@]}"; do
        [[ -e "$OUTPUT_DIR/$SITE/$RUN_TS" ]] && die_unknown "Sweep directory '$OUTPUT_DIR/$SITE/$RUN_TS' already exists."
    done
    for SITE in "${SITES[@]}"; do
        DIR="$OUTPUT_DIR/$SITE/$RUN_TS"
        # Plain mkdir fails if DIR appeared meanwhile: the directory is claimed, never shared
        if ! { mkdir -p -- "$OUTPUT_DIR/$SITE" && mkdir -- "$DIR" && mkdir -- "$DIR/nodes"; }; then
            die_unknown "Cannot create '$DIR' (it may already exist)."
        fi
    done
    WORK_DIR=$(mktemp -d) || die_unknown "Cannot create a temporary directory."
    trap cleanup EXIT
    trap on_interrupt INT TERM

    printf '%b🛰️  %s %s%b  %d hosts, %d site(s), level %s, window %ss%s, %d at a time%s\n' "$BOLD" "$SCRIPT_NAME" \
        "$SCRIPT_VERSION" "$RESET_COLOR" "${#INV_HOST[@]}" "${#SITES[@]}" "$LEVEL" "$INTERVAL" \
        "${LOOKBACK:+, look-back ${LOOKBACK}m}" "$PARALLEL" \
        "$( (( INV_SKIPPED > 0 )) && printf ', %d inventory line(s) skipped' "$INV_SKIPPED")"
    run_sweep
    TZ=UTC0 printf -v FINISHED_AT '%(%Y-%m-%dT%H:%M:%SZ)T' -1

    ALL_RESULTS=""
    for SITE in "${SITES[@]}"; do
        DIR="$OUTPUT_DIR/$SITE/$RUN_TS"
        write_manifest "$DIR" "$SITE"
        write_merged_csv "$DIR" "$SITE"
        write_sweep_json "$DIR" "$SITE" "$FINISHED_AT"
        print_site_summary "$DIR" "$SITE"
        ALL_RESULTS+="$(site_results "$SITE")"$'\n'
    done
    RC=$(results_exit_code "$(grep . <<< "$ALL_RESULTS")")
    exit "$RC"
}

# Run only when executed, not when sourced (unit tests source this file)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
