#!/usr/bin/env python3
"""Remote project files as MCP tools, over the session's shared SSH connection.

A remote-first session has no local copy of the project to read: the mount is a
view at best and absent at worst. Without this the agent's only way to a file is
a shell command, which costs it structured reads, exact-string edits and
line-anchored search. This server hands those back without a mount, so nothing
depends on a filesystem that can die underneath it.

It runs on the Mac, not on the workstation. The workstation's node is too old
for the published MCP servers, and installing agent machinery there is the thing
afws-doctor exists to warn about. The cost is one SSH round trip per operation,
which a shared connection on a local network makes unnoticeable.

Every operation is confined to AFWS_REMOTE_DIR. That boundary is enforced where
it can actually be enforced -- on the remote, after resolution -- because a path
can leave the project through a symlink that no amount of local string checking
would reveal.
"""

from __future__ import annotations

import base64
import json
import os
import shlex
import subprocess
import sys
from pathlib import PurePosixPath
from typing import Any, NoReturn

SERVER_NAME = "afws-fs"
SERVER_VERSION = "1"
PROTOCOL_VERSION = "2024-11-05"

# A read that would fill the context window helps nobody, and a write that large
# is a file transfer rather than an edit; afws-push exists for those.
MAX_READ_BYTES = 2 * 1024 * 1024
MAX_WRITE_BYTES = 2 * 1024 * 1024
MAX_READ_LINES = 2000
MAX_DIRECTORY_ENTRIES = 1000
MAX_MATCHES = 200
SSH_TIMEOUT_SECONDS = 120

# Exit statuses the remote worker uses for conditions that are not its own
# failure. ssh itself reports 255, and the worker never returns that.
EXIT_OK = 0
EXIT_WORKER_ERROR = 1

# The worker runs on the workstation. It is sent as the argument to python3 -c
# on every call rather than installed, so there is nothing on the remote to keep
# up to date and nothing left behind. It speaks one JSON request on stdin and
# one JSON response on stdout, which keeps the remote shell out of the data
# path: no argument of ours is ever parsed by it.
REMOTE_WORKER = r'''
import base64, fnmatch, json, os, sys

def resolve(root, relative, must_exist, follow=True):
    """Return the real path of relative inside root, or raise if it leaves it.

    Resolution happens here, on the side that owns the filesystem, because a
    symlink is only an escape once it has been followed, and nothing on the Mac
    can see where a remote link points. The parent is resolved separately so a
    file that does not exist yet can still be written: only its directory has
    to be inside the project.

    follow draws the boundary at data rather than at visibility. This project
    is built out of symlinks -- a venv whose python3 points at /usr/local/bin,
    sequence databases pointing at each other -- and hiding them is the exact
    fidelity the rclone view already loses. So naming a link and its target is
    allowed even when the target is outside the project (follow=False, used by
    stat), while reading or writing through one is not (follow=True). Metadata
    about an entry that is itself inside the project discloses nothing; its
    contents would.
    """
    if not relative or relative == ".":
        return root
    target = os.path.join(root, relative)
    parent = os.path.dirname(target) or root
    try:
        real_parent = os.path.realpath(parent)
    except OSError:
        raise Failure("no such directory: " + relative)
    if not os.path.isdir(real_parent):
        raise Failure("no such directory: " + os.path.dirname(relative))
    if not inside(root, real_parent):
        raise Failure("path leaves the project directory: " + relative)
    resolved = os.path.join(real_parent, os.path.basename(target))
    exists = os.path.islink(resolved) or os.path.exists(resolved)
    if exists and follow:
        resolved = os.path.realpath(resolved)
        if not inside(root, resolved):
            raise Failure("path leaves the project directory through a link: " + relative)
    elif not exists and must_exist:
        raise Failure("no such file: " + relative)
    return resolved


def inside(root, candidate):
    return candidate == root or candidate.startswith(root + os.sep)


class Failure(Exception):
    pass


def relative_to(root, path):
    return os.path.relpath(path, root) if path != root else "."


def read_text(path, limit):
    with open(path, "rb") as handle:
        raw = handle.read(limit + 1)
    truncated = len(raw) > limit
    raw = raw[:limit]
    # A NUL byte in the first block is the usual signal, and the only one worth
    # acting on: guessing at encodings turns a clear refusal into a bad read.
    if b"\x00" in raw[:8192]:
        raise Failure("this is a binary file")
    return raw.decode("utf-8", errors="replace"), truncated


def op_read_file(root, request):
    path = resolve(root, request["path"], True)
    if os.path.isdir(path):
        raise Failure("this is a directory; use list_directory")
    text, truncated = read_text(path, MAX_READ_BYTES)
    lines = text.splitlines()
    total = len(lines)
    offset = max(int(request.get("offset") or 1), 1)
    limit = int(request.get("limit") or MAX_READ_LINES)
    limit = max(min(limit, MAX_READ_LINES), 1)
    window = lines[offset - 1:offset - 1 + limit]
    return {
        "lines": window, "first_line": offset, "total_lines": total,
        "truncated": truncated or offset - 1 + len(window) < total,
    }


def op_write_file(root, request):
    path = resolve(root, request["path"], False)
    if os.path.isdir(path):
        raise Failure("this is a directory")
    content = base64.b64decode(request["content"])
    existed = os.path.exists(path)
    with open(path, "wb") as handle:
        handle.write(content)
    return {"bytes": len(content), "created": not existed,
            "path": relative_to(root, path)}


def op_edit_file(root, request):
    path = resolve(root, request["path"], True)
    with open(path, "rb") as handle:
        raw = handle.read(MAX_READ_BYTES + 1)
    if len(raw) > MAX_READ_BYTES:
        raise Failure("file is too large to edit safely")
    if b"\x00" in raw[:8192]:
        raise Failure("this is a binary file")
    text = raw.decode("utf-8")
    old = request["old_string"]
    new = request["new_string"]
    occurrences = text.count(old)
    if occurrences == 0:
        raise Failure("old_string was not found in the file")
    if occurrences > 1 and not request.get("replace_all"):
        raise Failure(
            "old_string appears %d times; pass replace_all or include more "
            "surrounding context to make it unique" % occurrences)
    updated = text.replace(old, new) if request.get("replace_all") else text.replace(old, new, 1)
    with open(path, "wb") as handle:
        handle.write(updated.encode("utf-8"))
    return {"replacements": occurrences if request.get("replace_all") else 1,
            "path": relative_to(root, path)}


def describe(entry_path, name):
    try:
        stat_result = os.lstat(entry_path)
    except OSError:
        return {"name": name, "kind": "unreadable"}
    if os.path.islink(entry_path):
        # A link is reported as a link with its target: this project's venvs and
        # sequence databases are built out of them, and flattening them away is
        # the failure the mount already has.
        try:
            target = os.readlink(entry_path)
        except OSError:
            target = "?"
        return {"name": name, "kind": "symlink", "target": target,
                "dangling": not os.path.exists(entry_path)}
    if os.path.isdir(entry_path):
        return {"name": name, "kind": "directory"}
    return {"name": name, "kind": "file", "size": stat_result.st_size}


def op_list_directory(root, request):
    path = resolve(root, request.get("path") or "", True)
    if not os.path.isdir(path):
        raise Failure("this is not a directory")
    names = sorted(os.listdir(path))
    truncated = len(names) > MAX_DIRECTORY_ENTRIES
    entries = [describe(os.path.join(path, name), name)
               for name in names[:MAX_DIRECTORY_ENTRIES]]
    return {"path": relative_to(root, path), "entries": entries,
            "truncated": truncated}


def op_glob(root, request):
    pattern = request["pattern"].lstrip("/")
    matches = []
    for current, directories, files in os.walk(root, followlinks=False):
        directories[:] = [d for d in directories if d not in (".git", "__pycache__")]
        for name in directories + files:
            candidate = os.path.relpath(os.path.join(current, name), root)
            if fnmatch.fnmatch(candidate, pattern) or fnmatch.fnmatch(name, pattern):
                matches.append(candidate)
                if len(matches) > MAX_MATCHES:
                    return {"matches": sorted(matches[:MAX_MATCHES]), "truncated": True}
    return {"matches": sorted(matches), "truncated": False}


def op_grep(root, request):
    import re
    where = resolve(root, request.get("path") or "", True)
    flags = re.IGNORECASE if request.get("case_insensitive") else 0
    try:
        expression = re.compile(request["pattern"], flags)
    except re.error as error:
        raise Failure("invalid pattern: %s" % error)
    name_filter = request.get("glob")
    limit = max(min(int(request.get("max_results") or MAX_MATCHES), MAX_MATCHES), 1)
    results = []

    def scan(file_path):
        try:
            with open(file_path, "rb") as handle:
                raw = handle.read(MAX_READ_BYTES)
        except OSError:
            return
        if b"\x00" in raw[:8192]:
            return
        for number, line in enumerate(raw.decode("utf-8", errors="replace").splitlines(), 1):
            if expression.search(line):
                results.append({"path": relative_to(root, file_path),
                                "line": number, "text": line[:500]})
                if len(results) >= limit:
                    return

    if os.path.isfile(where):
        scan(where)
    else:
        for current, directories, files in os.walk(where, followlinks=False):
            directories[:] = [d for d in directories if d not in (".git", "__pycache__")]
            for name in files:
                if name_filter and not fnmatch.fnmatch(name, name_filter):
                    continue
                scan(os.path.join(current, name))
                if len(results) >= limit:
                    return {"matches": results, "truncated": True}
    return {"matches": results, "truncated": len(results) >= limit}


def op_stat(root, request):
    # Not followed: reporting that an entry is a link, and where it points, is
    # the point of the tool. Reading through it is what resolve() guards.
    path = resolve(root, request.get("path") or "", True, follow=False)
    information = describe(path, os.path.basename(path) or ".")
    try:
        stat_result = os.lstat(path)
        information["size"] = stat_result.st_size
        information["mode"] = oct(stat_result.st_mode & 0o7777)
        information["modified"] = int(stat_result.st_mtime)
    except OSError:
        pass
    information["path"] = relative_to(root, path)
    return information


OPERATIONS = {
    "read_file": op_read_file, "write_file": op_write_file,
    "edit_file": op_edit_file, "list_directory": op_list_directory,
    "glob": op_glob, "grep": op_grep, "stat": op_stat,
}

request = json.loads(sys.stdin.read())
MAX_READ_BYTES = request["limits"]["read_bytes"]
MAX_READ_LINES = request["limits"]["read_lines"]
MAX_DIRECTORY_ENTRIES = request["limits"]["directory_entries"]
MAX_MATCHES = request["limits"]["matches"]
try:
    project_root = os.path.realpath(request["root"], strict=True)
except OSError:
    print(json.dumps({"error": "the remote project directory is unreadable: "
                      + request["root"]}))
    sys.exit(0)
if not os.path.isdir(project_root):
    print(json.dumps({"error": "the remote project directory is not a directory"}))
    sys.exit(0)
try:
    print(json.dumps({"result": OPERATIONS[request["operation"]](project_root, request)}))
except Failure as failure:
    print(json.dumps({"error": str(failure)}))
except KeyError as missing:
    print(json.dumps({"error": "missing argument: %s" % missing}))
except OSError as error:
    print(json.dumps({"error": "%s: %s" % (type(error).__name__, error)}))
'''


def die(message: str, code: int = 2) -> NoReturn:
    print(f"afws-fs-mcp: {message}", file=sys.stderr)
    raise SystemExit(code)


def normalize_relative(value: str) -> str:
    """A project-relative path with nothing in it that could climb out.

    This is the cheap half of the boundary. It rejects what can be rejected
    without asking the remote -- absolute paths, '..', empty segments -- so an
    obvious escape never becomes an SSH round trip. It is not the boundary
    itself: a symlink out of the project passes every check here, and only the
    remote can see that. Both halves are required.
    """
    if value in ("", ".", "./"):
        return ""
    if any(ord(character) < 32 for character in value):
        die("a path may not contain control characters")
    path = PurePosixPath(value)
    if path.is_absolute():
        raise ToolFailure("path must be relative to the project directory: " + value)
    for part in path.parts:
        if part in ("..", ""):
            raise ToolFailure("path must not climb out of the project directory: " + value)
    return path.as_posix()


class ToolFailure(Exception):
    """A tool could not do what was asked. Reported to the caller, not fatal."""


class RemoteProject:
    """The workstation's project directory, reached over the shared connection."""

    def __init__(self) -> None:
        self.ssh_host = os.environ.get("AFWS_SSH_HOST", "")
        self.remote_dir = os.environ.get("AFWS_REMOTE_DIR", "")
        self.control_path = os.environ.get("AFWS_CONTROL_PATH", "")
        self.control_persist = os.environ.get("AFWS_CONTROL_PERSIST", "600")
        if not self.ssh_host or not self.remote_dir:
            die("AFWS_SSH_HOST and AFWS_REMOTE_DIR must be set; run this from a "
                "work-station session")
        if not self.remote_dir.startswith("/"):
            die(f"AFWS_REMOTE_DIR must be absolute: {self.remote_dir}")

    def ssh_command(self) -> list[str]:
        command = ["ssh", "-o", "BatchMode=yes"]
        if self.control_path:
            # ControlMaster=auto rather than -S: -S only ever reuses, so once
            # the shared connection has gone nothing recreates it and every
            # later call pays a full handshake against a socket that is not
            # coming back. This server outlives the launcher that authenticated
            # it, so it has to be able to open the replacement itself.
            command += [
                "-o", "ControlMaster=auto",
                "-o", f"ControlPath={self.control_path}",
                "-o", f"ControlPersist={self.control_persist}",
            ]
        return command + [self.ssh_host]

    def run(self, operation: str, **arguments: Any) -> dict[str, Any]:
        request = {
            "operation": operation,
            "root": self.remote_dir,
            "limits": {
                "read_bytes": MAX_READ_BYTES, "read_lines": MAX_READ_LINES,
                "directory_entries": MAX_DIRECTORY_ENTRIES, "matches": MAX_MATCHES,
            },
        }
        request.update(arguments)
        # The worker reaches the remote as one quoted argument, so the remote
        # shell never parses anything that came from a caller. The request goes
        # over stdin for the same reason, and because a file's contents have no
        # business on a command line.
        remote_command = "exec python3 -c " + shlex.quote(REMOTE_WORKER)
        try:
            completed = subprocess.run(
                self.ssh_command() + [remote_command],
                input=json.dumps(request), text=True, capture_output=True,
                timeout=SSH_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            raise ToolFailure(
                f"the workstation did not answer within {SSH_TIMEOUT_SECONDS}s")
        except OSError as error:
            raise ToolFailure(f"could not run ssh: {error}")

        if completed.returncode == 255:
            raise ToolFailure(
                "ssh could not reach " + self.ssh_host + ". The shared "
                "connection may be gone and this session may have nowhere to "
                "authenticate from.\n" + completed.stderr.strip())
        if completed.returncode != EXIT_OK:
            detail = completed.stderr.strip() or completed.stdout.strip()
            if "python3" in detail and "not found" in detail:
                raise ToolFailure(
                    "python3 is not installed on " + self.ssh_host + ", which "
                    "this server needs in order to confine every operation to "
                    "the project directory. Use afws-run for file work on this "
                    "host instead.")
            raise ToolFailure(f"the workstation reported: {detail}")
        try:
            answer = json.loads(completed.stdout)
        except ValueError:
            raise ToolFailure(
                "the workstation did not answer with JSON. A login shell that "
                "prints something on connect is the usual cause.\n"
                + completed.stdout[:500])
        if "error" in answer:
            raise ToolFailure(answer["error"])
        return answer["result"]


# --- tool definitions -----------------------------------------------------
# The descriptions are what the agent reads to decide between these and a shell
# command, so each says what it is for rather than only what it does.

RELATIVE_PATH = {
    "type": "string",
    "description": "Path relative to the remote project directory.",
}

TOOLS: list[dict[str, Any]] = [
    {
        "name": "read_file",
        "description": "Read a text file from the remote project, with line "
                       "numbers. Use this instead of 'afws-run cat'.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": RELATIVE_PATH,
                "offset": {"type": "integer", "description": "First line to read (1-based)."},
                "limit": {"type": "integer", "description": f"Lines to read (max {MAX_READ_LINES})."},
            },
            "required": ["path"],
        },
    },
    {
        "name": "write_file",
        "description": "Create or overwrite a file in the remote project.",
        "inputSchema": {
            "type": "object",
            "properties": {"path": RELATIVE_PATH, "content": {"type": "string"}},
            "required": ["path", "content"],
        },
    },
    {
        "name": "edit_file",
        "description": "Replace an exact string in a remote file. Fails unless "
                       "old_string appears exactly once, or replace_all is set.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": RELATIVE_PATH,
                "old_string": {"type": "string"},
                "new_string": {"type": "string"},
                "replace_all": {"type": "boolean"},
            },
            "required": ["path", "old_string", "new_string"],
        },
    },
    {
        "name": "list_directory",
        "description": "List a remote directory. Symlinks are reported as "
                       "symlinks with their targets rather than hidden.",
        "inputSchema": {
            "type": "object",
            "properties": {"path": RELATIVE_PATH},
        },
    },
    {
        "name": "glob",
        "description": "Find files in the remote project by shell pattern, "
                       "for example '**/*.py' or 'figure*/*.png'.",
        "inputSchema": {
            "type": "object",
            "properties": {"pattern": {"type": "string"}},
            "required": ["pattern"],
        },
    },
    {
        "name": "grep",
        "description": "Search remote file contents with a regular expression. "
                       "Returns matching lines with their line numbers.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "pattern": {"type": "string", "description": "Python regular expression."},
                "path": RELATIVE_PATH,
                "glob": {"type": "string", "description": "Only search file names matching this pattern."},
                "case_insensitive": {"type": "boolean"},
                "max_results": {"type": "integer"},
            },
            "required": ["pattern"],
        },
    },
    {
        "name": "stat",
        "description": "Report the kind, size and modification time of a remote "
                       "path, following symlinks only inside the project.",
        "inputSchema": {
            "type": "object",
            "properties": {"path": RELATIVE_PATH},
            "required": ["path"],
        },
    },
]


def render(name: str, result: dict[str, Any]) -> str:
    """Tool output as the agent will read it, not as JSON it has to re-parse."""
    if name == "read_file":
        width = len(str(result["first_line"] + len(result["lines"])))
        body = "\n".join(
            f"{number:>{width}}\t{line}"
            for number, line in enumerate(result["lines"], result["first_line"]))
        if result["truncated"]:
            body += (f"\n\n[{result['total_lines']} lines total; showing from "
                     f"line {result['first_line']}]")
        return body or "[empty file]"
    if name == "list_directory":
        if not result["entries"]:
            return f"{result['path']}: empty"
        lines = [result["path"] + ":"]
        for entry in result["entries"]:
            if entry["kind"] == "directory":
                lines.append(f"  {entry['name']}/")
            elif entry["kind"] == "symlink":
                marker = " (dangling)" if entry["dangling"] else ""
                lines.append(f"  {entry['name']} -> {entry['target']}{marker}")
            elif entry["kind"] == "file":
                lines.append(f"  {entry['name']}  {entry['size']}")
            else:
                lines.append(f"  {entry['name']}  [unreadable]")
        if result["truncated"]:
            lines.append(f"  [more than {MAX_DIRECTORY_ENTRIES} entries; truncated]")
        return "\n".join(lines)
    if name == "glob":
        if not result["matches"]:
            return "no matches"
        body = "\n".join(result["matches"])
        return body + ("\n[truncated]" if result["truncated"] else "")
    if name == "grep":
        if not result["matches"]:
            return "no matches"
        body = "\n".join(f"{match['path']}:{match['line']}:{match['text']}"
                         for match in result["matches"])
        return body + ("\n[truncated]" if result["truncated"] else "")
    if name == "write_file":
        verb = "Created" if result["created"] else "Wrote"
        return f"{verb} {result['path']} ({result['bytes']} bytes)"
    if name == "edit_file":
        return f"Edited {result['path']} ({result['replacements']} replacement(s))"
    return json.dumps(result, indent=2)


def call_tool(project: RemoteProject, name: str, arguments: dict[str, Any]) -> str:
    if name not in {tool["name"] for tool in TOOLS}:
        raise ToolFailure(f"no such tool: {name}")

    if name == "write_file":
        content = arguments.get("content", "")
        encoded = content.encode("utf-8")
        if len(encoded) > MAX_WRITE_BYTES:
            raise ToolFailure(
                f"content is {len(encoded)} bytes; the limit is {MAX_WRITE_BYTES}. "
                "Use afws-push to transfer a file this size.")
        result = project.run("write_file",
                             path=normalize_relative(arguments.get("path", "")),
                             content=base64.b64encode(encoded).decode("ascii"))
        return render(name, result)

    forwarded: dict[str, Any] = {}
    if "path" in arguments or name in ("read_file", "edit_file", "stat"):
        forwarded["path"] = normalize_relative(arguments.get("path", ""))
    for key in ("offset", "limit", "old_string", "new_string", "replace_all",
                "pattern", "glob", "case_insensitive", "max_results"):
        if key in arguments:
            forwarded[key] = arguments[key]
    return render(name, project.run(name, **forwarded))


# --- JSON-RPC over stdio --------------------------------------------------
# Newline-delimited JSON, which is what the MCP stdio transport is. The SDK
# would add a dependency on both this Mac and every machine this repository is
# installed on, for a protocol whose three methods fit here.

def respond(message: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def handle(project: RemoteProject, message: dict[str, Any]) -> dict[str, Any] | None:
    method = message.get("method")
    identifier = message.get("id")

    # A notification has no id and takes no reply, whatever it asks for.
    if identifier is None:
        return None

    if method == "initialize":
        return {
            "jsonrpc": "2.0", "id": identifier,
            "result": {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
                "instructions": (
                    f"Files on {project.ssh_host}:{project.remote_dir}. These "
                    "tools reach the project directly over SSH; there is no "
                    "local copy, and paths are relative to that directory."),
            },
        }
    if method == "ping":
        return {"jsonrpc": "2.0", "id": identifier, "result": {}}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": identifier, "result": {"tools": TOOLS}}
    if method == "tools/call":
        parameters = message.get("params") or {}
        name = parameters.get("name", "")
        arguments = parameters.get("arguments") or {}
        try:
            text = call_tool(project, name, arguments)
        except ToolFailure as failure:
            # A tool that could not do the job is an answer, not a protocol
            # error: the agent should read it and try something else.
            return {"jsonrpc": "2.0", "id": identifier,
                    "result": {"content": [{"type": "text", "text": str(failure)}],
                               "isError": True}}
        return {"jsonrpc": "2.0", "id": identifier,
                "result": {"content": [{"type": "text", "text": text}]}}

    return {"jsonrpc": "2.0", "id": identifier,
            "error": {"code": -32601, "message": f"method not found: {method}"}}


def main() -> None:
    project = RemoteProject()
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            respond({"jsonrpc": "2.0", "id": None,
                     "error": {"code": -32700, "message": "parse error"}})
            continue
        reply = handle(project, message)
        if reply is not None:
            respond(reply)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except BrokenPipeError:
        # The client closed the transport; there is nothing to report it to.
        pass
