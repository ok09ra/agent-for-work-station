#!/bin/zsh

set -eu

readonly REPOSITORY_ROOT="${0:A:h:h}"
readonly LIBRARY="${REPOSITORY_ROOT}/lib/afws-common.zsh"
readonly CLAUDE_LAUNCHER="${REPOSITORY_ROOT}/bin/claudefws"
readonly CODEX_LAUNCHER="${REPOSITORY_ROOT}/bin/codexfws"
readonly RUNNER="${REPOSITORY_ROOT}/bin/afws-run"
readonly PUSHER="${REPOSITORY_ROOT}/bin/afws-push"
readonly PEERS="${REPOSITORY_ROOT}/bin/afws-peers"
readonly MESSAGE="${REPOSITORY_ROOT}/bin/afws-message"
readonly STATUS_HELPER="${REPOSITORY_ROOT}/bin/afws-status"
readonly ORG="${REPOSITORY_ROOT}/bin/afws-org"
readonly CLAUDE_HOOK="${REPOSITORY_ROOT}/bin/afws-claude-hook"
readonly CLAUDE_INBOX="${REPOSITORY_ROOT}/bin/afws-claude-inbox"
readonly REMOTE_HELPER="${REPOSITORY_ROOT}/bin/afws-remote"
readonly CODEX_HOOK="${REPOSITORY_ROOT}/bin/afws-codex-hook"
readonly ISOLATE="${REPOSITORY_ROOT}/bin/afws-isolate"
readonly LOCK="${REPOSITORY_ROOT}/bin/afws-lock"
readonly REMOUNT="${REPOSITORY_ROOT}/bin/afws-remount"
readonly UMOUNT="${REPOSITORY_ROOT}/bin/afws-umount"
readonly SHELL_WRAPPER="${REPOSITORY_ROOT}/bin/afws-shell"

# Kept short on purpose: the shared-connection socket lives under this
# directory and a Unix domain socket path is limited to 104 bytes.
readonly SANDBOX="$(mktemp -d /tmp/afws-test.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

# Two tests below exercise the non-dry-run path, which ends in ssh. They put
# this stub ahead of it on PATH, so the suite still reaches no real host.
readonly STUB_BIN="${SANDBOX}/stub-bin"
mkdir -p "$STUB_BIN"
cat >| "${STUB_BIN}/ssh" <<'STUB_SSH'
#!/bin/zsh
print -r -- "stub-ssh $*"
exit "${STUB_SSH_EXIT:-0}"
STUB_SSH
chmod +x "${STUB_BIN}/ssh"

# Every test runs against a throwaway registry and mount root. No test reaches
# ssh, sshfs, or a real agent session.
export AFWS_STATE_DIR="${SANDBOX}/state"
export AFWS_MOUNT_BASE="${SANDBOX}/mounts"
unset AFWS_SESSION_NAME AFWS_SSH_HOST AFWS_REMOTE_DIR AFWS_CONTROL_PATH \
  AFWS_AGENT AFWS_LOCAL_WORKSPACE AFWS_KEEP_MOUNT AFWS_NO_CONTROL_MASTER AFWS_NO_SHELL_MARKER \
  AFWS_REMOTE_FIRST AFWS_ALLOWED_LOCAL_DIRS \
  AFWS_PERMISSION_MODE AFWS_MOUNT_COMMAND AFWS_KEEP_CONTROL_MASTER \
  AFWS_REMOTE_ASSUME_YES AFWS_VISIBILITY_MOUNT AFWS_ALLOW_HOME_MOUNT \
  AFWS_CONTROL_PERSIST AFWS_PROBE_TIMEOUT_SECONDS 2>/dev/null || true
unset SSH_ASKPASS 2>/dev/null || true

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

# write_record NAME AGENT PID HOST REMOTE_DIR EPOCH [WORKSPACE] [MOUNT_POINT] [AGENT_PID]
write_record() {
  local name="$1" agent="$2" pid="$3" host="$4" remote="$5" epoch="$6"
  local workspace="${7:-${AFWS_MOUNT_BASE}/${4}${5}}"
  local point="${8:-$workspace}"
  local agent_pid="${9:-}"
  local instance_id="${name}-instance" token="${name}-token" token_hash
  token_hash="$(print -rn -- "$token" | shasum -a 256 | awk '{print $1}')"

  mkdir -p "${AFWS_STATE_DIR}/sessions"
  {
    print -r -- "session_name=${name}"
    print -r -- "instance_id=${instance_id}"
    print -r -- "token_hash=${token_hash}"
    print -r -- "afws_version=2"
    print -r -- "agent=${agent}"
    print -r -- "kind=interactive"
    print -r -- "pid=${pid}"
    print -r -- "agent_pid=${agent_pid}"
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
  "$MESSAGE" \
  "$STATUS_HELPER" \
  "$ORG" \
  "$CLAUDE_HOOK" \
  "$CLAUDE_INBOX" \
  "$REMOTE_HELPER" \
  "$CODEX_HOOK" \
  "$LOCK" \
  "$REMOUNT" \
  "$UMOUNT" \
  "${REPOSITORY_ROOT}/scripts/install.sh" \
  "${REPOSITORY_ROOT}/bin/afws-lab" \
  "${REPOSITORY_ROOT}/bin/afws-doctor" \
  "${REPOSITORY_ROOT}/scripts/prepublish-check.sh"; do
  zsh -n "$script" || fail "syntax check failed: ${script:t}"
done

sh -n "$SHELL_WRAPPER" || fail "syntax check failed: ${SHELL_WRAPPER:t}"
python3 -m py_compile "${REPOSITORY_ROOT}/lib/afws-orchestrator.py" \
  "${REPOSITORY_ROOT}/lib/afws-fs-mcp.py" \
  "${REPOSITORY_ROOT}/scripts/test_org_resilience.py" || fail "Python syntax check failed"

# zsh ties 'path' to $PATH and makes 'status' read-only, so assigning to either
# inside a function breaks command lookup or aborts outright. Both have bitten
# this code before, and the shared library makes the blast radius large.
special_parameter_hits=""
for name in path status cdpath fpath manpath module_path argv options signals \
  psvar mailpath watch histchars prompt SECONDS RANDOM LINES COLUMNS pipestatus dirstack; do
  hits="$(grep -nE "(^|[[:space:];(&|]|local |readonly |typeset |integer |export )${name}=" \
    "$LIBRARY" "$CLAUDE_LAUNCHER" "$CODEX_LAUNCHER" "$RUNNER" "$PEERS" "$MESSAGE" "$STATUS_HELPER" "$ORG" "$CLAUDE_HOOK" "$CLAUDE_INBOX" "$REMOTE_HELPER" "$CODEX_HOOK" "$LOCK" "$REMOUNT" "$UMOUNT" \
    "${REPOSITORY_ROOT}/scripts/"*.sh 2>/dev/null || true)"
  [[ -n "$hits" ]] && special_parameter_hits+="${name}: ${hits}"$'\n'
done
[[ -z "$special_parameter_hits" ]] || \
  fail "assignment to a zsh special parameter:"$'\n'"$special_parameter_hits"

# macOS has no system timeout command. The shared helper must preserve an
# ordinary failure and bound a command that never returns.
timeout_probe="$(zsh -c '
  set -u
  AFWS_PROGRAM=test
  source '"$LIBRARY"'
  result=0
  afws_run_with_timeout 1 /bin/sh -c "exit 7" || result=$?
  print -r -- "failure=${result}"
  result=0
  afws_run_with_timeout 1 /bin/sleep 10 || result=$?
  print -r -- "timeout=${result}"
')"
[[ "$timeout_probe" == $'failure=7\ntimeout=124' ]] || \
  fail "the bounded-command helper returned the wrong result (${timeout_probe})"

terminal_title="$(zsh -c '
  set -eu
  source '"$LIBRARY"'
  afws_session_name=ngof-1
  afws_remote_dir=/data3/okuda/ngof
  afws_terminal_title_text
')"
[[ "$terminal_title" == '[ngof-1] ngof | agent-for-work-station' ]] || \
  fail "the terminal title does not begin with the session name (${terminal_title})"

# The detached rclone wrapper and the macOS mount table become visible on
# independent schedules. A mount-table entry must never make the parent read a
# PID file that has not been created yet, and a cold view gets health retries.
visibility_lifecycle="$(zsh -c '
  set -eu
  AFWS_PROGRAM=test
  AFWS_STATE_DIR='"$SANDBOX"'/visibility-state
  AFWS_MOUNT_BASE='"$SANDBOX"'/visibility-mounts
  AFWS_MOUNT_TIMEOUT_SECONDS=6
  AFWS_UNMOUNT_TIMEOUT_SECONDS=2
  mount_table='"$SANDBOX"'/visibility-mount-table
  : > "$mount_table"
  AFWS_MOUNT_COMMAND="cat ${mount_table}"
  source '"$LIBRARY"'
  fake_pid=""
  health_attempts=0
  afws_detached() {
    local pidfile="$6"
    /bin/sleep 30 &
    fake_pid=$!
    (
      afws_pause_seconds 1
      print -r -- "$fake_pid" > "$pidfile"
      print -r -- "localhost:/ on '"$SANDBOX"'/visibility-mounts/host/project (nfs)" > "$mount_table"
    ) &!
  }
  afws_visibility_mount_is_healthy() {
    afws_mount_is_present "$3" || return 1
    health_attempts=$(( health_attempts + 1 ))
    (( health_attempts >= 3 ))
  }
  result=0
  afws_visibility_mount host /project '"$SANDBOX"'/visibility-mounts/host/project "" \
    '"$SANDBOX"'/visibility.log || result=$?
  record="$(afws_visibility_record host /project)"
  afws_read_visibility_record "$record"
  print -r -- "result=${result} pid=${afws_visibility_pid} attempts=${health_attempts}"
  kill -TERM "$fake_pid" 2>/dev/null || true
  wait "$fake_pid" 2>/dev/null || true
' 2>&1)"
[[ "$visibility_lifecycle" == *"result=0 pid="*" attempts=3"* ]] || \
  fail "the visibility mount did not wait for its PID and healthy contents (${visibility_lifecycle})"
[[ "$visibility_lifecycle" != *"no such file or directory"* ]] || \
  fail "the visibility mount raced its PID file (${visibility_lifecycle})"

# A view that never becomes healthy must not leave either its NFS mount, its
# rclone process, or a management record behind for the next launch to trip on.
visibility_failure="$(zsh -c '
  set -eu
  AFWS_PROGRAM=test
  AFWS_STATE_DIR='"$SANDBOX"'/failed-visibility-state
  AFWS_MOUNT_BASE='"$SANDBOX"'/failed-visibility-mounts
  AFWS_MOUNT_TIMEOUT_SECONDS=2
  AFWS_UNMOUNT_TIMEOUT_SECONDS=2
  mount_table='"$SANDBOX"'/failed-visibility-mount-table
  : > "$mount_table"
  AFWS_MOUNT_COMMAND="cat ${mount_table}"
  source '"$LIBRARY"'
  fake_pid=""
  afws_detached() {
    local pidfile="$6"
    /bin/sleep 30 &
    fake_pid=$!
    print -r -- "$fake_pid" > "$pidfile"
    print -r -- "localhost:/ on '"$SANDBOX"'/failed-visibility-mounts/host/project (nfs)" > "$mount_table"
  }
  afws_visibility_mount_is_healthy() { return 1 }
  umount() { : > "$mount_table" }
  result=0
  afws_visibility_mount host /project '"$SANDBOX"'/failed-visibility-mounts/host/project "" \
    '"$SANDBOX"'/failed-visibility.log || result=$?
  alive=0
  afws_visibility_process_is_alive "$fake_pid" && alive=1
  record="$(afws_visibility_record host /project)"
  print -r -- "result=${result} alive=${alive} mounted=$(afws_mount_is_present '"$SANDBOX"'/failed-visibility-mounts/host/project && print 1 || print 0) record=$([[ -e "$record" || -e "${record}.pid" ]] && print 1 || print 0)"
' 2>&1)"
[[ "$visibility_failure" == *"result=1 alive=0 mounted=0 record=0"* ]] || \
  fail "a failed visibility mount leaked state (${visibility_failure})"

# Healthy legacy views are shared even with live sessions. Reusing them must
# neither detach a mount nor create a fictitious rclone management record.
cat >| "${SANDBOX}/visibility-peers" <<'STUB_PEERS'
#!/bin/zsh
print -r -- "${STUB_VIEW_USERS:-2}"
STUB_PEERS
chmod +x "${SANDBOX}/visibility-peers"
for view_users in 0 2; do
  legacy_reuse="$(STUB_VIEW_USERS="$view_users" zsh -c '
    set -eu
    AFWS_PROGRAM=test
    AFWS_STATE_DIR='"$SANDBOX"'/legacy-visibility-state
    AFWS_MOUNT_BASE='"$SANDBOX"'/legacy-visibility-mounts
    source '"$LIBRARY"'
    afws_mount_is_present() { return 0 }
    afws_directory_responds() { return 0 }
    afws_unmount_visibility_mount() { print unexpected-unmount; return 1 }
    afws_visibility_mount() { print unexpected-mount; return 1 }
    afws_establish_visibility_mount host /project "" 0 test '"$SANDBOX"'/visibility-peers
    record="$(afws_visibility_record host /project)"
    print -r -- "point=${afws_mount_point} record=$([[ -e "$record" ]] && print 1 || print 0)"
  ' 2>&1)" || fail "a healthy legacy view blocked launch with ${view_users} users (${legacy_reuse})"
  [[ "$legacy_reuse" == *"Reusing existing Finder/VS Code view:"*"record=0" ]] || \
    fail "legacy reuse did not preserve the view without rclone state (${legacy_reuse})"
  [[ "$legacy_reuse" != *"unexpected-"* ]] || fail "legacy reuse remounted the view"
done

# An unresponsive legacy mount with live users must still be left intact.
legacy_busy="$(zsh -c '
  set -eu
  AFWS_PROGRAM=test
  AFWS_STATE_DIR='"$SANDBOX"'/legacy-visibility-state
  AFWS_MOUNT_BASE='"$SANDBOX"'/legacy-visibility-mounts
  source '"$LIBRARY"'
  afws_mount_is_present() { return 0 }
  afws_directory_responds() { return 1 }
  afws_unmount_visibility_mount() { print unexpected-unmount; return 1 }
  afws_visibility_mount() { print unexpected-mount; return 1 }
  afws_establish_visibility_mount host /project "" 0 test '"$SANDBOX"'/visibility-peers
' 2>&1)" && fail "replaced an unresponsive legacy view with live users"
[[ "$legacy_busy" == *"not responding and is still used by 2 live session(s)"* ]] || \
  fail "an unresponsive legacy view lost its repair guidance (${legacy_busy})"
[[ "$legacy_busy" != *"unexpected-"* ]] || fail "detached a busy legacy view"

# --- documentation --------------------------------------------------------

for document in \
  "${REPOSITORY_ROOT}/README.md" \
  "${REPOSITORY_ROOT}/README.ja.md" \
  "${REPOSITORY_ROOT}/docs/agents.md" \
  "${REPOSITORY_ROOT}/docs/agents.ja.md" \
  "${REPOSITORY_ROOT}/docs/install-macos.md" \
  "${REPOSITORY_ROOT}/docs/install-macos.ja.md" \
  "${REPOSITORY_ROOT}/docs/isolated-jobs.md" \
  "${REPOSITORY_ROOT}/docs/isolated-jobs.ja.md" \
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

[[ -f "${REPOSITORY_ROOT}/LICENSE" ]] || fail "LICENSE is missing"
python3 "${REPOSITORY_ROOT}/scripts/test-isolate.py" || fail "isolated job tests failed"
grep -Fq 'MIT License' "${REPOSITORY_ROOT}/LICENSE" || fail "LICENSE is not the MIT licence"
grep -Fq 'Copyright (c) 2026 Sota Okuda (ok09ra)' "${REPOSITORY_ROOT}/LICENSE" || \
  fail "LICENSE has no copyright line"
for readme in README.md README.ja.md; do
  grep -Fq '(LICENSE)' "${REPOSITORY_ROOT}/${readme}" || \
    fail "${readme} does not link to the licence"
done

grep -Fq '[日本語](README.ja.md)' "${REPOSITORY_ROOT}/README.md" || \
  fail "English README does not link to Japanese README"
grep -Fq '[English](README.md)' "${REPOSITORY_ROOT}/README.ja.md" || \
  fail "Japanese README does not link to English README"

# --- help -----------------------------------------------------------------

for command_path in "$CLAUDE_LAUNCHER" "$CODEX_LAUNCHER" "$RUNNER" "$PUSHER" "$PEERS" "$MESSAGE" "$STATUS_HELPER" "$ORG" "$CLAUDE_INBOX" "$REMOTE_HELPER" "$ISOLATE" "$LOCK" "$REMOUNT" "$UMOUNT"; do
  "$command_path" --help >/dev/null || fail "${command_path:t} --help failed"
done

# --- shared library resolution -------------------------------------------

reset_state
prefix="${SANDBOX}/prefix"
AFWS_INSTALL_DIR="${prefix}/bin" "${REPOSITORY_ROOT}/scripts/install.sh" --no-shell-config >/dev/null ||
  fail "the installer failed"

for command_name in claudefws codexfws afws-run afws-push afws-peers afws-message afws-status afws-org afws-remote afws-codex-hook afws-claude-hook afws-claude-inbox afws-isolate afws-lock afws-remount afws-umount afws-shell afws-lab afws-doctor; do
  [[ -x "${prefix}/bin/${command_name}" ]] || fail "the installer did not place ${command_name}"
done
[[ -f "${prefix}/lib/afws-common.zsh" ]] || fail "the installer did not place the shared library"
[[ -f "${prefix}/lib/afws-orchestrator.py" ]] || fail "the installer did not place the organization backend"
[[ -f "${prefix}/lib/afws-fs-mcp.py" ]] || fail "the installer did not place the remote-filesystem MCP server"
"${prefix}/bin/afws-org" --help >/dev/null || fail "the installed organization command cannot load its backend"
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

# The foreground shim records the process that actually becomes the agent. A
# watchdog needs this to avoid unmounting underneath an agent whose launcher
# alone was killed.
zsh -c '
  set -eu
  AFWS_PROGRAM=test
  AFWS_STATE_DIR='"$AFWS_STATE_DIR"'
  AFWS_MOUNT_BASE='"$AFWS_MOUNT_BASE"'
  source '"$LIBRARY"'
  afws_agent=codex afws_session_name=tracked-agent afws_ssh_host=h
  afws_remote_dir=/d afws_local_workspace=/w afws_mount_point=/w
  afws_write_session_record interactive "$$" ""
  afws_run_tracked_agent "$$" /bin/zsh -c '\''
    grep -Fqx "agent_pid=$$" "$1"
  '\'' tracked-agent-check '"$AFWS_STATE_DIR"'/sessions/tracked-agent.conf
' || fail "the foreground agent process was not recorded"
rm -f "${AFWS_STATE_DIR}/sessions/tracked-agent.conf"

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

# A TERM/HUP sent only to the launcher can leave its child agent alive. Normal
# trap cleanup must hand that case to the watchdog instead of unmounting under
# the surviving process.
deferred_release_probe="$(zsh -c '
  set -eu
  AFWS_PROGRAM=test
  AFWS_STATE_DIR='"$AFWS_STATE_DIR"'
  AFWS_MOUNT_BASE='"$AFWS_MOUNT_BASE"'
  source '"$LIBRARY"'
  afws_agent=codex afws_session_name=deferred-release afws_ssh_host=h
  afws_remote_dir=/d afws_local_workspace=/w afws_mount_point=/w
  afws_control_socket_path=""
  afws_write_session_record interactive "$$" ""
  /bin/sleep 30 &
  agent_pid=$!
  print -r -- "agent_pid=${agent_pid}" >> '"$AFWS_STATE_DIR"'/sessions/deferred-release.conf
  afws_release_session /nonexistent-peers
  [[ -e '"$AFWS_STATE_DIR"'/sessions/deferred-release.conf ]] && print -r -- DEFERRED
  kill -9 "$agent_pid" 2>/dev/null || true
  wait "$agent_pid" 2>/dev/null || true
  rm -f '"$AFWS_STATE_DIR"'/sessions/deferred-release.conf
')"
[[ "$deferred_release_probe" == *DEFERRED* ]] || \
  fail "cleanup did not defer to the watchdog for a surviving agent (${deferred_release_probe})"

# A pre-authenticated SSH channel must expire on its own, because a session
# may still outlive both of its cleanup processes.
grep -q 'AFWS_CONTROL_PERSIST:=[1-9]' "$LIBRARY" || \
  fail "the shared SSH connection has no finite ControlPersist"
grep -q 'ControlPersist=\${AFWS_CONTROL_PERSIST}' "$LIBRARY" || \
  fail "the shared SSH connection does not use AFWS_CONTROL_PERSIST"

# A host that authenticates by password cannot afford to re-authenticate on
# every launch, so AFWS_KEEP_CONTROL_MASTER trades the close-on-last-exit bound
# for expiry alone -- which then has to be the longer of the two defaults.
persist_probe="$(zsh -c '
  set -eu
  source '"$LIBRARY"'
  print -r -- "$AFWS_CONTROL_PERSIST"
')"
kept_persist_probe="$(zsh -c '
  set -eu
  AFWS_KEEP_CONTROL_MASTER=1
  source '"$LIBRARY"'
  print -r -- "$AFWS_CONTROL_PERSIST"
')"
chosen_persist_probe="$(zsh -c '
  set -eu
  AFWS_KEEP_CONTROL_MASTER=1 AFWS_CONTROL_PERSIST=42
  source '"$LIBRARY"'
  print -r -- "$AFWS_CONTROL_PERSIST"
')"
(( kept_persist_probe > persist_probe )) || \
  fail "keeping the connection open did not outlast the default (${kept_persist_probe})"
[[ "$chosen_persist_probe" == 42 ]] || \
  fail "AFWS_KEEP_CONTROL_MASTER overrode an explicit AFWS_CONTROL_PERSIST (${chosen_persist_probe})"

# The knob suppresses only the close. Releasing the last session of a host is
# what reaches that branch, so this stands in for afws-peers reporting none
# left; the mount point is deliberately outside AFWS_MOUNT_BASE, which leaves
# the unmount alone and isolates the connection.
readonly PEERS_STUB="${SANDBOX}/stub-peers"
cat >| "$PEERS_STUB" <<'STUB_PEERS'
#!/bin/zsh
print -r -- 0
STUB_PEERS
chmod +x "$PEERS_STUB"

release_probe_for() {
  zsh -c '
    set -eu
    AFWS_PROGRAM=test
    AFWS_STATE_DIR='"$AFWS_STATE_DIR"'
    AFWS_MOUNT_BASE='"$AFWS_MOUNT_BASE"'
    export AFWS_KEEP_CONTROL_MASTER='"${1}"'
    source '"$LIBRARY"'
    afws_close_control_master() { print -r -- "CLOSED"; }
    afws_session_name=keep-probe afws_ssh_host=h
    afws_mount_point='"$SANDBOX"'/not-a-managed-mount
    afws_control_socket_path=/nonexistent.sock
    afws_release_session '"$PEERS_STUB"'
  '
}

closed_probe="$(release_probe_for '')"
[[ "$closed_probe" == *CLOSED* ]] || \
  fail "releasing the last session of a host left the connection open (${closed_probe})"

keep_probe="$(release_probe_for 1)"
[[ "$keep_probe" != *CLOSED* ]] || \
  fail "AFWS_KEEP_CONTROL_MASTER still closed the shared connection"
[[ "$keep_probe" == *"Leaving the shared SSH connection"* ]] || \
  fail "AFWS_KEEP_CONTROL_MASTER did not say the connection was left open"

# zsh runs an EXIT trap set inside a function when that function returns, not
# when the shell exits, unless POSIX_TRAPS is set. Installing the traps from a
# helper therefore released the session before the agent had started: record
# removed, connection closed, mount unmounted, and the launcher left in $HOME
# for the agent to inherit as its workspace.
trap_order="$(zsh -c '
  set -eu
  AFWS_PROGRAM=test
  AFWS_STATE_DIR='"$AFWS_STATE_DIR"'
  AFWS_MOUNT_BASE='"$AFWS_MOUNT_BASE"'
  source '"$LIBRARY"'
  afws_release_session() { print -r -- "RELEASED"; }
  afws_session_name=trap-probe afws_ssh_host=h
  afws_install_release_traps /nonexistent-peers
  print -r -- "AGENT STARTED"
')"
[[ "$trap_order" == "AGENT STARTED
RELEASED" ]] || \
  fail "the session was not released exactly once, at the end (${trap_order})"

# zsh runs the EXIT trap on a normal exit and on HUP, but not on TERM, so the
# signal traps have to be installed alongside it. Both launchers get them from
# the same place.
grep -q "trap 'afws_release_for_traps; exit 143' TERM" "$LIBRARY" || \
  fail "the launchers do not release what they hold on SIGTERM"
grep -q "trap 'afws_release_for_traps; exit 129' HUP" "$LIBRARY" || \
  fail "the launchers do not release what they hold on SIGHUP"
for launcher in "$CLAUDE_LAUNCHER"; do
  grep -q 'afws_install_release_traps' "$launcher" || \
    fail "${launcher:t} does not install the release traps"
  grep -q 'afws_start_release_watchdog' "$launcher" || \
    fail "${launcher:t} does not start the crash-cleanup watchdog"
  grep -q 'afws_run_tracked_agent' "$launcher" || \
    fail "${launcher:t} does not record its agent process"
done

# A function defined inside another is global in zsh, so the trap cannot see a
# local of the function that installed it.
grep -q 'afws_peers_command=' "$LIBRARY" || \
  fail "the release traps depend on a local that will not be in scope when they fire"

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

# Both launchers are remote-first now, so they share one set of rules and the
# agent names itself. Naming one agent in the shared text used to leave the
# other reading instructions addressed to something else.
operating_rules="$(zsh -c 'source '"$LIBRARY"'; afws_remote_first_operating_rules Claude')"
[[ "$operating_rules" == *"The remote working directory is the authoritative project"* ]] || \
  fail "the session instructions do not say which tree is authoritative"
[[ "$operating_rules" == *"Run every project read, search, edit, file-management, and Git operation through afws-run"* ]] || \
  fail "the session instructions do not route project work through afws-run"
[[ "$operating_rules" == *"do not use it for Claude project work"* ]] || \
  fail "the shared rules did not take the agent's own name"
[[ "$operating_rules" != *Codex* ]] || \
  fail "a Claude session was handed rules addressed to Codex"

codex_rules="$(zsh -c 'source '"$LIBRARY"'; afws_remote_first_operating_rules Codex')"
[[ "$codex_rules" == *"do not use it for Codex project work"* ]] || \
  fail "the shared rules did not take Codex's name"
[[ "$codex_rules" != *Claude* ]] || \
  fail "a Codex session was handed rules addressed to Claude"

# The mounted session type is gone, and so are the functions that served it.
for removed in afws_establish_mount afws_session_preamble \
  afws_shared_operating_rules afws_warn_about_home_workspace; do
  if grep -q "^${removed}()" "$LIBRARY"; then
    fail "${removed} outlived the mounted session type it served"
  fi
  if grep -rq "${removed}" "${REPOSITORY_ROOT}/bin"; then
    fail "something still calls ${removed}"
  fi
done

reset_state
claude_plan="$("$CLAUDE_LAUNCHER" --dry-run example-workstation /remote/project)"
# Nothing is mounted by default any more. SSHFS aborts in its own readdir path
# on a bug this repository cannot fix, and the rclone view it was stacked on
# cannot represent remote symlinks; afws-run reaches the real tree through
# neither. The view is still available, but it has to be asked for.
[[ "$claude_plan" != *"Would mount"* ]] || \
  fail "claudefws planned a mount without being asked for one"
[[ "$claude_plan" == *"Nothing will be mounted"* ]] || \
  fail "claudefws did not say that it mounts nothing"
[[ "$claude_plan" == *"Add --view"* ]] || \
  fail "claudefws did not say how to get a Finder/VS Code view"
# The empty control workspace is what confines Claude's file tools: they are
# limited to the working directory, and the project is not in it.
[[ "$claude_plan" == *"cd ${AFWS_STATE_DIR}/workspaces/example-workstation/remote/project"* ]] || \
  fail "claudefws did not start Claude in the empty control workspace"
[[ "$claude_plan" != *--add-dir* ]] || \
  fail "claudefws handed Claude a directory beyond its control workspace"
[[ "$claude_plan" == *"Would start Claude with"* ]] || fail "claudefws dry run did not plan a launch"
[[ "$claude_plan" == *"--permission-mode auto"* ]] || fail "claudefws dry run did not plan the auto permission mode"
[[ "$claude_plan" == *"--name fws-example-workstation-project-1"* ]] || fail "claudefws dry run did not plan a session name"
[[ "$claude_plan" == *"--append-system-prompt"* ]] || fail "claudefws dry run did not plan session instructions"
[[ "$claude_plan" == *"Would enable Claude Agent Teams"* ]] ||
  fail "claudefws did not enable the Claude execution layer by default"
[[ "$claude_plan" == *"shared SSH connection at ${AFWS_STATE_DIR}/control/example-workstation.sock"* ]] || \
  fail "claudefws dry run did not plan the shared SSH connection"
[[ "$claude_plan" == *"Would label locally-run shell commands"* ]] || \
  fail "claudefws dry run did not mention labelling local shell commands"

grep -q 'afws_remote_first=1' "$CLAUDE_LAUNCHER" || \
  fail "claudefws is not a remote-first launcher"
grep -Fq 'afws_remote_first_operating_rules Claude' "$CLAUDE_LAUNCHER" || \
  fail "claudefws handed its session rules addressed to some other agent"
grep -Fq 'afws_remote_first_operating_rules Codex' "$CODEX_LAUNCHER" || \
  fail "codexfws handed its session rules addressed to some other agent"

# Without a mount, the structured file tools would be gone and every read
# would become a shell command. The MCP server is what keeps them, reaching
# the real tree over SSH -- symlinks and all, which the rclone view cannot do.
[[ "$claude_plan" == *"Would give Claude the remote filesystem through"* ]] || \
  fail "claudefws did not plan the remote filesystem tools"
[[ "$claude_plan" == *"--mcp-config"* ]] || \
  fail "claudefws did not pass the MCP server to Claude"
without_mcp="$(AFWS_NO_FS_MCP=1 "$CLAUDE_LAUNCHER" --dry-run example-workstation /remote/project)"
[[ "$without_mcp" != *--mcp-config* ]] || \
  fail "AFWS_NO_FS_MCP did not turn the remote filesystem tools off"
[[ "$without_mcp" == *"Would start Claude with"* ]] || \
  fail "turning the filesystem tools off stopped the launch as well"

# The launcher builds that configuration inline. It has to be JSON, and it has
# to tell the server which directory it is serving, or the tools come up
# pointing at nothing.
# The dry run prints a placeholder rather than the configuration itself, so
# run the generator the launcher embeds and check what it actually emits. A
# server that comes up without AFWS_REMOTE_DIR is pointed at nothing.
mcp_generator="${SANDBOX}/mcp-generator.py"
python3 - "$CLAUDE_LAUNCHER" "$mcp_generator" <<'EXTRACT_MCP_GENERATOR'
import io
import sys

launcher = io.open(sys.argv[1], encoding="utf-8").read()
opening = "mcp_config=\"$(python3 -c '"
start = launcher.index(opening) + len(opening)
end = launcher.index("\n' \"$afws_fs_mcp\"", start)
io.open(sys.argv[2], "w", encoding="utf-8").write(launcher[start:end])
EXTRACT_MCP_GENERATOR
[[ -s "$mcp_generator" ]] || fail "could not find the MCP configuration the launcher builds"

mcp_emitted="$(python3 "$mcp_generator" /lib/afws-fs-mcp.py example-workstation \
  /remote/project /tmp/socket.sock 600 fws-session "$AFWS_STATE_DIR")" || \
  fail "the MCP configuration generator failed"
python3 -c '
import json, sys
config = json.loads(sys.argv[1])
server = config["mcpServers"]["afws-fs"]
assert server["command"] == "python3", server
assert server["args"] == ["/lib/afws-fs-mcp.py"], server
environment = server["env"]
assert environment["AFWS_SSH_HOST"] == "example-workstation", environment
assert environment["AFWS_REMOTE_DIR"] == "/remote/project", environment
assert environment["AFWS_CONTROL_PATH"] == "/tmp/socket.sock", environment
# The server is launched before an isolated assignment exists, so it is given
# the identity it needs to find that checkout later rather than the checkout.
assert environment["AFWS_SESSION_NAME"] == "fws-session", environment
assert environment["AFWS_STATE_DIR"], environment
' "$mcp_emitted" || fail "the injected MCP configuration is not what the server expects (${mcp_emitted})"

# With no shared connection yet there is nothing to point the server at, but
# it must still be given the host and directory rather than dropped.
mcp_socketless="$(python3 "$mcp_generator" /lib/afws-fs-mcp.py example-workstation \
  /remote/project "" 600 fws-session "$AFWS_STATE_DIR")" || \
  fail "the MCP configuration generator failed without a socket"
python3 -c '
import json, sys
environment = json.loads(sys.argv[1])["mcpServers"]["afws-fs"]["env"]
assert environment["AFWS_REMOTE_DIR"] == "/remote/project", environment
assert "AFWS_CONTROL_PATH" not in environment, environment
' "$mcp_socketless" || fail "the MCP configuration mishandled a missing shared connection"

grep -Fq 'AFWS_NO_FS_MCP' "$CLAUDE_LAUNCHER" || \
  fail "there is no way to turn the remote filesystem tools off"

# Asked for, the view appears -- and the file tools are denied it, so it stays
# a view rather than quietly becoming the data path again.
view_plan="$("$CLAUDE_LAUNCHER" --dry-run --view example-workstation /remote/project)"
[[ "$view_plan" == *"Would mount a Finder/VS Code view"* ]] || \
  fail "--view did not plan the Finder/VS Code view"
[[ "$view_plan" == *"with rclone NFS"* ]] || \
  fail "--view planned something other than the rclone view"
[[ "$view_plan" == *--disallowedTools* ]] || \
  fail "--view left the file tools free to treat the view as the project"
[[ "$view_plan" != *--add-dir* ]] || \
  fail "--view added the view to the directories Claude may work in"

env_view_plan="$(AFWS_VISIBILITY_MOUNT=1 "$CLAUDE_LAUNCHER" --dry-run example-workstation /remote/project)"
[[ "$env_view_plan" == *"Would mount a Finder/VS Code view"* ]] || \
  fail "AFWS_VISIBILITY_MOUNT did not ask for the view"
overridden="$(AFWS_VISIBILITY_MOUNT=1 "$CLAUDE_LAUNCHER" --dry-run --no-view example-workstation /remote/project)"
[[ "$overridden" != *"Would mount"* ]] || \
  fail "--no-view did not override AFWS_VISIBILITY_MOUNT"

[[ -d "$AFWS_MOUNT_BASE" ]] && fail "claudefws dry run created a mount directory"
[[ -e "${AFWS_STATE_DIR}/control" ]] && fail "claudefws dry run created a control directory"
[[ -e "${AFWS_STATE_DIR}/sessions/fws-example-workstation-project-1.conf" ]] && \
  fail "claudefws dry run wrote a session record"

codex_plan="$("$CODEX_LAUNCHER" --dry-run example-workstation /remote/project)"
[[ "$codex_plan" != *"Would mount"* ]] || \
  fail "codexfws planned a mount without being asked for one"
[[ "$codex_plan" == *"Nothing will be mounted"* ]] || \
  fail "codexfws did not say that it mounts nothing"
[[ "$codex_plan" == *"Add --view"* ]] || \
  fail "codexfws did not say how to get a Finder/VS Code view"
codex_view_plan="$("$CODEX_LAUNCHER" --dry-run --view example-workstation /remote/project)"
[[ "$codex_view_plan" == *"Would mount a Finder/VS Code view"* ]] || \
  fail "codexfws --view did not plan the Finder/VS Code view"
codex_overridden="$(AFWS_VISIBILITY_MOUNT=1 "$CODEX_LAUNCHER" --dry-run --no-view example-workstation /remote/project)"
[[ "$codex_overridden" != *"Would mount"* ]] || \
  fail "codexfws --no-view did not override AFWS_VISIBILITY_MOUNT"
[[ "$codex_plan" == *"Would start Codex with"* ]] || fail "codexfws dry run did not plan a launch"
[[ "$codex_plan" == *"--sandbox workspace-write"* ]] || fail "codexfws dry run lost the sandbox flag"
[[ "$codex_plan" == *"--ask-for-approval on-request"* ]] || fail "codexfws dry run lost the approval flag"

# Leaving Codex to decide when its own action deserves review is the judgement
# being checked, so the reviewing agent is available. It is opt-in because a
# managed configuration can refuse the policy outright.
[[ "$codex_plan" != *"approvals_reviewer"* ]] || \
  fail "codexfws planned the reviewing agent without being asked for it"
codex_reviewed_plan="$(AFWS_CODEX_AUTO_REVIEW=1 "$CODEX_LAUNCHER" --dry-run example-workstation /remote/project)"
[[ "$codex_reviewed_plan" == *'approvals_reviewer="auto_review"'* ]] || \
  fail "AFWS_CODEX_AUTO_REVIEW did not route approvals to the reviewing agent"

# A write scope that is only written down is not a write scope. Both launchers
# state that the workstation tree is compared against it before a turn ends.
for launcher_plan_source in "$CLAUDE_LAUNCHER" "$CODEX_LAUNCHER"; do
  if ! grep -q "The write scope on an assignment is checked, not trusted" "$launcher_plan_source"; then
    fail "${launcher_plan_source:t} does not tell the session its write scope is checked"
  fi
  if ! grep -q "done_when" "$launcher_plan_source"; then
    fail "${launcher_plan_source:t} does not tell the session how an assignment is closed"
  fi
done

# A session that can rewrite this Mac's configuration can undo its own limits.
for protected_path in '~/.claude/\*\*' '~/.afws/\*\*' '~/.ssh/\*\*'; do
  if ! grep -q "$protected_path" "$CLAUDE_LAUNCHER"; then
    fail "claudefws does not deny the file tools ${protected_path}"
  fi
done
grep -q '"ConfigChange"' "$CLAUDE_LAUNCHER" || \
  fail "claudefws does not report configuration changes made during a session"

# Widening a daemon shared by the whole Mac needs a person, not a session.
remote_state="$(mktemp -d)"
mkdir -p "${remote_state}/sessions"
cat > "${remote_state}/sessions/cx-guard.conf" <<REMOTE_RECORD
session_name=cx-guard
instance_id=cx-guard-instance
token_hash=unused
afws_version=2
agent=codex
kind=interactive
pid=$$
ssh_host=example-workstation
remote_dir=/remote/project
started_epoch=$(date +%s)
REMOTE_RECORD
remote_refusal="$(AFWS_STATE_DIR="$remote_state" AFWS_SESSION_NAME=cx-guard \
  "${REPOSITORY_ROOT}/bin/afws-remote" on < /dev/null 2>&1 || true)"
[[ "$remote_refusal" == *"needs a person at the terminal"* ]] || \
  fail "afws-remote enabled Remote Control without a person at the terminal"
remote_refusal="$(AFWS_STATE_DIR="$remote_state" AFWS_SESSION_NAME=cx-guard \
  "${REPOSITORY_ROOT}/bin/afws-remote" pair < /dev/null 2>&1 || true)"
[[ "$remote_refusal" == *"needs a person at the terminal"* ]] || \
  fail "afws-remote paired a device without a person at the terminal"
rm -rf "$remote_state"
[[ "$codex_plan" == *"developer_instructions="* ]] || fail "codexfws dry run did not plan session instructions"
[[ "$codex_view_plan" == *"with rclone NFS"* ]] || fail "codexfws did not plan the stable visibility mount"
[[ "$codex_plan" == *"${AFWS_STATE_DIR}/workspaces/example-workstation/remote/project"* ]] || \
  fail "codexfws did not use a separate local control workspace"
codex_resume_plan="$("$CODEX_LAUNCHER" --dry-run --resume example-workstation /remote/project)"
[[ "$codex_resume_plan" == *" resume --all"* ]] || \
  fail "codexfws --resume did not disable Codex's cwd-only history filter"
codex_trailing_resume_plan="$("$CODEX_LAUNCHER" --dry-run example-workstation /remote/project --resume)"
[[ "$codex_trailing_resume_plan" == *" resume --all"* ]] || \
  fail "codexfws did not accept --resume after the project arguments"
[[ "$codex_plan" == *"--name "* ]] && fail "codexfws planned a --name flag that Codex does not have"
[[ "$codex_plan" == *"Would label locally-run shell commands"* ]] && \
  fail "codexfws planned a shell marker that Codex cannot use"

# Both launchers must agree on where the view and the socket go.
[[ "$codex_view_plan" == *"${AFWS_MOUNT_BASE}/example-workstation/remote/project"* ]] || \
  fail "codexfws planned a different mount point from claudefws"
[[ "$view_plan" == *"${AFWS_MOUNT_BASE}/example-workstation/remote/project"* ]] || \
  fail "claudefws --view planned a different mount point from codexfws"
[[ "$codex_plan" == *"${AFWS_STATE_DIR}/control/example-workstation.sock"* ]] || \
  fail "codexfws planned a different shared connection from claudefws"
[[ "$codex_plan" == *"session: cx-example-workstation-project-1"* ]] || \
  fail "codexfws did not allocate its own session name"

# Remote Control operates on Codex's shared daemon, not the AFWS session.
reset_state
write_record cx-remote codex "$$" example-workstation /remote/project "$(date +%s)"
write_record fws-remote claude "$$" example-workstation /remote/project "$(date +%s)"
cat >| "${STUB_BIN}/codex" <<'STUB_CODEX_REMOTE'
#!/bin/zsh
print -r -- "$*" >> "$AFWS_TEST_REMOTE_LOG"
if [[ "$*" == "remote-control pair" ]]; then
  print -r -- "PAIR-CODE"
fi
STUB_CODEX_REMOTE
chmod +x "${STUB_BIN}/codex"
export AFWS_TEST_REMOTE_LOG="${SANDBOX}/remote-codex.log"
: > "$AFWS_TEST_REMOTE_LOG"
expect_rejected "Remote Control outside a session" env PATH="${STUB_BIN}:$PATH" "$REMOTE_HELPER" on
expect_rejected "Remote Control from Claude" env PATH="${STUB_BIN}:$PATH" AFWS_SESSION_NAME=fws-remote "$REMOTE_HELPER" on

# 'on' and 'pair' widen access to a daemon shared by the whole Mac, so they ask
# at the controlling terminal. The suite has none, which is the same position
# an agent session is in -- so they must refuse here, and say why.
for widening in on pair; do
  refusal="$(env PATH="${STUB_BIN}:$PATH" AFWS_SESSION_NAME=cx-remote \
    "$REMOTE_HELPER" "$widening" 2>&1 >/dev/null || true)"
  [[ "$refusal" == *"needs a person at the terminal"* ]] || \
    fail "afws-remote ${widening} widened shared access with nobody to confirm it (${refusal})"
done
[[ ! -s "$AFWS_TEST_REMOTE_LOG" ]] || \
  fail "afws-remote reached Codex despite refusing to confirm"

# The two that widen nothing need no confirmation, terminal or not.
env PATH="${STUB_BIN}:$PATH" AFWS_SESSION_NAME=cx-remote AFWS_REMOTE_ASSUME_YES=1 \
  "$REMOTE_HELPER" on >/dev/null ||
  fail "afws-remote on failed"
env PATH="${STUB_BIN}:$PATH" AFWS_SESSION_NAME=cx-remote "$REMOTE_HELPER" off >/dev/null ||
  fail "afws-remote off failed"
pair_output="$(env PATH="${STUB_BIN}:$PATH" AFWS_SESSION_NAME=cx-remote \
  AFWS_REMOTE_ASSUME_YES=1 "$REMOTE_HELPER" pair)" ||
  fail "afws-remote pair failed"
[[ "$pair_output" == "PAIR-CODE" ]] || fail "afws-remote did not pass through the pairing code"
[[ "$(cat "$AFWS_TEST_REMOTE_LOG")" == $'app-server daemon enable-remote-control\napp-server daemon disable-remote-control\nremote-control pair' ]] ||
  fail "afws-remote called the wrong Codex commands"
mkdir -p "${SANDBOX}/codex-home/app-server-control"
if python3 - "${SANDBOX}/codex-home/app-server-control/probe.sock" <<'SOCKET_PROBE'
import socket
import sys
try:
    with socket.socket(socket.AF_UNIX) as probe:
        probe.bind(sys.argv[1])
except OSError:
    sys.exit(1)
SOCKET_PROBE
then
  rm -f "${SANDBOX}/codex-home/app-server-control/probe.sock"
  cat >| "${SANDBOX}/remote-status-server.py" <<'STUB_REMOTE_STATUS'
import base64
import hashlib
import json
import socket
import struct
import sys

with socket.socket(socket.AF_UNIX) as server:
    server.bind(sys.argv[1])
    server.listen(1)
    open(sys.argv[2], "w").close()
    conn, _ = server.accept()
    with conn:
        reader = conn.makefile("rb")
        headers = {}
        while line := reader.readline():
            if line == b"\r\n":
                break
            if b":" in line:
                name, value = line.decode("ascii").split(":", 1)
                headers[name.lower()] = value.strip()
        accept = base64.b64encode(hashlib.sha1(
            (headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
        ).digest()).decode()
        conn.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                      f"Connection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n").encode())

        def send_json(message):
            payload = json.dumps(message).encode()
            conn.sendall(bytes([0x81, len(payload)]) + payload)

        while True:
            first, second = reader.read(2)
            size = second & 127
            if size == 126:
                size = struct.unpack("!H", reader.read(2))[0]
            mask = reader.read(4)
            payload = reader.read(size)
            request = json.loads(bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload)))
            if request.get("method") == "initialize":
                send_json({"id": 1, "result": {}})
            elif request.get("method") == "remoteControl/status/read":
                send_json({"id": 2, "result": {"status": "connected"}})
                break
        reader.close()
STUB_REMOTE_STATUS
  python3 "${SANDBOX}/remote-status-server.py" \
    "${SANDBOX}/codex-home/app-server-control/app-server-control.sock" \
    "${SANDBOX}/remote-status.ready" &
  remote_server_pid=$!
  for attempt in {1..30}; do
    [[ -f "${SANDBOX}/remote-status.ready" ]] && break
    sleep 0.1
  done
  [[ -f "${SANDBOX}/remote-status.ready" ]] || fail "stub remote status server did not start"
  remote_status="$(env PATH="${STUB_BIN}:$PATH" CODEX_HOME="${SANDBOX}/codex-home" \
    AFWS_SESSION_NAME=cx-remote "$REMOTE_HELPER" status)" || fail "afws-remote status failed"
  [[ "$remote_status" == *"connected"* ]] || fail "afws-remote reported the wrong status"
  wait "$remote_server_pid" || fail "stub remote status server failed"
else
  print -r -- "[SKIP] Unix socket status test (socket binding unavailable)"
fi
rm -f "${STUB_BIN}/codex"
reset_state

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

no_teams_plan="$(AFWS_NO_AGENT_TEAMS=1 "$CLAUDE_LAUNCHER" --dry-run example-workstation /remote/project)"
[[ "$no_teams_plan" == *"Agent Teams would remain disabled"* ]] ||
  fail "AFWS_NO_AGENT_TEAMS did not disable the Claude execution layer"

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
[[ "$long_ok" == *"Would start Claude with"* ]] || \
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

# The same variable, the same reported effect, whichever agent is launched. Which
# flag carries it is the launcher's business, not the user's.
for launcher in "$CLAUDE_LAUNCHER" "$CODEX_LAUNCHER"; do
  both="$(AFWS_ADD_DIR="${SANDBOX}/papers:${SANDBOX}/notes" \
    "$launcher" --dry-run example-workstation /remote/project)"
  [[ "$both" == *"also:    ${SANDBOX}/papers"* ]] || \
    fail "${launcher:t} did not report an extra directory"
  [[ "$both" == *"also:    ${SANDBOX}/notes"* ]] || \
    fail "${launcher:t} dropped the second extra directory"
done

codex_plan_extra="$(AFWS_ADD_DIR="${SANDBOX}/papers:${SANDBOX}/notes" \
  "$CODEX_LAUNCHER" --dry-run example-workstation /remote/project)"
[[ "$codex_plan_extra" == *"-c sandbox_workspace_write.writable_roots=[\"${SANDBOX}/papers\",\"${SANDBOX}/notes\"]"* ]] || \
  fail "codexfws did not plan to make the extra directories writable in its sandbox"

codex_plan_plain="$("$CODEX_LAUNCHER" --dry-run example-workstation /remote/project)"
[[ "$codex_plan_plain" != *writable_roots* ]] || \
  fail "codexfws planned writable roots with nothing to add"

expect_rejected "a relative extra directory (codexfws)" \
  env AFWS_ADD_DIR=relative "$CODEX_LAUNCHER" --dry-run example-workstation /remote/project

codex_flag_extra="$($CODEX_LAUNCHER --dry-run --allow-local-files "${SANDBOX}/papers" \
  example-workstation /remote/project)"
[[ "$codex_flag_extra" == *"also:    ${SANDBOX}/papers"* ]] || \
  fail "codexfws ignored --allow-local-files"
expect_rejected "a relative --allow-local-files directory" \
  "$CODEX_LAUNCHER" --dry-run --allow-local-files relative example-workstation /remote/project

# Unsolicited peer messages interrupt another session and cost it budget, and
# nothing asks the user first, so the session instructions have to narrow it.
for phrase in 'nothing asks the user first' 'only when the user asked you to' \
  'Do not send file contents'; do
  grep -Fq "$phrase" "$CLAUDE_LAUNCHER" || \
    fail "the session instructions no longer constrain messaging a peer: ${phrase}"
done

for phrase in '[AFWS organization assignment]' 'Queueing is not acknowledgement' \
  'redelegation: forbidden' 'the task matches the ledger'; do
  grep -Fq "$phrase" "$CODEX_LAUNCHER" ||
    fail "Codex organization delegation lost a required guard: ${phrase}"
done

# --- mount table ----------------------------------------------------------
# The launchers read the mount table through AFWS_MOUNT_COMMAND, so reuse and
# nesting can be checked without mounting anything.

reset_state
readonly FAKE_MOUNTS="${SANDBOX}/mounts.txt"
readonly FAKE_ROOT="${AFWS_MOUNT_BASE}/example-workstation/remote/project"
mkdir -p "${FAKE_ROOT}/inner"

print -r -- "example-workstation:/remote/project on ${FAKE_ROOT} (macfuse, nodev, nosuid)" > "$FAKE_MOUNTS"

# Neither launcher mounts a project tree any more, so these are library
# behaviours rather than launcher behaviours. Driving the functions directly
# keeps them covered without a launcher that would mount anything, and follows
# the same shape as the visibility-mount probes above.
mount_probe() {
  # mount_probe MOUNT_TABLE SNIPPET
  zsh -c '
    set -eu
    AFWS_PROGRAM=test
    AFWS_STATE_DIR='"${AFWS_STATE_DIR}"'
    AFWS_MOUNT_BASE='"${AFWS_MOUNT_BASE}"'
    AFWS_MOUNT_COMMAND="cat '"$1"'"
    source '"$LIBRARY"'
    '"$2"'
  ' 2>&1
}

find_existing() {
  mount_probe "$1" '
    if afws_find_existing_mount "'"$2"'" "'"$3"'"; then
      print -r -- "FOUND source=${afws_mount_source} workspace=${afws_local_workspace}"
    else
      print -r -- "NONE stale=${afws_stale_mount} reason=${afws_stale_mount_reason}"
    fi'
}

print -r -- "example-workstation:/remote/project on ${FAKE_ROOT} (macfuse, nodev, nosuid)" > "$FAKE_MOUNTS"

reuse="$(find_existing "$FAKE_MOUNTS" example-workstation /remote/project/inner)"
[[ "$reuse" == *"FOUND source=example-workstation:/remote/project"* ]] || \
  fail "a mount that already covers the requested directory was not reused (${reuse})"
[[ "$reuse" == *"workspace=${FAKE_ROOT}/inner"* ]] || \
  fail "the workspace did not point at the subdirectory of the reused mount (${reuse})"

other_host="$(find_existing "$FAKE_MOUNTS" other-workstation /remote/project)"
[[ "$other_host" == NONE* ]] || \
  fail "a mount belonging to another host was reused (${other_host})"

# A mount below the one about to be made would be hidden by it, and the session
# that owns it would silently start resolving its workspace through ours.
print -r -- "example-workstation:/remote/project/inner on ${FAKE_ROOT}/inner (macfuse, nodev, nosuid)" > "$FAKE_MOUNTS"
nested="$(mount_probe "$FAKE_MOUNTS" '
  if afws_find_nested_mount "'"${FAKE_ROOT}"'"; then
    print -r -- "NESTED ${afws_nested_mount}"
  else
    print -r -- "NONE"
  fi')"
[[ "$nested" == "NESTED ${FAKE_ROOT}/inner" ]] || \
  fail "a mount underneath the requested path was not noticed (${nested})"

sibling="$(mount_probe "$FAKE_MOUNTS" '
  if afws_find_nested_mount "'"${AFWS_MOUNT_BASE}"'/example-workstation/remote/other"; then
    print -r -- "NESTED ${afws_nested_mount}"
  else
    print -r -- "NONE"
  fi')"
[[ "$sibling" == NONE ]] || \
  fail "a sibling directory was mistaken for a nested mount (${sibling})"

# A Finder/VS Code view mounts as "localhost:/", not "example-workstation:",
# and it sits on exactly the path a new SSHFS mount would take. The
# existing-mount search filters on the host-spelled source and the nested-mount
# search only looks strictly below the path, so neither sees it. An SSHFS mount
# was laid straight on top of a live view, and once its process died the corpse
# answered ENXIO for everything while the healthy mount underneath could not be
# reached. Peeling one layer only uncovered the next, so a repair looked like it
# had worked and failed again hours later.
print -r -- "localhost:/ on ${FAKE_ROOT} (nfs, nodev, nosuid)" > "$FAKE_MOUNTS"

invisible="$(find_existing "$FAKE_MOUNTS" example-workstation /remote/project)"
[[ "$invisible" == NONE* ]] || \
  fail "the test no longer reproduces the blind spot the guard exists for (${invisible})"
blind="$(mount_probe "$FAKE_MOUNTS" '
  if afws_find_nested_mount "'"${FAKE_ROOT}"'"; then print -r -- NESTED; else print -r -- NONE; fi')"
[[ "$blind" == NONE ]] || \
  fail "the nested search now sees a mount at exactly the path, so the guard is untested"

stacked="$(mount_probe "$FAKE_MOUNTS" '
  afws_refuse_to_stack sshfs "example-workstation:/remote/project" "'"${FAKE_ROOT}"'"
  print -r -- ALLOWED' || true)"
[[ "$stacked" != *ALLOWED* ]] || \
  fail "an SSHFS mount was allowed on top of a live Finder/VS Code view"
[[ "$stacked" == *"already mounted on exactly that path"* ]] || \
  fail "the refusal did not say the path is already taken (${stacked})"
[[ "$stacked" == *"localhost:/"* ]] || \
  fail "the refusal did not name what is already mounted there (${stacked})"
[[ "$stacked" == *"only uncovers the next"* ]] || \
  fail "the refusal did not warn that releasing one layer uncovers the next"
[[ "$stacked" == *afws-umount* ]] || \
  fail "the refusal did not say how to release what is there (${stacked})"

# Both mount functions have to pass through the guard. afws-remount calls
# afws_mount directly rather than going through a launcher, and the rclone view
# can be stacked just as an SSHFS mount can, so covering only one leaves the
# failure above reachable by the other route.
for mount_function in afws_mount afws_visibility_mount; do
  awk -v target="${mount_function}() {" '
    index($0, target) == 1 { inside = 1 }
    inside && /afws_refuse_to_stack/ { found = 1 }
    inside && /^}/ { exit }
    END { exit found ? 0 : 1 }
  ' "$LIBRARY" || fail "${mount_function} can stack a filesystem on an occupied path"
done

empty_path="$(mount_probe "$FAKE_MOUNTS" '
  afws_refuse_to_stack sshfs "example-workstation:/remote/elsewhere" "'"${AFWS_MOUNT_BASE}"'/unused"
  print -r -- ALLOWED')"
[[ "$empty_path" == ALLOWED ]] || \
  fail "the guard refused a path that carries no mount (${empty_path})"

# A mount that exists but cannot be read stands for a dead macFUSE mount. It is
# still found, but reported as stale rather than reusable, which is what sends
# the caller to afws-remount instead of straight into a broken workspace.
unreadable="${AFWS_MOUNT_BASE}/example-workstation/remote/dead"
mkdir -p "$unreadable"
chmod 000 "$unreadable"
if ! ls -1 "$unreadable" >/dev/null 2>&1; then
  print -r -- "example-workstation:/remote/dead on ${unreadable} (macfuse)" > "$FAKE_MOUNTS"
  dead="$(find_existing "$FAKE_MOUNTS" example-workstation /remote/dead)"
  [[ "$dead" == NONE* ]] || \
    fail "a disconnected mount was offered for reuse (${dead})"
  [[ "$dead" == *"stale=${unreadable}"* ]] || \
    fail "a disconnected mount was not reported as stale (${dead})"
  [[ "$dead" == *"reason=error"* ]] || \
    fail "a mount that answers with an error was not told apart from one that says nothing (${dead})"
fi
chmod 755 "$unreadable"

# A mount that answers nothing is not the same as one that answers with an
# error: a cold mount on a slow link also answers nothing, and telling someone
# to unmount that one costs them a working mount. The deadline is a knob for
# exactly that reason, so it has to be read rather than hardcoded.
readonly SLOW_BIN="${SANDBOX}/slow-bin"
mkdir -p "$SLOW_BIN"
cat >| "${SLOW_BIN}/ls" <<'STUB_LS'
#!/bin/zsh
sleep 30
STUB_LS
chmod +x "${SLOW_BIN}/ls"

probe_started=$SECONDS
slow_probe="$(PATH="${SLOW_BIN}:$PATH" zsh -c '
  set -eu
  AFWS_PROBE_TIMEOUT_SECONDS=1
  source '"$LIBRARY"'
  afws_directory_responds '"$SANDBOX"' && rc=0 || rc=$?
  print -r -- "${afws_probe_outcome} ${rc}"
')"
probe_elapsed=$(( SECONDS - probe_started ))
[[ "$slow_probe" == "timeout 1" ]] || \
  fail "a mount that answered nothing was not reported as a timeout (${slow_probe})"
(( probe_elapsed < 5 )) || \
  fail "AFWS_PROBE_TIMEOUT_SECONDS was ignored; the probe took ${probe_elapsed}s"

# Repair is afws-remount's job now that no launcher mounts a project tree.
# A timeout must not be treated as proof of death there either: unmounting a
# cold mount that was still setting up its first read costs a working mount.
print -r -- "example-workstation:/remote/dead on ${unreadable} (macfuse)" > "$FAKE_MOUNTS"
slow_repair="$(PATH="${SLOW_BIN}:$PATH" AFWS_PROBE_TIMEOUT_SECONDS=1 \
  AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" \
  "$REMOUNT" --dry-run example-workstation /remote/dead 2>&1 || true)"
[[ "$slow_repair" == *"does not prove it is disconnected"* ]] || \
  fail "afws-remount did not report an ambiguous mount timeout (${slow_repair})"
[[ "$slow_repair" == *"AFWS_PROBE_TIMEOUT_SECONDS=60"* ]] || \
  fail "afws-remount did not offer a longer probe before replacing the mount"
[[ "$slow_repair" != *"Would unmount"* ]] || \
  fail "afws-remount replaced a mount on timeout alone"
[[ "$slow_repair" == *"--force"* ]] || \
  fail "afws-remount did not say what to do when the mount really is stuck"

timeout_message="$(zsh -c 'AFWS_PROGRAM=test; source '"$LIBRARY"'; afws_stale_mount_message /some/path timeout')"
[[ "$timeout_message" == *"not proof that it is dead"* ]] || \
  fail "the timeout message stated more than the probe established"

healthy_probe="$(zsh -c '
  set -eu
  source '"$LIBRARY"'
  afws_directory_responds '"$SANDBOX"' && rc=0 || rc=$?
  print -r -- "${afws_probe_outcome} ${rc}"
')"
[[ "$healthy_probe" == "ok 0" ]] || \
  fail "a readable directory was not reported as responding (${healthy_probe})"

timeout_message="$(zsh -c '
  set -eu
  AFWS_PROGRAM=test
  source '"$LIBRARY"'
  afws_stale_mount_message /some/mount timeout
')"
[[ "$timeout_message" == *"not proof"* ]] || \
  fail "the timeout message claimed more than the probe established"
[[ "$timeout_message" == *pgrep* ]] || \
  fail "the timeout message did not say how to check whether sshfs is alive"
[[ "$timeout_message" != *ENXIO* ]] || \
  fail "the timeout message asserted the ENXIO diagnosis it has no evidence for"
[[ "$timeout_message" == *AFWS_PROBE_TIMEOUT_SECONDS* ]] || \
  fail "the timeout message did not offer a longer deadline"

# ssh reaches a password prompt through /dev/tty, which the mount's redirections
# do not cover. A background mount has nobody to answer one, so it must neither
# be able to ask nor be able to reach the terminal the agent is drawing on.
grep -q 'sshfs_options+=(-o BatchMode=yes)' "$LIBRARY" || \
  fail "sshfs was left able to ask for a password it has nobody to hear from"
grep -q 'sshfs_options+=(-o dir_cache=no)' "$LIBRARY" || \
  fail "sshfs directory caching can repeat the observed stale-empty readdir failure"
grep -q 'afws_detached "$logfile" sshfs' "$LIBRARY" || \
  fail "sshfs was started without taking its controlling terminal away"

# Taking it away means a session of its own; a session leader has no terminal
# inherited from here. Asserted on the process rather than on the source.
detach_log="$(mktemp "${SANDBOX}/afws-detach.XXXXXX")"
zsh -c '
  set -eu
  AFWS_PROGRAM=test
  source '"$LIBRARY"'
  afws_detached '"$detach_log"' zsh -c "ps -o stat= -p \$\$"
'
detach_waited=0
while (( detach_waited < 10 )) && [[ ! -s "$detach_log" ]]; do
  sleep 1
  detach_waited=$(( detach_waited + 1 ))
done
[[ "$(cat "$detach_log")" == *s* ]] || \
  fail "a detached command did not become a session leader ($(cat "$detach_log"))"
rm -f "$detach_log"

# ENXIO is one symptom of two different faults, and the message used to assert
# the one it could not see. A reconnect that cannot authenticate leaves the
# process running behind a mount that answers nothing else.
enxio_alive="$(zsh -c '
  set -eu
  AFWS_PROGRAM=test
  source '"$LIBRARY"'
  afws_sshfs_pids_for() { print -r -- "4242 "; }
  afws_stale_mount_message /some/mount error
')"
[[ "$enxio_alive" == *"still running"* ]] || \
  fail "a mount whose sshfs is alive was reported as one whose process died"
[[ "$enxio_alive" == *4242* ]] || fail "the surviving sshfs process was not named"
[[ "$enxio_alive" != *"process is gone"* ]] || \
  fail "the message asserted the process was gone while naming it as running"

enxio_dead="$(zsh -c '
  set -eu
  AFWS_PROGRAM=test
  source '"$LIBRARY"'
  afws_sshfs_pids_for() { print -r -- ""; }
  afws_stale_mount_message /some/mount error
')"
[[ "$enxio_dead" == *"process is gone"* ]] || \
  fail "a mount with no sshfs process left was not reported as dead"
[[ "$enxio_dead" == *"diskutil unmount force"* ]] || \
  fail "the dead-mount message stopped offering a way out"

# --- afws-remount --------------------------------------------------------

: > "$FAKE_MOUNTS"
remount_new="$(AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" \
  "$REMOUNT" --dry-run example-workstation /remote/project)"
[[ "$remount_new" == *"Would mount example-workstation:/remote/project"* ]] || \
  fail "afws-remount did not plan a missing mount"

remount_new_fresh="$(AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" \
  "$REMOUNT" --fresh-connection --dry-run example-workstation /remote/project)"
[[ "$remount_new_fresh" == *"Using a fresh SSH connection"* ]] || \
  fail "afws-remount could not request a fresh connection for a missing mount"
[[ "$remount_new_fresh" != *"over a shared SSH connection"* ]] || \
  fail "afws-remount mixed fresh and shared connection modes"

remount_from_session="$(AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" \
  AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  "$REMOUNT" --dry-run)"
[[ "$remount_from_session" == *"Would mount example-workstation:/remote/project"* ]] || \
  fail "afws-remount did not use the current session target"

print -r -- "example-workstation:/remote/project on ${FAKE_ROOT} (macfuse)" > "$FAKE_MOUNTS"
remount_healthy="$(AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" \
  "$REMOUNT" --dry-run example-workstation /remote/project)"
[[ "$remount_healthy" == *"Mount is healthy: ${FAKE_ROOT}"* ]] || \
  fail "afws-remount offered to replace a healthy mount"

remount_forced="$(AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" \
  "$REMOUNT" --force --dry-run example-workstation /remote/project)"
[[ "$remount_forced" == *"Would unmount ${FAKE_ROOT}"* ]] || \
  fail "afws-remount --force could not replace a healthy-looking wrong mount"
[[ "$remount_forced" == *"Would mount example-workstation:/remote/project"* ]] || \
  fail "afws-remount --force lost the source of a healthy-looking mount"
[[ "$remount_forced" == *"Using a fresh SSH connection"* ]] || \
  fail "afws-remount reused the possibly broken transport of a replacement mount"
[[ "$remount_forced" != *"over a shared SSH connection"* ]] || \
  fail "afws-remount attached a replacement to the old shared connection"

remount_reused="$(AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" \
  "$REMOUNT" --force --reuse-connection --dry-run example-workstation /remote/project)"
[[ "$remount_reused" == *"over a shared SSH connection"* ]] || \
  fail "afws-remount --reuse-connection did not keep password-auth recovery available"

expect_rejected "conflicting afws-remount connection modes" \
  "$REMOUNT" --fresh-connection --reuse-connection --dry-run \
  example-workstation /remote/project

write_record remount-user-1 codex "$$" example-workstation /remote/project \
  "$(date +%s)" "$FAKE_ROOT" "$FAKE_ROOT"
write_record remount-user-2 codex "$$" example-workstation /remote/project \
  "$(date +%s)" "$FAKE_ROOT" "$FAKE_ROOT"
expect_rejected "remounting a workspace shared by live sessions without explicit approval" \
  env AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" \
  "$REMOUNT" --force --dry-run example-workstation /remote/project
remount_shared="$(AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" \
  "$REMOUNT" --force --force-shared --dry-run example-workstation /remote/project)"
[[ "$remount_shared" == *"Would unmount ${FAKE_ROOT}"* ]] || \
  fail "afws-remount --force-shared did not acknowledge a shared replacement"
rm -f "${AFWS_STATE_DIR}/sessions/remount-user-1.conf" \
  "${AFWS_STATE_DIR}/sessions/remount-user-2.conf"

readonly FAIL_BIN="${SANDBOX}/fail-bin"
mkdir -p "$FAIL_BIN"
cat >| "${FAIL_BIN}/ls" <<'STUB_LS_FAIL'
#!/bin/zsh
exit 1
STUB_LS_FAIL
chmod +x "${FAIL_BIN}/ls"

# A confirmed disconnected mount is already unusable to every attached
# session. Startup repair may restore it for all of them without treating that
# restorative action like a forced replacement of a responding mount.
print -r -- "example-workstation:/remote/project on ${FAKE_ROOT} (macfuse)" > "$FAKE_MOUNTS"
write_record remount-dead-user-1 codex "$$" example-workstation /remote/project \
  "$(date +%s)" "$FAKE_ROOT" "$FAKE_ROOT"
write_record remount-dead-user-2 claude "$$" example-workstation /remote/project \
  "$(date +%s)" "$FAKE_ROOT" "$FAKE_ROOT"
remount_confirmed_shared="$(PATH="${FAIL_BIN}:$PATH" \
  AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" \
  "$REMOUNT" --dry-run example-workstation /remote/project)"
[[ "$remount_confirmed_shared" == *"confirmed disconnected; repairing it for all"* ]] || \
  fail "afws-remount refused automatic repair of a confirmed dead shared mount"
rm -f "${AFWS_STATE_DIR}/sessions/remount-dead-user-1.conf" \
  "${AFWS_STATE_DIR}/sessions/remount-dead-user-2.conf"

# A subdirectory session may be using a broader mount. Recovery must recreate
# the original source and mount point, not put a second mount inside it.
remount_failed="$(PATH="${FAIL_BIN}:$PATH" AFWS_PROBE_TIMEOUT_SECONDS=1 \
  AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" \
  "$REMOUNT" --dry-run example-workstation /remote/project/inner)"
[[ "$remount_failed" == *"Would unmount ${FAKE_ROOT}"* ]] || \
  fail "afws-remount did not release a confirmed failed mount"
[[ "$remount_failed" == *"Would mount example-workstation:/remote/project"* ]] || \
  fail "afws-remount lost the root of a reused parent mount"
[[ "$remount_failed" != *"example-workstation:/remote/project/inner"* ]] || \
  fail "afws-remount planned a nested replacement mount"

print -r -- "example-workstation:/remote/project/inner on ${FAKE_ROOT}/inner (macfuse)" > "$FAKE_MOUNTS"
expect_rejected "remounting over a nested work-station mount" \
  env AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" \
  "$REMOUNT" --dry-run example-workstation /remote/project

expect_rejected "afws-remount without a target outside a session" \
  env -u AFWS_SSH_HOST -u AFWS_REMOTE_DIR "$REMOUNT" --dry-run
expect_rejected "a relative afws-remount directory" \
  "$REMOUNT" --dry-run example-workstation relative

# --- afws-run -------------------------------------------------------------

runner_plan="$("$RUNNER" example-workstation --cwd /remote/project --dry-run -- printf '%s' 'hello world')"
[[ "$runner_plan" == ssh\ * && "$runner_plan" == *" example-workstation "* ]] || \
  fail "afws-run did not plan SSH execution"

# An isolated assignment redirects the session's project operations into its
# own checkout without the session having to know. The ledger publishes the
# path; afws-run reads it because it is on the path of every project operation
# and cannot afford to open the ledger each time.
checkout_state="$(mktemp -d)"
mkdir -p "${checkout_state}/session-meta"
print -r -- "/remote/project.afws-worktrees/abc" > "${checkout_state}/session-meta/fws-checkout.worktree"
redirected="$(AFWS_STATE_DIR="$checkout_state" AFWS_SESSION_NAME=fws-checkout \
  AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  "$RUNNER" --dry-run -- printf '%s' hello)"
[[ "$redirected" == *"/remote/project.afws-worktrees/abc"* ]] || \
  fail "afws-run did not follow the assignment's checkout (${redirected})"
# A caller that names a directory means it, and a session with no isolated
# assignment is not redirected anywhere.
named="$(AFWS_STATE_DIR="$checkout_state" AFWS_SESSION_NAME=fws-checkout \
  AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  "$RUNNER" --cwd /remote/elsewhere --dry-run -- printf '%s' hello)"
[[ "$named" == *"/remote/elsewhere"* && "$named" != *afws-worktrees* ]] || \
  fail "afws-run overrode an explicitly named directory"
plain="$(AFWS_STATE_DIR="$checkout_state" AFWS_SESSION_NAME=fws-nothing \
  AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  "$RUNNER" --dry-run -- printf '%s' hello)"
[[ "$plain" == *"/remote/project"* && "$plain" != *afws-worktrees* ]] || \
  fail "afws-run redirected a session that has no isolated assignment"
# A pointer that is empty, relative or unreadable means the project, not a
# guess: this runs before every project operation and must never invent a path.
print -rn -- "" > "${checkout_state}/session-meta/fws-checkout.worktree"
blank="$(AFWS_STATE_DIR="$checkout_state" AFWS_SESSION_NAME=fws-checkout \
  AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  "$RUNNER" --dry-run -- printf '%s' hello)"
[[ "$blank" == *"/remote/project"* ]] || fail "an empty checkout pointer did not fall back to the project"
print -r -- "relative/path" > "${checkout_state}/session-meta/fws-checkout.worktree"
relative="$(AFWS_STATE_DIR="$checkout_state" AFWS_SESSION_NAME=fws-checkout \
  AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  "$RUNNER" --dry-run -- printf '%s' hello)"
[[ "$relative" == *"/remote/project"* && "$relative" != *"relative/path"* ]] || \
  fail "a relative checkout pointer was not refused"
rm -rf "$checkout_state"

stdin_plan="$(print -r -- 'echo remote-script' | "$RUNNER" example-workstation --cwd /remote/project --dry-run)"
[[ "$stdin_plan" == *"bash\\ -s"* ]] || fail "afws-run did not plan Bash standard-input execution"

quoted="$("$RUNNER" example-workstation --cwd '/remote/project' --dry-run -- printf '%s' '$(not-a-command)')"
[[ "$quoted" != *'$(not-a-command)'* ]] || fail "afws-run left a command substitution unquoted"

environment_plan="$(AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  "$RUNNER" --dry-run -- pwd)"
[[ "$environment_plan" == ssh\ * && "$environment_plan" == *" example-workstation "* ]] || \
  fail "afws-run did not take the host and directory from the session environment"

environment_stdin="$(print -r -- 'echo remote-script' | \
  AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project "$RUNNER" --dry-run)"
[[ "$environment_stdin" == *"bash\\ -s"* ]] || \
  fail "afws-run did not accept a piped script using the session environment"

# Inside a mounted session, project files and Git belong on the mount. The
# guard's diagnostic stays on one line so one corrected tool call does not add
# an explanation-sized chunk to the agent's context.
guard_status=0
guard_output="$(AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  AFWS_LOCAL_WORKSPACE="${AFWS_MOUNT_BASE}/example-workstation/remote/project" \
  "$RUNNER" --dry-run git status 2>&1)" || guard_status=$?
(( guard_status != 0 )) || fail "afws-run allowed Git through the remote shell in a mounted session"
[[ "$guard_output" == *"use the mounted workspace"* ]] || \
  fail "the remote-file guard did not explain the local route (${guard_output})"
[[ "$guard_output" != *$'\n'* ]] || \
  fail "the remote-file guard wastes context with a multi-line diagnostic (${guard_output})"

for guarded_command in rg mkdir /usr/bin/git; do
  expect_rejected "remote project command ${guarded_command} in a mounted session" \
    env AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
    AFWS_LOCAL_WORKSPACE="${AFWS_MOUNT_BASE}/example-workstation/remote/project" \
    "$RUNNER" --dry-run "$guarded_command" probe
done

expect_rejected "a shell-wrapped remote Git worktree" \
  env AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  AFWS_LOCAL_WORKSPACE="${AFWS_MOUNT_BASE}/example-workstation/remote/project" \
  "$RUNNER" --dry-run sh -c 'cd src && git worktree add ../copy'
expect_rejected "a shell-wrapped remote directory creation" \
  env AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  AFWS_LOCAL_WORKSPACE="${AFWS_MOUNT_BASE}/example-workstation/remote/project" \
  "$RUNNER" --dry-run bash -lc 'mkdir generated'
expect_rejected "a multiline shell-wrapped remote project scan" \
  env AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  AFWS_LOCAL_WORKSPACE="${AFWS_MOUNT_BASE}/example-workstation/remote/project" \
  "$RUNNER" --dry-run bash -lc $'printf "TRUTH_FILES\\n"\nfind datasets results reports configs -maxdepth 5 -type f | sort\nprintf "DONE\\n"'
expect_rejected "a later shell-wrapped remote project scan" \
  env AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  AFWS_LOCAL_WORKSPACE="${AFWS_MOUNT_BASE}/example-workstation/remote/project" \
  "$RUNNER" --dry-run bash -lc 'nvidia-smi; grep pattern logs/job.log'
expect_rejected "a project scan behind env" \
  env AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  AFWS_LOCAL_WORKSPACE="${AFWS_MOUNT_BASE}/example-workstation/remote/project" \
  "$RUNNER" --dry-run env RUN_KIND=probe find .
expect_rejected "a project scan behind extra shell options" \
  env AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  AFWS_LOCAL_WORKSPACE="${AFWS_MOUNT_BASE}/example-workstation/remote/project" \
  "$RUNNER" --dry-run bash --noprofile -lc 'find .'
expect_rejected "a project scan after a shell control keyword" \
  env AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  AFWS_LOCAL_WORKSPACE="${AFWS_MOUNT_BASE}/example-workstation/remote/project" \
  "$RUNNER" --dry-run bash -lc 'if true; then find .; fi'
expect_rejected "a generic remote shell" \
  env AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  AFWS_LOCAL_WORKSPACE="${AFWS_MOUNT_BASE}/example-workstation/remote/project" \
  "$RUNNER" --dry-run bash

stdin_guard_status=0
stdin_guard_output="$(print -r -- 'find .' | \
  AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  AFWS_LOCAL_WORKSPACE="${AFWS_MOUNT_BASE}/example-workstation/remote/project" \
  "$RUNNER" --dry-run 2>&1)" || stdin_guard_status=$?
(( stdin_guard_status != 0 )) || \
  fail "afws-run allowed a project scan in a standard-input script"
[[ "$stdin_guard_output" != *$'\n'* ]] || \
  fail "the standard-input guard wastes context with a multi-line diagnostic"

stdin_runtime="$(print -r -- 'pytest -q' | \
  AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  AFWS_LOCAL_WORKSPACE="${AFWS_MOUNT_BASE}/example-workstation/remote/project" \
  "$RUNNER" --dry-run)"
[[ "$stdin_runtime" == *"bash\\ -s"* ]] || \
  fail "the standard-input guard rejected a runtime script"

allowed_remote_files="$(AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  AFWS_LOCAL_WORKSPACE="${AFWS_MOUNT_BASE}/example-workstation/remote/project" \
  "$RUNNER" --dry-run --allow-remote-files git status)"
[[ "$allowed_remote_files" == *"git\\ status"* ]] || \
  fail "--allow-remote-files did not allow an explicit remote-side operation"

outside_mount_git="$("$RUNNER" example-workstation --cwd /remote/project --dry-run -- git status)"
[[ "$outside_mount_git" == *"git\\ status"* ]] || \
  fail "the mounted-session guard changed afws-run outside a mounted session"

remote_first_git="$(AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  AFWS_LOCAL_WORKSPACE="${AFWS_STATE_DIR}/workspaces/session" AFWS_REMOTE_FIRST=1 \
  "$RUNNER" --dry-run git status)"
[[ "$remote_first_git" == *"git\\ status"* ]] || \
  fail "a remote-first session did not allow project Git by default"
expect_rejected "obsolete --allow-remote-files in a remote-first session" \
  env AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  AFWS_LOCAL_WORKSPACE="${AFWS_STATE_DIR}/workspaces/session" AFWS_REMOTE_FIRST=1 \
  "$RUNNER" --dry-run --allow-remote-files git status

# Local input is opt-in and the destination cannot escape the remote project.
push_plan="$(AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  AFWS_REMOTE_FIRST=1 AFWS_ALLOWED_LOCAL_DIRS="${SANDBOX}/papers" \
  "$PUSHER" --dry-run "${SANDBOX}/papers" inputs)"
[[ "$push_plan" == *"/remote/project/inputs/papers"* ]] || \
  fail "afws-push did not plan a project-confined transfer"
expect_rejected "pushing an unapproved local path" \
  env AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  AFWS_REMOTE_FIRST=1 AFWS_ALLOWED_LOCAL_DIRS="${SANDBOX}/papers" \
  "$PUSHER" --dry-run "${SANDBOX}/notes"
expect_rejected "pushing outside the remote project" \
  env AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  AFWS_REMOTE_FIRST=1 AFWS_ALLOWED_LOCAL_DIRS="${SANDBOX}/papers" \
  "$PUSHER" --dry-run "${SANDBOX}/papers" ../outside

remote_pipeline="$(AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  AFWS_LOCAL_WORKSPACE="${AFWS_MOUNT_BASE}/example-workstation/remote/project" \
  "$RUNNER" --dry-run sh -c 'nvidia-smi | wc -l')"
[[ "$remote_pipeline" == *nvidia-smi* ]] || \
  fail "the remote-file guard rejected a shell-wrapped environment command"

# The launcher's own helper directory wins over stale installations elsewhere
# on PATH, keeping the injected instructions and the executable guard in sync.
exported_path="$(zsh -c '
  set -eu
  SCRIPT_DIR=/current/afws/bin
  source '"$LIBRARY"'
  afws_agent=codex afws_session_name=s afws_ssh_host=h
  afws_remote_dir=/d afws_local_workspace=/w afws_control_socket_path=""
  PATH=/stale/bin:/usr/bin
  afws_export_session_environment
  print -r -- "$PATH"
')"
[[ "$exported_path" == /current/afws/bin:* ]] || \
  fail "a session can resolve a stale afws-run before its launcher's helper"

# Inside a session everything given is the remote command, so no '--' and no
# host: short enough to type after Claude Code's '!'.
short_form="$(AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  "$RUNNER" --dry-run nvidia-smi)"
[[ "$short_form" == ssh\ * && "$short_form" == *" example-workstation "* ]] || fail "afws-run did not accept the short form"
[[ "$short_form" == *nvidia-smi* ]] || fail "afws-run lost the command in the short form"

short_args="$(AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  "$RUNNER" --dry-run python train.py)"
[[ "$short_args" == *"python\\ train.py"* ]] || fail "afws-run lost an argument in the short form"

# A command spelled like a host must not be mistaken for one, and a real host
# must still be addressable from inside a session.
other_host="$(AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  "$RUNNER" other-workstation --cwd /elsewhere --dry-run -- pwd)"
[[ "$other_host" == ssh\ * && "$other_host" == *" other-workstation "* ]] || \
  fail "afws-run could not address another host from inside a session"

own_host="$(AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  "$RUNNER" example-workstation --dry-run -- pwd)"
[[ "$own_host" == ssh\ * && "$own_host" == *" example-workstation "* ]] || \
  fail "afws-run rejected its own host given explicitly"

dashed="$(AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  "$RUNNER" --dry-run -- nvidia-smi)"
[[ "$dashed" == ssh\ * && "$dashed" == *" example-workstation "* ]] || fail "afws-run rejected the short form with a leading --"

# Outside a session the host is still positional and required.
expect_rejected "a bare command with no session environment" \
  env -u AFWS_SSH_HOST "$RUNNER" --dry-run nvidia-smi

expect_rejected "the remote filesystem root" "$RUNNER" example-workstation --cwd / --dry-run -- pwd
expect_rejected "a control character in the remote path" \
  "$RUNNER" example-workstation --cwd $'/remote/project\nsecond' --dry-run -- pwd
expect_rejected "a relative remote path" "$RUNNER" example-workstation --cwd relative --dry-run -- pwd
expect_rejected "an invalid SSH config host name" "$RUNNER" 'invalid host' --cwd /remote/project --dry-run -- pwd
expect_rejected "a missing host with no session environment" "$RUNNER" --dry-run -- pwd
expect_rejected "a piped script with no host anywhere" \
  env -u AFWS_SSH_HOST sh -c "print -r -- pwd | '$RUNNER' --dry-run"

# A session labels where a command ran, and afws-run is the one that did not run
# here. Outside a session there is nothing to tell it apart from.
remote_marker="$(PATH="${STUB_BIN}:$PATH" AFWS_SESSION_NAME=probe AFWS_SSH_HOST=example-workstation \
  AFWS_REMOTE_DIR=/remote/project "$RUNNER" -- pwd 2>&1 >/dev/null || true)"
[[ "$remote_marker" == *'[remote] '* ]] || \
  fail "afws-run did not say that it ran somewhere else (${remote_marker})"

outside_session="$(PATH="${STUB_BIN}:$PATH" \
  "$RUNNER" example-workstation --cwd /remote/project -- pwd 2>&1 >/dev/null || true)"
[[ "$outside_session" != *'[remote]'* ]] || \
  fail "afws-run labelled itself outside a session, where nothing is labelled"

unlabelled="$(PATH="${STUB_BIN}:$PATH" AFWS_NO_SHELL_MARKER=1 AFWS_SESSION_NAME=probe \
  AFWS_SSH_HOST=example-workstation AFWS_REMOTE_DIR=/remote/project \
  "$RUNNER" -- pwd 2>&1 >/dev/null || true)"
[[ "$unlabelled" != *'[remote]'* ]] || \
  fail "AFWS_NO_SHELL_MARKER did not turn off the remote label"

# --- shared SSH connection reuse -----------------------------------------

if command -v python3 >/dev/null 2>&1; then
  short_state="/tmp/afws-sock-$$"
  mkdir -p "${short_state}/control"
  socket_path="${short_state}/control/example-workstation.sock"
  python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1)' "$socket_path" ||
    fail "could not create a test socket"

  shared="$(AFWS_STATE_DIR="$short_state" "$RUNNER" example-workstation --cwd /remote/project --dry-run -- pwd)"
  [[ "$shared" == *"ControlPath=${socket_path}"* ]] || fail "afws-run did not reuse the shared SSH connection"

  shared_lock="$(AFWS_STATE_DIR="$short_state" "$LOCK" status --host example-workstation --dry-run)"
  [[ "$shared_lock" == *"ControlPath=${socket_path}"* ]] || fail "afws-lock did not reuse the shared SSH connection"

  other="$(AFWS_STATE_DIR="$short_state" "$RUNNER" other-workstation --cwd /remote/project --dry-run -- pwd)"
  [[ "$other" != *"ControlPath=${socket_path}"* ]] || fail "afws-run reused a connection belonging to another host"

  mismatch="$(AFWS_STATE_DIR="$short_state" AFWS_CONTROL_PATH="$socket_path" \
    AFWS_SSH_HOST=example-workstation "$RUNNER" other-workstation --cwd /remote/project --dry-run -- pwd)"
  [[ "$mismatch" != *"ControlPath=${socket_path}"* ]] || fail "afws-run applied the session socket to a different host"

  # Falling back to a separate connection is allowed and usually works: a
  # key-authenticated host takes that path on every call and gets where it was
  # going. So the fallback is explained only when it actually failed, and only
  # when there was nowhere to have answered a password prompt.
  succeeded="$(PATH="${STUB_BIN}:$PATH" AFWS_STATE_DIR="$short_state" \
    "$RUNNER" other-workstation --cwd /remote/project -- true 2>&1 >/dev/null || true)"
  [[ -z "$succeeded" ]] || fail "a fallback that worked was complained about (${succeeded})"

  # 255 is ssh's own failure rather than the remote command's.
  ssh_failed="$(PATH="${STUB_BIN}:$PATH" STUB_SSH_EXIT=255 AFWS_STATE_DIR="$short_state" \
    "$RUNNER" other-workstation --cwd /remote/project -- true 2>&1 >/dev/null || true)"
  [[ "$ssh_failed" == *"no shared SSH connection to reuse"* ]] || \
    fail "ssh failed with nowhere to ask for a password and nothing said why"
  [[ "$ssh_failed" == *"ssh -M -S"* ]] || \
    fail "the failure did not say how to reopen the shared connection"

  # A remote command that fails is not the connection's fault.
  command_failed="$(PATH="${STUB_BIN}:$PATH" STUB_SSH_EXIT=1 AFWS_STATE_DIR="$short_state" \
    "$RUNNER" other-workstation --cwd /remote/project -- true 2>&1 >/dev/null || true)"
  [[ "$command_failed" != *"no shared SSH connection to reuse"* ]] || \
    fail "a failing remote command was blamed on the shared connection"

  # The status has to survive the reporting that was added around it.
  runner_status=0
  PATH="${STUB_BIN}:$PATH" STUB_SSH_EXIT=42 AFWS_STATE_DIR="$short_state" \
    "$RUNNER" other-workstation --cwd /remote/project -- true >/dev/null 2>&1 || runner_status=$?
  (( runner_status == 42 )) || fail "afws-run did not pass the remote exit status through (${runner_status})"

  ssh_failed_lock="$(PATH="${STUB_BIN}:$PATH" STUB_SSH_EXIT=255 AFWS_STATE_DIR="$short_state" \
    "$LOCK" status --host other-workstation 2>&1 >/dev/null || true)"
  [[ "$ssh_failed_lock" == *"no shared SSH connection to reuse"* ]] || \
    fail "afws-lock said nothing when ssh had nowhere to ask for a password"

  # A dry run connects to nothing, so it has nothing to report either way.
  quiet="$(AFWS_STATE_DIR="$short_state" "$RUNNER" other-workstation --cwd /remote/project --dry-run -- pwd 2>&1 >/dev/null)"
  [[ -z "$quiet" ]] || fail "a dry run reported on a connection it never opens (${quiet})"

  # ssh asks for a password on the controlling terminal. Where there is none --
  # inside an agent session -- it cannot ask at all, and that is the case the
  # explanation is for. The terminal check is stubbed rather than inherited, so
  # this holds whether or not the suite itself was started from a terminal.
  fallback_state() {
    zsh -c '
      set -eu
      AFWS_PROGRAM=test
      AFWS_STATE_DIR='"$short_state"'
      source '"$LIBRARY"'
      afws_has_controlling_terminal() { return '"${1}"'; }
      afws_control_ssh_options '"${2}"'
      print -r -- "OPTIONS=${afws_ssh_control_options[*]} FALLBACK=${afws_control_fallback}"
    ' 2>&1
  }

  no_terminal="$(fallback_state 1 other-workstation)"
  [[ "$no_terminal" == *"OPTIONS=-o BatchMode=yes"* ]] || \
    fail "ssh was left to hunt for an askpass helper with no terminal to ask on (${no_terminal})"
  [[ "$no_terminal" == *"FALLBACK=batch"* ]] || fail "the no-terminal fallback was not recorded as such"

  with_terminal="$(fallback_state 0 other-workstation)"
  [[ "$with_terminal" != *BatchMode* ]] || \
    fail "a terminal that could answer a password prompt was denied the chance"
  [[ "$with_terminal" == *"FALLBACK=terminal"* ]] || fail "the fallback on a terminal was not recorded as such"

  reusing="$(fallback_state 1 example-workstation)"
  [[ "$reusing" == *"ControlPath=${socket_path}"* ]] || fail "the shared connection was not reused (${reusing})"
  [[ "$reusing" != *BatchMode* ]] || fail "a reused connection was given BatchMode it does not need"
  [[ "$reusing" == *"FALLBACK=" ]] || \
    fail "reusing a connection was recorded as a fallback (${reusing})"

  # A master that dies must be replaced by whoever needs it next. -S alone only
  # ever reuses, so a consumer that outlives its launcher -- the rclone view, an
  # SSHFS mount -- was left holding a path to a socket nothing would recreate.
  for state in "$no_terminal" "$with_terminal" "$reusing"; do
    [[ "$state" == *"ControlMaster=auto"* ]] || \
      fail "a consumer was left unable to re-open the shared connection (${state})"
  done
  [[ "$no_terminal" == *"ControlPath="* ]] || \
    fail "the no-terminal fallback was given no control path to re-open"

  grep -q 'ControlMaster=auto' "$LIBRARY" || \
    fail "the shared connection is reused but never re-opened"
  grep -Fq 'sshfs_options+=("${afws_control_master_option_list[@]}")' "$LIBRARY" || \
    fail "an SSHFS mount cannot re-open the shared connection it outlives"
  grep -q 'ssh_command+=" -o ControlMaster=auto' "$LIBRARY" || \
    fail "the rclone view cannot re-open the shared connection it outlives"

  # Asking for separate connections on purpose is not a thing to report on.
  opted_out="$(PATH="${STUB_BIN}:$PATH" STUB_SSH_EXIT=255 AFWS_STATE_DIR="$short_state" \
    AFWS_NO_CONTROL_MASTER=1 \
    "$RUNNER" other-workstation --cwd /remote/project -- true 2>&1 >/dev/null || true)"
  [[ "$opted_out" != *"no shared SSH connection to reuse"* ]] || \
    fail "AFWS_NO_CONTROL_MASTER was reported on despite being deliberate"

  rm -rf "$short_state"
fi

# --- afws-doctor: failures that otherwise look like health ----------------
# Both of these leave a mount that is present and a process that is running, so
# nothing else in the suite -- or in the doctor as it stood -- reports them. The
# first sign used to be a person noticing that a directory listing had got slow.

reset_state
doctor_mounts="${SANDBOX}/doctor-mounts.txt"
stacked_path="${AFWS_MOUNT_BASE}/example-workstation/remote/project"
{
  print -r -- "localhost:/ on ${stacked_path} (nfs, nodev, nosuid)"
  print -r -- "example-workstation:/remote/project on ${stacked_path} (macfuse, nodev, nosuid)"
} > "$doctor_mounts"
stacked_doctor="$(AFWS_MOUNT_COMMAND="cat ${doctor_mounts}" \
  "${REPOSITORY_ROOT}/bin/afws-doctor" 2>&1 || true)"
[[ "$stacked_doctor" == *"stacked on the same path"* ]] || \
  fail "afws-doctor did not notice two filesystems mounted on one path"
[[ "$stacked_doctor" == *"${stacked_path}"* ]] || \
  fail "afws-doctor did not name the path that carries both"
[[ "$stacked_doctor" == *"2 layers"* ]] || \
  fail "afws-doctor did not say how many layers there are"
[[ "$stacked_doctor" == *"Release every layer"* ]] || \
  fail "afws-doctor did not warn that unmounting one layer uncovers the next"

print -r -- "example-workstation:/remote/project on ${stacked_path} (macfuse)" > "$doctor_mounts"
single_doctor="$(AFWS_MOUNT_COMMAND="cat ${doctor_mounts}" \
  "${REPOSITORY_ROOT}/bin/afws-doctor" 2>&1 || true)"
[[ "$single_doctor" == *"no mount is stacked"* ]] || \
  fail "afws-doctor reported stacking where a single mount stands alone"

# An arbitrary command must not be run here either, exactly as afws-peers
# refuses one; the doctor falls back to 'mount' rather than obeying it.
rm -f /tmp/afws-doctor-should-not-exist
AFWS_MOUNT_COMMAND='touch /tmp/afws-doctor-should-not-exist' \
  "${REPOSITORY_ROOT}/bin/afws-doctor" >/dev/null 2>&1 || true
[[ ! -e /tmp/afws-doctor-should-not-exist ]] || \
  fail "afws-doctor ran an arbitrary command from AFWS_MOUNT_COMMAND"

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

# --- Codex peer metadata and queue routing -------------------------------

reset_state
write_record cx-sender codex "$$" alpha /remote/project 1000000000
write_record cx-training codex "$$" alpha /remote/project 1000000001
write_record cx-other codex "$$" beta /srv/other 1000000002
write_record fws-review claude "$$" alpha /remote/project 1000000003

print -r -- '{"hook_event_name":"SessionStart","session_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}' |
  AFWS_SESSION_NAME=cx-training "$CODEX_HOOK" || fail "Codex SessionStart hook failed"
print -r -- '{"hook_event_name":"UserPromptSubmit","session_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","prompt":"Train the 8B model\\nmore details"}' |
  AFWS_SESSION_NAME=cx-training "$CODEX_HOOK" || fail "Codex prompt hook failed"
[[ "$(AFWS_SESSION_NAME=cx-training "$STATUS_HELPER" set '8B training')" == 'Activity: 8B training' ]] ||
  fail "afws-status could not set a manual task label"
print -r -- '{"hook_event_name":"UserPromptSubmit","session_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","prompt":"はい"}' |
  AFWS_SESSION_NAME=cx-training "$CODEX_HOOK" || fail "Codex prompt update failed"
json_listing="$("$PEERS" --json)"
[[ "$json_listing" == *'"thread_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"'* ]] ||
  fail "Codex hook thread ID was not listed"
[[ "$json_listing" == *'"activity":"8B training"'* ]] ||
  fail "manual task label did not survive the next prompt"
[[ "$json_listing" == *'"status":"busy"'* ]] || fail "Codex busy status was not listed"
[[ "$(print -r -- '{"hook_event_name":"Stop","session_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}' |
  AFWS_SESSION_NAME=cx-training "$CODEX_HOOK")" == '{}' ]] || fail "Codex Stop hook failed"
[[ "$("$PEERS" --json)" == *'"status":"idle"'* ]] || fail "Codex idle status was not listed"

peer_prompt='[AFWS peer message from cx-sender]
Checkpoint complete?
[End AFWS peer message]'
peer_hook_input="$(/usr/bin/python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"UserPromptSubmit","session_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","turn_id":"peer-turn-1","prompt":sys.argv[1]}))' "$peer_prompt")"
print -r -- "$peer_hook_input" | AFWS_SESSION_NAME=cx-training "$CODEX_HOOK" ||
  fail "Codex peer prompt hook failed"
[[ "$(< "${AFWS_STATE_DIR}/session-meta/cx-training.prompt")" == 'はい' ]] ||
  fail "peer message replaced the direct user task label"
peer_stop='{"hook_event_name":"Stop","session_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","turn_id":"peer-turn-1","stop_hook_active":false}'
peer_stop_result="$(print -r -- "$peer_stop" | AFWS_SESSION_NAME=cx-training "$CODEX_HOOK")"
[[ "$peer_stop_result" == *'"decision":"block"'* && "$peer_stop_result" == *'direct user task'* ]] ||
  fail "Codex peer turn did not request a return to the direct user task"
[[ "$("$PEERS" --json)" == *'"status":"busy"'* ]] ||
  fail "Codex peer continuation prematurely marked the session idle"
print -r -- '{"hook_event_name":"UserPromptSubmit","session_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","turn_id":"resume-turn-1","prompt":"[AFWS resume after peer message] Continue the direct user task"}' |
  AFWS_SESSION_NAME=cx-training "$CODEX_HOOK" || fail "Codex continuation prompt hook failed"
[[ "$(< "${AFWS_STATE_DIR}/session-meta/cx-training.prompt")" == 'はい' ]] ||
  fail "Codex continuation replaced the direct user task label"
[[ "$(print -r -- "$peer_stop" | AFWS_SESSION_NAME=cx-training "$CODEX_HOOK")" == '{}' ]] ||
  fail "Codex peer continuation was not one-shot"
print -r -- "$peer_hook_input" | AFWS_SESSION_NAME=cx-training "$CODEX_HOOK" ||
  fail "second Codex peer prompt hook failed"
[[ "$(print -r -- '{"hook_event_name":"Stop","session_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","turn_id":"peer-turn-1","stop_hook_active":true}' |
  AFWS_SESSION_NAME=cx-training "$CODEX_HOOK")" == '{}' ]] ||
  fail "active Stop continuation attempted to loop"
print -r -- "$peer_hook_input" | AFWS_SESSION_NAME=cx-training "$CODEX_HOOK" ||
  fail "third Codex peer prompt hook failed"
print -r -- '{"hook_event_name":"UserPromptSubmit","session_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","turn_id":"direct-turn-2","prompt":"New direct task"}' |
  AFWS_SESSION_NAME=cx-training "$CODEX_HOOK" || fail "direct user prompt hook failed"
[[ "$(print -r -- "$peer_stop" | AFWS_SESSION_NAME=cx-training "$CODEX_HOOK")" == '{}' ]] ||
  fail "superseded peer turn resumed a stale task"

print -r -- '{"hook_event_name":"SessionStart","session_id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"}' |
  AFWS_SESSION_NAME=cx-other "$CODEX_HOOK" || fail "second Codex hook failed"

cat >| "${STUB_BIN}/codex" <<'STUB_CODEX_QUEUE'
#!/bin/zsh
[[ "$1" == queue && "$2" == --thread && "$4" == --message ]] || exit 5
print -r -- "$3" >> "$AFWS_TEST_QUEUE_LOG"
print -r -- "$5" >> "${AFWS_TEST_QUEUE_LOG}.messages"
STUB_CODEX_QUEUE
chmod +x "${STUB_BIN}/codex"
export AFWS_TEST_QUEUE_LOG="${SANDBOX}/queued-threads"

direct_result="$(PATH="${STUB_BIN}:$PATH" AFWS_SESSION_NAME=cx-sender \
  "$MESSAGE" --to cx-training --message 'Checkpoint complete?')" || fail "direct queue failed"
[[ "$direct_result" == 'Queued for cx-training.' ]] || fail "direct queue output was wrong"
[[ "$(< "$AFWS_TEST_QUEUE_LOG")" == 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' ]] ||
  fail "direct queue used the wrong thread ID"
[[ "$(< "${AFWS_TEST_QUEUE_LOG}.messages")" == *'[AFWS peer message from cx-sender]'* ]] ||
  fail "queued message did not identify its sender"
claude_direct_result="$(PATH="${STUB_BIN}:$PATH" AFWS_SESSION_NAME=cx-sender \
  "$MESSAGE" --to fws-review --message 'Hello Claude')" || fail "direct Claude queue failed"
[[ "$claude_direct_result" == 'Queued for fws-review.' ]] || fail "direct Claude queue output was wrong"
claude_inbox_output="$(AFWS_SESSION_NAME=fws-review \
  AFWS_INSTANCE_ID=fws-review-instance AFWS_SESSION_TOKEN=fws-review-token \
  "$CLAUDE_INBOX" poll)" || fail "Claude inbox poll failed"
[[ "$claude_inbox_output" == *'[AFWS peer message from cx-sender]'* &&
   "$claude_inbox_output" == *'Hello Claude'* ]] || fail "Claude inbox lost its peer message"
[[ -z "$(AFWS_SESSION_NAME=fws-review \
  AFWS_INSTANCE_ID=fws-review-instance AFWS_SESSION_TOKEN=fws-review-token \
  "$CLAUDE_INBOX" poll)" ]] || fail "Claude inbox did not consume its message once"
expect_rejected "queue to a Codex session before its first turn" env PATH="${STUB_BIN}:$PATH" \
  AFWS_SESSION_NAME=cx-training "$MESSAGE" --to cx-sender --message hello

PATH="${STUB_BIN}:$PATH" AFWS_SESSION_NAME=cx-sender \
  "$MESSAGE" --to fws-review --message 'Continue the review' >/dev/null ||
  fail "Claude hook test message could not be queued"
claude_hook_output="$(print -r -- '{"hook_event_name":"SessionStart","session_id":"claude-session-id","source":"startup"}' |
  AFWS_SESSION_NAME=fws-review AFWS_INSTANCE_ID=fws-review-instance \
  AFWS_SESSION_TOKEN=fws-review-token AFWS_SSH_HOST=alpha \
  AFWS_REMOTE_DIR=/remote/project "$CLAUDE_HOOK")" || fail "Claude SessionStart hook failed"
[[ "$claude_hook_output" == *'Continue the review'* ]] || fail "Claude hook did not inject its inbox"
[[ "$(< "${AFWS_STATE_DIR}/session-meta/fws-review.thread")" == claude-session-id ]] ||
  fail "Claude hook did not record its session ID"
[[ "$(< "${AFWS_STATE_DIR}/session-meta/fws-review.state")" == idle ]] ||
  fail "Claude SessionStart hook state was wrong"
claude_stop_output="$(print -r -- '{"hook_event_name":"Stop","session_id":"claude-session-id","stop_hook_active":false}' |
  AFWS_SESSION_NAME=fws-review AFWS_INSTANCE_ID=fws-review-instance \
  AFWS_SESSION_TOKEN=fws-review-token AFWS_SSH_HOST=alpha \
  AFWS_REMOTE_DIR=/remote/project "$CLAUDE_HOOK")" || fail "Claude Stop hook failed"
[[ "$claude_stop_output" == '{}' ]] || fail "idle Claude Stop hook attempted to continue"

: > "$AFWS_TEST_QUEUE_LOG"
broadcast_result="$(PATH="${STUB_BIN}:$PATH" AFWS_SESSION_NAME=cx-sender \
  AFWS_SSH_HOST=alpha AFWS_REMOTE_DIR=/remote/project \
  "$MESSAGE" --all --same --message 'Please pause')" || fail "same-project broadcast failed"
[[ "$broadcast_result" == 'Queued for cx-training.' ]] || fail "same-project broadcast included a wrong peer"
[[ "$(wc -l < "$AFWS_TEST_QUEUE_LOG" | tr -d ' ')" == 1 ]] || fail "same-project broadcast sent more than once"

: > "$AFWS_TEST_QUEUE_LOG"
PATH="${STUB_BIN}:$PATH" AFWS_SESSION_NAME=cx-sender \
  "$MESSAGE" --all --message 'Status please' >/dev/null || fail "all-peer broadcast failed"
[[ "$(wc -l < "$AFWS_TEST_QUEUE_LOG" | tr -d ' ')" == 2 ]] || fail "broadcast missed a Codex peer"

# The organization ledger is project-scoped, retains declared membership when
# a session is offline, and overlays live state only when displayed.
org() {
  AFWS_SSH_HOST=alpha AFWS_REMOTE_DIR=/remote/project AFWS_SESSION_NAME=cx-sender \
    AFWS_INSTANCE_ID=cx-sender-instance AFWS_SESSION_TOKEN=cx-sender-token "$ORG" "$@"
}
# Re-register the second test agent in this project; cross-project members are
# deliberately rejected by the organization ledger.
write_record cx-other codex "$$" alpha /remote/project 1000000002
org init >/dev/null || fail "organization initialization failed"
org add-team task-a cx-sender >/dev/null || fail "organization team creation failed"
org add-member task-a cx-training 'Run regression tests' >/dev/null || fail "organization member creation failed"
org add-team task-b cx-other >/dev/null || fail "second organization team creation failed"
org set-scope cx-training 'tests/auth/**' >/dev/null || fail "organization write scope update failed"
org set-state cx-training delivered >/dev/null || fail "organization delivery state update failed"
org set-state cx-training acknowledged >/dev/null || fail "organization acknowledgement failed"
org set-state cx-training running >/dev/null || fail "organization state update failed"
org validate >/dev/null || fail "a valid organization failed validation"
org_tree="$(org show)"
[[ "$org_tree" == *'Coordinator: cx-sender'* && "$org_tree" == *'Team task-a'* &&
   "$org_tree" == *'cx-training'*'running'*'Run regression tests'* ]] ||
  fail "organization tree omitted structure or assignment (${org_tree})"
org_json="$(org show --json)"
[[ "$org_json" == *'"name":"task-a"'* && "$org_json" == *'"write_scope":"tests/auth"'* ]] ||
  fail "organization JSON omitted machine-readable state (${org_json})"
org move-member cx-training task-b --cancel-active >/dev/null || fail "organization member move failed"
[[ "$(org show --team task-b)" == *cx-training* ]] || fail "moved member did not appear in the destination team"
expect_rejected "removing a team lead" env AFWS_SSH_HOST=alpha AFWS_REMOTE_DIR=/remote/project \
  AFWS_SESSION_NAME=cx-sender AFWS_INSTANCE_ID=cx-sender-instance AFWS_SESSION_TOKEN=cx-sender-token \
  "$ORG" remove-member cx-other
expect_rejected "an invalid organization task state" env AFWS_SSH_HOST=alpha AFWS_REMOTE_DIR=/remote/project \
  AFWS_SESSION_NAME=cx-sender AFWS_INSTANCE_ID=cx-sender-instance AFWS_SESSION_TOKEN=cx-sender-token \
  "$ORG" set-state cx-training invented
python3 "${REPOSITORY_ROOT}/scripts/test_org_resilience.py" >/dev/null || \
  fail "organization resilience tests failed"

"$STATUS_HELPER" --help >/dev/null || fail "afws-status help failed"
AFWS_SESSION_NAME=cx-training "$STATUS_HELPER" clear >/dev/null || fail "afws-status clear failed"
[[ "$("$PEERS" --json)" == *'"activity":"New direct task"'* ]] || fail "prompt fallback was not restored"

write_record cx-gone codex 999999 alpha /remote/gone 1000000004
mkdir -p "${AFWS_STATE_DIR}/session-meta"
print -r -- 'cccccccc-cccc-cccc-cccc-cccccccccccc' > "${AFWS_STATE_DIR}/session-meta/cx-gone.thread"
"$PEERS" --prune
[[ ! -e "${AFWS_STATE_DIR}/session-meta/cx-gone.thread" ]] || fail "dead session left its thread metadata"

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

write_record cx-agent-only codex 999999 example-workstation /remote/project 1000000000 \
  "$RELEASE_POINT" "$RELEASE_POINT" "$$"
[[ "$("$PEERS" --users-of-mount "$RELEASE_POINT")" == 3 ]] || \
  fail "a surviving agent with a dead launcher was not counted"
rm -f "${AFWS_STATE_DIR}/sessions/cx-agent-only.conf"

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

# SIGKILL cannot run a shell trap. The detached watchdog waits for a surviving
# agent, then removes the record and releases the mount after that agent ends.
watch_umount_marker="${SANDBOX}/watchdog-umount"
watch_log="${SANDBOX}/watchdog.log"
watch_name=cx-watchdog-probe
: > "$watch_umount_marker"

apply_umount_stub="${STUB_BIN}/umount"
cat >| "$apply_umount_stub" <<'STUB_UMOUNT'
#!/bin/zsh
print -r -- "$1" >> "$STUB_UMOUNT_MARKER"
STUB_UMOUNT
chmod +x "$apply_umount_stub"

/bin/sleep 30 &
watch_launcher_pid=$!
/bin/sleep 30 &
watch_agent_pid=$!
write_record "$watch_name" codex "$watch_launcher_pid" example-workstation \
  /remote/project 1000000000 "$RELEASE_POINT" "$RELEASE_POINT" "$watch_agent_pid"

PATH="${STUB_BIN}:$PATH" STUB_UMOUNT_MARKER="$watch_umount_marker" \
  AFWS_MOUNT_COMMAND="cat ${FAKE_MOUNTS}" \
  "$UMOUNT" --watch-launcher "$watch_launcher_pid" "$watch_name" \
  >"$watch_log" 2>&1 &
watchdog_pid=$!
watch_ready="${AFWS_STATE_DIR}/watchdogs/${watch_name}.${watch_launcher_pid}.ready"
watch_waited=0
while (( watch_waited < 10 )) && [[ ! -s "$watch_ready" ]]; do
  sleep 1
  watch_waited=$(( watch_waited + 1 ))
done
[[ -s "$watch_ready" ]] || fail "the cleanup watchdog did not become ready"

kill -9 "$watch_launcher_pid" 2>/dev/null || true
wait "$watch_launcher_pid" 2>/dev/null || true
sleep 2
[[ -e "${AFWS_STATE_DIR}/sessions/${watch_name}.conf" ]] || \
  fail "the watchdog removed a session whose agent was still alive"
[[ ! -s "$watch_umount_marker" ]] || \
  fail "the watchdog unmounted a workspace underneath a surviving agent"

kill -9 "$watch_agent_pid" 2>/dev/null || true
wait "$watch_agent_pid" 2>/dev/null || true
watch_waited=0
while (( watch_waited < 10 )) && kill -0 "$watchdog_pid" 2>/dev/null; do
  sleep 1
  watch_waited=$(( watch_waited + 1 ))
done
wait "$watchdog_pid" 2>/dev/null || fail "the cleanup watchdog failed: $(cat "$watch_log")"
[[ ! -e "${AFWS_STATE_DIR}/sessions/${watch_name}.conf" ]] || \
  fail "the cleanup watchdog left its dead session registered"
[[ "$(cat "$watch_umount_marker")" == "$RELEASE_POINT" ]] || \
  fail "the cleanup watchdog did not unmount the dead session"

reset_state

# --- afws-shell -----------------------------------------------------------

marker_out="$("$SHELL_WRAPPER" 'echo only-stdout' 2>/dev/null)"
[[ "$marker_out" == only-stdout ]] || fail "the shell wrapper altered standard output"

marker_err="$("$SHELL_WRAPPER" 'echo ignored' 2>&1 >/dev/null)"
[[ "$marker_err" == '[local] ' ]] || fail "the shell wrapper did not label the command on stderr"

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

# A command that mentions afws-run is left to afws-run's own [remote] label.
# The agent wraps the command line before the wrapper sees it, so this has to
# match on a substring rather than on the first word.
bare="$("$SHELL_WRAPPER" 'afws-run pwd' 2>&1 >/dev/null || true)"
[[ "$bare" != *'[local]'* ]] || \
  fail "a command handed to afws-run was labelled twice (${bare})"

wrapped="$("$SHELL_WRAPPER" "true && eval 'afws-run pwd'" 2>&1 >/dev/null || true)"
[[ "$wrapped" != *'[local]'* ]] || \
  fail "the wrapping the agent adds defeated the check (${wrapped})"

# The mistake this labelling exists to catch is a command that never mentions
# the workstation and runs here anyway. Those are always labelled.
local_only="$("$SHELL_WRAPPER" 'python --version' 2>&1 >/dev/null || true)"
[[ "$local_only" == *'[local]'* ]] || \
  fail "a command that never leaves this Mac was not labelled (${local_only})"

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
[[ "$lock_plan" == ssh\ * && "$lock_plan" == *" example-workstation "* ]] || \
  fail "afws-lock did not plan SSH execution"
[[ "$lock_plan" == *"--- remote script ---"* ]] || fail "afws-lock did not show the remote script"
[[ "$lock_plan" == *'\~/.afws-locks'* ]] || \
  fail "afws-lock did not keep the remote lock root unexpanded for the remote shell"

environment_lock="$(AFWS_SSH_HOST=example-workstation "$LOCK" status --dry-run)"
[[ "$environment_lock" == ssh\ * && "$environment_lock" == *" example-workstation "* ]] || \
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

# --- afws-lab -------------------------------------------------------------
# The work station is shared: 21 accounts, and ps is not restricted, so every
# one of them can read another's command line. Two of these are about that, and
# one is about not killing a tmux session the user made themselves.

readonly LAB="${REPOSITORY_ROOT}/bin/afws-lab"

reset_state
[[ -x "$LAB" ]] || fail "afws-lab is not installed next to the other commands"
"$LAB" --help >/dev/null || fail "afws-lab has no usage text"

# A token on the command line is readable by every other account on the host,
# so it is never put there: Jupyter generates one and it is read back out of
# the runtime file it writes. This checks for something NOT being present,
# which is the only way to keep it from quietly coming back.
if grep -q 'ServerApp.token' "$LAB"; then
  fail "afws-lab passes a token on the command line, where ps exposes it to every other account"
fi
grep -Fq 'ServerApp.ip=127.0.0.1' "$LAB" || \
  fail "afws-lab does not pin JupyterLab to the loopback address"
if grep -q '0\.0\.0\.0' "$LAB"; then
  fail "afws-lab has a route to binding JupyterLab on every interface"
fi

# The user's own long-running tmux sessions live beside these. Killing by a
# name that came from a record is not enough on its own.
grep -Fq 'lab_tmux_name_is_ours' "$LAB" || \
  fail "afws-lab kills a tmux session without checking the name is one of its own"

# Reachability is not liveness. A dropped connection must never be read as
# permission to tear down a session that is still running on the work station.
grep -Fq 'lab_tmux_state" == present' "$LAB" || \
  fail "afws-lab acts on a tmux session whose state it could not determine"

# Sessions using one directory share one JupyterLab, counted the same way the
# mounts are. A second counter would drift from the first.
grep -Fq 'users-of-mount' "$LAB" || \
  fail "afws-lab counts its users separately from the rest of the registry"

lab_outside=0
"$LAB" status >/dev/null 2>&1 || lab_outside=$?
(( lab_outside == 2 )) || \
  fail "afws-lab did not refuse to run outside a session (status ${lab_outside})"

write_record fws-lab-session claude "$$" example-workstation /remote/project "$(date +%s)"
lab_plan="$(AFWS_SESSION_NAME=fws-lab-session "$LAB" --dry-run 2>&1 || true)"
[[ "$lab_plan" == *example-workstation* ]] || \
  fail "afws-lab did not take the host from the session record (${lab_plan})"
[[ "$lab_plan" == *afws-lab-* ]] || \
  fail "afws-lab planned a tmux session outside its own namespace (${lab_plan})"

# --- lib/afws-fs-mcp.py ---------------------------------------------------
# The MCP server is what lets a remote-first Claude session keep structured
# file tools without a mount. Its one hard boundary is the project directory,
# and a path that climbs out must be refused before it can reach ssh at all.

readonly FS_MCP="${REPOSITORY_ROOT}/lib/afws-fs-mcp.py"
[[ -f "$FS_MCP" ]] || fail "the remote-filesystem MCP server is missing"

mcp_call() {
  # mcp_call TOOL JSON_ARGUMENTS -> the text of the single tool result
  {
    print -r -- '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
    print -r -- "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"${1}\",\"arguments\":${2}}}"
  } | AFWS_SSH_HOST=afws-test-unreachable-host AFWS_REMOTE_DIR=/remote/project \
      python3 "$FS_MCP" 2>&1 | tail -1
}

mcp_missing=0
print -r -- '{}' | python3 "$FS_MCP" >/dev/null 2>&1 || mcp_missing=$?
(( mcp_missing == 2 )) || \
  fail "the MCP server started without being told which host and directory to serve"

mcp_tools="$(print -r -- '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | \
  AFWS_SSH_HOST=example AFWS_REMOTE_DIR=/remote/project python3 "$FS_MCP" 2>&1)"
for tool in read_file write_file edit_file list_directory glob grep stat; do
  [[ "$mcp_tools" == *"\"${tool}\""* ]] || \
    fail "the MCP server does not offer ${tool}, so that work falls back to the shell"
done

# The host below does not exist. A refusal that still arrives proves the path
# was rejected here rather than out on the work station.
climbing="$(mcp_call read_file '{"path":"../../../etc/passwd"}')"
[[ "$climbing" == *'"isError": true'* ]] || \
  fail "a path climbing out of the project was accepted (${climbing})"
[[ "$climbing" == *"climb out of the project"* ]] || \
  fail "the refusal did not say why the path was rejected (${climbing})"

absolute="$(mcp_call read_file '{"path":"/etc/passwd"}')"
[[ "$absolute" == *'"isError": true'* ]] || \
  fail "an absolute path outside the project was accepted (${absolute})"

for confined_tool in write_file list_directory glob stat; do
  case "$confined_tool" in
    write_file) arguments='{"path":"../escaped","content":"x"}' ;;
    glob)       arguments='{"pattern":"../*"}' ;;
    *)          arguments='{"path":"../.."}' ;;
  esac
  refused="$(mcp_call "$confined_tool" "$arguments")"
  [[ "$refused" == *'"isError": true'* ]] || \
    fail "${confined_tool} accepted a path outside the project (${refused})"
done

print -r -- "All tests passed."
