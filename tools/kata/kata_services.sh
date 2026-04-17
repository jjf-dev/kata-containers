#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
config_dir="${script_dir}/config"
containerd_pid_file=/tmp/containerd.pid
syslogd_pid_file=/tmp/syslogd.pid
# shellcheck source=tools/kata/common.sh
source "${script_dir}/common.sh"

show_help() {
  cat <<'EOF'
Usage: bash tools/kata/kata_services.sh <start|stop|status>

Manages the background Kata smoke-test services.

Commands:
  start   Installs repo-owned configs and starts the background services.
  stop    Stops the background services if they are running.
  status  Prints whether the managed services are running.

Environment:
  KATA_CONFIG_FILE  Optional Bash config fragment. Default:
                    tools/kata/config/smoke-test.env.
  KATA_GUEST_KERNEL Optional guest kernel selector: `linux`, `asterinas`, or
                    empty to use the installed Kata default.
  PAUSE_IMAGE       Pause image for inner `containerd`.
EOF
}

select_kata_config_source() {
  case "${KATA_GUEST_KERNEL:-}" in
    linux)
      if [ -f /opt/kata/share/defaults/kata-containers/configuration-qemu.toml ]; then
        echo /opt/kata/share/defaults/kata-containers/configuration-qemu.toml
        return
      fi

      cat >&2 <<'EOF'
Cannot find Kata's Linux guest configuration.
Expected:
  /opt/kata/share/defaults/kata-containers/configuration-qemu.toml

Run `bash tools/kata/kata_env.sh install` before starting Kata services.
EOF
      return 1
      ;;
    asterinas)
      if [ -f /opt/kata/share/defaults/kata-containers/configuration-asterinas.toml ]; then
        echo /opt/kata/share/defaults/kata-containers/configuration-asterinas.toml
        return
      fi

      cat >&2 <<'EOF'
Cannot find Kata's Asterinas guest configuration.
Expected:
  /opt/kata/share/defaults/kata-containers/configuration-asterinas.toml

Run `bash tools/kata/kata_env.sh install` before starting Kata services.
EOF
      return 1
      ;;
    '')
      ;;
    *)
      echo "Unsupported KATA_GUEST_KERNEL: ${KATA_GUEST_KERNEL}" >&2
      echo "Expected \`linux\`, \`asterinas\`, or empty." >&2
      return 1
      ;;
  esac

  if [ -f /opt/kata/share/defaults/kata-containers/configuration.toml ]; then
    echo /opt/kata/share/defaults/kata-containers/configuration.toml
    return
  fi

  if [ -f /opt/kata/share/defaults/kata-containers/configuration-qemu.toml ]; then
    echo /opt/kata/share/defaults/kata-containers/configuration-qemu.toml
    return
  fi

  cat >&2 <<'EOF'
Cannot find Kata's default configuration.
Expected one of:
  /opt/kata/share/defaults/kata-containers/configuration.toml
  /opt/kata/share/defaults/kata-containers/configuration-qemu.toml

Run `bash tools/kata/kata_env.sh install` before starting Kata services.
EOF
  return 1
}

select_qemu_binary_path() {
  local qemu_candidate
  local qemu_candidates=(
    /opt/kata/bin/qemu-system-x86_64
    /usr/local/qemu/bin/qemu-system-x86_64
    /usr/bin/qemu-system-x86_64
    /usr/bin/qemu-kvm
    /usr/libexec/qemu-kvm
    /usr/lib/qemu/qemu-system-x86_64
  )

  if command -v qemu-system-x86_64 >/dev/null 2>&1; then
    command -v qemu-system-x86_64
    return 0
  fi

  for qemu_candidate in "${qemu_candidates[@]}"; do
    if [ -x "${qemu_candidate}" ]; then
      printf '%s\n' "${qemu_candidate}"
      return 0
    fi
  done

  return 1
}

normalize_qemu_config_path() {
  local kata_config_path="$1"
  local qemu_binary_path

  if ! qemu_binary_path="$(select_qemu_binary_path)"; then
    echo "Cannot find a usable QEMU binary for Kata." >&2
    return 1
  fi

  sed -i \
    -e 's#^\(path = \)".*"#\1"'"${qemu_binary_path}"'"#' \
    -e 's#^\(valid_hypervisor_paths = \)\[.*\]#\1["'"${qemu_binary_path}"'"]#' \
    "${kata_config_path}"
}

normalize_kata_guest_artifact_paths() {
  local kata_config_path="$1"
  local packaged_initrd=/opt/kata/share/kata-containers/kata-containers-initrd.img

  if [ -f "${packaged_initrd}" ]; then
    sed -i \
      -e 's#^\([[:space:]]*initrd = \)".*"#\1"'"${packaged_initrd}"'"#' \
      "${kata_config_path}"
  fi
}

select_linux_guest_kernel_path() {
  local kernel_candidate
  local share_dir=/opt/kata/share/kata-containers

  for kernel_candidate in "${share_dir}"/vmlinux-[0-9]* "${share_dir}"/vmlinuz-[0-9]*; do
    if [ -f "${kernel_candidate}" ]; then
      printf '%s\n' "${kernel_candidate}"
      return 0
    fi
  done

  echo "Cannot find a Linux guest kernel under ${share_dir}." >&2
  return 1
}

normalize_linux_guest_kernel_artifacts() {
  local kata_config_path="$1"
  local linux_kernel_path
  local share_dir=/opt/kata/share/kata-containers

  if [ "${KATA_GUEST_KERNEL:-}" != linux ]; then
    return 0
  fi

  linux_kernel_path="$(select_linux_guest_kernel_path)"
  ln -sfn "$(basename "${linux_kernel_path}")" "${share_dir}/vmlinux.container"
  ln -sfn "$(basename "${linux_kernel_path}")" "${share_dir}/vmlinuz.container"
  sed -i \
    -e 's#^\([[:space:]]*kernel = \)".*"#\1"'"${share_dir}/vmlinux.container"'"#' \
    "${kata_config_path}"
}

install_repo_configs() {
  local kata_config_source

  : "${PAUSE_IMAGE:?PAUSE_IMAGE must be set}"

  kata_config_source="$(select_kata_config_source)"

  install -d -m 0755 /etc/kata-containers /etc/kata-containers/config.d
  install -m 0644 "${kata_config_source}" /etc/kata-containers/configuration.toml
  normalize_qemu_config_path /etc/kata-containers/configuration.toml
  normalize_linux_guest_kernel_artifacts /etc/kata-containers/configuration.toml
  normalize_kata_guest_artifact_paths /etc/kata-containers/configuration.toml
  install -m 0644 "${config_dir}/kata-10-container.toml" /etc/kata-containers/config.d/10-container.toml

  install -d -m 0755 /opt/cni /etc/cni/net.d /etc/containerd /run/containerd /var/lib/containerd
  if [ ! -e /opt/cni/bin ]; then
    ln -s /usr/lib/cni /opt/cni/bin
  fi
  install -m 0644 "${config_dir}/cni-10-kata.conflist" /etc/cni/net.d/10-kata.conflist
  sed "s|__PAUSE_IMAGE__|${PAUSE_IMAGE}|g" "${config_dir}/containerd-config.toml.in" > /etc/containerd/config.toml
}

prepare_host_prerequisites() {
  modprobe overlay || true
  modprobe br_netfilter || true
  sysctl -w net.ipv4.ip_forward=1 || true
  sysctl -w net.bridge.bridge-nf-call-iptables=1 || true
  iptables -P FORWARD ACCEPT
}

wait_for_socket() {
  local socket_path="$1"
  local service_name="$2"
  local timeout_seconds="$3"

  if timeout "${timeout_seconds}" bash -c '
    socket_path="$1"
    until [ -S "${socket_path}" ]; do
      sleep 1
    done
  ' bash "${socket_path}"; then
    return 0
  fi

  echo "Timed out waiting for ${service_name} socket: ${socket_path}" >&2
  return 1
}

print_log_tail() {
  local log_file="$1"

  if [ ! -f "${log_file}" ]; then
    return 0
  fi

  echo "--- ${log_file} ---" >&2
  tail -40 "${log_file}" >&2 || true
}

read_pid_file() {
  local pid_file="$1"
  local process_id

  if [ ! -f "${pid_file}" ]; then
    return 1
  fi

  process_id="$(cat "${pid_file}")"
  case "${process_id}" in
    '' | *[!0-9]*)
      return 1
      ;;
  esac

  printf '%s\n' "${process_id}"
}

pid_is_running() {
  local process_id="$1"

  kill -0 "${process_id}" 2>/dev/null
}

cleanup_pid_file() {
  local pid_file="$1"
  local process_id

  if ! process_id="$(read_pid_file "${pid_file}")"; then
    rm -f "${pid_file}"
    return 1
  fi

  if ! pid_is_running "${process_id}"; then
    rm -f "${pid_file}"
    return 1
  fi

  return 0
}

service_is_running() {
  local pid_file="$1"

  cleanup_pid_file "${pid_file}" >/dev/null 2>&1
}

print_status() {
  local service_name="$1"
  local pid_file="$2"
  local expected_socket="${3:-}"
  local process_id='-'
  local state="stopped"

  if service_is_running "${pid_file}"; then
    process_id="$(cat "${pid_file}")"
    state="running"
  fi

  if [ -n "${expected_socket}" ] && [ ! -S "${expected_socket}" ] && [ "${state}" = "running" ]; then
    state="degraded"
  fi

  printf '%s: %s (pid: %s)\n' "${service_name}" "${state}" "${process_id}"
  if [ -n "${expected_socket}" ]; then
    if [ -S "${expected_socket}" ]; then
      printf '  socket: %s (ready)\n' "${expected_socket}"
    else
      printf '  socket: %s (missing)\n' "${expected_socket}"
    fi
  fi
}

services_are_fully_running() {
  service_is_running "${syslogd_pid_file}" &&
    service_is_running "${containerd_pid_file}" &&
    [ -S /dev/log ] &&
    [ -S "${CONTAINERD_ADDRESS}" ]
}

stop_service_from_pid_file() {
  local pid_file="$1"
  local service_name="$2"
  local process_id

  if ! process_id="$(read_pid_file "${pid_file}")"; then
    rm -f "${pid_file}"
    echo "${service_name} is not running."
    return 0
  fi

  if ! pid_is_running "${process_id}"; then
    rm -f "${pid_file}"
    echo "${service_name} is not running."
    return 0
  fi

  kill "${process_id}" 2>/dev/null || true
  wait_for_exit "${process_id}"
  rm -f "${pid_file}"
  echo "Stopped ${service_name}."
}

stop_services() {
  stop_service_from_pid_file "${containerd_pid_file}" "containerd"
  stop_service_from_pid_file "${syslogd_pid_file}" "syslogd"
}

start_services() {
  if services_are_fully_running; then
    echo "Kata services are already running."
    return 0
  fi

  if service_is_running "${syslogd_pid_file}" || service_is_running "${containerd_pid_file}"; then
    echo "Kata services are partially running; restarting them."
    stop_services
  fi

  install_repo_configs
  prepare_host_prerequisites

  rm -f /dev/log /tmp/containerd.log /tmp/kata-syslog.log

  nohup syslogd -n -O /tmp/kata-syslog.log >/tmp/kata-syslog.stdout 2>&1 &
  echo $! > "${syslogd_pid_file}"

  if ! wait_for_socket /dev/log syslogd 10; then
    print_log_tail /tmp/kata-syslog.stdout
    return 1
  fi

  nohup containerd --config /etc/containerd/config.toml --log-level debug >/tmp/containerd.log 2>&1 &
  echo $! > "${containerd_pid_file}"

  if ! wait_for_socket "${CONTAINERD_ADDRESS}" containerd 30; then
    print_log_tail /tmp/containerd.log
    return 1
  fi

  echo "Started Kata services."
}

status_services() {
  print_status "syslogd" "${syslogd_pid_file}" /dev/log
  print_status "containerd" "${containerd_pid_file}" "${CONTAINERD_ADDRESS:-/run/containerd/containerd.sock}"

  if services_are_fully_running; then
    echo "Kata services are running."
    return 0
  fi

  echo "Kata services are not fully running."
  return 1
}

main() {
  local action="${1:-}"

  case "${action}" in
    -h | --help)
      show_help
      exit 0
      ;;
    start | stop | status)
      ;;
    '')
      echo "Missing command." >&2
      echo >&2
      show_help >&2
      exit 1
      ;;
    *)
      echo "Unsupported command: ${action}" >&2
      echo >&2
      show_help >&2
      exit 1
      ;;
  esac

  if [ "$#" -ne 1 ]; then
    echo "Unexpected arguments: ${*:2}" >&2
    echo >&2
    show_help >&2
    exit 1
  fi

  case "${action}" in
    start)
      kata_load_config "${script_dir}/config/smoke-test.env"
      start_services
      ;;
    stop)
      stop_services
      ;;
    status)
      kata_load_config "${script_dir}/config/smoke-test.env"
      status_services
      ;;
  esac
}

main "$@"
