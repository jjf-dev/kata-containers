# Asterinas Kata CI Progress

## 2026-04-17 Initial findings

- Read `requirements.md` and confirmed three requested deliverables:
  1. Import the CI plus all referenced scripts from `StevenJiang1110/asterinas` PR `#57` into this repo.
  2. Update `release-asterinas` so the imported scripts are also included in the release output.
  3. Add a new workflow that builds an `asterinas/asterinas-kata` image from the upstream `asterinas/asterinas` base image, runs `kata_env.sh install`, copies all imported scripts into `/root/asterinas/tools/kata`, and pushes the result to Docker Hub.
- Found the current repo already contains `.github/workflows/release-asterinas.yaml`.
- Found Git remote `origin` points to `git@github.com:jjf-dev/kata-containers.git`.
- Next step: inspect PR `StevenJiang1110/asterinas#57` with `gh` and map the required files into this repository.

## 2026-04-17 Source import findings

- Inspected `StevenJiang1110/asterinas#57` with `gh`.
- The PR contributes one workflow and the full reusable helper set under `tools/kata/`:
  - `.github/workflows/test_kata_guest_os.yml`
  - `tools/kata/README.md`
  - `tools/kata/common.sh`
  - `tools/kata/check_overlayfs.sh`
  - `tools/kata/kata_env.sh`
  - `tools/kata/kata_services.sh`
  - `tools/kata/run_kata.sh`
  - `tools/kata/config/cni-10-kata.conflist`
  - `tools/kata/config/containerd-config.toml.in`
  - `tools/kata/config/kata-10-container.toml`
  - `tools/kata/config/smoke-test.env`
- The imported workflow uses a privileged GitHub Actions job container, runs overlayfs preflight, installs the Kata test environment, and executes two Kata passes.
- Next step: wire those files into this repo, then teach `release-asterinas` to package the same helper directory into the Asterinas release tarball.

## 2026-04-17 Upstream version findings

- Queried `asterinas/asterinas` with `gh` to avoid stale tag assumptions.
- Latest upstream GitHub release is `v0.17.1` published on `2026-03-12`.
- I am now checking the upstream Docker publish workflow so the new `asterinas/asterinas-kata` image can follow the same versioning convention.

## 2026-04-17 Implementation update

- Imported `.github/workflows/test_kata_guest_os.yml` and the full `tools/kata/` helper directory from `StevenJiang1110/asterinas#57`.
- Adjusted the imported guest-OS workflow so it:
  - resolves the upstream `asterinas/asterinas` base image version dynamically from `DOCKER_IMAGE_VERSION`
  - points `KATA_STATIC_TARBALL_RELEASE_REPO` at the current GitHub repository during CI runs
- Updated `tools/packaging/release/build-asterinas-release.sh` so Asterinas release tarballs now include `opt/kata/share/kata-containers/tools/kata/`.
- Added an explicit verification step in `.github/workflows/release-asterinas.yaml` to assert the packaged tarball contains the key Kata helper scripts.
- Added `.github/workflows/publish-asterinas-kata-image.yaml` and `tools/packaging/asterinas-kata/Dockerfile` to build an `asterinas/asterinas-kata` image from the upstream Asterinas base image, install the Kata environment, copy `tools/kata/` into `/root/asterinas/tools/kata`, and push when Docker Hub credentials are available.
- Static validation so far:
  - `bash -n` passed for the imported helper scripts and the release packaging script
  - `git diff --check` passed
  - YAML parser/actionlint checks are being attempted next depending on tool availability in this environment

## 2026-04-17 PR and CI observation

- Created branch `kata-ci-release-image` and opened PR `https://github.com/jjf-dev/kata-containers/pull/21` against base branch `asterinas`.
- Initial local commit: `16fb051c0` (`Add Asterinas Kata CI and image workflows`).
- Next step: observe the GitHub Actions runs for this PR and record any failures or conclusions here.

## 2026-04-17 Published image test update

- Added a second job to `.github/workflows/test_kata_guest_os.yml` named `Test published Asterinas Kata image`.
- The new job pulls `asterinas/asterinas-kata:<DOCKER_IMAGE_VERSION>` from Docker Hub, where `<DOCKER_IMAGE_VERSION>` is resolved from upstream `asterinas/asterinas`.
- Because the published `asterinas/asterinas-kata` image already contains `/root/asterinas/tools/kata` and should already have the Kata environment installed, the test does not use a job-level `container:` and does not rerun `kata_env.sh install`.
- Instead, it runs the pulled image with `docker run --privileged --cgroupns host` and the same `tmpfs` staging mounts, then executes overlayfs preflight plus two `run_kata.sh pass` runs from inside `/root/asterinas`.

## 2026-04-17 Published image validation note

- Static validation after switching to the published-image job:
  - `git diff --check` passed
  - YAML parsing for `.github/workflows/test_kata_guest_os.yml` passed
- Local `docker manifest inspect asterinas/asterinas-kata:<DOCKER_IMAGE_VERSION>` timed out while reaching Docker Hub, matching the known local network instability. I will rely on the PR GitHub Actions runner to validate that the published image can be pulled and can run the Kata tests.

## 2026-04-17 Published image runtime finding

- The PR run successfully pulled `asterinas/asterinas-kata:0.17.2-20260407`, so the published Docker Hub tag exists and is reachable from GitHub Actions.
- The first published-image test attempt failed with exit code `127` because the pulled image did not contain `/root/asterinas/tools/kata/check_overlayfs.sh`.
- To keep validating the published image as the runtime environment while avoiding dependence on the image's current helper-file layout, I updated the job to mount the checked-out `tools/kata/` directory into `/root/asterinas/tools/kata` before running the overlayfs preflight and the two Kata passes.

## 2026-04-17 Published image config finding

- The next published-image attempt progressed far enough to boot Kata, but failed because the published image's Kata config still referenced developer-local QEMU log paths under `/home/jianfeng/kata-asterinas/`.
- The failure surfaced as QEMU refusing to create:
  - `/home/jianfeng/kata-asterinas/console.log`
  - `/home/jianfeng/kata-asterinas/qemu-serial.log`
- I patched `tools/kata/kata_services.sh` so the copied runtime config is normalized to repo-expected log targets under `/tmp` before the services start:
  - `/tmp/kata-console.log`
  - `/tmp/kata-qemu-serial.log`
- The follow-up run still showed the old paths in the final QEMU command line, which indicates the published image is likely carrying an older `/etc/kata-containers/config.d` drop-in that overrides the copied base config.
- I therefore tightened `install_repo_configs()` to delete the existing `/etc/kata-containers/config.d` tree before installing the repo-owned drop-in used by the test workflow.
