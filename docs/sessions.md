# Multiple sessions on one workstation

[日本語](sessions.ja.md) · [README](../README.md)

One workstation is usually shared by more than one piece of work: a long
training run, a bug being reproduced, a refactor being reviewed. Claude and
Codex sessions running on the same Mac can see each other's work in
`afws-peers`; either agent can queue a direct message to a Claude or Codex peer.

This page describes what the launchers add on top of that, and how to use it.

## Two directions of coordination

| Question | Answer |
| --- | --- |
| Who else is here, and what are they working on? | `afws-peers`, a shell command |
| Let me talk to an independent session | `afws-message` for Claude or Codex |
| Coordinate teammates in one Claude Agent Team | native `ListAgents` and `SendMessage` |
| Nobody else touch this GPU while I use it | `afws-lock`, a shell command |

`afws-peers` reports every AFWS session on this Mac and which SSH host and
remote directory each name is attached to. Native `ListAgents` lists teammates
inside the current Claude Agent Team; it is not the registry for arbitrary
independent Claude sessions.

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

A session's own working directory on this Mac is an empty control workspace
under `~/.afws/workspaces/HOST/REMOTE/PATH`. The project is not there: it is
reached through `afws-run`, so nothing about two sessions' file tools can
collide locally. What they do share is the remote directory itself, which is
what `afws-lock` and the peer messaging in this document are for.

A Finder/VS Code view, when one is mounted, has its mount point derived from
the host alias and the full remote path:

```
~/afws-mounts/HOST/REMOTE/PATH
```

So two sessions are kept apart automatically. Different hosts land in different
trees, and two different directories on one host land in different mount points.
Three cases are worth knowing:

| Second session asks for | What happens |
| --- | --- |
| A **subdirectory** of a directory already mounted | The existing mount is reused and the view points into it. No second mount, no second connection. |
| A **sibling** directory | A separate mount, over the shared SSH connection to that host. |
| A **parent** of a directory already mounted | Refused. Mounting there would hide the existing mount, and the other session's view would start resolving through the new one. Start on the deeper directory instead, or unmount it first. |
| **Exactly** a path something is already mounted on | Refused. A second filesystem there stacks on the first rather than replacing it: only the newest layer is visible, and releasing it uncovers the next instead of freeing the path. |

A shared view is released by whichever session leaves last: a session that
exits while others are still using the same mount leaves it in place and says
so. A JupyterLab started by `afws-lab` follows the same rule — one serves every
session on the same host and remote directory, and the last to leave stops it. Each interactive launcher also starts a detached watchdog, which
does the same last-user cleanup if the launcher is killed or crashes. It waits
for a surviving Claude or Codex process before releasing anything. A background
session leaves a view behind entirely — `afws-umount --orphaned` releases those,
and `afws-lab stop --orphaned` does the same for a lab.

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
SESSION        AGENT   KIND         STATUS  SSH HOST             REMOTE DIRECTORY  ACTIVITY
gpu-trainer    claude  interactive  busy    example-workstation  /remote/project   -
cx-training    codex   interactive  idle    example-workstation  /remote/project   8B training
nightly-watch  claude  background   idle    example-workstation  /remote/project   -
```

`AGENT` is which launcher started the session. Claude's `STATUS` comes from
Claude Code itself, including `waiting`; Codex's `busy` and `idle` come from
local lifecycle hooks. `ACTIVITY` gives a short Codex task label. A session
that has exited is removed from the listing the next time a command runs.

Narrow the listing when several workstations or projects are in play:

```zsh
afws-peers --host SSH_CONFIG_HOST   # one workstation
afws-peers --same                   # only sessions sharing this exact remote directory
afws-peers --json                   # machine-readable
```

## Talking to another session

Independent sessions use `afws-message`. It resolves a name in `afws-peers`,
then either writes a Claude durable inbox or queues to the Codex thread ID
captured by a lifecycle hook. A Codex recipient becomes addressable after its
first turn. Native `ListAgents` and `SendMessage` remain the faster path between
members of the current Claude Agent Team. See [what each agent supports](agents.md).

Inside a session, ask in ordinary language:

> Check `afws-peers`, then ask `gpu-trainer` whether the 8B run has
> finished and what the final loss was.

The sender checks live activity labels and uses
`afws-message --to NAME --message TEXT`. An idle Codex session starts a turn; a
busy one handles the message after its current turn. Claude consumes its durable
inbox at session start, user-prompt submission, or the end of a response; a Stop
hook can continue the conversation with that context. Queueing is not an answer
or acknowledgement. The sender reports that it queued the message, and you can
ask the recipient's session for its answer later.

Peer messages are coordination, not replacements for the recipient's direct
user task. A Codex Stop hook recognizes an `afws-message` turn and, after the
reply, prompts the recipient once to check and resume unfinished work. It does
not restart a task that is already complete. Claude recipients are instructed
to reply and then continue their prior task in the same turn. This does not
prevent a genuine interruption, a new direct user request, or a task that
needs user input from stopping work.

You need not know the name: “Tell the agent working on 8B training that the
dataset is ready” works when the activity, host, and directory identify one
live Codex peer. If several fit, the sender asks you which one. `afws-peers`
performs this lookup only on demand; lifecycle hooks do not fill model context
with peer status. `afws-status set '8B training'` gives a Codex session a stable
activity label; otherwise the first line of its latest user prompt is shown.
Labels remain in owner-only files on this Mac. Avoid secrets in labels.

For a direct terminal send to either agent, use `afws-message --to NAME --message TEXT` or
`afws-message --all --same --message TEXT` for every other Codex session on
this project. `--all` without `--same` targets all live Codex sessions on this
Mac. A broadcast must be explicitly requested.

This is worth using when one session holds knowledge the other would otherwise
have to rediscover: which checkpoint is current, why a test was disabled, what
a failure looked like an hour ago, whether a dataset has finished converting.

## Managing teams through chat

In either a Claude or Codex session, describe the organization naturally:
“Task A uses agents 1–3, Task B uses agents 4–9, and the first agent in each
group is the lead.”
The agent resolves those descriptions to live session names with `afws-peers` and
updates a project-scoped local ledger through `afws-org`. By default, the first
listed member leads, workers do not redelegate, workers report to their lead,
and leads report to the coordinator. Codex asks only when a numbered or
described session cannot be resolved unambiguously.

Ask “show the organization,” “show only Task B,” or “who is doing what?” to see
the declared reporting structure and assignments overlaid with observed
session liveness. Membership remains in the ledger after a session exits, so
the member appears as `offline`. The same views are available directly:

```zsh
afws-org show
afws-org show --team task-b
afws-org show --json
afws-org validate
```

`afws-peers` is the observed set of live sessions; `afws-org` is the source of
truth for declared organization and assignments. A session changes the
organization for a direct user request, never merely because an ordinary peer
message asked it to.

When the user says to start or distribute the work, the coordinator records
each assignment first, then sends one structured organization assignment to
each affected Claude or Codex session. It never broadcasts assignments. A
recipient checks that the sender is its declared coordinator or lead and that its team
and task exactly match the ledger before acknowledging and advancing through
`acknowledged`, `running`, and `completed`. Workers cannot redelegate.
Destructive, expensive, privileged, or out-of-scope work still requires the
recipient user's approval.

### Durable delivery and recovery

The organization ledger is a per-project SQLite database in
`~/.afws/organizations`. It uses WAL journaling, full synchronization,
revision-checked state transitions, an audit event stream, and a transactional
outbox. Session names are display names; authorization and assignment ownership
use a random instance ID plus a session token whose hash is stored in the local
registry. Reusing a session name retires the old identity and orphans its active
work instead of silently inheriting it.

The normal assignment loop is `assigned` → `delivered` → `acknowledged` →
`running` → `completed`, `failed`, `waiting`, or `blocked`. Use
`afws-org dispatch` to deliver pending outbox items, `claim ASSIGNMENT TOKEN`
to consume the one-time claim token,
`heartbeat` while working, and `reconcile` after a crash. Reconciliation marks
expired delivery acknowledgements `ack_timeout`, marks work owned by a missing
instance `orphaned`, and recovers abandoned outbox delivery leases. `retry`,
`reassign`, and `cancel` are explicit manager actions; cancellation of running
work is itself delivered through the outbox.

Write scopes are normalized project-relative paths. Overlapping live scopes
are rejected transactionally, even when two coordinators race. `--lock NAME`
adds an `afws-lock` prerequisite acquired before work enters `running`.

A scope written down is not a scope enforced. The project lives on the
workstation, so no rule on this Mac can hold one: every project write arrives
through `afws-run`. What the launchers do instead is check the result. Before a
turn ends, a session under a scoped assignment compares the workstation's
`git status` against its scope and refuses to stop on a change outside it,
naming the paths and pointing at `afws-org wait`. It blocks once per stop, so a
session that cannot reach the workstation to clean up is not trapped. Reading is
never restricted: an agent that cannot look around guesses instead.

`afws-org guard PATH...` is that check on its own. It is read-only, records no
event, and returns success when the session has no scoped assignment, so it is
safe to call on every write. `check-write` remains the self-reported form.

`--done-when CONDITION` states what finishing means. An assignment that carries
one cannot be closed on the assignee's own word: `afws-org complete` then needs
`--evidence "COMMAND -> WHAT IT RETURNED"` as well as a result, and refuses
without it. Declaring completion early is the failure this field exists to
catch. `afws-org set-done-when` adds a condition to an assignment already made.

Split work by what can be understood independently rather than by what can be
listed separately. Two tasks that need the same context belong in one
assignment even when they touch different files; splitting them only moves the
context loss to the handoff.

Only the coordinator can change the overall organization. A team lead can
manage and dispatch work for that team. A worker can claim and update only its
own assignment. If a coordinator session is recreated, it does not inherit
authority automatically; after confirming the old instance is retired, run
`afws-org recover-coordinator` from the replacement session with the exact same
session name. Schema upgrades are additive and create a mode-0600 backup before
migration. `afws-org events` shows the audit stream and `afws-org validate`
checks reporting lines, states, versions, and scope collisions.

Delivery is intentionally at-least-once: a process can crash after the receiver
accepted a message but before the sender recorded success. The one-time claim
token makes acknowledgement idempotent, but task side effects must still be
designed so that a retry is safe.

### Self-solving loops

For a direct Claude objective, enter `/goal VERIFIABLE_CONDITION`. Claude Code
implements this as a session-scoped Stop hook and continues until the condition
is met, interrupted, or its safety cap is reached. State the condition as an
observable artifact plus a check, for example “`report.json` exists and
`./scripts/verify.sh` passes.” Use `/loop` or a scheduled wakeup for time-based
waiting instead of repeatedly polling in a shell.

Durable AFWS assignments use the same lifecycle boundary automatically. While
an assignment remains `acknowledged` or `running`, the Claude Stop hook injects
the next required action. It stops cleanly when the agent records `completed`,
`failed`, `waiting`, or `blocked`; the latter two must include the concrete
unblock condition. Claude Code also enforces its own consecutive Stop-hook cap,
so this mechanism is persistent supervision, not an infinite loop.

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
