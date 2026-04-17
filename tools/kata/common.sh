#!/usr/bin/env bash

# Shared helpers for the Kata setup and smoke-test scripts.

kata_export_config_vars() {
  local config_var

  for config_var in \
    CONTAINERD_ADDRESS \
    CRICTL_VERSION \
    KATA_ASTERINAS_KERNEL_PATH \
    KATA_CGROUP_NAMESPACE \
    KATA_CGROUP_PARENT \
    KATA_CHECK_DEBUG \
    KATA_FORCE_APT \
    KATA_GUEST_KERNEL \
    KATA_INSTALL_CRICTL \
    KATA_NERDCTL_DEBUG \
    KATA_NERDCTL_RUNTIME \
    KATA_PASSES \
    KATA_PAYLOAD_IMAGE \
    KATA_PULL_LOG_FILE \
    KATA_RUN_LOG_FILE \
    KATA_SNAPSHOTTER \
    KATA_STATIC_TARBALL_CACHE_DIR \
    KATA_STATIC_TARBALL_RELEASE_REPO \
    KATA_STATIC_TARBALL_SHA256 \
    KATA_STATIC_TARBALL_SHA256_URL \
    KATA_STATIC_TARBALL_URL \
    KATA_TEST_COMMAND \
    KATA_TEST_COMMAND_SHELL \
    KATA_TEST_EXPECT_OUTPUT_REGEX \
    KATA_TEST_IMAGE \
    KATA_TEST_LOG_FILE \
    KATA_TEST_NAME \
    KATA_TEST_NET \
    KATA_TEST_PULL_IMAGE \
    KATA_VERSION \
    NERDCTL_VERSION \
    PAUSE_IMAGE; do
    if [ "${!config_var+x}" = x ]; then
      export "${config_var}"
    fi
  done
}

kata_load_config() {
  local default_config_file="$1"
  local config_file="${KATA_CONFIG_FILE:-${default_config_file}}"

  if [ ! -f "${config_file}" ]; then
    echo "Kata config file not found: ${config_file}" >&2
    return 1
  fi

  KATA_CONFIG_FILE="${config_file}"
  # shellcheck source=/dev/null
  source "${config_file}"
  export KATA_CONFIG_FILE
  kata_export_config_vars
}

kata_handle_help_or_no_args() {
  local usage_fn="$1"
  shift

  case "${1:-}" in
    -h | --help)
      "${usage_fn}"
      exit 0
      ;;
  esac

  if [ "$#" -ne 0 ]; then
    echo "Unexpected arguments: $*" >&2
    echo >&2
    "${usage_fn}" >&2
    exit 1
  fi
}

wait_for_exit() {
  local process_id="$1"

  for _ in $(seq 1 50); do
    if ! kill -0 "${process_id}" 2>/dev/null; then
      return 0
    fi
    sleep 0.2
  done

  kill -9 "${process_id}" 2>/dev/null || true
}
