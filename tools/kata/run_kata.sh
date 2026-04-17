#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/kata/common.sh
source "${script_dir}/common.sh"

show_help() {
  cat <<'EOF'
Usage: bash tools/kata/run_kata.sh <smoke|pass|workload>

Runs one of the predefined Kata tasks.

Commands:
  smoke     Installs the local Kata test environment and runs one or more
            smoke-test passes.
  pass      Runs one full Kata pass:
            1. start background services
            2. validate the environment
            3. run the configured workload
            4. stop background services
  workload  Runs the configured Kata workload against the already-started
            inner `containerd` daemon.

Environment:
  KATA_CONFIG_FILE              Optional Bash config fragment. Default:
                                tools/kata/config/smoke-test.env.
  KATA_PASSES                   Number of passes to run for `smoke`.
  CONTAINERD_ADDRESS            Inner `containerd` socket.
  KATA_TEST_NAME                Friendly workload name used in logs.
  KATA_TEST_IMAGE               Smoke-test image.
  KATA_TEST_COMMAND             Shell command run inside the test container.
  KATA_TEST_COMMAND_SHELL       Shell used for `KATA_TEST_COMMAND`. Set empty
                                to use `KATA_TEST_COMMAND_ARGS` from a config
                                file instead.
  KATA_TEST_EXPECT_OUTPUT_REGEX Expected regex checked against stdout/stderr.
                                Set empty to skip output matching.
  KATA_TEST_TIMEOUT             Timeout in seconds for the `nerdctl run`
                                workload. Default: 300.
  KATA_TEST_PULL_IMAGE          Set to 0/false/no to skip `nerdctl pull`.
  KATA_TEST_NET                 `nerdctl run --net` value.
  KATA_NERDCTL_DEBUG            Set to 1/true/yes to add `--debug-full` and
                                print `nerdctl run` output during successful
                                runs too.
  KATA_NERDCTL_RUNTIME          Runtime name.
  KATA_CGROUP_NAMESPACE         `nerdctl run --cgroupns` value.
  KATA_CGROUP_PARENT            Host cgroup parent.
  KATA_SNAPSHOTTER              Optional snapshotter passed to `nerdctl`.
EOF
}

check_local_cgroup_delegation() {
  local probe_dir

  if [ ! -f /sys/fs/cgroup/cgroup.controllers ]; then
    return 0
  fi

  probe_dir="/sys/fs/cgroup/kata-script-preflight-$$"
  mkdir "${probe_dir}"
  if ! printf '+cpu\n' > "${probe_dir}/cgroup.subtree_control" 2>/dev/null; then
    rmdir "${probe_dir}" 2>/dev/null || true
    echo "Local cgroup v2 hierarchy cannot delegate controllers required by Kata." >&2
    echo "Run this inside a dev container started with a delegable cgroup setup (the CI job uses --privileged --cgroupns host)." >&2
    exit 1
  fi
  rmdir "${probe_dir}" 2>/dev/null || true
}

should_enable_nerdctl_debug() {
  case "${KATA_NERDCTL_DEBUG:-0}" in
    1 | true | TRUE | yes | YES)
      return 0
      ;;
  esac

  return 1
}

should_pull_test_image() {
  case "${KATA_TEST_PULL_IMAGE:-1}" in
    0 | false | FALSE | no | NO)
      return 1
      ;;
  esac

  return 0
}

emit_github_error_tail() {
  local title="$1"
  local file_path="$2"
  local message

  if [ ! -f "${file_path}" ]; then
    return 0
  fi

  message="$(python3 -c 'import pathlib, sys; text = pathlib.Path(sys.argv[1]).read_text(); text = text[-6000:]; text = text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A"); print(text)' "${file_path}")"
  echo "::error title=${title}::${message}"
}

build_test_command() {
  if declare -p KATA_TEST_COMMAND_ARGS >/dev/null 2>&1; then
    test_command=("${KATA_TEST_COMMAND_ARGS[@]}")
    return 0
  fi

  if [ -n "${KATA_TEST_COMMAND_SHELL}" ]; then
    test_command=("${KATA_TEST_COMMAND_SHELL}" -c "${KATA_TEST_COMMAND}")
    return 0
  fi

  echo "Set \`KATA_TEST_COMMAND_SHELL\` or define \`KATA_TEST_COMMAND_ARGS\` in ${KATA_CONFIG_FILE}." >&2
  return 1
}

ensure_cgroup_parent() {
  local available_controllers
  local enabled_controllers
  local controller
  local -a controllers_to_enable

  if [ ! -f /sys/fs/cgroup/cgroup.controllers ]; then
    return 0
  fi

  mkdir -p "${cgroup_parent_path}"
  available_controllers="$(cat "${cgroup_parent_path}/cgroup.controllers")"
  enabled_controllers="$(cat "${cgroup_parent_path}/cgroup.subtree_control")"
  controllers_to_enable=()

  for controller in cpu cpuset; do
    if grep -qw "${controller}" <<< "${available_controllers}" &&
      ! grep -qw "${controller}" <<< "${enabled_controllers}"; then
      controllers_to_enable+=("+${controller}")
    fi
  done

  if [ "${#controllers_to_enable[@]}" -gt 0 ]; then
    printf '%s\n' "${controllers_to_enable[*]}" > "${cgroup_parent_path}/cgroup.subtree_control"
  fi
}

run_workload_task() (
  local containerd_address image runtime snapshotter test_name expected_output_regex
  local cgroup_namespace cgroup_parent pull_log_file run_log_file test_log_file
  local test_net_mode cgroup_parent_path test_timeout
  local captured_output_file
  local rc
  local -a cgroup_parent_args
  local -a nerdctl_debug_args
  local -a snapshotter_args
  local -a test_command

  workload_cleanup() {
    rc=$?

    if [ "${rc}" -ne 0 ]; then
      if [ -s "${run_log_file}" ]; then
        emit_github_error_tail "nerdctl run (${test_name})" "${run_log_file}"
        echo "::group::$(basename "${run_log_file}")"
        cat "${run_log_file}" || true
        echo "::endgroup::"
      fi
      if [ -s "${pull_log_file}" ]; then
        emit_github_error_tail "nerdctl pull (${test_name})" "${pull_log_file}"
        echo "::group::$(basename "${pull_log_file}")"
        cat "${pull_log_file}" || true
        echo "::endgroup::"
      fi
      if [ -s "${test_log_file}" ]; then
        emit_github_error_tail "nerdctl workload (${test_name})" "${test_log_file}"
        echo "::group::$(basename "${test_log_file}")"
        cat "${test_log_file}" || true
        echo "::endgroup::"
      fi
      if [ -f /tmp/containerd.log ]; then
        emit_github_error_tail "containerd log" /tmp/containerd.log
        echo "::group::containerd.log"
        cat /tmp/containerd.log || true
        echo "::endgroup::"
      fi
      if [ -f /tmp/kata-syslog.log ]; then
        emit_github_error_tail "kata syslog" /tmp/kata-syslog.log
        echo "::group::kata-syslog.log"
        cat /tmp/kata-syslog.log || true
        echo "::endgroup::"
      fi
      if [ -f /tmp/kata-console.log ]; then
        emit_github_error_tail "kata console" /tmp/kata-console.log
        echo "::group::kata-console.log"
        cat /tmp/kata-console.log || true
        echo "::endgroup::"
      fi
      if [ -f /tmp/kata-qemu-serial.log ]; then
        emit_github_error_tail "kata qemu serial" /tmp/kata-qemu-serial.log
        echo "::group::kata-qemu-serial.log"
        cat /tmp/kata-qemu-serial.log || true
        echo "::endgroup::"
      fi
    fi

    rm -f "${captured_output_file:-}" "${test_log_file}"
  }

  containerd_address="${CONTAINERD_ADDRESS}"
  image="${KATA_TEST_IMAGE}"
  runtime="${KATA_NERDCTL_RUNTIME}"
  snapshotter="${KATA_SNAPSHOTTER}"
  test_name="${KATA_TEST_NAME}"
  expected_output_regex="${KATA_TEST_EXPECT_OUTPUT_REGEX}"
  cgroup_namespace="${KATA_CGROUP_NAMESPACE}"
  cgroup_parent="${KATA_CGROUP_PARENT}"
  cgroup_parent_path="/sys/fs/cgroup${cgroup_parent}"
  pull_log_file="${KATA_PULL_LOG_FILE:-/tmp/nerdctl-pull.txt}"
  run_log_file="${KATA_RUN_LOG_FILE:-/tmp/nerdctl-run-command.txt}"
  test_log_file="${KATA_TEST_LOG_FILE:-/tmp/nerdctl-run.txt}"
  test_net_mode="${KATA_TEST_NET}"
  test_timeout="${KATA_TEST_TIMEOUT:-300}"

  build_test_command

  : > "${pull_log_file}"
  : > "${run_log_file}"
  : > "${test_log_file}"

  captured_output_file="$(mktemp)"
  trap workload_cleanup EXIT

  cgroup_parent_args=()
  nerdctl_debug_args=()
  snapshotter_args=()
  if [ "${cgroup_namespace}" = "host" ]; then
    ensure_cgroup_parent
    cgroup_parent_args=(--cgroup-parent "${cgroup_parent}")
  fi

  if [ -n "${snapshotter}" ]; then
    snapshotter_args=(--snapshotter "${snapshotter}")
  fi

  if should_enable_nerdctl_debug; then
    nerdctl_debug_args=(--debug-full)
  fi

  if should_pull_test_image; then
    nerdctl "${snapshotter_args[@]}" --address "${containerd_address}" pull --quiet "${image}" \
      2>&1 | tee "${pull_log_file}"
  fi

  printf 'image=%s\n' "${image}" > "${run_log_file}"
  printf 'runtime=%s\n' "${runtime}" >> "${run_log_file}"
  printf 'snapshotter=%s\n' "${snapshotter:-nerdctl-default}" >> "${run_log_file}"
  printf 'net=%s\n' "${test_net_mode}" >> "${run_log_file}"
  printf 'command=' >> "${run_log_file}"
  printf '%q ' "${test_command[@]}" >> "${run_log_file}"
  printf '\n\n' >> "${run_log_file}"

  timeout "${test_timeout}" \
    nerdctl "${nerdctl_debug_args[@]}" --address "${containerd_address}" run \
      --rm \
      --cgroup-manager cgroupfs \
      "${cgroup_parent_args[@]}" \
      --cgroupns "${cgroup_namespace}" \
      --net "${test_net_mode}" \
      "${snapshotter_args[@]}" \
      --runtime "${runtime}" \
      "${image}" \
      "${test_command[@]}" 2>&1 | tee -a "${run_log_file}" > "${captured_output_file}"

  cp "${captured_output_file}" "${test_log_file}"

  if [ -n "${expected_output_regex}" ]; then
    grep -E "${expected_output_regex}" "${captured_output_file}"
  fi

  ls -l /dev/kvm || true
)

run_pass_task() (
  pass_cleanup() {
    bash "${script_dir}/kata_services.sh" stop
  }

  trap pass_cleanup EXIT

  bash "${script_dir}/kata_services.sh" start
  bash "${script_dir}/kata_env.sh" check
  run_workload_task
)

run_smoke_task() {
  local pass_count
  local pass_index

  pass_count="${KATA_PASSES}"
  if ! [[ "${pass_count}" =~ ^[1-9][0-9]*$ ]]; then
    echo "KATA_PASSES must be a positive integer, got: ${pass_count}" >&2
    exit 1
  fi

  check_local_cgroup_delegation
  bash "${script_dir}/kata_env.sh" install

  for pass_index in $(seq 1 "${pass_count}"); do
    echo "==> Kata smoke-test pass ${pass_index}/${pass_count}"
    run_pass_task
  done
}

main() {
  local command="${1:-}"

  case "${command}" in
    -h | --help)
      show_help
      exit 0
      ;;
    smoke | pass | workload)
      ;;
    '')
      echo "Missing command." >&2
      echo >&2
      show_help >&2
      exit 1
      ;;
    *)
      echo "Unsupported command: ${command}" >&2
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

  kata_load_config "${script_dir}/config/smoke-test.env"

  case "${command}" in
    smoke)
      run_smoke_task
      ;;
    pass)
      run_pass_task
      ;;
    workload)
      run_workload_task
      ;;
  esac
}

main "$@"
