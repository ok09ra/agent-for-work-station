# Multiple sessions on one workstation

[日本語](sessions.ja.md) · [README](../README.md)

One workstation is usually shared by more than one piece of work: a long
training run, a bug being reproduced, a refactor being reviewed. Claude Code
sessions running on the same Mac can see each other and exchange messages, so
those pieces of work can be separate sessions that still cooperate instead of
one session switching between them.

This page describes what `claudefws` adds on top of that, and how to use it.

## Two directions of coordination

| Question | Answer |
| --- | --- |
| Who else is here, and what are they working on? | `afws-peers`, a shell command |
| Let me talk to that session | `ListAgents` and `SendMessage`, Claude Code tools — Claude sessions only |
| Nobody else touch this GPU while I use it | `afws-lock`, a shell command |

`ListAgents` reports the Claude sessions on this Mac and the name each one
answers to. `afws-peers` reports which SSH host and remote directory each
of those names is attached to. You normally want both: the first to address a
session, the second to know which one to address.

## Starting a second session

Run the launcher again in another terminal, with the same host and directory or
a different one:

```zsh
claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
```

Each launch takes the next unused name of the form `fws-HOST-PROJECT-N`, so the
first is `fws-HOST-PROJECT-1`, the second `fws-HOST-PROJECT-2`, and so on. The
launcher prints the name it chose, and the session is told its own name so it
can tell a peer how to reply.

Give a session a name that describes its job when that is more useful than a
number:

```zsh
AFWS_SESSION_NAME=gpu-trainer claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
AFWS_SESSION_NAME=bug-1204 claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
```

Two sessions on the same host and directory share one SSHFS mount. The second
launch reuses the mount created by the first rather than mounting the project
again.

## Where each session's workspace lives

A mount point is derived from the host alias and the full remote path:

```
~/afws-mounts/HOST/REMOTE/PATH
```

So two sessions are kept apart automatically. Different hosts land in different
trees, and two different directories on one host land in different mount points.
Three cases are worth knowing:

| Second session asks for | What happens |
| --- | --- |
| A **subdirectory** of a directory already mounted | The existing mount is reused and the workspace points into it. No second SSHFS mount, no second connection. |
| A **sibling** directory | A separate mount, over the shared SSH connection to that host. |
| A **parent** of a directory already mounted | Refused. Mounting there would hide the existing mount and the other session's workspace would start resolving through the new one. Start on the deeper directory instead, or unmount it first. |

A shared mount is released by whichever session leaves last: a session that
exits while others are still working inside the same mount leaves it in place
and says so. A background session leaves its mount behind entirely, because no
launcher process remains to clean up after it — `afws-umount --orphaned`
releases those.

A lock, by contrast, is per **host**, not per directory: the lock directory lives
in the remote user's home. That is deliberate — a GPU is shared by every session
on that workstation, whichever project directory each one is working in. It also
means a generic lock name like `build` collides across unrelated projects on the
same host, so name the resource, not the action: `build-projectX`.

## Seeing the other sessions

```zsh
afws-peers
```

```
SESSION                      KIND         STATUS   SSH HOST           REMOTE DIRECTORY
gpu-trainer                  interactive  busy     example-workstation /remote/project
fws-example-workstation-project-2  interactive  idle  example-workstation /remote/project
nightly-watch                background   idle     example-workstation /remote/project
```

`AGENT` is which launcher started the session. `STATUS` comes from Claude Code
itself, so `busy`, `idle`, and `waiting` say
whether a session is working, free, or waiting for its user to answer
something. A session that has exited is removed from the listing the next time
any of these commands runs.

Narrow the listing when several workstations or projects are in play:

```zsh
afws-peers --host SSH_CONFIG_HOST   # one workstation
afws-peers --same                   # only sessions sharing this exact remote directory
afws-peers --json                   # machine-readable
```

## Talking to another session

This works between Claude sessions. A Codex session appears in `afws-peers` and
takes locks, but cannot be addressed by name, because Codex CLI has no
launch-time session name — see [what each agent supports](agents.md).

Messaging is done by Claude, not by a shell command. Inside a session, ask for
it in the ordinary way:

> Check `afws-peers`, then ask `gpu-trainer` whether the 8B run has
> finished and what the final loss was.

The session uses `ListAgents` to confirm the name, `SendMessage` to send the
question, and reports the answer back to you. The receiving session is
interrupted with the message, answers from what it has actually run and
observed, and continues its own work.

This is worth using when one session holds knowledge the other would otherwise
have to rediscover: which checkpoint is current, why a test was disabled, what
a failure looked like an hour ago, whether a dataset has finished converting.

## Taking turns on an exclusive resource

Two sessions on one workstation will eventually want the same GPU, the same
build directory, or the same dataset. `afws-lock` makes that explicit.

```zsh
afws-lock acquire gpu0        # claims it, or exits 3 and names the holder
afws-lock status              # every lock on this host
afws-lock status gpu0         # one lock
afws-lock release gpu0        # only the holder may release it
```

A lock is a directory created atomically on the remote host under
`~/.afws-locks`, so it works without any daemon, is visible to every
session on the workstation, and never writes inside the project tree. The
holder is recorded as the session name, which is also the name a peer can be
messaged by:

```
held gpu0 holder=gpu-trainer since=2026-01-01T09:12:44Z age=318s ttl=7200s
```

Wait for a lock instead of failing immediately:

```zsh
afws-lock acquire gpu0 --wait 600
```

A lock older than its TTL is reported as `stale` rather than released
automatically, because a long job is a normal reason for a lock to be held for
hours. Taking a held lock is always an explicit decision:

```zsh
afws-lock steal gpu0
```

Ask the holder first — that is what messaging is for. A session is told not to
steal a lock unless its user says so.

Lock names are yours to choose. `gpu0`, `build`, `dataset-convert`, and
`migrations` are all reasonable; use the same name in every session that
competes for that resource, since a lock only protects against sessions that
agree on the name.

## Background sessions

Claude Code only; `codexfws` has no equivalent.

A session that only needs to watch something does not need a terminal:

```zsh
claudefws --bg SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY \
  "Watch the training job with afws-run. Report failures and summarise progress when asked."
```

The launcher prints the identifier that Claude Code uses for it:

```zsh
claude agents          # list background and interactive sessions
claude attach ID       # open it in this terminal
claude logs ID         # print its recent output
claude stop ID         # stop it, keeping the conversation
claude rm ID           # delete a stopped session
```

A background session appears in `afws-peers` like any other and can be
messaged by name, which is the point: an interactive session can ask the
watcher what happened rather than re-reading the logs itself.

## A worked example

Three sessions against one workstation:

```zsh
AFWS_SESSION_NAME=gpu-trainer claudefws workstation /remote/project
AFWS_SESSION_NAME=bug-1204 claudefws workstation /remote/project
claudefws --bg workstation /remote/project "Watch the queue and report failures."
```

- `gpu-trainer` takes `afws-lock acquire gpu0`, starts the run through
  `afws-run`, and keeps the lock until the run ends.
- `bug-1204` wants to reproduce a crash on the GPU, finds the lock held by
  `gpu-trainer`, and asks it through `SendMessage` how long the run has left. It
  works on the CPU-only part of the reproduction in the meantime, or waits with
  `afws-lock acquire gpu0 --wait 1800`.
- The background session notices a failed job and is asked by either of the
  others what the last error was.

No session has to guess what the others are doing, and no two of them run on
the GPU at the same time.

## Boundaries

- The registry and peer messaging are local to one Mac. Two sessions on two
  different Macs cannot see each other through this tool, even when they share
  a workstation. Claude Code's Remote Control is the mechanism for that, and it
  is outside the scope of `claudefws`.
- A lock coordinates sessions that use `afws-lock`. It does not stop
  another person, another tool, or a scheduler on the workstation from using
  the same resource.
- Sessions share the remote filesystem. Two sessions editing the same file
  through the same mount will overwrite each other; that is what messaging is
  for.
