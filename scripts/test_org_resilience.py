#!/usr/bin/env python3
"""Failure-path integration tests for the AFWS organization ledger."""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
ORG = ROOT / "bin" / "afws-org"
HOST = "test-host"
REMOTE = "/srv/resilience"


class OrganizationResilienceTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="afws-org-test-")
        self.root = Path(self.temporary.name)
        self.state = self.root / "state"
        self.sessions = self.state / "sessions"
        self.sessions.mkdir(parents=True)
        self.delivery_log = self.root / "delivery.log"
        self.message = self.root / "message"
        self.lock = self.root / "lock"
        self.message.write_text(
            "#!/bin/sh\n"
            "printf '%s\\n' \"$*\" >> \"$AFWS_TEST_DELIVERY_LOG\"\n"
            "exit \"${AFWS_TEST_MESSAGE_EXIT:-0}\"\n"
        )
        self.lock.write_text("#!/bin/sh\nexit \"${AFWS_TEST_LOCK_EXIT:-0}\"\n")
        self.run_log = self.root / "run.log"
        self.run = self.root / "run"
        self.run.write_text(
            "#!/bin/sh\n"
            "printf '%s\\n' \"$*\" >> \"$AFWS_TEST_RUN_LOG\"\n"
            "case \"$*\" in\n"
            "  *'--is-inside-work-tree'*) printf '%s\\n' \"${AFWS_TEST_IS_GIT:-true}\"; exit 0 ;;\n"
            "  *'status --porcelain'*) printf '%s' \"${AFWS_TEST_DIRTY:-}\"; exit 0 ;;\n"
            "esac\n"
            "exit \"${AFWS_TEST_RUN_EXIT:-0}\"\n"
        )
        self.run.chmod(0o755)
        self.message.chmod(0o755)
        self.lock.chmod(0o755)
        for name in ("coord", "lead", "worker", "worker2", "outsider"):
            self.write_record(name)
        self.run_as("coord", "init")
        self.run_as("coord", "add-team", "alpha", "lead")
        self.run_as("lead", "add-member", "alpha", "worker")
        self.run_as("lead", "add-member", "alpha", "worker2")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_record(self, name: str, *, instance: str | None = None,
                     version: str = "2", host: str = HOST, remote: str = REMOTE,
                     agent: str = "codex") -> None:
        instance = instance or f"{name}-instance"
        token = f"{instance}-token"
        token_hash = hashlib.sha256(token.encode()).hexdigest()
        (self.sessions / f"{name}.conf").write_text(
            f"session_name={name}\ninstance_id={instance}\ntoken_hash={token_hash}\n"
            f"afws_version={version}\nagent={agent}\nkind=interactive\npid={os.getpid()}\n"
            f"ssh_host={host}\nremote_dir={remote}\nstarted_epoch={int(time.time())}\n"
        )

    def environment(self, name: str, **extra: str) -> dict[str, str]:
        instance = self.record(name)["instance_id"]
        values = os.environ.copy()
        values.update({
            "AFWS_STATE_DIR": str(self.state), "AFWS_SSH_HOST": HOST,
            "AFWS_REMOTE_DIR": REMOTE, "AFWS_SESSION_NAME": name,
            "AFWS_INSTANCE_ID": instance, "AFWS_SESSION_TOKEN": f"{instance}-token",
            "AFWS_ORG_MESSAGE_COMMAND": str(self.message),
            "AFWS_ORG_LOCK_COMMAND": str(self.lock),
            "AFWS_ORG_RUN_COMMAND": str(self.run),
            "AFWS_TEST_RUN_LOG": str(self.run_log),
            "AFWS_TEST_DELIVERY_LOG": str(self.delivery_log),
        })
        values.update(extra)
        return values

    def record(self, name: str) -> dict[str, str]:
        return dict(line.split("=", 1) for line in
                    (self.sessions / f"{name}.conf").read_text().splitlines() if "=" in line)

    def run_as(self, name: str, *arguments: str, ok: bool | None = True,
               **extra: str) -> subprocess.CompletedProcess[str]:
        result = subprocess.run([str(ORG), *arguments], env=self.environment(name, **extra),
                                text=True, capture_output=True)
        if ok is True and result.returncode:
            self.fail(f"{' '.join(arguments)} failed: {result.stderr}")
        if ok is False and not result.returncode:
            self.fail(f"{' '.join(arguments)} unexpectedly succeeded: {result.stdout}")
        return result

    def db(self) -> sqlite3.Connection:
        target = next((self.state / "organizations").glob("*.sqlite3"))
        connection = sqlite3.connect(target)
        connection.row_factory = sqlite3.Row
        return connection

    def assign(self, actor: str, member: str, title: str, scope: str | None = None) -> str:
        arguments = ["assign", member, title]
        if scope:
            arguments += ["--scope", scope]
        output = self.run_as(actor, *arguments).stdout
        return output.split("assignment_id=", 1)[1].strip()

    def assignment(self, assignment_id: str) -> sqlite3.Row:
        with self.db() as database:
            return database.execute("SELECT * FROM assignments WHERE assignment_id=?",
                                    (assignment_id,)).fetchone()

    def claim_token(self, assignment_id: str) -> str:
        with self.db() as database:
            payload = database.execute(
                "SELECT payload FROM outbox WHERE assignment_id=? AND kind='assignment'",
                (assignment_id,),
            ).fetchone()[0]
        return next(line.split(": ", 1)[1] for line in payload.splitlines()
                    if line.startswith("claim_token: "))

    def test_rbac_claim_replay_and_state_machine(self) -> None:
        self.run_as("worker", "add-team", "illegal", "worker", ok=False)
        assignment = self.assign("lead", "worker", "owned work", "src/worker")
        self.run_as("lead", "dispatch", assignment)
        self.assertEqual(self.assignment(assignment)["state"], "delivered")
        token = self.claim_token(assignment)
        self.run_as("worker2", "claim", assignment, token, ok=False)
        self.run_as("worker", "claim", assignment, token)
        self.run_as("worker", "claim", assignment, token, ok=False)
        self.run_as("worker", "start", assignment)
        def complete(result: str) -> int:
            return self.run_as("worker", "complete", assignment, result, ok=None).returncode
        with ThreadPoolExecutor(max_workers=2) as pool:
            completions = list(pool.map(complete, ("done", "duplicate")))
        self.assertEqual(sum(code == 0 for code in completions), 1)
        self.run_as("worker", "complete", assignment, "again", ok=False)

    def test_delivery_retry_timeout_cancel_and_orphan_recovery(self) -> None:
        failed = self.assign("lead", "worker", "retry delivery")
        self.run_as("lead", "dispatch", failed, ok=True, AFWS_TEST_MESSAGE_EXIT="7")
        self.assertEqual(self.assignment(failed)["state"], "delivery_failed")
        self.run_as("lead", "retry", failed)
        self.run_as("lead", "dispatch", failed, "--force")
        self.assertEqual(self.assignment(failed)["state"], "delivered")
        with self.db() as database:
            database.execute("UPDATE assignments SET ack_deadline=0 WHERE assignment_id=?", (failed,))
        self.run_as("coord", "reconcile")
        self.assertEqual(self.assignment(failed)["state"], "ack_timeout")
        self.run_as("lead", "cancel", failed)

        running = self.assign("lead", "worker2", "orphan work")
        self.run_as("lead", "dispatch", running)
        self.run_as("worker2", "claim", running, self.claim_token(running))
        self.run_as("worker2", "start", running)
        stale = self.record("worker2")
        stale["pid"] = "99999999"
        stale["started_epoch"] = "0"
        (self.sessions / "worker2.conf").write_text(
            "".join(f"{key}={value}\n" for key, value in stale.items()))
        self.run_as("coord", "reconcile")
        self.assertEqual(self.assignment(running)["state"], "orphaned")

        cancel = self.assign("lead", "worker", "cancel work")
        self.run_as("lead", "dispatch", cancel)
        self.run_as("worker", "claim", cancel, self.claim_token(cancel))
        self.run_as("worker", "start", cancel)
        self.run_as("lead", "cancel", cancel)
        self.assertEqual(self.assignment(cancel)["state"], "cancel_requested")
        with self.db() as database:
            kinds = {row[0] for row in database.execute(
                "SELECT kind FROM outbox WHERE assignment_id=?", (cancel,))}
        self.assertEqual(kinds, {"assignment", "cancellation"})

    def test_scope_is_transactional_and_write_guard_is_strict(self) -> None:
        first = self.assign("lead", "worker", "scope one", "src/api")
        self.run_as("lead", "assign", "worker2", "scope conflict", "--scope", "src", ok=False)
        with self.db() as database:
            self.assertEqual(database.execute("SELECT count(*) FROM tasks").fetchone()[0], 1)
        self.run_as("worker", "check-write", first, "src/api/file.py")
        self.run_as("worker", "check-write", first, "src/other.py", ok=False)

        self.run_as("lead", "cancel", first)
        def competing(member: str) -> int:
            return self.run_as("lead", "assign", member, f"race {member}",
                               "--scope", "shared", ok=None).returncode
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(competing, ("worker", "worker2")))
        self.assertEqual(sorted(results), [0, 2])

    def test_name_reuse_cross_project_and_mixed_version(self) -> None:
        abandoned = self.assign("lead", "worker", "old identity work")
        self.write_record("worker", instance="worker-new")
        self.run_as("worker", "heartbeat")
        with self.db() as database:
            old = database.execute("SELECT retired_at FROM agents WHERE instance_id='worker-instance'").fetchone()[0]
            new = database.execute("SELECT retired_at FROM agents WHERE instance_id='worker-new'").fetchone()[0]
        self.assertIsNotNone(old)
        self.assertIsNone(new)
        self.assertEqual(self.assignment(abandoned)["state"], "orphaned")

        self.write_record("coord", instance="coord-new")
        self.run_as("coord", "recover-coordinator")
        with self.db() as database:
            self.assertEqual(database.execute(
                "SELECT value FROM meta WHERE key='coordinator_instance'").fetchone()[0], "coord-new")

        self.write_record("outsider", host="different-host")
        self.run_as("coord", "add-member", "alpha", "outsider", ok=False)
        self.write_record("outsider", version="1")
        self.run_as("lead", "add-member", "alpha", "outsider", ok=False)
        with self.db() as database:
            database.execute("UPDATE agents SET afws_version='1' WHERE instance_id='worker-new'")
        self.run_as("coord", "validate", ok=False)

    def test_claude_delivery_inbox_hook_context_and_wait_states(self) -> None:
        self.write_record("claude-worker", agent="claude")
        self.run_as("lead", "add-member", "alpha", "claude-worker")
        assignment = self.assign("lead", "claude-worker", "review the release", "docs")
        self.run_as("lead", "dispatch", assignment)
        self.assertEqual(self.assignment(assignment)["state"], "delivered")
        self.assertFalse(self.delivery_log.exists(), "Claude dispatch used the Codex adapter")

        inbox = self.run_as("claude-worker", "inbox").stdout
        token = self.claim_token(assignment)
        self.assertIn("[AFWS organization assignment]", inbox)
        self.assertIn(token, inbox)
        self.run_as("claude-worker", "claim", assignment, token)
        self.run_as("claude-worker", "start", assignment)
        context = self.run_as("claude-worker", "hook-context").stdout
        self.assertIn(assignment, context)
        self.assertIn("still running", context)
        self.run_as("claude-worker", "wait", assignment, "awaiting CI")
        self.assertEqual(self.assignment(assignment)["state"], "waiting")
        self.run_as("lead", "cancel", assignment)
        self.run_as("claude-worker", "set-state", "claude-worker", "cancelled")

        second = self.assign("lead", "claude-worker", "investigate failure")
        self.run_as("lead", "dispatch", second)
        self.run_as("claude-worker", "claim", second, self.claim_token(second))
        self.run_as("claude-worker", "start", second)
        self.run_as("claude-worker", "block", second, "needs credentials")
        self.assertEqual(self.assignment(second)["state"], "blocked")
        view = json.loads(self.run_as("coord", "show", "--json").stdout)
        claude_member = next(member for member in view["teams"][0]["members"]
                             if member["session"] == "claude-worker")
        self.assertEqual(claude_member["agent"], "claude")

    def test_additive_schema_migration_and_newer_schema_rejection(self) -> None:
        legacy_state = self.root / "legacy-state"
        organizations = legacy_state / "organizations"
        organizations.mkdir(parents=True)
        digest = hashlib.sha256(f"{HOST}\n{REMOTE}".encode()).hexdigest()
        target = organizations / f"{digest}.sqlite3"
        with sqlite3.connect(target) as database:
            database.executescript("""
              CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
              INSERT INTO meta VALUES('schema_version','2');
              CREATE TABLE teams(name TEXT PRIMARY KEY, lead_instance TEXT NOT NULL);
              CREATE TABLE agents(
                instance_id TEXT PRIMARY KEY, session_name TEXT NOT NULL,
                ssh_host TEXT NOT NULL, remote_dir TEXT NOT NULL,
                afws_version TEXT NOT NULL, token_hash TEXT NOT NULL,
                registered_at INTEGER NOT NULL, heartbeat_at INTEGER NOT NULL,
                retired_at INTEGER);
              CREATE TABLE outbox(
                outbox_id TEXT PRIMARY KEY, assignment_id TEXT NOT NULL, recipient TEXT NOT NULL,
                payload TEXT NOT NULL, state TEXT NOT NULL, attempts INTEGER NOT NULL,
                next_attempt INTEGER NOT NULL, last_error TEXT, created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL);
            """)
        environment = self.environment("coord")
        environment["AFWS_STATE_DIR"] = str(legacy_state)
        migrated = subprocess.run([str(ORG), "version"], env=environment, text=True, capture_output=True)
        self.assertEqual(migrated.returncode, 0, migrated.stderr)
        self.assertTrue(target.with_suffix(".v2.bak").is_file())
        with sqlite3.connect(target) as database:
            self.assertIn("archived_at", {row[1] for row in database.execute("PRAGMA table_info(teams)")})
            self.assertIn("kind", {row[1] for row in database.execute("PRAGMA table_info(outbox)")})
            self.assertIn("agent_type", {row[1] for row in database.execute("PRAGMA table_info(agents)")})
            assignment_columns = {row[1] for row in database.execute("PRAGMA table_info(assignments)")}
            self.assertIn("done_when", assignment_columns)
            self.assertIn("evidence", assignment_columns)
            self.assertIn("wants_worktree", assignment_columns)
            self.assertIn("worktree_path", assignment_columns)
            self.assertIn("shared_paths", assignment_columns)
            self.assertEqual(database.execute(
                "SELECT value FROM meta WHERE key='schema_version'").fetchone()[0], "6")
            database.execute("UPDATE meta SET value='999' WHERE key='schema_version'")
        rejected = subprocess.run([str(ORG), "version"], env=environment, text=True, capture_output=True)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("newer", rejected.stderr)

    def test_acceptance_condition_gates_completion(self) -> None:
        output = self.run_as("lead", "assign", "worker", "harden the guard",
                             "--scope", "lib", "--done-when",
                             "scripts/test.sh passes and afws-org validate is clean").stdout
        assignment = output.split("assignment_id=", 1)[1].strip()
        row = self.assignment(assignment)
        self.assertEqual(row["done_when"], "scripts/test.sh passes and afws-org validate is clean")
        with self.db() as database:
            payload = database.execute("SELECT payload FROM outbox WHERE assignment_id=?",
                                       (assignment,)).fetchone()[0]
        self.assertIn("done_when: scripts/test.sh passes", payload)

        self.run_as("lead", "dispatch", assignment)
        self.run_as("worker", "claim", assignment, self.claim_token(assignment))
        self.run_as("worker", "start", assignment)

        # Closing it on the assignee's own say-so is refused, and the refusal
        # leaves the assignment running rather than half-closed.
        refused = self.run_as("worker", "complete", assignment, "all done", ok=False)
        self.assertEqual(refused.returncode, 4)
        self.assertIn("acceptance condition", refused.stderr)
        self.assertEqual(self.assignment(assignment)["state"], "running")

        # Evidence without a result is not a close either.
        self.run_as("worker", "complete", assignment, "--evidence", "ran the suite", ok=False)
        self.assertEqual(self.assignment(assignment)["state"], "running")

        self.run_as("worker", "complete", assignment, "guard added",
                    "--evidence", "scripts/test.sh -> 0 failures; afws-org validate -> clean")
        closed = self.assignment(assignment)
        self.assertEqual(closed["state"], "completed")
        self.assertIn("afws-org validate -> clean", closed["evidence"])

        # An assignment that states no condition keeps the old behaviour.
        plain = self.assign("lead", "worker2", "no stated condition")
        self.run_as("lead", "dispatch", plain)
        self.run_as("worker2", "claim", plain, self.claim_token(plain))
        self.run_as("worker2", "start", plain)
        self.run_as("worker2", "complete", plain, "finished")
        self.assertEqual(self.assignment(plain)["state"], "completed")

    def test_guard_refuses_out_of_scope_writes_and_fails_open(self) -> None:
        # No assignment at all: the guard must not interfere with ordinary work.
        self.run_as("worker", "guard", "anything/at/all.py")

        assignment = self.assign("lead", "worker", "scoped work", scope="lib")
        self.run_as("worker", "guard", "lib/afws-common.zsh", "lib/nested/file.py")

        refused = self.run_as("worker", "guard", "bin/afws-run", ok=False)
        self.assertEqual(refused.returncode, 4)
        self.assertIn("bin/afws-run", refused.stderr)
        self.assertIn("afws-org wait", refused.stderr)

        # A sibling that merely shares a prefix is outside the scope.
        self.run_as("worker", "guard", "library/thing.py", ok=False)
        # Traversal is rejected by path normalization, not by the prefix test.
        self.run_as("worker", "guard", "lib/../bin/afws-run", ok=False)
        self.run_as("worker", "guard", "/etc/passwd", ok=False)

        # A scopeless assignment does not constrain anything.
        unscoped = self.assign("lead", "worker2", "unscoped work")
        self.assertIsNotNone(unscoped)
        self.run_as("worker2", "guard", "bin/afws-run")

        # The guard is read-only: it records no event and moves no heartbeat.
        with self.db() as database:
            before = database.execute("SELECT count(*) FROM events").fetchone()[0]
        self.run_as("worker", "guard", "lib/afws-common.zsh")
        with self.db() as database:
            self.assertEqual(database.execute("SELECT count(*) FROM events").fetchone()[0], before)

    def calls(self) -> str:
        return self.run_log.read_text() if self.run_log.exists() else ""

    def test_worktree_isolation_is_opt_in_and_reclaimed(self) -> None:
        # Sharing only means anything when there is something to share into.
        self.run_as("lead", "assign", "worker", "no worktree", "--share", "data", ok=False)

        output = self.run_as("lead", "assign", "worker", "isolated work", "--scope", "lib",
                             "--worktree", "--share", "data", "--share", ".venv").stdout
        assignment = output.split("assignment_id=", 1)[1].strip()
        row = self.assignment(assignment)
        self.assertEqual(row["wants_worktree"], 1)
        self.assertEqual(json.loads(row["shared_paths"]), ["data", ".venv"])
        self.assertIsNone(row["worktree_path"], "the checkout waits for start, not assign")
        with self.db() as database:
            payload = database.execute("SELECT payload FROM outbox WHERE assignment_id=?",
                                       (assignment,)).fetchone()[0]
        self.assertIn("shared and therefore NOT isolated: data, .venv", payload)

        self.run_as("lead", "dispatch", assignment)
        self.run_as("worker", "claim", assignment, self.claim_token(assignment))

        # A project with uncommitted changes would lose them behind a worktree
        # that starts from HEAD, so the ledger refuses rather than guessing.
        refused = self.run_as("worker", "start", assignment, ok=False, AFWS_TEST_DIRTY=" M lib/x.py")
        self.assertIn("uncommitted changes", refused.stderr)
        self.assertNotIn("worktree add", self.calls())
        self.assertEqual(self.assignment(assignment)["state"], "acknowledged")

        # Neither does it try to isolate something that is not a Git work tree.
        refused = self.run_as("worker", "start", assignment, ok=False, AFWS_TEST_IS_GIT="false")
        self.assertIn("Git work tree", refused.stderr)

        started = self.run_as("worker", "start", assignment).stdout
        row = self.assignment(assignment)
        expected = f"{REMOTE}.afws-worktrees/{assignment}"
        self.assertEqual(row["worktree_path"], expected)
        self.assertEqual(row["worktree_branch"], f"afws/{assignment[:8]}")
        self.assertIn(expected, started)
        calls = self.calls()
        self.assertIn(f"worktree add {expected} -b afws/{assignment[:8]} HEAD", calls)
        self.assertIn("ln -sfn", calls)
        self.assertIn(f"{REMOTE}/data", calls)
        # The checkout sits beside the project, not inside it: a worktree under
        # the project would be swept up by every build, search and scope check.
        self.assertFalse(expected.startswith(REMOTE + "/"))

        view = self.run_as("coord", "show").stdout
        self.assertIn(expected, view)
        self.assertIn("shared, not isolated: data, .venv", view)

        self.run_as("worker", "complete", assignment, "done")
        row = self.assignment(assignment)
        self.assertIsNotNone(row["worktree_removed_at"])
        self.assertIn(f"worktree remove --force {expected}", self.calls())
        # The branch is the work, so reclaiming the checkout must not touch it.
        self.assertNotIn("branch -D", self.calls())

    def test_archive_a_team_with_history_and_recover_delivery_lease(self) -> None:
        assignment = self.assign("lead", "worker", "historical task")
        original_task = self.assignment(assignment)["task_id"]
        reassigned_output = self.run_as("lead", "reassign", assignment, "worker2").stdout
        reassigned = reassigned_output.split(" -> ", 1)[1].split(" ", 1)[0]
        self.assertEqual(self.assignment(assignment)["state"], "cancelled")
        self.assertEqual(self.assignment(reassigned)["task_id"], original_task)
        with self.db() as database:
            self.assertEqual(database.execute("SELECT count(*) FROM tasks").fetchone()[0], 1)
        self.run_as("coord", "remove-team", "alpha", "--cancel-active")
        view = json.loads(self.run_as("coord", "show", "--json").stdout)
        self.assertEqual(view["teams"], [])
        with self.db() as database:
            self.assertEqual(database.execute("SELECT state FROM assignments WHERE assignment_id=?",
                                              (reassigned,)).fetchone()[0], "cancelled")
            database.execute("UPDATE outbox SET state='sending',updated_at=0 WHERE assignment_id=?",
                             (assignment,))
        self.run_as("coord", "reconcile")
        with self.db() as database:
            self.assertEqual(database.execute("SELECT state FROM outbox WHERE assignment_id=?",
                                              (assignment,)).fetchone()[0], "failed")


if __name__ == "__main__":
    unittest.main(verbosity=2)
