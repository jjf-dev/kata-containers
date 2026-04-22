Kata helpers live here.

- `common.sh`: shared shell helpers used by the other Kata scripts
- `run_kata.sh`: provides predefined `smoke`, `pass`, and `workload` Kata tasks
- `kata_env.sh`: provides `install` and `check` for the shared Kata environment lifecycle
- `kata_services.sh`: provides `start`, `stop`, and `status` for the background Kata smoke-test services
- `interactive_doc_test.py`: replays the documented `docker run -it` and
  inner `nerdctl run -it` flows with `pexpect` for both the `asterinas/kata`
  and `asterinas/asterinas` images
- `check_overlayfs.sh`: probes whether the current host-side backing filesystem
  can support overlayfs `upperdir` and `workdir` for local Kata runs
- `config/`: repo-owned Kata, CNI, `containerd`, and smoke-test config files used by the scripts

## Configuration

- Default smoke-test settings live in `tools/kata/config/smoke-test.env`.
- By default, `bash tools/kata/kata_env.sh install` resolves the latest
  Asterinas Kata static tarball from `kata-containers/kata-containers`.
- Repository workflows override `KATA_STATIC_TARBALL_RELEASE_REPO` to the
  current GitHub repository so pull requests in a fork can validate that
  repository's latest Asterinas Kata release assets.
- Override a value ad hoc with environment variables, for example:
  `KATA_TEST_IMAGE=docker.io/library/ubuntu:24.04 bash tools/kata/run_kata.sh smoke`
- Pin a specific tarball explicitly with `KATA_STATIC_TARBALL_URL=...` when you
  do not want the latest release.
- Force the Linux guest kernel from a multi-kernel Kata release with
  `KATA_GUEST_KERNEL=linux`.
- Or point `KATA_CONFIG_FILE` at another Bash config fragment.
- Legacy `KATA_ALPINE_*` overrides still map to the new `KATA_TEST_*` names.
- The default workload still pulls Alpine and runs `cat /etc/alpine-release`, but
  the image, in-container command, and output check are now script-configurable.
- `interactive_doc_test.py` uses `KATA_DOC_TEST_WORKLOAD_IMAGE`, which defaults
  to `docker.io/alpine:latest`. For local validation in environments where
  Docker Hub is unreachable, you can temporarily switch it to
  `docker.1ms.run/alpine:latest`.

## Local virtio-fs note

- The local `bash tools/kata/run_kata.sh smoke` flow now uses `virtio-fs`.
- In the current dev container, `/dev/shm` is only `64M`, which is too small
  for Kata's default shared guest memory backend when the VM memory is `2048M`.
- The repo-owned Kata drop-in therefore sets `file_mem_backend = "/tmp"` so
  `virtio-fs` local runs do not fail during early VM boot.
- If local `virtio-fs` bring-up fails again, check both:
  - the outer container flags (`--privileged --cgroupns=host`)
  - the available space of the configured file-backed memory directory
- If you want to use host-side overlayfs rootfs staging, run
  `bash tools/kata/check_overlayfs.sh` first to verify that the current backing
  filesystem can host overlay `upperdir` and `workdir`.
