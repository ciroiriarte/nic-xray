#!/usr/bin/env bash
# install-tools.sh — install the pinned security-scan toolchain (Trivy, Checkov)
# into TOOLS_DIR (default: <repo>/.ci-tools, gitignored).
#
# Used by .github/workflows/security-scan.yml and `make security-scan`. Release
# archives (Trivy) are verified against the sha256 pinned below; bump a version and
# its hash together. Checkov is pinned by version only (pip, into its own venv).
# Idempotent: a tool already at its pinned version is not re-fetched.
set -Eeuo pipefail

usage() {
	cat <<-'USAGE'
Usage: install-tools.sh [-h|--help] [TOOL...]

Install the pinned security-scan tools into $TOOLS_DIR (default: <repo>/.ci-tools).
TOOL is trivy or checkov; with none given, both are installed.
USAGE
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="${TOOLS_DIR:-$ROOT/.ci-tools}"
BIN="$TOOLS_DIR/bin"
KNOWN_TOOLS=(trivy checkov)

TRIVY_VERSION="0.70.0"
TRIVY_SHA256="8b4376d5d6befe5c24d503f10ff136d9e0c49f9127a4279fd110b727929a5aa9"
CHECKOV_VERSION="3.3.9"
PYTHON="${PYTHON:-python3}"

TOOLS=()
while [[ $# -gt 0 ]]; do
	case "$1" in
		-h|--help) usage; exit 0 ;;
		trivy|checkov) TOOLS+=("$1"); shift ;;
		*) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done
[[ ${#TOOLS[@]} -gt 0 ]] || TOOLS=("${KNOWN_TOOLS[@]}")

mkdir -p "$BIN"
# Absolute, so the checkov symlink and security-scan.sh (which cds to ROOT) agree
TOOLS_DIR="$(cd "$TOOLS_DIR" && pwd)"
BIN="$TOOLS_DIR/bin"

# fetch <url> <sha256> <dest-file>
fetch() {
	curl -fsSL --retry 3 -o "$3" "$1"
	echo "$2  $3" | sha256sum -c --quiet - || { echo "Checksum mismatch for $1" >&2; exit 1; }
}

# have <tool> <version>: true when BIN already holds that version
have() {
	[[ -x "$BIN/$1" ]] && [[ "$("$BIN/$1" --version 2>/dev/null)" == *"$2"* ]]
}

install_trivy() {
	have trivy "$TRIVY_VERSION" && return
	local tmp
	tmp="$(mktemp -d)"
	# shellcheck disable=SC2064  # expand now: tmp is local
	trap "rm -rf '$tmp'" RETURN EXIT
	fetch "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" \
		"$TRIVY_SHA256" "$tmp/trivy.tgz"
	tar -xzf "$tmp/trivy.tgz" -C "$tmp" trivy
	install -m 755 "$tmp/trivy" "$BIN/trivy"
}

install_checkov() {
	have checkov "$CHECKOV_VERSION" && return
	"$PYTHON" -m venv "$TOOLS_DIR/checkov-venv"
	"$TOOLS_DIR/checkov-venv/bin/pip" install -q --disable-pip-version-check "checkov==${CHECKOV_VERSION}"
	ln -sf "$TOOLS_DIR/checkov-venv/bin/checkov" "$BIN/checkov"
}

for tool in "${TOOLS[@]}"; do
	"install_$tool"
	printf '%-8s %s\n' "$tool" "$("$BIN/$tool" --version 2>&1 | head -n1)"
done
