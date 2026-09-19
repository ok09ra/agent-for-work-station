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

Append any additional Claude Code arguments after those values:

```zsh
claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY --model MODEL_NAME
```

## What happens at startup

1. The launcher looks for an existing SSHFS mount that covers the selected host and remote directory.
2. It reuses that mount when found, or creates a new mount under the user's home directory.
3. It opens one shared, authenticated SSH connection to the host, prompting here if the host asks for a password or a key passphrase.
4. It picks an unused session name of the form `fws-HOST-PROJECT-N`.
5. It records the session in `~/.claudefws/sessions/` so other sessions can see what this one is working on.
6. It starts Claude Code in the mount with `--permission-mode auto`, the session name, and instructions for working against a remote host.

The local Claude Code process inspects and edits files through the mounted workspace. Python, tests, builds, GPU checks, and other remote-environment operations run on the SSH host.

## Run a remote command manually

Use the normal argument form:

```zsh
claudefws-run SSH_CONFIG_HOST --cwd REMOTE_ABSOLUTE_DIRECTORY -- nvidia-smi
```

Inside a session started by `claudefws`, the host and remote directory are already in the environment, so both can be omitted:

```zsh
claudefws-run -- nvidia-smi
```

You can also send a script through standard input:

```zsh
printf '%s\n' 'pwd' 'git status --short' |
  claudefws-run SSH_CONFIG_HOST --cwd REMOTE_ABSOLUTE_DIRECTORY
```

Standard-input mode runs the supplied script with `bash -s` in the selected remote directory. It can therefore run arbitrary Bash code with the permissions of the configured SSH user. The `--cwd` value sets the initial directory; it is not a remote sandbox, so a script can access other paths available to that user. To use another installed shell explicitly, pass it as the command:

```zsh
claudefws-run SSH_CONFIG_HOST --cwd REMOTE_ABSOLUTE_DIRECTORY -- \
  zsh -lc 'print -r -- $ZSH_VERSION'
```

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

Because that is easy to miss, a session labels every command it runs here:

```
!echo works        → [mac] works
!python train.py   → [mac] /Library/Frameworks/Python.framework/.../python3
!nvidia-smi        → [mac] zsh:1: command not found: nvidia-smi
                     [mac] not found on this Mac. for HOST, use: ws-run <command>
```

The `[mac]` label goes to standard error, so it never mixes into a command's
output, and nothing is blocked — a command that belongs on the workstation still
runs here, it just says so. The second line appears only when the command does
not exist on the Mac at all. Set `CLAUDEFWS_NO_SHELL_MARKER=1` for a launch to
turn the labelling off.

`ws-run` is the short form for running something on the workstation instead:

```zsh
!ws-run nvidia-smi
!ws-run python train.py
!ws-run sh -c 'ls *.log | wc -l'
```

Every argument is part of the remote command, so no `--` is needed. Shell
metacharacters are passed through literally rather than interpreted on the
remote host, which is why the pipeline above is wrapped in `sh -c`. A `|` typed
after `!` is interpreted by the local shell, so `!ws-run ls | wc -l` runs `ls` on
the workstation and `wc` on the Mac.

This applies to what you type. Claude itself is instructed to use
`claudefws-run` for anything that depends on the remote environment.

## Work with several sessions

List the sessions on this Mac and what each one is attached to:

```zsh
claudefws-peers
claudefws-peers --host SSH_CONFIG_HOST
claudefws-peers --same
```

Claim an exclusive remote resource before using it, and release it afterwards:

```zsh
claudefws-lock acquire gpu0
claudefws-lock status
claudefws-lock release gpu0
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
`~/claudefws-mounts`, which claudefws did not create.

Two things are not covered automatically. A background session has no launcher
process left to clean up after it, and a session killed outright (`kill -9`, a
crash, a closed lid) never runs its cleanup. For both, release the mount
explicitly:

```zsh
claudefws-umount --list                                  # mounts and who uses each
claudefws-umount --orphaned                              # release the unused ones
claudefws-umount SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
claudefws-umount --orphaned --force                      # when a plain umount is refused
```

To keep the mount after the session ends, for example because you are about to
start another session on it, set `CLAUDEFWS_KEEP_MOUNT=1` for that launch.

## Preview without making changes

Use dry-run mode to print the planned operation without mounting SSHFS, writing to the registry, or starting Claude Code:

```zsh
claudefws --dry-run SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
```

The remote runner and the lock support the same pattern:

```zsh
claudefws-run SSH_CONFIG_HOST --cwd REMOTE_ABSOLUTE_DIRECTORY --dry-run -- nvidia-smi
claudefws-lock acquire gpu0 --host SSH_CONFIG_HOST --dry-run
```

`claudefws-lock --dry-run` prints both the SSH command and the script that would run on the remote host, so the whole effect can be reviewed before any connection is made.

## Environment variables

| Variable | Effect |
| --- | --- |
| `CLAUDEFWS_MOUNT_BASE` | Root for new mounts (default: `~/claudefws-mounts`) |
| `CLAUDEFWS_STATE_DIR` | Session registry root (default: `~/.claudefws`) |
| `CLAUDEFWS_PERMISSION_MODE` | Claude Code permission mode (default: `auto`) |
| `CLAUDEFWS_SESSION_NAME` | Use this session name instead of a generated one |
| `CLAUDEFWS_REMOTE_LOCK_DIR` | Remote lock root (default: `~/.claudefws-locks`) |
| `CLAUDEFWS_NO_CONTROL_MASTER` | Set to any value to authenticate separately for every connection |
| `CLAUDEFWS_KEEP_MOUNT` | Set to any value to leave the mount in place when the session ends |
| `CLAUDEFWS_NO_SHELL_MARKER` | Set to any value to stop labelling locally-run shell commands |
| `CLAUDEFWS_LOCK_TTL` | Seconds after which a lock is reported as stale (default: 7200) |

Inside a running session the launcher also exports `CLAUDEFWS_SSH_HOST`, `CLAUDEFWS_REMOTE_DIR`, and `CLAUDEFWS_LOCAL_WORKSPACE`, which is how `claudefws-run` and `claudefws-lock` can be used without repeating the host.

To give a session a different permission mode, set the variable for that launch only. The accepted values are the ones Claude Code accepts: `acceptEdits`, `auto`, `bypassPermissions`, `manual`, `dontAsk`, and `plan`. An unrecognised value is rejected before anything is mounted.

```zsh
CLAUDEFWS_PERMISSION_MODE=manual claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
```

## The shared SSH connection

The mount and every `claudefws-run` and `claudefws-lock` call go through one
multiplexed SSH connection, whose control socket lives at
`~/.claudefws/control/HOST.sock`. This matters for two reasons.

A host that asks for a password or a key passphrase asks once, in the terminal
where you started `claudefws`. Nothing afterwards can prompt: the mount is
detached from the terminal, and a session's remote commands have no one to ask.

Reusing the connection also removes the TCP handshake and authentication from
every remote command, which is noticeable when a session runs many of them.

Close it when you are finished with a host:

```zsh
ssh -S ~/.claudefws/control/HOST.sock -O exit HOST
```

To connect separately every time instead, set `CLAUDEFWS_NO_CONTROL_MASTER=1`.
Key-based authentication is then effectively required.

## Limitations

- The remote filesystem root cannot be selected; choose a project directory.
- Remote paths containing `.`, `..`, or repeated `/` segments are rejected.
- SSH configuration aliases may contain only letters, numbers, periods, underscores, and hyphens.
- Remote package installation, shell configuration changes, and system changes are not automatically authorized.
- SSHFS operates over the network, so workloads involving many small files are usually faster when run remotely.
- The session registry and peer messaging are local to one Mac. Sessions on two different Macs cannot see each other through this tool.

## If something goes wrong

Read [Troubleshooting](troubleshooting.md) and run `claudefws-doctor` first.
