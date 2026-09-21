# Troubleshooting

[日本語](troubleshooting.ja.md) · [README](../README.md)

Run diagnostics first:

```zsh
afws-doctor
```

## `command not found: claudefws` or `codexfws`

Open a new Terminal after running the installer, or reload the login shell:

```zsh
exec zsh -l
```

If the problem remains, run `./scripts/install.sh` again and check the displayed installation directory.

## `command not found: sshfs`

Install the macOS package from the [macFUSE SSHFS page](https://github.com/macfuse/macfuse/wiki/File-Systems-%E2%80%90-SSHFS), then reopen Terminal.

## macOS refuses to mount the project

Confirm that macFUSE has been allowed in macOS System Settings. The exact screens vary by macOS and Mac model, so follow the official [macFUSE Getting Started guide](https://github.com/macfuse/macfuse/wiki/Getting-Started). Restart if prompted.

## SSH connection fails

Test ordinary SSH before involving Claude Code or SSHFS:

```zsh
ssh SSH_CONFIG_HOST
```

Resolve aliases, usernames, keys, VPN requirements, and jump hosts through your local SSH configuration and your organization's connection guide. Never paste passwords or private keys into an issue, log, or repository.

## Claude Code asks whether to trust the folder (claudefws only)

The first launch in a new mount point opens a directory Claude Code has not seen before, so it asks once per mount point. Confirm it. It does not reappear for later sessions on the same mount.

## `fuse: forking after mount is not supported`

macFUSE refuses the fork that sshfs performs to put itself in the background
after mounting. When sshfs is run the ordinary way, the mount succeeds but
sshfs stays in the foreground and never gives the terminal back.

`claudefws` avoids this by running sshfs with `-f` and detaching it from the
shell itself, so nothing is left holding the terminal. If you hit the message
after running sshfs by hand, the mount is usually already up: check `mount`
before assuming it failed, and use `-f` with a trailing `&` next time.

## The mount did not appear within 30 seconds

The detached sshfs process writes to `~/.afws/logs/SESSION.sshfs.log`, and
the launcher prints the end of that file when it gives up. A permission error
there means the shared SSH connection is not usable; a timeout means the host
became unreachable between opening the connection and mounting.

## The mount did not answer within 20 seconds

This is a timeout, not a diagnosis. Before reusing an existing mount the
launcher reads it once; a mount whose sshfs process has died answers straight
away with an error, so anything that answers nothing is either hung or merely
cold, and a cold mount on a slow link can take a while over its first read.

Check which one you have before unmounting anything:

```zsh
pgrep -fl sshfs
```

If the process for that mount is still there, the mount is very likely fine and
only slow. Give the probe longer:

```zsh
AFWS_PROBE_TIMEOUT_SECONDS=60 claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
```

If there is no such process, the mount is dead; unmount it as below.

## The mount exists but does not respond

This is the other case: the read came back as an error rather than not coming
back at all, which on macFUSE means every path inside the mount now fails with
`ENXIO`. Two faults end there, and the message says which one it found -- the
sshfs process gone, or the process still running behind a connection it could
not re-establish. Neither recovers on its own.

The mount cannot re-authenticate for itself: it runs with `BatchMode`, in a
session of its own, precisely so that it can never interrupt the agent's
terminal to ask. On a host that authenticates by password, that means a
connection lost for long enough needs a fresh authenticated connection.

SSHFS attempts to reconnect after a network interruption, but recovery is not
always possible. Use the supported recovery command rather than composing
`umount` and `sshfs` by hand:

```zsh
afws-remount                                        # inside the affected session
afws-remount SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
```

Both launchers run the same check at startup and automatically repair a mount
that returns a confirmed read error before starting the agent. The command
leaves a healthy mount alone and recreates a confirmed failed mount in place.
A replacement uses a fresh independent SSH connection by default, so it does
not inherit a hung SFTP channel from a long-lived shared connection. Use
`--reuse-connection` only if that connection is known to be healthy and password
authentication requires it. A timeout alone is not proof
of failure; first increase `AFWS_PROBE_TIMEOUT_SECONDS`, or obtain approval
before `afws-remount --force`. Rarely, a damaged SSHFS directory cache can make
the mount answer successfully with empty or incorrect contents; after comparing
with the remote directory, the same `--force` option replaces that
healthy-looking mount. Before forcing a remount, confirm that no write
operation is still in progress. If the live agent still sees `ENXIO` afterward,
exit and relaunch it so its working directory is reopened.

If plain `umount` itself hangs, recovery gives it a fixed deadline, stops only
the SSHFS process for that mount, and continues with a forced detach.

The launcher disables SSHFS's directory-name cache. This costs a network round
trip for directory reads, but avoids the observed `cache_readdir` abort and the
stale empty listings it can leave behind after reconnecting. If more than one
live session uses the mount, recovery stops unless interruption of all sessions
was explicitly approved with `--force-shared`.

Increase the keepalive values in your SSH configuration if this happens during long sessions:

```
  ServerAliveInterval 30
  ServerAliveCountMax 6
```

## The GPU is not visible

Run `nvidia-smi` on the SSH host, not on the Mac:

```zsh
afws-run SSH_CONFIG_HOST --cwd REMOTE_ABSOLUTE_DIRECTORY -- nvidia-smi
```

Its output returns to the current Terminal for both you and Claude to inspect. If the command does not exist on the host or reports a permission error, contact the remote-system administrator.

## A script uses the wrong shell

Scripts piped to `afws-run` run under remote `bash -s`. For code written for another shell, invoke that shell explicitly:

```zsh
afws-run SSH_CONFIG_HOST --cwd REMOTE_ABSOLUTE_DIRECTORY -- \
  zsh -lc 'YOUR_ZSH_CODE'
```

## The agent tries to run tests locally

Confirm that the session was started through `claudefws` or `codexfws`. A plain `claude` or `codex` launch does not receive the remote-execution instructions. Exit it and restart through the launcher with the target project selected.

## A remote command hangs instead of running

Every remote command goes through the shared SSH connection at
`~/.afws/control/HOST.sock`. If that connection is gone, ssh falls back to
connecting on its own and may wait for a password that nobody can type. Check
it, and reopen it by starting `claudefws` again:

```zsh
ssh -S ~/.afws/control/HOST.sock -O check HOST
```

## The shared connection is stuck or should be closed

```zsh
ssh -S ~/.afws/control/HOST.sock -O exit HOST
```

The next `claudefws` launch opens a new one. A stale socket file left behind by
a killed connection is removed automatically at the next launch.

## A mount is left over after the session ended

Interactive sessions have a detached watchdog, so killing or crashing their
launcher normally still releases the mount after any surviving agent exits. A
background session leaves its mount in place, and a watchdog that was also
killed or an unmount refused by macOS can leave one behind. List what is left
and release it:

```zsh
afws-umount --list
afws-umount --orphaned
```

`--list` reports how many live sessions use each mount, so a mount showing `0` is
safe to release. Add `--force` if `umount` is refused because something is still
sitting in the directory.

## `afws-peers` shows nothing, or a session is missing

The registry only holds sessions started through `claudefws` or `codexfws`. A session started with plain `claude` or `codex` is not registered, even in a mounted workspace.

If a session you started is missing, check whether it is still running:

```zsh
claude agents
```

An exited session is pruned from the registry automatically. To see the registry without changing it, add `--no-prune`.

## `afws-peers` reports the status as `unknown` or `-`

A Codex row always shows `-`: Codex CLI has no machine-readable session listing. For a Claude row, status comes from `claude agents --json`. Run it directly to see why it failed; the usual cause is that Claude Code is not signed in:

```zsh
claude agents --json
claude auth login
```

The host, remote directory, and kind still come from the registry and remain correct.

## A lock is held by a session that no longer exists

Check who holds it and how old it is:

```zsh
afws-lock status gpu0
```

A lock past its TTL is reported as `stale`. Confirm with `afws-peers` and `claude agents` that the holder is really gone, then release it explicitly:

```zsh
afws-lock steal gpu0
```

Locks are never taken automatically, because a lock held for hours is normal for a long job.

## A session resumed with `--resume` uses stale paths

Claude Code records the system prompt on a conversation's first request and reuses that recording when the conversation is resumed. A resumed session therefore still sees the mount point and session name it was launched with. If the mount point has changed, start a new session through `claudefws` instead of resuming the old one.

## Two sessions overwrote each other's edits

Both sessions write to the same remote files through the same mount, and the
filesystem does not arbitrate between them. Split the work by directory, or
have the sessions agree through `SendMessage` before editing shared files. A
`afws-lock` on a shared build or output directory prevents the same
problem for generated files. See [Multiple sessions](sessions.md).
