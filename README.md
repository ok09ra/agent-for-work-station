# Claude for Work Station

[日本語](README.ja.md)

`claude-for-work-station` is a small macOS wrapper for using Claude Code with a project hosted on a remote workstation.

- It mounts the remote project as a local workspace with SSHFS.
- It sends Python, tests, builds, GPU jobs, and other environment-dependent commands to the remote host through `claudefws-run`.
- It gives every session a name, registers it, and lets several Claude sessions on the same Mac see each other, talk to each other, and take turns on exclusive remote resources.
- It does not store real IP addresses, usernames, passwords, or project paths in this repository.
- The supported client operating system is macOS.

The repository name is `claude-for-work-station`; the installed commands use the shorter `claudefws` prefix.

## Quick setup

On a clean Mac, prepare the following components in order:

1. Install the latest stable release from the [official macFUSE website](https://macfuse.github.io/).
2. Install the macOS SSHFS package linked from the [official macFUSE SSHFS page](https://github.com/macfuse/macfuse/wiki/File-Systems-%E2%80%90-SSHFS).
3. Install Claude Code according to the [official Claude Code documentation](https://docs.claude.com/en/docs/claude-code/overview).

   ```zsh
   curl -fsSL https://claude.ai/install.sh | bash
   claude auth login
   ```

4. Run the installer from the repository root.

   ```zsh
   ./scripts/install.sh
   exec zsh -l
   claudefws-doctor
   ```

5. Add a host alias to your local `~/.ssh/config`. Keep all real values outside this repository; use the [fictional SSH configuration example](examples/ssh-config.example) as a template.
6. Start the launcher. With no arguments, it prompts for the SSH host alias and remote project directory.

   ```zsh
   claudefws
   ```

You can also provide both values directly:

```zsh
claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY
```

For SSH authentication, use SSH keys and the macOS Keychain rather than saving a password in a file.

## Installed commands

| Command | Purpose |
| --- | --- |
| `claudefws` | Mount the remote project and start a named Claude Code session on it. |
| `claudefws-run` | Run one command, or a piped script, on the remote host. |
| `claudefws-peers` | List the sessions on this Mac and the host and directory each one works on. |
| `claudefws-lock` | Claim an exclusive remote resource so two sessions do not collide. |
| `claudefws-umount` | Release a mount left behind by a background or killed session. |
| `ws-run` | Short form of `claudefws-run --`, for typing after Claude Code's `!`. |
| `claudefws-doctor` | Check that the prerequisites are installed and usable. |

## Several sessions on one workstation

Each launch produces a named session, so a second terminal gives you a second
session on the same workstation rather than a competing copy of the first:

```zsh
claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY   # fws-HOST-PROJECT-1
claudefws SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY   # fws-HOST-PROJECT-2
claudefws --bg SSH_CONFIG_HOST REMOTE_ABSOLUTE_DIRECTORY "watch the training job"
```

Inside a session, Claude can list its peers with `claudefws-peers`, message one
of them by name, and serialise access to a GPU or a shared build directory with
`claudefws-lock`. See [Multiple sessions](docs/sessions.md) for the details.

## Documentation

| Topic | English | 日本語 |
| --- | --- | --- |
| macOS installation | [Install on macOS](docs/install-macos.md) | [macOSセットアップ](docs/install-macos.ja.md) |
| Usage | [Usage](docs/usage.md) | [使い方](docs/usage.ja.md) |
| Multiple sessions | [Multiple sessions](docs/sessions.md) | [複数セッション](docs/sessions.ja.md) |
| Security | [Security](docs/security.md) | [セキュリティ](docs/security.ja.md) |
| Troubleshooting | [Troubleshooting](docs/troubleshooting.md) | [トラブルシューティング](docs/troubleshooting.ja.md) |

## Development checks

```zsh
./scripts/test.sh
./scripts/prepublish-check.sh
```

`test.sh` runs entirely against a throwaway registry; it never opens an SSH
connection, never mounts a filesystem, and never starts a Claude session.

`prepublish-check.sh` scans the publishable tree for private-key material, common token formats, IP address literals, personal home-directory paths, and likely assigned passwords. Always review the staged diff before pushing.

## Repository status

The installer, doctor, and tests never add a Git remote, create a commit, push code, or create a release. Repository publication is a separate, explicit operation.
