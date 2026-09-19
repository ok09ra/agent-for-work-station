# Install on macOS

[日本語](install-macos.ja.md) · [README](../README.md)

This guide covers the path from a mostly clean Mac to a working `claudefws` installation. Keep real connection values and credentials in your Mac's SSH configuration and Keychain, not in this repository.

## 1. Check the requirements

- macOS 12 or later
- An Intel or Apple silicon Mac
- Permission to access the SSH host
- Permission to read, write, and run the target project on the remote host

This setup does not modify software or shell configuration on the remote host.

## 2. Install macFUSE

1. Open the [official macFUSE website](https://macfuse.github.io/).
2. Download and run the latest stable installer.
3. If macOS asks you to allow macFUSE in System Settings, follow the official instructions.
4. Restart the Mac if prompted.

Because macFUSE interacts with macOS security controls, this part is intentionally not automated by the repository.

## 3. Install SSHFS

1. Open the [macFUSE project's SSHFS page](https://github.com/macfuse/macfuse/wiki/File-Systems-%E2%80%90-SSHFS).
2. Download and run the latest package for macOS.
3. Reopen Terminal and verify the installation:

   ```zsh
   command -v sshfs
   sshfs --version
   ```

This project follows the signed package referenced by the macFUSE project rather than assuming a particular third-party package manager.

## 4. Install Claude Code

Use the installer documented in the [official Claude Code documentation](https://docs.claude.com/en/docs/claude-code/overview):

```zsh
curl -fsSL https://claude.ai/install.sh | bash
exec zsh -l
claude --version
claude auth login
```

The official installer uses a user-level location, so Claude Code does not need to run with administrator privileges. Complete the sign-in once; every session started through `claudefws` reuses it.

## 5. Configure SSH

Obtain the following information from the remote-system administrator through an approved secure channel:

- SSH destination
- Remote username
- An authorized SSH key
- Absolute path to the target project

Never copy a password or private key into this repository. If you do not have an SSH key yet, create and register one according to your organization's policy. Use the macOS Keychain or an SSH agent for authentication.

Create a host alias in your local SSH configuration. The [configuration example](../examples/ssh-config.example) contains fictional values only. Replace `HostName` and `User` with real values only in your local file.

Prepare the configuration file and its permissions:

```zsh
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/config
chmod 600 ~/.ssh/config
```

Test the connection:

```zsh
ssh example-workstation
```

Replace `example-workstation` with the alias defined in your SSH configuration. On the first connection, compare the host-key fingerprint with the value supplied by the administrator.

Because a session can stay attached to the workstation for hours, and a background session longer still, keep the connection alive in your SSH configuration:

```
  ServerAliveInterval 30
  ServerAliveCountMax 6
```

## 6. Install claudefws

After obtaining the repository, run the installer from its root. If Git is not available, downloading and extracting the repository archive is also sufficient.

```zsh
./scripts/install.sh
exec zsh -l
```

The installer performs only these actions:

1. Copies `claudefws`, `claudefws-run`, `claudefws-peers`, `claudefws-lock`, and `claudefws-doctor` to a user-level command directory.
2. Adds that directory to the zsh login `PATH` only when needed.
3. Makes the commands discoverable in newly opened Terminal sessions.

It does not modify your existing SSH configuration, Claude Code configuration, or remote environment.

## 7. Run diagnostics

```zsh
claudefws-doctor
```

To validate an SSH configuration alias without opening a connection, pass the alias as an argument:

```zsh
claudefws-doctor example-workstation
```

The diagnostic also confirms that `claude agents --json` works, because that listing is how `claudefws-peers` reports the status of live sessions. If it fails, run `claude auth login` and try again.

The setup is ready when every diagnostic reports `[OK]`.

## 8. Start Claude for Work Station

Start without arguments if you do not want real values stored in shell history:

```zsh
claudefws
```

Enter the SSH alias and the allowed remote project's absolute path when prompted. After SSHFS mounts the project, Claude Code starts with that mount as its working directory.

The first launch in a new mount point shows the Claude Code workspace trust prompt, because the directory has not been opened before. Confirm it once per mount point.

## 9. Exit and unmount

Exiting Claude Code releases the mount, unless another session is still working inside it. The shared SSH connection to the host is closed at the same time, once no session is left on that host. The registry record for the finished session is removed too, and stale records are pruned whenever `claudefws-peers` or `claudefws` runs.

While a session is running, the launcher reuses any existing SSHFS mount that already covers the requested host and path, because it looks at the system `mount` table rather than at its own records.

A background session, or a session that was killed rather than exited, leaves its mount behind. Release it explicitly:

```zsh
claudefws-umount --list
claudefws-umount --orphaned
```

`--list` shows each claudefws mount and how many live sessions are using it; `--orphaned` releases the ones nobody is using. Add `--force` when a plain `umount` is refused. Ejecting the volume in Finder also works.

If you unmount by hand from Terminal, inspect `mount` first and pass only the verified mount point to `umount`. Do not run it against a broad or unverified path.
