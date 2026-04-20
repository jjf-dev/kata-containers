# Asterinas Kata CI Progress

## 2026-04-20 Workflow naming cleanup

- Renamed the test workflow file from `.github/workflows/test_kata_guest_os.yml` to `.github/workflows/test-asterinas-kata.yml` and updated its top-level workflow name to `Test | Asterinas Kata`.
- Renamed the release workflow file from `.github/workflows/release-asterinas.yaml` to `.github/workflows/release-asterinas-kata-bundle.yml` so the file name matches the Asterinas-specific release payload it builds.
- Renamed the publish workflow file from `.github/workflows/publish-asterinas-kata-image.yaml` to `.github/workflows/publish-asterinas-kata-image.yml` to align the extension with the other workflow files.
- Normalized the user-facing job names so the GitHub Actions UI now shows:
  - `Resolve upstream Asterinas image`
  - `Build and optionally push Asterinas Kata image`
  - `Build Asterinas kernel artifact`
  - `Build and publish Asterinas Kata bundle`
- Normalized the step names across all three workflows to the same Title Case style so the GitHub Actions UI reads consistently at both job and step level.
- Updated repository documentation links and workflow-path references to match the renamed files.
- Static validation after the naming cleanup:
  - all workflow YAML files parsed successfully
  - no stale references to the old workflow file names remain outside this historical log entry

## 2026-04-20 Asterinas branch push triggers

- Updated `.github/workflows/test-asterinas-kata.yml` so pushes to the `asterinas` branch trigger the workflow in addition to `main`.
- Updated `.github/workflows/publish-asterinas-kata-image.yml` so pushes to the `asterinas` branch trigger the workflow in addition to `main`.
- Left `.github/workflows/release-asterinas-kata-bundle.yml` unchanged because it already triggers on every `push`, which already includes the `asterinas` branch.

## 2026-04-20 Published image job workspace fix

- The first post-rewrite PR run failed in `Test published Asterinas Kata image` during `Check OverlayFS Staging Prerequisites`.
- Root cause: after converting the published-image test to a job-level `container:`, the workflow still expected the helper scripts to be available under `/root/asterinas/tools/kata`, but `actions/checkout` places the repo under the GitHub Actions workspace instead.
- Fix: removed the extra `container.volumes` mount and the `/root/asterinas` working-directory override so the published-image job now runs the repo-owned helper scripts from the checked-out workspace, just like the source-image job.

## 2026-04-20 Docker image repository rename

- Updated the publish workflow defaults so the image is now pushed to `asterinas/kata` instead of `asterinas/asterinas-kata`.
- Updated the published-image test job so it pulls `asterinas/kata:<DOCKER_IMAGE_VERSION>`.
- Updated repository docs so the Docker image name is consistently documented as `asterinas/kata`.

## 2026-04-20 Dual guest-kernel test matrix

- Updated `.github/workflows/test-asterinas-kata.yml` so both test jobs now run as a matrix over `KATA_GUEST_KERNEL=linux` and `KATA_GUEST_KERNEL=asterinas`.
- Both guest-kernel variants continue to use the same smoke-test helpers, container image, workload command, and output expectation, so the CI now checks that Linux and Asterinas guests produce the same expected workload result.

## 2026-04-20 Unified test job matrix

- Collapsed the previous `test-kata-from-source` and `test-published-kata-image` jobs into a single `test-kata` matrix job.
- The new matrix spans both image variants (`source`, `published`) and both guest kernels (`linux`, `asterinas`), so the workflow still covers the same four combinations with less duplicated YAML.

## 2026-04-20 In-workflow published-image dependency

- The first unified-matrix attempt showed that using `asterinas/kata:<DOCKER_IMAGE_VERSION>` directly as a job container races with image publication, because job containers are pulled before any steps run.
- To keep job-level `container:` semantics while guaranteeing ordering, I added a `build-published-kata-image` job into `.github/workflows/test-asterinas-kata.yml` and made the matrix test job depend on it with `needs`.
- I also wired the `asterinas` guest-kernel matrix entries to export `KATA_ASTERINAS_KERNEL_PATH=/root/asterinas/target/osdk/aster-kernel-osdk-bin.qemu_elf` so `kata_env.sh install` can overlay the image’s own Asterinas kernel before the smoke test runs.

## 2026-04-17 Initial findings

- Read `requirements.md` and confirmed three requested deliverables:
  1. Import the CI plus all referenced scripts from `StevenJiang1110/asterinas` PR `#57` into this repo.
  2. Update `release-asterinas-kata-bundle` so the imported scripts are also included in the release output.
  3. Add a new workflow that builds an `asterinas/kata` image from the upstream `asterinas/asterinas` base image, runs `kata_env.sh install`, copies all imported scripts into `/root/asterinas/tools/kata`, and pushes the result to Docker Hub.
- Found the current repo already contains `.github/workflows/release-asterinas-kata-bundle.yml`.
- Found Git remote `origin` points to `git@github.com:jjf-dev/kata-containers.git`.
- Next step: inspect PR `StevenJiang1110/asterinas#57` with `gh` and map the required files into this repository.

## 2026-04-17 Source import findings

- Inspected `StevenJiang1110/asterinas#57` with `gh`.
- The PR contributes one workflow and the full reusable helper set under `tools/kata/`:
  - `.github/workflows/test-asterinas-kata.yml`
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
- Next step: wire those files into this repo, then teach `release-asterinas-kata-bundle` to package the same helper directory into the Asterinas release tarball.

## 2026-04-17 Upstream version findings

- Queried `asterinas/asterinas` with `gh` to avoid stale tag assumptions.
- Latest upstream GitHub release is `v0.17.1` published on `2026-03-12`.
- I am now checking the upstream Docker publish workflow so the new `asterinas/kata` image can follow the same versioning convention.

## 2026-04-17 Implementation update

- Imported `.github/workflows/test-asterinas-kata.yml` and the full `tools/kata/` helper directory from `StevenJiang1110/asterinas#57`.
- Adjusted the imported guest-OS workflow so it:
  - resolves the upstream `asterinas/asterinas` base image version dynamically from `DOCKER_IMAGE_VERSION`
  - points `KATA_STATIC_TARBALL_RELEASE_REPO` at the current GitHub repository during CI runs
- Updated `tools/packaging/release/build-asterinas-release.sh` so Asterinas release tarballs now include `opt/kata/share/kata-containers/tools/kata/`.
- Added an explicit verification step in `.github/workflows/release-asterinas-kata-bundle.yml` to assert the packaged tarball contains the key Kata helper scripts.
- Added `.github/workflows/publish-asterinas-kata-image.yml` and `tools/packaging/asterinas-kata/Dockerfile` to build an `asterinas/kata` image from the upstream Asterinas base image, install the Kata environment, copy `tools/kata/` into `/root/asterinas/tools/kata`, and push when Docker Hub credentials are available.
- Static validation so far:
  - `bash -n` passed for the imported helper scripts and the release packaging script
  - `git diff --check` passed
  - YAML parser/actionlint checks are being attempted next depending on tool availability in this environment

## 2026-04-17 PR and CI observation

- Created branch `kata-ci-release-image` and opened PR `https://github.com/jjf-dev/kata-containers/pull/21` against base branch `asterinas`.
- Initial local commit: `16fb051c0` (`Add Asterinas Kata CI and image workflows`).
- Next step: observe the GitHub Actions runs for this PR and record any failures or conclusions here.

## 2026-04-17 Published image test update

- Added a second job to `.github/workflows/test-asterinas-kata.yml` named `Test published Asterinas Kata image`.
- The new job pulls `asterinas/kata:<DOCKER_IMAGE_VERSION>` from Docker Hub, where `<DOCKER_IMAGE_VERSION>` is resolved from upstream `asterinas/asterinas`.
- Because the published `asterinas/kata` image already contains `/root/asterinas/tools/kata` and should already have the Kata environment installed, the test does not use a job-level `container:` and does not rerun `kata_env.sh install`.
- Instead, it runs the pulled image with `docker run --privileged --cgroupns host` and the same `tmpfs` staging mounts, then executes overlayfs preflight plus two `run_kata.sh pass` runs from inside `/root/asterinas`.

## 2026-04-17 Published image validation note

- Static validation after switching to the published-image job:
  - `git diff --check` passed
  - YAML parsing for `.github/workflows/test-asterinas-kata.yml` passed
- Local `docker manifest inspect asterinas/kata:<DOCKER_IMAGE_VERSION>` timed out while reaching Docker Hub, matching the known local network instability. I will rely on the PR GitHub Actions runner to validate that the published image can be pulled and can run the Kata tests.

## 2026-04-17 Published image runtime finding

- The PR run successfully pulled `asterinas/kata:0.17.2-20260407`, so the published Docker Hub tag exists and is reachable from GitHub Actions.
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
- Even after that cleanup, the published Docker Hub image still behaved like an older runtime/config payload. To keep using the published image while making the test exercise the current Kata release bits, I updated the published-image job to run `bash tools/kata/kata_env.sh install` inside the pulled image before the two Kata passes.
