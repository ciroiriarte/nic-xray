#!/bin/bash
# Tests for nic-sweep.sh: unit tests of sourced helpers, then end-to-end runs against a stub ssh
# that plays every host status (design docs/design/nic-sweep.md §5).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/nic-sweep.sh"
PASS=0
FAIL=0
FIX=$(mktemp -d "${TMPDIR:-/tmp}/nic-sweep-test.XXXXXX")
trap 'rm -rf "$FIX"' EXIT

assert_eq() {  # assert_eq <description> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf '❌ %s\n   expected: %s\n   actual:   %s\n\n' "$1" "$2" "$3"
    fi
}

if ! command -v jq &>/dev/null; then
    echo "⏭️  SKIP nic-sweep tests: jq not found (nic-sweep.sh requires it)"
    exit 0
fi

# --- Unit tests (sourced) ---
# shellcheck source-path=SCRIPTDIR source=../nic-sweep.sh
source "$SCRIPT"

assert_eq "bounded_uint in range"      "8"    "$(bounded_uint 8 1 256)"
assert_eq "bounded_uint leading zeros" "30"   "$(bounded_uint 0030 0 3600)"
assert_eq "bounded_uint below min"     "fail" "$(bounded_uint 0 1 256 || echo fail)"
assert_eq "bounded_uint above max"     "fail" "$(bounded_uint 257 1 256 || echo fail)"
assert_eq "bounded_uint huge (no wrap)" "fail" "$(bounded_uint 99999999999999999999 1 256 || echo fail)"
assert_eq "bounded_uint not a number"  "fail" "$(bounded_uint 5s 1 256 || echo fail)"
assert_eq "trim" "x y" "$(trim $'  x y \t')"

printf '{"verdict":"OK","results":[]}' > "$FIX/good.json"
printf 'garbage' > "$FIX/bad.json"
: > "$FIX/empty.err"
printf 'sudo: a password is required\n' > "$FIX/sudo.err"
assert_eq "classify valid JSON wins over exit code" "ok" "$(classify 1 "$FIX/good.json" "$FIX/empty.err")"
assert_eq "classify timeout"     "timeout"      "$(classify 124 "$FIX/bad.json" "$FIX/empty.err")"
assert_eq "classify killed"      "timeout"      "$(classify 137 "$FIX/bad.json" "$FIX/empty.err")"
assert_eq "classify ssh failure" "ssh-fail"     "$(classify 255 "$FIX/bad.json" "$FIX/empty.err")"
assert_eq "classify tool absent" "tool-missing" "$(classify 127 "$FIX/bad.json" "$FIX/empty.err")"
assert_eq "classify sudo denied" "sudo-fail"    "$(classify 1 "$FIX/bad.json" "$FIX/sudo.err")"
assert_eq "classify garbage"     "bad-output"   "$(classify 0 "$FIX/bad.json" "$FIX/empty.err")"
: > "$FIX/empty.json"
assert_eq "classify empty output is not ok (jq 1.6 exits 0 on it)" "bad-output" "$(classify 0 "$FIX/empty.json" "$FIX/empty.err")"
# jq accepts non-finite numbers; strict JSON does not
printf '{"verdict":"OK","results":[{"rx": -inf}]}' > "$FIX/inf.json"
assert_eq "classify non-finite number is bad-output" "bad-output" "$(classify 0 "$FIX/inf.json" "$FIX/empty.err")"
printf '[{"optics": {"rx_power_dbm": -inf}}]' > "$FIX/xinf.json"
printf '[\n  1.0,\n  -inf\n]\n' > "$FIX/xinf-pretty.json"
printf '[{"optics": {"rx_power_dbm": null, "vendor": "-inf corp", "note": "nan", "ev": "rx_power: -inf dBm", "l": "lanes [1, nan] bad"}}]' > "$FIX/xok.json"
assert_eq "xray JSON with -inf rejected" "no" "$(valid_xray_json "$FIX/xinf.json" && echo yes || echo no)"
assert_eq "pretty-printed -inf rejected (not line-based)" "no" "$(valid_xray_json "$FIX/xinf-pretty.json" && echo yes || echo no)"
assert_eq "inf/nan inside string values accepted" "yes" "$(valid_xray_json "$FIX/xok.json" && echo yes || echo no)"
printf '{"verdict":"OK","results":[{"evidence":"rx_power: -inf dBm"}]}' > "$FIX/str-inf.json"
assert_eq "nic-health with -inf in evidence text is ok" "ok" "$(classify 0 "$FIX/str-inf.json" "$FIX/empty.err")"
printf '{"verdict":"OK\\nb\\th-b\\tok\\t0\\t0\\tskipped\\tOK","results":[]}' > "$FIX/forged.json"
assert_eq "verdict with embedded tabs/newlines rejected" "bad-output" "$(classify 0 "$FIX/forged.json" "$FIX/empty.err")"
printf '{"verdict":"FAIL","results":[]}' > "$FIX/odd.json"
assert_eq "unknown verdict value rejected" "bad-output" "$(classify 0 "$FIX/odd.json" "$FIX/empty.err")"
printf 'Sorry, user ops is not allowed to execute '"'"'/usr/bin/bash /tmp/x'"'"' as root on h.\n' > "$FIX/sorry.err"
assert_eq "sudo 'Sorry, user ... not allowed' is sudo-fail" "sudo-fail" "$(classify 1 "$FIX/bad.json" "$FIX/sorry.err")"
printf 'Sorry, user ops may not run sudo on h.\n' > "$FIX/sorry2.err"
assert_eq "sudo 'may not run sudo' is sudo-fail" "sudo-fail" "$(classify 1 "$FIX/bad.json" "$FIX/sorry2.err")"
printf 'nic-sweep: sudo not found\n' > "$FIX/nosudo.err"
assert_eq "missing sudo is sudo-fail, not tool-missing" "sudo-fail" "$(classify 1 "$FIX/bad.json" "$FIX/nosudo.err")"

# Exit code precedence: CRIT > not collected > WARN > UNKNOWN verdict > OK; empty set is UNKNOWN
R_OK=$'a\tx\tok\t0\t1\tok\tOK'; R_WARN=$'b\tx\tok\t1\t1\tok\tWARN'; R_UNK=$'c\tx\tok\t3\t1\tok\tUNKNOWN'
R_CRIT=$'d\tx\tok\t2\t1\tok\tCRIT'; R_FAIL=$'e\tx\tssh-fail\t255\t1\tskipped\t-'
assert_eq "exit: empty result set" "3" "$(results_exit_code "")"
assert_eq "exit: OK" "0" "$(results_exit_code "$R_OK")"
assert_eq "exit: WARN + UNKNOWN verdict -> WARN" "1" "$(results_exit_code "$R_WARN"$'\n'"$R_UNK")"
assert_eq "exit: UNKNOWN verdict alone" "3" "$(results_exit_code "$R_OK"$'\n'"$R_UNK")"
assert_eq "exit: not collected outranks WARN" "3" "$(results_exit_code "$R_WARN"$'\n'"$R_FAIL")"
assert_eq "exit: CRIT outranks not collected" "2" "$(results_exit_code "$R_CRIT"$'\n'"$R_FAIL")"

# A worker that died before writing its result still appears (never silently dropped)
WORK_DIR="$FIX/work"; mkdir -p "$WORK_DIR"
INV_SITE=(S1 S1); INV_HOST=(alive lost); INV_ADDR=(h-a h-l)
printf '%s\n' "$R_OK" | sed 's/^a/alive/' > "$WORK_DIR/0"
assert_eq "lost worker result becomes bad-output with exit -" $'lost\th-l\tbad-output\t-\t-\tskipped\t-' \
    "$(site_results S1 | grep '^lost')"
assert_eq "lost worker makes the sweep not OK" "3" "$(results_exit_code "$(site_results S1)")"
INV_SITE=(); INV_HOST=(); INV_ADDR=()

# Remote commands: constant text, validated values, POSIX shell; executed below under sh/dash
# shellcheck disable=SC2034  # globals read by build_remote_commands
LEVEL=deep; INTERVAL=30; TIMEOUT=330; SHIP=""
build_remote_commands
# shellcheck disable=SC2016  # literal remote text, expanded on the host
assert_eq "remote text starts with LC_ALL=C" "yes" "$([[ "$REMOTE_HEALTH" == 'LC_ALL=C; export LC_ALL; '* ]] && echo yes)"
# shellcheck disable=SC2016
assert_eq "remote health: packaged tool first, bounded by a remote timeout" "yes" \
    "$([[ "$REMOTE_HEALTH" == *'command -v nic-health || command -v nic-health.sh || exit 127'*'exec timeout -k 10 325 sudo -n "$T" -O json -l deep -I 30'* ]] && echo yes)"
# shellcheck disable=SC2016
assert_eq "remote xray bounded" "yes" "$([[ "$REMOTE_XRAY" == *'exec timeout -k 10 115 sudo -n "$T" --all --output json'* ]] && echo yes)"

# Run the remote text for real under a POSIX shell, with stub sudo/timeout/nic-health
POSIX_SH=$(command -v dash || command -v sh)
mkdir -p "$FIX/rbin" "$FIX/rbin-notool" "$FIX/rbin-nosudo"
# shellcheck disable=SC2016  # stub scripts: literal text
printf '#!/bin/sh\n[ "$1" = "-n" ] && shift\nexec "$@"\n' > "$FIX/rbin/sudo"
printf '#!/bin/sh\nshift 3\nexec "$@"\n' > "$FIX/rbin/timeout"   # drop "-k N LIMIT"
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "{\\"verdict\\":\\"OK\\",\\"results\\":[],\\"args\\":\\"$*\\",\\"lc\\":\\"$LC_ALL\\"}"\n' > "$FIX/rbin/nic-health"
chmod +x "$FIX/rbin/"*
cp "$FIX/rbin/sudo" "$FIX/rbin/timeout" "$FIX/rbin-notool/"
cp "$FIX/rbin/nic-health" "$FIX/rbin-nosudo/"
RPATH="$FIX/rbin:/usr/bin:/bin"
OUT_R=$(PATH="$RPATH" "$POSIX_SH" -c "$REMOTE_HEALTH")
assert_eq "remote health runs under $POSIX_SH with args and LC_ALL=C" "-O json -l deep -I 30 C" "$(jq -r '.args + " " + .lc' <<< "$OUT_R")"
PATH="$FIX/rbin-notool:/usr/bin:/bin" "$POSIX_SH" -c "$REMOTE_HEALTH" >/dev/null 2>&1
assert_eq "remote health without the tool exits 127" "127" "$?"
# PATH without any system directory: the remote text needs only shell builtins to reach the sudo check
ERR_R=$(PATH="$FIX/rbin-nosudo" "$POSIX_SH" -c "$REMOTE_HEALTH" 2>&1 >/dev/null)
assert_eq "remote health without sudo says so" "nic-sweep: sudo not found" "$ERR_R"

SHIP="$SCRIPT"; build_remote_commands
# shellcheck disable=SC2016
assert_eq "remote ship: private temp file, traps for EXIT/HUP/INT/TERM" "yes" \
    "$([[ "$REMOTE_HEALTH" == *'mktemp /tmp/nic-health.XXXXXX'*"trap 'rm -f \"\$T\"' EXIT; trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM"* ]] && echo yes)"
# shellcheck disable=SC2016
printf '#!/bin/bash\necho "{\\"verdict\\":\\"WARN\\",\\"results\\":[],\\"me\\":\\"$0\\"}"\nexit 1\n' > "$FIX/shipme.sh"
OUT_R=$(PATH="$RPATH" "$POSIX_SH" -c "$REMOTE_HEALTH" < "$FIX/shipme.sh"); RC_R=$?
SHIPPED=$(jq -r .me <<< "$OUT_R")
assert_eq "ship: shipped script ran and its exit code is kept" "WARN 1" "$(jq -r .verdict <<< "$OUT_R") $RC_R"
assert_eq "ship: temp file removed afterwards" "no" "$([[ -e "$SHIPPED" ]] && echo yes || echo no)"
# shellcheck disable=SC2034
SHIP=""

# --- Stub ssh: the destination name selects the behaviour ---
mkdir -p "$FIX/bin"
cat > "$FIX/bin/ssh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_LOG"
while (( $# )); do [[ "$1" == "--" ]] && { shift; break; }; shift; done
DEST="$1" CMD="$2"
[[ "$CMD" == *"cat > "* ]] && cat > "$STUB_DIR/shipped.$DEST"
health() {  # health <verdict> <exit>
    printf '{"schema_version": 1, "tool": "nic-health.sh", "version": "9.9.9", "host": "%s", ' "$DEST"
    printf '"collected_at": "2026-10-26T12:00:00Z", "uptime_s": 1000, "boot_id": "0f1e2d3c-4b5a-4968-8778-a6b5c4d3e2f1", '
    printf '"level": "deep", "mode": "delta", "interval_s": 30, "verdict": "%s", "exit_code": %d, "results": [' "$1" "$2"
    printf '{"severity": "%s", "scope": "port", "target": "eth0", "check_id": "generic.link.state", "value": "up", ' "$1"
    printf '"unit": "", "threshold": "", "evidence": "a, \\"quoted\\" value", "hint": "", "ref": "x"},'
    printf '{"severity": "OK", "scope": "asic", "target": "0000:01:00", "check_id": "generic.pcie.aer", "value": "0", '
    printf '"unit": "", "threshold": "", "evidence": "", "hint": "", "ref": "y"}]}\n'
    exit "$2"
}
health2() {  # health2 <metric value>: nic-health JSON schema 2, with typed metrics (design §7 P2/P3)
    printf '{"schema_version": 2, "tool": "nic-health.sh", "version": "9.9.9", "host": "%s", ' "$DEST"
    printf '"collected_at": "2026-10-26T12:00:00Z", "uptime_s": 1000, "boot_id": null, '
    printf '"level": "deep", "mode": "delta", "interval_s": 30, "verdict": "OK", "exit_code": 0, "results": ['
    printf '{"severity": "OK", "scope": "port", "target": "eth0", "check_id": "generic.link.state", "value": "up", '
    printf '"unit": "", "threshold": "", "evidence": "operstate=up", "hint": "", "ref": "x", '
    printf '"metrics": {"carrier": true, "in_use": true, "in_use_reasons": ["bond"], "bond": "bond0", "bond_link_failures": 2}},'
    printf '{"severity": "OK", "scope": "port", "target": "eth0", "check_id": "mlx5.deep.module", "value": "Rx=%s", ' "$1"
    printf '"unit": "", "threshold": "", "evidence": "", "hint": "", "ref": "y", '
    printf '"metrics": {"rx_dbm": %s, "rx_dbm_lanes": [%s, -0.4], "rx_symbol_err_phy": {"total": 18446744073709551615, "delta": 0}}}]}\n' "$1" "$1"
    exit 0
}
if [[ "$CMD" == *nic-xray* ]]; then
    case "$DEST" in
        h-noxray) exit 127 ;;
        h-xraybad) echo "not json"; exit 0 ;;
        h-xrayinf) echo '[{"interface": "eth0", "optics": {"rx_power_dbm": -inf}}]'; exit 0 ;;
        *) echo '[{"interface": "eth0", "switch_name": "sw1"}]'; exit 0 ;;
    esac
fi
case "$DEST" in
    h-ok|h-noxray|h-xraybad|h-xrayinf) health OK 0 ;;
    h-v2) health2 -8.83 ;;
    h-v2nan) health2 NaN ;;
    h-warn) health WARN 1 ;;
    h-crit) health CRIT 2 ;;
    h-unknown) health UNKNOWN 3 ;;
    h-sshfail) echo "ssh: connect to host $DEST port 22: Connection refused" >&2; exit 255 ;;
    h-sudo) echo "sudo: a password is required" >&2; exit 1 ;;
    h-sorry) echo "Sorry, user ops may not run sudo on h-sorry." >&2; exit 1 ;;
    h-missing) exit 127 ;;
    h-slow) exec sleep 30 ;;
    h-hang) exec sleep 31 ;;
    h-garbage) echo "garbage"; exit 0 ;;
esac
exit 99
STUB
chmod +x "$FIX/bin/ssh"
export STUB_LOG="$FIX/ssh.log" STUB_DIR="$FIX"

# sweep <inventory> [options...]: run nic-sweep.sh with the stub; sets RC and OUT (output dir)
sweep() {
    local INV="$1"; shift
    OUT="$FIX/out.$((++RUN_N))"
    : > "$STUB_LOG"
    PATH="$FIX/bin:$PATH" bash "$SCRIPT" -f "$INV" -o "$OUT" -n "$@" > "$FIX/stdout" 2> "$FIX/stderr"
    RC=$?
}
RUN_N=0
latest() { find "$OUT/$1" -mindepth 1 -maxdepth 1 -type d | head -1; }
# manifest_col <site> <host> <column>: one MANIFEST.tsv field (pure Bash: CI images may lack awk)
manifest_col() {
    local H A S X D XR V
    while IFS=$'\t' read -r H A S X D XR V; do
        [[ "$H" == "$2" ]] || continue
        case "$3" in status) echo "$S" ;; xray) echo "$XR" ;; esac
    done < "$(latest "$1")/MANIFEST.tsv"
}
manifest_status() { manifest_col "$1" "$2" status; }
manifest_xray() { manifest_col "$1" "$2" xray; }

# --- Full run: every status, two sites ---
cat > "$FIX/inv-all.csv" <<'INV'
site,host,address,user
# comment line
S1,ok,h-ok
S1,warn,h-warn
S1,crit,h-crit
S1,sshfail,h-sshfail
S1,sudo,h-sudo
S1,missing,h-missing
S1,slow,h-slow
S1,garbage,h-garbage
S1,noxray,h-noxray,ops
S1,xraybad,h-xraybad
S2,ok2,h-ok
S1,bad;name,h-ok
S1,ok,h-ok
S1,dash,-oProxyCommand=evil
S1,toofew
S1,.,h-ok
S1,..,h-ok
..,host,h-ok
S1,a.xray,h-ok
S1,-x,h-ok
S1,sorry,h-sorry
INV
# shellcheck disable=SC2016  # the injection attempt must stay literal
printf 'S1,inject,$(touch %s/pwned)\n' "$FIX" >> "$FIX/inv-all.csv"
sweep "$FIX/inv-all.csv" -T 2 -p 4
D1=$(latest S1)
assert_eq "full run: CRIT present -> exit 2" "2" "$RC"
assert_eq "full run: two site directories" "S1 S2" "$(find "$OUT" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "status ok"           "ok"           "$(manifest_status S1 ok)"
assert_eq "status warn host ok" "ok"           "$(manifest_status S1 warn)"
assert_eq "status ssh-fail"     "ssh-fail"     "$(manifest_status S1 sshfail)"
assert_eq "status sudo-fail"    "sudo-fail"    "$(manifest_status S1 sudo)"
assert_eq "status tool-missing" "tool-missing" "$(manifest_status S1 missing)"
assert_eq "status timeout"      "timeout"      "$(manifest_status S1 slow)"
assert_eq "status bad-output"   "bad-output"   "$(manifest_status S1 garbage)"
assert_eq "xray ok"             "ok"           "$(manifest_xray S1 ok)"
assert_eq "xray absent"         "absent"       "$(manifest_xray S1 noxray)"
assert_eq "xray failed"         "failed"       "$(manifest_xray S1 xraybad)"
assert_eq "xray skipped when unreachable" "skipped" "$(manifest_xray S1 sshfail)"
assert_eq "xray skipped on timeout" "skipped"  "$(manifest_xray S1 slow)"
assert_eq "manifest: header + 11 hosts" "12" "$(wc -l < "$D1/MANIFEST.tsv" | tr -d ' ')"
assert_eq "manifest header" $'host\taddress\tstatus\texit_code\tduration_s\txray\tverdict' "$(head -1 "$D1/MANIFEST.tsv")"
assert_eq "inventory: 10 bad/duplicate lines skipped (incl. . .. a.xray -x)" "10" "$(grep -c 'skipped' "$FIX/stderr")"
assert_eq "inventory: no injected command ran" "no" "$([[ -e "$FIX/pwned" ]] && echo yes || echo no)"
assert_eq "inventory: nothing written outside the sweep tree" "no" "$([[ -e "$FIX/MANIFEST.tsv" || -d "$FIX/nodes" ]] && echo yes || echo no)"
assert_eq "status sudo-fail ('Sorry, user')" "sudo-fail" "$(manifest_status S1 sorry)"
assert_eq "inventory: dash address never reached ssh" "0" "$(grep -c 'ProxyCommand' "$STUB_LOG")"
assert_eq "per-host user passed with -l (nic-health and nic-xray)" "2" "$(grep -c -- '-l ops -- h-noxray' "$STUB_LOG")"
assert_eq "ssh always BatchMode" "0" "$(grep -vc 'BatchMode=yes' "$STUB_LOG")"
assert_eq "node JSON kept verbatim" "CRIT" "$(jq -r .verdict "$D1/nodes/crit.json")"
assert_eq "xray JSON saved" "sw1" "$(jq -r '.[0].switch_name' "$D1/nodes/ok.xray.json")"
assert_eq "absent xray leaves no file" "no" "$([[ -e "$D1/nodes/noxray.xray.json" ]] && echo yes || echo no)"
assert_eq "stderr captured" "1" "$(grep -c 'Connection refused' "$D1/nodes/sshfail.err")"
assert_eq "sweep.json valid" "1" "$(jq -r .schema_version "$D1/sweep.json")"
# Collected (ok): ok, warn, crit, noxray, xraybad; one host per failure status
assert_eq "sweep.json totals" "11 5 1 2 1 1 1 2" "$(jq -r '[.hosts.total, (.hosts.by_status | .ok, ."ssh-fail", ."sudo-fail", ."tool-missing", .timeout, ."bad-output"), .exit_code] | map(tostring) | join(" ")' "$D1/sweep.json")"
# nic-xray runs wherever ssh worked (also when nic-health failed); skipped only for ssh-fail/timeout
assert_eq "sweep.json xray" "7 1 1 2" "$(jq -r '[.hosts.xray.ok, .hosts.xray.absent, .hosts.xray.failed, .hosts.xray.skipped] | map(tostring) | join(" ")' "$D1/sweep.json")"
assert_eq "sweep.json verdicts" "3 1 1" "$(jq -r '[.hosts.by_verdict.OK, .hosts.by_verdict.WARN, .hosts.by_verdict.CRIT] | map(tostring) | join(" ")' "$D1/sweep.json")"
assert_eq "sweep.json options" "deep 30 4 2 false true" "$(jq -r '[.options.level, .options.interval_s, .options.parallel, .options.timeout_s, .options.ship, .options.xray] | map(tostring) | join(" ")' "$D1/sweep.json")"
assert_eq "sweep.json records skipped inventory lines" "10" "$(jq -r .inventory.skipped_lines "$D1/sweep.json")"
assert_eq "sweep.json inventory hash" "$(sha256sum < "$FIX/inv-all.csv" | cut -d' ' -f1)" "$(jq -r .inventory.sha256 "$D1/sweep.json")"
assert_eq "merged.csv header" "site,hostname,collected_at,version,level,interval_s,uptime_s,boot_id,severity,scope,target,check_id,value,unit,threshold,evidence,hint,ref" "$(head -1 "$D1/merged.csv")"
assert_eq "merged.csv: header + 2 results x 5 collected hosts" "11" "$(wc -l < "$D1/merged.csv" | tr -d ' ')"
assert_eq "merged.csv carries collection metadata" '"S1","crit","2026-10-26T12:00:00Z","9.9.9","deep",30,1000,"0f1e2d3c-4b5a-4968-8778-a6b5c4d3e2f1","CRIT"' \
    "$(grep '^"S1","crit"' "$D1/merged.csv" | head -1 | cut -d, -f1-9)"
if command -v python3 &>/dev/null; then
    assert_eq "merged.csv parses (RFC 4180, embedded comma and quotes)" 'a, "quoted" value' \
        "$(python3 -c 'import csv,sys; r=list(csv.DictReader(open(sys.argv[1]))); print(r[0]["evidence"])' "$D1/merged.csv")"
fi
assert_eq "dirs 0750" "750" "$(stat -c %a "$D1")"
assert_eq "files 0640" "640" "$(stat -c %a "$D1/MANIFEST.tsv")"
assert_eq "summary names failing hosts" "1" "$(grep -c 'sshfail (h-sshfail): ssh-fail, exit 255' "$FIX/stdout")"

# nic-xray < 2.13.0 (#24): -inf output is kept but marked failed, with a note
printf 'S1,inf,h-xrayinf\n' > "$FIX/inv-inf.csv"
sweep "$FIX/inv-inf.csv"
assert_eq "xray with -inf: failed" "failed" "$(manifest_xray S1 inf)"
assert_eq "xray with -inf: file kept" "yes" "$([[ -s "$(latest S1)/nodes/inf.xray.json" ]] && echo yes)"
assert_eq "xray with -inf: note in .err" "1" "$(grep -c 'non-finite numbers' "$(latest S1)/nodes/inf.err")"
assert_eq "xray with -inf: host still collected" "0" "$RC"

# nic-health JSON schema 2 (typed metrics, design §7 P2/P3): collected like schema 1; merged.csv keeps
# its columns (metrics are JSON only); a non-finite number in metrics is still bad output
printf 'S1,v2,h-v2\nS1,v1,h-ok\nS1,v2nan,h-v2nan\n' > "$FIX/inv-v2.csv"
sweep "$FIX/inv-v2.csv" --no-xray
assert_eq "schema 2: collected" "ok" "$(manifest_status S1 v2)"
assert_eq "schema 2 next to schema 1: both collected" "ok" "$(manifest_status S1 v1)"
assert_eq "schema 2: node JSON kept verbatim (metrics)" "2 bond0 -8.83" \
    "$(jq -r '[.schema_version, .results[0].metrics.bond, .results[1].metrics.rx_dbm] | map(tostring) | join(" ")' "$(latest S1)/nodes/v2.json")"
assert_eq "schema 2: merged.csv header unchanged" "site,hostname,collected_at,version,level,interval_s,uptime_s,boot_id,severity,scope,target,check_id,value,unit,threshold,evidence,hint,ref" \
    "$(head -1 "$(latest S1)/merged.csv")"
assert_eq "schema 2: merged.csv has header + 2 rows per collected host" "5" "$(wc -l < "$(latest S1)/merged.csv" | tr -d ' ')"
assert_eq "schema 2: NaN in metrics is bad output" "bad-output" "$(manifest_status S1 v2nan)"

# --- Exit codes (design §5.5) ---
printf 'S1,ok,h-ok\nS1,ok2,h-noxray\n' > "$FIX/inv-ok.csv"
sweep "$FIX/inv-ok.csv"
assert_eq "all OK -> 0" "0" "$RC"
printf 'S1,ok,h-ok\nS1,warn,h-warn\n' > "$FIX/inv-warn.csv"
sweep "$FIX/inv-warn.csv"
assert_eq "WARN -> 1" "1" "$RC"
printf 'S1,ok,h-ok\nS1,down,h-sshfail\n' > "$FIX/inv-fail.csv"
sweep "$FIX/inv-fail.csv"
assert_eq "host not collected -> 3" "3" "$RC"
printf 'S1,ok,h-ok\nS1,unk,h-unknown\n' > "$FIX/inv-unk.csv"
sweep "$FIX/inv-unk.csv"
assert_eq "UNKNOWN verdict (no WARN) -> 3" "3" "$RC"
printf 'S1,warn,h-warn\nS1,unk,h-unknown\n' > "$FIX/inv-wunk.csv"
sweep "$FIX/inv-wunk.csv"
assert_eq "WARN + UNKNOWN verdict -> 1 (nic-health order)" "1" "$RC"
printf 'S1,crit,h-crit\nS1,down,h-sshfail\n' > "$FIX/inv-critfail.csv"
sweep "$FIX/inv-critfail.csv"
assert_eq "CRIT outranks a failed host -> 2" "2" "$RC"

# --- Options ---
sweep "$FIX/inv-all.csv" -s S2
assert_eq "--site: only S2 swept" "S2" "$(find "$OUT" -mindepth 1 -maxdepth 1 -printf '%f\n')"
sweep "$FIX/inv-ok.csv" --no-xray
assert_eq "--no-xray: nic-xray never called" "0" "$(grep -c 'nic-xray' "$STUB_LOG")"
assert_eq "--no-xray: recorded as skipped" "skipped" "$(manifest_xray S1 ok)"
sweep "$FIX/inv-ok.csv" -J jumpuser@jump.example:2222 --accept-new-hostkeys -u svc -l basic -I 5
assert_eq "-J passed to every ssh call" "yes" "$( (( $(grep -c -- '-J jumpuser@jump.example:2222' "$STUB_LOG") >= 2 )) && echo yes)"
assert_eq "--accept-new-hostkeys" "1" "$(grep -m1 -c 'StrictHostKeyChecking=accept-new' "$STUB_LOG")"
assert_eq "-u default user" "1" "$(grep -m1 -c -- '-l svc -- h-ok' "$STUB_LOG")"
assert_eq "-l/-I reach nic-health" "1" "$(grep -m1 -c -- '-O json -l basic -I 5' "$STUB_LOG")"
assert_eq "basic default timeout = interval + 120" "125" "$(jq -r .options.timeout_s "$(latest S1)/sweep.json")"
assert_eq "no -L: nic-health not given -L" "0" "$(grep -c -- '-I 5 -L' "$STUB_LOG")"
assert_eq "no -L: lookback_min null" "null" "$(jq -r .options.lookback_min "$(latest S1)/sweep.json")"
sweep "$FIX/inv-ok.csv" -L 1440
assert_eq "-L reaches nic-health" "1" "$(grep -m1 -c -- '-O json -l deep -I 30 -L 1440' "$STUB_LOG")"
assert_eq "-L recorded as lookback_min" "1440" "$(jq -r .options.lookback_min "$(latest S1)/sweep.json")"
sweep "$FIX/inv-ok.csv" --lookback 0
assert_eq "--lookback 0 passed (off)" "1" "$(grep -m1 -c -- '-I 30 -L 0' "$STUB_LOG")"
sweep "$FIX/inv-ok.csv" --ship "$REPO/nic-health.sh"
assert_eq "--ship: script sent over stdin unchanged" "$(sha256sum < "$REPO/nic-health.sh" | cut -d' ' -f1)" \
    "$(sha256sum < "$FIX/shipped.h-ok" | cut -d' ' -f1)"
assert_eq "--ship: does not look for an installed nic-health" "0" "$(grep -c 'command -v nic-health ' "$STUB_LOG")"
assert_eq "--ship recorded" "true" "$(jq -r .options.ship "$(latest S1)/sweep.json")"

# --- Usage errors (exit 3, usage on stderr) ---
for CASE in "" "-f /nonexistent" "-f $FIX/inv-ok.csv -p 0" "-f $FIX/inv-ok.csv -p 999" "-f $FIX/inv-ok.csv -l bogus" \
            "-f $FIX/inv-ok.csv -I 3601" "-f $FIX/inv-ok.csv -L 1441" "-f $FIX/inv-ok.csv -L x" "-f $FIX/inv-ok.csv -T 0" "-f $FIX/inv-ok.csv -J bad;host" \
            "-f $FIX/inv-ok.csv -s bad/site" "-f $FIX/inv-ok.csv --ship /nonexistent" "-f $FIX/inv-ok.csv extra" \
            "-f $FIX/inv-ok.csv -s NOSUCH" "--bogus"; do
    # shellcheck disable=SC2086
    PATH="$FIX/bin:$PATH" bash "$SCRIPT" $CASE -o "$FIX/usage-out" >/dev/null 2>&1
    assert_eq "exit 3 for '$CASE'" "3" "$?"
done
PATH="$FIX/bin:$PATH" bash "$SCRIPT" > /dev/null 2> "$FIX/usage.err"
assert_eq "missing --inventory prints usage" "1" "$(grep -c '^Usage:' "$FIX/usage.err")"
assert_eq "--version" "nic-sweep.sh $(sed -n 's/^SCRIPT_VERSION="\(.*\)"/\1/p' "$SCRIPT")" "$(bash "$SCRIPT" --version)"
bash "$SCRIPT" -h >/dev/null
assert_eq "--help exits 0" "0" "$?"
# An existing sweep directory is refused, never reused: pre-create the next few seconds' directories
OUTC="$FIX/clash"
for (( D = 0; D <= 3; D++ )); do
    TS=$(TZ=UTC0 date -d "@$(( $(date +%s) + D ))" +%Y%m%dT%H%M%SZ)
    mkdir -p "$OUTC/S1/$TS"; echo keep > "$OUTC/S1/$TS/marker"
done
PATH="$FIX/bin:$PATH" bash "$SCRIPT" -f "$FIX/inv-ok.csv" -o "$OUTC" -n > /dev/null 2> "$FIX/clash.err"
assert_eq "existing sweep directory: exit 3" "3" "$?"
assert_eq "existing sweep directory: refused with a message" "1" "$(grep -c 'already exists' "$FIX/clash.err")"
assert_eq "existing sweep directory: nothing written into it" "0" "$(find "$OUTC" -name MANIFEST.tsv | wc -l | tr -d ' ')"

# count_procs CMDLINE: processes whose full command line is exactly CMDLINE (from /proc; pure Bash,
# CI images may lack pgrep)
count_procs() {
    local P N=0
    local -a ARGV
    for P in /proc/[0-9]*/cmdline; do
        mapfile -d '' ARGV < "$P" 2>/dev/null || continue
        [[ "${ARGV[*]:-}" == "$1" ]] && (( ++N ))
    done
    echo "$N"
}

# Interrupt: workers forward TERM to timeout(1), so no ssh or remote stand-in survives the sweep
printf 'S1,hang1,h-hang\nS1,hang2,h-hang\n' > "$FIX/inv-hang.csv"
PATH="$FIX/bin:$PATH" bash "$SCRIPT" -f "$FIX/inv-hang.csv" -o "$FIX/out-int" -n -T 60 > /dev/null 2>&1 &
SWEEP_PID=$!
for (( W = 0; W < 50; W++ )); do (( $(count_procs "sleep 31") > 0 )) && break; sleep 0.1; done
kill -INT "$SWEEP_PID"
wait "$SWEEP_PID"
assert_eq "interrupt: exit 3" "3" "$?"
sleep 0.5
assert_eq "interrupt: stand-ins were running before" "yes" "$( (( W < 50 )) && echo yes)"
assert_eq "interrupt: no stand-in ssh left running" "0" "$(count_procs "sleep 31")"

echo
if (( FAIL > 0 )); then
    echo "❌ $FAIL failed, $PASS passed"
    exit 1
fi
echo "✅ All $PASS tests passed"
