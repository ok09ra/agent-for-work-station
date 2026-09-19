# afws-common.zsh — shared by every agent-for-work-station command.
#
# Sourced, never executed. A caller sets AFWS_PROGRAM to its own name before
# sourcing, so that messages are attributed correctly, and then uses the
# functions below. Nothing here is specific to Claude Code or to Codex CLI:
# the two launchers differ only in how they start their agent.
#
# zsh note: never name a variable 'path' (it is tied to $PATH as an array and
# assigning to it destroys command lookup inside the function) or 'status'
# (read-only). scripts/test.sh checks for both.

: ${AFWS_PROGRAM:=afws}
: ${AFWS_MOUNT_BASE:=${HOME}/afws-mounts}
: ${AFWS_STATE_DIR:=${HOME}/.afws}
: ${AFWS_MOUNT_COMMAND:=mount}
: ${AFWS_LOCK_TTL:=7200}
# A pre-authenticated SSH channel should not outlive the sessions using it. The
# launcher closes it when the last session exits, but a session killed with
# SIGKILL never gets to, so the connection also expires on its own.
: ${AFWS_CONTROL_PERSIST:=600}
# Quoted on purpose: the tilde must survive to the remote shell rather than
# being expanded to this Mac's home directory here.
: ${AFWS_REMOTE_LOCK_DIR:="~/.afws-locks"}

AFWS_SESSION_DIR="${AFWS_STATE_DIR}/sessions"
AFWS_CONTROL_DIR="${AFWS_STATE_DIR}/control"
AFWS_LOG_DIR="${AFWS_STATE_DIR}/logs"
AFWS_MOUNT_TIMEOUT_SECONDS=30
# A Unix domain socket path cannot exceed 104 bytes on macOS.
AFWS_SOCKET_PATH_LIMIT=100
# A record written just before the agent starts is not visible to the agent's
# own session listing yet, so young records are never pruned.
AFWS_REGISTRATION_GRACE_SECONDS=90

# zselect is a zsh builtin, so waiting never depends on an external sleep being
# present. It returns non-zero when it simply times out, which is normal here.
zmodload zsh/zselect 2>/dev/null || true

afws_die() {
  print -u2 -r -- "${AFWS_PROGRAM}: $*"
  exit 2
}

afws_pause_seconds() {
  if zmodload -e zsh/zselect; then
    zselect -t $(( $1 * 100 )) 2>/dev/null || true
  else
    command sleep "$1" 2>/dev/null || true
  fi
}

# --- input validation -----------------------------------------------------

afws_validate_host() {
  case "$1" in
    ''|-*|*[!A-Za-z0-9._-]*)
      afws_die "invalid SSH config host name"
      ;;
  esac
}

# Prints the normalized remote directory, or dies explaining why it cannot.
afws_normalize_remote_dir() {
  local remote_dir="$1" for_check

  [[ "$remote_dir" == /* ]] ||
    afws_die "remote directory must be an absolute path"
  [[ "$remote_dir" != *[[:cntrl:]]* ]] ||
    afws_die "remote directory must not contain control characters"
  [[ "$remote_dir" != "/" ]] ||
    afws_die "refusing to use the remote filesystem root; choose a project directory"

  remote_dir="${remote_dir%/}"
  for_check="/${remote_dir#/}/"
  if [[ "$for_check" == *"/../"* || "$for_check" == *"/./"* || "$for_check" == *"//"* ]]; then
    afws_die "use a normalized remote path without '.', '..', or repeated slashes"
  fi

  print -r -- "$remote_dir"
}

afws_validate_session_name() {
  case "$1" in
    ''|-*|*[!A-Za-z0-9._-]*)
      afws_die "a session name may contain only letters, numbers, '.', '_', and '-'"
      ;;
  esac
}

# --- session naming -------------------------------------------------------

afws_sanitize_component() {
  local cleaned="${1//[^A-Za-z0-9._-]/-}"

  while [[ "$cleaned" == *--* ]]; do
    cleaned="${cleaned//--/-}"
  done
  cleaned="${cleaned#-}"
  cleaned="${cleaned%-}"

  print -r -- "${cleaned[1,24]}"
}

# afws_allocate_session_name BASE -> prints the first unused BASE-N
afws_allocate_session_name() {
  local base="$1" index=1 candidate

  while (( index <= 999 )); do
    candidate="${base}-${index}"
    if [[ ! -e "${AFWS_SESSION_DIR}/${candidate}.conf" ]]; then
      print -r -- "$candidate"
      return 0
    fi
    index=$(( index + 1 ))
  done

  return 1
}

# --- mount table ----------------------------------------------------------

# A macFUSE mount whose sshfs process is gone still passes -d, but every read
# inside it fails with ENXIO; only a directory read exposes that. A mount that
# is merely hung would block forever, so the probe is given a deadline, and
# success is signalled through a marker file rather than the job's exit status,
# which is not reliably retrievable once the job has been reaped.
afws_directory_responds() {
  local target="$1" waited=0 probe_pid probe_marker result=1

  probe_marker="$(mktemp "${TMPDIR:-/tmp}/afws-probe.XXXXXX")" || return 1

  ( ls -1 "$target" >/dev/null 2>&1 && print -r -- ok >"$probe_marker" ) &
  probe_pid=$!

  while (( waited < 5 )); do
    kill -0 "$probe_pid" 2>/dev/null || break
    afws_pause_seconds 1
    waited=$(( waited + 1 ))
  done

  kill -9 "$probe_pid" 2>/dev/null || true
  [[ -s "$probe_marker" ]] && result=0
  rm -f "$probe_marker"

  return "$result"
}

# afws_find_existing_mount HOST REMOTE_DIR
# On success sets afws_local_workspace, afws_mount_source and afws_mount_point.
# A matching but unresponsive mount is reported in afws_stale_mount instead.
afws_find_existing_mount() {
  local ssh_host="$1" remote_dir="$2"
  local mount_line src remainder mount_path remote_root suffix candidate

  afws_local_workspace=""
  afws_mount_source=""
  afws_mount_point=""
  afws_stale_mount=""

  while IFS= read -r mount_line; do
    src="${mount_line%% on *}"
    [[ "$src" == "${ssh_host}:"* ]] || continue

    remainder="${mount_line#* on }"
    mount_path="${remainder%% \(*}"
    remote_root="${src#${ssh_host}:}"
    [[ "$remote_root" == "/" ]] || remote_root="${remote_root%/}"

    if [[ "$remote_dir" == "$remote_root" ]]; then
      suffix=""
    elif [[ "$remote_root" == "/" && "$remote_dir" == /* ]]; then
      suffix="$remote_dir"
    elif [[ "$remote_dir" == "${remote_root}/"* ]]; then
      suffix="${remote_dir#${remote_root}}"
    else
      continue
    fi

    candidate="${mount_path%/}${suffix}"
    if [[ -d "$candidate" ]]; then
      if afws_directory_responds "$candidate"; then
        afws_local_workspace="$candidate"
        afws_mount_source="$src"
        afws_mount_point="$mount_path"
        return 0
      fi
      afws_stale_mount="$mount_path"
    fi
  done < <(${=AFWS_MOUNT_COMMAND})

  return 1
}

# afws_find_nested_mount WORKSPACE
# A mount point under the one we are about to create would be hidden by it, and
# the session that owns it would silently start resolving its workspace through
# our mount instead. Sets afws_nested_mount.
afws_find_nested_mount() {
  local workspace="$1" mount_line remainder mount_path

  afws_nested_mount=""

  while IFS= read -r mount_line; do
    remainder="${mount_line#* on }"
    mount_path="${remainder%% \(*}"
    if [[ "$mount_path" == "${workspace}/"* ]]; then
      afws_nested_mount="$mount_path"
      return 0
    fi
  done < <(${=AFWS_MOUNT_COMMAND})

  return 1
}

afws_mount_is_present() {
  ${=AFWS_MOUNT_COMMAND} | grep -Fq " on $1 ("
}

afws_stale_mount_message() {
  print -r -- "the SSHFS mount at $1 is present but not responding
Its sshfs process is gone, so every path inside it fails with ENXIO. Unmount it,
then start again:
  umount ${(q)1}
If that is refused, close anything still sitting in that directory, or force it:
  diskutil unmount force ${(q)1}"
}

# --- shared SSH connection ------------------------------------------------
# A detached sshfs cannot answer a password prompt, and a session's remote
# commands have nobody to ask either. One multiplexed connection is
# authenticated in the foreground and reused by everything afterwards.

afws_control_socket() {
  print -r -- "${AFWS_CONTROL_DIR}/$1.sock"
}

afws_check_socket_length() {
  local socket="$1"

  if (( ${#socket} > AFWS_SOCKET_PATH_LIMIT )); then
    afws_die "the shared-connection socket path is too long (${#socket} > ${AFWS_SOCKET_PATH_LIMIT} bytes): ${socket}
Set AFWS_STATE_DIR to a shorter directory, or set AFWS_NO_CONTROL_MASTER=1 to connect separately each time."
  fi
}

afws_control_master_is_open() {
  local ssh_host="$1" socket="$2"

  [[ -S "$socket" ]] || return 1
  ssh -S "$socket" -O check "$ssh_host" >/dev/null 2>&1
}

afws_open_control_master() {
  local ssh_host="$1" socket="$2"

  mkdir -p "$AFWS_CONTROL_DIR"
  chmod 700 "$AFWS_STATE_DIR" "$AFWS_CONTROL_DIR" 2>/dev/null || true

  if afws_control_master_is_open "$ssh_host" "$socket"; then
    print -r -- "Reusing the shared SSH connection to ${ssh_host}"
    return 0
  fi

  rm -f "$socket"
  print -r -- "Opening a shared SSH connection to ${ssh_host}"
  ssh -M -S "$socket" -o "ControlPersist=${AFWS_CONTROL_PERSIST}" -f -N "$ssh_host"
}

afws_close_control_master() {
  local ssh_host="$1" socket="$2"

  [[ -S "$socket" ]] || return 0
  ssh -S "$socket" -O exit "$ssh_host" >/dev/null 2>&1 || true
}

# Used by afws-run and afws-lock: the session's socket when it belongs to the
# host being addressed, otherwise the default location for that host.
afws_resolve_control_path() {
  local ssh_host="$1"

  if [[ -n "${AFWS_CONTROL_PATH-}" && "${AFWS_SSH_HOST-}" == "$ssh_host" ]]; then
    print -r -- "$AFWS_CONTROL_PATH"
  else
    afws_control_socket "$ssh_host"
  fi
}

# --- mounting -------------------------------------------------------------

# afws_mount HOST REMOTE_DIR WORKSPACE SOCKET_OR_EMPTY LOGFILE
afws_mount() {
  local ssh_host="$1" remote_dir="$2" workspace="$3" socket="$4" logfile="$5"
  local waited=0
  local -a sshfs_options

  mkdir -p "$workspace"
  mkdir -p "${logfile:h}"
  chmod 700 "$AFWS_LOG_DIR" 2>/dev/null || true

  sshfs_options=(-o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3)
  [[ -n "$socket" ]] && sshfs_options+=(-o "ControlPath=${socket}")

  print -r -- "Mounting ${ssh_host}:${remote_dir}"
  print -r -- "  on ${workspace}"

  # macFUSE refuses the fork that sshfs performs to daemonize itself after
  # mounting, which leaves sshfs holding the terminal. Keeping sshfs in the
  # foreground with -f and detaching it from this shell avoids that fork.
  sshfs -f "${ssh_host}:${remote_dir}" "$workspace" "${sshfs_options[@]}" \
    </dev/null >"$logfile" 2>&1 &!

  while (( waited < AFWS_MOUNT_TIMEOUT_SECONDS )); do
    afws_mount_is_present "$workspace" && return 0
    afws_pause_seconds 1
    waited=$(( waited + 1 ))
  done

  afws_mount_is_present "$workspace" && return 0

  print -u2 -r -- "${AFWS_PROGRAM}: the mount did not appear within ${AFWS_MOUNT_TIMEOUT_SECONDS} seconds"
  if [[ -s "$logfile" ]]; then
    print -u2 -r -- "--- sshfs output ---"
    tail -n 20 "$logfile" >&2
  fi
  return 1
}

# --- extra local directories ----------------------------------------------
# A session works on the remote project, but the material it is working from is
# often local: papers, notes, a scratch analysis. AFWS_ADD_DIR names those so
# one session can read them and write its conclusions into the remote project,
# instead of the two living in separate sessions with separate histories.
# Colon-separated, like PATH.
# afws_extra_directories -> prints one absolute directory per line
afws_extra_directories() {
  local entry

  [[ -n "${AFWS_ADD_DIR-}" ]] || return 0

  for entry in ${(s.:.)AFWS_ADD_DIR}; do
    [[ -n "$entry" ]] || continue
    [[ "$entry" == /* ]] ||
      afws_die "AFWS_ADD_DIR must list absolute directories: ${entry}"
    [[ "$entry" != *[[:cntrl:]]* ]] ||
      afws_die "AFWS_ADD_DIR must not contain control characters"
    [[ -d "$entry" ]] ||
      afws_die "AFWS_ADD_DIR names a directory that does not exist: ${entry}"
    print -r -- "$entry"
  done
}

# --- workspace shape ------------------------------------------------------

# Mounting a home directory does not grant the agent anything its own account
# cannot already do, so this warns rather than refuses. What it costs is
# containment: the agent's own credentials and every other project sit inside
# the workspace, and a settings file there is read as project settings.
# afws_warn_about_home_workspace WORKSPACE AGENT
afws_warn_about_home_workspace() {
  local workspace="$1" agent="$2" settings
  local -a home_signals

  [[ -n "${AFWS_ALLOW_HOME_MOUNT-}" ]] && return 0
  [[ -d "$workspace" ]] || return 0

  home_signals=()
  [[ -e "${workspace}/.ssh" ]] && home_signals+=(.ssh)
  [[ -e "${workspace}/.claude" ]] && home_signals+=(.claude)
  [[ -e "${workspace}/.codex" ]] && home_signals+=(.codex)
  (( ${#home_signals} > 0 )) || return 0

  print -u2 -r -- ""
  print -u2 -r -- "${AFWS_PROGRAM}: this workspace looks like a home directory, not a project."
  print -u2 -r -- "  It contains: ${home_signals}"
  print -u2 -r -- "  Your account's permissions still apply, so nothing new is reachable, but"
  print -u2 -r -- "  everything in that home is now inside the agent's workspace: any SSH key,"
  print -u2 -r -- "  any stored credential, and every other project. A file read there also"
  print -u2 -r -- "  reaches the model."

  settings="${workspace}/.claude/settings.json"
  if [[ "$agent" == claude && -f "$settings" ]]; then
    print -u2 -r -- "  It also contains .claude/settings.json ($(wc -c <"$settings" | tr -d ' ') bytes),"
    print -u2 -r -- "  which Claude Code loads as this session's project settings, including any"
    print -u2 -r -- "  permission rules in it."
  fi

  print -u2 -r -- "  Consider starting on a project directory instead. Set AFWS_ALLOW_HOME_MOUNT=1"
  print -u2 -r -- "  to silence this."
  print -u2 -r -- ""

  return 0
}

# --- session registry -----------------------------------------------------
# The launchers set these before calling the functions below.
#   afws_agent afws_session_name afws_ssh_host afws_remote_dir
#   afws_local_workspace afws_mount_point afws_control_socket_path

# afws_write_session_record KIND PID BG_ID
afws_write_session_record() {
  local kind="$1" pid="$2" bg_id="$3"
  local record="${AFWS_SESSION_DIR}/${afws_session_name}.conf"

  mkdir -p "$AFWS_SESSION_DIR"
  chmod 700 "$AFWS_STATE_DIR" "$AFWS_SESSION_DIR" 2>/dev/null || true

  # The umask is set inside a subshell on purpose: setting it here would leak
  # into the agent this launcher starts, and every file the agent then created
  # in the remote project would be owner-only.
  (
  umask 077
  {
    print -r -- "session_name=${afws_session_name}"
    print -r -- "agent=${afws_agent}"
    print -r -- "kind=${kind}"
    print -r -- "pid=${pid}"
    print -r -- "bg_id=${bg_id}"
    print -r -- "ssh_host=${afws_ssh_host}"
    print -r -- "remote_dir=${afws_remote_dir}"
    print -r -- "local_workspace=${afws_local_workspace}"
    print -r -- "mount_point=${afws_mount_point}"
    print -r -- "started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    print -r -- "started_epoch=$(date +%s)"
  } > "$record"
  )
}

afws_remove_session_record() {
  rm -f "${AFWS_SESSION_DIR}/${afws_session_name}.conf" 2>/dev/null || true
}

# afws_read_record FILE -> sets afws_record_*
afws_read_record() {
  local record="$1" line key value

  afws_record_session_name=""
  afws_record_agent=""
  afws_record_kind=""
  afws_record_pid=""
  afws_record_bg_id=""
  afws_record_ssh_host=""
  afws_record_remote_dir=""
  afws_record_local_workspace=""
  afws_record_mount_point=""
  afws_record_started_at=""
  afws_record_started_epoch=""

  while IFS= read -r line; do
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      session_name) afws_record_session_name="$value" ;;
      agent) afws_record_agent="$value" ;;
      kind) afws_record_kind="$value" ;;
      pid) afws_record_pid="$value" ;;
      bg_id) afws_record_bg_id="$value" ;;
      ssh_host) afws_record_ssh_host="$value" ;;
      remote_dir) afws_record_remote_dir="$value" ;;
      local_workspace) afws_record_local_workspace="$value" ;;
      mount_point) afws_record_mount_point="$value" ;;
      started_at) afws_record_started_at="$value" ;;
      started_epoch) afws_record_started_epoch="$value" ;;
    esac
  done < "$record"

  [[ -n "$afws_record_session_name" ]]
}

# --- environment validation -----------------------------------------------
# AFWS_STATE_DIR decides where the registry, the logs and the shared-connection
# socket are written, and AFWS_MOUNT_BASE decides which mounts this tool
# considers its own and is therefore willing to unmount. A relative path would
# resolve against the working directory, which for claudefws is inside the
# remote mount, and too broad a mount base would widen the unmount guard.

afws_validate_absolute_directory() {
  local name="$1" value="$2"

  [[ "$value" == /* ]] || afws_die "${name} must be an absolute path: ${value}"
  [[ "$value" != *[[:cntrl:]]* ]] || afws_die "${name} must not contain control characters"
  [[ "$value" != "/" ]] || afws_die "${name} must not be the filesystem root"
}

afws_validate_environment() {
  afws_validate_absolute_directory AFWS_STATE_DIR "$AFWS_STATE_DIR"
  afws_validate_absolute_directory AFWS_MOUNT_BASE "$AFWS_MOUNT_BASE"

  # A mount base that contains the home directory would make the unmount guard
  # match paths this tool never created.
  if [[ "${HOME}/" == "${AFWS_MOUNT_BASE}/"* ]]; then
    afws_die "AFWS_MOUNT_BASE must not contain your home directory: ${AFWS_MOUNT_BASE}"
  fi

  # The mount table is read through a command so that tests can supply a fixed
  # table. Anything beyond that would be an arbitrary command run by every
  # launcher, so only the two shapes that are actually used are accepted.
  case "${AFWS_MOUNT_COMMAND}" in
    mount|"cat "*) ;;
    *) afws_die "AFWS_MOUNT_COMMAND must be 'mount' or 'cat FILE': ${AFWS_MOUNT_COMMAND}" ;;
  esac
}

afws_validate_environment

# Releases what this session is the last user of: its registry record, the
# mount when no other session is working inside it, and the shared SSH
# connection when no other session is on that host. A mount outside the mount
# base was not created here and is never unmounted.
# afws_release_session PEERS_COMMAND
afws_released=0

afws_release_session() {
  local peers="$1" mount_users=1 host_users=1

  # Reached from the EXIT trap and from the signal traps, so it must be safe to
  # call more than once.
  (( afws_released )) && return 0
  afws_released=1

  afws_remove_session_record

  [[ -n "${AFWS_KEEP_MOUNT-}" ]] && return 0
  [[ -x "$peers" ]] || return 0

  mount_users="$("$peers" --users-of-mount "$afws_mount_point" 2>/dev/null)" || mount_users=1
  host_users="$("$peers" --users-of-host "$afws_ssh_host" 2>/dev/null)" || host_users=1

  if [[ "$mount_users" == 0 && "$afws_mount_point" == "${AFWS_MOUNT_BASE}/"* ]]; then
    print -r -- "Unmounting ${afws_mount_point}"
    # A shell sitting inside the mount makes umount fail with "Resource busy",
    # and claudefws necessarily cd'd into it because claude has no -C.
    cd "$HOME" 2>/dev/null || cd / 2>/dev/null || true
    if ! umount "$afws_mount_point" 2>/dev/null; then
      print -u2 -r -- "${AFWS_PROGRAM}: could not unmount ${afws_mount_point}"
      print -u2 -r -- "  release it with: diskutil unmount force ${(q)afws_mount_point}"
    fi
  elif [[ "$mount_users" != 0 ]]; then
    print -r -- "Leaving ${afws_mount_point} mounted for ${mount_users} other session(s)."
  fi

  if [[ "$host_users" == 0 ]]; then
    afws_close_control_master "$afws_ssh_host" "$afws_control_socket_path"
  fi

  return 0
}
