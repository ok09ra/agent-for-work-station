#!/usr/bin/env python3
"""Crash-tolerant organization and task orchestration for AFWS."""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import subprocess
import sys
import time
import uuid
from pathlib import Path
from pathlib import PurePosixPath
from typing import NoReturn

SCHEMA_VERSION = 5
AFWS_VERSION = "2"
TERMINAL_STATES = {"completed", "failed", "cancelled"}
ACTIVE_STATES = {
    "assigned", "delivered", "acknowledged", "running", "waiting",
    "blocked", "cancel_requested", "orphaned", "delivery_failed", "ack_timeout",
}
TRANSITIONS = {
    "assigned": {"delivered", "delivery_failed", "cancel_requested", "cancelled"},
    "delivery_failed": {"assigned", "cancel_requested", "cancelled"},
    "delivered": {"acknowledged", "ack_timeout", "cancel_requested", "cancelled"},
    "ack_timeout": {"assigned", "cancel_requested", "cancelled"},
    "acknowledged": {"running", "waiting", "blocked", "failed", "cancel_requested"},
    "running": {"waiting", "blocked", "completed", "failed", "cancel_requested", "orphaned"},
    "waiting": {"running", "blocked", "failed", "cancel_requested", "orphaned"},
    "blocked": {"running", "failed", "cancel_requested", "orphaned"},
    "orphaned": {"assigned", "failed", "cancelled", "cancel_requested"},
    "cancel_requested": {"cancelled", "failed"},
    "completed": set(), "failed": set(), "cancelled": set(),
}


def die(message: str, code: int = 2) -> NoReturn:
    print(f"afws-org: {message}", file=sys.stderr)
    raise SystemExit(code)


def timestamp() -> int:
    return int(time.time())


def validate_name(value: str, label: str) -> str:
    if not value or value.startswith("-") or any(not (c.isalnum() or c in "._-") for c in value):
        die(f"invalid {label}: {value}")
    return value


def validate_text(value: str, label: str, limit: int = 1000) -> str:
    if not value or len(value) > limit or any(ord(c) < 32 for c in value):
        die(f"{label} must be one line of 1 to {limit} characters")
    return value


def normalize_scope(value: str) -> str:
    validate_text(value, "write scope")
    raw = value[:-3] if value.endswith("/**") else value
    raw = raw.rstrip("/")
    path = PurePosixPath(raw)
    if not raw or path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        die("write scope must be a normalized project-relative path")
    return path.as_posix()


def normalize_project_path(value: str) -> str:
    validate_text(value, "project path")
    path = PurePosixPath(value.rstrip("/"))
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        die(f"project path is not normalized: {value}")
    return path.as_posix()


def read_record(state_dir: Path, session_name: str) -> dict[str, str]:
    result: dict[str, str] = {}
    target = state_dir / "sessions" / f"{session_name}.conf"
    if not target.is_file():
        return result
    for line in target.read_text(errors="replace").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            result[key] = value
    return result


def project_context(require_actor: bool = True) -> tuple[str, str, Path, dict[str, str]]:
    host = os.environ.get("AFWS_SSH_HOST", "")
    remote = os.environ.get("AFWS_REMOTE_DIR", "").rstrip("/")
    state_dir = Path(os.environ.get("AFWS_STATE_DIR", str(Path.home() / ".afws")))
    if not host or not remote.startswith("/") or remote == "/":
        die("run this inside a work-station session")
    if any(ord(c) < 32 for c in host + remote):
        die("project scope contains control characters")
    name = os.environ.get("AFWS_SESSION_NAME", "")
    instance_id = os.environ.get("AFWS_INSTANCE_ID", "")
    token = os.environ.get("AFWS_SESSION_TOKEN", "")
    record = read_record(state_dir, name) if name else {}
    token_hash = hashlib.sha256(token.encode()).hexdigest() if token else ""
    valid = bool(
        name and instance_id and token
        and record.get("instance_id") == instance_id
        and hmac.compare_digest(record.get("token_hash", ""), token_hash)
    )
    if require_actor and not valid:
        die("this session has no valid v2 identity; restart it with the updated launcher")
    actor = {"name": name, "instance_id": instance_id, "token": token, "valid": "1" if valid else "0", **record}
    return host, remote, state_dir, actor


def database_path(state_dir: Path, host: str, remote: str) -> Path:
    digest = hashlib.sha256(f"{host}\n{remote}".encode()).hexdigest()
    root = state_dir / "organizations"
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(root, 0o700)
    except OSError:
        pass
    return root / f"{digest}.sqlite3"


def open_database(state_dir: Path, host: str, remote: str) -> sqlite3.Connection:
    target = database_path(state_dir, host, remote)
    db = sqlite3.connect(target, timeout=20)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=FULL")
    db.execute("PRAGMA foreign_keys=ON")
    db.execute("PRAGMA busy_timeout=20000")
    db.executescript("""
      CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS agents(
        instance_id TEXT PRIMARY KEY, session_name TEXT NOT NULL, token_hash TEXT NOT NULL,
        ssh_host TEXT NOT NULL, remote_dir TEXT NOT NULL, afws_version TEXT NOT NULL,
        agent_type TEXT NOT NULL DEFAULT 'codex',
        team TEXT, role TEXT NOT NULL DEFAULT 'worker', registered_at INTEGER NOT NULL,
        heartbeat_at INTEGER NOT NULL, retired_at INTEGER);
      CREATE UNIQUE INDEX IF NOT EXISTS active_session_name
        ON agents(session_name) WHERE retired_at IS NULL;
      CREATE TABLE IF NOT EXISTS teams(
        name TEXT PRIMARY KEY, lead_instance TEXT NOT NULL REFERENCES agents(instance_id),
        archived_at INTEGER);
      CREATE TABLE IF NOT EXISTS tasks(
        task_id TEXT PRIMARY KEY, title TEXT NOT NULL, team TEXT NOT NULL REFERENCES teams(name),
        state TEXT NOT NULL, revision INTEGER NOT NULL, created_by TEXT NOT NULL,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS assignments(
        assignment_id TEXT PRIMARY KEY, task_id TEXT NOT NULL REFERENCES tasks(task_id),
        assignee_instance TEXT NOT NULL REFERENCES agents(instance_id), state TEXT NOT NULL,
        revision INTEGER NOT NULL, write_scope TEXT, required_locks TEXT NOT NULL,
        claim_hash TEXT, ack_deadline INTEGER, heartbeat_at INTEGER, result TEXT,
        done_when TEXT, evidence TEXT,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS outbox(
        outbox_id TEXT PRIMARY KEY, assignment_id TEXT NOT NULL REFERENCES assignments(assignment_id),
        recipient TEXT NOT NULL, payload TEXT NOT NULL, kind TEXT NOT NULL DEFAULT 'assignment', state TEXT NOT NULL,
        attempts INTEGER NOT NULL, next_attempt INTEGER NOT NULL, last_error TEXT,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS events(
        event_id INTEGER PRIMARY KEY AUTOINCREMENT, occurred_at INTEGER NOT NULL,
        actor_instance TEXT, kind TEXT NOT NULL, entity_id TEXT, details TEXT NOT NULL);
    """)
    existing = db.execute("SELECT value FROM meta WHERE key='schema_version'").fetchone()
    if existing and int(existing[0]) > SCHEMA_VERSION:
        die("organization database was created by a newer afws-org")
    if existing and int(existing[0]) < SCHEMA_VERSION:
        backup_path = target.with_suffix(f".v{existing[0]}.bak")
        if not backup_path.exists():
            with sqlite3.connect(backup_path) as backup:
                db.backup(backup)
            os.chmod(backup_path, 0o600)
    # Migrations are additive so an interrupted upgrade is safe to run again.
    team_columns = {row[1] for row in db.execute("PRAGMA table_info(teams)")}
    outbox_columns = {row[1] for row in db.execute("PRAGMA table_info(outbox)")}
    agent_columns = {row[1] for row in db.execute("PRAGMA table_info(agents)")}
    assignment_columns = {row[1] for row in db.execute("PRAGMA table_info(assignments)")}
    with db:
        if "archived_at" not in team_columns:
            db.execute("ALTER TABLE teams ADD COLUMN archived_at INTEGER")
        if "kind" not in outbox_columns:
            db.execute("ALTER TABLE outbox ADD COLUMN kind TEXT NOT NULL DEFAULT 'assignment'")
        if "agent_type" not in agent_columns:
            db.execute("ALTER TABLE agents ADD COLUMN agent_type TEXT NOT NULL DEFAULT 'codex'")
        if "done_when" not in assignment_columns:
            db.execute("ALTER TABLE assignments ADD COLUMN done_when TEXT")
        if "evidence" not in assignment_columns:
            db.execute("ALTER TABLE assignments ADD COLUMN evidence TEXT")
        for key, value in (("schema_version", str(SCHEMA_VERSION)), ("ssh_host", host), ("remote_dir", remote)):
            db.execute("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, value))
    os.chmod(target, 0o600)
    return db


def audit(db: sqlite3.Connection, actor: str | None, kind: str, entity: str | None, details: dict) -> None:
    db.execute(
        "INSERT INTO events(occurred_at,actor_instance,kind,entity_id,details) VALUES(?,?,?,?,?)",
        (timestamp(), actor, kind, entity, json.dumps(details, ensure_ascii=False, sort_keys=True)),
    )


def coordinator_id(db: sqlite3.Connection) -> str | None:
    row = db.execute("SELECT value FROM meta WHERE key='coordinator_instance'").fetchone()
    return row[0] if row else None


def retire_instance(db: sqlite3.Connection, instance_id: str, actor_id: str, reason: str) -> None:
    stamp = timestamp()
    db.execute("UPDATE agents SET retired_at=? WHERE instance_id=?", (stamp, instance_id))
    marks = ",".join("?" for _ in ACTIVE_STATES)
    rows = db.execute(
        f"SELECT * FROM assignments WHERE assignee_instance=? AND state IN ({marks})",
        (instance_id, *ACTIVE_STATES),
    ).fetchall()
    for assignment in rows:
        change_state(db, assignment, "orphaned", actor_id, reason, force=True)
        release_assignment_locks(assignment)


def register_actor(db: sqlite3.Connection, actor: dict[str, str], host: str, remote: str) -> None:
    if actor.get("ssh_host") != host or actor.get("remote_dir", "").rstrip("/") != remote:
        die("session belongs to another project scope")
    stamp = timestamp()
    token_hash = hashlib.sha256(actor["token"].encode()).hexdigest()
    with db:
        collision = db.execute(
            "SELECT instance_id FROM agents WHERE session_name=? AND retired_at IS NULL AND instance_id<>?",
            (actor["name"], actor["instance_id"]),
        ).fetchone()
        if collision:
            retire_instance(db, collision[0], actor["instance_id"], "session name was reused")
            audit(db, actor["instance_id"], "agent.name_reused", collision[0], {"session_name": actor["name"]})
        db.execute("""
          INSERT INTO agents(instance_id,session_name,token_hash,ssh_host,remote_dir,afws_version,
                             agent_type,registered_at,heartbeat_at)
          VALUES(?,?,?,?,?,?,?,?,?)
          ON CONFLICT(instance_id) DO UPDATE SET session_name=excluded.session_name,
            token_hash=excluded.token_hash, agent_type=excluded.agent_type,
            heartbeat_at=excluded.heartbeat_at, retired_at=NULL
        """, (actor["instance_id"], actor["name"], token_hash, host, remote,
              actor.get("afws_version", AFWS_VERSION), actor.get("agent", "unknown"), stamp, stamp))


def resolve_live_agent(db: sqlite3.Connection, state_dir: Path, host: str, remote: str, name: str) -> sqlite3.Row:
    validate_name(name, "session")
    record = read_record(state_dir, name)
    if not record.get("instance_id") or not record.get("token_hash"):
        die(f"{name} is not a live v2 session")
    if record.get("afws_version") != AFWS_VERSION:
        die(f"{name} uses unsupported AFWS version {record.get('afws_version', 'unknown')}")
    if record.get("agent") not in {"codex", "claude"}:
        die(f"{name} is not a supported Codex or Claude session")
    if record.get("ssh_host") != host or record.get("remote_dir", "").rstrip("/") != remote:
        die(f"{name} belongs to another project")
    stamp = timestamp()
    with db:
        old = db.execute(
            "SELECT instance_id FROM agents WHERE session_name=? AND retired_at IS NULL AND instance_id<>?",
            (name, record["instance_id"]),
        ).fetchone()
        if old:
            retire_instance(db, old[0], record["instance_id"], "session name was reused")
        db.execute("""
          INSERT INTO agents(instance_id,session_name,token_hash,ssh_host,remote_dir,afws_version,
                             agent_type,registered_at,heartbeat_at)
          VALUES(?,?,?,?,?,?,?,?,?)
          ON CONFLICT(instance_id) DO UPDATE SET session_name=excluded.session_name,
            token_hash=excluded.token_hash, agent_type=excluded.agent_type,
            heartbeat_at=excluded.heartbeat_at, retired_at=NULL
        """, (record["instance_id"], name, record["token_hash"], host, remote,
              record.get("afws_version", "unknown"), record.get("agent", "unknown"), stamp, stamp))
    return db.execute("SELECT * FROM agents WHERE instance_id=?", (record["instance_id"],)).fetchone()


def require_manager(db: sqlite3.Connection, actor_id: str, team: str | None = None) -> None:
    if actor_id == coordinator_id(db):
        return
    if team:
        row = db.execute("SELECT lead_instance FROM teams WHERE name=? AND archived_at IS NULL", (team,)).fetchone()
        if row and row[0] == actor_id:
            return
    die("only the coordinator or the affected team lead may do that", 4)


def latest_assignment(db: sqlite3.Connection, instance_id: str) -> sqlite3.Row | None:
    return db.execute("""
      SELECT a.*,t.title,t.team FROM assignments a JOIN tasks t USING(task_id)
      WHERE a.assignee_instance=? ORDER BY a.created_at DESC,a.rowid DESC LIMIT 1
    """, (instance_id,)).fetchone()


def active_assignments(db: sqlite3.Connection, instance_id: str | None = None) -> list[sqlite3.Row]:
    marks = ",".join("?" for _ in ACTIVE_STATES)
    query = f"SELECT a.*,t.title,t.team FROM assignments a JOIN tasks t USING(task_id) WHERE a.state IN ({marks})"
    params: list[object] = list(ACTIVE_STATES)
    if instance_id:
        query += " AND a.assignee_instance=?"
        params.append(instance_id)
    return db.execute(query, params).fetchall()


def scopes_overlap(left: str | None, right: str | None) -> bool:
    if not left or not right:
        return False
    left = left.rstrip("/*/")
    right = right.rstrip("/*/")
    return left == right or left.startswith(right + "/") or right.startswith(left + "/")


def paths_outside_scope(scope: str, paths: list[str]) -> list[str]:
    """Project-relative paths that fall outside a normalized write scope."""
    base = normalize_scope(scope)
    return [original for original, item in ((p, normalize_project_path(p)) for p in paths)
            if not (item == base or item.startswith(base + "/"))]


def change_state(db: sqlite3.Connection, assignment: sqlite3.Row, target: str,
                 actor_id: str, result: str | None = None, force: bool = False) -> None:
    source = assignment["state"]
    if not force and target not in TRANSITIONS.get(source, set()):
        die(f"invalid assignment transition: {source} -> {target}")
    stamp = timestamp()
    updated = db.execute("""
      UPDATE assignments SET state=?,revision=revision+1,updated_at=?,heartbeat_at=?,
                             result=COALESCE(?,result)
      WHERE assignment_id=? AND state=? AND revision=?
    """, (target, stamp, stamp, result, assignment["assignment_id"], source,
          assignment["revision"])).rowcount
    if updated != 1:
        die(f"stale assignment revision for {assignment['assignment_id']}; reload and retry", 3)
    db.execute("UPDATE tasks SET state=?,revision=revision+1,updated_at=? WHERE task_id=?",
               (target, stamp, assignment["task_id"]))
    audit(db, actor_id, f"assignment.{target}", assignment["assignment_id"], {"from": source})


def live_instances(state_dir: Path, host: str, remote: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for target in (state_dir / "sessions").glob("*.conf") if (state_dir / "sessions").is_dir() else []:
        record = read_record(state_dir, target.stem)
        try:
            age = timestamp() - int(record.get("started_epoch", "0"))
        except ValueError:
            age = 10**9
        alive = age < 15
        for field in ("pid", "agent_pid"):
            try:
                process_id = int(record.get(field, "0"))
                if process_id > 0:
                    os.kill(process_id, 0)
                    alive = True
            except PermissionError:
                alive = True
            except (ValueError, ProcessLookupError):
                pass
        if (alive and record.get("ssh_host") == host
                and record.get("remote_dir", "").rstrip("/") == remote
                and record.get("instance_id")):
            result[record["instance_id"]] = record.get("session_name", target.stem)
    return result


def afws_message_path() -> Path:
    override = os.environ.get("AFWS_ORG_MESSAGE_COMMAND")
    if override:
        return Path(override)
    candidate = Path(__file__).resolve().parent.parent / "bin" / "afws-message"
    if candidate.is_file():
        return candidate
    return Path("afws-message")


def lock_command_path() -> Path:
    override = os.environ.get("AFWS_ORG_LOCK_COMMAND")
    if override:
        return Path(override)
    candidate = Path(__file__).resolve().parent.parent / "bin" / "afws-lock"
    if candidate.is_file():
        return candidate
    return Path("afws-lock")


def release_assignment_locks(assignment: sqlite3.Row) -> None:
    for lock_name in json.loads(assignment["required_locks"] or "[]"):
        subprocess.run([str(lock_command_path()), "release", lock_name], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, check=False)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="afws-org")
    sub = parser.add_subparsers(dest="command")
    init = sub.add_parser("init"); init.add_argument("coordinator", nargs="?")
    command = sub.add_parser("add-team"); command.add_argument("team"); command.add_argument("lead")
    command = sub.add_parser("set-lead"); command.add_argument("team"); command.add_argument("lead")
    command = sub.add_parser("add-member"); command.add_argument("team"); command.add_argument("session"); command.add_argument("task", nargs="?")
    command = sub.add_parser("move-member"); command.add_argument("session"); command.add_argument("team"); command.add_argument("--cancel-active", action="store_true")
    command = sub.add_parser("remove-member"); command.add_argument("session"); command.add_argument("--cancel-active", action="store_true")
    command = sub.add_parser("remove-team"); command.add_argument("team"); command.add_argument("--cancel-active", action="store_true")
    command = sub.add_parser("transfer-coordinator"); command.add_argument("session")
    sub.add_parser("recover-coordinator")
    command = sub.add_parser("assign"); command.add_argument("session"); command.add_argument("task"); command.add_argument("--scope"); command.add_argument("--lock", action="append", default=[]); command.add_argument("--done-when", dest="done_when")
    command = sub.add_parser("dispatch"); command.add_argument("assignment_id", nargs="?"); command.add_argument("--force", action="store_true")
    command = sub.add_parser("claim"); command.add_argument("assignment_id"); command.add_argument("claim_token")
    command = sub.add_parser("start"); command.add_argument("assignment_id")
    for name in ("complete", "fail"):
        command = sub.add_parser(name); command.add_argument("assignment_id"); command.add_argument("result", nargs="?", default="")
        if name == "complete":
            command.add_argument("--evidence")
    command = sub.add_parser("set-done-when"); command.add_argument("assignment_id"); command.add_argument("done_when")
    for name in ("wait", "block"):
        command = sub.add_parser(name); command.add_argument("assignment_id"); command.add_argument("reason")
    command = sub.add_parser("cancel"); command.add_argument("assignment_id")
    command = sub.add_parser("retry"); command.add_argument("assignment_id")
    command = sub.add_parser("reassign"); command.add_argument("assignment_id"); command.add_argument("session")
    command = sub.add_parser("set-state"); command.add_argument("session"); command.add_argument("state")
    command = sub.add_parser("set-scope"); command.add_argument("session"); command.add_argument("write_scope")
    command = sub.add_parser("heartbeat"); command.add_argument("assignment_id", nargs="?")
    command = sub.add_parser("show"); command.add_argument("--team"); command.add_argument("--json", action="store_true")
    sub.add_parser("validate")
    sub.add_parser("reconcile")
    command = sub.add_parser("events"); command.add_argument("--limit", type=int, default=50)
    command = sub.add_parser("check-write"); command.add_argument("assignment_id"); command.add_argument("paths", nargs="+")
    command = sub.add_parser("guard"); command.add_argument("paths", nargs="+")
    sub.add_parser("scope")
    sub.add_parser("inbox")
    sub.add_parser("hook-context")
    sub.add_parser("version")
    return parser


def cancel_active(db: sqlite3.Connection, actor_id: str, instance_id: str, allowed: bool) -> None:
    rows = active_assignments(db, instance_id)
    if rows and not allowed:
        die("member has active assignments; pass --cancel-active or hand them off first")
    for row in rows:
        change_state(db, row, "cancelled", actor_id, "cancelled during organization change", force=True)
        release_assignment_locks(row)


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    if not args.command:
        args = parser.parse_args(["show"])
    read_only = args.command in {"show", "validate", "events", "version", "guard", "scope"}
    host, remote, state_dir, actor = project_context(not read_only)
    if not read_only and actor.get("afws_version") != AFWS_VERSION:
        die(f"session AFWS version {actor.get('afws_version', 'unknown')} cannot mutate schema {SCHEMA_VERSION}")
    if not read_only and actor.get("agent") not in {"codex", "claude"}:
        die("organization mutation requires a Codex or Claude session")
    db = open_database(state_dir, host, remote)
    if actor["valid"] == "1" and args.command not in {"guard", "scope"}:
        register_actor(db, actor, host, remote)
    if args.command == "version":
        print(f"afws-org schema={SCHEMA_VERSION} afws={AFWS_VERSION}")
        return
    if args.command == "init":
        if coordinator_id(db):
            die("organization already initialized")
        if args.coordinator and args.coordinator != actor["name"]:
            die("initial coordinator must be the current authenticated session")
        with db:
            db.execute("INSERT INTO meta(key,value) VALUES('coordinator_instance',?)", (actor["instance_id"],))
            audit(db, actor["instance_id"], "organization.initialized", actor["instance_id"], {})
        print(f"Initialized organization with coordinator {actor['name']}.")
        return
    if not coordinator_id(db) and args.command in {"inbox", "hook-context", "guard", "scope"}:
        return
    if not coordinator_id(db):
        die("organization is not initialized; run afws-org init")

    actor_id = actor.get("instance_id", "")
    if args.command == "inbox":
        print_inbox(db, actor_id)
        return
    if args.command == "hook-context":
        print_hook_context(db, actor_id)
        return
    if args.command == "recover-coordinator":
        previous = db.execute("SELECT * FROM agents WHERE instance_id=?", (coordinator_id(db),)).fetchone()
        if not previous:
            die("the previous coordinator identity is unavailable")
        if previous["retired_at"] is None or previous["session_name"] != actor["name"]:
            die("recovery requires a replacement session with the offline coordinator's exact name", 4)
        with db:
            db.execute("UPDATE meta SET value=? WHERE key='coordinator_instance'", (actor_id,))
            audit(db, actor_id, "coordinator.recovered", actor_id, {"previous": previous["instance_id"]})
        print(f"Coordinator recovered by {actor['name']} ({actor_id}).")
        return
    if args.command == "add-team":
        require_manager(db, actor_id)
        validate_name(args.team, "team")
        existing_team = db.execute("SELECT archived_at FROM teams WHERE name=?", (args.team,)).fetchone()
        if existing_team:
            suffix = " (archived names are reserved for audit history)" if existing_team["archived_at"] else ""
            die(f"team already exists: {args.team}{suffix}")
        lead = resolve_live_agent(db, state_dir, host, remote, args.lead)
        if lead["team"]:
            die(f"{args.lead} already belongs to team {lead['team']}")
        with db:
            db.execute("INSERT INTO teams(name,lead_instance) VALUES(?,?)", (args.team, lead["instance_id"]))
            db.execute("UPDATE agents SET team=?,role='lead' WHERE instance_id=?", (args.team, lead["instance_id"]))
            audit(db, actor_id, "team.added", args.team, {"lead": args.lead})
        print(f"Added team {args.team} with lead {args.lead}.")
        return
    if args.command == "add-member":
        require_manager(db, actor_id, args.team)
        if not db.execute("SELECT 1 FROM teams WHERE name=? AND archived_at IS NULL", (args.team,)).fetchone():
            die(f"unknown team: {args.team}")
        member = resolve_live_agent(db, state_dir, host, remote, args.session)
        if member["team"]:
            die(f"{args.session} already belongs to team {member['team']}")
        with db:
            db.execute("UPDATE agents SET team=?,role='worker' WHERE instance_id=?", (args.team, member["instance_id"]))
            audit(db, actor_id, "member.added", member["instance_id"], {"team": args.team})
        print(f"Added {args.session} to team {args.team}.")
        if args.task:
            member = db.execute("SELECT * FROM agents WHERE instance_id=?", (member["instance_id"],)).fetchone()
            assign_to(db, actor, member, args.task, None, [])
        return
    if args.command == "set-lead":
        require_manager(db, actor_id)
        team = db.execute("SELECT * FROM teams WHERE name=? AND archived_at IS NULL", (args.team,)).fetchone()
        if not team:
            die(f"unknown team: {args.team}")
        new_lead = resolve_live_agent(db, state_dir, host, remote, args.lead)
        if new_lead["team"] not in (None, args.team):
            die(f"{args.lead} belongs to another team")
        with db:
            db.execute("UPDATE agents SET role='worker' WHERE instance_id=?", (team["lead_instance"],))
            db.execute("UPDATE agents SET team=?,role='lead' WHERE instance_id=?", (args.team, new_lead["instance_id"]))
            db.execute("UPDATE teams SET lead_instance=? WHERE name=?", (new_lead["instance_id"], args.team))
            audit(db, actor_id, "team.lead_changed", args.team, {"lead": args.lead})
        print(f"Team {args.team} lead is now {args.lead}.")
        return
    if args.command in {"move-member", "remove-member"}:
        member = db.execute("SELECT * FROM agents WHERE session_name=? AND retired_at IS NULL", (args.session,)).fetchone()
        if not member or not member["team"]:
            die(f"unknown member: {args.session}")
        require_manager(db, actor_id, member["team"])
        if member["role"] == "lead":
            die("change the team lead first")
        with db:
            cancel_active(db, actor_id, member["instance_id"], args.cancel_active)
            if args.command == "move-member":
                if not db.execute("SELECT 1 FROM teams WHERE name=? AND archived_at IS NULL", (args.team,)).fetchone():
                    die(f"unknown team: {args.team}")
                db.execute("UPDATE agents SET team=? WHERE instance_id=?", (args.team, member["instance_id"]))
                audit(db, actor_id, "member.moved", member["instance_id"], {"from": member["team"], "to": args.team})
                print(f"Moved {args.session}: {member['team']} -> {args.team}")
            else:
                db.execute("UPDATE agents SET team=NULL,role='worker' WHERE instance_id=?", (member["instance_id"],))
                audit(db, actor_id, "member.removed", member["instance_id"], {"team": member["team"]})
                print(f"Removed {args.session} from the organization.")
        return
    if args.command == "remove-team":
        require_manager(db, actor_id)
        team = db.execute("SELECT * FROM teams WHERE name=? AND archived_at IS NULL", (args.team,)).fetchone()
        if not team:
            die(f"unknown team: {args.team}")
        members = db.execute("SELECT * FROM agents WHERE team=? AND retired_at IS NULL", (args.team,)).fetchall()
        with db:
            for member in members:
                cancel_active(db, actor_id, member["instance_id"], args.cancel_active)
            db.execute("UPDATE agents SET team=NULL,role='worker' WHERE team=?", (args.team,))
            db.execute("UPDATE teams SET archived_at=? WHERE name=?", (timestamp(), args.team))
            audit(db, actor_id, "team.removed", args.team, {})
        print(f"Removed team {args.team}.")
        return
    if args.command == "transfer-coordinator":
        require_manager(db, actor_id)
        target = resolve_live_agent(db, state_dir, host, remote, args.session)
        with db:
            db.execute("UPDATE meta SET value=? WHERE key='coordinator_instance'", (target["instance_id"],))
            audit(db, actor_id, "coordinator.transferred", target["instance_id"], {"session": args.session})
        print(f"Coordinator transferred to {args.session}.")
        return
    if args.command == "assign":
        member = db.execute("SELECT * FROM agents WHERE session_name=? AND retired_at IS NULL", (args.session,)).fetchone()
        if not member or not member["team"]:
            die("assignee is not an active organization member")
        require_manager(db, actor_id, member["team"])
        assignment_id = assign_to(db, actor, member, args.task, args.scope, args.lock,
                                  done_when=args.done_when)
        print(f"Assigned {args.session}: {args.task}\nassignment_id={assignment_id}")
        return
    if args.command == "dispatch":
        if args.assignment_id:
            assignment = get_assignment(db, args.assignment_id)
            task = db.execute("SELECT team FROM tasks WHERE task_id=?", (assignment["task_id"],)).fetchone()
            require_manager(db, actor_id, task["team"])
        else:
            require_manager(db, actor_id)
        dispatch_outbox(db, actor_id, args.assignment_id, args.force)
        return
    if args.command == "claim":
        db.execute("BEGIN IMMEDIATE")
        try:
            assignment = get_assignment(db, args.assignment_id)
            if assignment["assignee_instance"] != actor_id:
                die("assignment is not addressed to this session", 4)
            actual = hashlib.sha256(args.claim_token.encode()).hexdigest()
            if not assignment["claim_hash"] or not hmac.compare_digest(assignment["claim_hash"], actual):
                die("invalid or replayed claim token", 4)
            change_state(db, assignment, "acknowledged", actor_id)
            db.execute("UPDATE assignments SET claim_hash=NULL WHERE assignment_id=?", (args.assignment_id,))
            db.commit()
        except BaseException:
            db.rollback()
            raise
        print(f"Acknowledged {args.assignment_id}.")
        return
    if args.command == "start":
        assignment = owned_assignment(db, args.assignment_id, actor_id)
        acquired: list[str] = []
        for lock_name in json.loads(assignment["required_locks"] or "[]"):
            result = subprocess.run([str(lock_command_path()), "acquire", lock_name], text=True, capture_output=True)
            if result.returncode:
                for held in acquired:
                    subprocess.run([str(lock_command_path()), "release", held], check=False)
                with db:
                    change_state(db, assignment, "waiting", actor_id, f"waiting for lock {lock_name}")
                die(f"could not acquire required lock {lock_name}", 3)
            acquired.append(lock_name)
        try:
            with db:
                change_state(db, assignment, "running", actor_id)
        except BaseException:
            for held in acquired:
                subprocess.run([str(lock_command_path()), "release", held], check=False)
            raise
        print(f"Started {args.assignment_id}.")
        return
    if args.command in {"complete", "fail"}:
        assignment = owned_assignment(db, args.assignment_id, actor_id)
        target = "completed" if args.command == "complete" else "failed"
        evidence = None
        if target == "completed":
            # An assignment that states when it is done cannot be closed on the
            # assignee's own say-so. Declaring completion early is the failure
            # mode this field exists to catch, so the close needs the observed
            # result, not an assurance.
            condition = assignment["done_when"]
            if condition:
                if not (args.evidence or "").strip():
                    die(
                        f"assignment {args.assignment_id} states its acceptance condition: {condition}. "
                        "Close it with '--evidence' naming the command you ran and what it actually "
                        "returned. If the condition does not hold, use 'afws-org fail', "
                        "'afws-org wait', or 'afws-org block' instead.",
                        4,
                    )
                evidence = validate_text(args.evidence.strip(), "evidence", 2000)
                if not (args.result or "").strip():
                    die(f"assignment {args.assignment_id} needs a concrete result as well as evidence", 4)
        with db:
            change_state(db, assignment, target, actor_id, args.result)
            if evidence is not None:
                db.execute("UPDATE assignments SET evidence=? WHERE assignment_id=?",
                           (evidence, assignment["assignment_id"]))
                audit(db, actor_id, "assignment.evidence_recorded", assignment["assignment_id"],
                      {"done_when": assignment["done_when"]})
        release_assignment_locks(assignment)
        print(f"{target.capitalize()} {args.assignment_id}.")
        return
    if args.command in {"wait", "block"}:
        assignment = owned_assignment(db, args.assignment_id, actor_id)
        target = "waiting" if args.command == "wait" else "blocked"
        with db:
            change_state(db, assignment, target, actor_id, validate_text(args.reason, "reason"))
        print(f"{target.capitalize()} {args.assignment_id}: {args.reason}")
        return
    if args.command == "cancel":
        assignment = get_assignment(db, args.assignment_id)
        task = db.execute("SELECT team FROM tasks WHERE task_id=?", (assignment["task_id"],)).fetchone()
        require_manager(db, actor_id, task["team"])
        with db:
            target = "cancelled" if assignment["state"] in {"assigned", "delivery_failed", "ack_timeout"} else "cancel_requested"
            change_state(db, assignment, target, actor_id)
            if target == "cancel_requested":
                recipient = db.execute("SELECT session_name FROM agents WHERE instance_id=?",
                                       (assignment["assignee_instance"],)).fetchone()[0]
                payload = f"[AFWS organization cancellation]\nassignment_id: {args.assignment_id}\naction: stop and acknowledge cancellation"
                stamp = timestamp()
                db.execute("""
                  INSERT INTO outbox(outbox_id,assignment_id,recipient,payload,kind,state,attempts,
                                     next_attempt,last_error,created_at,updated_at)
                  VALUES(?,?,?,?,?,'pending',0,?,NULL,?,?)
                """, (str(uuid.uuid4()), args.assignment_id, recipient, payload, "cancellation",
                      stamp, stamp, stamp))
        if target == "cancelled":
            release_assignment_locks(assignment)
        print(f"{target} {args.assignment_id}.")
        return
    if args.command == "retry":
        assignment = get_assignment(db, args.assignment_id)
        task = db.execute("SELECT team FROM tasks WHERE task_id=?", (assignment["task_id"],)).fetchone()
        require_manager(db, actor_id, task["team"])
        with db:
            change_state(db, assignment, "assigned", actor_id)
            db.execute("""
              UPDATE outbox SET state='pending',next_attempt=?,last_error=NULL
              WHERE assignment_id=? AND kind='assignment'
            """, (timestamp(), args.assignment_id))
        print(f"Retry scheduled for {args.assignment_id}.")
        return
    if args.command == "reassign":
        old = get_assignment(db, args.assignment_id)
        if old["state"] in {"completed", "cancelled"}:
            die(f"cannot reassign a terminal {old['state']} assignment")
        task = db.execute("SELECT * FROM tasks WHERE task_id=?", (old["task_id"],)).fetchone()
        require_manager(db, actor_id, task["team"])
        target = db.execute("SELECT * FROM agents WHERE session_name=? AND retired_at IS NULL", (args.session,)).fetchone()
        if not target or target["team"] != task["team"]:
            die("new assignee must be an active member of the same team")
        new_id = assign_to(db, actor, target, task["title"], old["write_scope"],
                           json.loads(old["required_locks"]), task, old,
                           done_when=old["done_when"])
        print(f"Reassigned {args.assignment_id} -> {new_id} ({args.session}).")
        return
    if args.command == "set-state":
        member = db.execute("SELECT * FROM agents WHERE session_name=? AND retired_at IS NULL", (args.session,)).fetchone()
        if not member:
            die(f"unknown member: {args.session}")
        assignment = latest_assignment(db, member["instance_id"])
        if not assignment:
            die("member has no assignment")
        if actor_id != member["instance_id"]:
            require_manager(db, actor_id, member["team"])
        with db:
            change_state(db, assignment, args.state, actor_id)
        if args.state in TERMINAL_STATES:
            release_assignment_locks(assignment)
        print(f"{args.session} task state: {args.state}")
        return
    if args.command == "set-scope":
        member = db.execute("SELECT * FROM agents WHERE session_name=? AND retired_at IS NULL", (args.session,)).fetchone()
        if not member:
            die(f"unknown member: {args.session}")
        require_manager(db, actor_id, member["team"])
        assignment = latest_assignment(db, member["instance_id"])
        if not assignment or assignment["state"] in TERMINAL_STATES:
            die("member has no active assignment")
        normalized_scope = normalize_scope(args.write_scope)
        ensure_scope_available(db, normalized_scope, assignment["assignment_id"])
        with db:
            db.execute("UPDATE assignments SET write_scope=?,revision=revision+1,updated_at=? WHERE assignment_id=?",
                       (normalized_scope, timestamp(), assignment["assignment_id"]))
            audit(db, actor_id, "assignment.scope_changed", assignment["assignment_id"], {"scope": normalized_scope})
        print(f"{args.session} write scope: {normalized_scope}")
        return
    if args.command == "heartbeat":
        if args.assignment_id:
            owned_assignment(db, args.assignment_id, actor_id)
        with db:
            stamp = timestamp()
            db.execute("UPDATE agents SET heartbeat_at=? WHERE instance_id=?", (stamp, actor_id))
            if args.assignment_id:
                db.execute("UPDATE assignments SET heartbeat_at=? WHERE assignment_id=? AND assignee_instance=?",
                           (stamp, args.assignment_id, actor_id))
        print("Heartbeat recorded.")
        return
    if args.command == "scope":
        # Printed only when this session is actually under a write scope, so a
        # caller can skip an expensive check entirely in the ordinary case.
        assignment = latest_assignment(db, actor_id)
        if assignment and assignment["state"] in ACTIVE_STATES and assignment["write_scope"]:
            print(f"{assignment['assignment_id']}\t{normalize_scope(assignment['write_scope'])}")
        return
    if args.command == "guard":
        # A guard runs on every intercepted write, so it must be cheap, must
        # never mutate, and must fail open: an unscoped session is ordinary
        # work, not a violation.
        assignment = latest_assignment(db, actor_id)
        if not assignment or assignment["state"] not in ACTIVE_STATES:
            return
        scope = assignment["write_scope"]
        if not scope:
            return
        try:
            outside = paths_outside_scope(scope, args.paths)
        except SystemExit:
            raise
        if outside:
            die(
                f"write outside assignment {assignment['assignment_id']} scope '{normalize_scope(scope)}': "
                + ", ".join(outside)
                + ". Do not route around this. If the work genuinely needs that path, stop with "
                f"'afws-org wait {assignment['assignment_id']} REASON' and report it, or ask the "
                "coordinator to widen the scope with 'afws-org set-scope'.",
                4,
            )
        return
    if args.command == "set-done-when":
        assignment = owned_assignment(db, args.assignment_id, actor_id)
        condition = validate_text(args.done_when, "acceptance condition")
        with db:
            db.execute("UPDATE assignments SET done_when=?,revision=revision+1,updated_at=? WHERE assignment_id=?",
                       (condition, timestamp(), assignment["assignment_id"]))
            audit(db, actor_id, "assignment.done_when_set", assignment["assignment_id"],
                  {"done_when": condition})
        print(f"Acceptance condition for {args.assignment_id}: {condition}")
        return
    if args.command == "check-write":
        assignment = owned_assignment(db, args.assignment_id, actor_id)
        scope = assignment["write_scope"]
        if not scope:
            die("assignment has no write scope", 4)
        outside = paths_outside_scope(scope, args.paths)
        if outside:
            die("write outside assignment scope: " + ", ".join(outside), 4)
        print("Write scope accepted.")
        return
    if args.command == "reconcile":
        require_manager(db, actor_id)
        live = live_instances(state_dir, host, remote)
        changes = 0
        with db:
            recovered = db.execute("""
              UPDATE outbox SET state='failed',next_attempt=?,last_error='recovered stale delivery lease'
              WHERE state='sending' AND updated_at<?
            """, (timestamp(), timestamp() - 300)).rowcount
            for row in db.execute("SELECT * FROM assignments WHERE state IN ('running','waiting','blocked')").fetchall():
                if row["assignee_instance"] not in live:
                    change_state(db, row, "orphaned", actor_id)
                    release_assignment_locks(row)
                    changes += 1
            for row in db.execute("SELECT * FROM assignments WHERE state='delivered' AND ack_deadline<?", (timestamp(),)).fetchall():
                    change_state(db, row, "ack_timeout", actor_id)
                    changes += 1
        print(f"Reconciled {changes} assignment(s), recovered {recovered} delivery lease(s).")
        return
    if args.command == "show":
        show(db, state_dir, host, remote, args.team, args.json)
        return
    if args.command == "validate":
        validate_database(db, state_dir, host, remote)
        return
    if args.command == "events":
        for row in db.execute("SELECT * FROM events ORDER BY event_id DESC LIMIT ?", (max(1, min(args.limit, 1000)),)):
            print(json.dumps(dict(row), ensure_ascii=False))
        return
    die(f"unknown command: {args.command}")


def assign_to(db: sqlite3.Connection, actor: dict[str, str], member: sqlite3.Row,
              title: str, scope: str | None, locks: list[str],
              existing_task: sqlite3.Row | None = None,
              previous_assignment: sqlite3.Row | None = None,
              done_when: str | None = None) -> str:
    validate_text(title, "task")
    if done_when:
        done_when = validate_text(done_when, "acceptance condition")
    if scope:
        scope = normalize_scope(scope)
    for lock_name in locks:
        validate_name(lock_name, "lock")
    task_id, assignment_id = str(uuid.uuid4()), str(uuid.uuid4())
    claim_token = secrets.token_urlsafe(32)
    stamp = timestamp()
    db.execute("BEGIN IMMEDIATE")
    try:
        if previous_assignment is not None:
            change_state(db, previous_assignment, "cancelled", actor["instance_id"],
                         "superseded by reassignment", force=True)
        if active_assignments(db, member["instance_id"]):
            die(f"{member['session_name']} already has an active assignment; complete, cancel, or reassign it first")
        if scope:
            ensure_scope_available(db, scope)
        if existing_task is None:
            db.execute("INSERT INTO tasks VALUES(?,?,?,?,?,?,?,?)",
                       (task_id, title, member["team"], "assigned", 1,
                        actor["instance_id"], stamp, stamp))
        else:
            task_id = existing_task["task_id"]
            db.execute("UPDATE tasks SET state='assigned',revision=revision+1,updated_at=? WHERE task_id=?",
                       (stamp, task_id))
        db.execute("""
          INSERT INTO assignments(assignment_id,task_id,assignee_instance,state,revision,write_scope,
                                  required_locks,claim_hash,done_when,created_at,updated_at)
          VALUES(?,?,?,'assigned',1,?,?,?,?,?,?)
        """, (assignment_id, task_id, member["instance_id"], scope, json.dumps(locks),
              hashlib.sha256(claim_token.encode()).hexdigest(), done_when, stamp, stamp))
        payload = (
            f"[AFWS organization assignment]\nassignment_id: {assignment_id}\nclaim_token: {claim_token}\n"
            f"team: {member['team']}\ntask: {title}\nwrite_scope: {scope or '-'}\n"
            f"done_when: {done_when or '-'}\n"
            f"report_to: {actor['name']}\nredelegation: forbidden"
        )
        db.execute("""
          INSERT INTO outbox(outbox_id,assignment_id,recipient,payload,kind,state,attempts,
                             next_attempt,last_error,created_at,updated_at)
          VALUES(?,?,?,?,?,'pending',0,?,NULL,?,?)
        """, (str(uuid.uuid4()), assignment_id, member["session_name"], payload, "assignment",
              stamp, stamp, stamp))
        audit(db, actor["instance_id"], "assignment.created", assignment_id,
              {"task_id": task_id, "assignee": member["session_name"], "scope": scope, "locks": locks,
               "done_when": done_when})
        db.commit()
    except BaseException:
        db.rollback()
        raise
    if previous_assignment is not None:
        release_assignment_locks(previous_assignment)
    return assignment_id


def ensure_scope_available(db: sqlite3.Connection, scope: str, ignore_id: str | None = None) -> None:
    for row in active_assignments(db):
        if row["assignment_id"] != ignore_id and scopes_overlap(scope, row["write_scope"]):
            die(f"write scope conflicts with assignment {row['assignment_id']}")


def get_assignment(db: sqlite3.Connection, assignment_id: str) -> sqlite3.Row:
    row = db.execute("SELECT * FROM assignments WHERE assignment_id=?", (assignment_id,)).fetchone()
    if not row:
        die(f"unknown assignment: {assignment_id}")
    return row


def owned_assignment(db: sqlite3.Connection, assignment_id: str, actor_id: str) -> sqlite3.Row:
    row = get_assignment(db, assignment_id)
    if row["assignee_instance"] != actor_id:
        die("assignment is not owned by this session", 4)
    return row


def print_inbox(db: sqlite3.Connection, actor_id: str) -> None:
    rows = db.execute("""
      SELECT o.kind,o.payload,a.state,a.claim_hash FROM outbox o
      JOIN assignments a USING(assignment_id)
      WHERE a.assignee_instance=? AND o.state='sent'
        AND ((o.kind='assignment' AND a.state='delivered' AND a.claim_hash IS NOT NULL)
          OR (o.kind='cancellation' AND a.state='cancel_requested'))
      ORDER BY o.created_at,o.rowid
    """, (actor_id,)).fetchall()
    if rows:
        print("\n\n".join(row["payload"] for row in rows))


def print_hook_context(db: sqlite3.Connection, actor_id: str) -> None:
    assignment = latest_assignment(db, actor_id)
    if not assignment:
        return
    state = assignment["state"]
    assignment_id = assignment["assignment_id"]
    if state == "acknowledged":
        print(
            f"AFWS assignment {assignment_id} is acknowledged but not started. "
            f"Run 'afws-org start {assignment_id}' and continue the assigned task."
        )
    elif state == "running":
        lines = [
            f"AFWS assignment {assignment_id} is still running: {assignment['title']}. "
            "Do not stop merely because one approach ended. Inspect concrete progress and continue toward the "
            "acceptance condition."
        ]
        if assignment["write_scope"]:
            lines.append(
                f"Write scope: {assignment['write_scope']}. Writes outside it are refused. If the work genuinely "
                "needs another path, stop and say so rather than routing around it."
            )
        if assignment["done_when"]:
            lines.append(
                f"Done when: {assignment['done_when']}. Close it with "
                f"'afws-org complete {assignment_id} RESULT --evidence \"COMMAND -> WHAT IT RETURNED\"'; "
                "completion without that evidence is refused."
            )
        else:
            lines.append(f"Close it with 'afws-org complete {assignment_id} RESULT'.")
        lines.append(
            f"The other outcomes are 'afws-org fail {assignment_id} REASON', "
            f"'afws-org wait {assignment_id} REASON', and 'afws-org block {assignment_id} REASON'."
        )
        print(" ".join(lines))
    elif state == "cancel_requested":
        print(
            f"Cancellation was requested for AFWS assignment {assignment_id}. Stop its side effects, release "
            f"resources, then run 'afws-org set-state {session_name_for(db, actor_id)} cancelled'."
        )


def session_name_for(db: sqlite3.Connection, instance_id: str) -> str:
    row = db.execute("SELECT session_name FROM agents WHERE instance_id=?", (instance_id,)).fetchone()
    return row[0] if row else instance_id


def dispatch_outbox(db: sqlite3.Connection, actor_id: str, assignment_id: str | None, force: bool) -> None:
    query = "SELECT * FROM outbox WHERE state IN ('pending','failed')"
    params: list[object] = []
    if not force:
        query += " AND next_attempt<=?"
        params.append(timestamp())
    if assignment_id:
        query += " AND assignment_id=?"
        params.append(assignment_id)
    rows = db.execute(query, params).fetchall()
    processed = 0
    for row in rows:
        if row["attempts"] >= 5 and not force:
            continue
        with db:
            claimed = db.execute("""
              UPDATE outbox SET state='sending',updated_at=?
              WHERE outbox_id=? AND state IN ('pending','failed')
            """, (timestamp(), row["outbox_id"])).rowcount
        if not claimed:
            continue
        recipient = db.execute(
            "SELECT agent_type FROM agents WHERE session_name=? AND retired_at IS NULL",
            (row["recipient"],),
        ).fetchone()
        if recipient and recipient["agent_type"] == "claude":
            # Claude Code has no CLI for injecting a message into an arbitrary
            # already-running session. Its lifecycle hook reads this durable
            # sent item from `afws-org inbox` at the next turn boundary.
            result = subprocess.CompletedProcess([], 0, "durable Claude inbox", "")
        elif recipient and recipient["agent_type"] == "codex":
            result = subprocess.run(
                [str(afws_message_path()), "--to", row["recipient"], "--message", row["payload"]],
                text=True, capture_output=True,
            )
        else:
            result = subprocess.CompletedProcess([], 2, "", "recipient is unavailable or unsupported")
        stamp = timestamp()
        attempts = row["attempts"] + 1
        with db:
            assignment = get_assignment(db, row["assignment_id"])
            if result.returncode == 0:
                db.execute("UPDATE outbox SET state='sent',attempts=?,updated_at=?,last_error=NULL WHERE outbox_id=?",
                           (attempts, stamp, row["outbox_id"]))
                if row["kind"] == "assignment" and assignment["state"] in {"assigned", "delivery_failed", "ack_timeout"}:
                    change_state(db, assignment, "delivered", actor_id)
                    db.execute("UPDATE assignments SET ack_deadline=? WHERE assignment_id=?",
                               (stamp + 300, assignment["assignment_id"]))
                audit(db, actor_id, "outbox.sent", row["outbox_id"], {"recipient": row["recipient"]})
            else:
                delay = min(600, 10 * (3 ** min(attempts - 1, 4)))
                error = (result.stderr or result.stdout or "delivery failed")[-1000:]
                db.execute("""
                  UPDATE outbox SET state='failed',attempts=?,next_attempt=?,updated_at=?,last_error=?
                  WHERE outbox_id=?
                """, (attempts, stamp + delay, stamp, error, row["outbox_id"]))
                if row["kind"] == "assignment" and assignment["state"] == "assigned":
                    change_state(db, assignment, "delivery_failed", actor_id, error)
                audit(db, actor_id, "outbox.failed", row["outbox_id"], {"error": error})
        processed += 1
    print(f"Processed {processed} outbox item(s).")


def show(db: sqlite3.Connection, state_dir: Path, host: str, remote: str,
         team_filter: str | None, as_json: bool) -> None:
    live = live_instances(state_dir, host, remote)
    coordinator = db.execute("SELECT session_name,instance_id,retired_at FROM agents WHERE instance_id=?",
                             (coordinator_id(db),)).fetchone()
    teams = []
    for team in db.execute("SELECT * FROM teams WHERE archived_at IS NULL ORDER BY name"):
        if team_filter and team["name"] != team_filter:
            continue
        members = []
        for member in db.execute("SELECT * FROM agents WHERE team=? AND retired_at IS NULL ORDER BY role,session_name",
                                 (team["name"],)):
            assignment = latest_assignment(db, member["instance_id"])
            members.append({
                "session": member["session_name"], "instance_id": member["instance_id"],
                "agent": member["agent_type"], "role": member["role"],
                "afws_version": member["afws_version"],
                "live_status": "live" if member["instance_id"] in live else "offline",
                "assignment": dict(assignment) if assignment else None,
            })
        teams.append({"name": team["name"], "lead_instance": team["lead_instance"], "members": members})
    data = {
        "schema_version": SCHEMA_VERSION, "ssh_host": host, "remote_dir": remote,
        "coordinator": dict(coordinator) if coordinator else None, "teams": teams,
    }
    if as_json:
        print(json.dumps(data, ensure_ascii=False, indent=2, separators=(",", ":")))
        return
    print(f"Organization: {host}:{remote}")
    coordinator_label = coordinator["session_name"] if coordinator else "(missing)"
    if coordinator and coordinator["retired_at"] is not None:
        coordinator_label += " [retired; run recover-coordinator]"
    print(f"Coordinator: {coordinator_label}")
    for team in teams:
        print(f"\n├─ Team {team['name']}")
        for member in team["members"]:
            label = "Lead: " if member["role"] == "lead" else ""
            assignment = member["assignment"]
            suffix = " (idle)"
            if assignment:
                suffix = f" ({assignment['state']}) {assignment['title']} [{assignment['assignment_id'][:8]}]"
            print(f"│  ├─ {label}{member['session']} [{member['live_status']}]{suffix}")
            if assignment and assignment["state"] in ACTIVE_STATES:
                if assignment["write_scope"]:
                    print(f"│  │     scope: {assignment['write_scope']}")
                if assignment["done_when"]:
                    print(f"│  │     done when: {assignment['done_when']}")


def validate_database(db: sqlite3.Connection, state_dir: Path, host: str, remote: str) -> None:
    errors: list[str] = []
    coordinator = coordinator_id(db)
    if not coordinator or not db.execute(
            "SELECT 1 FROM agents WHERE instance_id=? AND retired_at IS NULL", (coordinator,)).fetchone():
        errors.append("missing coordinator agent")
    for team in db.execute("SELECT * FROM teams WHERE archived_at IS NULL"):
        lead = db.execute("SELECT * FROM agents WHERE instance_id=?", (team["lead_instance"],)).fetchone()
        if (not lead or lead["retired_at"] is not None or lead["team"] != team["name"]
                or lead["role"] != "lead"):
            errors.append(f"invalid lead for team {team['name']}")
    active = active_assignments(db)
    for index, left in enumerate(active):
        for right in active[index + 1:]:
            if scopes_overlap(left["write_scope"], right["write_scope"]):
                errors.append(f"scope conflict: {left['assignment_id']} / {right['assignment_id']}")
    for row in db.execute("SELECT * FROM assignments"):
        if row["state"] not in TRANSITIONS:
            errors.append(f"invalid state on {row['assignment_id']}: {row['state']}")
    versions = {row[0] for row in db.execute("SELECT DISTINCT afws_version FROM agents WHERE retired_at IS NULL")}
    if len(versions) > 1 or (versions and versions != {AFWS_VERSION}):
        errors.append("mixed or unsupported AFWS session versions: " + ", ".join(sorted(versions)))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        raise SystemExit(1)
    print("Organization is valid.")


if __name__ == "__main__":
    try:
        main()
    except sqlite3.IntegrityError as error:
        die(f"ledger constraint rejected the operation ({error})", 2)
    except sqlite3.OperationalError as error:
        die(f"organization ledger operation failed ({error})", 3)
    except sqlite3.DatabaseError as error:
        die(f"organization ledger is corrupt or incompatible ({error}); preserve it and restore from backup", 1)
    except KeyboardInterrupt:
        die("interrupted; committed ledger transactions remain intact", 130)
