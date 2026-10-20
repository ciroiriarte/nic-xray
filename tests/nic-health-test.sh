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
    REC_THRESHOLD=(); REC_SEV=(); REC_EVIDENCE=(); REC_HINT=(); REC_REF=()
}

# --- Pure helpers ---

assert_eq "pcie speed 16.0" "160" "$(pcie_speed_tenths "16.0 GT/s PCIe")"
assert_eq "pcie speed 2.5"  "25"  "$(pcie_speed_tenths "2.5 GT/s PCIe")"
assert_eq "pcie speed 8 (no decimal)" "80" "$(pcie_speed_tenths "8 GT/s")"
assert_eq "pcie speed Unknown" "" "$(pcie_speed_tenths "Unknown")"

printf '4844149.08 306790526.43\n' > "$FIX/uptime"
PROC_UPTIME="$FIX/uptime"
assert_eq "uptime centiseconds" "484414908" "$(uptime_cs)"

assert_eq "json_escape control chars" 'a\"b\\c\nd\u001be' "$(json_escape $'a"b\\c\nd\x1be')"
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
ethtool() { printf 'driver: stub\nfirmware-version: 1.2.3 (STUB)\nbus-info: x\n'; }
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

if command -v python3 &>/dev/null; then
    COLLECTED_AT="2026-10-20T00:00:00Z"
    if render_json | python3 -I -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
        (( ++PASS ))
    else
        (( ++FAIL )); echo "❌ render_json produced invalid JSON"
    fi
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

# --- Verdict precedence ---
for CASE in "OK N/A:OK 0" "OK UNKNOWN:UNKNOWN 3" "WARN UNKNOWN:WARN 1" "WARN CRIT UNKNOWN:CRIT 2"; do
    read -ra REC_SEV <<< "${CASE%%:*}"
    compute_verdict
    assert_eq "verdict for ${CASE%%:*}" "${CASE#*:}" "$VERDICT $EXIT_CODE"
done

# --- CLI (runs before the root check, so works unprivileged) ---
for CASE in "-v:0" "-I 99999:3" "-I abc:3" "-O xml:3" "extra:3" "--bogus:3"; do
    # shellcheck disable=SC2086
    bash "$SCRIPT" ${CASE%%:*} >/dev/null 2>&1
    assert_eq "exit code for '${CASE%%:*}'" "${CASE#*:}" "$?"
done
bash "$SCRIPT" -i '' >/dev/null 2>&1
assert_eq "exit code for empty -i" "3" "$?"

echo
if (( FAIL > 0 )); then
    echo "❌ $FAIL failed, $PASS passed"
    exit 1
fi
echo "✅ All $PASS tests passed"
