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
    printf 'driver: stub\nfirmware-version: 1.2.3 (STUB)\nbus-info: x\n'
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
assert_eq "mlx5 not run on other drivers" "MISSING" "$(sev_of mlx5.rx.starvation eth2)"
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
reset_results
ets_write eth0 rx_bits_phy=0
grow2() { ets_write eth0 rx_bits_phy=1000000000 rx_corrected_bits_phy=2000; }
snap_pair grow2
check_mlx5_port 0
assert_eq "mlx5 pre-FEC BER>1e-6 WARN"   "WARN"    "$(sev_of mlx5.phy.errors eth0)"
assert_eq "mlx5 BER value"               "pre-FEC BER=2.0e-06" "$(mlx5_rec REC_VALUE mlx5.phy.errors eth0)"
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
snap_pair huge
check_mlx5_port 0
assert_eq "overflow-safe BER WARN" "WARN" "$(sev_of mlx5.phy.errors eth0)"
assert_eq "overflow-safe BER value" "pre-FEC BER=1.0e-05" "$(mlx5_rec REC_VALUE mlx5.phy.errors eth0)"
assert_eq "overflow-safe lane hint" "yes" "$([[ "$(mlx5_rec REC_HINT mlx5.phy.errors eth0)" == *"concentrated on rx_err_lane_1_phy"* ]] && echo yes)"
assert_eq "bits counter not listed as context" "no" "$([[ "$(mlx5_rec REC_HINT mlx5.phy.errors eth0)" == *rx_bits_phy* ]] && echo yes || echo no)"

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
assert_eq "mlxlink BER evidence names tool counter" "yes" "$([[ "$(mlx5_rec REC_EVIDENCE mlx5.deep.ber eth0)" == *"Link Down Counter=331"* ]] && echo yes)"
assert_eq "mlxlink module (Rx -8.069 in range) OK" "OK" "$(sev_of mlx5.deep.module eth0)"
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
ip() { [[ "$5" == "eth3" && -e "$FIX/eth3_has_addr" ]] && echo "4: eth3    inet 192.0.2.10/24 brd 192.0.2.255 scope global eth3"; return 0; }
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
ip() { [[ "$5" == "eth3" ]] && echo "4: eth3    inet6 2001:db8::1/64 scope global"; return 0; }
assert_eq "IPv6-only address in use" "yes" "$([[ "$(link_state eth3)" == "WARN|no link|"*"in use: address=2001:db8::1/64" ]] && echo yes)"
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

echo
if (( FAIL > 0 )); then
    echo "❌ $FAIL failed, $PASS passed"
    exit 1
fi
echo "✅ All $PASS tests passed"
