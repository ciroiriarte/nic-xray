#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<-'USAGE'
Usage: build-offline-iso.sh --distro-id ID --obs-path OBS_PATH --package-manager apt|zypper|dnf --version VERSION [--arch ARCH] [--with-graphviz true|false] [--with-vendor-tools true|false]

Build a self-contained offline installer ISO for nic-xray (and its companion nic-health) from the OBS package repo.
--with-vendor-tools adds mstflint from the distribution mirror (open source; enables nic-health -l deep on ConnectX).
Proprietary vendor tools (NVIDIA MFT, Broadcom niccli) are never included.
USAGE
}

DISTRO_ID=""
OBS_PATH=""
PACKAGE_MANAGER=""
VERSION=""
ARCH="$(uname -m)"
WITH_GRAPHVIZ="true"
WITH_VENDOR_TOOLS="false"
VENDOR_TOOL_PKGS=(mstflint)

while [[ $# -gt 0 ]]; do
	case "$1" in
		--distro-id) DISTRO_ID="$2"; shift 2 ;;
		--obs-path) OBS_PATH="$2"; shift 2 ;;
		--package-manager) PACKAGE_MANAGER="$2"; shift 2 ;;
		--version) VERSION="$2"; shift 2 ;;
		--arch) ARCH="$2"; shift 2 ;;
		--with-graphviz) WITH_GRAPHVIZ="$2"; shift 2 ;;
		--with-vendor-tools) WITH_VENDOR_TOOLS="$2"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done

if [[ -z "$DISTRO_ID" || -z "$OBS_PATH" || -z "$PACKAGE_MANAGER" || -z "$VERSION" ]]; then
	usage >&2
	exit 2
fi
for flag_value in "$WITH_GRAPHVIZ" "$WITH_VENDOR_TOOLS"; do
	if [[ "$flag_value" != "true" && "$flag_value" != "false" ]]; then
		echo "Expected true or false, got: $flag_value" >&2
		usage >&2
		exit 2
	fi
done

OBS_BASE_URL="https://download.opensuse.org/repositories/home:/ciriarte:/network-tools/${OBS_PATH}"
WORKDIR="${RUNNER_TEMP:-/tmp}/nic-xray-offline-${DISTRO_ID}"
STAGING_DIR="$WORKDIR/staging"
PKG_DIR="$STAGING_DIR/repo/packages"
OUT_DIR="${GITHUB_WORKSPACE:-$PWD}/dist"
ISO_NAME="nic-xray-${VERSION}-offline-${DISTRO_ID}-${ARCH}.iso"
# The closure is built without recommends, so the optional tools nic-xray
# recommends are listed explicitly and only when their flag asks for them
INSTALL_PKGS=(nic-xray pciutils)
# Optional packages left out by their flag
EXCLUDED_PKGS=()
if [[ "$WITH_GRAPHVIZ" == "true" ]]; then
	INSTALL_PKGS+=(graphviz)
else
	EXCLUDED_PKGS+=(graphviz)
fi
if [[ "$WITH_VENDOR_TOOLS" == "true" ]]; then
	INSTALL_PKGS+=("${VENDOR_TOOL_PKGS[@]}")
else
	EXCLUDED_PKGS+=("${VENDOR_TOOL_PKGS[@]}")
fi

log() { printf '::notice::%s\n' "$*"; }
run_root() {
	if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
		"$@"
	else
		sudo "$@"
	fi
}

reset_workspace() {
	rm -rf "$WORKDIR"
	mkdir -p "$PKG_DIR" "$OUT_DIR"
}

write_common_files() {
	cat > "$STAGING_DIR/README.txt" <<-README
nic-xray offline installer ISO
================================

Distro target: ${DISTRO_ID}
OBS source:    ${OBS_BASE_URL}
Packages:      ${INSTALL_PKGS[*]}

Mount this ISO on the target host, then run:

  sudo bash /path/to/mount/install.sh

The installer points the system package manager at the ISO-local repository and
uses only that repository for the nic-xray installation transaction.
README
}

# Installer snippet: percent-encode the mount path for use in a repository URL
read -r -d '' INSTALL_URL_PATH_FN <<'URLFN' || true
url_path() {
	local LC_ALL=C path="$1" out="" ch i
	for (( i = 0; i < ${#path}; i++ )); do
		ch="${path:i:1}"
		case "$ch" in
			[A-Za-z0-9/._~-]) out+="$ch" ;;
			*) printf -v ch '%%%02X' "'$ch"; out+="$ch" ;;
		esac
	done
	printf '%s' "$out"
}
URLFN

# Replace the installer placeholders with the package list and shared helpers
fill_installer() {
	local installer="$STAGING_DIR/install.sh" content
	content="$(<"$installer")"
	content="${content//@INSTALL_PACKAGES@/"${INSTALL_PKGS[*]}"}"
	content="${content//@URL_PATH_FN@/"$INSTALL_URL_PATH_FN"}"
	printf '%s\n' "$content" > "$installer"
	chmod +x "$installer"
}

write_apt_installer() {
	cat > "$STAGING_DIR/install.sh" <<-'INSTALL'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
	echo "Run as root: sudo bash $0" >&2
	exit 1
fi

@URL_PATH_FN@

ISO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_URL_PATH="$(url_path "$ISO_DIR/repo")"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/empty" "$TMP_DIR/lists/partial" "$TMP_DIR/cache/archives/partial"
cat > "$TMP_DIR/sources.list" <<-APT
deb [trusted=yes] file:${REPO_URL_PATH} ./
APT

apt-get \
	-o Dir::Etc::sourcelist="$TMP_DIR/sources.list" \
	-o Dir::Etc::sourceparts="$TMP_DIR/empty" \
	-o Dir::State::Lists="$TMP_DIR/lists" \
	-o Dir::Cache="$TMP_DIR/cache" \
	-o APT::Get::List-Cleanup=0 \
	update
apt-get \
	-o Dir::Etc::sourcelist="$TMP_DIR/sources.list" \
	-o Dir::Etc::sourceparts="$TMP_DIR/empty" \
	-o Dir::State::Lists="$TMP_DIR/lists" \
	-o Dir::Cache="$TMP_DIR/cache" \
	-o APT::Get::List-Cleanup=0 \
	install -y --no-install-recommends @INSTALL_PACKAGES@
INSTALL
	fill_installer
}

write_rpm_installer() {
	cat > "$STAGING_DIR/install.sh" <<-'INSTALL'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
	echo "Run as root: sudo bash $0" >&2
	exit 1
fi

@URL_PATH_FN@

ISO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_URL_PATH="$(url_path "$ISO_DIR/repo")"
REPO_ALIAS="nic-xray-offline"
if command -v dnf >/dev/null 2>&1; then
	# Transient repository: nothing is left in /etc/yum.repos.d
	dnf --repofrompath="${REPO_ALIAS},file://${REPO_URL_PATH}" --repo="$REPO_ALIAS" --nogpgcheck \
		--setopt=install_weak_deps=False install -y @INSTALL_PACKAGES@
elif command -v zypper >/dev/null 2>&1; then
	# The repository points at the mount; remove it however the install ends
	trap 'zypper --non-interactive removerepo "$REPO_ALIAS" >/dev/null 2>&1 || true' EXIT
	zypper --non-interactive removerepo "$REPO_ALIAS" >/dev/null 2>&1 || true
	zypper --non-interactive addrepo --no-gpgcheck "dir://${REPO_URL_PATH}" "$REPO_ALIAS"
	zypper --non-interactive refresh "$REPO_ALIAS"
	zypper --non-interactive install --repo "$REPO_ALIAS" --no-recommends @INSTALL_PACKAGES@
else
	echo "Neither dnf nor zypper is available on this host" >&2
	exit 1
fi
INSTALL
	fill_installer
}

build_iso() {
	write_common_files
	mkdir -p "$STAGING_DIR/repo"
	xorriso -as mkisofs \
		-iso-level 3 \
		-rock \
		-joliet \
		-volid "NICXRAY_OFFLINE" \
		-output "$OUT_DIR/$ISO_NAME" \
		"$STAGING_DIR"
	# Bare file name, so "sha256sum -c" works next to the downloaded ISO
	(cd "$OUT_DIR" && sha256sum "$ISO_NAME" > "$ISO_NAME.sha256")
	log "Built $OUT_DIR/$ISO_NAME"
}

install_apt_tools() {
	export DEBIAN_FRONTEND=noninteractive
	apt-get update
	apt-get install -y --no-install-recommends ca-certificates curl gnupg dpkg-dev xorriso apt-utils
}

build_apt_repo() {
	install_apt_tools
	install -d -m 0755 /etc/apt/keyrings
	curl -fsSL "$OBS_BASE_URL/Release.key" | gpg --dearmor > /etc/apt/keyrings/home_ciriarte_network-tools.gpg
	cat > /etc/apt/sources.list.d/home_ciriarte_network-tools.list <<-APT
deb [signed-by=/etc/apt/keyrings/home_ciriarte_network-tools.gpg] ${OBS_BASE_URL}/ /
APT
	apt-get update

	pushd "$PKG_DIR" >/dev/null
	# Download the recursive dependency closure, including packages
	# already present in the build container, so the ISO does not depend on the
	# container's installed state.
	mapfile -t closure < <(apt-cache depends --recurse --no-recommends --no-conflicts --no-breaks --no-replaces --no-enhances --no-suggests "${INSTALL_PKGS[@]}" \
		| awk '/^[[:alnum:]][[:alnum:].+:-]*$/ { print $1 }' \
		| sort -u)
	if [[ ${#closure[@]} -eq 0 ]]; then
		echo "apt dependency closure is empty" >&2
		exit 1
	fi
	apt-get download "${closure[@]}"
	popd >/dev/null

	pushd "$STAGING_DIR/repo" >/dev/null
	dpkg-scanpackages packages /dev/null | tee Packages | gzip -9c > Packages.gz
	popd >/dev/null
	write_apt_installer
}

# The bundle must install on a system that has none of it
verify_rpm_bundle() {
	local check_root="$WORKDIR/rpm-check"
	mkdir -p "$check_root"
	rpm --root "$check_root" --initdb
	rpm --root "$check_root" --install --test --nosignature "$PKG_DIR"/*.rpm
}

install_zypper_tools() {
	zypper --non-interactive refresh
	zypper --non-interactive install --no-recommends ca-certificates curl findutils xorriso createrepo_c
}

configure_slowroll_repos() {
	# No official Slowroll container image is published, so the workflow uses a
	# Tumbleweed bootstrap container and switches zypper to Slowroll before
	# resolving the nic-xray dependency closure.
	if [[ "$OBS_PATH" != "openSUSE_Slowroll" ]]; then
		return 0
	fi
	zypper --non-interactive removerepo --all
	zypper --non-interactive addrepo --check --refresh https://download.opensuse.org/slowroll/repo/oss/ slowroll-oss
	zypper --non-interactive addrepo --check --refresh https://download.opensuse.org/slowroll/repo/non-oss/ slowroll-non-oss
	zypper --non-interactive addrepo --check --refresh https://download.opensuse.org/update/slowroll/repo/oss/ slowroll-update
	zypper --non-interactive --gpg-auto-import-keys refresh
}

build_zypper_repo() {
	install_zypper_tools
	configure_slowroll_repos
	zypper --non-interactive addrepo --check --refresh "$OBS_BASE_URL/" nic-xray-obs
	zypper --non-interactive --gpg-auto-import-keys refresh nic-xray-obs
	# Resolve against an empty root that uses the container's repositories, so
	# packages already installed in the container are downloaded too
	local resolve_root="$WORKDIR/zypper-root" pkg_cache="$WORKDIR/zypper-packages"
	local key key_file="$WORKDIR/gpg-pubkey.asc"
	mkdir -p "$resolve_root" "$pkg_cache"
	rpm --root "$resolve_root" --initdb
	# Same trusted keys as the container, so downloads are still verified
	while read -r key; do
		rpm -q --qf '%{DESCRIPTION}\n' "$key" > "$key_file"
		rpm --root "$resolve_root" --import "$key_file"
	done < <(rpm -q gpg-pubkey)
	zypper --non-interactive --installroot "$resolve_root" --pkg-cache-dir "$pkg_cache" \
		install --download-only --no-recommends "${INSTALL_PKGS[@]}"
	find "$pkg_cache" -type f -name '*.rpm' -exec cp -n {} "$PKG_DIR" \;
	if ! find "$PKG_DIR" -type f -name '*.rpm' -print -quit | grep -q .; then
		echo "No RPMs were downloaded" >&2
		exit 1
	fi
	verify_rpm_bundle
	createrepo_c "$STAGING_DIR/repo"
	write_rpm_installer
}

install_dnf_tools() {
	dnf install -y --allowerasing ca-certificates curl dnf-plugins-core xorriso createrepo_c
}

build_dnf_repo() {
	install_dnf_tools
	curl -fsSL -o /etc/yum.repos.d/home_ciriarte_network-tools.repo "$OBS_BASE_URL/home:ciriarte:network-tools.repo"
	dnf makecache --repo='home_ciriarte_network-tools' || dnf makecache
	# Without --arch the name query also matches i686 builds and resolves their closure.
	# Older dnf download (EL9) ignores install_weak_deps, so hide the optional
	# packages left out by their flag instead of relying on it.
	local exclude_args=() pkg
	for pkg in "${EXCLUDED_PKGS[@]}"; do
		exclude_args+=(--exclude="$pkg")
	done
	dnf download --resolve --alldeps --arch "${ARCH},noarch" --setopt=install_weak_deps=False \
		"${exclude_args[@]}" --destdir "$PKG_DIR" "${INSTALL_PKGS[@]}"
	if ! find "$PKG_DIR" -type f -name '*.rpm' -print -quit | grep -q .; then
		echo "No RPMs were downloaded" >&2
		exit 1
	fi
	verify_rpm_bundle
	createrepo_c "$STAGING_DIR/repo"
	write_rpm_installer
}

reset_workspace
case "$PACKAGE_MANAGER" in
	apt) build_apt_repo ;;
	zypper) build_zypper_repo ;;
	dnf) build_dnf_repo ;;
	*) echo "Unsupported package manager: $PACKAGE_MANAGER" >&2; exit 2 ;;
esac
build_iso
