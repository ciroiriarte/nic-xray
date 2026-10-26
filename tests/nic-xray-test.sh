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

echo
if (( FAIL > 0 )); then
    echo "❌ $FAIL failed, $PASS passed"
    exit 1
fi
echo "✅ All $PASS tests passed"
