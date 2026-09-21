# Usage

[日本語](usage.ja.md) · [README](../README.md)

## Basic launch

The shortest and safest way to start is the interactive mode with no arguments:

```zsh
claudefws
```

To skip the prompts, pass an SSH configuration alias and the remote project's absolute path:

```zsh
claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
```

`codexfws` takes exactly the same two arguments. Append any additional agent arguments after them:

```zsh
claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY --model MODEL_NAME
```

## What happens at startup

1. The launcher looks for an existing SSHFS mount that covers the selected host and remote directory.
2. It reuses that mount when found, or creates a new mount under the user's home directory.
3. It opens one shared, authenticated SSH connection to the host, prompting here if the host asks for a password or a key passphrase.
4. It picks an unused session name of the form `fws-HOST-PROJECT-N`.
5. It records the session in `~/.afws/sessions/` so other sessions can see what this one is working on.
6. It starts the agent in the mount, with instructions for working against a remote host. `claudefws` passes the session name and `--permission-mode auto`; `codexfws` passes `--sandbox workspace-write` and `--ask-for-approval on-request`.

The agent runs locally and inspects and edits files through the mounted workspace. Python, tests, builds, GPU checks, and other remote-environment operations run on the SSH host.

## Run a remote command manually

Use the normal argument form:

```zsh
afws-run SSH_CONFIG_HOST --cwd REMOTE_ABSOLUTE_DIRECTORY -- nvidia-smi
```

Inside a session started by either launcher, the host and remote directory are already in the environment, so everything you give is the remote command:

```zsh
afws-run nvidia-smi
afws-run python train.py
```

That is short enough to type after Claude Code's `!`, which is the point: `!afws-run nvidia-smi` reaches the workstation where `!nvidia-smi` would run on the Mac. A leading `--` still works, and naming a host explicitly still addresses that host even from inside a session.

You can also send a script through standard input:

```zsh
printf '%s\n' 'pwd' 'git status --short' |
  afws-run SSH_CONFIG_HOST --cwd REMOTE_ABSOLUTE_DIRECTORY
```

Standard-input mode runs the supplied script with `bash -s` in the selected remote directory. It can therefore run arbitrary Bash code with the permissions of the configured SSH user. The `--cwd` value sets the initial directory; it is not a remote sandbox, so a script can access other paths available to that user. To use another installed shell explicitly, pass it as the command:

```zsh
afws-run SSH_CONFIG_HOST --cwd REMOTE_ABSOLUTE_DIRECTORY -- \
  zsh -lc 'print -r -- $ZSH_VERSION'
```

An argument containing a newline is quoted in zsh's form, which the remote
login shell only understands if it is bash or zsh. Pipe a script in instead when
an argument would contain one.

Standard output and standard error return directly to the current Terminal, so both you and Claude can inspect the result.

## Typing a remote command yourself

Claude Code's `!` escape runs in the session's own shell, which is on the Mac.
The workspace is an SSHFS mount, so **paths are remote but execution is local**:

```zsh
!ls                  # remote files, listed by the Mac's ls — fine
!nvidia-smi          # runs on the Mac. No GPU here, so it just fails
!python train.py     # runs on the Mac, against remote files, in the wrong
                     # interpreter and the wrong environment — and it does not fail
```

The third line is the dangerous one. `nvcc` and `conda` are usually absent from a
Mac and fail loudly, but `python`, `git`, `make` and `gcc` are present and will
quietly do the wrong thing.

Because that is easy to miss, a `claudefws` session labels every command it runs here. A `codexfws` session cannot: Codex CLI has no shell wrapper to hang the label on, so there nothing marks a command as local. See [what each agent supports](agents.md).

```
!echo works        → [local] works
!python train.py   → [local] /Library/Frameworks/Python.framework/.../python3
!nvidia-smi        → [local] zsh:1: command not found: nvidia-smi
                     [local] not found on this Mac. for HOST, use: afws-run -- <command>
!afws-run nvidia-smi → [remote] NVIDIA-SMI ...
```

`[local]` says the command ran on this Mac; `[remote]` says it ran on the
workstation. A command that mentions `afws-run` anywhere is left to `afws-run`
to label, so it reads as one answer rather than two.

That last part is a trade-off worth knowing: in `python prep.py && afws-run
train` the local half goes unlabelled. What stays covered is the mistake the
labelling is for -- a command that never mentions the workstation and quietly
runs here anyway. Those are always labelled `[local]`.

The labels go to standard error, so they never mix into a command's output, and
nothing is blocked — a command that belongs on the workstation still runs here,
it just says so. The "not found on this Mac" line appears only when the command
does not exist on the Mac at all. Set `AFWS_NO_SHELL_MARKER=1` for a launch to
turn the labelling off; `AFWS_MARKER` and `AFWS_REMOTE_MARKER` change the two
words themselves.

`afws-run` is the short form for running something on the workstation instead:

```zsh
!afws-run -- nvidia-smi
!afws-run -- python train.py
!afws-run -- sh -c 'nvidia-smi | wc -l'
```

Every argument is part of the remote command, so no `--` is needed. Shell
metacharacters are passed through literally rather than interpreted on the
remote host, which is why the pipeline above is wrapped in `sh -c`. A `|` typed
after `!` is interpreted by the local shell, so `!afws-run -- nvidia-smi | wc
-l` runs `nvidia-smi` on the workstation and `wc` on the Mac.

The remote directory and the mounted local workspace are two paths to the same
project tree. Project reads, searches, edits, file management, and Git therefore
use ordinary local tools on the mount. Sessions are instructed never to create
another clone, checkout, or Git worktree unless the user explicitly asks.

Inside a mounted session, `afws-run` reinforces that division by rejecting
common direct inspection, filesystem, and Git commands. Multiline shell
commands, standard-input shell scripts, and common wrappers such as `env` are
inspected too, rejecting obvious project scans, Git operations, and file
mutations; a bare remote shell is also rejected. The diagnostic is one line so
a corrected tool call costs little context. This is a workflow guard, not a
security sandbox: arbitrary programs can still read and write files, and static
inspection cannot understand every shell expression. When the user explicitly
requests a remote-side file operation, use the escape hatch:

```zsh
afws-run --allow-remote-files COMMAND ARG...
```

This applies to what you type too. Claude and Codex receive the same instruction
to reserve `afws-run` for programs that need the workstation's environment.

## Local material and remote compute in one session

The project is remote, but what you are working *from* is often local: papers, a
notes directory, a scratch analysis. Usually nothing has to be arranged. Both
sides are ordinary paths on this Mac, shell commands are not scoped to the
workspace, and the file tools take an absolute path outside it, so naming the
path in the conversation is enough.

`AFWS_ADD_DIR` does less than its name suggests. Under `codexfws` it is how a
local directory becomes writable at all, because Codex confines writes to the
workspace and settles that at launch. Under `claudefws` reading, creating and
editing an outside path already work, so it only affects whether skills and
commands in that directory are loaded. It takes a colon-separated list:

```zsh
AFWS_ADD_DIR=~/Documents/papers:~/Documents/notes \
  claudefws SSH_CONFIG_HOST /remote/project
```

The launcher lists them under `also:` and passes them to Claude Code with
`--add-dir`. They are validated before anything is mounted, so a typo does not
cost a mount. The session is told they are local reference material: read from
them, write into the remote project.

Under `codexfws` it is the only way to write outside the workspace, because
Codex's sandbox is decided when the session starts rather than during it.

Both launchers take the same variable and report the same thing. What they pass
to the agent differs, because the two agents ask for it differently, but that is
the launcher's business.

## Work with several sessions

List the sessions on this Mac and what each one is attached to:

```zsh
afws-peers
afws-peers --host SSH_CONFIG_HOST
afws-peers --same
```

Claim an exclusive remote resource before using it, and release it afterwards:

```zsh
afws-lock acquire gpu0
afws-lock status
afws-lock release gpu0
```

Start a session that keeps running in the background and can be messaged by the others:

```zsh
claudefws --bg SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY "watch the training job and report failures"
```

[Multiple sessions](sessions.md) describes the whole model, including how one session sends a message to another.

## Ending a session

When a session exits, the launcher releases what that session was the last user
of: its registry record, the SSHFS mount when no other session is working inside
it, and the shared SSH connection when no other session is on that host. A mount
that another session is still using is kept, and so is any mount outside
`~/afws-mounts`, which claudefws did not create.

Interactive sessions also start a detached watchdog. If a `claudefws` or
`codexfws` launcher is killed outright or crashes, the watchdog waits for any
surviving agent process, then performs the same last-user checks and cleanup.
It never unmounts a workspace another registered session is using.

A background Claude session has no launcher watchdog and leaves its mount in
place. A watchdog can also fail to clean up when it is killed too or when macOS
refuses the unmount. Release leftovers explicitly:

```zsh
afws-umount --list                                  # mounts and who uses each
afws-umount --orphaned                              # release the unused ones
afws-umount SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
afws-umount --orphaned --force                      # when a plain umount is refused
```

If a live session's mount disconnects, repair it in place instead of moving
project file work to the remote shell:

```zsh
afws-remount                                        # current session's mount
afws-remount SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
```

Both launchers perform the same check at startup and automatically repair a
mount that returns a confirmed read error before starting the agent. A healthy
mount is a no-op unless `--force` is explicit. A confirmed failed mount is recreated at the same
mount point, including when the session uses a subdirectory of a broader mount.
A probe timeout is ambiguous—it may only be a slow cold mount—so replacement in
that case requires the user's approval and `afws-remount --force`. The same
explicit option repairs a mount whose shallow read succeeds but whose contents
are known to be wrong. A replacement uses a fresh independent SSH connection by
default, so it cannot inherit a hung SFTP channel from the launcher's long-lived
shared connection. Use `--reuse-connection` only when that shared connection is
known to be healthy and password authentication requires it; use
`--fresh-connection` when no old mount remains to identify as a replacement.
If plain `umount` hangs, recovery stops only the SSHFS process for that mount and
continues with a bounded forced detach. If a live
agent retains the old working-directory handle and still reports `ENXIO`, exit
and relaunch that agent after the repair. A mount shared by more than one live
session may be repaired automatically once a read error confirms it is already
unusable to all of them. Replacing a responding or merely timed-out shared mount
is refused unless the user explicitly approves interrupting all sessions with
`--force-shared`.

To keep the mount after the session ends, for example because you are about to
start another session on it, set `AFWS_KEEP_MOUNT=1` for that launch.

## Preview without making changes

Use dry-run mode to print the planned operation without mounting SSHFS, writing to the registry, or starting the agent:

```zsh
claudefws --dry-run SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
afws-remount --dry-run SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
```

The remote runner and the lock support the same pattern:

```zsh
afws-run SSH_CONFIG_HOST --cwd REMOTE_ABSOLUTE_DIRECTORY --dry-run -- nvidia-smi
afws-lock acquire gpu0 --host SSH_CONFIG_HOST --dry-run
```

`afws-lock --dry-run` prints both the SSH command and the script that would run on the remote host, so the whole effect can be reviewed before any connection is made.

## Environment variables

| Variable | Effect |
| --- | --- |
| `AFWS_MOUNT_BASE` | Root for new mounts (default: `~/afws-mounts`) |
| `AFWS_STATE_DIR` | Session registry root (default: `~/.afws`) |
| `AFWS_PERMISSION_MODE` | Claude Code permission mode, `claudefws` only (default: `auto`) |
| `AFWS_SESSION_NAME` | Use this session name instead of a generated one |
| `AFWS_REMOTE_LOCK_DIR` | Remote lock root (default: `~/.afws-locks`) |
| `AFWS_NO_CONTROL_MASTER` | Set to any value to authenticate separately for every connection |
| `AFWS_KEEP_MOUNT` | Set to any value to leave the mount in place when the session ends |
| `AFWS_NO_SHELL_MARKER` | Set to any value to stop labelling locally-run shell commands |
| `AFWS_ALLOW_HOME_MOUNT` | Set to any value to silence the home-directory warning |
| `AFWS_ADD_DIR` | Extra local directories the session may read, colon-separated (`claudefws` only) |
| `AFWS_KEEP_CONTROL_MASTER` | Set to any value to keep the shared connection open after the last session exits |
| `AFWS_CONTROL_PERSIST` | Seconds a shared SSH connection survives without use (default: 600, or 28800 with `AFWS_KEEP_CONTROL_MASTER`) |
| `AFWS_PROBE_TIMEOUT_SECONDS` | Seconds an existing mount is given to answer its first read (default: 20) |
| `AFWS_LOCK_TTL` | Seconds after which a lock is reported as stale (default: 7200) |

Inside a running session the launcher also exports `AFWS_SSH_HOST`, `AFWS_REMOTE_DIR`, and `AFWS_LOCAL_WORKSPACE`, which is how `afws-run` and `afws-lock` can be used without repeating the host.

To give a session a different permission mode, set the variable for that launch only. The accepted values are the ones Claude Code accepts: `acceptEdits`, `auto`, `bypassPermissions`, `manual`, `dontAsk`, and `plan`. An unrecognised value is rejected before anything is mounted.

```zsh
AFWS_PERMISSION_MODE=manual claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
```

## The shared SSH connection

The mount and every `afws-run` and `afws-lock` call go through one
multiplexed SSH connection, whose control socket lives at
`~/.afws/control/HOST.sock`. This matters for two reasons.

A host that asks for a password or a key passphrase asks once, in the terminal
where you started `claudefws`. Nothing afterwards can prompt: the mount is
detached from the terminal, and a session's remote commands have no one to ask.

Reusing the connection also removes the TCP handshake and authentication from
every remote command, which is noticeable when a session runs many of them.

Close it when you are finished with a host:

```zsh
ssh -S ~/.afws/control/HOST.sock -O exit HOST
```

The connection is closed when the last session using that host exits, so the
next launch authenticates again. On a host that authenticates by password that
is a password per launch, and `afws-run` used outside a session then asks once
per command. `AFWS_KEEP_CONTROL_MASTER=1` keeps the connection open instead,
leaving `AFWS_CONTROL_PERSIST` as the only thing that bounds its life; see
[security.md](security.md) for what that gives up.

`afws-run` and `afws-lock` still work with no shared connection to reuse: they
open their own, which on a key-authenticated host simply works. Where it cannot
work -- no connection to reuse, and no terminal to answer a password prompt on,
which is the situation inside a session -- ssh is given `BatchMode` so it fails
at once instead of hunting for an askpass helper, and the failure says how to
reopen the shared connection. A fallback that worked is not reported.

To connect separately every time instead, set `AFWS_NO_CONTROL_MASTER=1`.
Key-based authentication is then effectively required, and nothing is reported
about connections that were never meant to be shared.

## Limitations

- The remote filesystem root cannot be selected; choose a project directory.
- Remote paths containing `.`, `..`, or repeated `/` segments are rejected.
- SSH configuration aliases may contain only letters, numbers, periods, underscores, and hyphens.
- Remote package installation, shell configuration changes, and system changes are not automatically authorized.
- SSHFS operates over the network, so workloads involving many small files are usually faster when run remotely.
- The session registry and peer messaging are local to one Mac. Sessions on two different Macs cannot see each other through this tool.

## If something goes wrong

Read [Troubleshooting](troubleshooting.md) and run `afws-doctor` first.
