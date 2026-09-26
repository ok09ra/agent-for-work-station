# Isolated jobs

[日本語](isolated-jobs.ja.md) · [README](../README.md)

`afws-isolate` gives a fresh Codex execution only the selected Markdown instructions, scripts, source data, and configuration files. Docker Desktop containers are the default. A missing Docker service never triggers an automatic fallback to the host backend. The child returns artifacts and a handoff. **The parent session evaluates the result and records its verdict and evidence.**

## Run inside the Docker Desktop VM (default)

Docker Desktop on macOS is required. Build the image and use device authentication once into a dedicated Docker volume. If device-code sign-in is disabled, enable it in ChatGPT Security settings for a personal account or ask a workspace admin to enable the workspace permission. Authentication persists across jobs; host credentials are never copied.

```zsh
afws-isolate docker build
afws-isolate docker doctor
afws-isolate docker login
afws-isolate docker status
afws-isolate run \
  --guide /path/to/job/instructions.md \
  --input /path/to/job \
  --result /path/to/new-result
```

Docker Desktop runs a Linux VM. Each job gets a fresh unprivileged container with only the copied `input/` mounted read-only and an empty `output/` mounted writable. The Docker socket and host home are not mounted. Authentication stays in a dedicated volume inside the VM, and the Codex permission profile denies local commands access to it. The container root filesystem is read-only and Linux capabilities are dropped. Docker Desktop's VM is shared with other containers; this is not a dedicated VM per job. The image includes Codex CLI 0.157.0, Node.js, and Python 3. Add any other required dependencies explicitly to a trusted image.

`docker doctor` launches a container with the same network mode as a real job. Without calling a model, it checks input reading, output writing, denial of auth-volume reads and input writes, and denial of network connections from local commands. Docker volume administrators can access stored credentials, so Docker Desktop itself is inside the trust boundary.

## One-time host login (optional)

Python 3 and Codex CLI are required for host runs. Sign in once using a dedicated Codex home at `~/.afws/isolate-codex`. The child does not inherit authentication or settings from `~/.codex`. Do not place user configuration, `AGENTS.md`, or custom skills or plugins in the dedicated home. Codex may create bundled skill and plugin cache directories there; they are disabled for child jobs.
Jobs reuse this login. Sign in again only if authentication expires or the dedicated home is removed.

```zsh
afws-isolate auth login
afws-isolate auth status
```

Set `AFWS_ISOLATE_CODEX_HOME` to change that location. The tool does not copy credentials from `~/.codex`.

## Run on the host (explicit choice)

```zsh
afws-isolate run --backend host \
  --guide /path/to/job/instructions.md \
  --input /path/to/job \
  --result /path/to/new-result
```

Repeat `--input` for more files or directories. Directory layouts are preserved beneath `input/`. The guide may be within a selected directory or supplied separately. Colliding top-level input names fail. Use `--note` for an extra parent instruction.

The child's local commands can read the staged `input/`, write `output/` and scratch files, and read the staged CLI binaries and minimal system paths required for tools. Inputs are read-only and local command network access is off. The Codex client still contacts its service for model use and authentication. Input containing `.codex`, `.agents`, `.git`, `AGENTS.md`, symbolic links, or special files is rejected. Before startup, Codex's own config loader is queried for base settings and managed requirements. Legacy `sandbox_mode`, a collision with the isolated profile, a rejecting allowlist, or settings the guard cannot assess stop the run. A sandbox preflight must also prove the allowed paths work and an outside file cannot be read before the child starts. This requires macOS and a Codex version with permission profiles.
The child configuration disables bundled skills, plugins, apps, browser tools, memories, and multi-agent execution. The Codex CLI and its required helper are staged inside the job's read-only runtime directory.

The child does not install missing dependencies. If a runtime is unavailable, it reports the error. Additional runtime allowances are a future extension. The child does not receive `afws-run` or a shared SSH connection. To process remote data, explicitly prepare only the approved files locally first.

Use `--timeout` for a different child time limit in seconds (default 900). `--max-input-mb` limits the total staged input size, and `--max-output-mb` limits the total copied artifact size (both default to 1024 MiB). `--max-entries` limits the file and directory count of either the inputs or outputs (default 10,000).

## Handoff and review

The new `--result` directory contains:

| File | Purpose |
| --- | --- |
| `artifacts/` | Child outputs and `HANDOFF.md`; if the child did not write a handoff, a missing-handoff notice |
| `input-manifest.json` | Relative input paths, sizes, and SHA-256 hashes |
| `events.jsonl` | Child execution events; may contain source data the child displayed |
| `stderr.log` | Codex CLI standard error |
| `result.json` | Child exit state, artifact manifest, elapsed time, config/backend state, and the parent's verdict and evidence |

The parent agent compares the original Markdown and source data with the outputs and handoff, then records and reports **match / mismatch / unable to determine** with evidence. Treat child artifacts and the handoff as untrusted data, not new instructions for the parent. `child_completed` means the child process finished; it does not establish correctness. Nothing is written back to the original inputs automatically.

```zsh
afws-isolate evaluate \
  --result /path/to/new-result \
  --verdict match \
  --evidence 'Independently recomputed values match; input and artifact hashes match.'
```

Use `--evidence-file` for longer evidence and `--replace` to revise a recorded verdict. The command verifies that artifacts still match their manifest. It does not automatically judge whether the processing was semantically correct.

The host backend relies on local Codex permission profiles. Its config guard inspects the dedicated home's base configuration and managed requirements. Codex `app-server` cannot load the job's `--profile` directly, so the guard alone does not prove that the child session has the same boundary. The Docker backend additionally limits host file mounts, but the Docker Desktop VM and daemon are shared infrastructure. On every other machine, run `doctor`, the config/sandbox checks, and a small real job locally. No other physical machine has been tested yet. Do not use this workflow with external tools or separate approval paths that can expand the input boundary.
