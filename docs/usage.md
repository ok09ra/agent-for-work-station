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

`codexfws` takes the same two target arguments. Explicitly allow a local input directory before them when Codex needs local material:

```zsh
claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY --model MODEL_NAME
codexfws --allow-local-files /LOCAL/DATA SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
codexfws --resume SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
```

## What happens at startup

1. It opens one shared, authenticated SSH connection to the host, prompting here if the host asks for a password or a key passphrase.
2. `codexfws` brings up a Finder/VS Code rclone NFS view, reusing a healthy one that is already there. `claudefws` mounts nothing unless given `--view`.
3. Both agents start in an empty local control directory and treat the remote project as authoritative.
4. It picks an unused session name of the form `fws-HOST-PROJECT-N` for Claude
   or `cx-HOST-PROJECT-N` for Codex.
5. It records the session in `~/.afws/sessions/` so other sessions can see what this one is working on.
6. The agent performs every project operation through `afws-run`, which starts in the remote project directory.

Codex also attaches four local lifecycle hooks. Review and trust them when
Codex prompts. They record the thread ID, status, and short task label after
the first turn so another session can address this one.

Both agents run on the Mac. Project reads, edits, Git, tests and builds all run
on the SSH host. The work continues if a view drops, because no view is a data
path: the empty control directory is the agent's own working directory, which is
what keeps its file tools off a local copy that could be stale or incomplete.

An interactive session sets its terminal title to `[session] project | agent-for-work-station`; for example, `AFWS_SESSION_NAME=ngof-1` produces `[ngof-1] ngof | agent-for-work-station`. Set `AFWS_NO_TERMINAL_TITLE=1` at launch when the terminal should manage its own title. Background sessions do not change it.

Additional sessions reuse a healthy view at the same mount point, including an existing SSHFS mount. They do not remount it or require existing sessions to exit just to switch to rclone. A new view uses rclone when no mount is present. A launcher refuses to mount anything on a path that already carries a filesystem: stacking a second one there hides the first rather than replacing it, and releasing the top layer afterwards only uncovers the next.

## Control a session from another device

In an interactive `claudefws` session, enter `/remote-control` (or `/rc`) in
Claude's prompt. It makes that conversation available through Claude on the web
or mobile app. Enter the command again to check its status or disconnect.

Inside a `codexfws` session, ask Codex to turn Remote Control off or report its
status, or run:

```zsh
afws-remote status   # check the connection
afws-remote off      # disable Remote Control; keep local sessions running
```

`on` and `pair` widen access to a daemon shared by this whole Mac, so they ask
for confirmation on the controlling terminal and refuse when there is none. An
agent session has none, which is the point: run these two in your own shell.

```zsh
afws-remote on       # enable the shared Codex app server on this Mac
afws-remote pair     # print a short-lived device pairing code
```

Codex Remote Control applies to other Codex sessions on this Mac and stays set
after this session exits. Pair only a trusted device. Codex may ask for approval
to run the helper outside its workspace sandbox. An open Codex CLI conversation
can remain locked to its terminal. Enabling Remote Control does not hand off
that live conversation; `codexfws` currently has no safe session handoff.

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

For Codex, opt in to local material and stream it directly into the remote project when needed:

```zsh
codexfws --allow-local-files ~/Documents/input SSH_CONFIG_HOST /remote/project
afws-push ~/Documents/input data
```

This creates `/remote/project/data/input`, without an intermediate copy. Sources outside the allowed local roots and destinations outside the remote project are rejected.

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
of: its registry record, any view it started when no other session is using it,
the JupyterLab `afws-lab` started when no other session needs it, and the shared
SSH connection when no other session is on that host. A view another session is
still using is kept, and so is any mount outside `~/afws-mounts`, which the
launchers did not create.

Interactive sessions also start a detached watchdog. If a `claudefws` or
`codexfws` launcher is killed outright or crashes, the watchdog waits for any
surviving agent process, then performs the same last-user checks and cleanup.
It never unmounts a workspace another registered session is using.

A background Claude session has no launcher watchdog and leaves any view it
started in place. A watchdog can also fail to clean up when it is killed too or when macOS
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

To keep a view after the session ends, for example because you are about to
start another session on it, set `AFWS_KEEP_MOUNT=1` for that launch.

## Reading the project: JupyterLab

A view is for looking at file names; `afws-lab` is for reading content. It runs
JupyterLab on the workstation, inside a `tmux` session of its own, and forwards
it to a local port:

```zsh
afws-lab                    # start, or repair and reuse the one already running
afws-lab --force            # rebuild even a layer whose state is undetermined
afws-lab status             # per-layer health, and the next step for the broken one
afws-lab open               # open it in the browser
afws-lab list               # every lab, and the sessions using each
afws-lab stop
afws-lab stop --orphaned    # stop the labs no live session is using
afws-lab -n                 # print what would change, change nothing
```

Because the server runs on the workstation, it reads the project as the
workstation has it: symlinks resolve, images and PDFs render, notebooks run
against the remote kernel, and Markdown renders with its images in place. A
mount that is slow, stale or absent has no bearing on it.

One lab serves every session on the same host and remote directory — the same
sharing rule a view follows — and it is released when the last of those sessions
exits. `start` is also the repair path: it checks the `tmux` session, the server
process, the forwarded port and the HTTP endpoint in turn, and rebuilds only the
layers that are actually broken. A dropped connection therefore costs a
reconnect rather than a restart, and open notebooks keep their state.

Two details matter on a shared machine. The port is not fixed: JupyterLab picks
a free one and `afws-lab` reads it back, so two people cannot collide. And the
token is never passed on the command line, because `ps` is readable by other
users on most systems; it is read from the server's own runtime file instead.

`afws-lab` needs JupyterLab on the workstation, invoked as `python3 -m
jupyterlab`. A distribution's `jupyter` command is often the classic notebook
package without JupyterLab in it, so the check is deliberately for the module
rather than for a command called `jupyter`.

## Structured file tools without a mount: the MCP server

`lib/afws-fs-mcp.py` is a stdio MCP server that runs on this Mac and reaches the
remote project over the session's shared SSH connection. It gives an agent
`read_file`, `write_file`, `edit_file`, `list_directory`, `glob`, `grep` and
`stat` — the structured operations that would otherwise be lost when the project
is only reachable as shell output.

It reads `AFWS_SSH_HOST`, `AFWS_REMOTE_DIR`, and optionally `AFWS_CONTROL_PATH`
and `AFWS_CONTROL_PERSIST`, all of which a session already exports. It is not
wired into the launchers, so point Claude Code at it explicitly:

```zsh
claude --mcp-config '{"mcpServers":{"afws-fs":{"command":"python3",
  "args":["'"$HOME"'/.local/lib/afws-fs-mcp.py"]}}}'
```

Every path is confined to `AFWS_REMOTE_DIR`. The check happens on the remote
after the path is resolved, not as a string test here, because a path can leave
the project through a symlink that no amount of local checking would reveal.
`stat` is the one operation that does not follow a link: it reports the link and
its target instead, so a `venv` whose `bin/python3` points outside the project
is still visible for what it is.

## Preview without making changes

Use dry-run mode to print the planned operation without mounting anything, writing to the registry, or starting the agent:

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
| `AFWS_NO_AGENT_TEAMS` | Leave Claude Code's experimental Agent Teams disabled for this launch |
| `AFWS_SESSION_NAME` | Use this session name instead of a generated one |
| `AFWS_REMOTE_LOCK_DIR` | Remote lock root (default: `~/.afws-locks`) |
| `AFWS_NO_CONTROL_MASTER` | Set to any value to authenticate separately for every connection |
| `AFWS_KEEP_MOUNT` | Set to any value to leave the Finder/VS Code view in place when the session ends |
| `AFWS_VISIBILITY_MOUNT` | Set to any value to mount the Finder/VS Code view by default (`claudefws` only; `--no-view` overrides it) |
| `AFWS_NO_SHELL_MARKER` | Set to any value to stop labelling locally-run shell commands |
| `AFWS_ADD_DIR` | Extra local directories the session may read, colon-separated (`claudefws` only) |
| `AFWS_REMOTE_ASSUME_YES` | Skip the terminal confirmation `afws-remote on` and `pair` require. For your own scripts, not for getting an agent session past the check |
| `AFWS_CODEX_TIGHTEN` | Set to any value to deny sandboxed Codex commands `~/.ssh`, `~/.codex`, `~/.claude` and the work-station registry. Reading the rest of the machine stays open, and `afws-run` escalates out of the sandbox so it is unaffected (`codexfws` only) |
| `AFWS_CODEX_AUTO_REVIEW` | Set to any value to route Codex approval requests to its own reviewing agent instead of deciding them in-session (`codexfws` only) |
| `AFWS_KEEP_CONTROL_MASTER` | Set to any value to keep the shared connection open after the last session exits |
| `AFWS_CONTROL_PERSIST` | Seconds a shared SSH connection survives without use (default: 600, or 28800 with `AFWS_KEEP_CONTROL_MASTER`) |
| `AFWS_PROBE_TIMEOUT_SECONDS` | Seconds an existing mount is given to answer its first read (default: 20) |
| `AFWS_LOCK_TTL` | Seconds after which a lock is reported as stale (default: 7200) |

Inside a running session the launcher also exports `AFWS_SSH_HOST`, `AFWS_REMOTE_DIR`, and `AFWS_LOCAL_WORKSPACE`, which is how `afws-run` and `afws-lock` can be used without repeating the host.

To give a session a different permission mode, set the variable for that launch only. The accepted values are the ones Claude Code accepts: `acceptEdits`, `auto`, `bypassPermissions`, `manual`, `dontAsk`, and `plan`. An unrecognised value is rejected before anything is mounted.

`claudefws` enables Claude Code Agent Teams and a project-shared native task
list by default. Set `AFWS_NO_AGENT_TEAMS=1` when a policy or compatibility
issue requires the experimental feature to remain off. AFWS organization,
peer delivery, and lifecycle hooks continue to work without Agent Teams.

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
