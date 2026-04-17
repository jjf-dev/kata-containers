#!/usr/bin/env bash

set -euo pipefail

OVERLAYFS_CHECK_ROOT=''
OVERLAYFS_CHECK_TMPFS=''

show_help() {
  cat <<'EOF'
Usage: bash tools/kata/check_overlayfs.sh

Checks whether the current environment can create an `overlayfs` mount for
container rootfs staging, and whether the current backing filesystem can host
the overlay `upperdir` and `workdir`.

The script runs two probes:
  1. mount an overlay using a probe directory under `${TMPDIR:-/tmp}`
  2. if that fails, retry with `upperdir` and `workdir` on a fresh `tmpfs`

Interpretation:
  - pass on probe 1: the current backing filesystem can host overlay upper/work
  - fail on probe 1, pass on probe 2: overlayfs works, but the current backing
    filesystem cannot host overlay upper/work (common with nested overlayfs)
  - fail on both probes: overlayfs is unavailable in this environment

Environment:
  TMPDIR  Optional base directory for probe 1. Defaults to `/tmp`.
EOF
}

show_mount_info() {
  local path="$1"

  printf '%s -> ' "${path}"
  findmnt -no TARGET,FSTYPE,OPTIONS -T "${path}"
}

cleanup_mount() {
  local mount_path="$1"

  if mountpoint -q "${mount_path}" 2>/dev/null; then
    umount "${mount_path}"
  fi
}

cleanup_probe_root() {
  set +eu

  cleanup_mount "${OVERLAYFS_CHECK_ROOT}/current/merged"
  cleanup_mount "${OVERLAYFS_CHECK_ROOT}/tmpfs/tmpfs-case/merged"
  cleanup_mount "${OVERLAYFS_CHECK_ROOT}/mixed/merged"
  cleanup_mount "${OVERLAYFS_CHECK_TMPFS}"
  rm -rf "${OVERLAYFS_CHECK_ROOT}"
}

run_overlay_probe() {
  local probe_name="$1"
  local lower_dir="$2"
  local upper_dir="$3"
  local work_dir="$4"
  local merged_dir="$5"

  mkdir -p "${lower_dir}" "${upper_dir}" "${work_dir}" "${merged_dir}"
  printf 'overlayfs probe\n' > "${lower_dir}/probe.txt"

  printf '\n== %s ==\n' "${probe_name}"
  show_mount_info "${lower_dir}"
  show_mount_info "${upper_dir}"
  show_mount_info "${work_dir}"

  if mount -t overlay overlay \
    -o "lowerdir=${lower_dir},upperdir=${upper_dir},workdir=${work_dir}" \
    "${merged_dir}"; then
    printf 'mounted -> '
    findmnt -no SOURCE,FSTYPE,OPTIONS "${merged_dir}"
    cat "${merged_dir}/probe.txt"
    cleanup_mount "${merged_dir}"
    return 0
  fi

  return 1
}

main() {
  local probe_root="${TMPDIR:-/tmp}/kata-overlayfs-check.$$"
  local tmpfs_root="${probe_root}/tmpfs"
  local current_backing_failed=0
  local tmpfs_mount_failed=0

  OVERLAYFS_CHECK_ROOT="${probe_root}"
  OVERLAYFS_CHECK_TMPFS="${tmpfs_root}"
  trap cleanup_probe_root EXIT

  mkdir -p "${probe_root}"

  printf 'kernel=%s\n' "$(uname -a)"
  printf 'overlayfs entry: '
  grep -w overlay /proc/filesystems || true
  show_mount_info "${TMPDIR:-/tmp}"

  if run_overlay_probe \
    "probe 1: all overlay dirs under ${TMPDIR:-/tmp}" \
    "${probe_root}/current/lower" \
    "${probe_root}/current/upper" \
    "${probe_root}/current/work" \
    "${probe_root}/current/merged"; then
    printf '\nRESULT: current backing filesystem supports overlay upper/work.\n'
    return 0
  fi
  current_backing_failed=1

  printf '\nprobe 1 failed; retrying with `tmpfs` for `upperdir` and `workdir`.\n'
  mkdir -p "${tmpfs_root}"
  if ! mount -t tmpfs tmpfs "${tmpfs_root}"; then
    tmpfs_mount_failed=1
  fi

  if [ "${tmpfs_mount_failed}" -eq 0 ] &&
    run_overlay_probe \
      "probe 2: lower on ${TMPDIR:-/tmp}, upper/work on tmpfs" \
      "${probe_root}/mixed/lower" \
      "${tmpfs_root}/mixed/upper" \
      "${tmpfs_root}/mixed/work" \
      "${probe_root}/mixed/merged"; then
    cat <<'EOF'

RESULT: overlayfs is available, but the current backing filesystem cannot host
`upperdir` and `workdir`.

Use a non-overlay-backed location for overlay upper/work, such as:
  - a `tmpfs` mounted at `/var/lib/containerd`
  - a host bind mount backed by `ext4`, `xfs`, or another real filesystem
EOF
    return 1
  fi

  if [ "${tmpfs_mount_failed}" -eq 0 ] &&
    run_overlay_probe \
      "probe 3: all overlay dirs on tmpfs" \
      "${tmpfs_root}/tmpfs-case/lower" \
      "${tmpfs_root}/tmpfs-case/upper" \
      "${tmpfs_root}/tmpfs-case/work" \
      "${tmpfs_root}/tmpfs-case/merged"; then
    cat <<'EOF'

RESULT: overlayfs works on tmpfs, but not on the current backing filesystem.

This usually means the outer container rootfs is itself `overlayfs`, so nested
overlay upper/work directories are rejected by the kernel.
EOF
    return 1
  fi

  if [ "${current_backing_failed}" -eq 1 ] && [ "${tmpfs_mount_failed}" -eq 1 ]; then
    cat <<'EOF'

RESULT: could not mount the tmpfs fallback probe, so the environment cannot be
classified further.
EOF
    return 1
  fi

  cat <<'EOF'

RESULT: overlayfs mounts failed even with the tmpfs fallback.

This environment likely lacks usable overlayfs support for the Kata host-side
rootfs staging path.
EOF
  return 1
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  show_help
  exit 0
fi

if [ "$#" -ne 0 ]; then
  echo "Unexpected arguments: $*" >&2
  echo >&2
  show_help >&2
  exit 1
fi

main
