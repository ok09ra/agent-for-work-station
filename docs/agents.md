# What each agent supports

[日本語](agents.ja.md) · [README](../README.md)

One installation provides two launchers. They share everything about reaching
the workstation — the mount, the shared SSH connection, the registry, the locks
— and differ only in the agent they start and in what that agent exposes.

| | `claudefws` (Claude Code) | `codexfws` (Codex CLI) |
| --- | --- | --- |
| Mount, shared SSH connection, release on exit | yes | yes |
| `afws-run`, `afws-lock`, `afws-remount`, `afws-umount` | yes | yes |
| Listed in `afws-peers` with its host and directory | yes | yes |
| Session name the agent itself knows | yes, via `--name` | yes, via launcher instructions |
| Status column in `afws-peers` | native `busy` / `idle` / `waiting` | hook-derived `busy` / `idle` |
| Messaged by name from another session | yes, `SendMessage` from Claude | yes, `afws-message` to Codex |
| Locally-run shell commands labelled `[local]` | yes | no |
| Background session (`--bg`) | yes | no |
| Extra local directories (`AFWS_ADD_DIR`) | yes | yes |

`AFWS_ADD_DIR` is in the table as supported by both because it behaves the same
way from the outside, though the two agents need different things said to them:
Claude Code scopes its file tools to the working directory and takes extra
directories with `--add-dir`, while Codex already reads outside its workspace and
needs those directories added as writable roots in its sandbox. The launchers
translate; a caller sets one variable.

The two do not need it for the same reason, and Claude Code barely needs it at
all. Reading, creating and editing a path outside the workspace were tested
directly under `claudefws` and all work without it, so there it only decides
whether skills and commands in that directory are loaded. Under `codexfws` it is
how a local directory becomes writable, since Codex confines writes to the
workspace and settles that at launch — that part is inferred from its sandbox
profile rather than tested.

The remaining differences follow from the CLIs, measured against Codex CLI
0.156.1:

- **No launch-time session name.** Codex CLI has no flag that names a session.
  The launcher gives the agent its `cx-HOST-PROJECT-N` registry name in its
  instructions, and a lifecycle hook associates that name with the Codex thread
  UUID after the first turn begins.
- **No machine-readable session listing.** `codex agents` is an interactive
  browser with no JSON output. Codex liveness therefore comes from the launcher
  process; hooks supply `busy` and `idle` state plus a short activity label.
  Claude status comes from `claude agents --json`.
- **Different messaging paths.** `afws-message` resolves a live registry name
  to the hooked Codex thread UUID and calls `codex queue`. An idle session
  starts a turn; a busy session processes the queued message after its current
  turn. Claude-to-Claude still uses `ListAgents` and `SendMessage`. There is no
  external CLI path here for Codex-to-Claude messages.
- **No shell wrapper.** Claude Code runs shell commands through
  `CLAUDE_CODE_SHELL_PREFIX`, which is how `[local]` gets attached. Codex CLI has
  no equivalent, so in a Codex session nothing marks a command as having run on
  the Mac. The session instructions say so in words instead.

## What this means in practice

A Codex session participates fully in everything that protects the workstation:
it shares one mount and one authenticated connection with any other session on
the same host, it takes and respects `afws-lock`, and it releases what it was
the last user of when it exits. A Claude session on the same workstation can see
it in `afws-peers` and avoid its directory.

A Codex session can be asked a question by name after its first turn. You can
also describe its work rather than its name: the sending agent checks
`afws-peers --json` and resolves a unique match from the activity label, host,
and directory. Ambiguous matches require clarification. This peer lookup is
on demand; hooks do not put the session list into the model's context.

## Mixing the two

Nothing stops a Claude session and a Codex session from working on the same
workstation, and on the same directory. They share the mount, so they are
looking at the same files through the same SSHFS connection, and `afws-lock`
serialises the GPU between them. Codex can receive queued messages from either
agent, but cannot use this tool to message a Claude recipient. Shared-file edits
still need coordination and locks where appropriate.

See [Multiple sessions](sessions.md) for the coordination model itself.
