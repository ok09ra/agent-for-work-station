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

## Installation

macOS only. Nothing is installed on the workstation.

**1. macFUSE and SSHFS.** Install the latest stable release from the
[macFUSE website](https://macfuse.github.io/), then the macOS SSHFS package
linked from the [macFUSE SSHFS page](https://github.com/macfuse/macfuse/wiki/File-Systems-%E2%80%90-SSHFS).
macOS may ask you to allow macFUSE in System Settings; follow the official
instructions and restart if prompted.

```zsh
command -v sshfs && sshfs --version
```

**2. At least one agent.** Install the one you use, or both.

```zsh
curl -fsSL https://claude.ai/install.sh | bash        # Claude Code
claude auth login

curl -fsSL https://chatgpt.com/codex/install.sh | sh  # Codex CLI
codex login
```

**3. The commands.** From the repository root:

```zsh
./scripts/install.sh
exec zsh -l
```

This copies eight commands into `~/.local/bin` and the shared library into
`~/.local/lib`, and adds that directory to your login `PATH` if it is not there
already. It deletes nothing; if an earlier `claudefws` or `codexfws` install is
present it lists what is left over.

**4. An SSH host alias.** In your local `~/.ssh/config`, using the
[fictional example](examples/ssh-config.example) as a template. Real values stay
out of this repository.

```
Host my-workstation
  HostName host.example.invalid
  User remote-user
  AddKeysToAgent yes
  UseKeychain yes
  ServerAliveInterval 30
  ServerAliveCountMax 6
```

Use SSH keys and the macOS Keychain rather than a password in a file. Test the
alias before going further:

```zsh
ssh my-workstation
```

**5. Check.**

```zsh
afws-doctor                  # prerequisites
afws-doctor my-workstation   # and your SSH configuration
```

It is ready when every line reports `[OK]`. `afws-doctor` also tells you which
launcher is usable, so an agent you did not install is a note rather than a
failure.

## How to Use

**Start a session** on a remote project directory. Use the project, not the home
directory — the launcher warns if it looks like a home.

```zsh
claudefws my-workstation /remote/path/to/project   # Claude Code
codexfws  my-workstation /remote/path/to/project   # Codex CLI
```

With no arguments either launcher asks for the two values, which keeps them out
of your shell history. A password or key passphrase is asked for once, here.

**Bring local material in** — papers, notes, a scratch analysis. Both launchers
take the same variable.

```zsh
AFWS_ADD_DIR=~/Documents/papers:~/Documents/notes \
  claudefws my-workstation /remote/path/to/project
```

Inside the session the remote project and those directories are all ordinary
local paths, so moving something between them is a plain `cp`.

**Run something on the workstation.** Inside a session the host and directory
come from the environment:

```zsh
afws-run -- nvidia-smi
afws-run -- python train.py
afws-run -- sh -c 'ls *.log | wc -l'     # shell syntax needs a remote shell
printf 'set -eu\npytest -q\n' | afws-run   # a whole script
```

Claude Code's `!` escape runs on your Mac, not on the workstation. A `claudefws`
session labels those `[mac]` so it is visible; prefix with `afws-run --` when you
meant the workstation.

**See who else is working**, and take turns on a GPU or a shared build
directory:

```zsh
afws-peers                  # every session, both agents, with host and directory
afws-lock acquire gpu0      # claims it, or names the holder
afws-lock release gpu0
```

**Ending a session** releases its mount and its shared SSH connection once no
other session is using them. A background session, or one that was killed,
leaves its mount behind:

```zsh
afws-umount --list          # mounts and connections, and who uses each
afws-umount --orphaned      # release the ones nobody is using
```

**Preview anything** without mounting, connecting or starting an agent:

```zsh
claudefws --dry-run my-workstation /remote/path/to/project
afws-run my-workstation --cwd /remote/path --dry-run -- nvidia-smi
```

[Usage](docs/usage.md) covers the rest, including every environment variable.

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

## Operations that carry risk

The agent runs as your SSH user on the workstation, so nothing here grants more
than your own account already has. What these change is how much of your account
is exposed, for how long, and how easily a mistake reaches it.

| Operation | Why it matters | Instead |
| --- | --- | --- |
| Mounting a home directory | `~/.ssh`, stored credentials and every other project end up inside the workspace, and a `.claude/settings.json` there becomes this session's project settings | Mount the project directory. The launcher warns when the workspace looks like a home |
| Piping a script to `afws-run`, or `afws-run -- sh -c …` | An unrestricted remote shell as your SSH user. `--cwd` is a starting directory, not a sandbox | Review it before approving. Prefer one named command over a script when you can |
| Leaving a shared SSH connection open | A pre-authenticated channel any process of your user can reuse without a password. A session killed with `SIGKILL` never closes it | It expires after `AFWS_CONTROL_PERSIST` seconds (600). `afws-umount --orphaned` closes one nothing is using; `afws-doctor` reports one |
| `AFWS_PERMISSION_MODE=bypassPermissions` | Every write in a session lands on the remote host, so there is no local-only blast radius to fall back on | `manual` or `plan` for sensitive work; `auto` is the default |
| An `allow` rule with a `*` before the end of the command | `*` spans spaces, so the rule also approves options inserted at that point. A rule containing `;` or a pipe approves a whole compound command | Name the exact value, or put `*` only after the subcommand. Never allowlist a compound command |
| `AFWS_ADD_DIR` pointing at something sensitive | Those directories become readable, and for Codex writable, by the session — and anything read reaches the model | Name the specific reference directories. Never `~`, `~/.ssh` or `~/Library` |
| Reading data that must not leave the machine | Mounting changes nothing: a file the agent reads is a file the model is shown | Do not mount it |
| `afws-lock steal` | Takes a lock someone else holds, which is how two jobs end up on one GPU | Ask the holder first. A lock held for hours is normal for a long job |
| `afws-umount --force` | `diskutil unmount force` on a mount another session may be writing in | Check `afws-umount --list` first; force only when the holder is really gone |
| Connecting as a privileged remote account | Passwordless sudo, a container-runtime group, or group-writable shared data widen what a mistake can destroy — check `id` and the permissions of any shared path | Use a least-privilege account |
| Installing an agent on the workstation as well | Two diverging sets of permission rules and two versions, and the set nobody looks at is the one that grows | `afws-doctor HOST` reports it when a connection is open |
| Bridging to Claude Desktop with `claude mcp serve` | Hands Desktop arbitrary shell access on your Mac, and none of this tool's scoping, labelling or cleanup applies | Bring local directories into the session with `AFWS_ADD_DIR` instead |
| Committing real values to this repository | Host aliases, addresses, usernames and remote paths are not secrets, but they do not belong here | `./scripts/prepublish-check.sh`, and read `git diff --cached` |

[Security](docs/security.md) explains what this architecture does and does not
protect, and why the boundary that actually holds belongs in `authorized_keys` on
the workstation.

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
