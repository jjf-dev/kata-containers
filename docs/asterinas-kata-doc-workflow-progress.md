# Asterinas Kata Doc Workflow Progress

## 2026-04-22 Initial implementation notes

- Requirement focus:
  - add a new workflow that follows `docs/doc-in-asterinas-repo.md`
  - keep the overall documented flow, but correct commands that are currently off
  - test the interactive `docker run -it` and inner `nerdctl run -it` behavior with `pexpect`
  - mount the local Asterinas tree from `$HOME/asterinas` for the developer flow
  - use local `asterinas/asterinas` and `asterinas/kata` images first, then wire the same logic into CI
- Document drift confirmed and corrected in the implementation plan:
  - `docker run --cgroupns none` is invalid; use `--cgroupns host`
  - the outer container needs `/dev/vhost-net` and `/dev/vsock` in addition to `/dev/kvm` and `/dev/vhost-vsock`
  - helper script names are `tools/kata/kata_env.sh` and `tools/kata/kata_services.sh`
  - the developer flow bind mount should be `-v "${ASTERINAS_SRC}:/root/asterinas"`
  - the Kata config path should be `/etc/kata-containers/configuration.toml`
- Added `tools/kata/interactive_doc_test.py`:
  - uses `pexpect` to drive the documented interactive flow instead of only calling the existing non-interactive smoke helper
  - covers the end-user scenario on `asterinas/kata`
  - covers the kernel-developer scenario on `asterinas/asterinas`
  - validates the local kernel handoff path with `/root/asterinas/target/osdk/aster-kernel-osdk-bin.qemu_elf`
- Added `.github/workflows/test-asterinas-kata-docs.yml`:
  - one job replays the documented end-user flow against `asterinas/kata`
  - one job replays the documented kernel-developer flow against `asterinas/asterinas`
  - both jobs install `pexpect` only when needed and upload transcripts as artifacts
- Local environment findings:
  - `pexpect` is already available in the current local environment
  - local `asterinas/asterinas:*` and `asterinas/kata:*` images are present
  - the local Asterinas source tree exists at `/home/jianfeng/asterinas`
  - the local machine exposes `/dev/kvm`, `/dev/vhost-net`, `/dev/vhost-vsock`, and `/dev/vsock`
  - local Docker Hub access currently times out during the inner `nerdctl run`
- Local validation completed so far:
  - the documented end-user flow passed locally with
    `python3 tools/kata/interactive_doc_test.py --scenario end-user --workload-image docker.1ms.run/alpine:latest`
  - this successfully covered the interactive outer `docker run -it`, `tools/kata/kata_services.sh start`, inner `nerdctl run -it`, and post-exit `nerdctl rm foo` sequence
  - after cleaning the `pexpect` output parsing and passing outer env overrides explicitly, the same end-user replay was run again locally and still passed
  - per the latest user instruction, the kernel-developer flow does not need to finish locally; CI is now the authoritative validation path for that scenario
- Local validation policy:
  - local testing uses `docker.1ms.run/alpine:latest` as the workload image when Docker Hub is unreachable
  - CI must keep using `docker.io/alpine:latest`
- CI wiring note:
  - the kernel-developer workflow path exports `KATA_STATIC_TARBALL_RELEASE_REPO=${GITHUB_REPOSITORY}` so `tools/kata/kata_env.sh install` validates this repository's published Asterinas Kata release assets instead of defaulting to upstream `kata-containers/kata-containers`
  - the first GitHub dispatch attempt exposed a GitHub expression-validation issue: `runner.temp` is not accepted in this workflow's job-level `env`, so the log directory paths were normalized to plain `/tmp/...`
- Next steps:
  - run a final quick local end-user replay after the latest script cleanup
  - static-check the new workflow and script changes
  - push and wait for CI to verify both documented flows end to end
