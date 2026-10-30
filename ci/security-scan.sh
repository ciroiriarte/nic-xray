#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329  # run_* functions are dispatched indirectly ("run_$check")
# security-scan.sh — run one or all repository security checks with the same gates
# as .github/workflows/security-scan.yml. Tools come from ci/install-tools.sh.
#
# Gates:
#   trivy    any secret (every severity) fails; HIGH/CRITICAL fixable vulnerability
#            or misconfiguration fails (trivy.yaml, .trivyignore)
#   checkov  any failed GitHub Actions workflow check fails (.checkov.yaml)
# ShellCheck is not here: `make lint` (ci.yml) already gates every shell file.
# Reports (SARIF) land in REPORT_DIR. Every selected check runs; the exit status is
# non-zero if any gate failed.
set -Euo pipefail

usage() {
	cat <<-'USAGE'
Usage: security-scan.sh [-h|--help] {trivy|checkov|all}

Run the repository security checks (tools from ci/install-tools.sh).
Reports are written to $REPORT_DIR (default: <repo>/.ci-tools/reports).
USAGE
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="${TOOLS_DIR:-$ROOT/.ci-tools}"
REPORT_DIR="${REPORT_DIR:-$TOOLS_DIR/reports}"
ALL_CHECKS=(trivy checkov)

CHECK=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		-h|--help) usage; exit 0 ;;
		trivy|checkov|all) CHECK="$1"; shift ;;
		*) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done
if [[ -z "$CHECK" ]]; then
	usage >&2
	exit 2
fi

mkdir -p "$REPORT_DIR"
# Absolute, before the cd below
TOOLS_DIR="$(cd "$TOOLS_DIR" 2>/dev/null && pwd || echo "$TOOLS_DIR")"
REPORT_DIR="$(cd "$REPORT_DIR" && pwd)"
export PATH="$TOOLS_DIR/bin:$PATH"
cd "$ROOT" || exit 1

run_trivy() {
	local rc=0
	# A failed scan must not leave the previous run's reports to be converted
	rm -f "$REPORT_DIR/trivy.json" "$REPORT_DIR/trivy.sarif"
	echo "== trivy: secrets (every severity fails)"
	trivy fs --config trivy.yaml --skip-version-check --scanners secret \
		--severity UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL --exit-code 1 . || rc=1
	echo "== trivy: vulnerabilities + misconfigurations (HIGH/CRITICAL fail)"
	trivy fs --config trivy.yaml --skip-version-check --scanners secret,vuln,misconfig \
		--severity UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL --exit-code 0 \
		--format json --output "$REPORT_DIR/trivy.json" . || rc=1
	trivy convert --format sarif --output "$REPORT_DIR/trivy.sarif" "$REPORT_DIR/trivy.json" || rc=1
	trivy convert --format table --severity HIGH,CRITICAL --exit-code 1 "$REPORT_DIR/trivy.json" || rc=1
	return "$rc"
}

run_checkov() {
	echo "== checkov: GitHub Actions workflows (any failed check fails)"
	checkov --config-file .checkov.yaml -o cli -o sarif \
		--output-file-path "console,$REPORT_DIR/checkov.sarif"
}

status=0
if [[ "$CHECK" == "all" ]]; then
	for check in "${ALL_CHECKS[@]}"; do
		"run_$check" || { status=1; echo "!! $check: gate FAILED"; }
	done
else
	"run_$CHECK" || status=1
fi
exit "$status"
