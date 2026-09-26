#!/usr/bin/env python3
"""Entrypoint for one Codex job inside a Docker Desktop Linux VM container."""

import argparse
import os
from pathlib import Path
import signal
import socket
import stat
import subprocess
import sys
import uuid


AUTH = Path("/auth")
INPUT = Path("/job/input")
OUTPUT = Path("/job/output")
SCRATCH = Path("/job/scratch")
PROFILE = "afws-isolated"


def check_auth_home() -> None:
    for forbidden_host_path in ("/Users", "/host_mnt", "/run/desktop/mnt/host",
                                "/var/run/docker.sock"):
        if Path(forbidden_host_path).exists():
            raise RuntimeError(f"unexpected host path in Docker job: {forbidden_host_path}")
    for forbidden_config in ("/etc/codex/config.toml", "/etc/codex/managed_config.toml",
                             "/etc/codex/requirements.toml"):
        if Path(forbidden_config).exists():
            raise RuntimeError(f"unexpected system Codex config in image: {forbidden_config}")
    metadata = AUTH.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid():
        raise RuntimeError("Docker auth volume is not owned by the isolated user")
    AUTH.chmod(0o700)
    for name in ("config.toml", "AGENTS.md", "AGENTS.override.md"):
        if (AUTH / name).exists() or (AUTH / name).is_symlink():
            raise RuntimeError(f"Docker auth volume contains forbidden config: {name}")
    skills = AUTH / "skills"
    if (skills.exists() or skills.is_symlink()) and (skills.is_symlink() or any(
        item.name != ".system" or item.is_symlink() or not item.is_dir()
        for item in skills.iterdir()
    )):
        raise RuntimeError("Docker auth volume contains user skills")
    plugins = AUTH / "plugins"
    if (plugins.exists() or plugins.is_symlink()) and (plugins.is_symlink() or any(
        item.name not in {"cache", ".remote-plugin-install-staging"}
        or item.is_symlink() or not item.is_dir()
        for item in plugins.iterdir()
    )):
        raise RuntimeError("Docker auth volume contains user plugins")


def profile_text() -> str:
    return "\n".join([
        'default_permissions = "afws-isolated"',
        'approval_policy = "never"',
        'web_search = "disabled"',
        'allow_login_shell = false',
        '[features]',
        'apps = false',
        'plugins = false',
        'remote_plugin = false',
        'browser_use = false',
        'browser_use_external = false',
        'browser_use_full_cdp_access = false',
        'computer_use = false',
        'in_app_browser = false',
        'multi_agent = false',
        'memories = false',
        'shell_snapshot = false',
        'skill_search = false',
        '[skills]',
        'include_instructions = false',
        '[skills.bundled]',
        'enabled = false',
        f'[permissions.{PROFILE}.filesystem]',
        '":root" = "read"',
        '"/auth" = "deny"',
        '"/job/input" = "read"',
        '"/job/output" = "write"',
        '"/job/scratch" = "write"',
        f'[permissions.{PROFILE}.network]',
        'enabled = false',
        '',
    ])


def probe(profile_name: str) -> None:
    prefix = ["codex", "sandbox", "--profile", profile_name,
              "--permission-profile", PROFILE, "--include-managed-config"]
    guide_relative = Path(os.environ.get("AFWS_GUIDE", ""))
    if (guide_relative.is_absolute() or not guide_relative.parts
            or ".." in guide_relative.parts):
        raise RuntimeError("Docker guide path is unsafe")
    input_probe = INPUT / guide_relative
    output_probe = OUTPUT / ".afws-probe"
    auth_probe = AUTH / ".afws-denied-probe"
    if not input_probe.is_file():
        raise RuntimeError("staged input probe is missing")
    auth_probe.write_text("auth must be denied\n")
    try:
        allowed = subprocess.run(
            prefix + ["/bin/sh", "-c", 'test -r "$1" && : > "$2"',
                      "probe", str(input_probe), str(output_probe)],
            capture_output=True, text=True, timeout=30,
        )
        if allowed.returncode:
            raise RuntimeError("Docker Codex sandbox rejected staged input/output: "
                               + allowed.stderr.strip()[:300])
        for denied_path in (auth_probe,
                            Path("/proc/1/root/auth") / auth_probe.name,
                            Path("/proc/self/root/auth") / auth_probe.name):
            denied = subprocess.run(
                prefix + ["/bin/sh", "-c", 'IFS= read -r line < "$1"',
                          "probe", str(denied_path)],
                capture_output=True, text=True, timeout=30,
            )
            if denied.returncode == 0:
                raise RuntimeError("Docker Codex sandbox allowed reading the auth volume")
        denied_write = subprocess.run(
            prefix + ["/bin/sh", "-c", ': > "$1"',
                      "probe", str(INPUT / ".afws-write-probe")],
            capture_output=True, text=True, timeout=30,
        )
        if denied_write.returncode == 0:
            raise RuntimeError("Docker Codex sandbox allowed modifying input")
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.bind(("localhost", 0))
            listener.listen(1)
            with socket.create_connection(listener.getsockname(), timeout=2):
                connection, _ = listener.accept()
                connection.close()
            network = subprocess.run(
                prefix + ["python3", "-c",
                          "import socket, sys; "
                          "socket.create_connection(('localhost', int(sys.argv[1])), "
                          "timeout=2).close()",
                          str(listener.getsockname()[1])],
                capture_output=True, text=True, timeout=30,
            )
            if network.returncode == 0:
                raise RuntimeError("Docker Codex sandbox allowed a network connection")
    finally:
        auth_probe.unlink(missing_ok=True)
        output_probe.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--probe", action="store_true", help="check sandbox without model use")
    args = parser.parse_args()
    check_auth_home()
    profile_name = f"afws-job-{uuid.uuid4().hex}"
    profile_file = AUTH / f"{profile_name}.config.toml"
    try:
        with profile_file.open("x") as stream:
            stream.write(profile_text())
        profile_file.chmod(0o600)
        probe(profile_name)
        if args.probe:
            print("sandbox-ok")
            return 0
        auth = subprocess.run(["codex", "login", "status"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              timeout=30)
        if auth.returncode:
            raise RuntimeError("Docker Codex login is missing; run: afws-isolate docker login")
        prompt = sys.stdin.read(64 * 1024)
        if not prompt.strip() or sys.stdin.read(1):
            raise RuntimeError("Docker job prompt is empty or too large")
        command = ["codex", "exec", "--profile", profile_name,
                   "--strict-config", "--ignore-rules", "--ephemeral",
                   "--skip-git-repo-check", "--json", "-C", "/job", prompt]
        return subprocess.call(command, stdin=subprocess.DEVNULL)
    finally:
        profile_file.unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"afws-isolate docker: {error}", file=sys.stderr)
        sys.exit(1)
