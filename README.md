# Agent for Work Station

[日本語](README.ja.md)

`agent-for-work-station` is a small macOS wrapper for using a coding agent with
a project that lives on a remote workstation. It supports two agents from one
installation:

```zsh
claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY   # Claude Code
codexfws  SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY   # Codex CLI
```

- The agent runs on your Mac. Only the project is remote, mounted with SSHFS,
  and only environment-dependent commands are sent to the workstation. Nothing
  has to be installed on the workstation, which matters when it is shared.
- One authenticated SSH connection per host is opened once and reused by the
  mount and by every remote command, so a host that asks for a password asks
  once.
- Sessions on the same Mac are registered, see each other, and take turns on a
  GPU or a shared build directory instead of colliding.
- The mount and the connection are released when the last session using them
  exits.
- No real IP addresses, usernames, passwords, or project paths are stored in
  this repository. The supported client operating system is macOS.

## Quick setup

On a clean Mac, prepare the following in order:

1. Install the latest stable release from the [official macFUSE website](https://macfuse.github.io/).
2. Install the macOS SSHFS package linked from the [official macFUSE SSHFS page](https://github.com/macfuse/macfuse/wiki/File-Systems-%E2%80%90-SSHFS).
3. Install at least one agent. Both are optional individually; `afws-doctor`
   reports which launcher is usable.

   ```zsh
   curl -fsSL https://claude.ai/install.sh | bash      # Claude Code
   claude auth login
   curl -fsSL https://chatgpt.com/codex/install.sh | sh  # Codex CLI
   ```

4. Run the installer from the repository root.

   ```zsh
   ./scripts/install.sh
   exec zsh -l
   afws-doctor
   ```

5. Add a host alias to your local `~/.ssh/config`. Keep real values outside this
   repository; use the [fictional SSH configuration example](examples/ssh-config.example)
   as a template.
6. Start a session. With no arguments either launcher prompts for the SSH host
   alias and the remote project directory.

   ```zsh
   claudefws
   ```

For SSH authentication, use SSH keys and the macOS Keychain rather than saving a
password in a file.

## Installed commands

| Command | Purpose |
| --- | --- |
| `claudefws` | Mount the remote project and start a Claude Code session on it. |
| `codexfws` | The same, for Codex CLI. |
| `afws-run` | Run one command, or a piped script, on the remote host. |
| `afws-peers` | List the sessions on this Mac and the host and directory each works on. |
| `afws-lock` | Claim an exclusive remote resource so two sessions do not collide. |
| `afws-umount` | Release a mount left behind by a background or killed session. |
| `afws-doctor` | Check that the prerequisites are installed and usable. |
| `afws-shell` | Labels locally-run shell commands `[mac]`; used by `claudefws`, not run by hand. |

The plumbing commands are shared: there is one `afws-run`, not one per agent,
and `afws-peers` lists the sessions of both. `lib/afws-common.zsh` holds the
logic they share and is installed next to them, in `../lib`.

## Two agents on one workstation

Both launchers reach the workstation the same way, so a Claude session and a
Codex session on the same host and directory **share one mount and one SSH
connection**, and appear side by side:

```zsh
afws-peers
```

```
SESSION                    AGENT   KIND         STATUS   SSH HOST            REMOTE DIRECTORY
fws-workstation-project-1  claude  interactive  busy     workstation         /remote/project
cx-workstation-project-1   codex   interactive  -        workstation         /remote/project
```

They differ in what the agent itself exposes: a Claude session can be messaged
by name and reports a status, a Codex session cannot and does not, because Codex
CLI offers no launch-time session name and no machine-readable session listing.
[What each agent supports](docs/agents.md) sets out the whole difference and why.

## What this is good for

**A workstation you would rather not install an agent on.** Shared machines,
machines holding sensitive data, machines you do not administer. The agent's
credentials, permission rules and history stay on your Mac, and nothing
accumulates on the workstation — no allowlist growing for months, no background
process left behind by a session that ended.

**Local material and remote compute in one session.** Papers and notes on your
Mac, the project and the GPU on the workstation. `AFWS_ADD_DIR` brings the local
directories into the same session, so reading a paper and running the job that
follows from it happen in one conversation instead of two with a copy in between.

**Several workstations from one place.** One Mac, one configuration, one session
history. `afws-peers` lists every session across every host.

**Several sessions on one workstation.** They share one mount and one
authenticated connection, `afws-lock` serialises the GPU or a shared build
directory between them, and Claude sessions can ask each other what they found.

**A machine you cannot install on at all** — no permission, no outbound network
for the agent to sign in with, a policy that forbids it.

**Authoring with your own toolchain.** Your editor, your Python tooling, your IDE
integration stay local; only the parts that need the remote environment go over.

## What this is not good for

**Work that is mostly file traffic.** SSHFS pays a network round trip per
operation, so a large `grep`, a full build or `git status` over a big tree is
slower than it would be on the machine itself. Send those through `afws-run`
instead, or run the agent natively.

**A machine that is yours alone and that you administer.** Installing the agent
there is simpler and faster, and there is no shared state to keep off it.

**Data that must not reach a model.** Mounting changes nothing here: a file the
agent reads is a file the model is shown, wherever the agent runs. The answer is
not to mount it.

**Restricting what the agent may do on the workstation.** `afws-run` is an
unrestricted remote shell as your SSH user, so the mount scopes convenience, not
authority. That boundary belongs in `authorized_keys` on the workstation, with a
separate key for the agent and a forced command; this repository does not set it
up. [Security](docs/security.md) says what does and does not hold.

**Anything but macOS on the client side.**

## Documentation

| Topic | English | 日本語 |
| --- | --- | --- |
| What each agent supports | [Agents](docs/agents.md) | [エージェント](docs/agents.ja.md) |
| macOS installation | [Install on macOS](docs/install-macos.md) | [macOSセットアップ](docs/install-macos.ja.md) |
| Usage | [Usage](docs/usage.md) | [使い方](docs/usage.ja.md) |
| Multiple sessions | [Multiple sessions](docs/sessions.md) | [複数セッション](docs/sessions.ja.md) |
| Security | [Security](docs/security.md) | [セキュリティ](docs/security.ja.md) |
| Troubleshooting | [Troubleshooting](docs/troubleshooting.md) | [トラブルシューティング](docs/troubleshooting.ja.md) |

## Upgrading from the separate claudefws and codexfws

This repository replaces two earlier ones, and the names changed. There are no
compatibility aliases.

| Before | Now |
| --- | --- |
| `claudefws-run`, `codexfws-run` | `afws-run` |
| `claudefws-peers`, `claudefws-lock`, `claudefws-umount` | `afws-peers`, `afws-lock`, `afws-umount` |
| `claudefws-doctor`, `codexfws-doctor` | `afws-doctor` |
| `ws-run` | removed; use `afws-run -- COMMAND` |
| `CLAUDEFWS_*`, `CODEXFWS_*` | `AFWS_*` |
| `~/claudefws-mounts`, `~/codexfws-mounts` | `~/afws-mounts` |
| `~/.claudefws`, `~/.codexfws` | `~/.afws` |

Migrate in this order. The installer deletes nothing; it lists what is left over.

1. Exit any running session, which releases its mount and connection.
2. Release what remains: `claudefws-umount --orphaned`, and check
   `mount | grep macfuse` for anything under `~/codexfws-mounts` to `umount`.
3. Remove the old commands from `~/.local/bin` and the old `~/.claudefws` and
   `~/.codexfws` state directories.
4. Run `./scripts/install.sh`.

## Development checks

```zsh
./scripts/test.sh
./scripts/prepublish-check.sh
```

`test.sh` runs entirely against a throwaway registry and a text file standing in
for the mount table; it never opens an SSH connection, never mounts a
filesystem, and never starts an agent.

`prepublish-check.sh` scans the publishable tree for private-key material,
common token formats, IP address literals, personal home-directory paths, likely
assigned passwords, and names left over from before the merge.

## Repository status

The installer, doctor, and tests never add a Git remote, create a commit, push
code, or create a release. Repository publication is a separate, explicit
operation.
