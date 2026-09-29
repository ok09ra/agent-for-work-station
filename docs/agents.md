# What each agent supports

[日本語](agents.ja.md) · [README](../README.md)

One installation provides two launchers. They share everything about reaching
the workstation — `afws-run`, the shared SSH connection, the registry, the
locks — and differ only in the agent they start and in what that agent exposes.
Both are remote-first: the remote tree is authoritative and neither reads the
project through a mount.

| | `claudefws` (Claude Code) | `codexfws` (Codex CLI) |
| --- | --- | --- |
| Remote-first: the project is reached through `afws-run` | yes | yes |
| Shared SSH connection, release on exit | yes | yes |
| Finder/VS Code view | opt-in, `--view` | yes, on every launch |
| `afws-lab` (JupyterLab on the workstation) | yes | yes |
| `afws-run`, `afws-lock`, `afws-remount`, `afws-umount` | yes | yes |
| Listed in `afws-peers` with its host and directory | yes | yes |
| Session name the agent itself knows | yes, via `--name` | yes, via launcher instructions |
| Status column in `afws-peers` | native `busy` / `idle` / `waiting` | hook-derived `busy` / `idle` |
| Messaged by name from another independent session | yes, durable `afws-message` inbox | yes, `afws-message` via `codex queue` |
| Native multi-agent execution | experimental Agent Teams, enabled by `claudefws` | subagents managed by Codex |
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
- **Different messaging adapters.** `afws-message` resolves a live registry
  name. For Codex it calls `codex queue` with the hooked thread UUID. For Claude
  it writes an owner-only durable inbox that a lifecycle hook injects on session
  start, user input, or stop. Native `ListAgents` and `SendMessage` are reserved
  for teammates in the current Claude Agent Team, not arbitrary independent
  Claude sessions.
- **No shell wrapper.** Claude Code runs shell commands through
  `CLAUDE_CODE_SHELL_PREFIX`, which is how `[local]` gets attached. Codex CLI has
  no equivalent, so in a Codex session nothing marks a command as having run on
  the Mac. The session instructions say so in words instead.

## What this means in practice

A Codex session participates fully in everything that protects the workstation:
it shares one authenticated connection with any other session on the same host,
and one Finder/VS Code view and one JupyterLab with any session on the same
remote directory, it takes and respects `afws-lock`, and it releases what it was
the last user of when it exits. A Claude session on the same workstation can see
it in `afws-peers` and avoid its directory.

A Codex session can be asked a question by name after its first turn. You can
also describe its work rather than its name: the sending agent checks
`afws-peers --json` and resolves a unique match from the activity label, host,
and directory. Ambiguous matches require clarification. This peer lookup is
on demand; hooks do not put the session list into the model's context.

## Mixing the two

Nothing stops a Claude session and a Codex session from working on the same
workstation, and on the same directory. Both reach it through `afws-run`, so
they are acting on the same remote tree directly rather than through a
filesystem layer, they share a view and a lab if either started one, and
`afws-lock` serialises the GPU between them. Either agent can queue a direct message for
the other through `afws-message`. Claude delivery is hook-driven rather than an
immediate external interrupt, so queue receipt is not acknowledgement.
Shared-file edits still need coordination and locks where appropriate.

See [Multiple sessions](sessions.md) for the coordination model itself.
