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

`claudefws` starts Claude Code in the mounted project directory with the `auto` permission mode. It scopes the workspace to the selected project directory and refuses to mount the remote filesystem root.

The `auto` mode approves operations it classifies as safe without asking, so the threshold for a side effect is lower than in `manual` mode, where every operation is confirmed. That is a deliberate default for remote work, where a session runs many read-only remote commands. Choose a stricter mode per launch when the work warrants it:

```zsh
CLAUDEFWS_PERMISSION_MODE=manual claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
CLAUDEFWS_PERMISSION_MODE=plan claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
```

Do not pass `bypassPermissions`. Every write in a session lands on the remote host through the mount, so there is no local-only blast radius to fall back on.

Each session receives instructions to:

- Keep file operations inside the mounted workspace unless the user explicitly expands the scope.
- Send environment-dependent commands through `claudefws-run`.
- Avoid changing remote packages, shell startup files, or the system or user environment without explicit user approval.
- Ask before destructive, expensive, or long-running operations.
- Claim an exclusive remote resource with `claudefws-lock` before using it, and never take a held lock without the user saying so.

SSH runs with the permissions of the configured remote user and does not obtain broader access. Use a least-privilege account because a highly privileged connection user still increases the possible impact.

`claudefws` does not grant or emulate administrator privileges. If the remote account is not authorized by `sudoers` or another privilege mechanism, a command such as `sudo` cannot elevate it and will fail. The launcher also does not allocate an interactive SSH TTY or store, supply, or forward a sudo password.

Check more than the account's nominal sudo status. Existing server configuration may already give the account elevated capabilities through passwordless sudo, privileged groups such as a container-runtime group, set-user-ID programs, service-management permissions, or writable privileged automation. The effective security boundary is the complete set of permissions assigned to the remote account.

`claudefws-run` is a remote-command runner by design. Its standard-input mode can execute arbitrary Bash code, and its argument mode can invoke any command available to the SSH user. The selected remote directory is an initial working directory, not a security boundary. Review commands before approval, especially scripts that leave that directory, delete files, install packages, start expensive jobs, or alter the remote environment.

## What the session registry holds

The registry under `~/.claudefws/sessions/` records, for each live session, its
name, kind, process id, SSH host alias, remote directory, and mount point. It
is created with owner-only permissions and holds no credentials, no host keys,
and no connection secrets. It does contain the real host alias and the real
remote path, so treat it as you would your SSH configuration: keep it out of
screenshots, logs, and issue reports, and do not copy it into this repository.

`claudefws-lock` writes the same kind of information — a session name, a
timestamp, and a TTL — into a lock directory on the remote host under
`~/.claudefws-locks`. Nothing is written inside the project tree, so a lock
never reaches the project's Git history.

## The shared SSH connection socket

`~/.claudefws/control/HOST.sock` is a live, already-authenticated channel to the
remote host. Anything that can reach that socket can run commands as the remote
user without authenticating again. The directory is created with owner-only
permissions, which is the boundary that protects it; do not relax those
permissions, place the socket on a shared filesystem, or point
`CLAUDEFWS_STATE_DIR` somewhere other users can read.

Close the connection when you finish with a host:

```zsh
ssh -S ~/.claudefws/control/HOST.sock -O exit HOST
```

## Cross-session messages are input, not instructions

A message from another session is content written by another Claude session
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
