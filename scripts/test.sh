#!/bin/zsh

set -eu

readonly REPOSITORY_ROOT="${0:A:h:h}"
readonly LIBRARY="${REPOSITORY_ROOT}/lib/afws-common.zsh"
readonly CLAUDE_LAUNCHER="${REPOSITORY_ROOT}/bin/claudefws"
readonly CODEX_LAUNCHER="${REPOSITORY_ROOT}/bin/codexfws"
readonly RUNNER="${REPOSITORY_ROOT}/bin/afws-run"
readonly PEERS="${REPOSITORY_ROOT}/bin/afws-peers"
readonly LOCK="${REPOSITORY_ROOT}/bin/afws-lock"
readonly UMOUNT="${REPOSITORY_ROOT}/bin/afws-umount"
readonly SHELL_WRAPPER="${REPOSITORY_ROOT}/bin/afws-shell"

# Kept short on purpose: the shared-connection socket lives under this
# directory and a Unix domain socket path is limited to 104 bytes.
readonly SANDBOX="$(mktemp -d /tmp/afws-test.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

# Every test runs against a throwaway registry and mount root. No test reaches
# ssh, sshfs, or a real agent session.
export AFWS_STATE_DIR="${SANDBOX}/state"
export AFWS_MOUNT_BASE="${SANDBOX}/mounts"
unset AFWS_SESSION_NAME AFWS_SSH_HOST AFWS_REMOTE_DIR AFWS_CONTROL_PATH \
  AFWS_AGENT AFWS_KEEP_MOUNT AFWS_NO_CONTROL_MASTER AFWS_NO_SHELL_MARKER \
  AFWS_PERMISSION_MODE AFWS_MOUNT_COMMAND 2>/dev/null || true

fail() {
  print -u2 -r -- "test.sh: $*"
  exit 1
}

expect_rejected() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "accepted what it should reject: ${description}"
  fi
}

reset_state() {
  rm -rf "$AFWS_STATE_DIR"
  mkdir -p "${AFWS_STATE_DIR}/sessions"
}

# write_record NAME AGENT PID HOST REMOTE_DIR EPOCH [WORKSPACE] [MOUNT_POINT]
write_record() {
  local name="$1" agent="$2" pid="$3" host="$4" remote="$5" epoch="$6"
  local workspace="${7:-${AFWS_MOUNT_BASE}/${4}${5}}"
  local point="${8:-$workspace}"

  mkdir -p "${AFWS_STATE_DIR}/sessions"
  {
    print -r -- "session_name=${name}"
    print -r -- "agent=${agent}"
    print -r -- "kind=interactive"
    print -r -- "pid=${pid}"
    print -r -- "bg_id="
    print -r -- "ssh_host=${host}"
    print -r -- "remote_dir=${remote}"
    print -r -- "local_workspace=${workspace}"
    print -r -- "mount_point=${point}"
    print -r -- "started_at=2026-01-01T00:00:00Z"
    print -r -- "started_epoch=${epoch}"
  } > "${AFWS_STATE_DIR}/sessions/${name}.conf"
}

# --- syntax ---------------------------------------------------------------

for script in \
  "$LIBRARY" \
  "$CLAUDE_LAUNCHER" \
  "$CODEX_LAUNCHER" \
  "$RUNNER" \
  "$PEERS" \
  "$LOCK" \
  "$UMOUNT" \
  "${REPOSITORY_ROOT}/scripts/install.sh" \
  "${REPOSITORY_ROOT}/scripts/doctor.sh" \
  "${REPOSITORY_ROOT}/scripts/prepublish-check.sh"; do
  zsh -n "$script" || fail "syntax check failed: ${script:t}"
done

sh -n "$SHELL_WRAPPER" || fail "syntax check failed: ${SHELL_WRAPPER:t}"

# zsh ties 'path' to $PATH and makes 'status' read-only, so assigning to either
# inside a function breaks command lookup or aborts outright. Both have bitten
# this code before, and the shared library makes the blast radius large.
special_parameter_hits=""
for name in path status cdpath fpath manpath module_path argv options signals \
  psvar mailpath watch histchars prompt SECONDS RANDOM LINES COLUMNS pipestatus dirstack; do
  hits="$(grep -nE "(^|[[:space:];(&|]|local |readonly |typeset |integer |export )${name}=" \
    "$LIBRARY" "$CLAUDE_LAUNCHER" "$CODEX_LAUNCHER" "$RUNNER" "$PEERS" "$LOCK" "$UMOUNT" \
    "${REPOSITORY_ROOT}/scripts/"*.sh 2>/dev/null || true)"
  [[ -n "$hits" ]] && special_parameter_hits+="${name}: ${hits}"$'\n'
done
[[ -z "$special_parameter_hits" ]] || \
  fail "assignment to a zsh special parameter:"$'\n'"$special_parameter_hits"

# --- documentation --------------------------------------------------------

for document in \
  "${REPOSITORY_ROOT}/README.md" \
  "${REPOSITORY_ROOT}/README.ja.md" \
  "${REPOSITORY_ROOT}/docs/agents.md" \
  "${REPOSITORY_ROOT}/docs/agents.ja.md" \
  "${REPOSITORY_ROOT}/docs/install-macos.md" \
  "${REPOSITORY_ROOT}/docs/install-macos.ja.md" \
  "${REPOSITORY_ROOT}/docs/security.md" \
  "${REPOSITORY_ROOT}/docs/security.ja.md" \
  "${REPOSITORY_ROOT}/docs/sessions.md" \
  "${REPOSITORY_ROOT}/docs/sessions.ja.md" \
  "${REPOSITORY_ROOT}/docs/troubleshooting.md" \
  "${REPOSITORY_ROOT}/docs/troubleshooting.ja.md" \
  "${REPOSITORY_ROOT}/docs/usage.md" \
  "${REPOSITORY_ROOT}/docs/usage.ja.md"; do
  [[ -f "$document" ]] || fail "bilingual documentation is missing: ${document:t}"
done

grep -Fq '[日本語](README.ja.md)' "${REPOSITORY_ROOT}/README.md" || \
  fail "English README does not link to Japanese README"
grep -Fq '[English](README.md)' "${REPOSITORY_ROOT}/README.ja.md" || \
  fail "Japanese README does not link to English README"

# --- help -----------------------------------------------------------------

for command_path in "$CLAUDE_LAUNCHER" "$CODEX_LAUNCHER" "$RUNNER" "$PEERS" "$LOCK" "$UMOUNT"; do
  "$command_path" --help >/dev/null || fail "${command_path:t} --help failed"
done

# --- shared library resolution -------------------------------------------

reset_state
prefix="${SANDBOX}/prefix"
AFWS_INSTALL_DIR="${prefix}/bin" "${REPOSITORY_ROOT}/scripts/install.sh" --no-shell-config >/dev/null ||
  fail "the installer failed"

for command_name in claudefws codexfws afws-run afws-peers afws-lock afws-umount afws-shell afws-doctor; do
  [[ -x "${prefix}/bin/${command_name}" ]] || fail "the installer did not place ${command_name}"
done
[[ -f "${prefix}/lib/afws-common.zsh" ]] || fail "the installer did not place the shared library"
[[ ! -x "${prefix}/lib/afws-common.zsh" ]] || fail "the installed library must not be executable"

"${prefix}/bin/afws-run" --help >/dev/null || \
  fail "an installed command could not find the library through ../lib"

# A command with no library anywhere must say so rather than fail obscurely.
lonely="${SANDBOX}/lonely"
mkdir -p "$lonely"
cp "$RUNNER" "${lonely}/afws-run"
lonely_output="$(HOME="${SANDBOX}/empty-home" "${lonely}/afws-run" --help 2>&1 || true)"
[[ "$lonely_output" == *"cannot find lib/afws-common.zsh"* ]] || \
  fail "a command without the shared library did not explain itself"

# --- library hardening ----------------------------------------------------

# The registry is written with a tight umask, which must not leak into the
# agent the launcher starts: every file the agent creates in the remote project
# would otherwise be owner-only.
umask_probe="$(zsh -c '
  set -eu
  AFWS_PROGRAM=test
  AFWS_STATE_DIR='"$AFWS_STATE_DIR"'
  source '"$LIBRARY"'
  afws_agent=claude afws_session_name=umask-probe afws_ssh_host=h
  afws_remote_dir=/d afws_local_workspace=/w afws_mount_point=/w
  before=$(umask)
  afws_write_session_record interactive 1 ""
  print -r -- "${before} $(umask)"
')"
[[ "${umask_probe% *}" == "${umask_probe#* }" ]] || \
  fail "writing a session record changed the umask of the calling shell (${umask_probe})"

record_mode="$(stat -f '%Sp' "${AFWS_STATE_DIR}/sessions/umask-probe.conf")"
[[ "$record_mode" == -rw------- ]] || fail "a session record is not owner-only (${record_mode})"
rm -f "${AFWS_STATE_DIR}/sessions/umask-probe.conf"

# Release runs from the EXIT trap and from the signal traps, so calling it more
# than once must not unmount or close anything twice.
release_probe="$(zsh -c '
  set -eu
  AFWS_PROGRAM=test
  AFWS_STATE_DIR='"$AFWS_STATE_DIR"'
  AFWS_MOUNT_BASE='"$AFWS_MOUNT_BASE"'
  source '"$LIBRARY"'
  afws_session_name=release-probe afws_ssh_host=h
  afws_mount_point='"$AFWS_MOUNT_BASE"'/nothing-here
  afws_control_socket_path=/nonexistent.sock
  afws_release_session /nonexistent-peers
  afws_release_session /nonexistent-peers
  print -r -- "released=${afws_released}"
')"
[[ "$release_probe" == "released=1" ]] || fail "release is not idempotent (${release_probe})"

# A pre-authenticated SSH channel must expire on its own, because a session
# killed with SIGKILL never closes it.
grep -q 'AFWS_CONTROL_PERSIST:=[1-9]' "$LIBRARY" || \
  fail "the shared SSH connection has no finite ControlPersist"
grep -q 'ControlPersist=\${AFWS_CONTROL_PERSIST}' "$LIBRARY" || \
  fail "the shared SSH connection does not use AFWS_CONTROL_PERSIST"

# zsh runs the EXIT trap on a normal exit and on HUP, but not on TERM.
for launcher in "$CLAUDE_LAUNCHER" "$CODEX_LAUNCHER"; do
  grep -q "trap 'release; exit 143' TERM" "$launcher" || \
    fail "${launcher:t} does not release what it holds on SIGTERM"
  grep -q "trap 'release; exit 129' HUP" "$launcher" || \
    fail "${launcher:t} does not release what it holds on SIGHUP"
done

# AFWS_STATE_DIR decides where the registry and the socket are written, and
# AFWS_MOUNT_BASE decides what this tool is willing to unmount.
expect_rejected "a relative state directory" \
  env AFWS_STATE_DIR=relative-state "$PEERS" --count
expect_rejected "the filesystem root as a state directory" \
  env AFWS_STATE_DIR=/ "$PEERS" --count
expect_rejected "a relative mount base" \
  env AFWS_MOUNT_BASE=relative-mounts "$PEERS" --count
expect_rejected "a mount base containing the home directory" \
  env AFWS_MOUNT_BASE="${HOME:h}" "$PEERS" --count
expect_rejected "a mount base that is the home directory" \
  env AFWS_MOUNT_BASE="$HOME" "$PEERS" --count
expect_rejected "an arbitrary command as the mount-table source" \
  env AFWS_MOUNT_COMMAND='touch /tmp/afws-should-not-exist' "$PEERS" --count
[[ ! -e /tmp/afws-should-not-exist ]] || fail "AFWS_MOUNT_COMMAND ran an arbitrary command"

# The two accepted shapes still work.
AFWS_MOUNT_COMMAND=mount "$PEERS" --count >/dev/null || fail "'mount' was rejected as the mount-table source"
: > "${SANDBOX}/empty-table"
AFWS_MOUNT_COMMAND="cat ${SANDBOX}/empty-table" "$PEERS" --count >/dev/null || \
  fail "'cat FILE' was rejected as the mount-table source"

# --- launchers: dry run ---------------------------------------------------

reset_state
claude_plan="$("$CLAUDE_LAUNCHER" --dry-run example-workstation /remote/project)"
[[ "$claude_plan" == *"Would mount"* ]] || fail "claudefws dry run did not plan a mount"
[[ "$claude_plan" == *"Would start Claude with"* ]] || fail "claudefws dry run did not plan a launch"
[[ "$claude_plan" == *"--permission-mode auto"* ]] || fail "claudefws dry run did not plan the auto permission mode"
[[ "$claude_plan" == *"--name fws-example-workstation-project-1"* ]] || fail "claudefws dry run did not plan a session name"
[[ "$claude_plan" == *"--append-system-prompt"* ]] || fail "claudefws dry run did not plan session instructions"
[[ "$claude_plan" == *"shared SSH connection at ${AFWS_STATE_DIR}/control/example-workstation.sock"* ]] || \
  fail "claudefws dry run did not plan the shared SSH connection"
[[ "$claude_plan" == *"Would label locally-run shell commands"* ]] || \
  fail "claudefws dry run did not mention labelling local shell commands"

[[ -d "$AFWS_MOUNT_BASE" ]] && fail "claudefws dry run created a mount directory"
[[ -e "${AFWS_STATE_DIR}/control" ]] && fail "claudefws dry run created a control directory"
[[ -e "${AFWS_STATE_DIR}/sessions/fws-example-workstation-project-1.conf" ]] && \
  fail "claudefws dry run wrote a session record"

codex_plan="$("$CODEX_LAUNCHER" --dry-run example-workstation /remote/project)"
[[ "$codex_plan" == *"Would mount"* ]] || fail "codexfws dry run did not plan a mount"
[[ "$codex_plan" == *"Would start Codex with"* ]] || fail "codexfws dry run did not plan a launch"
[[ "$codex_plan" == *"--sandbox workspace-write"* ]] || fail "codexfws dry run lost the sandbox flag"
[[ "$codex_plan" == *"--ask-for-approval on-request"* ]] || fail "codexfws dry run lost the approval flag"
[[ "$codex_plan" == *"developer_instructions="* ]] || fail "codexfws dry run did not plan session instructions"
[[ "$codex_plan" == *"--name "* ]] && fail "codexfws planned a --name flag that Codex does not have"
[[ "$codex_plan" == *"Would label locally-run shell commands"* ]] && \
  fail "codexfws planned a shell marker that Codex cannot use"

# Both launchers must agree on where the mount and the socket go.
[[ "$codex_plan" == *"${AFWS_MOUNT_BASE}/example-workstation/remote/project"* ]] || \
  fail "codexfws planned a different mount point from claudefws"
[[ "$codex_plan" == *"${AFWS_STATE_DIR}/control/example-workstation.sock"* ]] || \
  fail "codexfws planned a different shared connection from claudefws"
[[ "$codex_plan" == *"session: cx-example-workstation-project-1"* ]] || \
  fail "codexfws did not allocate its own session name"

background_plan="$("$CLAUDE_LAUNCHER" --dry-run --bg example-workstation /remote/project)"
[[ "$background_plan" == *"Would start Claude in the background with"* ]] || \
  fail "claudefws dry run did not plan a background session"
[[ "$background_plan" == *"claude --bg --permission-mode auto"* ]] || \
  fail "claudefws background dry run did not plan claude --bg"
expect_rejected "a background flag for codexfws" "$CODEX_LAUNCHER" --bg example-workstation /remote/project

# --- launchers: naming and validation ------------------------------------

reset_state
write_record fws-example-workstation-project-1 claude "$$" example-workstation /remote/project "$(date +%s)"
collision="$("$CLAUDE_LAUNCHER" --dry-run example-workstation /remote/project)"
[[ "$collision" == *"--name fws-example-workstation-project-2"* ]] || \
  fail "claudefws reused a session name that is already registered"

reset_state
named="$(AFWS_SESSION_NAME=gpu-watcher "$CLAUDE_LAUNCHER" --dry-run example-workstation /remote/project)"
[[ "$named" == *"--name gpu-watcher"* ]] || fail "claudefws ignored AFWS_SESSION_NAME"
codex_named="$(AFWS_SESSION_NAME=gpu-watcher "$CODEX_LAUNCHER" --dry-run example-workstation /remote/project)"
[[ "$codex_named" == *"session: gpu-watcher"* ]] || fail "codexfws ignored AFWS_SESSION_NAME"

mode_plan="$(AFWS_PERMISSION_MODE=manual "$CLAUDE_LAUNCHER" --dry-run example-workstation /remote/project)"
[[ "$mode_plan" == *"--permission-mode manual"* ]] || fail "claudefws ignored AFWS_PERMISSION_MODE"

quiet_plan="$(AFWS_NO_SHELL_MARKER=1 "$CLAUDE_LAUNCHER" --dry-run example-workstation /remote/project)"
[[ "$quiet_plan" != *"Would label locally-run shell commands"* ]] || \
  fail "AFWS_NO_SHELL_MARKER did not disable labelling"

no_master="$(AFWS_NO_CONTROL_MASTER=1 "$CLAUDE_LAUNCHER" --dry-run example-workstation /remote/project)"
[[ "$no_master" != *"shared SSH connection"* ]] || \
  fail "AFWS_NO_CONTROL_MASTER did not disable the shared connection"

for launcher in "$CLAUDE_LAUNCHER" "$CODEX_LAUNCHER"; do
  expect_rejected "a relative remote directory (${launcher:t})" "$launcher" --dry-run example-workstation relative
  expect_rejected "the remote filesystem root (${launcher:t})" "$launcher" --dry-run example-workstation /
  expect_rejected "an invalid SSH config host name (${launcher:t})" "$launcher" --dry-run 'invalid host' /remote/project
  expect_rejected "a parent-directory segment (${launcher:t})" "$launcher" --dry-run example-workstation /remote/../project
  expect_rejected "repeated slashes (${launcher:t})" "$launcher" --dry-run example-workstation //remote/project
  expect_rejected "a single positional argument (${launcher:t})" "$launcher" --dry-run example-workstation
  expect_rejected "an invalid explicit session name (${launcher:t})" \
    env AFWS_SESSION_NAME='bad name' "$launcher" --dry-run example-workstation /remote/project
done

expect_rejected "an unsupported permission mode" \
  env AFWS_PERMISSION_MODE=nonsense "$CLAUDE_LAUNCHER" --dry-run example-workstation /remote/project

# A Unix domain socket path cannot exceed 104 bytes.
long_state="/tmp/$(printf 'x%.0s' {1..90})"
expect_rejected "a socket path that cannot fit in a Unix socket" \
  env AFWS_STATE_DIR="$long_state" "$CLAUDE_LAUNCHER" --dry-run example-workstation /remote/project
long_ok="$(AFWS_STATE_DIR="$long_state" AFWS_NO_CONTROL_MASTER=1 \
  "$CLAUDE_LAUNCHER" --dry-run example-workstation /remote/project)"
[[ "$long_ok" == *"Would mount"* ]] || \
  fail "the socket-length guard fired even with the shared connection disabled"

# --- extra local directories ---------------------------------------------
# Local reference material read in the same session that works on the remote
# project, so the two do not live in separate sessions with separate histories.

reset_state
mkdir -p "${SANDBOX}/papers" "${SANDBOX}/notes"
extra_plan="$(AFWS_ADD_DIR="${SANDBOX}/papers:${SANDBOX}/notes" \
  "$CLAUDE_LAUNCHER" --dry-run example-workstation /remote/project)"
[[ "$extra_plan" == *"also:    ${SANDBOX}/papers"* ]] || fail "claudefws did not report an extra directory"
[[ "$extra_plan" == *"also:    ${SANDBOX}/notes"* ]] || fail "claudefws dropped the second extra directory"
[[ "$extra_plan" == *"--add-dir ${SANDBOX}/papers ${SANDBOX}/notes"* ]] || \
  fail "claudefws did not plan to pass the extra directories to Claude Code"

no_extra="$("$CLAUDE_LAUNCHER" --dry-run example-workstation /remote/project)"
[[ "$no_extra" != *--add-dir* ]] || fail "claudefws planned --add-dir with nothing to add"

expect_rejected "a relative extra directory" \
  env AFWS_ADD_DIR=relative "$CLAUDE_LAUNCHER" --dry-run example-workstation /remote/project
expect_rejected "an extra directory that does not exist" \
  env AFWS_ADD_DIR=/nonexistent-afws-dir "$CLAUDE_LAUNCHER" --dry-run example-workstation /remote/project

# Refusing before the mount matters: otherwise a typo costs a mount.
early="$(env AFWS_ADD_DIR=relative "$CLAUDE_LAUNCHER" --dry-run example-workstation /remote/project 2>&1 || true)"
[[ "$early" != *"Would mount"* ]] || fail "an invalid extra directory was reported only after planning a mount"

codex_note="$(AFWS_ADD_DIR="${SANDBOX}/papers" \
  "$CODEX_LAUNCHER" --dry-run example-workstation /remote/project 2>&1 >/dev/null)"
[[ "$codex_note" == *"AFWS_ADD_DIR is not needed here"* ]] || \
  fail "codexfws did not explain that it reads outside the workspace already"

# --- mount table ----------------------------------------------------------
# The launchers read the mount table through AFWS_MOUNT_COMMAND, so reuse and
# nesting can be checked without mounting anything.

reset_state
readonly FAKE_MOUNTS="${SANDBOX}/mounts.txt"
readonly FAKE_ROOT="${AFWS_MOUNT_BASE}/example-workstation/remote/project"
mkdir -p "${FAKE_ROOT}/inner"

print -r -- "example-workstation:/remote/project on ${FAKE_ROOT} (macfuse, nodev, nosuid)" > "$FAKE_MOUNTS"

for launcher in "$CLAUDE_LAUNCHER" "$CODEX_LAUNCHER"; do
  reuse="$(AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" "$launcher" --dry-run example-workstation /remote/project/inner)"
  [[ "$reuse" == *"Reusing SSHFS mount: example-workstation:/remote/project"* ]] || \
    fail "${launcher:t} did not reuse a mount that already covers the requested directory"
  [[ "$reuse" == *"${FAKE_ROOT}/inner"* ]] || \
    fail "${launcher:t} did not point the workspace at the subdirectory of the reused mount"
done

# Mounting a home directory is allowed but must say what it costs.
print -r -- "example-workstation:/remote/project on ${FAKE_ROOT} (macfuse, nodev, nosuid)" > "$FAKE_MOUNTS"
[[ "$(AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" "$CLAUDE_LAUNCHER" --dry-run example-workstation /remote/project 2>&1 >/dev/null)" == "" ]] || \
  fail "a plain project workspace was reported as a home directory"

# A project keeps its own .claude next to .git, so that is not a home signal.
mkdir -p "${FAKE_ROOT}/.claude" "${FAKE_ROOT}/.git"
print -r -- '{"permissions":{"allow":[]}}' > "${FAKE_ROOT}/.claude/settings.json"
[[ "$(AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" "$CLAUDE_LAUNCHER" --dry-run example-workstation /remote/project 2>&1 >/dev/null)" == "" ]] || \
  fail "a project with its own .claude was mistaken for a home directory"

mkdir -p "${FAKE_ROOT}/.ssh"

home_warning="$(AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" \
  "$CLAUDE_LAUNCHER" --dry-run example-workstation /remote/project 2>&1 >/dev/null)"
[[ "$home_warning" == *"looks like a home directory"* ]] || \
  fail "a workspace containing .ssh and .claude was not flagged as a home directory"
[[ "$home_warning" == *".claude/settings.json"* ]] || \
  fail "the home-directory warning did not mention the project settings it pulls in"
[[ "$home_warning" == *AFWS_ALLOW_HOME_MOUNT* ]] || \
  fail "the home-directory warning did not say how to silence it"

silenced="$(AFWS_ALLOW_HOME_MOUNT=1 AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" \
  "$CLAUDE_LAUNCHER" --dry-run example-workstation /remote/project 2>&1 >/dev/null)"
[[ "$silenced" != *"looks like a home directory"* ]] || \
  fail "AFWS_ALLOW_HOME_MOUNT did not silence the home-directory warning"

codex_warning="$(AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" \
  "$CODEX_LAUNCHER" --dry-run example-workstation /remote/project 2>&1 >/dev/null)"
[[ "$codex_warning" == *"looks like a home directory"* ]] || \
  fail "codexfws did not flag a home directory"
[[ "$codex_warning" != *"Claude Code loads"* ]] || \
  fail "codexfws claimed Claude Code would load the settings file"

rm -rf "${FAKE_ROOT}/.ssh" "${FAKE_ROOT}/.claude" "${FAKE_ROOT}/.git"

print -r -- "example-workstation:/remote/project/inner on ${FAKE_ROOT}/inner (macfuse, nodev, nosuid)" > "$FAKE_MOUNTS"

expect_rejected "a mount that would hide another session's mount underneath it" \
  env AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" "$CLAUDE_LAUNCHER" --dry-run example-workstation /remote/project

sibling="$(AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" "$CLAUDE_LAUNCHER" --dry-run example-workstation /remote/project/other)"
[[ "$sibling" == *"Would mount"* ]] || fail "a sibling directory did not get its own mount"

print -r -- "other-host:/remote/project on ${AFWS_MOUNT_BASE}/other-host/remote/project (macfuse)" > "$FAKE_MOUNTS"
other_host="$(AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" "$CLAUDE_LAUNCHER" --dry-run example-workstation /remote/project)"
[[ "$other_host" == *"Would mount"* ]] || fail "a mount belonging to another host was reused"

# A mount that exists but cannot be read stands for a dead macFUSE mount.
unreadable="${AFWS_MOUNT_BASE}/example-workstation/remote/dead"
mkdir -p "$unreadable"
chmod 000 "$unreadable"
if ! ls -1 "$unreadable" >/dev/null 2>&1; then
  print -r -- "example-workstation:/remote/dead on ${unreadable} (macfuse)" > "$FAKE_MOUNTS"
  stale="$(AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" "$CLAUDE_LAUNCHER" --dry-run example-workstation /remote/dead 2>&1 || true)"
  [[ "$stale" == *"present but not responding"* ]] || \
    fail "a mount that does not respond to a directory read was reused"
  [[ "$stale" == *"diskutil unmount force"* ]] || \
    fail "the stale-mount message did not offer a way out"
fi
chmod 755 "$unreadable"

# --- afws-run -------------------------------------------------------------

runner_plan="$("$RUNNER" example-workstation --cwd /remote/project --dry-run -- printf '%s' 'hello world')"
[[ "$runner_plan" == ssh\ example-workstation* ]] || fail "afws-run did not plan SSH execution"

stdin_plan="$(print -r -- 'echo remote-script' | "$RUNNER" example-workstation --cwd /remote/project --dry-run)"
[[ "$stdin_plan" == *"bash\\ -s"* ]] || fail "afws-run did not plan Bash standard-input execution"

quoted="$("$RUNNER" example-workstation --cwd '/remote/project' --dry-run -- printf '%s' '$(not-a-command)')"
[[ "$quoted" != *'$(not-a-command)'* ]] || fail "afws-run left a command substitution unquoted"

environment_plan="$(AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  "$RUNNER" --dry-run -- pwd)"
[[ "$environment_plan" == ssh\ example-workstation* ]] || \
  fail "afws-run did not take the host and directory from the session environment"

environment_stdin="$(print -r -- 'echo remote-script' | \
  AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project "$RUNNER" --dry-run)"
[[ "$environment_stdin" == *"bash\\ -s"* ]] || \
  fail "afws-run did not accept a piped script using the session environment"

expect_rejected "the remote filesystem root" "$RUNNER" example-workstation --cwd / --dry-run -- pwd
expect_rejected "a control character in the remote path" \
  "$RUNNER" example-workstation --cwd $'/remote/project\nsecond' --dry-run -- pwd
expect_rejected "a relative remote path" "$RUNNER" example-workstation --cwd relative --dry-run -- pwd
expect_rejected "an invalid SSH config host name" "$RUNNER" 'invalid host' --cwd /remote/project --dry-run -- pwd
expect_rejected "a missing host with no session environment" "$RUNNER" --dry-run -- pwd
expect_rejected "a piped script with no host anywhere" \
  env -u AFWS_SSH_HOST sh -c "print -r -- pwd | '$RUNNER' --dry-run"

# --- shared SSH connection reuse -----------------------------------------

if command -v python3 >/dev/null 2>&1; then
  short_state="/tmp/afws-sock-$$"
  mkdir -p "${short_state}/control"
  socket_path="${short_state}/control/example-workstation.sock"
  python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1)' "$socket_path" ||
    fail "could not create a test socket"

  shared="$(AFWS_STATE_DIR="$short_state" "$RUNNER" example-workstation --cwd /remote/project --dry-run -- pwd)"
  [[ "$shared" == *"-S ${socket_path}"* ]] || fail "afws-run did not reuse the shared SSH connection"

  shared_lock="$(AFWS_STATE_DIR="$short_state" "$LOCK" status --host example-workstation --dry-run)"
  [[ "$shared_lock" == *"-S ${socket_path}"* ]] || fail "afws-lock did not reuse the shared SSH connection"

  other="$(AFWS_STATE_DIR="$short_state" "$RUNNER" other-workstation --cwd /remote/project --dry-run -- pwd)"
  [[ "$other" != *"-S "* ]] || fail "afws-run reused a connection belonging to another host"

  mismatch="$(AFWS_STATE_DIR="$short_state" AFWS_CONTROL_PATH="$socket_path" \
    AFWS_SSH_HOST=example-workstation "$RUNNER" other-workstation --cwd /remote/project --dry-run -- pwd)"
  [[ "$mismatch" != *"-S "* ]] || fail "afws-run applied the session socket to a different host"

  rm -rf "$short_state"
fi

# --- afws-peers -----------------------------------------------------------

reset_state
write_record fws-alpha-live claude "$$" alpha /remote/project 1000000000
write_record fws-alpha-dead claude 999999 alpha /remote/other 1000000000
write_record cx-alpha-live codex "$$" alpha /remote/project 1000000000
write_record fws-beta-live claude "$$" beta /srv/thing 1000000000

listing="$("$PEERS")"
[[ "$listing" == *AGENT* ]] || fail "afws-peers did not print an AGENT column"
[[ "$listing" == *fws-alpha-live* ]] || fail "afws-peers hid a live Claude session"
[[ "$listing" == *cx-alpha-live* ]] || fail "afws-peers hid a live Codex session"
[[ "$listing" == *fws-beta-live* ]] || fail "afws-peers hid a session on another host"
[[ "$listing" != *fws-alpha-dead* ]] || fail "afws-peers listed a dead session"
[[ ! -e "${AFWS_STATE_DIR}/sessions/fws-alpha-dead.conf" ]] || \
  fail "afws-peers did not prune the dead session record"
[[ "$listing" == *codex* ]] || fail "afws-peers did not report the agent of a Codex session"

host_listing="$("$PEERS" --host alpha)"
[[ "$host_listing" == *cx-alpha-live* ]] || fail "afws-peers --host dropped a matching session"
[[ "$host_listing" != *fws-beta-live* ]] || fail "afws-peers --host kept a session on another host"

same_listing="$(AFWS_SESSION_NAME=fws-alpha-live AFWS_SSH_HOST=alpha \
  AFWS_REMOTE_DIR=/remote/project "$PEERS" --same)"
[[ "$same_listing" == *"(this session)"* ]] || fail "afws-peers --same did not mark the current session"
[[ "$same_listing" == *cx-alpha-live* ]] || \
  fail "afws-peers --same hid a session of the other agent in the same directory"
[[ "$same_listing" != *fws-beta-live* ]] || fail "afws-peers --same kept a session elsewhere"

peer_count="$(AFWS_SESSION_NAME=fws-alpha-live "$PEERS" --count)"
[[ "$peer_count" == 2 ]] || fail "afws-peers --count did not exclude the current session (got ${peer_count})"

json_listing="$("$PEERS" --json)"
[[ "$json_listing" == \[* ]] || fail "afws-peers --json did not produce a JSON array"
[[ "$json_listing" == *'"agent":"codex"'* ]] || fail "afws-peers --json omitted the agent"
if command -v plutil >/dev/null 2>&1; then
  # plutil -lint rejects a top-level array, so parse it instead of linting it.
  print -r -- "$json_listing" | plutil -convert json -o /dev/null -- - 2>/dev/null || \
    fail "afws-peers --json produced invalid JSON"
fi

reset_state
write_record fws-alpha-dead claude 999999 alpha /remote/other 1000000000
"$PEERS" --no-prune >/dev/null
[[ -e "${AFWS_STATE_DIR}/sessions/fws-alpha-dead.conf" ]] || fail "afws-peers --no-prune deleted a record"

expect_rejected "contradictory prune options" "$PEERS" --prune --no-prune
expect_rejected "an invalid SSH config host name" "$PEERS" --host 'invalid host'
expect_rejected "an unknown option" "$PEERS" --nonsense

# --- releasing mounts -----------------------------------------------------

reset_state
readonly RELEASE_POINT="${AFWS_MOUNT_BASE}/example-workstation/remote/project"
mkdir -p "${RELEASE_POINT}/inner"
print -r -- "example-workstation:/remote/project on ${RELEASE_POINT} (macfuse, nodev, nosuid)" > "$FAKE_MOUNTS"

[[ "$("$PEERS" --users-of-mount "$RELEASE_POINT")" == 0 ]] || fail "an unused mount was reported as in use"

write_record fws-release-1 claude "$$" example-workstation /remote/project "$(date +%s)" "$RELEASE_POINT" "$RELEASE_POINT"
[[ "$("$PEERS" --users-of-mount "$RELEASE_POINT")" == 1 ]] || fail "a session in the mount was not counted"

write_record cx-release-2 codex "$$" example-workstation /remote/project "$(date +%s)" "${RELEASE_POINT}/inner" "$RELEASE_POINT"
[[ "$("$PEERS" --users-of-mount "$RELEASE_POINT")" == 2 ]] || \
  fail "a session of the other agent sharing the mount was not counted"

[[ "$(AFWS_SESSION_NAME=fws-release-1 "$PEERS" --users-of-mount "$RELEASE_POINT")" == 1 ]] || \
  fail "--users-of-mount did not exclude the current session"
[[ "$(AFWS_SESSION_NAME=fws-release-1 "$PEERS" --users-of-host example-workstation)" == 1 ]] || \
  fail "--users-of-host did not exclude the current session"
[[ "$("$PEERS" --users-of-host other-workstation)" == 0 ]] || \
  fail "--users-of-host counted a session on another host"

umount_list="$(AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" "$UMOUNT" --list)"
[[ "$umount_list" == *"${RELEASE_POINT}"* ]] || fail "afws-umount --list hid a mount"
[[ "$umount_list" == *2* ]] || fail "afws-umount --list did not report the session count"

orphan_plan="$(AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" "$UMOUNT" --orphaned --dry-run)"
[[ "$orphan_plan" == *"still in use"* ]] || \
  fail "afws-umount --orphaned offered to release a mount that is in use"

expect_rejected "unmounting a mount live sessions are working in" \
  env AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" "$UMOUNT" example-workstation /remote/project --dry-run

rm -f "${AFWS_STATE_DIR}/sessions/"*.conf
release_plan="$(AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" "$UMOUNT" example-workstation /remote/project --dry-run)"
[[ "$release_plan" == *"Would unmount ${RELEASE_POINT}"* ]] || \
  fail "afws-umount did not plan to release an unused mount"

orphan_plan="$(AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" "$UMOUNT" --orphaned --dry-run)"
[[ "$orphan_plan" == *"Would unmount ${RELEASE_POINT}"* ]] || \
  fail "afws-umount --orphaned did not plan to release an unused mount"

not_mounted="$(AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" "$UMOUNT" example-workstation /remote/elsewhere --dry-run)"
[[ "$not_mounted" == *"Not mounted"* ]] || fail "afws-umount did not report an absent mount"

expect_rejected "an invalid host for afws-umount" "$UMOUNT" 'invalid host' /remote/project
expect_rejected "a relative directory for afws-umount" "$UMOUNT" example-workstation relative
expect_rejected "--orphaned combined with a host" "$UMOUNT" --orphaned example-workstation /remote/project

reset_state

# --- afws-shell -----------------------------------------------------------

marker_out="$("$SHELL_WRAPPER" 'echo only-stdout' 2>/dev/null)"
[[ "$marker_out" == only-stdout ]] || fail "the shell wrapper altered standard output"

marker_err="$("$SHELL_WRAPPER" 'echo ignored' 2>&1 >/dev/null)"
[[ "$marker_err" == '[mac] ' ]] || fail "the shell wrapper did not label the command on stderr"

marker_status=0
"$SHELL_WRAPPER" 'exit 42' >/dev/null 2>&1 || marker_status=$?
(( marker_status == 42 )) || fail "the shell wrapper did not propagate the exit status"

# These probes exit 127 on purpose, so the substitution must not take the whole
# script down under 'set -e'.
hint="$(AFWS_SSH_HOST=example-workstation \
  "$SHELL_WRAPPER" 'definitely-not-a-command-xyz' 2>&1 >/dev/null || true)"
[[ "$hint" == *"for example-workstation, use: afws-run"* ]] || \
  fail "the shell wrapper did not suggest afws-run for a command that is not installed here"

no_hint="$(env -u AFWS_SSH_HOST "$SHELL_WRAPPER" 'definitely-not-a-command-xyz' 2>&1 >/dev/null || true)"
[[ "$no_hint" != *afws-run* ]] || fail "the shell wrapper suggested afws-run outside a session"

custom_marker="$(AFWS_MARKER=laptop "$SHELL_WRAPPER" 'true' 2>&1 >/dev/null)"
[[ "$custom_marker" == '[laptop] ' ]] || fail "the shell wrapper ignored AFWS_MARKER"

# If the single-argument contract ever changes, the wrapper must not eat the
# command: it becomes a transparent shell instead.
passthrough="$("$SHELL_WRAPPER" /bin/sh -c 'echo passthrough-ok' 2>/dev/null)"
[[ "$passthrough" == passthrough-ok ]] || fail "the shell wrapper did not fall back to a transparent shell"

# AFWS_SHELL exists for unusual setups, but a value that cannot be executed
# must not break every command in the session.
fallback="$(AFWS_SHELL=/nonexistent/shell "$SHELL_WRAPPER" 'echo fell-back' 2>/dev/null)"
[[ "$fallback" == fell-back ]] || fail "the shell wrapper did not fall back from an unusable AFWS_SHELL"

# --- releasing shared connections ----------------------------------------

if command -v python3 >/dev/null 2>&1; then
  reset_state
  mkdir -p "${AFWS_STATE_DIR}/control"
  orphan_socket="${AFWS_STATE_DIR}/control/example-workstation.sock"
  python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1)' "$orphan_socket" ||
    fail "could not create a test socket"

  : > "$FAKE_MOUNTS"
  connection_list="$(AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" "$UMOUNT" --list)"
  [[ "$connection_list" == *"shared SSH connection to example-workstation"* ]] || \
    fail "afws-umount --list did not show a shared connection"

  connection_plan="$(AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" "$UMOUNT" --orphaned --dry-run)"
  [[ "$connection_plan" == *"Would close the shared SSH connection to example-workstation"* ]] || \
    fail "afws-umount --orphaned did not offer to close an unused connection"

  write_record fws-holder claude "$$" example-workstation /remote/project "$(date +%s)"
  held_plan="$(AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" "$UMOUNT" --orphaned --dry-run)"
  [[ "$held_plan" != *"Would close the shared SSH connection"* ]] || \
    fail "afws-umount --orphaned offered to close a connection a live session is using"

  reset_state
fi

# --- afws-lock ------------------------------------------------------------

lock_plan="$("$LOCK" acquire gpu0 --host example-workstation --dry-run)"
[[ "$lock_plan" == ssh\ example-workstation* ]] || fail "afws-lock did not plan SSH execution"
[[ "$lock_plan" == *"--- remote script ---"* ]] || fail "afws-lock did not show the remote script"
[[ "$lock_plan" == *'\~/.afws-locks'* ]] || \
  fail "afws-lock did not keep the remote lock root unexpanded for the remote shell"

environment_lock="$(AFWS_SSH_HOST=example-workstation "$LOCK" status --dry-run)"
[[ "$environment_lock" == ssh\ example-workstation* ]] || \
  fail "afws-lock did not take the host from the session environment"

expect_rejected "an invalid lock name" "$LOCK" acquire 'bad name' --host example-workstation --dry-run
expect_rejected "a missing lock name" "$LOCK" acquire --host example-workstation --dry-run
expect_rejected "a missing SSH host" env -u AFWS_SSH_HOST "$LOCK" acquire gpu0 --dry-run
expect_rejected "an unknown action" "$LOCK" frobnicate gpu0 --host example-workstation --dry-run
expect_rejected "a non-numeric wait" "$LOCK" acquire gpu0 --host example-workstation --wait soon --dry-run
expect_rejected "a non-numeric ttl" "$LOCK" acquire gpu0 --host example-workstation --ttl forever --dry-run
expect_rejected "a relative remote lock root" \
  env AFWS_REMOTE_LOCK_DIR=relative/locks "$LOCK" acquire gpu0 --host example-workstation --dry-run

# The remote half of the lock is a plain POSIX script, so it can be exercised
# here against a throwaway directory instead of a real workstation.
readonly LOCK_BASE="${SANDBOX}/locks"
mkdir -p "$LOCK_BASE"

remote_lock_script() {
  "$LOCK" "$1" "${2:-}" --host example-workstation --dry-run 2>/dev/null |
    sed -n '/^--- remote script ---$/,$p' | tail -n +2
}

run_remote_lock() {
  local action="$1" name="$2" holder="$3" force="$4"
  local script_file="${SANDBOX}/remote-lock.sh"
  local exit_status=0

  remote_lock_script "$action" "$name" > "$script_file"
  bash "$script_file" "$name" "$holder" 60 "$LOCK_BASE" "$force" || exit_status=$?
  return "$exit_status"
}

run_remote_lock acquire gpu0 session-a 0 >/dev/null || fail "the remote lock could not be acquired"
lock_base_mode="$(stat -f '%Sp' "$LOCK_BASE")"
[[ "$lock_base_mode" == drwx------ ]] || \
  fail "the remote lock root is not owner-only (${lock_base_mode}); it is on a shared machine"

held_status=0
run_remote_lock acquire gpu0 session-b 0 >/dev/null || held_status=$?
(( held_status == 3 )) || fail "a held lock was handed to a second session (status ${held_status})"

held_report="$(run_remote_lock status '' session-b 0)"
[[ "$held_report" == held\ gpu0* ]] || fail "lock status did not report the lock as held"
[[ "$held_report" == *holder=session-a* ]] || fail "lock status did not name the holder"

refused_status=0
run_remote_lock release gpu0 session-b 0 >/dev/null || refused_status=$?
(( refused_status == 4 )) || fail "a session released a lock it does not hold (status ${refused_status})"

steal_report="$(run_remote_lock release gpu0 session-b 1)"
[[ "$steal_report" == stole\ gpu0\ from\ session-a* ]] || fail "an explicit steal did not name the previous holder"

run_remote_lock acquire gpu0 session-b 0 >/dev/null || fail "a released lock could not be re-acquired"
released_report="$(run_remote_lock release gpu0 session-b 0)"
[[ "$released_report" == released\ gpu0* ]] || fail "a held lock was not released by its holder"

free_report="$(run_remote_lock status gpu0 session-b 0)"
[[ "$free_report" == free\ gpu0* ]] || fail "lock status did not report a free lock"

print -r -- "All tests passed."
