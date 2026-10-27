#!/bin/bash
#
# Unit tests for nic-health.sh
# Builds a fake sysfs tree and stubs ethtool/devlink, so it needs neither
# root nor NIC hardware. Usage: bash tests/nic-health-test.sh (or: make test)

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TEST_DIR/../nic-health.sh"

# shellcheck source-path=SCRIPTDIR source=../nic-health.sh
source "$SCRIPT"

PASS=0
FAIL=0
FIX=$(mktemp -d "${TMPDIR:-/tmp}/nic-health-test.XXXXXX")
trap 'rm -rf -- "$FIX"' EXIT

assert_eq() {  # assert_eq <description> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf '❌ %s\n   expected: %s\n   actual:   %s\n' "$1" "$2" "$3"
    fi
}

# Severity of the first record matching check_id and target
sev_of() {
    local i
    for i in "${!REC_SEV[@]}"; do
        [[ "${REC_CHECK[i]}" == "$1" && "${REC_TARGET[i]}" == "$2" ]] && { printf '%s' "${REC_SEV[i]}"; return; }
    done
    printf 'MISSING'
}

count_of() {  # count_of <check_id> <target>
    local i n=0
    for i in "${!REC_SEV[@]}"; do
        [[ "${REC_CHECK[i]}" == "$1" && "${REC_TARGET[i]}" == "$2" ]] && (( ++n ))
    done
    printf '%d' "$n"
}

reset_results() {
    REC_SCOPE=(); REC_TARGET=(); REC_CHECK=(); REC_VALUE=(); REC_UNIT=()
    REC_THRESHOLD=(); REC_SEV=(); REC_EVIDENCE=(); REC_HINT=(); REC_REF=(); REC_METRICS=()
    ADDR_STATE=""       # addresses are read once per run: every test case is a new run
}

# Typed metrics (JSON object members) of the first record matching check_id and target
metrics_of() {
    local i
    for i in "${!REC_SEV[@]}"; do
        [[ "${REC_CHECK[i]}" == "$1" && "${REC_TARGET[i]}" == "$2" ]] && { printf '%s' "${REC_METRICS[i]:-}"; return; }
    done
}

# JSON fixtures for nic-report (tests/fixtures/nic-health-json/, README there): render_json of
# scenarios below, from mocks only. Every run writes them to JSON_OUT and compares them with the
# checked-in copies at the end; NIC_HEALTH_UPDATE_FIXTURES=1 (make fixtures) rewrites the copies
JSON_FIXTURES="$TEST_DIR/fixtures/nic-health-json"
JSON_OUT="$FIX/json"
mkdir -p "$JSON_OUT"
dump_json() {  # dump_json <name>: the current records as nic-health JSON, host-independent
    local OUT RE
    OUT=$(compute_verdict; HOSTNAME="server-01.example.net" COLLECTED_AT="2026-10-26T12:00:00Z" HOST_UPTIME_S=1987654 \
        HOST_BOOT_ID="3f2a6c1e-8b4d-4e7f-9a10-5c6d7e8f9a0b" render_json)
    # bash's own read error text names the script path and a line number, and varies by version
    RE='; read: [^"]*nic-health\.sh[^"]*"'
    while [[ "$OUT" =~ $RE ]]; do OUT="${OUT//"${BASH_REMATCH[0]}"/; read: (bash read error)\"}"; done
    printf '%s\n' "$OUT" > "$JSON_OUT/$1.json"
}

# render_json is strict JSON with schema_version 2, every metrics value an object, and no
# non-finite number anywhere (python3, else jq; skipped without either)
json_strict_check() {  # json_strict_check <description>
    local OUT
    OUT=$(render_json)
    if command -v python3 &>/dev/null; then
        if python3 -I -c '
import json, math, sys
def bad(c):
    raise ValueError(c)
d = json.loads(sys.stdin.read(), parse_constant=bad)
def finite(v):
    if isinstance(v, float):
        assert math.isfinite(v)
    for x in (v.values() if isinstance(v, dict) else v if isinstance(v, list) else ()):
        finite(x)
finite(d)
assert d["schema_version"] == 2
assert all(isinstance(r.get("metrics", {}), dict) for r in d["results"])
' <<< "$OUT" 2>/dev/null; then (( ++PASS )); else (( ++FAIL )); echo "❌ $1: render_json is not strict schema-2 JSON"; fi
    elif command -v jq &>/dev/null; then
        if [[ "$(jq -r '.schema_version == 2 and ([.. | numbers | select(isinfinite or isnan)] | length == 0) and all(.results[]; (.metrics // {}) | type == "object")' <<< "$OUT" 2>/dev/null)" == "true" ]]; then
            (( ++PASS )); else (( ++FAIL )); echo "❌ $1: render_json is not strict schema-2 JSON"; fi
    else
        echo "⏭️  SKIP $1: neither python3 nor jq found"
    fi
}

# --- Pure helpers ---

assert_eq "bounded_uint leading zeros" "60" "$(bounded_uint 0060 1440)"
assert_eq "bounded_uint zero" "0" "$(bounded_uint 000 1440)"
assert_eq "bounded_uint at max" "1440" "$(bounded_uint 1440 1440)"
assert_eq "bounded_uint over max" "fail" "$(bounded_uint 1441 1440 || echo fail)"
assert_eq "bounded_uint huge (no wrap)" "fail" "$(bounded_uint 18446744073709551621 3600 || echo fail)"
assert_eq "bounded_uint non-digit" "fail" "$(bounded_uint -5 3600 || echo fail)"

assert_eq "pcie speed 16.0" "160" "$(pcie_speed_tenths "16.0 GT/s PCIe")"
assert_eq "pcie speed 2.5"  "25"  "$(pcie_speed_tenths "2.5 GT/s PCIe")"
assert_eq "pcie speed 8 (no decimal)" "80" "$(pcie_speed_tenths "8 GT/s")"
assert_eq "pcie speed Unknown" "" "$(pcie_speed_tenths "Unknown")"

printf '4844149.08 306790526.43\n' > "$FIX/uptime"
PROC_UPTIME="$FIX/uptime"
assert_eq "uptime centiseconds" "484414908" "$(uptime_cs)"

assert_eq "json_escape control chars" 'a\"b\\c\nd\u001be' "$(json_escape $'a"b\\c\nd\x1be')"

# Typed metrics helpers (JSON numbers copied from text after a strict check)
jn() { JSON_NUM=""; "$@" || { printf 'fail'; return; }; printf '%s' "$JSON_NUM"; }
assert_eq "json_uint leading zeros" "120" "$(jn json_uint 000120)"
assert_eq "json_uint zero" "0" "$(jn json_uint 000)"
assert_eq "json_uint 20 digits" "18446744073709551615" "$(jn json_uint 18446744073709551615)"
assert_eq "json_uint 21 digits refused" "fail" "$(jn json_uint 184467440737095516150)"
assert_eq "json_uint sign refused" "fail" "$(jn json_uint -1)"
assert_eq "json_decimal negative" "-0.079" "$(jn json_decimal -0.079)"
assert_eq "json_decimal leading zeros" "7.50" "$(jn json_decimal 007.50)"
assert_eq "json_decimal -0 keeps its sign" "-0.0" "$(jn json_decimal -0)"
for BAD in "" "?" "1." ".5" "1e5" "nan" "inf" "-" "1,2" "0x10"; do
    assert_eq "json_decimal refuses '$BAD'" "fail" "$(jn json_decimal "$BAD")"
done
assert_eq "json_sci tool BER" "15e-255" "$(jn json_sci 15E-255)"
assert_eq "json_sci fmt_sci output" "1.2e-8" "$(jn json_sci 1.2e-08)"
assert_eq "json_sci zero" "0e0" "$(jn json_sci 0E0)"
assert_eq "json_sci plus exponent" "5e10" "$(jn json_sci 5E+10)"
assert_eq "json_sci overflow refused" "fail" "$(jn json_sci 1E400)"
assert_eq "json_sci near-overflow refused" "fail" "$(jn json_sci 99E299)"
assert_eq "json_sci N/A refused" "fail" "$(jn json_sci N/A)"
mt() { local METRICS=""; "$@"; printf '%s' "$METRICS"; }
assert_eq "metric_counter with delta" '"c": {"total": 12, "delta": 3}' "$(mt metric_counter c 0012 3)"
assert_eq "metric_counter absolute" '"c": {"total": 12}' "$(mt metric_counter c 12)"
assert_eq "metric_counter not a counter: left out" "" "$(mt metric_counter c '?' 3)"
assert_eq "metric_list decimals" '"l": [-1.445, -0.405]' "$(mt metric_list l "-1.445,-0.405" json_decimal)"
assert_eq "metric_list one bad item: left out" "" "$(mt metric_list l "1,x,3" json_uint)"
assert_eq "metric_milli exact" '"t": 54.5' "$(mt metric_milli t 54500)"
assert_eq "metric_milli integer" '"t": 67' "$(mt metric_milli t 67000)"
assert_eq "metric_milli negative" '"t": -5.25' "$(mt metric_milli t -5250)"
assert_eq "metric_milli empty: left out" "" "$(mt metric_milli t "")"
assert_eq "metric_str N/A and empty left out" "" "$(mt metric_str a "N/A"; mt metric_str b "")"
assert_eq "metric_str escaped" '"s": "a\"b"' "$(mt metric_str s 'a"b')"
assert_eq "metric_bool" '"x": true, "y": false' "$(mt eval 'metric_bool x true; metric_bool y false')"
assert_eq "metric_tenths" '"s": 16.0' "$(mt metric_tenths s 160)"
assert_eq "milli_to_c" "67" "$(milli_to_c 67999)"

SNAP0=(["a"]=10 ["b"]=10 ["c"]=x)
SNAP1=(["a"]=15 ["b"]=3 ["c"]=4)
RC=0; delta a || RC=$?; assert_eq "delta growth rc" "0" "$RC"; assert_eq "delta growth" "5" "$DELTA"
RC=0; delta b || RC=$?; assert_eq "delta reset rc" "2" "$RC"
RC=0; delta c || RC=$?; assert_eq "delta non-numeric rc" "1" "$RC"
RC=0; delta zz || RC=$?; assert_eq "delta missing rc" "1" "$RC"

# --- devlink parsers ---

declare -A DLT=()
DLT_ORDER=()
parse_devlink_health DLT DLT_ORDER <<'EOF'
pci/0000:41:00.0:
  reporter fw
    state healthy error 0 recover 0 auto_dump true
  reporter fw_fatal
    state error error 2 recover 1 grace_period 60000 auto_recover true auto_dump true
auxiliary/mlx5_core.eth.0/65535:
  reporter tx
    state healthy error 0 recover 0 grace_period 500 auto_recover true auto_dump true
pci/0000:05:00.0:
  name tx
    state healthy error 3 recover 3 grace_period 500 auto_recover true
EOF
assert_eq "devlink order" "pci/0000:41:00.0|fw pci/0000:41:00.0|fw_fatal auxiliary/mlx5_core.eth.0/65535|tx pci/0000:05:00.0|tx" "${DLT_ORDER[*]}"
assert_eq "devlink fw_fatal state" "error" "${DLT["dl|pci/0000:41:00.0|fw_fatal|state"]}"
assert_eq "devlink fw_fatal error" "2" "${DLT["dl|pci/0000:41:00.0|fw_fatal|error"]}"
assert_eq "devlink recover not auto_recover" "1" "${DLT["dl|pci/0000:41:00.0|fw_fatal|recover"]}"
assert_eq "devlink old 'name' layout" "3" "${DLT["dl|pci/0000:05:00.0|tx|error"]}"

parse_devlink_ports <<'EOF'
auxiliary/mlx5_core.eth.0/65535: type eth netdev ens4f0np0 flavour physical port 0 splittable false
pci/0000:05:00.0/0: type eth netdev ens6f0 flavour physical port 0 splittable false
EOF
assert_eq "devlink port mlx5 auxiliary" "ens4f0np0" "${DL_PORT_NETDEV[auxiliary/mlx5_core.eth.0/65535]}"
assert_eq "devlink port pci" "ens6f0" "${DL_PORT_NETDEV[pci/0000:05:00.0/0]}"

# --- Fake sysfs: three ASICs, one USB NIC ---
#   0000:01:00  mlx5-like, 2 ports (eth0, eth1), hwmon on both functions
#   0000:02:00  sfc-like, 1 port (eth2): max below crit
#   0000:03:00  ixgbe-like, 1 port (eth3): max above crit, no devlink reporters
#   usb0        non-PCI

SYSFS_NET="$FIX/class/net"
SYSFS_PCI="$FIX/bus/pci/devices"
mkdir -p "$SYSFS_NET" "$SYSFS_PCI" "$FIX/bus/pci_sub/pci" "$FIX/bus/usb_sub/usb" "$FIX/drivers/mlx5_core" "$FIX/drivers/sfc" "$FIX/drivers/ixgbe" "$FIX/usbdev"
ln -s "$FIX/bus/usb_sub/usb" "$FIX/usbdev/subsystem"

aer_write() {  # aer_write <bdf> <cor> <nonfatal> <fatal>
    printf 'RxErr 0\nBadTLP 0\nTOTAL_ERR_COR %s\n' "$2" > "$SYSFS_PCI/$1/aer_dev_correctable"
    printf 'DLP 0\nTOTAL_ERR_NONFATAL %s\n' "$3" > "$SYSFS_PCI/$1/aer_dev_nonfatal"
    printf 'DLP 0\nTOTAL_ERR_FATAL %s\n' "$4" > "$SYSFS_PCI/$1/aer_dev_fatal"
}
hwmon_write() {  # hwmon_write <bdf> <hwmon> <n> <label> <input> <crit> [max]
    local HWDIR="$SYSFS_PCI/$1/hwmon/$2"
    mkdir -p "$HWDIR"
    printf '%s\n' "$4" > "$HWDIR/temp${3}_label"
    printf '%s\n' "$5" > "$HWDIR/temp${3}_input"
    printf '%s\n' "$6" > "$HWDIR/temp${3}_crit"
    [[ -n "${7:-}" ]] && printf '%s\n' "$7" > "$HWDIR/temp${3}_max"
    return 0
}
mk_port() {  # mk_port <iface> <bdf> <driver> <speed> <width> <maxspeed> <maxwidth>
    local B="$SYSFS_PCI/$2"
    mkdir -p "$B" "$SYSFS_NET/$1"
    ln -s "$FIX/bus/pci_sub/pci" "$B/subsystem"
    ln -s "$FIX/drivers/$3" "$B/driver"
    printf '0x15b3\n' > "$B/vendor"
    printf '0x101f\n' > "$B/device"
    printf '%s\n' "$4" > "$B/current_link_speed"
    printf '%s\n' "$5" > "$B/current_link_width"
    printf '%s\n' "$6" > "$B/max_link_speed"
    printf '%s\n' "$7" > "$B/max_link_width"
    ln -s "$B" "$SYSFS_NET/$1/device"
    printf 'up\n' > "$SYSFS_NET/$1/operstate"
    printf '2\n' > "$SYSFS_NET/$1/carrier_changes"
}

mk_port eth0 0000:01:00.0 mlx5_core "16.0 GT/s PCIe" 8 "16.0 GT/s PCIe" 8
mk_port eth1 0000:01:00.1 mlx5_core "16.0 GT/s PCIe" 8 "16.0 GT/s PCIe" 8
mk_port eth2 0000:02:00.0 sfc "8.0 GT/s PCIe" 4 "8.0 GT/s PCIe" 8
mk_port eth3 0000:03:00.0 ixgbe "5.0 GT/s PCIe" 8 "5.0 GT/s PCIe" 8
mkdir -p "$SYSFS_NET/usb0"
ln -s "$FIX/usbdev" "$SYSFS_NET/usb0/device"
mkdir -p "$SYSFS_NET/lo"

aer_write 0000:01:00.0 0 0 0
aer_write 0000:01:00.1 1 0 0
aer_write 0000:03:00.0 0 0 0
# 0000:02:00 has no AER attributes (CONFIG_PCIEAER off)

hwmon_write 0000:01:00.0 hwmon0 1 asic 67000 105000
hwmon_write 0000:01:00.0 hwmon0 2 Module0 99000 85000
hwmon_write 0000:01:00.1 hwmon1 1 asic 67500 105000
hwmon_write 0000:01:00.1 hwmon1 2 Module1 46000 85000
hwmon_write 0000:02:00.0 hwmon2 1 "Controller board temp." 72000 85000 70000
hwmon_write 0000:03:00.0 hwmon3 1 loc2 88000 95000 105000
# Broken sensor: input is unreadable (a directory gives a non-EBUSY read error)
mkdir -p "$SYSFS_PCI/0000:03:00.0/hwmon/hwmon3/temp2_input"
printf 'broken\n' > "$SYSFS_PCI/0000:03:00.0/hwmon/hwmon3/temp2_label"

cat > "$FIX/devlink_ports" <<'EOF'
auxiliary/mlx5_core.eth.0/65535: type eth netdev eth0 flavour physical port 0 splittable false
auxiliary/mlx5_core.eth.1/131071: type eth netdev eth1 flavour physical port 1 splittable false
pci/0000:03:00.0/0: type eth netdev eth3 flavour physical port 0 splittable false
EOF
devlink_health_write() {  # devlink_health_write <fw_error> <fw_fatal_state>
    cat > "$FIX/devlink_health" <<EOF
pci/0000:01:00.0:
  reporter fw
    state healthy error $1 recover $1 auto_dump true
  reporter fw_fatal
    state $2 error 0 recover 0 grace_period 60000 auto_recover true auto_dump true
auxiliary/mlx5_core.eth.0/65535:
  reporter tx
    state healthy error 0 recover 0 grace_period 500 auto_recover true auto_dump true
pci/0000:99:00.0:
  reporter fw
    state error error 9 recover 0
EOF
}
devlink_health_write 0 healthy

# Command stubs (shell functions take precedence over PATH)
ethtool() {
    if [[ "$1" == "--show-fec" ]]; then
        [[ -e "$FIX/fec_$2" ]] && cat "$FIX/fec_$2"
        return 0
    fi
    if [[ "$1" == "-S" ]]; then
        [[ -e "$FIX/ets_$2" ]] || { echo "no stats available" >&2; return 1; }
        cat "$FIX/ets_$2"
        return 0
    fi
    if [[ "$1" == "-i" ]]; then
        printf 'driver: stub\nfirmware-version: 1.2.3 (STUB)\nbus-info: x\n'
        return 0
    fi
    # Plain "ethtool IFACE": link settings, with a Lanes line when the fixture provides one
    printf 'Settings for %s:\n\tSpeed: 25000Mb/s\n' "$1"
    [[ -e "$FIX/lanes_$1" ]] && printf '\tLanes: %s\n' "$(< "$FIX/lanes_$1")"
    printf '\tLink detected: yes\n'
}
devlink() {
    case "$1 $2" in
        "health show") cat "$FIX/devlink_health" ;;
        "port show")   cat "$FIX/devlink_ports" ;;
    esac
}
TOOL_PATH=(["ethtool"]=stub ["getopt"]=stub ["readlink"]=stub ["lspci"]="" ["devlink"]=stub ["mlxlink"]="" ["mstlink"]="")

# --- Discovery ---
discover
assert_eq "ASICs grouped and sorted" "0000:01:00 0000:02:00 0000:03:00" "${ASIC_IDS[*]}"
assert_eq "ports of mlx5 ASIC" "0 1" "${ASIC_PORTS[0000:01:00]}"
assert_eq "driver from sysfs" "mlx5_core" "${ASIC_DRIVER[0000:01:00]}"
assert_eq "firmware from ethtool -i" "1.2.3 (STUB)" "${ASIC_FW[0000:01:00]}"
assert_eq "model falls back to PCI IDs" "PCI 15b3:101f" "${ASIC_MODEL[0000:01:00]}"
assert_eq "USB NIC reported N/A" "N/A" "$(sev_of discovery.bus usb0)"
assert_eq "asic functions" "0000:01:00.0 0000:01:00.1" "$(asic_functions 0000:01:00 | tr '\n' ' ' | sed 's/ $//')"
parse_devlink_ports < "$FIX/devlink_ports"

# --- Delta mode: T0, then counters move, then T1 ---
INTERVAL=5
printf '100.00 0\n' > "$FIX/uptime"
snapshot SNAP0 DL_SCRATCH
aer_write 0000:01:00.1 3 0 0            # +2 correctable on the mlx5 ASIC
aer_write 0000:03:00.0 0 1 0            # +1 nonfatal on the ixgbe ASIC
printf '4\n' > "$SYSFS_NET/eth1/carrier_changes"   # +2 transitions
printf '0\n' > "$SYSFS_NET/eth3/carrier_changes"   # reset (2 -> 0)
devlink_health_write 1 error            # fw +1 error, fw_fatal unhealthy
printf '105.01 0\n' > "$FIX/uptime"
snapshot SNAP1 DL_ORDER
ELAPSED_CS=$(( SNAP1["time"] - SNAP0["time"] ))
assert_eq "elapsed window" "5.01" "$(elapsed_str)"

run_checks

assert_eq "pcie link OK at max"            "OK"      "$(sev_of generic.pcie.link 0000:01:00)"
assert_eq "pcie link x4 of x8 WARN"        "WARN"    "$(sev_of generic.pcie.link 0000:02:00)"
assert_eq "AER correctable growth WARN"    "WARN"    "$(sev_of generic.pcie.aer 0000:01:00)"
assert_eq "AER absent N/A"                 "N/A"     "$(sev_of generic.pcie.aer 0000:02:00)"
assert_eq "AER nonfatal growth CRIT"       "CRIT"    "$(sev_of generic.pcie.aer 0000:03:00)"
assert_eq "temp asic OK"                   "OK"      "$(sev_of generic.temperature "0000:01:00 (asic)")"
assert_eq "temp asic deduplicated"         "1"       "$(count_of generic.temperature "0000:01:00 (asic)")"
assert_eq "temp module over crit CRIT"     "CRIT"    "$(sev_of generic.temperature "0000:01:00 (Module0)")"
assert_eq "temp module1 OK"                "OK"      "$(sev_of generic.temperature "0000:01:00 (Module1)")"
assert_eq "temp above max (max<crit) WARN" "WARN"    "$(sev_of generic.temperature "0000:02:00 (Controller board temp.)")"
assert_eq "temp max>crit ignored, margin WARN" "WARN" "$(sev_of generic.temperature "0000:03:00 (loc2)")"
assert_eq "temp unreadable (non-EBUSY) UNKNOWN" "UNKNOWN" "$(sev_of generic.temperature "0000:03:00 (broken)")"
assert_eq "flaps unchanged OK"             "OK"      "$(sev_of generic.link.flaps eth0)"
assert_eq "flaps growth WARN"              "WARN"    "$(sev_of generic.link.flaps eth1)"
assert_eq "flaps counter reset UNKNOWN"    "UNKNOWN" "$(sev_of generic.link.flaps eth3)"
assert_eq "devlink fw error growth WARN"   "WARN"    "$(sev_of generic.devlink.health.fw 0000:01:00.0)"
assert_eq "devlink fw_fatal unhealthy CRIT" "CRIT"   "$(sev_of generic.devlink.health.fw_fatal 0000:01:00.0)"
assert_eq "devlink port reporter mapped"   "OK"      "$(sev_of generic.devlink.health.tx eth0)"
assert_eq "devlink foreign device ignored" "MISSING" "$(sev_of generic.devlink.health.fw 0000:99:00.0)"
assert_eq "devlink no reporters N/A"       "N/A"     "$(sev_of generic.devlink.health 0000:02:00)"

compute_verdict
assert_eq "verdict CRIT wins" "CRIT 2" "$VERDICT $EXIT_CODE"
dump_json delta-generic

# Typed metrics (JSON only, nic-sweep design P2): typed values, absent ones left out, none on records
# that measured nothing
assert_eq "metrics pcie link OK" '"speed_gts": 16.0, "width": 8, "max_speed_gts": 16.0, "max_width": 8, "expected_speed_gts": 16.0, "expected_width": 8, "slot_limited": false, "below_capability": false' \
    "$(metrics_of generic.pcie.link 0000:01:00)"
assert_eq "metrics pcie link below capability" '"speed_gts": 8.0, "width": 4, "max_speed_gts": 8.0, "max_width": 8, "expected_speed_gts": 8.0, "expected_width": 8, "slot_limited": false, "below_capability": true' \
    "$(metrics_of generic.pcie.link 0000:02:00)"
assert_eq "metrics AER summed over functions" '"cor": {"total": 3, "delta": 2}, "nonfatal": {"total": 0, "delta": 0}, "fatal": {"total": 0, "delta": 0}' \
    "$(metrics_of generic.pcie.aer 0000:01:00)"
assert_eq "metrics AER absent: none" "" "$(metrics_of generic.pcie.aer 0000:02:00)"
assert_eq "metrics temperature" '"label": "Module0", "temp_c": 99, "warn_c": 75, "crit_c": 85' "$(metrics_of generic.temperature "0000:01:00 (Module0)")"
assert_eq "metrics temperature with max" '"label": "Controller board temp.", "temp_c": 72, "warn_c": 70, "crit_c": 85, "max_c": 70' \
    "$(metrics_of generic.temperature "0000:02:00 (Controller board temp.)")"
assert_eq "metrics temperature unreadable: none" "" "$(metrics_of generic.temperature "0000:03:00 (broken)")"
assert_eq "metrics flaps unchanged" '"carrier_changes": {"total": 2, "delta": 0}' "$(metrics_of generic.link.flaps eth0)"
assert_eq "metrics flaps growth" '"carrier_changes": {"total": 4, "delta": 2}' "$(metrics_of generic.link.flaps eth1)"
assert_eq "metrics flaps reset (UNKNOWN): none" "" "$(metrics_of generic.link.flaps eth3)"
assert_eq "metrics evidence unchanged (flaps growth)" "carrier_changes T0=2 T1=4" "$(for i in "${!REC_SEV[@]}"; do [[ "${REC_CHECK[i]}" == generic.link.flaps && "${REC_TARGET[i]}" == eth1 ]] && printf '%s' "${REC_EVIDENCE[i]}"; done)"
assert_eq "metrics not in CSV" "0" "$(render_csv | grep -c '"total"')"
assert_eq "metrics not in the table" "0" "$(SHOW_ALL=true; render_table | grep -c 'total')"
COLLECTED_AT="2026-10-20T00:00:00Z"
json_strict_check "delta mode JSON"
assert_eq "json metrics member follows ref" "1" "$(render_json | grep -c '"check_id": "generic.link.flaps", "value": "+2", .*"ref": "[^"]*", "metrics": {"carrier_changes": {"total": 4, "delta": 2}}}')"

if command -v python3 &>/dev/null; then
    COLLECTED_AT="2026-10-20T00:00:00Z"
    if render_json | python3 -I -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
        (( ++PASS ))
    else
        (( ++FAIL )); echo "❌ render_json produced invalid JSON"
    fi
else
    echo "⏭️  SKIP JSON validity test: python3 not found"
fi
assert_eq "CSV rows = records + header" "$(( ${#REC_SEV[@]} + 1 ))" "$(render_csv | wc -l | tr -d ' ')"

# --- Absolute mode: totals are historical, CRIT capped at WARN ---
reset_results
INTERVAL=0
aer_write 0000:03:00.0 0 0 4
devlink_health_write 5 healthy
DL_ORDER=()
snapshot SNAP1 DL_ORDER
run_checks
assert_eq "absolute AER fatal capped WARN"  "WARN" "$(sev_of generic.pcie.aer 0000:03:00)"
assert_eq "absolute devlink errors WARN"    "WARN" "$(sev_of generic.devlink.health.fw 0000:01:00.0)"
assert_eq "absolute flaps informational OK" "OK"   "$(sev_of generic.link.flaps eth1)"
dump_json absolute-generic
assert_eq "absolute metrics: totals, no delta" '"carrier_changes": {"total": 4}' "$(metrics_of generic.link.flaps eth1)"
assert_eq "absolute AER metrics: totals, no delta" '"cor": {"total": 0}, "nonfatal": {"total": 0}, "fatal": {"total": 4}' "$(metrics_of generic.pcie.aer 0000:03:00)"

# --- devlink missing ---
reset_results
TOOL_PATH[devlink]=""
check_devlink
assert_eq "devlink missing N/A" "N/A" "$(sev_of generic.devlink.health 0000:01:00)"

# --- Review regressions (delta mode) ---
INTERVAL=5
TOOL_PATH[devlink]=stub
snap_pair() {  # snap_pair: T0 snapshot, run the given mutation command, T1 snapshot, run checks
    reset_results
    DL_SCRATCH=(); DL_ORDER=()
    printf '200.00 0\n' > "$FIX/uptime"
    snapshot SNAP0 DL_SCRATCH
    "$@"
    printf '205.00 0\n' > "$FIX/uptime"
    snapshot SNAP1 DL_ORDER
}

# A reset on one function must not be hidden by growth on another
aer_write 0000:01:00.0 100 0 0
aer_write 0000:01:00.1 0 0 0
mix_reset() { aer_write 0000:01:00.0 0 0 0; aer_write 0000:01:00.1 200 0 0; }
snap_pair mix_reset
check_pcie_aer 0000:01:00
assert_eq "AER reset on one function + growth on other UNKNOWN" "UNKNOWN" "$(sev_of generic.pcie.aer 0000:01:00)"

# AER files and carrier_changes vanishing during the window
aer_write 0000:01:00.0 0 0 0
vanish() { rm -f "$SYSFS_PCI"/0000:01:00.0/aer_dev_*; mv "$SYSFS_NET/eth0/carrier_changes" "$FIX/cc.bak"; }
snap_pair vanish
check_pcie_aer 0000:01:00
check_link_flaps "${IFACE_PORT[eth0]}"
assert_eq "AER source vanished UNKNOWN"    "UNKNOWN" "$(sev_of generic.pcie.aer 0000:01:00)"
assert_eq "carrier_changes vanished UNKNOWN" "UNKNOWN" "$(sev_of generic.link.flaps eth0)"
mv "$FIX/cc.bak" "$SYSFS_NET/eth0/carrier_changes"
aer_write 0000:01:00.0 0 0 0

# devlink reporter vanishing during the window; reporter absent at T0 (set -u safe)
devlink_health_write 0 healthy
drop_fw() { sed -i '/^pci\/0000:01:00.0:/,/^auxiliary/{/^auxiliary/!d}' "$FIX/devlink_health"; }
snap_pair drop_fw
check_devlink
assert_eq "devlink reporter vanished UNKNOWN" "UNKNOWN" "$(sev_of generic.devlink.health.fw 0000:01:00.0)"
add_fw() { devlink_health_write 0 healthy; }
snap_pair add_fw
( set -u; check_devlink; sev_of generic.devlink.health.fw 0000:01:00.0 ) > "$FIX/out" 2>&1
assert_eq "devlink reporter new at T1 UNKNOWN (nounset)" "UNKNOWN" "$(<"$FIX/out")"

# devlink port show failure: unmapped port reporters must not read as N/A
devlink_health_write 0 healthy
DL_PORT_NETDEV=()
DL_PORT_ERROR="netlink error"
snap_pair true
check_devlink
assert_eq "port show failed: unmapped reporters UNKNOWN" "UNKNOWN" "$(sev_of generic.devlink.health "$HOSTNAME")"
assert_eq "port show failed: ASIC w/o device reporters UNKNOWN" "UNKNOWN" "$(sev_of generic.devlink.health 0000:02:00)"
DL_PORT_ERROR=""
parse_devlink_ports < "$FIX/devlink_ports"

# Alarm-only sensor (no crit/max) is WARN, not N/A
HWD="$SYSFS_PCI/0000:02:00.0/hwmon/hwmon2"
printf 'alarmonly\n' > "$HWD/temp3_label"; printf '40000\n' > "$HWD/temp3_input"; printf '1\n' > "$HWD/temp3_alarm"
printf 'noalarm\n' > "$HWD/temp4_label"; printf '40000\n' > "$HWD/temp4_input"
reset_results
check_temperature 0000:02:00
assert_eq "temp alarm without thresholds WARN" "WARN" "$(sev_of generic.temperature "0000:02:00 (alarmonly)")"
assert_eq "temp no thresholds N/A"             "N/A"  "$(sev_of generic.temperature "0000:02:00 (noalarm)")"
rm -f "$HWD"/temp[34]_*

# Zero threshold is no threshold: mlx5 empty module cage reports input=0 crit=0 (seen on CX5)
hwmon_write 0000:02:00.0 hwmon2 3 "emptycage" 0 0
hwmon_write 0000:02:00.0 hwmon2 4 "zerocrit" 60000 0 55000
reset_results
check_temperature 0000:02:00
assert_eq "temp empty cage (input=0 crit=0) N/A"  "N/A"  "$(sev_of generic.temperature "0000:02:00 (emptycage)")"
EMPTY_HINT=""
for I in "${!REC_SEV[@]}"; do [[ "${REC_TARGET[I]}" == "0000:02:00 (emptycage)" ]] && EMPTY_HINT="${REC_HINT[I]}"; done
assert_eq "temp empty cage hint" "Sensor reads 0 with no threshold: empty module cage or module without temperature monitoring" "$EMPTY_HINT"
assert_eq "temp crit=0 ignored, max still judged WARN" "WARN" "$(sev_of generic.temperature "0000:02:00 (zerocrit)")"
rm -f "$HWD"/temp[34]_*

# Strict shell: optional hwmon attributes missing must not abort under set -e
( set -euo pipefail; reset_results; check_temperature 0000:02:00; check_temperature 0000:03:00; echo "finished" ) > "$FIX/out" 2>&1
assert_eq "set -euo pipefail with missing hwmon attrs" "finished" "$(tail -1 "$FIX/out")"

# Malformed /proc/uptime: elapsed unknown, JSON elapsed_s null
CLOCK_OK=false
assert_eq "elapsed_str with bad clock" "?" "$(elapsed_str)"
CLOCK_OK=true
printf 'garbage\n' > "$FIX/uptime"
RC=0; uptime_cs >/dev/null || RC=$?
assert_eq "uptime_cs malformed fails" "1" "$RC"

# --- mlx5 rule engine ---
assert_eq "fmt_sci 2000/1e9" "2.0e-06" "$(fmt_sci 2000 1000000000)"
assert_eq "fmt_sci 1/3"      "3.3e-01" "$(fmt_sci 1 3)"
assert_eq "fmt_sci zero"     "0"       "$(fmt_sci 0 5)"
assert_eq "rule severities mixed" "CRIT/WARN" "$(mlx5_rule_severities 8)"
assert_eq "wanted set expands digit ranges" "1 1 1" "${MLX5_WANTED[rx_prio0_buf_discard]} ${MLX5_WANTED[rx_prio7_cong_discard]} ${MLX5_WANTED[rx_err_lane_9_phy]}"
assert_eq "wanted set drops per-channel" "" "${MLX5_WANTED[rx3_wqe_err]:-}"
printf '     rx_out_of_buffer: 7\n     rx_out_of_buffer: 9\n' > "$FIX/ets_dup"
declare -A DUPSNAP=()
mlx5_snapshot DUPSNAP dup
assert_eq "duplicate ethtool name: first wins, listed once" "7 rx_out_of_buffer" "${DUPSNAP[ets|dup|rx_out_of_buffer]} ${DUPSNAP[ets_names|dup]}"

# Real ConnectX-6 Lx counter set (pve-01), all zero, plus one irrelevant counter
MLX5_BASE="tx_recover tx_cqe_err rx_wqe_err rx_buff_alloc_err rx_recover rx_out_of_buffer rx_crc_errors_phy
rx_bytes_phy rx_oversize_pkts_phy rx_symbol_err_phy rx_pause_ctrl_phy tx_pause_ctrl_phy rx_discards_phy
tx_discards_phy rx_undersize_pkts_phy rx_fragments_phy rx_jabbers_phy link_down_events_phy rx_pcs_symbol_err_phy
rx_corrected_bits_phy rx_err_lane_0_phy rx_err_lane_1_phy rx_err_lane_2_phy rx_err_lane_3_phy
rx_buffer_passed_thres_phy rx_pci_signal_integrity tx_pci_signal_integrity outbound_pci_stalled_rd
outbound_pci_stalled_wr outbound_pci_stalled_rd_events outbound_pci_stalled_wr_events rx_global_pause
tx_global_pause tx_pause_storm_warning_events tx_pause_storm_error_events module_unplug module_bus_stuck
module_high_temp module_bad_shorted rx_prio0_buf_discard rx_prio3_buf_discard rx_prio3_cong_discard rx3_wqe_err"
ets_write() {  # ets_write <iface> [name=value ...] (unlisted base counters are 0)
    local IFACE="$1" N KV
    shift
    local -A V=()
    for KV in "$@"; do V["${KV%%=*}"]="${KV#*=}"; done
    {
        echo "NIC statistics:"
        for N in $MLX5_BASE; do printf '     %s: %s\n' "$N" "${V[$N]:-0}"; done
        for N in "${!V[@]}"; do [[ " ${MLX5_BASE//$'\n'/ } " == *" $N "* ]] || printf '     %s: %s\n' "$N" "${V[$N]}"; done
    } > "$FIX/ets_$IFACE"
}
mlx5_rec() {  # mlx5_rec <field> <check> <iface>: print one field of the matching record
    local i
    local -n _F="$1"
    for i in "${!REC_SEV[@]}"; do
        [[ "${REC_CHECK[i]}" == "$2" && "${REC_TARGET[i]}" == "$3" ]] && { printf '%s' "${_F[i]}"; return; }
    done
}

INTERVAL=5
reset_results
ets_write eth0
rm -f "$FIX/ets_eth1"     # eth1: ethtool -S fails
grow0() { ets_write eth0 rx_out_of_buffer=5 tx_cqe_err=1 rx_pause_ctrl_phy=100 rx_err_lane_2_phy=1000 rx_corrected_bits_phy=1000 module_high_temp=0; }
snap_pair grow0
for i in "${!PORT_IFACE[@]}"; do mlx5_port_eligible "$i" && check_mlx5_port "$i"; done
assert_eq "mlx5 eligible only mlx5 PFs" "0 1" "$(for i in "${!PORT_IFACE[@]}"; do mlx5_port_eligible "$i" && printf '%s ' "$i"; done | sed 's/ $//')"
assert_eq "mlx5 starvation WARN"          "WARN"    "$(sev_of mlx5.rx.starvation eth0)"
assert_eq "mlx5 starvation value"         "rx_out_of_buffer=+5" "$(mlx5_rec REC_VALUE mlx5.rx.starvation eth0)"
assert_eq "mlx5 datapath CRIT"            "CRIT"    "$(sev_of mlx5.datapath.faults eth0)"
assert_eq "mlx5 congestion INFO-only OK"  "OK"      "$(sev_of mlx5.congestion eth0)"
assert_eq "mlx5 congestion context hint"  "Context only: rx_pause_ctrl_phy +100" "$(mlx5_rec REC_HINT mlx5.congestion eth0)"
assert_eq "mlx5 unchanged rule OK"        "OK"      "$(sev_of mlx5.module eth0)"
assert_eq "mlx5 threshold compact"        ">0 CRIT/WARN" "$(mlx5_rec REC_THRESHOLD mlx5.module eth0)"
assert_eq "mlx5 PHY no rx_bits_phy OK"    "OK"      "$(sev_of mlx5.phy.errors eth0)"
assert_eq "mlx5 lane skew hint" "Context only: rx_corrected_bits_phy +1000, rx_err_lane_2_phy +1000. Corrected bits concentrated on rx_err_lane_2_phy: suspect that lane/fiber of the optic or cable" "$(mlx5_rec REC_HINT mlx5.phy.errors eth0)"
assert_eq "mlx5 BER not computed note" "yes" "$([[ "$(mlx5_rec REC_EVIDENCE mlx5.phy.errors eth0)" == *"rx_bits_phy not exposed"* ]] && echo yes)"
assert_eq "mlx5 ethtool -S failure UNKNOWN" "UNKNOWN" "$(sev_of mlx5.ethtool eth1)"
dump_json mlx5-delta
assert_eq "mlx5 not run on other drivers" "MISSING" "$(sev_of mlx5.rx.starvation eth2)"
assert_eq "mlx5 metrics: every counter of the rule, zeros included" '"rx_out_of_buffer": {"total": 5, "delta": 5}, "rx_buff_alloc_err": {"total": 0, "delta": 0}' \
    "$(metrics_of mlx5.rx.starvation eth0)"
assert_eq "mlx5 metrics: evidence unchanged" "rx_out_of_buffer=5 (+5)" "$(mlx5_rec REC_EVIDENCE mlx5.rx.starvation eth0)"
assert_eq "mlx5 metrics: lane and INFO counters typed" '"rx_symbol_err_phy": {"total": 0, "delta": 0}, "rx_pcs_symbol_err_phy": {"total": 0, "delta": 0}, "rx_corrected_bits_phy": {"total": 1000, "delta": 1000}, "rx_err_lane_0_phy": {"total": 0, "delta": 0}, "rx_err_lane_1_phy": {"total": 0, "delta": 0}, "rx_err_lane_2_phy": {"total": 1000, "delta": 1000}, "rx_err_lane_3_phy": {"total": 0, "delta": 0}' \
    "$(metrics_of mlx5.phy.errors eth0)"
assert_eq "mlx5 metrics: gauges as percent" "yes" "$([[ "$(metrics_of mlx5.pcie.path eth0)" == *'"outbound_pci_stalled_rd_pct": 0, "outbound_pci_stalled_wr_pct": 0' ]] && echo yes)"
assert_eq "mlx5 metrics: ethtool -S failure has none" "" "$(metrics_of mlx5.ethtool eth1)"
PORT_VF[1]=true
RC=0; mlx5_port_eligible 1 || RC=$?
assert_eq "mlx5 skips virtual functions" "1" "$RC"
PORT_VF[1]=false

# Pre-FEC BER with rx_bits_phy; post-FEC CRIT; PFC discard WARN; counter reset UNKNOWN; absent counters N/A
reset_results
ets_write eth0 rx_bits_phy=0 rx_prio3_cong_discard=0 rx_symbol_err_phy=50
ets_write eth1
grow1() {
    ets_write eth0 rx_bits_phy=1000000000 rx_corrected_bits_phy=2000 rx_prio3_cong_discard=4 rx_symbol_err_phy=10
    grep -v module_ "$FIX/ets_eth1" > "$FIX/ets_eth1.new"; mv "$FIX/ets_eth1.new" "$FIX/ets_eth1"
}
ets_write eth1
grep -v module_ "$FIX/ets_eth1" > "$FIX/ets_eth1.new"; mv "$FIX/ets_eth1.new" "$FIX/ets_eth1"
snap_pair grow1
check_mlx5_port 0
check_mlx5_port 1
assert_eq "mlx5 counter reset UNKNOWN"   "UNKNOWN" "$(sev_of mlx5.phy.errors eth0)"
assert_eq "mlx5 PFC discard WARN"        "WARN"    "$(sev_of mlx5.congestion eth0)"
assert_eq "mlx5 absent counters N/A"     "N/A"     "$(sev_of mlx5.module eth1)"
assert_eq "mlx5 metrics: counter reset (UNKNOWN) has none" "" "$(metrics_of mlx5.phy.errors eth0)"
assert_eq "mlx5 metrics: absent counters (N/A) have none" "" "$(metrics_of mlx5.module eth1)"
reset_results
ets_write eth0 rx_bits_phy=0
grow2() { ets_write eth0 rx_bits_phy=1000000000 rx_corrected_bits_phy=2000; }
snap_pair grow2
check_mlx5_port 0
assert_eq "mlx5 pre-FEC BER>1e-6 WARN"   "WARN"    "$(sev_of mlx5.phy.errors eth0)"
assert_eq "mlx5 BER value"               "pre-FEC BER=2.0e-06" "$(mlx5_rec REC_VALUE mlx5.phy.errors eth0)"
dump_json mlx5-ber
assert_eq "mlx5 metrics: pre-FEC BER typed" "yes" "$([[ "$(metrics_of mlx5.phy.errors eth0)" == *'"rx_bits_phy": {"total": 1000000000, "delta": 1000000000}, "pre_fec_ber": 2.0e-6, "pre_fec_ber_estimated": false, "pre_fec_ber_judged": true' ]] && echo yes)"
reset_results
ets_write eth0 rx_bits_phy=0
grow3() { ets_write eth0 rx_bits_phy=1000000000 rx_corrected_bits_phy=20 rx_symbol_err_phy=1; }
snap_pair grow3
check_mlx5_port 0
assert_eq "mlx5 post-FEC errors CRIT"    "CRIT"    "$(sev_of mlx5.phy.errors eth0)"
assert_eq "mlx5 low BER + post-FEC value" "rx_symbol_err_phy=+1 pre-FEC BER=2.0e-08" "$(mlx5_rec REC_VALUE mlx5.phy.errors eth0)"
assert_eq "no FEC hint without speed/fec data" "Uncorrectable" "$(mlx5_rec REC_HINT mlx5.phy.errors eth0 | cut -d' ' -f1)"
printf '25000\n' > "$SYSFS_NET/eth0/speed"
printf 'FEC parameters for eth0:\nSupported/Configured FEC encodings: Auto\nActive FEC encoding: Off\n' > "$FIX/fec_eth0"
reset_results
ets_write eth0 rx_bits_phy=0
snap_pair grow3
check_mlx5_port 0
assert_eq "FEC Off at 25G hint" "Active FEC is Off at 25000 Mb/s:" "$(mlx5_rec REC_HINT mlx5.phy.errors eth0 | cut -d' ' -f1-7)"
printf 'FEC parameters for eth0:\nActive FEC encoding: RS\n' > "$FIX/fec_eth0"
reset_results
ets_write eth0 rx_bits_phy=0
snap_pair grow3
check_mlx5_port 0
assert_eq "no FEC hint when RS active" "Uncorrectable" "$(mlx5_rec REC_HINT mlx5.phy.errors eth0 | cut -d' ' -f1)"

# Absolute mode: historical CRIT capped at WARN; under strict shell
reset_results
INTERVAL=0
ets_write eth0 tx_cqe_err=3
DL_ORDER=()
snapshot SNAP1 DL_ORDER
( set -euo pipefail; check_mlx5_port 0; sev_of mlx5.datapath.faults eth0; echo; sev_of mlx5.rx.starvation eth0; echo; mlx5_rec REC_VALUE mlx5.datapath.faults eth0; echo; mlx5_rec REC_VALUE mlx5.rx.starvation eth0 ) > "$FIX/out" 2>&1
assert_eq "mlx5 absolute capped WARN, others OK, unsigned values (strict)" "WARN OK tx_cqe_err=3 0" "$(tr '\n' ' ' < "$FIX/out" | sed 's/ $//')"
check_mlx5_port 0
assert_eq "mlx5 absolute metrics: totals only" '"tx_cqe_err": {"total": 3}, "rx_wqe_err": {"total": 0}, "tx_recover": {"total": 0}, "rx_recover": {"total": 0}' \
    "$(metrics_of mlx5.datapath.faults eth0)"
dump_json mlx5-absolute
INTERVAL=5

# --- Review regressions (Phase 3) ---
# Unsigned 64-bit counters beyond bash's signed range
SNAP0=(["a"]=18446744073709551000 ["b"]=999999999999999999 ["c"]=18446744073709551615 ["d"]=000123)
SNAP1=(["a"]=18446744073709551615 ["b"]=1000000000000000005 ["c"]=5 ["d"]=130)
RC=0; delta a || RC=$?; assert_eq "delta 20-digit growth" "0 615" "$RC $DELTA"
RC=0; delta b || RC=$?; assert_eq "delta crossing 18->19 digits" "0 6" "$RC $DELTA"
RC=0; delta c || RC=$?; assert_eq "delta 20-digit reset" "2" "$RC"
RC=0; delta d || RC=$?; assert_eq "delta leading zeros not octal" "0 7" "$RC $DELTA"
SNAP0["e"]=0; SNAP1["e"]=18446744073709551615
RC=0; delta e || RC=$?; assert_eq "delta too large for bash is rejected" "1" "$RC"
assert_eq "fmt_sci huge denominator" "1.0e-05" "$(fmt_sci 10000000000000 1000000000000000000)"

INTERVAL=5
# Gauges are T1-only context: a falling gauge is not a reset, a rising one is not a delta
reset_results
ets_write eth0 outbound_pci_stalled_rd=80 outbound_pci_buffer_overflow=0
gauge() { ets_write eth0 outbound_pci_stalled_rd=0 outbound_pci_buffer_overflow=12; }
snap_pair gauge
check_mlx5_port 0
assert_eq "falling gauge not UNKNOWN" "OK" "$(sev_of mlx5.pcie.path eth0)"
assert_eq "gauge context at T1" "yes" "$([[ "$(mlx5_rec REC_EVIDENCE mlx5.pcie.path eth0)" == *"outbound_pci_stalled_rd=0% (gauge); outbound_pci_stalled_wr=0% (gauge); outbound_pci_buffer_overflow=12% (gauge)" ]] && echo yes)"

# rx_bits_phy reset with corrected-bit growth must be UNKNOWN, not OK
reset_results
ets_write eth0 rx_bits_phy=1000000000
bits_reset() { ets_write eth0 rx_bits_phy=1 rx_corrected_bits_phy=2000; }
snap_pair bits_reset
check_mlx5_port 0
assert_eq "rx_bits_phy reset UNKNOWN" "UNKNOWN" "$(sev_of mlx5.phy.errors eth0)"

# BER 1e-5 with counters whose product would overflow
reset_results
ets_write eth0 rx_bits_phy=0
huge() { ets_write eth0 rx_bits_phy=1000000000000000000 rx_corrected_bits_phy=10000000000000 rx_err_lane_1_phy=5000000000000000000; }
# Multi-lane link (100G, no "Lanes:" from the stub): lane counters are judged
SAVED_SPEED=$(< "$SYSFS_NET/eth0/speed"); printf '100000\n' > "$SYSFS_NET/eth0/speed"
snap_pair huge
check_mlx5_port 0
assert_eq "overflow-safe BER WARN" "WARN" "$(sev_of mlx5.phy.errors eth0)"
assert_eq "overflow-safe BER value" "pre-FEC BER=1.0e-05" "$(mlx5_rec REC_VALUE mlx5.phy.errors eth0)"
assert_eq "overflow-safe lane hint" "yes" "$([[ "$(mlx5_rec REC_HINT mlx5.phy.errors eth0)" == *"concentrated on rx_err_lane_1_phy"* ]] && echo yes)"
assert_eq "bits counter not listed as context" "no" "$([[ "$(mlx5_rec REC_HINT mlx5.phy.errors eth0)" == *rx_bits_phy* ]] && echo yes || echo no)"
printf '%s\n' "$SAVED_SPEED" > "$SYSFS_NET/eth0/speed"

# Lanes in use (#16): ethtool "Lanes:", else speed <= 25G means one lane, else unknown
lane_hint() { reset_results; snap_pair "$1"; check_mlx5_port 0; mlx5_rec REC_HINT mlx5.phy.errors eth0; }
printf '4\n' > "$FIX/lanes_eth0"
assert_eq "active lanes from ethtool" "4" "$(port_active_lanes eth0)"
printf '0\n' > "$FIX/lanes_eth0"
assert_eq "Lanes: 0 ignored, speed fallback (25G)" "1" "$(port_active_lanes eth0)"
rm -f "$FIX/lanes_eth0"
assert_eq "no Lanes line, 25G: one lane" "1" "$(port_active_lanes eth0)"
printf '100000\n' > "$SYSFS_NET/eth0/speed"
assert_eq "no Lanes line, 100G: unknown" "" "$(port_active_lanes eth0)"
printf -- '-1\n' > "$SYSFS_NET/eth0/speed"
assert_eq "no link speed: unknown" "" "$(port_active_lanes eth0)"
printf '%s\n' "$SAVED_SPEED" > "$SYSFS_NET/eth0/speed"
# The reported case: single-lane 25G, all corrected bits on lane 0 -> no lane hint
ets_write eth0 rx_corrected_bits_phy=0 rx_err_lane_0_phy=0 rx_err_lane_1_phy=0 rx_err_lane_2_phy=0 rx_err_lane_3_phy=0
lane0() { ets_write eth0 rx_corrected_bits_phy=3911 rx_err_lane_0_phy=3911 rx_err_lane_1_phy=0 rx_err_lane_2_phy=0 rx_err_lane_3_phy=0; }
assert_eq "single-lane 25G: no lane hint" "no" "$([[ "$(lane_hint lane0)" == *concentrated* ]] && echo yes || echo no)"
printf '1\n' > "$FIX/lanes_eth0"; printf '100000\n' > "$SYSFS_NET/eth0/speed"
ets_write eth0 rx_corrected_bits_phy=0 rx_err_lane_0_phy=0 rx_err_lane_1_phy=0 rx_err_lane_2_phy=0 rx_err_lane_3_phy=0
assert_eq "Lanes: 1 from ethtool: no lane hint" "no" "$([[ "$(lane_hint lane0)" == *concentrated* ]] && echo yes || echo no)"
printf '%s\n' "$SAVED_SPEED" > "$SYSFS_NET/eth0/speed"
# 4-lane link with one dominant lane: hint kept
printf '4\n' > "$FIX/lanes_eth0"
ets_write eth0 rx_corrected_bits_phy=0 rx_err_lane_0_phy=0 rx_err_lane_1_phy=0 rx_err_lane_2_phy=0 rx_err_lane_3_phy=0
lane2() { ets_write eth0 rx_corrected_bits_phy=1000 rx_err_lane_0_phy=5 rx_err_lane_1_phy=5 rx_err_lane_2_phy=990 rx_err_lane_3_phy=0; }
assert_eq "4-lane link, lane 2 dominant: hint" "yes" "$([[ "$(lane_hint lane2)" == *"concentrated on rx_err_lane_2_phy"* ]] && echo yes || echo no)"
# 2-lane link: growth on an unused lane (3) is ignored, spread over the used lanes gives no hint
printf '2\n' > "$FIX/lanes_eth0"
ets_write eth0 rx_corrected_bits_phy=0 rx_err_lane_0_phy=0 rx_err_lane_1_phy=0 rx_err_lane_2_phy=0 rx_err_lane_3_phy=0
unused3() { ets_write eth0 rx_corrected_bits_phy=1000 rx_err_lane_0_phy=500 rx_err_lane_1_phy=500 rx_err_lane_2_phy=0 rx_err_lane_3_phy=900000; }
assert_eq "2-lane link: unused lane 3 ignored" "no" "$([[ "$(lane_hint unused3)" == *concentrated* ]] && echo yes || echo no)"
rm -f "$FIX/lanes_eth0"
ets_write eth0 rx_corrected_bits_phy=0 rx_err_lane_0_phy=0 rx_err_lane_1_phy=0 rx_err_lane_2_phy=0 rx_err_lane_3_phy=0

# Pre-FEC BER estimated from link speed x window when rx_bits_phy is absent (#15): 25G, 5.01 s
printf '25000\n' > "$SYSFS_NET/eth0/speed"
ber_est() { reset_results; snap_pair "$1"; check_mlx5_port 0; }
corr_low()  { ets_write eth0 rx_corrected_bits_phy=2000; }
corr_high() { ets_write eth0 rx_corrected_bits_phy=200000; }
ets_write eth0
ber_est corr_low
assert_eq "estimated BER low: OK"     "OK" "$(sev_of mlx5.phy.errors eth0)"
assert_eq "estimated BER value"       "pre-FEC BER~1.5e-08" "$(mlx5_rec REC_VALUE mlx5.phy.errors eth0)"
dump_json mlx5-ber-estimated
assert_eq "estimated BER metrics" "yes" "$([[ "$(metrics_of mlx5.phy.errors eth0)" == *'"pre_fec_ber": 1.5e-8, "pre_fec_ber_estimated": true, "pre_fec_ber_judged": true' ]] && echo yes)"
assert_eq "estimated BER evidence"    "yes" "$([[ "$(mlx5_rec REC_EVIDENCE mlx5.phy.errors eth0)" == *"pre-FEC BER estimated from link speed x window"* ]] && echo yes)"
ets_write eth0
ber_est corr_high
assert_eq "estimated BER>1e-6: WARN"  "WARN" "$(sev_of mlx5.phy.errors eth0)"
printf -- '-1\n' > "$SYSFS_NET/eth0/speed"
ets_write eth0
ber_est corr_high
assert_eq "no speed: BER not computed, OK" "OK" "$(sev_of mlx5.phy.errors eth0)"
assert_eq "no speed: not-computed note" "yes" "$([[ "$(mlx5_rec REC_EVIDENCE mlx5.phy.errors eth0)" == *"pre-FEC BER not computed"* ]] && echo yes)"
# PAM4 lanes are not judged: 100G without "Lanes:", and 2x50G; 4x25G NRZ is
printf '100000\n' > "$SYSFS_NET/eth0/speed"
corr_100g() { ets_write eth0 rx_corrected_bits_phy=800000; }
ets_write eth0
ber_est corr_100g
assert_eq "100G, lanes unknown: estimate not judged" "OK" "$(sev_of mlx5.phy.errors eth0)"
assert_eq "not-judged note" "yes" "$([[ "$(mlx5_rec REC_EVIDENCE mlx5.phy.errors eth0)" == *"(not judged: lanes above 25000 Mb/s may be PAM4)"* ]] && echo yes)"
printf '2\n' > "$FIX/lanes_eth0"
ets_write eth0
ber_est corr_100g
assert_eq "100G over 2 lanes (PAM4): not judged" "OK" "$(sev_of mlx5.phy.errors eth0)"
assert_eq "PAM4 estimate metrics: not judged" "yes" "$([[ "$(metrics_of mlx5.phy.errors eth0)" == *'"pre_fec_ber_estimated": true, "pre_fec_ber_judged": false' ]] && echo yes)"
dump_json mlx5-ber-pam4
printf '4\n' > "$FIX/lanes_eth0"
ets_write eth0
ber_est corr_100g
assert_eq "100G over 4 NRZ lanes: judged, WARN" "WARN" "$(sev_of mlx5.phy.errors eth0)"
rm -f "$FIX/lanes_eth0"
printf '25000\n' > "$SYSFS_NET/eth0/speed"
CLOCK_OK=false
ets_write eth0
ber_est corr_high
assert_eq "bad clock: BER not estimated" "OK" "$(sev_of mlx5.phy.errors eth0)"
CLOCK_OK=true

# History floor (#15): no growth in the window, but high totals since boot -> WARN
assert_eq "history rate"                "136344" "$(mlx5_history_rate 160341353 4233600)"
assert_eq "history leading zeros"       "3600"   "$(mlx5_history_rate 0001000 1000)"
RC=0; mlx5_history_rate 999 1 >/dev/null || RC=$?;        assert_eq "history below min count" "1" "$RC"
RC=0; mlx5_history_rate 5000 2592000 >/dev/null || RC=$?; assert_eq "history below rate (5000 in 30 days)" "1" "$RC"
assert_eq "history 20-digit total clamped" "yes" "$(mlx5_history_rate 18446744073709551615 100 >/dev/null && echo yes)"
assert_eq "history divide-first branch" "360000000000000000" "$(mlx5_history_rate 1000000000000000 10)"
assert_eq "history huge total, short uptime" "yes" "$(mlx5_history_rate 900000000000000000 1 >/dev/null && echo yes)"
# The reported port: 49 days up, 160M symbol/CRC errors, none in this window
hist_pair() {  # hist_pair <uptime-s> name=value...: same counters at T0 and T1, T1 at the given uptime
    local UP="$1"
    shift
    reset_results
    DL_SCRATCH=(); DL_ORDER=()
    ets_write eth0 "$@"
    printf '%d.00 0\n' $(( UP - 5 )) > "$FIX/uptime"
    snapshot SNAP0 DL_SCRATCH
    printf '%d.00 0\n' "$UP" > "$FIX/uptime"
    snapshot SNAP1 DL_ORDER
    check_mlx5_port 0
}
hist_pair 4233600 rx_symbol_err_phy=160341353 rx_crc_errors_phy=160341411 rx_corrected_bits_phy=900000000
assert_eq "history: PHY WARN"           "WARN" "$(sev_of mlx5.phy.errors eth0)"
assert_eq "history: frame WARN"         "WARN" "$(sev_of mlx5.frame.errors eth0)"
assert_eq "history: PHY value"          "history: rx_symbol_err_phy ~136344/h window pre-FEC BER~0" "$(mlx5_rec REC_VALUE mlx5.phy.errors eth0)"
assert_eq "history: unit"               "avg since boot" "$(mlx5_rec REC_UNIT mlx5.phy.errors eth0)"
assert_eq "history: hint suggests longer window" "yes" "$([[ "$(mlx5_rec REC_HINT mlx5.frame.errors eth0)" == "None in this 5s window, but high totals since boot: bursty errors or a past incident. Watch with -I $TROUBLESHOOT_INTERVAL or longer, or -l deep for the link BER; the totals only reset at driver reload or reboot. Frame errors:"* ]] && echo yes)"
assert_eq "history: threshold"          ">0 WARN, history>=60/h WARN" "$(mlx5_rec REC_THRESHOLD mlx5.frame.errors eth0)"
assert_eq "history: other rules untouched" "OK" "$(sev_of mlx5.rx.starvation eth0)"
dump_json mlx5-history
# Corrected-bit growth in the window stays visible as context when the floor fires
hist_ctx() { ets_write eth0 rx_symbol_err_phy=160341353 rx_corrected_bits_phy=900000050; }
ets_write eth0 rx_symbol_err_phy=160341353 rx_corrected_bits_phy=900000000
printf '4233595.00 0\n' > "$FIX/uptime"; reset_results; DL_SCRATCH=(); DL_ORDER=()
snapshot SNAP0 DL_SCRATCH; hist_ctx; printf '4233600.00 0\n' > "$FIX/uptime"; snapshot SNAP1 DL_ORDER
check_mlx5_port 0
assert_eq "history: context kept" "yes" "$([[ "$(mlx5_rec REC_HINT mlx5.phy.errors eth0)" == *". Context: rx_corrected_bits_phy +50" ]] && echo yes)"
# A counter reset stays UNKNOWN whatever the totals
ets_write eth0 rx_crc_errors_phy=160341411
crc_reset() { ets_write eth0 rx_crc_errors_phy=5000; }
snap_pair crc_reset
check_mlx5_port 0
assert_eq "history: reset still UNKNOWN" "UNKNOWN" "$(sev_of mlx5.frame.errors eth0)"
# Corrected bits alone (INFO) never trigger the floor
hist_pair 4233600 rx_corrected_bits_phy=900000000
assert_eq "history: INFO counter ignored" "OK" "$(sev_of mlx5.phy.errors eth0)"
# A one-off burst long ago: 5000 errors over 30 days is below 60/h
hist_pair 2592000 rx_crc_errors_phy=5000
assert_eq "history: old burst stays OK" "OK" "$(sev_of mlx5.frame.errors eth0)"
# A few link-training errors on a young host: below the minimum count
hist_pair 600 rx_crc_errors_phy=12
assert_eq "history: few errors stay OK" "OK" "$(sev_of mlx5.frame.errors eth0)"
# Growth in the window still wins: CRIT, no history value
ets_write eth0 rx_symbol_err_phy=160341353
grow_hist() { ets_write eth0 rx_symbol_err_phy=160341356; }
snap_pair grow_hist
check_mlx5_port 0
assert_eq "history: growth still CRIT"  "CRIT" "$(sev_of mlx5.phy.errors eth0)"
assert_eq "history: growth value"       "rx_symbol_err_phy=+3" "$(mlx5_rec REC_VALUE mlx5.phy.errors eth0 | cut -d' ' -f1)"
# Absolute mode keeps its own historical cap and hint
INTERVAL=0
reset_results
ets_write eth0 rx_crc_errors_phy=160341411
DL_ORDER=()
snapshot SNAP1 DL_ORDER
check_mlx5_port 0
assert_eq "history: -I 0 unchanged"     "WARN rx_crc_errors_phy=160341411" "$(sev_of mlx5.frame.errors eth0) $(mlx5_rec REC_VALUE mlx5.frame.errors eth0)"
INTERVAL=5
# Unreadable clock: no uptime, no history floor
reset_results
ets_write eth0 rx_crc_errors_phy=160341411
printf 'garbage\n' > "$FIX/uptime"
snapshot SNAP0 DL_SCRATCH
snapshot SNAP1 DL_ORDER
check_mlx5_port 0
assert_eq "history: no clock, no floor" "OK" "$(sev_of mlx5.frame.errors eth0)"
ets_write eth0

# --- Table filtering (-a/--all) ---
USE_COLOR=false
setup_colors
COLLECTED_AT="2026-10-20T00:00:00Z"
reset_results
add_record port eth0 c.ok   1 "" "-" OK      "" "" ""
add_record port eth0 c.na   - "" "-" "N/A"   "" "" ""
add_record port eth0 c.warn 1 "" "-" WARN    "" "" ""
add_record port eth0 c.unk  - "" "-" UNKNOWN "" "" ""
compute_verdict
SHOW_ALL=false
OUT=$(render_table)
assert_eq "table hides OK/N/A by default" "c.unk c.warn" "$(grep -oE 'c\.[a-z]+' <<< "$OUT" | sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "table reports hidden count" "yes" "$([[ "$OUT" == *"2 OK/N/A rows hidden (-a/--all to show)"* ]] && echo yes)"
SHOW_ALL=true
assert_eq "table -a shows all rows" "4" "$(render_table | grep -cE 'c\.[a-z]+')"
SHOW_ALL=false
assert_eq "CSV keeps all rows" "5" "$(render_csv | wc -l | tr -d ' ')"
reset_results
add_record port eth0 c.ok 1 "" "-" OK "" "" ""
compute_verdict
assert_eq "table with no problems" "yes" "$([[ "$(render_table)" == *"No problems found in 1 checks (-a/--all lists them)"* ]] && echo yes)"
assert_eq "no header when nothing listed" "0" "$(render_table | grep -c 'SEVERITY')"

# --- Deep mode (-l deep) ---
FIXTURES="$TEST_DIR/fixtures"
assert_eq "to_milli negative" "-79" "$(to_milli -0.079)"
assert_eq "to_milli integer" "45000" "$(to_milli 45)"
assert_eq "to_milli truncates" "3290800" "$(to_milli 3290.8001)"
assert_eq "ber_exponent 5E-10"   "-10"  "$(ber_exponent 5E-10)"
assert_eq "ber_exponent 15E-255" "-254" "$(ber_exponent 15E-255)"
assert_eq "ber_exponent 1.2E-12" "-12"  "$(ber_exponent 1.2E-12)"
assert_eq "ber_exponent zero"    "$BER_ZERO_EXPONENT" "$(ber_exponent 0E0)"
RC=0; ber_exponent "N/A" >/dev/null || RC=$?; assert_eq "ber_exponent unparseable" "1" "$RC"
assert_eq "ber_display tiny" "~0" "$(ber_display 15E-255)"

# Allowlist gate
deep_build_argv 0000:01:00.0
assert_eq "argv from template" "-d 0000:01:00.0 -m -c" "${DEEP_ARGV[*]}"
RC=0; deep_argv_allowed mstlink "${DEEP_ARGV[@]}" || RC=$?; assert_eq "allowlist accepts template" "0" "$RC"
RC=0; deep_argv_allowed mlxlink "${DEEP_ARGV[@]}" || RC=$?; assert_eq "allowlist accepts mlxlink" "0" "$RC"
for T in mstreg mlxreg mstconfig mstfwreset mstflint mlxfwmanager mst; do
    RC=0; deep_argv_allowed "$T" "${DEEP_ARGV[@]}" || RC=$?
    assert_eq "allowlist refuses tool $T" "1" "$RC"
done
for F in "${DEEP_FORBIDDEN_ARGS[@]}"; do
    RC=0; deep_argv_allowed mstlink -d 0000:01:00.0 "$F" -c || RC=$?
    assert_eq "allowlist refuses $F" "1" "$RC"
    RC=0; deep_argv_allowed mstlink -d 0000:01:00.0 -m -c "$F" || RC=$?
    assert_eq "allowlist refuses appended $F" "1" "$RC"
done
for B in "0000:01:00.0;reboot" "/dev/mst/mt4127_pciconf0" "01:00.0" "0000:01:00.8" ""; do
    RC=0; deep_argv_allowed mstlink -d "$B" -m -c || RC=$?
    assert_eq "allowlist refuses BDF '$B'" "1" "$RC"
done
RC=0; deep_argv_allowed mstlink -m -d 0000:01:00.0 -c || RC=$?; assert_eq "allowlist refuses reordered argv" "1" "$RC"
RC=0; deep_argv_allowed mstlink -d 0000:01:00.0 -m || RC=$?; assert_eq "allowlist refuses truncated argv" "1" "$RC"
# Defense in depth: a forbidden flag is refused even if someone adds it to the template
SAVED_TEMPLATE=("${DEEP_ARGS_TEMPLATE[@]}")
DEEP_ARGS_TEMPLATE+=("-e")
RC=0; deep_argv_allowed mstlink -d 0000:01:00.0 -m -c -e || RC=$?; assert_eq "forbidden flag refused even in template" "1" "$RC"
DEEP_ARGS_TEMPLATE=("${SAVED_TEMPLATE[@]}")
TEMPLATE_HITS=0
for A in "${DEEP_ARGS_TEMPLATE[@]}"; do for F in "${DEEP_FORBIDDEN_ARGS[@]}"; do [[ "$A" == "$F" ]] && (( ++TEMPLATE_HITS )); done; done
assert_eq "template contains no forbidden arg" "0" "$TEMPLATE_HITS"

# Execution: record every argv that reaches timeout(1) (to a file: it runs in a subshell);
# serve the real pve-01 captures
: > "$FIX/deep_calls"
# shellcheck disable=SC2329  # reached through TOOL_PATH[timeout]
timeout() { printf '%s\n' "$*" >> "$FIX/deep_calls"; shift 3; "$@"; }
# shellcheck disable=SC2329  # stubs below are invoked through the timeout stub
mstlink() {
    case "$2" in
        0000:01:00.0) cat "$FIXTURES/mstlink-cx6lx-25g-aoc-nofec-errors.txt" ;;
        0000:01:00.1) cat "$FIXTURES/mstlink-cx6lx-25g-aoc-nofec-clean.txt" ;;
        *) echo "-E- device not found"; return 1 ;;
    esac
}
# Function stubs are reached through TOOL_PATH (the script executes tools by path)
TOOL_PATH[mstlink]=mstlink
TOOL_PATH[mlxlink]=""
TOOL_PATH[timeout]=timeout
OUTPUT_FORMAT=json
DEEP_KV=(); DEEP_ERR=(); DEEP_TOOL_USED=()
deep_collect
mapfile -t DEEP_CALLS < "$FIX/deep_calls"
assert_eq "deep calls: one per mlx5 PF, exact argv" "-k $DEEP_KILL_AFTER $DEEP_TIMEOUT mstlink -d 0000:01:00.0 -m -c|-k $DEEP_KILL_AFTER $DEEP_TIMEOUT mstlink -d 0000:01:00.1 -m -c" "$(IFS='|'; echo "${DEEP_CALLS[*]}")"
FORBIDDEN_SEEN=0
for C in "${DEEP_CALLS[@]}"; do
    read -ra W <<< "$C"
    for A in "${W[@]}"; do for F in "${DEEP_FORBIDDEN_ARGS[@]}"; do [[ "$A" == "$F" ]] && (( ++FORBIDDEN_SEEN )); done; done
done
assert_eq "no forbidden flag ever executed" "0" "$FORBIDDEN_SEEN"
assert_eq "ANSI stripped from values" "Active" "${DEEP_KV[eth0|State]}"
assert_eq "parsed FEC" "No FEC" "${DEEP_KV[eth0|FEC]}"
assert_eq "parsed key with brackets" "45 [-45..90]" "${DEEP_KV[eth0|Temperature [C]]}"

reset_results
check_deep
assert_eq "deep troubleshooting OK"          "OK"   "$(sev_of mlx5.deep.troubleshooting eth0)"
assert_eq "deep FEC mismatch WARN"           "WARN" "$(sev_of mlx5.deep.fec eth0)"
assert_eq "deep BER 5E-10 WARN"              "WARN" "$(sev_of mlx5.deep.ber eth0)"
assert_eq "deep BER value"                   "effective 5E-10 raw 5E-10" "$(mlx5_rec REC_VALUE mlx5.deep.ber eth0)"
assert_eq "deep BER clean OK"                "OK"   "$(sev_of mlx5.deep.ber eth1)"
assert_eq "deep BER clean shown ~0"          "effective ~0 raw ~0" "$(mlx5_rec REC_VALUE mlx5.deep.ber eth1)"
assert_eq "deep module in range OK"          "OK"   "$(sev_of mlx5.deep.module eth0)"
assert_eq "deep module value" "Temperature=45 Voltage=3290.8 Bias=6.808 Rx=-0.079 Tx=0.607" "$(mlx5_rec REC_VALUE mlx5.deep.module eth0)"
assert_eq "deep metrics troubleshooting (Group Opcode N/A left out)" '"status_opcode": 0, "recommendation": "No issue was observed"' "$(metrics_of mlx5.deep.troubleshooting eth0)"
assert_eq "deep metrics FEC mismatch" '"fec": "No FEC", "compliance": "100G AOC (Active Optical Cable) or 25GAUI C2M AOC with FEC", "fec_mismatch": true' \
    "$(metrics_of mlx5.deep.fec eth0)"
assert_eq "deep metrics BER" '"effective_ber": 5e-10, "raw_ber": 5e-10, "effective_errors": 61179413, "raw_errors_per_lane": [61179413], "link_down_counter": 0, "since_clear_min": 71726.0' \
    "$(metrics_of mlx5.deep.ber eth0)"
assert_eq "deep metrics BER underflow kept as printed" "yes" "$([[ "$(metrics_of mlx5.deep.ber eth1)" == '"effective_ber": 15e-255, "raw_ber": 15e-255,'* ]] && echo yes)"
assert_eq "deep metrics module" '"temperature_c": 45, "temperature_c_low": -45, "temperature_c_high": 90, "voltage_mv": 3290.8, "voltage_mv_low": 3000, "voltage_mv_high": 3600, "bias_ma": 6.808, "bias_ma_low": 1, "bias_ma_high": 15, "rx_dbm": -0.079, "rx_dbm_low": -13.01, "rx_dbm_high": 4.4, "rx_dbm_judged": true, "tx_dbm": 0.607, "tx_dbm_low": -9.431, "tx_dbm_high": 3.398, "tx_fault": [0], "rx_los": [0], "tx_cdr_lol": [0], "rx_cdr_lol": [0], "vendor": "FS", "part_number": "SFP-25G-AO03", "compliance": "100G AOC (Active Optical Cable) or 25GAUI C2M AOC with FEC"' \
    "$(metrics_of mlx5.deep.module eth0)"
assert_eq "deep module evidence unchanged" "Temperature [C]=45 [-45..90]; Voltage [mV]=3290.8 [3000..3600]; Bias Current [mA]=6.808 [1..15]; Rx Power Current [dBm]=-0.079 [-13.01..4.4]; Tx Power Current [dBm]=0.607 [-9.431..3.398]; Tx Fault [per lane]=0; Rx LOS [per lane]=0; Tx CDR LOL [per lane]=0; Rx CDR LOL [per lane]=0; module FS SFP-25G-AO03" \
    "$(mlx5_rec REC_EVIDENCE mlx5.deep.module eth0)"
dump_json deep-mstlink
COLLECTED_AT="2026-10-20T00:00:00Z"
json_strict_check "deep mode JSON"

# Module out of range and lane faults
sed -e 's/^Rx Power Current \[dBm\]          : .*/Rx Power Current [dBm]          : -20.5 [-13.01..4.4]/' \
    -e 's/^Tx Fault \[per lane\]             : 0/Tx Fault [per lane]             : 1/' \
    "$FIXTURES/mstlink-cx6lx-25g-aoc-nofec-clean.txt" > "$FIX/mstlink-bad.txt"
# shellcheck disable=SC2329
mstlink() { cat "$FIX/mstlink-bad.txt"; }
DEEP_KV=(); DEEP_ERR=(); DEEP_TOOL_USED=()
deep_query mstlink eth1 0000:01:00.1
reset_results
check_deep_port 1
assert_eq "deep module Rx out of range + Tx fault WARN" "WARN" "$(sev_of mlx5.deep.module eth1)"
assert_eq "deep module hint" "Rx Power Current [dBm] -20.5 outside [-13.01..4.4]; Tx Fault set (lane mask 1): reseat or replace the module, check the peer optic and fiber" "$(mlx5_rec REC_HINT mlx5.deep.module eth1)"

# NVIDIA MFT mlxlink (4.34.1-25, installed --without-kernel), real captures from a ConnectX-6 Lx
# 25G SR port with a dirty link (eth0) and its unused no-link neighbour (eth1)
# shellcheck disable=SC2329
mlxlink() {
    case "$2" in
        0000:01:00.0) cat "$FIXTURES/mlxlink-cx6lx-25g-sr-ber-errors.txt" ;;
        0000:01:00.1) cat "$FIXTURES/mlxlink-cx6lx-25g-sr-nolink.txt" ;;
        *) echo "-E- device not found"; return 1 ;;
    esac
}
TOOL_PATH[mlxlink]=mlxlink
assert_eq "mlxlink preferred when both tools exist" "mlxlink" "$(deep_tool)"
: > "$FIX/deep_calls"
DEEP_KV=(); DEEP_ERR=(); DEEP_TOOL_USED=()
deep_collect
mapfile -t DEEP_CALLS < "$FIX/deep_calls"
assert_eq "mlxlink calls: exact argv" "-k $DEEP_KILL_AFTER $DEEP_TIMEOUT mlxlink -d 0000:01:00.0 -m -c|-k $DEEP_KILL_AFTER $DEEP_TIMEOUT mlxlink -d 0000:01:00.1 -m -c" "$(IFS='|'; echo "${DEEP_CALLS[*]}")"
assert_eq "mlxlink parsed FEC" "Firecode FEC" "${DEEP_KV[eth0|FEC]}"
assert_eq "mlxlink parsed Link Down Counter" "331" "${DEEP_KV[eth0|Link Down Counter]}"
reset_results
check_deep
assert_eq "mlxlink troubleshooting OK"       "OK"   "$(sev_of mlx5.deep.troubleshooting eth0)"
assert_eq "mlxlink FEC active OK"            "OK"   "$(sev_of mlx5.deep.fec eth0)"
assert_eq "mlxlink BER 3E-9 WARN"            "WARN" "$(sev_of mlx5.deep.ber eth0)"
assert_eq "mlxlink BER value"                "effective 3E-9 raw 7E-7" "$(mlx5_rec REC_VALUE mlx5.deep.ber eth0)"
assert_eq "mlxlink module (Rx -8.069 in range) OK" "OK" "$(sev_of mlx5.deep.module eth0)"
assert_eq "mlxlink BER metrics" '"effective_ber": 3e-9, "raw_ber": 7e-7, "effective_errors": 44005345, "raw_errors_per_lane": [9503137409], "link_down_counter": 331, "since_clear_min": 9145.9' \
    "$(metrics_of mlx5.deep.ber eth0)"
assert_eq "mlxlink FEC metrics" '"fec": "Firecode FEC", "compliance": "100GBASE-SR4 or 25GBASE-SR", "fec_mismatch": false' "$(metrics_of mlx5.deep.fec eth0)"
assert_eq "mlxlink BER evidence (all counters)" "Effective Physical BER=3E-9 Raw Physical BER=7E-7 Effective Physical Errors=44005345 Raw Physical Errors Per Lane=9503137409 Link Down Counter=331 since 9145.9 min" "$(mlx5_rec REC_EVIDENCE mlx5.deep.ber eth0)"
dump_json deep-mlxlink
assert_eq "mlxlink troubleshooting evidence" "mlxlink: No issue was observed" "$(mlx5_rec REC_EVIDENCE mlx5.deep.troubleshooting eth0)"
# Kernel says the port has link, so the tool's opcode 2 is still reported
assert_eq "mlxlink opcode WARN while kernel has carrier" "WARN" "$(sev_of mlx5.deep.troubleshooting eth1)"
# Without carrier (#12): link-level deep rows are N/A, the module is judged without Rx power
printf 'down\n' > "$SYSFS_NET/eth1/operstate"; printf '0\n' > "$SYSFS_NET/eth1/carrier"
reset_results
check_deep_port 1
assert_eq "no-link deep troubleshooting N/A" "N/A" "$(sev_of mlx5.deep.troubleshooting eth1)"
assert_eq "no-link deep FEC N/A"             "N/A" "$(sev_of mlx5.deep.fec eth1)"
assert_eq "no-link deep BER N/A (not UNKNOWN)" "N/A" "$(sev_of mlx5.deep.ber eth1)"
assert_eq "no-link deep evidence points to link.state" "no link (operstate=down): see generic.link.state" "$(mlx5_rec REC_EVIDENCE mlx5.deep.ber eth1)"
assert_eq "no-link module: Rx -40 dBm not judged" "OK" "$(sev_of mlx5.deep.module eth1)"
assert_eq "no-link module evidence says why" "yes" "$([[ "$(mlx5_rec REC_EVIDENCE mlx5.deep.module eth1)" == *"[dBm]=-40 [-11.308..3.398] (not judged: no link)"* ]] && echo yes)"
assert_eq "no-link module metrics: Rx not judged" "yes" "$([[ "$(metrics_of mlx5.deep.module eth1)" == *'"rx_dbm": -40, "rx_dbm_low": -11.308, "rx_dbm_high": 3.398, "rx_dbm_judged": false, "tx_dbm"'* ]] && echo yes)"
assert_eq "no-link deep link rows: no metrics" "||" "$(metrics_of mlx5.deep.troubleshooting eth1)|$(metrics_of mlx5.deep.fec eth1)|$(metrics_of mlx5.deep.ber eth1)"
dump_json deep-nolink
# Dark optic: Rx LOS / Rx CDR LOL set are expected without link; a Tx fault is still a fault
sed -E -e 's/^(Rx LOS \[per lane\] +: )0/\11/' -e 's/^(Rx CDR LOL \[per lane\] +: )0/\11/' \
    "$FIXTURES/mlxlink-cx6lx-25g-sr-nolink.txt" > "$FIX/mlxlink-dark.txt"
assert_eq "dark fixture has LOS set" "1" "$(grep -cE '^Rx LOS \[per lane\] +: 1' "$FIX/mlxlink-dark.txt")"
# shellcheck disable=SC2329
mlxlink() { cat "$FIX/mlxlink-dark.txt"; }
DEEP_KV=(); DEEP_ERR=(); DEEP_TOOL_USED=()
deep_query mlxlink eth1 0000:01:00.1
reset_results; check_deep_port 1
assert_eq "no-link: Rx LOS/CDR LOL not judged" "OK" "$(sev_of mlx5.deep.module eth1)"
sed -i -E 's/^(Tx Fault \[per lane\] +: )0/\11/' "$FIX/mlxlink-dark.txt"
DEEP_KV=(); DEEP_ERR=(); DEEP_TOOL_USED=()
deep_query mlxlink eth1 0000:01:00.1
reset_results; check_deep_port 1
assert_eq "no-link: Tx fault still WARN" "WARN" "$(sev_of mlx5.deep.module eth1)"
assert_eq "no-link: one row per deep check" "1 1 1 1" "$(count_of mlx5.deep.troubleshooting eth1) $(count_of mlx5.deep.fec eth1) $(count_of mlx5.deep.ber eth1) $(count_of mlx5.deep.module eth1)"
printf 'up\n' > "$SYSFS_NET/eth1/operstate"; rm -f "$SYSFS_NET/eth1/carrier"
TOOL_PATH[mlxlink]=""

# mstflint 4.26 prints no Link Down Counter (#13): list only what the tool printed, never "?"
# shellcheck disable=SC2329
mstlink() { cat "$FIXTURES/mstlink-4.26-cx6lx-25g-sr-ber-errors.txt"; }
DEEP_KV=(); DEEP_ERR=(); DEEP_TOOL_USED=()
deep_query mstlink eth0 0000:01:00.0
reset_results; check_deep_port 0
assert_eq "mstflint 4.26 has no Link Down Counter" "" "${DEEP_KV[eth0|Link Down Counter]:-}"
assert_eq "mstflint 4.26 BER evidence" "Effective Physical BER=3E-9 Raw Physical BER=7E-7 Effective Physical Errors=44005346 Raw Physical Errors Per Lane=9503137852 since 9145.9 min" "$(mlx5_rec REC_EVIDENCE mlx5.deep.ber eth0)"
assert_eq "mstflint 4.26 BER still WARN" "WARN" "$(sev_of mlx5.deep.ber eth0)"
# Multi-lane module (QSFP28 100G SR4): per-lane bias/Rx/Tx and per-lane flags are judged per lane
QSFP="$FIXTURES/mstlink-4.26-cx6dx-100g-sr4-qsfp28.txt"
# shellcheck disable=SC2329
mstlink() { cat "$QSFP"; }
DEEP_KV=(); DEEP_ERR=(); DEEP_TOOL_USED=()
deep_query mstlink eth0 0000:01:00.0
reset_results; check_deep_port 0
assert_eq "qsfp28 module OK" "OK" "$(sev_of mlx5.deep.module eth0)"
assert_eq "qsfp28 value shows lane min..max" "Temperature=52 Voltage=3295.3 Bias=7.408..7.592 Rx=-1.445..-0.372 Tx=1.189..1.386" \
    "$(mlx5_rec REC_VALUE mlx5.deep.module eth0)"
assert_eq "qsfp28 evidence keeps every Rx lane" "yes" \
    "$([[ "$(mlx5_rec REC_EVIDENCE mlx5.deep.module eth0)" == *"Rx Power Current [dBm]=-1.445,-0.405,-0.372,-1.284 [-14.089..3.398]"* ]] && echo yes)"
assert_eq "qsfp28 metrics: lowest lane and every lane" "yes" \
    "$([[ "$(metrics_of mlx5.deep.module eth0)" == *'"rx_dbm": -1.445, "rx_dbm_lanes": [-1.445, -0.405, -0.372, -1.284], "rx_dbm_low": -14.089, "rx_dbm_high": 3.398, "rx_dbm_judged": true'* ]] && echo yes)"
assert_eq "qsfp28 metrics: lane flags" "yes" "$([[ "$(metrics_of mlx5.deep.module eth0)" == *'"tx_fault": [0, 0, 0, 0], "rx_los": [0, 0, 0, 0]'* ]] && echo yes)"
dump_json deep-qsfp28
assert_eq "qsfp28 evidence keeps lane flags" "yes" \
    "$([[ "$(mlx5_rec REC_EVIDENCE mlx5.deep.module eth0)" == *"Tx Fault [per lane]=0,0,0,0; Rx LOS [per lane]=0,0,0,0"* ]] && echo yes)"
# One weak lane is a WARN naming the lane
sed -E 's/^(Rx Power Current \[dBm\] +: )-1.445,-0.405/\1-1.445,-15.2/' "$QSFP" > "$FIX/qsfp-weak.txt"
# shellcheck disable=SC2329
mstlink() { cat "$FIX/qsfp-weak.txt"; }
DEEP_KV=(); DEEP_ERR=(); DEEP_TOOL_USED=()
deep_query mstlink eth0 0000:01:00.0
reset_results; check_deep_port 0
assert_eq "qsfp28 weak lane WARN" "WARN" "$(sev_of mlx5.deep.module eth0)"
assert_eq "qsfp28 weak lane hint" "Rx Power Current [dBm] lane 2 -15.2 outside [-14.089..3.398]: reseat or replace the module, check the peer optic and fiber" \
    "$(mlx5_rec REC_HINT mlx5.deep.module eth0)"
# A fault flag on one lane is a WARN naming the lane
sed -E 's/^(Tx Fault \[per lane\] +: )0,0,0,0/\10,0,1,0/' "$QSFP" > "$FIX/qsfp-fault.txt"
# shellcheck disable=SC2329
mstlink() { cat "$FIX/qsfp-fault.txt"; }
DEEP_KV=(); DEEP_ERR=(); DEEP_TOOL_USED=()
deep_query mstlink eth0 0000:01:00.0
reset_results; check_deep_port 0
assert_eq "qsfp28 lane fault WARN" "WARN" "$(sev_of mlx5.deep.module eth0)"
assert_eq "qsfp28 lane fault hint" "Tx Fault set on lane 3: reseat or replace the module, check the peer optic and fiber" \
    "$(mlx5_rec REC_HINT mlx5.deep.module eth0)"
# Without link: dark Rx lanes and Rx LOS on every lane are expected, not judged
sed -E -e 's/^(Rx Power Current \[dBm\] +: ).*/\1-40,-40,-40,-40 [-14.089..3.398]/' \
    -e 's/^(Rx LOS \[per lane\] +: )0,0,0,0/\11,1,1,1/' "$QSFP" > "$FIX/qsfp-dark.txt"
# shellcheck disable=SC2329
mstlink() { cat "$FIX/qsfp-dark.txt"; }
printf 'down\n' > "$SYSFS_NET/eth0/operstate"
DEEP_KV=(); DEEP_ERR=(); DEEP_TOOL_USED=()
deep_query mstlink eth0 0000:01:00.0
reset_results; check_deep_port 0
assert_eq "qsfp28 no link: dark lanes not judged" "OK" "$(sev_of mlx5.deep.module eth0)"
dump_json deep-qsfp28-dark
printf 'up\n' > "$SYSFS_NET/eth0/operstate"
# shellcheck disable=SC2329
mstlink() { cat "$FIXTURES/mstlink-4.26-cx6lx-25g-sr-ber-errors.txt"; }

# A required counter that is missing is still flagged with "?"
DEEP_KV=(["eth0|Effective Physical BER"]="3E-9" ["eth0|Raw Physical BER"]="7E-7" ["eth0|Identifier"]="N/A")
DEEP_TOOL_USED=([eth0]=mstlink)
reset_results; check_deep_port 0
DEEP_KV=(["eth0|Effective Physical BER"]="3E-9" ["eth0|Raw Physical BER"]="7E-7" ["eth0|Effective Physical Errors"]="5" ["eth0|Link Down Counter"]="" ["eth0|Identifier"]="N/A")
reset_results; check_deep_port 0
assert_eq "optional counter printed empty is left out" "Effective Physical BER=3E-9 Raw Physical BER=7E-7 Effective Physical Errors=5 since ? min" "$(mlx5_rec REC_EVIDENCE mlx5.deep.ber eth0)"
DEEP_KV=(["eth0|Effective Physical BER"]="3E-9" ["eth0|Raw Physical BER"]="7E-7" ["eth0|Identifier"]="N/A")
reset_results; check_deep_port 0
assert_eq "missing required BER counter shown as ?" "Effective Physical BER=3E-9 Raw Physical BER=7E-7 Effective Physical Errors=? since ? min" "$(mlx5_rec REC_EVIDENCE mlx5.deep.ber eth0)"
assert_eq "missing BER values left out of metrics (never 0)" '"effective_ber": 3e-9, "raw_ber": 7e-7' "$(metrics_of mlx5.deep.ber eth0)"
DEEP_KV=(["eth0|Effective Physical BER"]="N/A" ["eth0|Identifier"]="N/A")
reset_results; check_deep_port 0
assert_eq "unparseable BER (UNKNOWN): no metrics" "UNKNOWN|" "$(sev_of mlx5.deep.ber eth0)|$(metrics_of mlx5.deep.ber eth0)"
assert_eq "no module (N/A): no metrics" "N/A|" "$(sev_of mlx5.deep.module eth0)|$(metrics_of mlx5.deep.module eth0)"

# mlx5.deep.rx_peers: each linked port's Rx against the host's other linked ports with the same module
# (nic-sweep.md §8). p0 is attenuated while still inside its module range; p5 has no link and is no peer;
# p6 has a different module and so no peers
DEEP_TOOL_USED=()
DEEP_RX_PORTS=(p0 p1 p2 p3 p4 p5 p6)
DEEP_RX_MILLI=([p0]=-8540 [p1]=-130 [p2]=-200 [p3]=-100 [p4]=-3000 [p5]=-40000 [p6]=-500)
DEEP_RX_TEXT=([p0]=-8.54 [p1]=-0.13 [p2]=-0.2 [p3]=-0.1 [p4]=-3 [p5]=-40 [p6]=-0.5)
DEEP_RX_MODULE=([p0]=SR [p1]=SR [p2]=SR [p3]=SR [p4]=SR [p5]=SR [p6]=LR)
DEEP_RX_LINK=([p0]=true [p1]=true [p2]=true [p3]=true [p4]=true [p5]=false [p6]=true)
reset_results; check_deep_rx_peers
assert_eq "rx_peers: severities" "WARN OK OK OK OK N/A N/A" \
    "$(for P in p0 p1 p2 p3 p4 p5 p6; do printf '%s ' "$(sev_of mlx5.deep.rx_peers "$P")"; done | sed 's/ $//')"
assert_eq "rx_peers: value is the delta to the even-count median" "-8.375" "$(mlx5_rec REC_VALUE mlx5.deep.rx_peers p0)"
assert_eq "rx_peers: evidence names the peers" "Rx -8.54 dBm; median -0.165 dBm over 4 peer(s) with module SR: p1 -0.13, p2 -0.2, p3 -0.1, p4 -3" \
    "$(mlx5_rec REC_EVIDENCE mlx5.deep.rx_peers p0)"
assert_eq "rx_peers: hint" "Rx 8.375 dB below the host's other ports with the same module, still inside the module's range: clean or inspect both fibre ends and the patch cord, check the peer optic's Tx" \
    "$(mlx5_rec REC_HINT mlx5.deep.rx_peers p0)"
assert_eq "rx_peers: metrics" '"rx_dbm": -8.54, "peers_median_dbm": -0.165, "delta_db": -8.375, "peers": 4, "compliance": "SR"' \
    "$(metrics_of mlx5.deep.rx_peers p0)"
assert_eq "rx_peers: a low peer pulls the median, not the verdict" "1.47" "$(mlx5_rec REC_VALUE mlx5.deep.rx_peers p1)"
assert_eq "rx_peers: no link" "no link: see generic.link.state" "$(mlx5_rec REC_EVIDENCE mlx5.deep.rx_peers p5)"
assert_eq "rx_peers: too few peers" "0 linked peer(s) with module LR, $DEEP_RX_PEERS_MIN needed" "$(mlx5_rec REC_EVIDENCE mlx5.deep.rx_peers p6)"
# Exactly the margin below is WARN; the odd-count median is the middle value
DEEP_RX_PORTS=(q0 q1 q2 q3)
DEEP_RX_MILLI=([q0]=-5100 [q1]=-100 [q2]=-90 [q3]=-110)
DEEP_RX_TEXT=([q0]=-5.1 [q1]=-0.1 [q2]=-0.09 [q3]=-0.11)
DEEP_RX_MODULE=([q0]=SR [q1]=SR [q2]=SR [q3]=SR)
DEEP_RX_LINK=([q0]=true [q1]=true [q2]=true [q3]=true)
reset_results; check_deep_rx_peers
assert_eq "rx_peers: margin itself is WARN" "WARN|-5" "$(sev_of mlx5.deep.rx_peers q0)|$(mlx5_rec REC_VALUE mlx5.deep.rx_peers q0)"
DEEP_RX_MILLI[q0]=-5099; DEEP_RX_TEXT[q0]=-5.099
reset_results; check_deep_rx_peers
assert_eq "rx_peers: just inside the margin is OK" "OK|-4.999" "$(sev_of mlx5.deep.rx_peers q0)|$(mlx5_rec REC_VALUE mlx5.deep.rx_peers q0)"
assert_eq "rx_peers: one record per port" "1 1 1 1" "$(for P in q0 q1 q2 q3; do printf '%s ' "$(count_of mlx5.deep.rx_peers "$P")"; done | sed 's/ $//')"
DEEP_RX_MODULE[q0]=""
reset_results; check_deep_rx_peers
assert_eq "rx_peers: no compliance, not judged" "N/A" "$(sev_of mlx5.deep.rx_peers q0)"
assert_eq "milli_text" "-8.66 5 -0.079 0 1.5" "$(for V in -8660 5000 -79 0 1500; do printf '%s ' "$(milli_text "$V")"; done | sed 's/ $//')"

# Failures: timeout, tool error, tool missing; mlxlink preferred
# shellcheck disable=SC2329
timeout() { return 124; }
DEEP_KV=(); DEEP_ERR=(); DEEP_TOOL_USED=()
deep_query mstlink eth0 0000:01:00.0
reset_results
check_deep_port 0
assert_eq "deep timeout UNKNOWN" "UNKNOWN" "$(sev_of mlx5.deep eth0)"
assert_eq "deep timeout evidence" "mstlink timed out after ${DEEP_TIMEOUT}s" "$(mlx5_rec REC_EVIDENCE mlx5.deep eth0)"
# shellcheck disable=SC2329
timeout() { shift 3; "$@"; }
# shellcheck disable=SC2329
mstlink() { echo "-E- Failed to open device"; return 1; }
DEEP_KV=(); DEEP_ERR=()
deep_query mstlink eth0 0000:01:00.0
assert_eq "deep tool error captured" "mstlink exit 1: -E- Failed to open device" "${DEEP_ERR[eth0]}"
# The gate inside deep_query: a malformed BDF never reaches timeout(1)
: > "$FIX/deep_calls"
# shellcheck disable=SC2329  # reached through TOOL_PATH[timeout]
timeout() { printf '%s\n' "$*" >> "$FIX/deep_calls"; shift 3; "$@"; }
DEEP_KV=(); DEEP_ERR=()
deep_query mstlink eth0 "0000:01:00.0;reboot"
assert_eq "deep_query refuses bad BDF" "refused by allowlist: mstlink -d 0000:01:00.0;reboot -m -c" "${DEEP_ERR[eth0]}"
assert_eq "refused query never executed" "0" "$(wc -l < "$FIX/deep_calls" | tr -d ' ')"
TOOL_PATH[mlxlink]=stub
assert_eq "mlxlink preferred over mstlink" "mlxlink" "$(deep_tool)"
TOOL_PATH[mlxlink]=""; TOOL_PATH[mstlink]=""
reset_results
check_deep
assert_eq "deep without tools N/A" "N/A" "$(sev_of mlx5.deep "$HOSTNAME")"
unset -f timeout mstlink
OUTPUT_FORMAT=table

# Real timeout(1) against a tool that ignores SIGTERM: must end as UNKNOWN within the kill grace
REAL_TIMEOUT=$(type -P timeout || true)
if [[ -n "$REAL_TIMEOUT" ]]; then
    mkdir -p "$FIX/bin"
    printf '#!/bin/bash\ntrap "" TERM\nexec sleep 30\n' > "$FIX/bin/mstlink"
    chmod +x "$FIX/bin/mstlink"
    TOOL_PATH[timeout]="$REAL_TIMEOUT"; TOOL_PATH[mstlink]="$FIX/bin/mstlink"
    SAVED_T=$DEEP_TIMEOUT SAVED_K=$DEEP_KILL_AFTER
    DEEP_TIMEOUT=1 DEEP_KILL_AFTER=1
    DEEP_KV=(); DEEP_ERR=()
    START=$SECONDS
    deep_query mstlink eth0 0000:01:00.0
    ELAPSED=$(( SECONDS - START ))
    assert_eq "TERM-ignoring tool killed within grace" "yes" "$( (( ELAPSED <= 4 )) && echo yes || echo "no (${ELAPSED}s)")"
    assert_eq "TERM-ignoring tool reported as timeout" "mstlink timed out after 1s" "${DEEP_ERR[eth0]:-}"
    DEEP_TIMEOUT=$SAVED_T DEEP_KILL_AFTER=$SAVED_K
    TOOL_PATH[timeout]=""; TOOL_PATH[mstlink]=""
fi

# Inherited (exported) functions are dropped when the script loads
# Control: the exported function is imported before the script loads, and gone after it
# shellcheck disable=SC2016  # $1 expands in the child shell
OUT=$(env 'BASH_FUNC_ethtool%%=() { echo HIJACKED; }' bash -c 'type -t ethtool; source "$1"; [[ "$(type -t ethtool)" == function ]] && echo still-function || echo dropped' _ "$SCRIPT")
assert_eq "exported functions dropped at load" "function dropped" "$(tr '\n' ' ' <<< "$OUT" | sed 's/ $//')"
# shellcheck disable=SC2329  # the function only has to exist while detect_tools runs
assert_eq "detect_tools resolves files, not functions" "yes" "$(ethtool() { :; }; TOOL_PATH=(); detect_tools; [[ "${TOOL_PATH[ethtool]:-/}" == /* ]] && echo yes)"

# --- PCIe link vs upstream port (#14) ---
# As on real systems, bus/pci/devices/<BDF> links to devices/pci0000:00/<port>/<BDF>; the
# port directory above the device holds the slot's own maxima
pcie_link() {  # pcie_link <asic>: severity|value|threshold|evidence
    local i
    reset_results; check_pcie_link "$1"
    for i in "${!REC_SEV[@]}"; do printf '%s|%s|%s|%s' "${REC_SEV[i]}" "${REC_VALUE[i]}" "${REC_THRESHOLD[i]}" "${REC_EVIDENCE[i]}"; done
}
PORT_DIR="$FIX/devices/pci0000:00/0000:00:01.1"
mkdir -p "$PORT_DIR"
mv "$SYSFS_PCI/0000:02:00.0" "$PORT_DIR/"
ln -s "$PORT_DIR/0000:02:00.0" "$SYSFS_PCI/0000:02:00.0"
# eth2 trains x4 of an x8 card: an x4 slot is by design (BCM5720 x1-of-x2 case)
printf '8.0 GT/s PCIe\n' > "$PORT_DIR/max_link_speed"; printf '4\n' > "$PORT_DIR/max_link_width"
assert_eq "slot narrower than card: OK" "OK|8.0 GT/s x4|8.0 GT/s x4 (slot)" "$(pcie_link 0000:02:00 | cut -d'|' -f1-3)"
assert_eq "slot-limited evidence" "yes" "$([[ "$(pcie_link 0000:02:00)" == *"upstream 0000:00:01.1 max_link_speed=8.0 GT/s PCIe max_link_width=4; slot-limited width: card max 8.0 GT/s x8" ]] && echo yes)"
# Slot is x8: training at x4 is a real degradation
printf '8\n' > "$PORT_DIR/max_link_width"
assert_eq "slot as wide as card, trained narrower: WARN" "WARN|8.0 GT/s x4|8.0 GT/s x8" "$(pcie_link 0000:02:00 | cut -d'|' -f1-3)"
# Slower slot: Gen2 port under a Gen3 card trained at 5.0 GT/s
printf '5.0 GT/s PCIe\n' > "$SYSFS_PCI/0000:02:00.0/current_link_speed"
printf '5.0 GT/s PCIe\n' > "$PORT_DIR/max_link_speed"; printf '4\n' > "$PORT_DIR/max_link_width"
assert_eq "slot slower and narrower: OK" "OK|5.0 GT/s x4|5.0 GT/s x4 (slot)" "$(pcie_link 0000:02:00 | cut -d'|' -f1-3)"
assert_eq "slot-limited names both" "yes" "$([[ "$(pcie_link 0000:02:00)" == *"slot-limited speed width:"* ]] && echo yes)"
# Trained below even the slot: WARN against the slot's maxima
printf '2.5 GT/s PCIe\n' > "$SYSFS_PCI/0000:02:00.0/current_link_speed"
assert_eq "below the slot too: WARN" "WARN|2.5 GT/s x4|5.0 GT/s x4 (slot)" "$(pcie_link 0000:02:00 | cut -d'|' -f1-3)"
# Upstream port without readable maxima: device maxima only (previous behaviour)
rm -f "$PORT_DIR/max_link_speed" "$PORT_DIR/max_link_width"
printf '8.0 GT/s PCIe\n' > "$SYSFS_PCI/0000:02:00.0/current_link_speed"
assert_eq "no upstream attributes: device maxima" "WARN|8.0 GT/s x4|8.0 GT/s x8" "$(pcie_link 0000:02:00 | cut -d'|' -f1-3)"
assert_eq "no upstream evidence" "yes" "$([[ "$(pcie_link 0000:02:00)" == *"no upstream port link attributes: card maxima used" ]] && echo yes)"
# Malformed or zero upstream width is ignored (0 would hide any width degradation)
printf 'garbage\n' > "$PORT_DIR/max_link_width"
assert_eq "malformed upstream width ignored" "WARN|8.0 GT/s x4|8.0 GT/s x8" "$(pcie_link 0000:02:00 | cut -d'|' -f1-3)"
printf '0\n' > "$PORT_DIR/max_link_width"
assert_eq "upstream width 0 ignored" "WARN|8.0 GT/s x4|8.0 GT/s x8" "$(pcie_link 0000:02:00 | cut -d'|' -f1-3)"
# Only the speed is readable on the port, and it is "Unknown": ignored too
rm -f "$PORT_DIR/max_link_width"; printf 'Unknown\n' > "$PORT_DIR/max_link_speed"
assert_eq "upstream speed Unknown ignored" "WARN|8.0 GT/s x4|8.0 GT/s x8" "$(pcie_link 0000:02:00 | cut -d'|' -f1-3)"
# Speed-limited only: Gen6-class card (64.0 GT/s) in a Gen5 slot, full width, no "PCIe" suffix
printf '64.0 GT/s\n' > "$SYSFS_PCI/0000:02:00.0/max_link_speed"; printf '32.0 GT/s\n' > "$SYSFS_PCI/0000:02:00.0/current_link_speed"
printf '8\n' > "$SYSFS_PCI/0000:02:00.0/current_link_width"
printf '32.0 GT/s PCIe\n' > "$PORT_DIR/max_link_speed"; printf '16\n' > "$PORT_DIR/max_link_width"
assert_eq "speed-limited only: OK" "OK|32.0 GT/s x8|32.0 GT/s x8 (slot)" "$(pcie_link 0000:02:00 | cut -d'|' -f1-3)"
assert_eq "speed-limited evidence" "yes" "$([[ "$(pcie_link 0000:02:00)" == *"slot-limited speed: card max 64.0 GT/s x8" ]] && echo yes)"
printf '8.0 GT/s PCIe\n' > "$SYSFS_PCI/0000:02:00.0/max_link_speed"; printf '8.0 GT/s PCIe\n' > "$SYSFS_PCI/0000:02:00.0/current_link_speed"
printf '4\n' > "$SYSFS_PCI/0000:02:00.0/current_link_width"
rm "$SYSFS_PCI/0000:02:00.0"
mv "$PORT_DIR/0000:02:00.0" "$SYSFS_PCI/"
rm -rf "$FIX/devices"

# --- Link state (#12): a port in use must have carrier; spare ports are not judged ---
link_state() {  # link_state <iface>: severity, value and evidence of generic.link.state
    local i
    reset_results
    check_link_state "${IFACE_PORT[$1]}"
    for i in "${!REC_SEV[@]}"; do
        printf '%s|%s|%s' "${REC_SEV[i]}" "${REC_VALUE[i]}" "${REC_EVIDENCE[i]}"
    done
}
# shellcheck disable=SC2329  # reached through TOOL_PATH[ip]
ip() {  # one query for every interface; eth30 must not match eth3, the first address wins
    [[ "$*" == "-o addr show scope global" ]] || return 9; 
    echo "9: eth30    inet 198.51.100.1/24 scope global eth30"
    [[ -e "$FIX/eth3_has_addr" ]] && printf '%s\n' "4: eth3    inet 192.0.2.10/24 brd 192.0.2.255 scope global eth3" \
        "4: eth3    inet 192.0.2.11/24 scope global secondary eth3"
    return 0
}
TOOL_PATH[ip]=ip
for P in eth0 eth1 eth2 eth3; do printf '0x1003\n' > "$SYSFS_NET/$P/flags"; done
printf '1\n' > "$SYSFS_NET/eth0/carrier"
assert_eq "link up OK" "OK|up" "$(link_state eth0 | cut -d'|' -f1,2)"
# Carrier up but traffic blocked (802.1X not authorized)
printf 'dormant\n' > "$SYSFS_NET/eth0/operstate"
assert_eq "carrier but dormant WARN" "WARN|carrier, dormant" "$(link_state eth0 | cut -d'|' -f1,2)"
printf 'up\n' > "$SYSFS_NET/eth0/operstate"
# eth1: no carrier, nothing on top
printf '0\n' > "$SYSFS_NET/eth1/carrier"; printf '1\n' > "$SYSFS_NET/eth1/carrier_up_count"; printf '1\n' > "$SYSFS_NET/eth1/carrier_down_count"
assert_eq "spare port without link N/A" "N/A|no link (unused)" "$(link_state eth1 | cut -d'|' -f1,2)"
assert_eq "spare port evidence" "yes" "$([[ "$(link_state eth1)" == *"carrier_up_count=1 carrier_down_count=1; no master, no upper device, no VFs, no global address" ]] && echo yes)"
# eth1 as a bond member: bond up -> WARN (redundancy lost), bond down -> CRIT
mkdir -p "$SYSFS_NET/bond0/bonding"; printf 'up\n' > "$SYSFS_NET/bond0/operstate"
ln -s "$SYSFS_NET/bond0" "$SYSFS_NET/eth1/master"
assert_eq "bond member without link WARN" "WARN|no link" "$(link_state eth1 | cut -d'|' -f1,2)"
assert_eq "bond member evidence" "yes" "$([[ "$(link_state eth1)" == *"in use: master=bond0" ]] && echo yes)"
printf 'down\n' > "$SYSFS_NET/bond0/operstate"
assert_eq "bond down with member CRIT" "CRIT|no link" "$(link_state eth1 | cut -d'|' -f1,2)"
# Operator downed the bond: not a fault
printf '0x1002\n' > "$SYSFS_NET/bond0/flags"
assert_eq "admin-down bond member N/A" "yes" "$([[ "$(link_state eth1)" == "N/A|no link|"*"bond0 flags=0x1002 (IFF_UP clear)" ]] && echo yes)"
rm -f "$SYSFS_NET/bond0/flags"
# Admin down wins over a master
printf '0x1002\n' > "$SYSFS_NET/eth1/flags"
assert_eq "admin-down member of a down bond N/A" "N/A|admin down" "$(link_state eth1 | cut -d'|' -f1,2)"
printf '0x1003\n' > "$SYSFS_NET/eth1/flags"
# Bond member down drives the verdict end to end
reset_results; check_link_state "${IFACE_PORT[eth1]}"; compute_verdict
assert_eq "bond down member: exit code" "CRIT 2" "$VERDICT $EXIT_CODE"
# Bridge (not a bond) master that is down: WARN, never CRIT
rm "$SYSFS_NET/eth1/master"; mkdir -p "$SYSFS_NET/br0"; printf 'down\n' > "$SYSFS_NET/br0/operstate"
ln -s "$SYSFS_NET/br0" "$SYSFS_NET/eth1/master"
assert_eq "bridge member without link WARN" "WARN|no link" "$(link_state eth1 | cut -d'|' -f1,2)"
rm "$SYSFS_NET/eth1/master"
# VLAN on top
ln -s "$SYSFS_NET/eth0" "$SYSFS_NET/eth1/upper_eth1.100"
assert_eq "port with VLAN upper in use" "yes" "$([[ "$(link_state eth1)" == "WARN|no link|"*"in use: upper=eth1.100" ]] && echo yes)"
rm "$SYSFS_NET/eth1/upper_eth1.100"
# Address only (no master/upper), from ip
printf '0\n' > "$SYSFS_NET/eth3/carrier"; : > "$FIX/eth3_has_addr"
assert_eq "port with global address in use" "yes" "$([[ "$(link_state eth3)" == "WARN|no link|"*"in use: address=192.0.2.10/24" ]] && echo yes)"
rm -f "$FIX/eth3_has_addr"
# ip failing or missing: never "spare" (the port may be used only through an address)
# shellcheck disable=SC2329
ip() { echo "Cannot open netlink socket"; return 2; }
assert_eq "ip failure: use unknown, UNKNOWN" "yes" "$([[ "$(link_state eth3)" == "UNKNOWN|no link (use unknown)|"*"addresses not checked: ip exit 2: Cannot open netlink socket" ]] && echo yes)"
TOOL_PATH[ip]=""
assert_eq "without ip: UNKNOWN, not spare" "yes" "$([[ "$(link_state eth3)" == "UNKNOWN|no link (use unknown)|"*"addresses not checked: ip missing" ]] && echo yes)"
# A port that had link more than the driver-init toggle is never silently spare
printf '3\n' > "$SYSFS_NET/eth3/carrier_up_count"
assert_eq "had link this boot, no use found: WARN" "WARN|no link (had link)" "$(link_state eth3 | cut -d'|' -f1,2)"
rm -f "$SYSFS_NET/eth3/carrier_up_count"
TOOL_PATH[ip]=ip
# SR-IOV PF with VFs (e.g. passed to VMs) is in use
printf '8\n' > "$FIX/bus/pci/devices/0000:03:00.0/sriov_numvfs"
assert_eq "PF with VFs in use" "yes" "$([[ "$(link_state eth3)" == "WARN|no link|"*"in use: vfs=8" ]] && echo yes)"
rm -f "$FIX/bus/pci/devices/0000:03:00.0/sriov_numvfs"
# IPv6-only global address
# shellcheck disable=SC2329
ip() { [[ "$*" == "-o addr show scope global" ]] || return 9; echo "4: eth3    inet6 2001:db8::1/64 scope global"; }
assert_eq "IPv6-only address in use" "yes" "$([[ "$(link_state eth3)" == "WARN|no link|"*"in use: address=2001:db8::1/64" ]] && echo yes)"
TOOL_PATH[ip]=""

# Service-impact facts in generic.link.state metrics (nic-sweep design P3): every port, up or down;
# the reasons come from the same scan that judges a port without link
SAVED_PROC_BONDING="$PROC_BONDING"
PROC_BONDING="$FIX/proc_bonding"
mkdir -p "$PROC_BONDING" "$SYSFS_NET/eth0/statistics" "$SYSFS_NET/eth1/statistics" "$SYSFS_NET/bond7/bonding" "$SYSFS_NET/br7/bridge" "$SYSFS_NET/ovs-system"
cat > "$PROC_BONDING/bond7" <<'EOF'
Ethernet Channel Bonding Driver: v6.8.0

Bonding Mode: IEEE 802.3ad Dynamic link aggregation
MII Status: up

Slave Interface: eth0
MII Status: up
Speed: 25000 Mbps
Link Failure Count: 0
Permanent HW addr: aa:bb:cc:00:00:01

Slave Interface: eth1
MII Status: down
Speed: Unknown
Link Failure Count: 3
EOF
printf 'up\n' > "$SYSFS_NET/bond7/operstate"
printf '123456789\n' > "$SYSFS_NET/eth0/statistics/rx_bytes"; printf '42\n' > "$SYSFS_NET/eth0/statistics/tx_bytes"
for P in eth0 eth1; do ln -s "$SYSFS_NET/bond7" "$SYSFS_NET/$P/master"; ln -s "$SYSFS_NET/bond7" "$SYSFS_NET/$P/upper_bond7"; done
# shellcheck disable=SC2329  # reached through TOOL_PATH[ip]
ip() { [[ "$*" == "-o addr show scope global" ]] || return 9; echo "4: eth3    inet 192.0.2.10/24 brd 192.0.2.255 scope global eth3"; }
TOOL_PATH[ip]=ip
assert_eq "bond_link_failures per slave" "0 3" "$(bond_link_failures bond7 eth0) $(bond_link_failures bond7 eth1)"
assert_eq "bond_link_failures: slave not listed" "fail" "$(bond_link_failures bond7 eth9 || echo fail)"
assert_eq "bond_link_failures: no state file" "fail" "$(bond_link_failures bond9 eth0 || echo fail)"
INTERVAL=5
snapshot SNAP0 DL_SCRATCH
assert_eq "traffic counters sampled with the others" "123456789 42" "${SNAP0[stat|eth0|rx_bytes]} ${SNAP0[stat|eth0|tx_bytes]}"
SNAP1=(["stat|eth0|rx_bytes"]=123999999 ["stat|eth0|tx_bytes"]=42 ["stat|eth1|rx_bytes"]=5 ["stat|eth1|tx_bytes"]=3)
SNAP0=(["stat|eth0|rx_bytes"]=123456789 ["stat|eth0|tx_bytes"]=42 ["stat|eth1|rx_bytes"]=9)
reset_results; check_link_state "${IFACE_PORT[eth0]}"
assert_eq "P3 bond member with link: facts, traffic in the window" '"carrier": true, "operstate": "up", "in_use": true, "in_use_reasons": ["bond"], "bond": "bond7", "bond_link_failures": 0, "rx_bytes": {"total": 123999999, "delta": 543210}, "tx_bytes": {"total": 42, "delta": 0}' \
    "$(metrics_of generic.link.state eth0)"
# shellcheck disable=SC2329  # the counting stub is reached through TOOL_PATH[ip]
assert_eq "one ip query for every port" "1" "$(reset_results; : > "$FIX/ip_calls"
    ip() { echo x >> "$FIX/ip_calls"; return 0; }
    for P in eth0 eth1 eth2 eth3; do check_link_state "${IFACE_PORT[$P]}"; done; wc -l < "$FIX/ip_calls" | tr -d ' ')"
assert_eq "P3 bond member with link: value and evidence unchanged" "OK|up|operstate=up; carrier_up_count=n/a carrier_down_count=n/a" "$(link_state eth0)"
reset_results; check_link_state "${IFACE_PORT[eth1]}"
assert_eq "P3 bond member without link: a reset or a counter new at T1 gives the total only" '"carrier": false, "operstate": "up", "carrier_up_count": 1, "carrier_down_count": 1, "in_use": true, "in_use_reasons": ["bond"], "bond": "bond7", "bond_link_failures": 3, "rx_bytes": {"total": 5}, "tx_bytes": {"total": 3}' \
    "$(metrics_of generic.link.state eth1)"
INTERVAL=0
reset_results; check_link_state "${IFACE_PORT[eth0]}"
assert_eq "P3 absolute mode: traffic totals only" "yes" "$([[ "$(metrics_of generic.link.state eth0)" == *'"rx_bytes": {"total": 123999999}, "tx_bytes": {"total": 42}' ]] && echo yes)"
INTERVAL=5
assert_eq "P3 bond member without link: evidence unchanged" "WARN|no link|operstate=up; carrier_up_count=1 carrier_down_count=1; in use: master=bond7" "$(link_state eth1)"
COLLECTED_AT="2026-10-20T00:00:00Z"
json_strict_check "JSON with service-impact facts"
# Bridge member with a VLAN upper, VFs and an address: every reason, in order; the master's own upper
# link is not a second reason
ln -s "$SYSFS_NET/br7" "$SYSFS_NET/eth3/master"; ln -s "$SYSFS_NET/br7" "$SYSFS_NET/eth3/upper_br7"
ln -s "$SYSFS_NET/eth0" "$SYSFS_NET/eth3/upper_eth3.100"
printf '4\n' > "$FIX/bus/pci/devices/0000:03:00.0/sriov_numvfs"
reset_results; check_link_state "${IFACE_PORT[eth3]}"
assert_eq "P3 all reasons" '"in_use": true, "in_use_reasons": ["bridge", "upper", "sriov_vfs", "global_address"]' \
    "$(metrics_of generic.link.state eth3 | grep -o '"in_use".*\]')"
assert_eq "P3 all reasons: evidence names the first" "yes" "$([[ "$(link_state eth3)" == "WARN|no link|"*"; in use: master=br7" ]] && echo yes)"
assert_eq "P3 bridge: no bond fact" "no" "$([[ "$(metrics_of generic.link.state eth3)" == *'"bond'* ]] && echo yes || echo no)"
reset_results
for P in eth0 eth1 eth2 eth3; do check_link_state "${IFACE_PORT[$P]}"; done
dump_json p3-link-state
rm -f "${SYSFS_NET:?}/eth3/master" "${SYSFS_NET:?}/eth3/upper_br7"
ln -s "$SYSFS_NET/ovs-system" "$SYSFS_NET/eth3/master"
reset_results; check_link_state "${IFACE_PORT[eth3]}"
assert_eq "P3 other master (OVS) is an upper" '"in_use_reasons": ["upper", "sriov_vfs", "global_address"]' "$(metrics_of generic.link.state eth3 | grep -o '"in_use_reasons".*\]')"
rm -f "${SYSFS_NET:?}/eth3/master" "${SYSFS_NET:?}/eth3/upper_eth3.100" "${FIX:?}/bus/pci/devices/0000:03:00.0/sriov_numvfs"
# Spare port: not in use, no reasons; ip failing: in_use left out, never guessed
reset_results; check_link_state "${IFACE_PORT[eth2]}"
assert_eq "P3 spare port" '"in_use": false, "in_use_reasons": []' "$(metrics_of generic.link.state eth2 | grep -o '"in_use".*\]')"
# shellcheck disable=SC2329
ip() { echo "Cannot open netlink socket"; return 2; }
reset_results; check_link_state "${IFACE_PORT[eth2]}"
assert_eq "P3 use undetermined: in_use left out" "no" "$([[ "$(metrics_of generic.link.state eth2)" == *in_use* ]] && echo yes || echo no)"
reset_results; check_link_state "${IFACE_PORT[eth0]}"
assert_eq "P3 ip failing does not hide the bond, reasons marked incomplete" "yes" "$([[ "$(metrics_of generic.link.state eth0)" == *'"in_use": true, "in_use_reasons": ["bond"], "in_use_reasons_complete": false'* ]] && echo yes)"
reset_results; check_link_state "${IFACE_PORT[eth1]}"
assert_eq "P3 ip failing: evidence of a port without link unchanged" "yes" "$([[ "$(link_state eth1)" == "WARN|no link|"*"; in use: master=bond7" ]] && echo yes)"
# Admin down: facts still recorded
printf '0x1002\n' > "$SYSFS_NET/eth0/flags"
reset_results; check_link_state "${IFACE_PORT[eth0]}"
assert_eq "P3 admin down still has facts" "N/A|yes" "$(sev_of generic.link.state eth0)|$([[ "$(metrics_of generic.link.state eth0)" == *'"bond": "bond7"'* ]] && echo yes)"
printf '0x1003\n' > "$SYSFS_NET/eth0/flags"
for P in eth0 eth1; do rm -f "${SYSFS_NET:?}/${P:?}/master" "${SYSFS_NET:?}/${P:?}/upper_bond7"; done
rm -rf "${SYSFS_NET:?}/eth0/statistics" "${SYSFS_NET:?}/eth1/statistics" "${SYSFS_NET:?}/bond7" "${SYSFS_NET:?}/br7" "${SYSFS_NET:?}/ovs-system" "${FIX:?}/proc_bonding"
PROC_BONDING="$SAVED_PROC_BONDING"
TOOL_PATH[ip]=""
# Admin down is operator intent, not a fault
printf '0x1002\n' > "$SYSFS_NET/eth1/flags"
assert_eq "admin down N/A" "N/A|admin down" "$(link_state eth1 | cut -d'|' -f1,2)"
# Carrier unreadable (admin down) falls back to operstate
rm -f "$SYSFS_NET/eth0/carrier"
assert_eq "no carrier file: operstate up is link" "OK" "$(link_state eth0 | cut -d'|' -f1)"
for P in eth0 eth1 eth2 eth3; do rm -f "$SYSFS_NET/$P/flags" "$SYSFS_NET/$P/carrier" "$SYSFS_NET/$P/carrier_up_count" "$SYSFS_NET/$P/carrier_down_count"; done
rm -rf "$SYSFS_NET/bond0" "$SYSFS_NET/br0"
unset -f ip

# --- Link-down look-back (-L/--lookback) ---
# Real mlx5 and bond lines (Ubuntu 24.04), other driver spellings, and negative cases
cat > "$FIX/kernel_log" <<'EOF'
mlx5_core 0000:01:00.0 eth0: Link down
bond0: (slave eth0): speed changed to 0 on port 1
bond0: (slave eth0): link status definitely down, disabling slave
mlx5_core 0000:01:00.0 eth0: Link up
bond0: (slave eth0): link status definitely up, 25000 Mbps full duplex
mlx5_core 0000:01:00.0 eth0: Link down
ixgbe 0000:03:00.0 eth3: NIC Link is Down
igb 0000:05:00.0 eth2: igb: eth2 NIC Link is Down
tg3 0000:c3:00.0 eth2: Link is down.
br0: port 1(eth1) entered disabled state
ice 0000:3b:00.0 eth10: NIC Link is Down
eth1: Link downshift occurred
mlx5_core 0000:01:00.1 eth1: Link up
EOF
declare -A LD=()
count_link_downs LD < "$FIX/kernel_log"
assert_eq "lookback mlx5 downs (bond lines not counted)" "2" "${LD[eth0]}"
assert_eq "lookback igb + tg3 spellings" "2" "${LD[eth2]}"
assert_eq "lookback ixgbe NIC Link is Down" "1" "${LD[eth3]}"
assert_eq "lookback eth1: bridge, eth10, downshift and up ignored" "0" "${LD[eth1]}"
assert_eq "lookback unknown port not added" "" "${LD[eth10]:-}"

# Interface names may contain '$(' (only '/', ':' and spaces are forbidden): never evaluated
SAVED_PORTS=("${PORT_IFACE[@]}")
# (no literal space: the kernel forbids it; ${IFS} becomes one only if the name were evaluated)
# shellcheck disable=SC2016  # the literal $( is the point of the test
HOSTILE='x$(touch${IFS}'"$FIX"'/pwned)'
PORT_IFACE=("$HOSTILE")
count_link_downs LD <<< "drv 0000:01:00.0 $HOSTILE: Link down"
assert_eq "lookback hostile ifname counted, not executed" "1 no" "${LD[$HOSTILE]} $([[ -e "$FIX/pwned" ]] && echo yes || echo no)"
PORT_IFACE=("${SAVED_PORTS[@]}")

# collect_lookback runs journalctl read-only with the window in minutes
mkdir -p "$FIX/bin"
JOURNAL_STUB="$FIX/bin/journalctl"
journal_stub() {  # journal_stub <exit code> [message instead of the kernel log]
    if [[ -n "${2:-}" ]]; then
        printf '#!/bin/bash\nprintf "%%s\\n" "$*" > "%s/journal_argv"\necho "%s" >&2\nexit %s\n' "$FIX" "$2" "$1" > "$JOURNAL_STUB"
    else
        printf '#!/bin/bash\nprintf "%%s\\n" "$*" > "%s/journal_argv"\ncat "%s/kernel_log"\nexit %s\n' "$FIX" "$FIX" "$1" > "$JOURNAL_STUB"
    fi
    chmod +x "$JOURNAL_STUB"
}
lookback_run() {  # reset and collect
    LOOKBACK_STATE=""; LOOKBACK_ERR=""; LOOKBACK_DOWNS=()
    collect_lookback
}
SAVED_TIMEOUT="${TOOL_PATH[timeout]:-}"
TOOL_PATH[timeout]=""
TOOL_PATH[journalctl]="$JOURNAL_STUB"
LOOKBACK=60
journal_stub 0
lookback_run
assert_eq "lookback state ok" "$LOOKBACK_OK" "$LOOKBACK_STATE"
assert_eq "lookback journalctl argv" "-k -q --no-pager -o cat --since -60min" "$(< "$FIX/journal_argv")"
assert_eq "lookback collected eth0" "2" "${LOOKBACK_DOWNS[eth0]}"

journal_stub 1 "No journal files were found."
lookback_run
assert_eq "lookback no journal files: absent" "$LOOKBACK_ABSENT" "$LOOKBACK_STATE"
reset_results; check_lookback
assert_eq "lookback absent journal host N/A" "N/A" "$(sev_of generic.link.lookback "$HOSTNAME")"
assert_eq "lookback absent: no port rows" "MISSING" "$(sev_of generic.link.lookback eth0)"

journal_stub 1 "Data from the specified boot (+0) is not available: No such boot ID in journal"
lookback_run
assert_eq "lookback no current boot: absent" "$LOOKBACK_ABSENT" "$LOOKBACK_STATE"

journal_stub 1 "Failed to open journal: Permission denied"
lookback_run
reset_results; check_lookback
assert_eq "lookback journalctl failure UNKNOWN" "UNKNOWN" "$(sev_of generic.link.lookback "$HOSTNAME")"
assert_eq "lookback failure evidence" "journalctl exit 1: Failed to open journal: Permission denied" "$LOOKBACK_ERR"

# Journal content is never read as a journalctl error, even when it says "is not available"
printf '#!/bin/bash\necho "platform foo: firmware feature is not available"\necho "Journal file /var/log/journal/x.journal is truncated, ignoring file." >&2\nexit 1\n' > "$JOURNAL_STUB"
lookback_run
assert_eq "lookback content not taken as absent journal" "$LOOKBACK_FAILED" "$LOOKBACK_STATE"
assert_eq "lookback error from stderr only" "journalctl exit 1: Journal file /var/log/journal/x.journal is truncated, ignoring file." "$LOOKBACK_ERR"

TOOL_PATH[journalctl]=""
lookback_run
reset_results; check_lookback
assert_eq "lookback without journalctl N/A" "N/A" "$(sev_of generic.link.lookback "$HOSTNAME")"

LOOKBACK=0
TOOL_PATH[journalctl]="$JOURNAL_STUB"
journal_stub 0
lookback_run
reset_results; check_lookback
assert_eq "lookback 0: nothing collected" "" "$LOOKBACK_STATE"
assert_eq "lookback 0: no rows" "0" "${#REC_SEV[@]}"
LOOKBACK=60

# Severity: history alone WARN; CRIT only with repeated downs and still flapping in the window
INTERVAL=5
LOOKBACK_STATE="$LOOKBACK_OK"
LOOKBACK_DOWNS=([eth0]=5 [eth1]=5 [eth2]=1 [eth3]=0)
SNAP0=(["carrier|eth0"]=10 ["carrier|eth1"]=10 ["carrier|eth2"]=10 ["carrier|eth3"]=10)
SNAP1=(["carrier|eth0"]=12 ["carrier|eth1"]=10 ["carrier|eth2"]=12 ["carrier|eth3"]=10)
printf '7\n' > "$SYSFS_NET/eth0/carrier_down_count"
reset_results; check_lookback
assert_eq "lookback repeated + flapping CRIT" "CRIT" "$(sev_of generic.link.lookback eth0)"
assert_eq "lookback repeated, not flapping now WARN" "WARN" "$(sev_of generic.link.lookback eth1)"
assert_eq "lookback single down while flapping WARN" "WARN" "$(sev_of generic.link.lookback eth2)"
assert_eq "lookback no downs OK" "OK" "$(sev_of generic.link.lookback eth3)"
assert_eq "lookback one row per port" "1" "$(count_of generic.link.lookback eth0)"
for i in "${!REC_SEV[@]}"; do
    [[ "${REC_CHECK[i]} ${REC_TARGET[i]}" == "generic.link.lookback eth0" ]] && LB_EVIDENCE="${REC_EVIDENCE[i]}" LB_VALUE="${REC_VALUE[i]} ${REC_UNIT[i]}"
done
assert_eq "lookback value and unit" "5 link-down/60m" "$LB_VALUE"
assert_eq "lookback evidence has carrier_down_count" "yes" "$([[ "$LB_EVIDENCE" == *"carrier_down_count=7"* && "$LB_EVIDENCE" == *"carrier_changes +2 in window"* ]] && echo yes)"
assert_eq "lookback evidence without carrier_down_count" "yes" "$(reset_results; check_lookback; for i in "${!REC_SEV[@]}"; do [[ "${REC_TARGET[i]}" == eth1 && "${REC_CHECK[i]}" == generic.link.lookback && "${REC_EVIDENCE[i]}" == *"carrier_down_count=n/a"* ]] && echo yes; done)"
rm -f "$SYSFS_NET/eth0/carrier_down_count"

# Boot inside the window is called out (the journal query stops at boot)
SAVED_UPTIME=$(< "$FIX/uptime")
printf '600.00 0\n' > "$FIX/uptime"
reset_results; check_lookback
assert_eq "lookback window truncated at boot" "yes" "$(for i in "${!REC_SEV[@]}"; do [[ "${REC_TARGET[i]}" == eth3 && "${REC_EVIDENCE[i]}" == *"boot was 10 min ago"* ]] && echo yes; done)"
printf '%s\n' "$SAVED_UPTIME" > "$FIX/uptime"

# Absolute mode (-I 0): no window, so history is never CRIT
INTERVAL=0
reset_results; check_lookback
assert_eq "lookback absolute mode WARN" "WARN" "$(sev_of generic.link.lookback eth0)"
INTERVAL=5

# Real timeout(1) bounds a hung journalctl: argv is wrapped, and both exit paths (TERM honoured:
# 124; TERM ignored, killed: 137) are timeouts, even when partial output says "is not available"
if [[ -n "$REAL_TIMEOUT" ]]; then
    TOOL_PATH[timeout]="$REAL_TIMEOUT"
    SAVED_JT=$JOURNAL_TIMEOUT SAVED_JK=$JOURNAL_KILL_AFTER
    JOURNAL_TIMEOUT=1 JOURNAL_KILL_AFTER=1
    journal_stub 0
    lookback_run
    assert_eq "lookback via timeout(1) argv" "$LOOKBACK_OK -k -q --no-pager -o cat --since -60min" "$LOOKBACK_STATE $(< "$FIX/journal_argv")"
    printf '#!/bin/bash\nexec sleep 30\n' > "$JOURNAL_STUB"
    lookback_run
    assert_eq "lookback journalctl TERM timeout UNKNOWN" "$LOOKBACK_FAILED journalctl timed out after 1s" "$LOOKBACK_STATE $LOOKBACK_ERR"
    printf '#!/bin/bash\ntrap "" TERM\necho "foo: feature is not available"\nexec sleep 30\n' > "$JOURNAL_STUB"
    lookback_run
    assert_eq "lookback journalctl killed (partial output) UNKNOWN" "$LOOKBACK_FAILED journalctl timed out after 1s" "$LOOKBACK_STATE $LOOKBACK_ERR"
    JOURNAL_TIMEOUT=$SAVED_JT JOURNAL_KILL_AFTER=$SAVED_JK
else
    echo "⏭️  SKIP lookback timeout tests: timeout(1) not found"
fi
TOOL_PATH[timeout]="$SAVED_TIMEOUT"
TOOL_PATH[journalctl]=""
LOOKBACK_STATE=""

# JSON header carries the window
assert_eq "json lookback_min" "yes" "$(render_json | grep -q '"lookback_min": 60,' && echo yes)"

# --- Host uptime and boot ID in the JSON envelope (nic-sweep design P1) ---
BOOT_UUID="0f1e2d3c-4b5a-4968-8778-a6b5c4d3e2f1"
PROC_BOOT_ID="$FIX/boot_id"
printf '%s\n' "$BOOT_UUID" > "$PROC_BOOT_ID"
assert_eq "boot_id read" "$BOOT_UUID" "$(read_boot_id)"
printf 'not-a-uuid\n' > "$PROC_BOOT_ID"
RC=0; OUT=$(read_boot_id) || RC=$?
assert_eq "boot_id malformed fails" "1 " "$RC $OUT"
: > "$PROC_BOOT_ID"
RC=0; read_boot_id >/dev/null || RC=$?
assert_eq "boot_id empty fails" "1" "$RC"
rm -f "$PROC_BOOT_ID"
RC=0; read_boot_id >/dev/null 2>&1 || RC=$?
assert_eq "boot_id missing fails" "1" "$RC"

printf '4844149.08 306790526.43\n' > "$FIX/uptime"
assert_eq "uptime whole seconds" "4844149" "$(uptime_seconds)"
printf 'garbage\n' > "$FIX/uptime"
RC=0; uptime_seconds >/dev/null || RC=$?
assert_eq "uptime seconds malformed fails" "1" "$RC"

# Captured together; unknown sources leave the values empty
printf '%s\n' "$BOOT_UUID" > "$PROC_BOOT_ID"
printf '4844149.08 306790526.43\n' > "$FIX/uptime"
capture_host_clock
assert_eq "captured uptime and boot ID" "4844149 $BOOT_UUID" "$HOST_UPTIME_S $HOST_BOOT_ID"
assert_eq "json uptime_s" "yes" "$(render_json | grep -q '"uptime_s": 4844149,' && echo yes)"
assert_eq "json boot_id" "yes" "$(render_json | grep -q "\"boot_id\": \"$BOOT_UUID\"," && echo yes)"
assert_eq "json order: collected_at, uptime_s, boot_id" "collected_at uptime_s boot_id" \
    "$(render_json | grep -o -E '^  "(collected_at|uptime_s|boot_id)"' | tr -d ' "' | tr '\n' ' ' | sed 's/ $//')"

PROC_BOOT_ID="$FIX/no_such_boot_id"
printf 'garbage\n' > "$FIX/uptime"
HOST_UPTIME_S="stale"; HOST_BOOT_ID="stale"
capture_host_clock
assert_eq "unknown uptime and boot ID are empty" "|" "$HOST_UPTIME_S|$HOST_BOOT_ID"
assert_eq "json uptime_s null" "yes" "$(render_json | grep -q '"uptime_s": null,' && echo yes)"
assert_eq "json boot_id null" "yes" "$(render_json | grep -q '"boot_id": null,' && echo yes)"
if command -v python3 &>/dev/null; then
    if render_json | python3 -I -c 'import json,sys; d=json.load(sys.stdin); assert d["uptime_s"] is None and d["boot_id"] is None and d["schema_version"] == 2' 2>/dev/null; then
        (( ++PASS ))
    else
        (( ++FAIL )); echo "❌ render_json with unknown uptime/boot ID is not valid JSON"
    fi
fi
assert_eq "CSV header unchanged" "severity,scope,target,check_id,value,unit,threshold,evidence,hint,ref" "$(render_csv | head -1)"

# Strict shell: missing sources must not abort under set -e / set -u
( set -euo pipefail; PROC_BOOT_ID="$FIX/no_such_boot_id"; PROC_UPTIME="$FIX/no_such_uptime"; capture_host_clock; echo "finished" ) > "$FIX/out" 2>&1
assert_eq "set -euo pipefail with missing uptime/boot ID" "finished" "$(tail -1 "$FIX/out")"
printf '4844149.08 306790526.43\n' > "$FIX/uptime"

# --- Verdict precedence ---
for CASE in "OK N/A:OK 0" "OK UNKNOWN:UNKNOWN 3" "WARN UNKNOWN:WARN 1" "WARN CRIT UNKNOWN:CRIT 2"; do
    read -ra REC_SEV <<< "${CASE%%:*}"
    compute_verdict
    assert_eq "verdict for ${CASE%%:*}" "${CASE#*:}" "$VERDICT $EXIT_CODE"
done

# --- CLI (runs before the root check, so works unprivileged) ---
for CASE in "-l deep -v:0" "--level=basic -v:0" "-l bogus:3" "-a -v:0" "--all -v:0" "-v:0" "-I 99999:3" "-I abc:3" "-L 0 -v:0" "--lookback=1440 -v:0" "-L 1441:3" "-L abc:3" "-L 99999999999999999999:3" "-L 0001440 -v:0" "-I 0005 -v:0" "-I 18446744073709551621:3" "-O xml:3" "extra:3" "--bogus:3"; do
    # shellcheck disable=SC2086
    bash "$SCRIPT" ${CASE%%:*} >/dev/null 2>&1
    assert_eq "exit code for '${CASE%%:*}'" "${CASE#*:}" "$?"
done
bash "$SCRIPT" -i '' >/dev/null 2>&1
assert_eq "exit code for empty -i" "3" "$?"

# JSON fixtures: regenerate on request, else they must match what this script writes now
if [[ "${NIC_HEALTH_UPDATE_FIXTURES:-}" == "1" ]]; then
    mkdir -p "$JSON_FIXTURES"
    cp "$JSON_OUT"/*.json "$JSON_FIXTURES/"
    echo "📝 JSON fixtures written to $JSON_FIXTURES"
fi
for F in "$JSON_OUT"/*.json; do
    assert_eq "JSON fixture ${F##*/} is current (make fixtures)" "same" \
        "$(cmp -s "$F" "$JSON_FIXTURES/${F##*/}" && echo same || echo differs)"
done
FIXTURE_NAMES=""
for F in "$JSON_FIXTURES"/*.json; do [[ -e "$JSON_OUT/${F##*/}" ]] || FIXTURE_NAMES+="${F##*/} "; done
assert_eq "no stale JSON fixture" "" "$FIXTURE_NAMES"

echo
if (( FAIL > 0 )); then
    echo "❌ $FAIL failed, $PASS passed"
    exit 1
fi
echo "✅ All $PASS tests passed"
