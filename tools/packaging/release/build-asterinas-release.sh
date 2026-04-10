#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0
#

set -o errexit
set -o nounset
set -o pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root_dir="$(cd "${script_dir}/../../../" && pwd)"

ARCHITECTURE="${ARCHITECTURE:-amd64}"
VERSION="${VERSION:-$(<"${repo_root_dir}/VERSION")}"
KATA_STATIC_RELEASE_REPOSITORY="${KATA_STATIC_RELEASE_REPOSITORY:-kata-containers/kata-containers}"
BASE_TARBALL_URL="${BASE_TARBALL_URL:-https://github.com/${KATA_STATIC_RELEASE_REPOSITORY}/releases/download/${VERSION}/kata-static-${VERSION}-${ARCHITECTURE}.tar.zst}"
FORCE_RUNTIME_BUILD="${FORCE_RUNTIME_BUILD:-false}"

ASTERINAS_REPOSITORY="${ASTERINAS_REPOSITORY:-}"
ASTERINAS_REF="${ASTERINAS_REF:-}"
ASTERINAS_BUILDER_IMAGE="${ASTERINAS_BUILDER_IMAGE:-}"
ASTERINAS_KERNEL="${ASTERINAS_KERNEL:-}"

BUILD_ROOT="${BUILD_ROOT:-${repo_root_dir}/build/asterinas-release}"
DOWNLOAD_DIR="${BUILD_ROOT}/downloads"
STAGING_DIR="${BUILD_ROOT}/staging"
DIST_DIR="${BUILD_ROOT}/dist"
ROOTFS_DIR="${BUILD_ROOT}/rootfs"

BASE_TARBALL="${DOWNLOAD_DIR}/kata-static-${VERSION}-${ARCHITECTURE}.tar.zst"
RELEASE_BASENAME="${RELEASE_BASENAME:-kata-static-${VERSION}-asterinas-${ARCHITECTURE}}"
RELEASE_ASSET="${DIST_DIR}/${RELEASE_BASENAME}.tar.zst"
MANIFEST_FILE="${DIST_DIR}/${RELEASE_BASENAME}.manifest.json"
CHECKSUMS_FILE="${DIST_DIR}/${RELEASE_BASENAME}.SHA256SUMS"
BUILD_SUMMARY="${DIST_DIR}/${RELEASE_BASENAME}.summary.md"
RELEASE_NOTES="${DIST_DIR}/${RELEASE_BASENAME}.release-notes.md"

KATA_SHARE_DIR_REL="opt/kata/share/kata-containers"
KATA_DEFAULTS_DIR_REL="opt/kata/share/defaults/kata-containers"

die() {
	echo >&2 "ERROR: $*"
	exit 1
}

require_cmd() {
	local cmd

	for cmd in "$@"; do
		command -v "${cmd}" >/dev/null 2>&1 || die "missing required command: ${cmd}"
	done
}

is_true() {
	case "${1,,}" in
		1|true|yes|on)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

emit_output() {
	if [ -n "${GITHUB_OUTPUT:-}" ]; then
		printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT}"
	fi
}

append_summary() {
	printf '%s\n' "$*" >> "${BUILD_SUMMARY}"
}

infer_guest_rootfs() {
	local initrd_target_name="$1"

	case "${initrd_target_name}" in
		kata-alpine-*.initrd)
			GUEST_OS_NAME="alpine"
			GUEST_OS_VERSION="${initrd_target_name#kata-alpine-}"
			GUEST_OS_VERSION="${GUEST_OS_VERSION%.initrd}"
			;;
		kata-ubuntu-*.initrd)
			GUEST_OS_NAME="ubuntu"
			GUEST_OS_VERSION="${initrd_target_name#kata-ubuntu-}"
			GUEST_OS_VERSION="${GUEST_OS_VERSION%.initrd}"
			;;
		*)
			die "unsupported initrd target name: ${initrd_target_name}"
			;;
	esac
}

patch_qemu_config() {
	local source_config="$1"
	local dest_config="$2"

	cp "${source_config}" "${dest_config}"
	sed -i \
		-e 's#^kernel = ".*"#kernel = "/opt/kata/share/kata-containers/aster-kernel-osdk-bin.qemu_elf"#' \
		-e 's#^image = ".*"#initrd = "/opt/kata/share/kata-containers/kata-containers-initrd.img"#' \
		-e 's#^initrd = ".*"#initrd = "/opt/kata/share/kata-containers/kata-containers-initrd.img"#' \
		"${dest_config}"
}

maybe_build_runtime() {
	local runtime_tag="refs/tags/${VERSION}"

	RUNTIME_REBUILT=false
	RUNTIME_REBUILD_REASON="unchanged"

	if is_true "${FORCE_RUNTIME_BUILD}"; then
		RUNTIME_REBUILT=true
		RUNTIME_REBUILD_REASON="forced by workflow input"
	elif ! git -C "${repo_root_dir}" rev-parse --verify --quiet "${runtime_tag}" >/dev/null; then
		RUNTIME_REBUILT=true
		RUNTIME_REBUILD_REASON="release tag ${VERSION} is unavailable for comparison"
	elif ! git -C "${repo_root_dir}" diff --quiet "${runtime_tag}" -- src/runtime; then
		RUNTIME_REBUILT=true
		RUNTIME_REBUILD_REASON="src/runtime differs from ${VERSION}"
	fi

	if ! is_true "${RUNTIME_REBUILT}"; then
		return 0
	fi

	append_summary "- Rebuilding \`kata-runtime\`: ${RUNTIME_REBUILD_REASON}"
	make -C "${repo_root_dir}/src/runtime" build
	make -C "${repo_root_dir}/src/runtime" PREFIX=/opt/kata DESTDIR="${STAGING_DIR}" install
}

build_initrd() {
	local initrd_output="$1"

	rm -rf "${ROOTFS_DIR}"

	pushd "${repo_root_dir}/tools/osbuilder/rootfs-builder" >/dev/null
	sudo -E \
		AGENT_INIT=yes \
		USE_DOCKER=true \
		SECCOMP=no \
		INIT_DATA=no \
		OS_VERSION="${GUEST_OS_VERSION}" \
		ROOTFS_DIR="${ROOTFS_DIR}" \
		./rootfs.sh "${GUEST_OS_NAME}"
	popd >/dev/null

	pushd "${repo_root_dir}/tools/osbuilder/initrd-builder" >/dev/null
	sudo -E \
		AGENT_INIT=yes \
		INITRD_IMAGE="${initrd_output}" \
		./initrd_builder.sh "${ROOTFS_DIR}"
	popd >/dev/null
}

write_manifest() {
	cat > "${MANIFEST_FILE}" <<EOF
{
  "built_at_utc": "${BUILD_TIME_UTC}",
  "kata_version": "${VERSION}",
  "kata_commit": "${KATA_COMMIT}",
  "architecture": "${ARCHITECTURE}",
  "base_tarball_url": "${BASE_TARBALL_URL}",
  "base_tarball_file": "$(basename "${BASE_TARBALL}")",
  "asterinas_repository": "${ASTERINAS_REPOSITORY}",
  "asterinas_ref": "${ASTERINAS_REF}",
  "asterinas_builder_image": "${ASTERINAS_BUILDER_IMAGE}",
  "asterinas_kernel_artifact": "$(basename "${ASTERINAS_KERNEL}")",
  "guest_kernel_path": "/opt/kata/share/kata-containers/aster-kernel-osdk-bin.qemu_elf",
  "guest_initrd_path": "/opt/kata/share/kata-containers/kata-containers-initrd.img",
  "guest_rootfs_os": "${GUEST_OS_NAME}",
  "guest_rootfs_version": "${GUEST_OS_VERSION}",
  "runtime_rebuilt": ${RUNTIME_REBUILT},
  "runtime_rebuild_reason": "${RUNTIME_REBUILD_REASON}"
}
EOF
}

write_release_notes() {
	local asset_sha

	asset_sha="$(sha256sum "${RELEASE_ASSET}" | awk '{print $1}')"

	cat > "${RELEASE_NOTES}" <<EOF
# Asterinas Kata release

- Kata version: \`${VERSION}\`
- Architecture: \`${ARCHITECTURE}\`
- Base tarball: \`${BASE_TARBALL_URL}\`
- Kata commit: \`${KATA_COMMIT}\`
- Asterinas repo/ref: \`${ASTERINAS_REPOSITORY}@${ASTERINAS_REF}\`
- Asterinas builder image: \`${ASTERINAS_BUILDER_IMAGE}\`
- Guest kernel: \`/opt/kata/share/kata-containers/aster-kernel-osdk-bin.qemu_elf\`
- Guest initrd: \`/opt/kata/share/kata-containers/kata-containers-initrd.img\`
- Guest rootfs rebuild: \`${GUEST_OS_NAME}:${GUEST_OS_VERSION}\`
- Runtime rebuilt: \`${RUNTIME_REBUILT}\`
- Runtime rebuild reason: \`${RUNTIME_REBUILD_REASON}\`
- Asset SHA256: \`${asset_sha}\`
EOF
}

require_cmd curl git make readlink sed sudo tar zstd sha256sum install cpio
[ -n "${ASTERINAS_KERNEL}" ] || die "ASTERINAS_KERNEL must be set"
[ -f "${ASTERINAS_KERNEL}" ] || die "Asterinas kernel artifact not found: ${ASTERINAS_KERNEL}"

mkdir -p "${DOWNLOAD_DIR}" "${DIST_DIR}"
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"

BUILD_TIME_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
KATA_COMMIT="$(git -C "${repo_root_dir}" rev-parse HEAD)"

: > "${BUILD_SUMMARY}"
append_summary "# Asterinas Kata release build"
append_summary
append_summary "- Time (UTC): \`${BUILD_TIME_UTC}\`"
append_summary "- Kata version: \`${VERSION}\`"
append_summary "- Kata commit: \`${KATA_COMMIT}\`"
append_summary "- Base tarball URL: \`${BASE_TARBALL_URL}\`"
append_summary "- Asterinas repo/ref: \`${ASTERINAS_REPOSITORY}@${ASTERINAS_REF}\`"
append_summary "- Asterinas builder image: \`${ASTERINAS_BUILDER_IMAGE}\`"

append_summary "- Downloading official Kata base tarball"
curl --fail --location --silent --show-error "${BASE_TARBALL_URL}" --output "${BASE_TARBALL}"

append_summary "- Extracting base tarball into staging"
tar -I zstd -xf "${BASE_TARBALL}" -C "${STAGING_DIR}"

share_dir="${STAGING_DIR}/${KATA_SHARE_DIR_REL}"
defaults_dir="${STAGING_DIR}/${KATA_DEFAULTS_DIR_REL}"
runtime_rs_defaults_dir="${defaults_dir}/runtime-rs"

[ -d "${share_dir}" ] || die "missing guest share dir in base tarball"
[ -d "${defaults_dir}" ] || die "missing defaults dir in base tarball"

initrd_link="${share_dir}/kata-containers-initrd.img"
if [ -L "${initrd_link}" ]; then
	initrd_target_rel="$(readlink "${initrd_link}")"
	initrd_target_name="$(basename "${initrd_target_rel}")"
else
	initrd_target_rel="kata-containers-initrd.img"
	initrd_target_name="kata-containers-initrd.img"
fi
infer_guest_rootfs "${initrd_target_name}"
append_summary "- Rebuilding initrd from \`${GUEST_OS_NAME}:${GUEST_OS_VERSION}\` rootfs"

rebuilt_initrd="${BUILD_ROOT}/${initrd_target_name}"
build_initrd "${rebuilt_initrd}"
install -m 0644 "${rebuilt_initrd}" "${share_dir}/${initrd_target_name}"

append_summary "- Installing Asterinas guest kernel"
install -m 0755 "${ASTERINAS_KERNEL}" "${share_dir}/aster-kernel-osdk-bin.qemu_elf"
ln -sfn "aster-kernel-osdk-bin.qemu_elf" "${share_dir}/vmlinuz.container"
ln -sfn "aster-kernel-osdk-bin.qemu_elf" "${share_dir}/vmlinux.container"

maybe_build_runtime
if ! is_true "${RUNTIME_REBUILT}"; then
	append_summary "- Reusing official \`kata-runtime\` binaries"
fi

append_summary "- Creating default Asterinas configs"
patch_qemu_config "${defaults_dir}/configuration-qemu.toml" "${defaults_dir}/configuration-asterinas.toml"
ln -sfn "configuration-asterinas.toml" "${defaults_dir}/configuration.toml"

if [ -f "${runtime_rs_defaults_dir}/configuration-qemu-runtime-rs.toml" ]; then
	patch_qemu_config \
		"${runtime_rs_defaults_dir}/configuration-qemu-runtime-rs.toml" \
		"${runtime_rs_defaults_dir}/configuration-asterinas-runtime-rs.toml"
	ln -sfn "configuration-asterinas-runtime-rs.toml" "${runtime_rs_defaults_dir}/configuration.toml"
fi

append_summary "- Packaging release asset"
tar \
	--sort=name \
	--owner=0 \
	--group=0 \
	--numeric-owner \
	-C "${STAGING_DIR}" \
	-I "zstd -19 -T0" \
	-cf "${RELEASE_ASSET}" \
	.

write_manifest
write_release_notes
sha256sum "${RELEASE_ASSET}" "${MANIFEST_FILE}" "${BUILD_SUMMARY}" "${RELEASE_NOTES}" > "${CHECKSUMS_FILE}"

cat "${BUILD_SUMMARY}" >> "${GITHUB_STEP_SUMMARY:-/dev/null}" 2>/dev/null || true

emit_output "release_asset" "${RELEASE_ASSET}"
emit_output "manifest_file" "${MANIFEST_FILE}"
emit_output "checksums_file" "${CHECKSUMS_FILE}"
emit_output "build_summary" "${BUILD_SUMMARY}"
emit_output "release_notes" "${RELEASE_NOTES}"
