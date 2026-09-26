#!/usr/bin/env python3
"""Exercise bundle isolation and result handoff without making model calls."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parent.parent
COMMAND = ROOT / "bin" / "afws-isolate"
FAKE_CODEX = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
import tomllib
import time

args = sys.argv[1:]
home = Path(os.environ["CODEX_HOME"])
if args[:2] == ["login", "status"]:
    sys.exit(0 if (home / "auth.ok").exists() else 1)
if args and args[0] == "app-server":
    requests = [json.loads(sys.stdin.readline()) for _ in range(4)]
    if [item["method"] for item in requests] != [
        "initialize", "initialized", "config/read", "configRequirements/read"
    ] or not requests[2]["params"]["includeLayers"]:
        sys.exit(13)
    config = {"sandbox_mode": None, "sandbox_workspace_write": None,
              "default_permissions": None, "approval_policy": None,
              "permissions": None}
    layer = {"name": {"type": "system"}, "config": {}}
    requirements = None
    if (home / "legacy-sandbox").exists():
        config["sandbox_mode"] = "danger-full-access"
        layer["config"]["sandbox_mode"] = "danger-full-access"
    if (home / "profile-collision").exists():
        config["permissions"] = {"afws-isolated": {"filesystem": {":root": "read"}}}
        layer["config"]["permissions"] = config["permissions"]
    if (home / "unsupported-layer").exists():
        layer["config"]["hooks"] = {"enabled": True}
    if (home / "allowlist-deny").exists():
        requirements = {"allowedPermissionProfiles": {":workspace": True}}
    if (home / "approval-deny").exists():
        requirements = {"allowedApprovalPolicies": ["onRequest"]}
    if (home / "compatible-managed").exists():
        layer["config"]["model"] = "gpt-6-sol"
        requirements = {"allowedPermissionProfiles": {"afws-isolated": True},
                        "defaultPermissions": "afws-isolated",
                        "allowedApprovalPolicies": ["never"]}
    responses = [
        {"id": 0, "result": {"codexHome": str(home)}},
        {"id": 1, "result": {"config": config, "layers": [layer]}},
        {"id": 2, "result": {"requirements": requirements}},
    ]
    if (home / "config-error").exists():
        responses[1] = {"id": 1, "error": {"message": "config unavailable"}}
    for response in responses:
        print(json.dumps(response), flush=True)
    sys.exit(0)
if "sandbox" in args:
    if "--permission-profile" not in args:
        sys.exit(3)
    profile_name = args[args.index("--profile") + 1]
    profile = tomllib.loads((home / (profile_name + ".config.toml")).read_text())
    rules = profile["permissions"]["afws-isolated"]
    if profile["skills"]["bundled"]["enabled"] or profile["skills"]["include_instructions"]:
        sys.exit(10)
    if any(profile["features"][key] for key in ("apps", "plugins", "remote_plugin")):
        sys.exit(11)
    if rules["filesystem"].get(":root") != "deny" or rules["network"]["enabled"]:
        sys.exit(6)
    if rules["filesystem"].get(str(home)) != "deny":
        sys.exit(7)
    if 'IFS= read -r line < "$1"' in args:
        sys.exit(0 if (home / "leak").exists() else 1)
    if ': > "$1"' in args:
        sys.exit(1)
    if args[-1] == "--version":
        staged_binary = Path(args[-2])
        sys.exit(0 if staged_binary.is_file() and staged_binary.parent.name == "runtime" else 9)
    target = Path(args[-1])
    target.touch()
    sys.exit(0)
if args and args[0] == "exec":
    if "--ignore-user-config" in args or "--profile" not in args:
        sys.exit(12)
    (home / "child.pid").write_text(str(os.getpid()))
    if (home / "sleep").exists():
        time.sleep(10)
    if "SSH_AUTH_SOCK" in os.environ or "AFWS_CONTROL_PATH" in os.environ:
        sys.exit(8)
    workspace = Path(args[args.index("-C") + 1])
    guide = next((workspace / "input").rglob("instructions.md")).read_text()
    source = next((workspace / "input").rglob("data.txt")).read_text()
    if "uppercase" not in guide:
        sys.exit(4)
    (workspace / "output" / "result.txt").write_text(source.upper())
    if (home / "large-output").exists():
        (workspace / "output" / "large.bin").write_bytes(b"x" * (2 * 1024 * 1024))
    if (home / "many-output").exists():
        for number in range(5):
            (workspace / "output" / f"extra-{number}.txt").write_text("x")
    if (home / "linked-output").exists():
        (workspace / "output" / "linked.txt").symlink_to(home / "auth.ok")
    if (home / "control-output").exists():
        (workspace / "output" / "bad\nname.txt").write_text("x")
    if not (home / "no-handoff").exists():
        (workspace / "output" / "HANDOFF.md").write_text("Processed one file.\\n")
    print('{"type":"turn.completed"}')
    sys.exit(0)
sys.exit(5)
'''
FAKE_DOCKER = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
if args[:2] == ["context", "inspect"]:
    print("unix:///tmp/fake-docker.sock")
    sys.exit(0)
if args[:1] == ["info"]:
    if os.environ.get("AFWS_FAKE_DOCKER_INFO_FAIL"):
        sys.exit(1)
    print("Docker Desktop")
    sys.exit(0)
if args[:2] == ["image", "inspect"]:
    print("sha256:" + "a" * 64)
    sys.exit(0)
if args[:2] == ["volume", "inspect"]:
    sys.exit(0)
if args[:2] == ["rm", "--force"]:
    sys.exit(0)
if args[:1] == ["run"]:
    if args[-3:] == ["codex", "login", "status"]:
        sys.exit(0)
    if "/opt/afws/child.py" not in args:
        sys.exit(3)
    mounts = [args[index + 1] for index, value in enumerate(args[:-1]) if value == "--mount"]
    input_mount = next((item for item in mounts if "target=/job/input" in item), "")
    output_mount = next((item for item in mounts if "target=/job/output" in item), "")
    if ("readonly" not in input_mount or not output_mount or "readonly" in output_mount
            or "--read-only" not in args or "--cap-drop=ALL" not in args
            or any(".codex" in item or "docker.sock" in item for item in mounts)):
        sys.exit(4)
    if "--probe" in args:
        if args[args.index("--network") + 1] != "bridge":
            sys.exit(7)
        print("sandbox-ok")
        sys.exit(0)
    prompt = sys.stdin.read()
    if "Read the Markdown guide" not in prompt or any(
        "SSH_AUTH_SOCK" in item for item in args
    ):
        sys.exit(5)
    input_dir = Path(input_mount.split("source=", 1)[1].split(",", 1)[0])
    output_dir = Path(output_mount.split("source=", 1)[1].split(",", 1)[0])
    (output_dir / "result.txt").write_text((input_dir / "data.txt").read_text().upper())
    (output_dir / "HANDOFF.md").write_text("Ran in Docker.\n")
    print('{"type":"turn.completed"}')
    sys.exit(0)
sys.exit(6)
'''


class IsolateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="afws-isolate-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.auth = self.root / "isolated-home"
        self.auth.mkdir(mode=0o700)
        (self.auth / "auth.ok").touch()
        (self.auth / "skills" / ".system").mkdir(parents=True)
        (self.auth / "plugins" / "cache").mkdir(parents=True)
        self.fake = self.root / "fake-codex"
        self.fake.write_text(FAKE_CODEX.replace("#!/usr/bin/env python3", f"#!{sys.executable}", 1))
        self.fake.chmod(0o755)
        docker_dir = self.root / "fake-bin"
        docker_dir.mkdir()
        self.fake_docker = docker_dir / "docker"
        self.fake_docker.write_text(FAKE_DOCKER.replace("#!/usr/bin/env python3",
                                                        f"#!{sys.executable}", 1))
        self.fake_docker.chmod(0o755)
        self.data = self.root / "data.txt"
        self.data.write_text("hello\n")
        self.guide = self.root / "instructions.md"
        self.guide.write_text("Run the uppercase script on data.txt.\n")
        self.env = os.environ.copy()
        self.env.update({
            "AFWS_ISOLATE_CODEX_HOME": str(self.auth),
            "AFWS_ISOLATE_CODEX_BIN": str(self.fake),
        })

    def invoke(self, *extra, backend="host"):
        backend_args = [] if backend is None else ["--backend", backend]
        return subprocess.run(
            [str(COMMAND), "run", *backend_args, "--guide", str(self.guide),
             "--input", str(self.guide), "--input", str(self.data),
             "--result", str(self.root / "result"), *extra],
            env=self.env, capture_output=True, text=True,
        )

    def evaluate(self, verdict, evidence, *extra):
        return subprocess.run(
            [str(COMMAND), "evaluate", "--result", str(self.root / "result"),
             "--verdict", verdict, "--evidence", evidence, *extra],
            env=self.env, capture_output=True, text=True,
        )

    def test_result_and_handoff(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        output = self.root / "result"
        self.assertEqual((output / "artifacts" / "result.txt").read_text(), "HELLO\n")
        self.assertEqual(self.data.read_text(), "hello\n")
        self.assertTrue((output / "artifacts" / "HANDOFF.md").exists())
        self.assertEqual(json.loads((output / "result.json").read_text())["status"], "child_completed")
        manifest = json.loads((output / "input-manifest.json").read_text())
        self.assertEqual({item["path"] for item in manifest}, {"instructions.md", "data.txt"})
        self.assertEqual(list(self.auth.glob("afws-job-*.config.toml")), [])
        self.assertEqual(json.loads((output / "result.json").read_text())
                         ["config_guard"]["status"], "passed")

    def test_compatible_managed_policy_runs(self):
        (self.auth / "compatible-managed").touch()
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        guard = json.loads((self.root / "result" / "result.json").read_text())["config_guard"]
        self.assertTrue(guard["managed_requirements"])

    def test_parent_evaluation_records_verdict_and_rejects_repeat(self):
        self.assertEqual(self.invoke().returncode, 0)
        result = self.evaluate("match", "Original data has one row; expected uppercase HELLO.")
        self.assertEqual(result.returncode, 0, result.stderr)
        evaluation = json.loads((self.root / "result" / "result.json").read_text())
        self.assertEqual(evaluation["parent_evaluation"]["verdict"], "match")
        self.assertIn("HELLO", evaluation["parent_evaluation"]["evidence"])
        self.assertNotEqual(self.evaluate("mismatch", "changed my mind").returncode, 0)

    def test_docker_backend_mounts_only_staged_files(self):
        self.env["PATH"] = f"{self.fake_docker.parent}:{self.env['PATH']}"
        self.env["SSH_AUTH_SOCK"] = "/tmp/should-not-reach-child"
        result = self.invoke(backend="docker")
        self.assertEqual(result.returncode, 0, result.stderr)
        output = self.root / "result"
        self.assertEqual((output / "artifacts" / "result.txt").read_text(), "HELLO\n")
        report = json.loads((output / "result.json").read_text())
        self.assertEqual(report["backend"], "docker-desktop-vm")
        self.assertEqual(report["status"], "child_completed")

    def test_docker_is_default_and_never_falls_back_to_host(self):
        self.env["PATH"] = f"{self.fake_docker.parent}:{self.env['PATH']}"
        success = self.invoke(backend=None)
        self.assertEqual(success.returncode, 0, success.stderr)
        report = json.loads((self.root / "result" / "result.json").read_text())
        self.assertEqual(report["backend"], "docker-desktop-vm")
        shutil.rmtree(self.root / "result")
        self.env["AFWS_FAKE_DOCKER_INFO_FAIL"] = "1"
        blocked = self.invoke(backend=None)
        self.assertNotEqual(blocked.returncode, 0)
        self.assertIn("Docker Desktop VM", blocked.stderr)
        self.assertFalse((self.root / "result").exists())

    def test_docker_doctor_uses_sandbox_probe(self):
        self.env["PATH"] = f"{self.fake_docker.parent}:{self.env['PATH']}"
        result = subprocess.run([str(COMMAND), "docker", "doctor"],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "passed")

    def test_parent_evaluation_detects_changed_artifact(self):
        self.assertEqual(self.invoke().returncode, 0)
        (self.root / "result" / "artifacts" / "result.txt").write_text("tampered")
        result = self.evaluate("match", "Expected uppercase HELLO.")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("changed", result.stderr)
        evaluation = json.loads((self.root / "result" / "result.json").read_text())
        self.assertEqual(evaluation["parent_evaluation"], "pending")

    def test_failed_child_can_be_marked_undetermined(self):
        (self.auth / "no-handoff").touch()
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertNotEqual(self.evaluate("match", "No handoff exists.").returncode, 0)
        result = self.evaluate("undetermined", "No handoff exists; correctness cannot be assessed.")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_legacy_sandbox_and_profile_collision_fail_before_child(self):
        for flag in ("legacy-sandbox", "profile-collision", "unsupported-layer"):
            with self.subTest(flag=flag):
                (self.auth / flag).touch()
                result = self.invoke("--result", str(self.root / f"result-{flag}"))
                self.assertNotEqual(result.returncode, 0)
                report = json.loads((self.root / f"result-{flag}" / "result.json").read_text())
                self.assertEqual(report["status"], "setup_failed")
                self.assertEqual(report["config_guard"]["status"], "failed")
                self.assertFalse((self.root / f"result-{flag}" / "events.jsonl").exists())
                self.assertEqual(list(self.auth.glob("afws-job-*.config.toml")), [])
                (self.auth / flag).unlink()

    def test_managed_denials_fail_before_child(self):
        for flag in ("allowlist-deny", "approval-deny", "config-error"):
            with self.subTest(flag=flag):
                (self.auth / flag).touch()
                result = self.invoke("--result", str(self.root / f"result-{flag}"))
                self.assertNotEqual(result.returncode, 0)
                report = json.loads((self.root / f"result-{flag}" / "result.json").read_text())
                self.assertEqual(report["status"], "setup_failed")
                self.assertFalse((self.root / f"result-{flag}" / "events.jsonl").exists())
                (self.auth / flag).unlink()

    def test_rejects_symlink_and_agent_config(self):
        link = self.root / "linked.txt"
        link.symlink_to(self.data)
        result = self.invoke("--input", str(link))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symbolic links", result.stderr)
        hidden = self.root / "bundle"
        (hidden / ".codex").mkdir(parents=True)
        (hidden / ".codex" / "config.toml").write_text("secret")
        result = self.invoke("--input", str(hidden), "--result", str(self.root / "result-hidden"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("reserved", result.stderr)
        mixed = self.root / "mixed"
        (mixed / ".CoDeX").mkdir(parents=True)
        result = self.invoke("--input", str(mixed), "--result", str(self.root / "result-mixed"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("reserved", result.stderr)
        control = self.root / "bad\nname.txt"
        control.write_text("data")
        result = self.invoke("--input", str(control), "--result", str(self.root / "result-control"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("control character", result.stderr)

    def test_rejects_non_system_skill_in_isolated_home(self):
        (self.auth / "skills" / "custom").mkdir()
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("non-system skills", result.stderr)

    def test_rejects_user_plugin_in_isolated_home(self):
        (self.auth / "plugins" / "custom").mkdir()
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("user plugins", result.stderr)

    def test_directory_keeps_relative_layout(self):
        bundle = self.root / "bundle"
        bundle.mkdir()
        (bundle / "instructions.md").write_text("Run the uppercase script.\n")
        nested = bundle / "source"
        nested.mkdir()
        (nested / "data.txt").write_text("nested\n")
        result = subprocess.run(
            [str(COMMAND), "run", "--backend", "host", "--guide", str(bundle / "instructions.md"),
             "--input", str(bundle), "--result", str(self.root / "result")],
            env=self.env, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "result" / "artifacts" / "result.txt").read_text(), "NESTED\n")
        manifest = json.loads((self.root / "result" / "input-manifest.json").read_text())
        self.assertEqual({item["path"] for item in manifest},
                         {"bundle/instructions.md", "bundle/source/data.txt"})

    def test_fails_closed_if_sandbox_probe_reads_outside(self):
        (self.auth / "leak").touch()
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        report = json.loads((self.root / "result" / "result.json").read_text())
        self.assertEqual(report["status"], "setup_failed")
        self.assertIn("outside", report["error"])
        self.assertFalse((self.root / "result" / "events.jsonl").exists())
        self.assertEqual(list(self.auth.glob("afws-job-*.config.toml")), [])

    def test_timeout_returns_failure_and_handoff_notice(self):
        (self.auth / "sleep").touch()
        result = self.invoke("--timeout", "1")
        self.assertNotEqual(result.returncode, 0)
        output = self.root / "result"
        report = json.loads((output / "result.json").read_text())
        self.assertEqual(report["child_exit_code"], 124)
        self.assertEqual(report["status"], "child_failed")
        self.assertTrue((output / "artifacts" / "HANDOFF.md").exists())

    def test_zero_exit_without_handoff_is_failure(self):
        (self.auth / "no-handoff").touch()
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        output = self.root / "result"
        report = json.loads((output / "result.json").read_text())
        self.assertEqual(report["status"], "child_failed")
        self.assertEqual(report["child_exit_code"], 0)
        self.assertIn("did not produce", report["error"])
        self.assertEqual({item["path"] for item in report["artifacts"]},
                         {"result.txt", "HANDOFF.md"})

    def test_output_limit_fails_without_partial_artifacts(self):
        (self.auth / "large-output").touch()
        result = self.invoke("--max-output-mb", "1")
        self.assertNotEqual(result.returncode, 0)
        output = self.root / "result"
        report = json.loads((output / "result.json").read_text())
        self.assertEqual(report["status"], "artifact_validation_failed")
        self.assertIn("size limit", report["error"])
        self.assertFalse((output / "artifacts").exists())

    def test_child_output_link_is_rejected(self):
        (self.auth / "linked-output").touch()
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        report = json.loads((self.root / "result" / "result.json").read_text())
        self.assertEqual(report["status"], "artifact_validation_failed")
        self.assertFalse((self.root / "result" / "artifacts").exists())

    def test_child_output_control_name_is_rejected(self):
        (self.auth / "control-output").touch()
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        report = json.loads((self.root / "result" / "result.json").read_text())
        self.assertEqual(report["status"], "artifact_validation_failed")
        self.assertIn("control character", report["error"])

    def test_input_limit_is_total_across_paths(self):
        first = self.root / "first.bin"
        second = self.root / "second.bin"
        first.write_bytes(b"a" * 600_000)
        second.write_bytes(b"b" * 600_000)
        result = self.invoke("--input", str(first), "--input", str(second),
                             "--max-input-mb", "1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("size limit", result.stderr)
        self.assertEqual(json.loads((self.root / "result" / "result.json").read_text())["status"],
                         "setup_failed")

    def test_input_and_output_entry_limits(self):
        result = self.invoke("--max-entries", "1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("entry limit", result.stderr)
        (self.auth / "many-output").touch()
        result = self.invoke("--max-entries", "3", "--result",
                             str(self.root / "output-result"))
        self.assertNotEqual(result.returncode, 0)
        report = json.loads((self.root / "output-result" / "result.json").read_text())
        self.assertEqual(report["status"], "artifact_validation_failed")
        self.assertIn("entry limit", report["error"])

    def test_sigterm_stops_child_and_cleans_profile(self):
        (self.auth / "sleep").touch()
        process = subprocess.Popen(
            [str(COMMAND), "run", "--backend", "host", "--guide", str(self.guide),
             "--input", str(self.guide), "--input", str(self.data),
             "--result", str(self.root / "result")],
            env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True,
        )
        try:
            deadline = time.monotonic() + 10
            while not (self.auth / "child.pid").exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertTrue((self.auth / "child.pid").exists())
            child_pid = int((self.auth / "child.pid").read_text())
            process.terminate()
            process.communicate(timeout=10)
            self.assertEqual(process.returncode, 143)
            report = json.loads((self.root / "result" / "result.json").read_text())
            self.assertEqual(report["status"], "interrupted")
            self.assertEqual(list(self.auth.glob("afws-job-*.config.toml")), [])
            with self.assertRaises(ProcessLookupError):
                os.kill(child_pid, 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()


if __name__ == "__main__":
    unittest.main()
