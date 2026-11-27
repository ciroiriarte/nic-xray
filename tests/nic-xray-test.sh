#!/bin/bash
# Unit tests for nic-xray.sh helpers that run without root or hardware.
# nic-xray.sh executes at top level, so the functions under test are loaded on their own.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/nic-xray.sh"
PASS=0
FAIL=0

assert_eq() {  # assert_eq <description> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf '❌ %s\n   expected: %s\n   actual:   %s\n\n' "$1" "$2" "$3"
    fi
}

# Load only the named top-level functions (from "name() {" to the closing "}" in column 0)
load_functions() {
    local F
    for F in "$@"; do
        # shellcheck disable=SC1090
        source <(sed -n "/^${F}() {/,/^}/p" "$SCRIPT")
        declare -F "$F" >/dev/null || { echo "❌ function $F not found in $SCRIPT"; exit 1; }
    done
}

load_functions json_dbm json_dbm_lanes

# --- Optical power values in JSON (#24): ethtool reports 0 mW as -inf ---
assert_eq "dBm negative decimal"  "-2.35" "$(json_dbm -2.35)"
assert_eq "dBm positive decimal"  "1.19"  "$(json_dbm 1.19)"
assert_eq "dBm integer"           "-40"   "$(json_dbm -40)"
assert_eq "dBm zero"              "0.00"  "$(json_dbm 0.00)"
assert_eq "dBm -inf is null"      "null"  "$(json_dbm -inf)"
assert_eq "dBm inf is null"       "null"  "$(json_dbm inf)"
assert_eq "dBm nan is null"       "null"  "$(json_dbm nan)"
assert_eq "dBm N/A is null"       "null"  "$(json_dbm N/A)"
assert_eq "dBm empty is null"     "null"  "$(json_dbm '')"
assert_eq "dBm with unit is null" "null"  "$(json_dbm '-2.35 dBm')"
assert_eq "lanes all numeric"     "[-1.00,-0.41,-0.36,-0.55]" "$(json_dbm_lanes '-1.00:-0.41:-0.36:-0.55')"
assert_eq "lanes with -inf/N/A"   "[-1.00,null,-0.36,null]"   "$(json_dbm_lanes '-1.00:-inf:-0.36:N/A')"
assert_eq "lanes single"          "[null]"                    "$(json_dbm_lanes '-inf')"

# Every optical power value in the JSON writer goes through json_dbm/json_dbm_lanes
JSON_BRANCH=$(sed -n '/OUTPUT_FORMAT}" == "json" \]\]; then/,/OUTPUT_FORMAT" == "dot" \]\]; then/p' "$SCRIPT")
[[ -n "$JSON_BRANCH" ]] || { echo "❌ JSON writer branch not found"; exit 1; }
PRINTS=$(grep -E 'printf.*DATA_OPTICS_(TX|RX)_(DBM|LANES)\[' <<< "$JSON_BRANCH")
assert_eq "JSON writer prints all four power fields" "4" "$(grep -c '' <<< "$PRINTS")"
RAW=$(grep -v -c 'json_dbm' <<< "$PRINTS")
assert_eq "JSON writer prints no raw optical power value" "0" "$RAW"

# A document built the way the writer builds it parses, with null for no light
if command -v python3 &>/dev/null; then
    DOC=$(printf '{"rx_power_dbm": %s, "tx_power_dbm": %s, "rx_lanes_dbm": %s}' \
        "$(json_dbm -inf)" "$(json_dbm -1.08)" "$(json_dbm_lanes '-0.5:-inf:-0.7:-0.6')")
    if python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["rx_power_dbm"] is None and d["tx_power_dbm"] == -1.08 and d["rx_lanes_dbm"][1] is None' "$DOC" 2>/dev/null; then
        (( ++PASS ))
    else
        (( ++FAIL )); echo "❌ optics JSON with no-light values does not parse: $DOC"
    fi
else
    echo "⏭️  SKIP JSON parse test: python3 not found"
fi

# --- Issue #34 ---
# Private scratch directory: fixed /tmp names could be pre-created by another user
TEST_TMP=$(mktemp -d) || { echo "❌ mktemp failed"; exit 1; }
trap 'rm -rf "$TEST_TMP"' EXIT
load_functions optics_lanes_summary optics_lane_variance squeeze_ws fmt_escape dot_id \
    counter_delta bond_slave_perm_mac
OPTICS_DARK_DBM=$(sed -n 's/^OPTICS_DARK_DBM="\(.*\)"$/\1/p' "$SCRIPT")
DOT_ID_CHARS=$(sed -n 's/^DOT_ID_CHARS="\(.*\)"$/\1/p' "$SCRIPT")
[[ -n "$OPTICS_DARK_DBM" && -n "$DOT_ID_CHARS" ]] || { echo "❌ constants not found in $SCRIPT"; exit 1; }

# Multi-lane optics: health is the worst lane, power shown is the lowest lane
# 100GBASE-SR4 Rx thresholds: low alarm -12.0, low warn -10.3, high warn 1.9, high alarm 2.4
SR4=(-12.0 -10.3 1.9 2.4)
check_lanes() {  # check_lanes <label> <awk command...>
    local AWK_LABEL="$1"
    AWK_CMD=("${@:2}")
    # shellcheck disable=SC2329  # used by the functions under test
    awk() { command "${AWK_CMD[@]}" "$@"; }
    assert_eq "$AWK_LABEL: lanes all OK"         "-2.10 OK"    "$(optics_lanes_summary '-1.00:-2.10:-0.50:-1.20' "${SR4[@]}")"
    assert_eq "$AWK_LABEL: one lane over high alarm" "-2.00 ALARM" "$(optics_lanes_summary '3.00:-2.00:-2.00:-2.00' "${SR4[@]}")"
    assert_eq "$AWK_LABEL: one lane over high warn"  "-2.00 WARN"  "$(optics_lanes_summary '2.00:-2.00:-2.00:-2.00' "${SR4[@]}")"
    assert_eq "$AWK_LABEL: one lane under low warn"  "-11.00 WARN" "$(optics_lanes_summary '-1.00:-11.00:-1.00:-1.00' "${SR4[@]}")"
    assert_eq "$AWK_LABEL: dark lane is ALARM"       "-inf ALARM"  "$(optics_lanes_summary '-1.00:-inf:-0.50:-1.20' "${SR4[@]}")"
    assert_eq "$AWK_LABEL: -40 dBm lane is ALARM"    "-40.00 ALARM" "$(optics_lanes_summary '-1.00:-40.00:-0.50:-1.20' "${SR4[@]}")"
    assert_eq "$AWK_LABEL: N/A lanes ignored"        "-1.00 OK"    "$(optics_lanes_summary '-1.00:N/A:N/A:N/A' "${SR4[@]}")"
    assert_eq "$AWK_LABEL: variance ignores dark lane" "" "$(optics_lane_variance '-1.00:-inf:-1.20:-1.10')"
    assert_eq "$AWK_LABEL: variance flags weak lane"  " Ch2↓4dB" "$(optics_lane_variance '-1.00:-5.00:-1.20:-1.10')"
    unset -f awk
}
AWKS=0
for AWK_BIN in gawk mawk busybox original-awk; do
    command -v "$AWK_BIN" &>/dev/null || continue
    if [[ "$AWK_BIN" == busybox ]]; then
        check_lanes busybox-awk busybox awk
    else
        check_lanes "$AWK_BIN" "$AWK_BIN"
    fi
    (( ++AWKS ))
done
(( AWKS > 0 )) || check_lanes awk awk
command -v mawk &>/dev/null || echo "⏭️  SKIP mawk optics tests: mawk not found"

# LLDP values are taken literally (xargs choked on quotes and ran echo on them)
assert_eq "squeeze_ws trims"            "sw-lab01"        "$(printf '  sw-lab01  \n' | squeeze_ws)"
assert_eq "squeeze_ws apostrophe"       "sw-lab'01"       "$(printf "sw-lab'01\n" | squeeze_ws)"
assert_eq "squeeze_ws quotes/backslash" 'to "core" a\b'  "$(printf '%s\n' 'to "core" a\b' | squeeze_ws)"
assert_eq "squeeze_ws echo option"      "-n"              "$(printf -- '-n\n' | squeeze_ws)"
assert_eq "squeeze_ws --version"        "--version"       "$(printf -- '--version\n' | squeeze_ws)"
assert_eq "squeeze_ws joins lines"      "sw1 sw2"         "$(printf 'sw1\n  sw2\n' | squeeze_ws)"
assert_eq "squeeze_ws glob kept"        "spine *"         "$(cd / && printf 'spine *\n' | squeeze_ws)"
assert_eq "squeeze_ws empty"            ""                "$(printf '' | squeeze_ws)"

# Separators are literal inside printf formats
for SEP in '%d' '%s' $'\\' '|' $'\t' '%%' '%n' $'\n'; do
    fmt_escape FMT "$SEP"
    # shellcheck disable=SC2059
    assert_eq "fmt_escape keeps '$SEP' literal" "a${SEP}b" "$(printf "%s${FMT}%s" a b)"
done

# DOT node IDs: distinct names never collide
assert_eq "dot_id keeps alnum"   "eth0"            "$(dot_id eth0)"
assert_eq "dot_id dot"           "eth0_2e_100"     "$(dot_id eth0.100)"
assert_eq "dot_id underscore"    "sw__spine1"      "$(dot_id sw_spine1)"
declare -A SEEN_IDS=()
COLLISIONS=0
for NAME in eth0.100 eth0-100 eth0_100 eth0__100 eth0_2e_100 Eth1/1 Eth1-1 'sw a' sw_a sw__a; do
    ID=$(dot_id "$NAME")
    [[ -n "${SEEN_IDS[$ID]+x}" ]] && (( ++COLLISIONS ))
    SEEN_IDS["$ID"]=1
    [[ "$ID" =~ ^[A-Za-z0-9_]+$ ]] || { (( ++COLLISIONS )); echo "❌ dot_id not a bare DOT ID: $ID"; }
done
assert_eq "dot_id is injective over similar names" "0" "$COLLISIONS"

# DOT/HTML escaping: bash 5.2+ patsub_replacement must not expand & in the replacement
load_functions dot_escape
assert_eq "dot_escape quotes"     'to &quot;core&quot;' "$(dot_escape 'to "core"')"
assert_eq "dot_escape all chars"  '&amp;&lt;&gt;'       "$(dot_escape '&<>')"

# Locale: bash runs UTF-8 for itself, but parsed tools must not inherit any locale
LOCALE_BLOCK=$(sed -n '/^# LOCALE setup/,/^} 2>\/dev\/null$/p' "$SCRIPT")
assert_eq "child sees no locale" "|||" "$(LC_ALL=de_DE.UTF-8 LANG=fr_FR.UTF-8 LC_NUMERIC=de_DE.UTF-8 bash -c "$LOCALE_BLOCK"$'\n''bash -c '"'"'printf %s "$LANG|$LC_ALL|$LC_NUMERIC|$LANGUAGE"'"'"'')"

# ...and bash's own locale stays UTF-8 (one column per icon), also under the caller's
# LC_ALL=C and on hosts without en_US.UTF-8 (simulated with a locale that never exists)
# shellcheck disable=SC2016  # expanded by the child bash
WIDTH_CHECK=$'\n''printf %s "${#LOCALE_PROBE}"'
assert_eq "bash width under LC_ALL=C" "1" "$(env -i LC_ALL=C bash -c "$LOCALE_BLOCK$WIDTH_CHECK")"
NO_EN_US="${LOCALE_BLOCK/LOCALE_PREFERRED=\"en_US.UTF-8\"/LOCALE_PREFERRED=\"xx_XX.UTF-8\"}"
[[ "$NO_EN_US" != "$LOCALE_BLOCK" ]] || echo "❌ LOCALE_PREFERRED not found in $SCRIPT"
assert_eq "bash width without en_US"  "1" "$(env -i LANG=C.UTF-8 bash -c "$NO_EN_US$WIDTH_CHECK")"
assert_eq "bash width, empty env, no en_US" "1" "$(env -i bash -c "$NO_EN_US$WIDTH_CHECK")"

# Empty separator after escape interpretation is rejected
assert_eq "empty separator rejected" 'Invalid separator: it is empty after interpreting escapes (\0, \c).' "$(bash "$SCRIPT" -s'\c' 2>&1)"

# Counter deltas: clamped, and interface names are never evaluated
# shellcheck disable=SC2034  # read through namerefs by counter_delta
declare -A T1=() T2=()
T1[eth0]=100; T2[eth0]=350
T1[wrap]=500; T2[wrap]=20
# shellcheck disable=SC2016  # the name must stay unexpanded: it is the payload
EVIL='x$(touch "$PWNED")'
PWNED="$TEST_TMP/pwned"
export PWNED
# shellcheck disable=SC2034  # read through namerefs by counter_delta
T1["$EVIL"]=1
# shellcheck disable=SC2034
T2["$EVIL"]=5
counter_delta D T1 T2 eth0;    assert_eq "counter_delta basic" "250" "$D"
counter_delta D T1 T2 wrap;    assert_eq "counter_delta wrap clamps" "0" "$D"
counter_delta D T1 T2 missing; assert_eq "counter_delta missing" "0" "$D"
counter_delta D T1 T2 "$EVIL"; assert_eq "counter_delta odd name" "4" "$D"
assert_eq "counter_delta never runs a name as code" "no" "$([[ -e "$PWNED" ]] && echo yes || echo no)"
rm -f "$PWNED"
# Unsigned 64-bit counters: crossing 2^63 still gives the right difference
# shellcheck disable=SC2034  # read through namerefs by counter_delta
T1[big]=9223372036854775800
# shellcheck disable=SC2034
T2[big]=9223372036854775900
counter_delta D T1 T2 big;     assert_eq "counter_delta across 2^63" "100" "$D"
assert_eq "read_iface_stats has no eval" "0" "$(sed -n '/^read_iface_stats() {/,/^}/p' "$SCRIPT" | grep -cE '^[[:space:]]*eval[[:space:]]')"

# Bond slave permanent MAC: exact slave name, not a prefix
BOND_FILE="$TEST_TMP/bond"
cat > "$BOND_FILE" <<'BOND'
Bonding Mode: IEEE 802.3ad Dynamic link aggregation

Slave Interface: eth10
MII Status: up
Permanent HW addr: aa:aa:aa:aa:aa:10

Slave Interface: eth1
MII Status: up
Permanent HW addr: aa:aa:aa:aa:aa:01

Slave Interface: eth2
MII Status: up
BOND
assert_eq "bond MAC exact slave"        "aa:aa:aa:aa:aa:01" "$(bond_slave_perm_mac "$BOND_FILE" eth1)"
assert_eq "bond MAC other slave"        "aa:aa:aa:aa:aa:10" "$(bond_slave_perm_mac "$BOND_FILE" eth10)"
assert_eq "bond MAC no line → empty"    ""                  "$(bond_slave_perm_mac "$BOND_FILE" eth2)"
assert_eq "bond MAC unknown slave"      ""                  "$(bond_slave_perm_mac "$BOND_FILE" eth)"
rm -f "$BOND_FILE"

# Unusable lane readings are not reported as a healthy 0 dBm
assert_eq "lanes with no usable reading" "N/A N/A" "$(optics_lanes_summary 'nan:N/A:N/A:N/A' "${SR4[@]}")"
# Single-lane optics: no light is ALARM whatever the thresholds
load_functions evaluate_optics_health
assert_eq "single lane -inf is ALARM"   "ALARM" "$(evaluate_optics_health -inf "${SR4[@]}")"
assert_eq "single lane -40 is ALARM"    "ALARM" "$(evaluate_optics_health -40.00 -50 -50 5 5)"
assert_eq "single lane in range is OK"  "OK"    "$(evaluate_optics_health -2.00 "${SR4[@]}")"

# Separators in real rows: a table gap and a CSV row built the way the writers build them
# shellcheck disable=SC2016  # a sed address, not a shell expansion
COL_GAP_BLOCK=$(sed -n '/^# --- Column Gap ---$/,/^fmt_escape COL_GAP/p' "$SCRIPT")
[[ -n "$COL_GAP_BLOCK" ]] || { echo "❌ column gap block not found"; exit 1; }
for FIELD_SEP in '%d' '|' $'\t' $'\n' ''; do
    eval "$COL_GAP_BLOCK"
    # shellcheck disable=SC2059
    ROW=$(printf "%-4s${COL_GAP}%s" eth0 up)
    EXPECT_GAP="${FIELD_SEP:+ $FIELD_SEP }"; EXPECT_GAP="${EXPECT_GAP:-   }"
    assert_eq "table row with separator '$FIELD_SEP'" "eth0${EXPECT_GAP}up" "$ROW"
    assert_eq "plain gap matches width for '$FIELD_SEP'" "$COL_GAP_WIDTH" "${#COL_GAP_TEXT}"
done

# A run that matches no interface still gives parseable JSON and CSV
load_functions print_csv_header render_empty_output
# shellcheck disable=SC2034  # read by the functions under test
SHOW_VIRTUAL=false SHOW_PHYSICAL=false SHOW_BMAC=false SHOW_LACP=false SHOW_VLAN=false
# shellcheck disable=SC2034
SHOW_OPTICS=false SHOW_METRICS=false
FIELD_SEP=""
OUTPUT_FORMAT=json; assert_eq "no match: JSON is []" "[]" "$(render_empty_output 2>/dev/null)"
OUTPUT_FORMAT=csv
HDR=$(render_empty_output 2>/dev/null)
assert_eq "no match: CSV is the header row only" "1" "$(grep -c '' <<< "$HDR")"
assert_eq "no match: CSV header starts with Device" "Device,Driver" "${HDR:0:13}"
FIELD_SEP='%s'; HDR=$(render_empty_output 2>/dev/null)
assert_eq "no match: CSV header keeps a % separator literal" "Device%sDriver" "${HDR:0:14}"
FIELD_SEP=$'\n'; HDR=$(render_empty_output 2>/dev/null)
assert_eq "no match: CSV header keeps a newline separator" $'Device\nDriver' "${HDR:0:13}"
FIELD_SEP=""
# shellcheck disable=SC2034
OUTPUT_FORMAT=table
assert_eq "no match: table prints nothing on stdout" "" "$(render_empty_output 2>/dev/null)"
assert_eq "no match: message on stderr" "No matching network interfaces found." "$(render_empty_output 2>&1 >/dev/null)"

echo
if (( FAIL > 0 )); then
    echo "❌ $FAIL failed, $PASS passed"
    exit 1
fi
echo "✅ All $PASS tests passed"
