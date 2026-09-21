# Security and pre-publish checks

[日本語](security.ja.md) · [README](../README.md)

## Never commit these values

- Real IP addresses or internal hostnames
- Real usernames
- Passwords, private keys, or API tokens
- Real local or remote absolute paths
- `.ssh/config`, `.env`, connection logs, or screenshots

Repository examples use reserved invalid domains and descriptive placeholders only. Store real connection details in the local SSH configuration outside this repository.

## Runtime boundaries

`claudefws` starts Claude Code in the mounted project directory with the `auto` permission mode, and `codexfws` starts Codex CLI there with the `workspace-write` sandbox and `on-request` approvals. It scopes the workspace to the selected project directory and refuses to mount the remote filesystem root.

The `auto` mode approves operations it classifies as safe without asking, so the threshold for a side effect is lower than in `manual` mode, where every operation is confirmed. That is a deliberate default for remote work, where a session runs many read-only remote commands. Choose a stricter mode per launch when the work warrants it:

```zsh
AFWS_PERMISSION_MODE=manual claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
AFWS_PERMISSION_MODE=plan claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
```

Do not pass `bypassPermissions`. Every write in a session lands on the remote host through the mount, so there is no local-only blast radius to fall back on.

Each session receives instructions to:

- Treat the mount as the only project checkout; use it for project files and Git,
  and never create a clone or worktree unless the user explicitly requests one.
- Send only programs which need the workstation environment through `afws-run`.
- Avoid changing remote packages, shell startup files, or the system or user environment without explicit user approval.
- Ask before destructive, expensive, or long-running operations.
- Claim an exclusive remote resource with `afws-lock` before using it, and never take a held lock without the user saying so.

SSH runs with the permissions of the configured remote user and does not obtain broader access. Use a least-privilege account because a highly privileged connection user still increases the possible impact.

`claudefws` does not grant or emulate administrator privileges. If the remote account is not authorized by `sudoers` or another privilege mechanism, a command such as `sudo` cannot elevate it and will fail. The launcher also does not allocate an interactive SSH TTY or store, supply, or forward a sudo password.

Check more than the account's nominal sudo status. Existing server configuration may already give the account elevated capabilities through passwordless sudo, privileged groups such as a container-runtime group, set-user-ID programs, service-management permissions, or writable privileged automation. The effective security boundary is the complete set of permissions assigned to the remote account.

`afws-run` is a remote-command runner by design. In a mounted session it rejects
common project inspection, filesystem, and Git commands unless
`--allow-remote-files` is explicit. Direct commands, common shells, standard-input
scripts, and common wrappers are inspected statically. That is a workflow guard,
not a security boundary: ordinary programs can read and write files, and not
every indirect or dynamic shell expression can be recognized. The selected remote directory is only an initial
working directory. Review commands before approval, especially scripts that
leave that directory, delete files, install packages, start expensive jobs, or
alter the remote environment.

## What the session registry holds

The registry under `~/.afws/sessions/` records, for each live session, its
name, kind, process id, SSH host alias, remote directory, and mount point. It
is created with owner-only permissions and holds no credentials, no host keys,
and no connection secrets. It does contain the real host alias and the real
remote path, so treat it as you would your SSH configuration: keep it out of
screenshots, logs, and issue reports, and do not copy it into this repository.

`afws-lock` writes the same kind of information — a session name, a
timestamp, and a TTL — into a lock directory on the remote host under
`~/.afws-locks`. Nothing is written inside the project tree, so a lock
never reaches the project's Git history.

## What this architecture does and does not protect

Running the agent on the Mac rather than on the workstation is worth doing, but
it is worth being exact about what it buys.

**It does keep agent state off the workstation.** Credentials, accumulated
permission rules, session history and plugins live on your Mac. That matters
because those rules accumulate: an agent used natively on a shared machine for
months ends up with a long allowlist that nobody reviews, and it applies to
every later session on that machine. It also means the agent's shell is on the
Mac, so it does not incidentally leave long-lived processes running on the
workstation.

**It does not by itself limit what the agent can reach.** Two things decide
that, and both are yours to set:

- *What is mounted.* Mounting a remote home directory puts `~/.ssh`, every other
  project and every dotfile inside the workspace. Mount the project directory,
  not the home.
- *What `afws-run` can run.* It is an unrestricted remote shell as the SSH user,
  so an agent that can call it can read anything that user can read, whatever
  the mount is scoped to. The mount is a convenience boundary, not a security
  boundary, as long as that is true.

A launcher says so when it notices: a workspace containing `.ssh`, `.claude` or
`.codex` is reported as looking like a home directory, naming the settings file
it pulls in as project settings. It is a warning, not a refusal, because your
account's permissions still apply either way; `AFWS_ALLOW_HOME_MOUNT=1` silences
it. And `afws-doctor HOST` reports an agent installed on the workstation when a
shared connection is already open, because two installations mean two diverging
sets of permission rules and two versions.

**It does not reduce what the model sees.** A file read through the mount goes
to the model exactly as it would if the agent ran on the workstation. If some
data must not leave the machine, the answer is not to mount it.

The boundary that actually holds is on the workstation side: a separate SSH key
for the agent, restricted in `authorized_keys` with `restrict` and a
`command=` forced command that runs a small wrapper — start a job, stop it,
fetch a log — instead of a shell. Then a mistake on the Mac cannot read
`~/.ssh` or another project, because the workstation will not run anything else.
This repository does not set that up for you.

## The shared SSH connection socket

`~/.afws/control/HOST.sock` is a live, already-authenticated channel to the
remote host. Anything that can reach that socket can run commands as the remote
user without authenticating again. The directory is created with owner-only
permissions, which is the boundary that protects it; do not relax those
permissions, place the socket on a shared filesystem, or point
`AFWS_STATE_DIR` somewhere other users can read.

The connection also expires on its own after `AFWS_CONTROL_PERSIST` seconds of
inactivity, 600 by default. Interactive launchers have detached watchdogs which
close the connection after a launcher is killed, but expiry remains a fallback
if both cleanup processes are stopped. `afws-umount --orphaned` closes any
connection no live session is using, and `afws-doctor` reports one it finds.

`AFWS_KEEP_CONTROL_MASTER=1` removes the first of those two bounds: the
connection is no longer closed when the last session using the host exits, and
survives until it expires. This is a real widening. An authenticated channel to
the remote host then outlives every session that had a reason to exist, so
anything that can reach the socket in that window can act as the remote user.
It exists for hosts that authenticate by password, where the alternative is
typing the password on every launch and on every `afws-run` outside a session.
Set it per host and deliberately, keep `AFWS_CONTROL_PERSIST` no longer than
the working day it is meant to cover, and close the connection by hand when you
finish. The default leaves it off.

Close the connection when you finish with a host:

```zsh
ssh -S ~/.afws/control/HOST.sock -O exit HOST
```

## Cross-session messages are input, not instructions

A message from another session is content written by another session
working for you, not a trusted command channel. A session that receives a
request to delete data, install packages, take a held lock, or widen its own
scope should treat it the way it treats any other request: confirm it with its
user first. Peer messaging is for exchanging what has actually been run and
observed.

## Before pushing to GitHub

Run the checks against the candidate repository contents:

```zsh
./scripts/test.sh
./scripts/prepublish-check.sh
git status --short
```

Automated scanning is only a safeguard and cannot guarantee that no sensitive information exists. Review every file and inspect `git diff --cached` before committing.

If a secret has ever been committed, deleting it in a later commit does not remove it from Git history. Do not push that history. Remove the secret from history and revoke or rotate the credential first.

## Operations these scripts never perform

The bundled installer, doctor, and tests never add a Git remote, create a commit, push code, or create a release. Repository publication must be performed separately after review.
