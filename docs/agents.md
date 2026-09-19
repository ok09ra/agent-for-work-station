# What each agent supports

[日本語](agents.ja.md) · [README](../README.md)

One installation provides two launchers. They share everything about reaching
the workstation — the mount, the shared SSH connection, the registry, the locks
— and differ only in the agent they start and in what that agent exposes.

| | `claudefws` (Claude Code) | `codexfws` (Codex CLI) |
| --- | --- | --- |
| Mount, shared SSH connection, release on exit | yes | yes |
| `afws-run`, `afws-lock`, `afws-umount` | yes | yes |
| Listed in `afws-peers` with its host and directory | yes | yes |
| Session name the agent itself knows | yes, via `--name` | no |
| Status column in `afws-peers` (`busy` / `idle` / `waiting`) | yes | no, shows `-` |
| Messaged by name from another session | yes, `SendMessage` | no |
| Locally-run shell commands labelled `[mac]` | yes | no |
| Background session (`--bg`) | yes | no |
| Extra local directories (`AFWS_ADD_DIR`) | yes | yes |

`AFWS_ADD_DIR` is in the table as supported by both because it behaves the same
way from the outside, though the two agents need different things said to them:
Claude Code scopes its file tools to the working directory and takes extra
directories with `--add-dir`, while Codex already reads outside its workspace and
needs those directories added as writable roots in its sandbox. The launchers
translate; a caller sets one variable.

Neither agent needs it merely to *read* a local directory — a shell command
reaches anything your account can, and Claude Code also takes `/add-dir` during a
session. The variable earns its place when the same directories are wanted every
time, or when writing outside the workspace is required, which under Codex can
only be decided at launch.

The remaining differences are not design choices. They follow from what each CLI offers,
measured against Codex CLI 0.154.0:

- **No launch-time session name.** Codex CLI has no flag that names a session,
  so the name in the registry is bookkeeping only: it identifies the session in
  `afws-peers` and as a lock holder, but Codex does not know it. Codex sessions
  are therefore named `cx-HOST-PROJECT-N` rather than `fws-…`, to make clear
  that the name is ours and not the agent's.
- **No machine-readable session listing.** `codex agents` is an interactive
  browser with no JSON output, so a Codex session's liveness is judged from the
  launcher process and no status can be reported. `claude agents --json` gives
  Claude Code's sessions an id, a pid and a status, which is what fills the
  status column.
- **No message addressed by name.** `codex queue --thread <uuid or exact name>
  --message TEXT` does exist, and would be the right mechanism, but without a
  way to set the name at launch there is nothing to address. When Codex CLI
  gains a name flag, this becomes a small change.
- **No shell wrapper.** Claude Code runs shell commands through
  `CLAUDE_CODE_SHELL_PREFIX`, which is how `[mac]` gets attached. Codex CLI has
  no equivalent, so in a Codex session nothing marks a command as having run on
  the Mac. The session instructions say so in words instead.

## What this means in practice

A Codex session participates fully in everything that protects the workstation:
it shares one mount and one authenticated connection with any other session on
the same host, it takes and respects `afws-lock`, and it releases what it was
the last user of when it exits. A Claude session on the same workstation can see
it in `afws-peers` and avoid its directory.

What a Codex session cannot do is be asked a question by another session. Two
Claude sessions can settle "is the 8B run finished?" between themselves; a Codex
session has to be asked by you.

## Mixing the two

Nothing stops a Claude session and a Codex session from working on the same
workstation, and on the same directory. They share the mount, so they are
looking at the same files through the same SSHFS connection, and `afws-lock`
serialises the GPU between them. The usual caution applies more strongly here
than between two Claude sessions: since they cannot talk to each other, split
the work by directory, or hold a lock, rather than relying on coordination.

See [Multiple sessions](sessions.md) for the coordination model itself.
