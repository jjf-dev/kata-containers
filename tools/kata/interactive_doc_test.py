#!/usr/bin/env python3

from __future__ import annotations

import argparse
import os
import pathlib
import re
import shlex
import subprocess
import sys
import uuid

import pexpect


OUTER_PROMPT = "PEXPECT_OUTER> "
GUEST_PROMPT = "PEXPECT_GUEST> "
DEFAULT_KATA_IMAGE = "asterinas/kata:0.17.2-20260407"
DEFAULT_ASTERINAS_IMAGE = "asterinas/asterinas:0.17.2-20260407"
DEFAULT_WORKLOAD_IMAGE = "docker.io/alpine:latest"
REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
ANSI_ESCAPE_RE = re.compile(r"\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")


class ScenarioError(RuntimeError):
    pass


def strip_terminal_control_sequences(text: str) -> str:
    return ANSI_ESCAPE_RE.sub("", text).replace("\r", "")


def clean_command_output(command: str, output: str) -> str:
    cleaned_lines: list[str] = []

    for raw_line in strip_terminal_control_sequences(output).splitlines():
        line = raw_line.strip()
        if not line:
            continue

        if line.startswith(OUTER_PROMPT.strip()):
            line = line[len(OUTER_PROMPT.strip()) :].strip()
        elif line.startswith(GUEST_PROMPT.strip()):
            line = line[len(GUEST_PROMPT.strip()) :].strip()

        if not line:
            continue

        if line == command:
            continue
        if line == "'":
            continue
        if line == "status=$?":
            continue
        if line.startswith("printf '__DOC_TEST_EXIT__"):
            continue
        if line.startswith("__DOC_TEST_EXIT__"):
            continue

        cleaned_lines.append(line)

    return "\n".join(cleaned_lines).strip()


def outer_docker_env_args() -> list[str]:
    args = ["-e", "TERM=dumb"]
    passthrough_vars = (
        "KATA_FORCE_APT",
        "KATA_PAYLOAD_IMAGE",
        "KATA_STATIC_TARBALL_RELEASE_REPO",
        "KATA_STATIC_TARBALL_SHA256",
        "KATA_STATIC_TARBALL_SHA256_URL",
        "KATA_STATIC_TARBALL_URL",
        "KATA_VERSION",
        "NERDCTL_VERSION",
    )

    for env_name in passthrough_vars:
        env_value = os.environ.get(env_name)
        if env_value:
            args.extend(["-e", f"{env_name}={env_value}"])

    return args


class DockerShell:
    def __init__(self, name: str, docker_args: list[str], transcript_path: pathlib.Path) -> None:
        self.name = name
        self.docker_args = docker_args
        self.transcript_path = transcript_path
        self.child: pexpect.spawn | None = None
        self.log_handle = None
        self.prompt = OUTER_PROMPT

    def start(self) -> "DockerShell":
        self.transcript_path.parent.mkdir(parents=True, exist_ok=True)
        self.log_handle = self.transcript_path.open("w", encoding="utf-8")
        subprocess.run(
            ["docker", "rm", "-f", self.name],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        self.child = pexpect.spawn(
            "docker",
            self.docker_args,
            encoding="utf-8",
            codec_errors="replace",
            echo=False,
            timeout=60,
        )
        self.child.logfile_read = self.log_handle
        self.child.setwinsize(60, 200)
        self.child.expect(r"[#$] ", timeout=120)
        self.set_prompt(OUTER_PROMPT)
        return self

    def close(self) -> None:
        if self.child is not None:
            self.child.close(force=True)
            self.child = None
        subprocess.run(
            ["docker", "rm", "-f", self.name],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if self.log_handle is not None:
            self.log_handle.close()
            self.log_handle = None

    def set_prompt(self, prompt: str) -> None:
        assert self.child is not None
        self.child.sendline(f"export PS1={shlex.quote(prompt)}")
        self.child.expect(re.escape(prompt), timeout=30)
        self.prompt = prompt

    def run(self, command: str, timeout: int = 300, check: bool = True) -> str:
        assert self.child is not None
        marker = f"__DOC_TEST_EXIT__{uuid.uuid4().hex}__:"
        self.child.sendline(command)
        self.child.sendline("status=$?")
        self.child.sendline(f"printf '{marker}%s\\n' \"$status\"")
        self.child.expect(re.compile(re.escape(marker) + r"(\d+)\r?\n"), timeout=timeout)
        output = clean_command_output(command, self.child.before)
        status = int(self.child.match.group(1))
        self.child.expect(re.escape(self.prompt), timeout=60)
        if check and status != 0:
            raise ScenarioError(f"Command failed with exit code {status}: {command}\n{output}")
        return output

    def enter_guest(self, command: str, timeout: int = 900) -> None:
        assert self.child is not None
        self.child.sendline(command)
        self.child.expect(r"[#$] ", timeout=timeout)
        self.set_prompt(GUEST_PROMPT)

    def exit_guest(self) -> None:
        assert self.child is not None
        self.child.sendline("exit")
        self.child.expect(re.escape(OUTER_PROMPT), timeout=120)
        self.prompt = OUTER_PROMPT


def require_paths(paths: list[pathlib.Path]) -> None:
    missing_paths = [str(path) for path in paths if not path.exists()]
    if missing_paths:
        raise ScenarioError(f"Missing required path(s): {', '.join(missing_paths)}")


def run_guest_workload(shell: DockerShell, workload_image: str, host_proc_version: str, container_name: str = "foo") -> tuple[str, str]:
    shell.run(f"nerdctl rm -f {shlex.quote(container_name)} >/dev/null 2>&1 || true", check=False)
    shell.enter_guest(
        " ".join(
            [
                "nerdctl",
                "run",
                "--cgroup-manager",
                "cgroupfs",
                "--net",
                "none",
                "--runtime",
                "io.containerd.kata.v2",
                "--name",
                shlex.quote(container_name),
                "-it",
                shlex.quote(workload_image),
            ]
        ),
        timeout=900,
    )
    guest_proc_version = shell.run("cat /proc/version")
    alpine_release = shell.run("cat /etc/alpine-release")
    shell.exit_guest()
    shell.run(f"nerdctl rm -f {shlex.quote(container_name)}")

    if guest_proc_version.strip() == host_proc_version.strip():
        raise ScenarioError("Guest /proc/version unexpectedly matches the outer container /proc/version")
    if not alpine_release.strip():
        raise ScenarioError("Expected a non-empty /etc/alpine-release inside the guest workload")

    return guest_proc_version.strip(), alpine_release.strip()


def run_end_user_scenario(args: argparse.Namespace) -> pathlib.Path:
    outer_name = f"kata-doc-end-user-{uuid.uuid4().hex[:12]}"
    transcript_path = args.log_dir / "end-user.transcript.log"
    shell = DockerShell(
        outer_name,
        [
            "run",
            "--rm",
            "-it",
            "--name",
            outer_name,
            "--cgroupns",
            "host",
            "--privileged",
            "--device",
            "/dev/kvm",
            "--device",
            "/dev/vhost-net",
            "--device",
            "/dev/vhost-vsock",
            "--device",
            "/dev/vsock",
            "--tmpfs",
            "/tmp:exec,mode=1777,size=8g",
            "--tmpfs",
            "/var/lib/containerd:exec,mode=755,size=8g",
            *outer_docker_env_args(),
            args.kata_image,
        ],
        transcript_path,
    ).start()

    try:
        print(f"[end-user] using outer image: {args.kata_image}")
        host_proc_version = shell.run("cat /proc/version")
        shell.run("cd /root/asterinas")
        shell.run("./tools/kata/kata_services.sh start", timeout=300)
        status_output = shell.run("./tools/kata/kata_services.sh status")
        if "Kata services are running." not in status_output:
            raise ScenarioError(f"Unexpected service status output:\n{status_output}")
        guest_proc_version, alpine_release = run_guest_workload(shell, args.workload_image, host_proc_version)
        print(f"[end-user] guest /proc/version: {guest_proc_version}")
        print(f"[end-user] alpine release: {alpine_release}")
        shell.run("./tools/kata/kata_services.sh stop", timeout=300)
        return transcript_path
    finally:
        shell.close()


def run_kernel_developer_scenario(args: argparse.Namespace) -> pathlib.Path:
    require_paths([args.repo_dir, args.asterinas_dir])
    outer_name = f"kata-doc-kernel-dev-{uuid.uuid4().hex[:12]}"
    transcript_path = args.log_dir / "kernel-developer.transcript.log"
    shell = DockerShell(
        outer_name,
        [
            "run",
            "--rm",
            "-it",
            "--name",
            outer_name,
            "--cgroupns",
            "host",
            "--privileged",
            "--device",
            "/dev/kvm",
            "--device",
            "/dev/vhost-net",
            "--device",
            "/dev/vhost-vsock",
            "--device",
            "/dev/vsock",
            "--tmpfs",
            "/tmp:exec,mode=1777,size=8g",
            "--tmpfs",
            "/var/lib/containerd:exec,mode=755,size=8g",
            *outer_docker_env_args(),
            "-v",
            f"{args.asterinas_dir.resolve()}:/root/asterinas",
            "-v",
            f"{args.repo_dir.resolve()}:/root/kata-containers:ro",
            "-w",
            "/root/kata-containers",
            args.asterinas_image,
        ],
        transcript_path,
    ).start()

    try:
        print(f"[kernel-developer] using outer image: {args.asterinas_image}")
        print(f"[kernel-developer] mounted Asterinas tree: {args.asterinas_dir}")
        host_proc_version = shell.run("cat /proc/version")
        shell.run("test -d /root/kata-containers/tools/kata")
        shell.run("./tools/kata/kata_env.sh install", timeout=3600)
        shell.run("./tools/kata/kata_services.sh start", timeout=300)
        status_output = shell.run("./tools/kata/kata_services.sh status")
        if "Kata services are running." not in status_output:
            raise ScenarioError(f"Unexpected service status output:\n{status_output}")
        packaged_guest_proc_version, packaged_alpine_release = run_guest_workload(
            shell,
            args.workload_image,
            host_proc_version,
            "foo",
        )
        print(f"[kernel-developer] packaged guest /proc/version: {packaged_guest_proc_version}")
        print(f"[kernel-developer] packaged alpine release: {packaged_alpine_release}")
        shell.run("cd /root/asterinas && make kernel BOOT_METHOD=qemu-direct", timeout=7200)
        shell.run("test -f /root/asterinas/target/osdk/aster-kernel-osdk-bin.qemu_elf")
        shell.run(
            "sed -i 's#^kernel = \".*\"#kernel = \"/root/asterinas/target/osdk/aster-kernel-osdk-bin.qemu_elf\"#' "
            "/etc/kata-containers/configuration.toml"
        )
        shell.run(
            "grep -F 'kernel = \"/root/asterinas/target/osdk/aster-kernel-osdk-bin.qemu_elf\"' "
            "/etc/kata-containers/configuration.toml"
        )
        local_guest_proc_version, local_alpine_release = run_guest_workload(
            shell,
            args.workload_image,
            host_proc_version,
            "foo",
        )
        print(f"[kernel-developer] local-kernel guest /proc/version: {local_guest_proc_version}")
        print(f"[kernel-developer] local-kernel alpine release: {local_alpine_release}")
        shell.run("./tools/kata/kata_services.sh stop", timeout=300)
        return transcript_path
    finally:
        shell.close()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Replay the documented Asterinas Kata flows with pexpect")
    parser.add_argument(
        "--scenario",
        choices=["end-user", "kernel-developer", "all"],
        default=os.environ.get("KATA_DOC_TEST_SCENARIO", "all"),
    )
    parser.add_argument(
        "--kata-image",
        default=os.environ.get("KATA_DOC_TEST_KATA_IMAGE", DEFAULT_KATA_IMAGE),
    )
    parser.add_argument(
        "--asterinas-image",
        default=os.environ.get("KATA_DOC_TEST_ASTERINAS_IMAGE", DEFAULT_ASTERINAS_IMAGE),
    )
    parser.add_argument(
        "--workload-image",
        default=os.environ.get("KATA_DOC_TEST_WORKLOAD_IMAGE", DEFAULT_WORKLOAD_IMAGE),
    )
    parser.add_argument(
        "--repo-dir",
        type=pathlib.Path,
        default=pathlib.Path(os.environ.get("KATA_DOC_TEST_REPO_DIR", str(REPO_ROOT))),
    )
    parser.add_argument(
        "--asterinas-dir",
        type=pathlib.Path,
        default=pathlib.Path(os.environ.get("KATA_DOC_TEST_ASTERINAS_DIR", str(pathlib.Path.home() / "asterinas"))),
    )
    parser.add_argument(
        "--log-dir",
        type=pathlib.Path,
        default=pathlib.Path(os.environ.get("KATA_DOC_TEST_LOG_DIR", "/tmp/asterinas-kata-doc-tests")),
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    args.log_dir.mkdir(parents=True, exist_ok=True)
    transcripts: list[pathlib.Path] = []

    try:
        if args.scenario in {"end-user", "all"}:
            transcripts.append(run_end_user_scenario(args))
        if args.scenario in {"kernel-developer", "all"}:
            transcripts.append(run_kernel_developer_scenario(args))
    except Exception as error:
        print(f"interactive_doc_test failed: {error}", file=sys.stderr)
        if transcripts:
            print("available transcript(s):", file=sys.stderr)
            for transcript in transcripts:
                print(f"  - {transcript}", file=sys.stderr)
        else:
            print(f"transcript directory: {args.log_dir}", file=sys.stderr)
        return 1

    print("interactive_doc_test passed")
    for transcript in transcripts:
        print(f"transcript: {transcript}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
