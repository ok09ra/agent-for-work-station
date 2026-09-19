#!/bin/zsh

set -eu

readonly REPOSITORY_ROOT="${0:A:h:h}"
readonly LAUNCHER="${REPOSITORY_ROOT}/bin/claudefws"
readonly RUNNER="${REPOSITORY_ROOT}/bin/claudefws-run"
readonly PEERS="${REPOSITORY_ROOT}/bin/claudefws-peers"
readonly LOCK="${REPOSITORY_ROOT}/bin/claudefws-lock"
readonly UMOUNT="${REPOSITORY_ROOT}/bin/claudefws-umount"
readonly WS_RUN="${REPOSITORY_ROOT}/bin/ws-run"
readonly SHELL_WRAPPER="${REPOSITORY_ROOT}/bin/claudefws-shell"

# Kept short on purpose: the shared-connection socket lives under this
# directory and a Unix domain socket path is limited to 104 bytes.
readonly SANDBOX="$(mktemp -d /tmp/claudefws-test.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

# Every test runs against a throwaway registry and mount root, and no test
# ever reaches ssh, sshfs, or a real Claude session.
export CLAUDEFWS_STATE_DIR="${SANDBOX}/state"
export CLAUDEFWS_MOUNT_BASE="${SANDBOX}/mounts"
unset CLAUDEFWS_SESSION_NAME CLAUDEFWS_SSH_HOST CLAUDEFWS_REMOTE_DIR 2>/dev/null || true

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
  rm -rf "$CLAUDEFWS_STATE_DIR"
  mkdir -p "${CLAUDEFWS_STATE_DIR}/sessions"
}

write_record() {
  local name="$1" kind="$2" pid="$3" host="$4" remote="$5" epoch="$6"
  mkdir -p "${CLAUDEFWS_STATE_DIR}/sessions"
  {
    print -r -- "session_name=${name}"
    print -r -- "kind=${kind}"
    print -r -- "pid=${pid}"
    print -r -- "bg_id="
    print -r -- "ssh_host=${host}"
    print -r -- "remote_dir=${remote}"
    print -r -- "local_workspace=${CLAUDEFWS_MOUNT_BASE}/${host}${remote}"
    print -r -- "started_at=2026-01-01T00:00:00Z"
    print -r -- "started_epoch=${epoch}"
  } > "${CLAUDEFWS_STATE_DIR}/sessions/${name}.conf"
}

# --- syntax ---------------------------------------------------------------

for script in \
  "$LAUNCHER" \
  "$RUNNER" \
  "$PEERS" \
  "$LOCK" \
  "$UMOUNT" \
  "$WS_RUN" \
  "${REPOSITORY_ROOT}/scripts/install.sh" \
  "${REPOSITORY_ROOT}/scripts/doctor.sh" \
  "${REPOSITORY_ROOT}/scripts/prepublish-check.sh"; do
  zsh -n "$script" || fail "syntax check failed: ${script:t}"
done

# --- documentation --------------------------------------------------------

sh -n "$SHELL_WRAPPER" || fail "syntax check failed: ${SHELL_WRAPPER:t}"

for document in \
  "${REPOSITORY_ROOT}/README.md" \
  "${REPOSITORY_ROOT}/README.ja.md" \
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

for command_path in "$LAUNCHER" "$RUNNER" "$PEERS" "$LOCK" "$UMOUNT" "$WS_RUN"; do
  "$command_path" --help >/dev/null || fail "${command_path:t} --help failed"
done

# --- launcher -------------------------------------------------------------

reset_state
launcher_output="$("$LAUNCHER" --dry-run example-workstation /remote/project)"
[[ "$launcher_output" == *"Would mount"* ]] || fail "launcher dry run did not plan a mount"
[[ "$launcher_output" == *"Would start Claude with"* ]] || fail "launcher dry run did not plan Claude startup"
[[ "$launcher_output" == *"--permission-mode auto"* ]] || fail "launcher dry run did not plan the auto permission mode"
[[ "$launcher_output" == *"--name fws-example-workstation-project-1"* ]] || fail "launcher dry run did not plan a session name"
[[ "$launcher_output" == *"--append-system-prompt"* ]] || fail "launcher dry run did not plan session instructions"

[[ -d "${CLAUDEFWS_MOUNT_BASE}" ]] && fail "launcher dry run created a mount directory"
[[ -e "${CLAUDEFWS_STATE_DIR}/sessions/fws-example-workstation-project-1.conf" ]] && \
  fail "launcher dry run wrote a session record"

background_output="$("$LAUNCHER" --dry-run --bg example-workstation /remote/project)"
[[ "$background_output" == *"Would start Claude in the background with"* ]] || \
  fail "launcher dry run did not plan a background session"
[[ "$background_output" == *"claude --bg --permission-mode auto"* ]] || \
  fail "launcher background dry run did not plan claude --bg"

reset_state
write_record fws-example-workstation-project-1 interactive "$$" example-workstation /remote/project "$(date +%s)"
collision_output="$("$LAUNCHER" --dry-run example-workstation /remote/project)"
[[ "$collision_output" == *"--name fws-example-workstation-project-2"* ]] || \
  fail "launcher reused a session name that is already registered"

reset_state
named_output="$(CLAUDEFWS_SESSION_NAME=gpu-watcher "$LAUNCHER" --dry-run example-workstation /remote/project)"
[[ "$named_output" == *"--name gpu-watcher"* ]] || fail "launcher ignored CLAUDEFWS_SESSION_NAME"

expect_rejected "an unsupported permission mode" \
  env CLAUDEFWS_PERMISSION_MODE=nonsense "$LAUNCHER" --dry-run example-workstation /remote/project

mode_output="$(CLAUDEFWS_PERMISSION_MODE=manual "$LAUNCHER" --dry-run example-workstation /remote/project)"
[[ "$mode_output" == *"--permission-mode manual"* ]] || fail "launcher ignored CLAUDEFWS_PERMISSION_MODE"

expect_rejected "an invalid explicit session name" \
  env CLAUDEFWS_SESSION_NAME='bad name' "$LAUNCHER" --dry-run example-workstation /remote/project
expect_rejected "a relative remote directory" \
  "$LAUNCHER" --dry-run example-workstation relative-directory
expect_rejected "the remote filesystem root" \
  "$LAUNCHER" --dry-run example-workstation /
expect_rejected "an invalid SSH config host name" \
  "$LAUNCHER" --dry-run 'invalid host' /remote/project
expect_rejected "a remote path with a parent-directory segment" \
  "$LAUNCHER" --dry-run example-workstation /remote/../project
expect_rejected "a remote path with repeated slashes" \
  "$LAUNCHER" --dry-run example-workstation //remote/project
expect_rejected "a single positional argument" \
  "$LAUNCHER" --dry-run example-workstation

# --- mount table handling -------------------------------------------------
# The launcher reads the mount table through CLAUDEFWS_MOUNT_COMMAND, so reuse
# and nesting can be checked without mounting anything.

reset_state
readonly FAKE_MOUNTS="${SANDBOX}/mounts.txt"
readonly FAKE_ROOT="${CLAUDEFWS_MOUNT_BASE}/example-workstation/remote/project"
mkdir -p "${FAKE_ROOT}/inner"

print -r -- "example-workstation:/remote/project on ${FAKE_ROOT} (macfuse, nodev, nosuid)" \
  > "$FAKE_MOUNTS"

reuse_output="$(CLAUDEFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" \
  "$LAUNCHER" --dry-run example-workstation /remote/project/inner)"
[[ "$reuse_output" == *"Reusing SSHFS mount: example-workstation:/remote/project"* ]] || \
  fail "launcher did not reuse a mount that already covers the requested directory"
[[ "$reuse_output" == *"${FAKE_ROOT}/inner"* ]] || \
  fail "launcher did not point the workspace at the subdirectory of the reused mount"

print -r -- "example-workstation:/remote/project/inner on ${FAKE_ROOT}/inner (macfuse, nodev, nosuid)" \
  > "$FAKE_MOUNTS"

expect_rejected "a mount that would hide another session's mount underneath it" \
  env CLAUDEFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" \
  "$LAUNCHER" --dry-run example-workstation /remote/project

sibling_output="$(CLAUDEFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" \
  "$LAUNCHER" --dry-run example-workstation /remote/project/other)"
[[ "$sibling_output" == *"Would mount"* ]] || \
  fail "launcher did not plan a separate mount for a sibling directory"

print -r -- "other-host:/remote/project on ${CLAUDEFWS_MOUNT_BASE}/other-host/remote/project (macfuse)" \
  > "$FAKE_MOUNTS"

other_host_mount="$(CLAUDEFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" \
  "$LAUNCHER" --dry-run example-workstation /remote/project)"
[[ "$other_host_mount" == *"Would mount"* ]] || \
  fail "launcher reused a mount belonging to a different host"

reset_state

# --- remote runner --------------------------------------------------------

runner_output="$("$RUNNER" example-workstation --cwd /remote/project --dry-run -- printf '%s' 'hello world')"
[[ "$runner_output" == ssh\ example-workstation* ]] || fail "runner dry run did not plan SSH execution"

stdin_output="$(print -r -- 'echo remote-script' | \
  "$RUNNER" example-workstation --cwd /remote/project --dry-run)"
[[ "$stdin_output" == *"bash\\ -s"* ]] || fail "runner did not plan Bash standard-input execution"

quoted_output="$("$RUNNER" example-workstation --cwd '/remote/project with spaces' --dry-run -- printf '%s' '$(not-a-command)')"
[[ "$quoted_output" == ssh\ example-workstation* ]] || fail "runner did not safely quote shell-sensitive arguments"
[[ "$quoted_output" != *'$(not-a-command)'* ]] || fail "runner left a command substitution unquoted"

environment_output="$(CLAUDEFWS_SSH_HOST=example-workstation CLAUDEFWS_REMOTE_DIR=/remote/project \
  "$RUNNER" --dry-run -- pwd)"
[[ "$environment_output" == ssh\ example-workstation* ]] || \
  fail "runner did not take the host and remote directory from the session environment"

# A shared SSH connection is reused only when the socket exists and belongs to
# the host being addressed.
if command -v python3 >/dev/null 2>&1; then
  # A Unix domain socket path must stay under 104 bytes, which the sandbox
  # directory alone can exceed, so the socket lives in a short directory.
  short_state="/tmp/claudefws-test-$$"
  mkdir -p "${short_state}/control"
  socket_path="${short_state}/control/example-workstation.sock"
  python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1)' "$socket_path" ||
    fail "could not create a test socket"

  shared_output="$(CLAUDEFWS_STATE_DIR="$short_state" \
    "$RUNNER" example-workstation --cwd /remote/project --dry-run -- pwd)"
  [[ "$shared_output" == *"-S ${socket_path}"* ]] || \
    fail "runner did not reuse the shared SSH connection"

  shared_lock="$(CLAUDEFWS_STATE_DIR="$short_state" \
    "$LOCK" status --host example-workstation --dry-run)"
  [[ "$shared_lock" == *"-S ${socket_path}"* ]] || \
    fail "lock did not reuse the shared SSH connection"

  other_host_output="$(CLAUDEFWS_STATE_DIR="$short_state" \
    "$RUNNER" other-workstation --cwd /remote/project --dry-run -- pwd)"
  [[ "$other_host_output" != *"-S "* ]] || \
    fail "runner reused a shared connection belonging to another host"

  wrong_env_output="$(CLAUDEFWS_STATE_DIR="$short_state" \
    CLAUDEFWS_CONTROL_PATH="$socket_path" CLAUDEFWS_SSH_HOST=example-workstation \
    "$RUNNER" other-workstation --cwd /remote/project --dry-run -- pwd)"
  [[ "$wrong_env_output" != *"-S "* ]] || \
    fail "runner applied the session socket to a different host"

  rm -rf "$short_state"
fi

expect_rejected "a shared-connection socket path that cannot fit in a Unix socket" \
  env CLAUDEFWS_STATE_DIR="/tmp/$(printf 'x%.0s' {1..90})" \
  "$LAUNCHER" --dry-run example-workstation /remote/project

# The standard-input script form must also work from the session environment.
environment_stdin="$(print -r -- 'echo remote-script' | \
  CLAUDEFWS_SSH_HOST=example-workstation CLAUDEFWS_REMOTE_DIR=/remote/project \
  "$RUNNER" --dry-run)"
[[ "$environment_stdin" == ssh\ example-workstation* ]] || \
  fail "runner did not accept a piped script using the session environment"
[[ "$environment_stdin" == *"bash\\ -s"* ]] || \
  fail "runner did not plan Bash standard-input execution from the session environment"

expect_rejected "a piped script with no host anywhere" \
  env -u CLAUDEFWS_SSH_HOST sh -c "print -r -- pwd | '$RUNNER' --dry-run"

expect_rejected "the remote filesystem root" \
  "$RUNNER" example-workstation --cwd / --dry-run -- pwd
expect_rejected "a control character in the remote path" \
  "$RUNNER" example-workstation --cwd $'/remote/project\nsecond-line' --dry-run -- pwd
expect_rejected "a relative remote path" \
  "$RUNNER" example-workstation --cwd relative --dry-run -- pwd
expect_rejected "an invalid SSH config host name" \
  "$RUNNER" 'invalid host' --cwd /remote/project --dry-run -- pwd
expect_rejected "a missing host with no session environment" \
  "$RUNNER" --dry-run -- pwd

# --- shell marker ---------------------------------------------------------

marker_out="$("$SHELL_WRAPPER" 'echo only-stdout' 2>/dev/null)"
[[ "$marker_out" == only-stdout ]] || fail "the shell wrapper altered standard output"

marker_err="$("$SHELL_WRAPPER" 'echo ignored' 2>&1 >/dev/null)"
[[ "$marker_err" == '[mac] ' ]] || fail "the shell wrapper did not label the command on stderr"

marker_status=0
"$SHELL_WRAPPER" 'exit 42' >/dev/null 2>&1 || marker_status=$?
(( marker_status == 42 )) || fail "the shell wrapper did not propagate the exit status"

# These probes exit 127 on purpose, so the substitution must not take the whole
# script down under 'set -e'.
hint="$(CLAUDEFWS_SSH_HOST=example-workstation \
  "$SHELL_WRAPPER" 'definitely-not-a-command-xyz' 2>&1 >/dev/null || true)"
[[ "$hint" == *"for example-workstation, use: ws-run"* ]] || \
  fail "the shell wrapper did not suggest ws-run for a command that is not installed here"

no_hint="$(env -u CLAUDEFWS_SSH_HOST \
  "$SHELL_WRAPPER" 'definitely-not-a-command-xyz' 2>&1 >/dev/null || true)"
[[ "$no_hint" != *"ws-run"* ]] || \
  fail "the shell wrapper suggested ws-run outside a Work Station session"

custom_marker="$(CLAUDEFWS_MARKER=laptop "$SHELL_WRAPPER" 'true' 2>&1 >/dev/null)"
[[ "$custom_marker" == '[laptop] ' ]] || fail "the shell wrapper ignored CLAUDEFWS_MARKER"

# If the single-argument contract ever changes, the wrapper must not eat the
# command: it becomes a transparent shell instead.
passthrough="$("$SHELL_WRAPPER" /bin/sh -c 'echo passthrough-ok' 2>/dev/null)"
[[ "$passthrough" == passthrough-ok ]] || fail "the shell wrapper did not fall back to a transparent shell"

reset_state
marker_plan="$("$LAUNCHER" --dry-run example-workstation /remote/project)"
[[ "$marker_plan" == *"Would label locally-run shell commands"* ]] || \
  fail "launcher dry run did not mention labelling local shell commands"

quiet_plan="$(CLAUDEFWS_NO_SHELL_MARKER=1 "$LAUNCHER" --dry-run example-workstation /remote/project)"
[[ "$quiet_plan" != *"Would label locally-run shell commands"* ]] || \
  fail "CLAUDEFWS_NO_SHELL_MARKER did not disable labelling"

# --- ws-run ------------------------------------------------------------------

expect_rejected "ws-run outside a claudefws session" \
  env -u CLAUDEFWS_SSH_HOST "$WS_RUN" nvidia-smi

ws_run_plan="$(CLAUDEFWS_SSH_HOST=example-workstation CLAUDEFWS_REMOTE_DIR=/remote/project \
  CLAUDEFWS_DRY_RUN_PASSTHROUGH=1 "$WS_RUN" --help)"
[[ "$ws_run_plan" == *"claudefws-run -- COMMAND"* ]] || fail "ws-run --help does not name what it wraps"

# --- session registry -----------------------------------------------------

reset_state
write_record fws-alpha-live interactive "$$" alpha /remote/project 1000000000
write_record fws-alpha-dead interactive 999999 alpha /remote/other 1000000000
write_record fws-beta-live interactive "$$" beta /srv/thing 1000000000

listing="$("$PEERS")"
[[ "$listing" == *fws-alpha-live* ]] || fail "peers hid a live session"
[[ "$listing" == *fws-beta-live* ]] || fail "peers hid a live session on another host"
[[ "$listing" != *fws-alpha-dead* ]] || fail "peers listed a dead session"
[[ ! -e "${CLAUDEFWS_STATE_DIR}/sessions/fws-alpha-dead.conf" ]] || \
  fail "peers did not prune the dead session record"

host_listing="$("$PEERS" --host alpha)"
[[ "$host_listing" == *fws-alpha-live* ]] || fail "peers --host dropped a matching session"
[[ "$host_listing" != *fws-beta-live* ]] || fail "peers --host kept a session on another host"

same_listing="$(CLAUDEFWS_SESSION_NAME=fws-alpha-live CLAUDEFWS_SSH_HOST=alpha \
  CLAUDEFWS_REMOTE_DIR=/remote/project "$PEERS" --same)"
[[ "$same_listing" == *"(this session)"* ]] || fail "peers --same did not mark the current session"
[[ "$same_listing" != *fws-beta-live* ]] || fail "peers --same kept a session on another remote directory"

peer_count="$(CLAUDEFWS_SESSION_NAME=fws-alpha-live "$PEERS" --count)"
[[ "$peer_count" == 1 ]] || fail "peers --count did not exclude the current session (got ${peer_count})"

json_listing="$("$PEERS" --json)"
[[ "$json_listing" == \[* ]] || fail "peers --json did not produce a JSON array"
if command -v plutil >/dev/null 2>&1; then
  # plutil -lint rejects a top-level array, so parse it instead of linting it.
  print -r -- "$json_listing" | plutil -convert json -o /dev/null -- - 2>/dev/null || \
    fail "peers --json produced invalid JSON"
fi

reset_state
write_record fws-alpha-dead interactive 999999 alpha /remote/other 1000000000
"$PEERS" --no-prune >/dev/null
[[ -e "${CLAUDEFWS_STATE_DIR}/sessions/fws-alpha-dead.conf" ]] || \
  fail "peers --no-prune deleted a record"

expect_rejected "contradictory prune options" "$PEERS" --prune --no-prune
expect_rejected "an invalid SSH config host name" "$PEERS" --host 'invalid host'
expect_rejected "an unknown option" "$PEERS" --nonsense

# --- releasing mounts -----------------------------------------------------

reset_state
readonly RELEASE_POINT="${CLAUDEFWS_MOUNT_BASE}/example-workstation/remote/project"
mkdir -p "${RELEASE_POINT}/inner"
print -r -- "example-workstation:/remote/project on ${RELEASE_POINT} (macfuse, nodev, nosuid)" \
  > "$FAKE_MOUNTS"

write_mounted_record() {
  local name="$1" workspace="$2"
  mkdir -p "${CLAUDEFWS_STATE_DIR}/sessions"
  {
    print -r -- "session_name=${name}"
    print -r -- "kind=interactive"
    print -r -- "pid=$$"
    print -r -- "bg_id="
    print -r -- "ssh_host=example-workstation"
    print -r -- "remote_dir=/remote/project"
    print -r -- "local_workspace=${workspace}"
    print -r -- "mount_point=${RELEASE_POINT}"
    print -r -- "started_at=2026-01-01T00:00:00Z"
    print -r -- "started_epoch=$(date +%s)"
  } > "${CLAUDEFWS_STATE_DIR}/sessions/${name}.conf"
}

[[ "$("$PEERS" --users-of-mount "$RELEASE_POINT")" == 0 ]] || \
  fail "an unused mount was reported as in use"

write_mounted_record fws-release-1 "$RELEASE_POINT"
[[ "$("$PEERS" --users-of-mount "$RELEASE_POINT")" == 1 ]] || \
  fail "a session working in the mount was not counted"

write_mounted_record fws-release-2 "${RELEASE_POINT}/inner"
[[ "$("$PEERS" --users-of-mount "$RELEASE_POINT")" == 2 ]] || \
  fail "a session working in a subdirectory of the mount was not counted"

[[ "$(CLAUDEFWS_SESSION_NAME=fws-release-1 "$PEERS" --users-of-mount "$RELEASE_POINT")" == 1 ]] || \
  fail "--users-of-mount did not exclude the current session"
[[ "$(CLAUDEFWS_SESSION_NAME=fws-release-1 "$PEERS" --users-of-host example-workstation)" == 1 ]] || \
  fail "--users-of-host did not exclude the current session"
[[ "$("$PEERS" --users-of-host other-workstation)" == 0 ]] || \
  fail "--users-of-host counted a session on another host"

umount_list="$(CLAUDEFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" "$UMOUNT" --list)"
[[ "$umount_list" == *"${RELEASE_POINT}"* ]] || fail "claudefws-umount --list hid a claudefws mount"
[[ "$umount_list" == *"2"* ]] || fail "claudefws-umount --list did not report the session count"

orphan_plan="$(CLAUDEFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" "$UMOUNT" --orphaned --dry-run)"
[[ "$orphan_plan" == *"still in use"* ]] || \
  fail "claudefws-umount --orphaned offered to release a mount that is in use"

expect_rejected "unmounting a mount that live sessions are working in" \
  env CLAUDEFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" \
  "$UMOUNT" example-workstation /remote/project --dry-run

rm -f "${CLAUDEFWS_STATE_DIR}/sessions/"*.conf
release_plan="$(CLAUDEFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" \
  "$UMOUNT" example-workstation /remote/project --dry-run)"
[[ "$release_plan" == *"Would unmount ${RELEASE_POINT}"* ]] || \
  fail "claudefws-umount did not plan to release an unused mount"

orphan_plan="$(CLAUDEFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" "$UMOUNT" --orphaned --dry-run)"
[[ "$orphan_plan" == *"Would unmount ${RELEASE_POINT}"* ]] || \
  fail "claudefws-umount --orphaned did not plan to release an unused mount"

not_mounted="$(CLAUDEFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" \
  "$UMOUNT" example-workstation /remote/elsewhere --dry-run)"
[[ "$not_mounted" == *"Not mounted"* ]] || \
  fail "claudefws-umount did not report an absent mount as not mounted"

expect_rejected "an invalid host for claudefws-umount" "$UMOUNT" 'invalid host' /remote/project
expect_rejected "a relative directory for claudefws-umount" "$UMOUNT" example-workstation relative
expect_rejected "--orphaned combined with a host" "$UMOUNT" --orphaned example-workstation /remote/project

reset_state

# --- remote lock ----------------------------------------------------------

lock_plan="$("$LOCK" acquire gpu0 --host example-workstation --dry-run)"
[[ "$lock_plan" == ssh\ example-workstation* ]] || fail "lock dry run did not plan SSH execution"
[[ "$lock_plan" == *"--- remote script ---"* ]] || fail "lock dry run did not show the remote script"

environment_plan="$(CLAUDEFWS_SSH_HOST=example-workstation "$LOCK" status --dry-run)"
[[ "$environment_plan" == ssh\ example-workstation* ]] || \
  fail "lock did not take the host from the session environment"

expect_rejected "an invalid lock name" "$LOCK" acquire 'bad name' --host example-workstation --dry-run
expect_rejected "a missing lock name" "$LOCK" acquire --host example-workstation --dry-run
expect_rejected "a missing SSH host" env -u CLAUDEFWS_SSH_HOST "$LOCK" acquire gpu0 --dry-run
expect_rejected "an unknown action" "$LOCK" frobnicate gpu0 --host example-workstation --dry-run
expect_rejected "a non-numeric wait" "$LOCK" acquire gpu0 --host example-workstation --wait soon --dry-run
expect_rejected "a non-numeric ttl" "$LOCK" acquire gpu0 --host example-workstation --ttl forever --dry-run
expect_rejected "a relative remote lock root" \
  env CLAUDEFWS_REMOTE_LOCK_DIR=relative/locks "$LOCK" acquire gpu0 --host example-workstation --dry-run

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

run_remote_lock acquire gpu0 session-a 0 >/dev/null || fail "remote lock could not be acquired"

lock_held_status=0
run_remote_lock acquire gpu0 session-b 0 >/dev/null || lock_held_status=$?
(( lock_held_status == 3 )) || fail "a held lock was handed to a second session (status ${lock_held_status})"

held_report="$(run_remote_lock status '' session-b 0)"
[[ "$held_report" == held\ gpu0* ]] || fail "lock status did not report the lock as held"
[[ "$held_report" == *holder=session-a* ]] || fail "lock status did not name the holder"

refused_status=0
run_remote_lock release gpu0 session-b 0 >/dev/null || refused_status=$?
(( refused_status == 4 )) || fail "a session released a lock it does not hold (status ${refused_status})"

steal_report="$(run_remote_lock release gpu0 session-b 1)"
[[ "$steal_report" == stole\ gpu0\ from\ session-a* ]] || fail "an explicit steal did not report the previous holder"

run_remote_lock acquire gpu0 session-b 0 >/dev/null || fail "a released lock could not be re-acquired"
released_report="$(run_remote_lock release gpu0 session-b 0)"
[[ "$released_report" == released\ gpu0* ]] || fail "a held lock was not released by its holder"

free_report="$(run_remote_lock status gpu0 session-b 0)"
[[ "$free_report" == free\ gpu0* ]] || fail "lock status did not report a free lock"

print -r -- "All tests passed."
