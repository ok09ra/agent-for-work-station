# Agent for Work Station

[日本語](README.ja.md)

Use Claude Code or Codex CLI on a project that lives on a remote workstation,
with the agent running on your Mac and nothing installed on the workstation.

```zsh
claudefws my-workstation /remote/path/to/project   # Claude Code
codexfws  my-workstation /remote/path/to/project   # Codex CLI
```

The project is mounted with SSHFS, so it is an ordinary local path. Commands that
need the remote environment — Python, tests, builds, GPU work — go over with
`afws-run`. One authenticated SSH connection per host is opened once and reused,
so a host that asks for a password asks once. Sessions on the same Mac are
registered, see each other, take turns on a GPU instead of colliding, and — for
Claude Code — can ask each other what they found. The
mount and the connection are released when the last session using them exits.

macOS client only. No real hostnames, addresses, usernames or paths are stored in
this repository.

## Who this is for

**You share a workstation with other people, and it holds data you are careful
with.** Other accounts are logged in; installing a coding agent there is a
decision that affects them. Run it on your Mac instead and nothing of yours
lands on the shared machine — no credentials, no permission rules accumulating
for months, no background process left behind by a session that ended. An agent
used natively on a shared box for half a year ends up with an allowlist nobody
reviews, applying to every later session on that machine.

**You do not administer the machine.** No permission to install, a policy that
forbids it, or no outbound network for an agent to sign in with. This needs
nothing on the workstation but `sshd` and a shell.

**What you read is local and what you compute is remote.** Papers, notes and a
scratch analysis on your Mac; the project and the GPU on the workstation. Both
are ordinary paths in one session, so reading a paper and running the job that
follows from it happen in one conversation rather than two with a copy in between.

**You work across more than one workstation.** One agent configuration, one
session history, and `afws-peers` showing every session on every host — instead of
an installation and a permission file per machine, each drifting from the others.

**You run several sessions against one machine.** They share one mount and one
authenticated connection, `afws-lock` keeps two of them off the same GPU, and
Claude sessions can ask each other what they found instead of rediscovering it.

Along the way: one password prompt per host rather than one per command, your own
editor and toolchain for authoring, and a mount and connection that release
themselves when the last session using them exits.

## Installation

**1. macFUSE and SSHFS.** The latest stable release from the
[macFUSE website](https://macfuse.github.io/), then the macOS SSHFS package from
the [macFUSE SSHFS page](https://github.com/macfuse/macfuse/wiki/File-Systems-%E2%80%90-SSHFS).
Allow macFUSE in System Settings if asked, and restart if prompted.

```zsh
sshfs --version
```

**2. At least one agent.** Either, or both.

```zsh
curl -fsSL https://claude.ai/install.sh | bash        # Claude Code
claude auth login

curl -fsSL https://chatgpt.com/codex/install.sh | sh  # Codex CLI
codex login
```

**3. This repository.** Anywhere you like.

```zsh
git clone https://github.com/ok09ra/agent-for-work-station.git ~/src/agent-for-work-station
cd ~/src/agent-for-work-station
```

**4. The commands on your `PATH`.** Either way works; each command finds the
shared library relative to itself.

*Point at the clone* — nothing is copied, and `git pull` updates everything:

```zsh
echo 'export PATH="$HOME/src/agent-for-work-station/bin:$PATH"' >> ~/.zprofile
exec zsh -l
```

*Or install a copy* into `~/.local/bin`, with the library next to it in
`~/.local/lib`:

```zsh
./scripts/install.sh
exec zsh -l
```

The installer adds `~/.local/bin` to your login `PATH` if it is not there
already, and deletes nothing — an earlier `claudefws` or `codexfws` install is
listed, not removed. Remember that a copy has to be reinstalled after a `git
pull`; pointing at the clone does not.

**5. An SSH host alias** in `~/.ssh/config`. Real values stay out of this
repository — the [example](examples/ssh-config.example) is fictional.

```
Host my-workstation
  HostName host.example.invalid
  User remote-user
  AddKeysToAgent yes
  UseKeychain yes
  ServerAliveInterval 30
  ServerAliveCountMax 6
```

Use SSH keys and the macOS Keychain, not a password in a file. Check the alias
works before going on: `ssh my-workstation`.

**6. Check.**

```zsh
afws-doctor                  # prerequisites
afws-doctor my-workstation   # and your SSH configuration
```

Ready when every line says `[OK]`. An agent you did not install is a note, not a
failure.

## How to Use

**Start a session** on a project directory — not the remote home, which would put
`~/.ssh`, stored credentials and every other project inside the workspace. The
launcher warns if the workspace looks like a home.

```zsh
claudefws my-workstation /remote/path/to/project
```

With no arguments it asks for both values, which keeps them out of your shell
history. A password or passphrase is asked for once, here.

**Run something on the workstation.** Inside a session the host and directory come
from the environment, so `afws-run` takes the command directly:

```zsh
afws-run nvidia-smi
afws-run python train.py
afws-run sh -c 'ls *.log | wc -l'            # shell syntax needs a remote shell
printf 'set -eu\npytest -q\n' | afws-run     # a whole script
```

This matters for what you type yourself. Claude Code's `!` runs on your Mac, so
`!nvidia-smi` fails here and `!python train.py` quietly uses the wrong
interpreter. A `claudefws` session labels everything it runs locally `[mac]` so
that is visible, and `afws-run` in front is the whole difference:

```
!nvidia-smi           → [mac] command not found
!afws-run nvidia-smi  → the workstation's GPU
```

Outside a session, name the host and directory:
`afws-run my-workstation --cwd /remote/path -- nvidia-smi`.

**Use local material** — papers, notes, a scratch analysis. Just name the path:

> Read ~/Documents/papers/method.md and compare it with what the pipeline here
> actually does.

Nothing has to be declared. Both sides are ordinary paths on this Mac, so moving
something between them is a plain `cp`, and the file tools read, create and edit
an absolute path outside the workspace as they would inside it.

**See who else is working**, and take turns on a GPU or a shared build directory:

```zsh
afws-peers                  # every session, both agents, with host and directory
afws-lock acquire gpu0      # claims it, or names the holder
afws-lock release gpu0
```

**Ask another session.** Each launch gets a name — `afws-peers` shows it — and a
Claude session can be reached by that name from another Claude session on the same
Mac. You do not run a command for this; you ask:

> Check afws-peers, then ask gpu-trainer whether the 8B run has finished and what
> the final loss was.

The session looks its peers up, sends the question, and reports the answer. It is
worth it when one session holds something the other would have to rediscover:
which checkpoint is current, why a test was disabled, what a failure looked like an
hour ago, whether a dataset finished converting. The session receiving the question answers from
what it actually ran, and a request arriving this way carries no authority — it is
asked to confirm anything destructive with you first.

There is no approval step on sending, so a session could message a peer without
being asked. Its instructions narrow that to three cases: you asked, a lock it
needs is held and it wants to ask the holder, or a peer is about to be affected by
something it is doing to shared state. It is told to send a question or what it
observed rather than file contents, and to tell you afterwards.

Give a session a name that says what it is doing when that helps:

```zsh
AFWS_SESSION_NAME=gpu-trainer claudefws my-workstation /remote/path/to/project
AFWS_SESSION_NAME=bug-1204    claudefws my-workstation /remote/path/to/project
```

Claude sessions only. A Codex session appears in `afws-peers` and takes locks, but
cannot be addressed, because Codex has no launch-time session name. Sessions on two
different Macs cannot reach each other either. [Multiple sessions](docs/sessions.md)
has the whole model.

**After a session,** its mount and connection are released once no other session
needs them. A background session, or one that was killed, leaves its mount:

```zsh
afws-umount --list          # mounts and connections, and who uses each
afws-umount --orphaned      # release the ones nobody is using
```

**Preview anything** without mounting, connecting or starting an agent:

```zsh
claudefws --dry-run my-workstation /remote/path/to/project
afws-run my-workstation --cwd /remote/path --dry-run -- nvidia-smi
```

[Usage](docs/usage.md) has the rest, including every environment variable.

## Commands

| Command | Purpose |
| --- | --- |
| `claudefws` | Mount the project and start a Claude Code session on it |
| `codexfws` | The same, for Codex CLI |
| `afws-run` | Run a command, or a piped script, on the workstation |
| `afws-peers` | Every session on this Mac, with the host and directory each works on |
| `afws-lock` | Claim an exclusive remote resource so two sessions do not collide |
| `afws-umount` | Release a mount or connection left behind |
| `afws-doctor` | Check the prerequisites |
| `afws-shell` | Labels local shell commands `[mac]`; used by `claudefws`, not run by hand |

The plumbing is shared: one `afws-run`, not one per agent, and `afws-peers` lists
the sessions of both. `lib/afws-common.zsh` holds what they have in common.

## Two agents, one workstation

A Claude session and a Codex session on the same host and directory share one
mount and one connection, and appear together:

```
SESSION                    AGENT   KIND         STATUS   SSH HOST      REMOTE DIRECTORY
fws-workstation-project-1  claude  interactive  busy     workstation   /remote/project
cx-workstation-project-1   codex   interactive  -        workstation   /remote/project
```

They differ in what each CLI exposes. A Claude session can be messaged by name and
reports a status; a Codex session cannot and does not, because Codex has no
launch-time session name and no machine-readable session listing.
[Agents](docs/agents.md) sets out every difference and the measurement behind it.

## When this is the wrong tool

- **Work that is mostly file traffic.** SSHFS pays a round trip per operation, so
  a large `grep`, a full build or `git status` over a big tree is slower than on
  the machine itself. Send those through `afws-run`, or run the agent natively.
- **A machine that is yours alone and that you administer.** Installing the agent
  there is simpler, and there is no shared state to keep off it.
- **Data that must not reach a model.** Mounting changes nothing: a file the agent
  reads is a file the model is shown, wherever the agent runs.
- **Restricting what the agent may do on the workstation.** `afws-run` is an
  unrestricted remote shell as your SSH user, so the mount scopes convenience, not
  authority. That boundary belongs in `authorized_keys` on the workstation, with a
  separate key and a forced command; this repository does not set it up.
- **Any client but macOS.**

## Operations that carry risk

The agent runs as your SSH user, so none of these grants more than your account
already has. What they change is how much of it is exposed, for how long, and how
easily a mistake reaches it.

| Operation | Why it matters | Instead |
| --- | --- | --- |
| Mounting a home directory | `~/.ssh`, credentials and every other project land in the workspace, and a `.claude/settings.json` there becomes this session's project settings | Mount the project directory; the launcher warns |
| Piping a script to `afws-run`, or `afws-run sh -c …` | An unrestricted remote shell as your SSH user; `--cwd` is a starting point, not a sandbox | Review before approving; prefer one named command |
| Leaving a shared connection open | A pre-authenticated channel any process of your user can reuse. A session killed with `SIGKILL` never closes it | It expires after `AFWS_CONTROL_PERSIST` seconds (600); `afws-umount --orphaned` closes one nothing uses |
| `AFWS_PERMISSION_MODE=bypassPermissions` | Every write lands on the remote host, so there is no local-only blast radius | `manual` or `plan` for sensitive work |
| An `allow` rule with `*` before the end of the command | `*` spans spaces, so options inserted there are approved too; a rule with `;` or a pipe approves a compound command | Name the exact value, or put `*` only after the subcommand |
| Reading data that must not leave the machine | A file the agent reads is shown to the model | Do not mount it |
| `afws-lock steal` | Takes a lock someone holds — how two jobs end up on one GPU | Ask the holder; hours-long locks are normal |
| `afws-umount --force` | Forces an unmount another session may be writing in | Check `afws-umount --list` first |
| Connecting as a privileged account | Passwordless sudo, a container-runtime group or group-writable shared data widen what a mistake destroys | Use a least-privilege account; check `id` |
| Installing an agent on the workstation too | Two diverging allowlists and two versions; the one nobody reads is the one that grows | `afws-doctor HOST` reports it |
| Bridging to Claude Desktop with `claude mcp serve` | Hands Desktop arbitrary shell access on your Mac, with none of this tool's scoping or cleanup | Name local paths in the session instead |
| A session messaging a peer on its own | No approval step: the peer is interrupted, your text enters its context, and its budget is spent | Instructions limit it to something you asked for, a lock found held, or a warning about shared state, and require it to tell you afterwards |
| Committing real values here | Host aliases and remote paths are not secrets but do not belong in the repository | `./scripts/prepublish-check.sh`, and read `git diff --cached` |

[Security](docs/security.md) explains what this architecture protects, what it
does not, and why the boundary that holds belongs on the workstation.

## Documentation

| Topic | English | 日本語 |
| --- | --- | --- |
| What each agent supports | [Agents](docs/agents.md) | [エージェント](docs/agents.ja.md) |
| macOS installation | [Install on macOS](docs/install-macos.md) | [macOSセットアップ](docs/install-macos.ja.md) |
| Usage | [Usage](docs/usage.md) | [使い方](docs/usage.ja.md) |
| Multiple sessions | [Multiple sessions](docs/sessions.md) | [複数セッション](docs/sessions.ja.md) |
| Security | [Security](docs/security.md) | [セキュリティ](docs/security.ja.md) |
| Troubleshooting | [Troubleshooting](docs/troubleshooting.md) | [トラブルシューティング](docs/troubleshooting.ja.md) |

## Coming from the separate claudefws and codexfws

This replaces two earlier repositories. Names changed and there are no
compatibility aliases: `claudefws-run` and `codexfws-run` became `afws-run`, the
other helpers became `afws-*`, `ws-run` is gone, `CLAUDEFWS_*` and `CODEXFWS_*`
became `AFWS_*`, and the mount and state directories became `~/afws-mounts` and
`~/.afws`.

Migrate in this order; the installer deletes nothing and lists what is left over.

1. Exit any running session, which releases its mount and connection.
2. Release what remains: `claudefws-umount --orphaned`, and check
   `mount | grep macfuse` for anything under `~/codexfws-mounts` to `umount`.
3. Remove the old commands from `~/.local/bin`, and `~/.claudefws` and
   `~/.codexfws`.
4. Run `./scripts/install.sh`.

## Development

```zsh
./scripts/test.sh
./scripts/prepublish-check.sh
```

`test.sh` runs against a throwaway registry and a text file standing in for the
mount table: no SSH connection, no mount, no agent. `prepublish-check.sh` scans
for private keys, token formats, IP literals, home-directory paths, likely
passwords, and names left over from before the merge.

The installer, doctor and tests never add a Git remote, commit, push, or create a
release.

## License

[MIT](LICENSE). Use it, change it, redistribute it, build something commercial on
it — keep the copyright notice and the licence text with it.

```
Copyright (c) 2026 Sota Okuda (ok09ra)
```
