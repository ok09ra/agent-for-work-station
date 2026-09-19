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
# AFWS_KEEP_CONTROL_MASTER gives up the first of those two bounds: a host that
# authenticates by password is otherwise asked again on every launch, and every
# afws-run once the connection is gone. Expiry is then the only bound left, so
# it is given a longer default; set AFWS_CONTROL_PERSIST to choose your own.
if [[ -n "${AFWS_KEEP_CONTROL_MASTER-}" ]]; then
  : ${AFWS_CONTROL_PERSIST:=28800}
else
  : ${AFWS_CONTROL_PERSIST:=600}
fi
# Quoted on purpose: the tilde must survive to the remote shell rather than
# being expanded to this Mac's home directory here.
: ${AFWS_REMOTE_LOCK_DIR:="~/.afws-locks"}

# Derived from AFWS_STATE_DIR rather than set directly.
AFWS_SESSION_DIR="${AFWS_STATE_DIR}/sessions"
AFWS_CONTROL_DIR="${AFWS_STATE_DIR}/control"
AFWS_LOG_DIR="${AFWS_STATE_DIR}/logs"
# Overridable: a slow link may need longer than this.
: ${AFWS_MOUNT_TIMEOUT_SECONDS:=30}
# How long a mount is given to answer its first read. A dead mount answers
# immediately -- with an error -- so this bounds only the hung and the merely
# cold, and a cold mount over a slow link is the common case of the two.
: ${AFWS_PROBE_TIMEOUT_SECONDS:=20}
# Not a setting: a Unix domain socket path cannot exceed 104 bytes on macOS, so
# there is nothing to tune here.
AFWS_SOCKET_PATH_LIMIT=100
# A record written just before the agent starts is not visible to the agent's
# own session listing yet, so young records are never pruned.
: ${AFWS_REGISTRATION_GRACE_SECONDS:=90}

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
# is merely hung would block forever, so the probe is given a deadline, and the
# outcome is signalled through a marker file rather than the job's exit status,
# which is not reliably retrievable once the job has been reaped.
#
# The three outcomes are kept apart in afws_probe_outcome, because they call for
# different advice. A mount that fails is dead and should be unmounted; a mount
# that says nothing within the deadline may be hung, but may equally be a cold
# mount on a slow link still setting up its first read, and telling someone to
# unmount that one destroys a working mount.
afws_directory_responds() {
  local target="$1" waited=0 probe_pid probe_marker probe_result result=1

  afws_probe_outcome=timeout

  probe_marker="$(mktemp "${TMPDIR:-/tmp}/afws-probe.XXXXXX")" || return 1

  (
    if ls -1 "$target" >/dev/null 2>&1; then
      print -r -- ok
    else
      print -r -- error
    fi >"$probe_marker"
  ) &
  probe_pid=$!

  while (( waited < AFWS_PROBE_TIMEOUT_SECONDS )); do
    kill -0 "$probe_pid" 2>/dev/null || break
    afws_pause_seconds 1
    waited=$(( waited + 1 ))
  done

  kill -9 "$probe_pid" 2>/dev/null || true
  probe_result="$(cat "$probe_marker" 2>/dev/null)"
  rm -f "$probe_marker"

  case "$probe_result" in
    ok)    afws_probe_outcome=ok; result=0 ;;
    error) afws_probe_outcome=error ;;
    *)     afws_probe_outcome=timeout ;;
  esac

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
  afws_stale_mount_reason=""

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
      afws_stale_mount_reason="$afws_probe_outcome"
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

# The mount answering with ENXIO used to be reported as the sshfs process having
# died, which is one way to get there but not the only one: a reconnect that
# cannot authenticate leaves the process running behind a mount that answers
# nothing else. So look before saying which happened.
afws_sshfs_pids_for() {
  pgrep -f "sshfs.*${1}" 2>/dev/null | tr '\n' ' '
}

# afws_stale_mount_message MOUNT_POINT [OUTCOME]
afws_stale_mount_message() {
  local unmount_advice="Unmount it, then start again:
  umount ${(q)1}
If that is refused, close anything still sitting in that directory, or force it:
  diskutil unmount force ${(q)1}"

  if [[ "${2-}" == timeout ]]; then
    print -r -- "the SSHFS mount at $1 did not answer within ${AFWS_PROBE_TIMEOUT_SECONDS} seconds
That is not proof that it is dead. A cold mount on a slow link can take longer
than this to answer its first read, and unmounting one that still works costs
you the mount. Check whether its sshfs process is still running:
  pgrep -fl sshfs
If it is, give the probe longer and start again:
  AFWS_PROBE_TIMEOUT_SECONDS=60 ${AFWS_PROGRAM} ...
If there is no such process, the mount is dead. ${unmount_advice}"
    return 0
  fi

  local pids
  pids="$(afws_sshfs_pids_for "$1")"
  pids="${pids%% }"

  if [[ -n "$pids" ]]; then
    print -r -- "the SSHFS mount at $1 is present but not responding
Every path inside it fails with ENXIO, yet its sshfs process is still running
(${pids}). That is a connection it could not re-establish, not a process that
died, so the mount will not recover on its own. ${unmount_advice}"
    return 0
  fi

  print -r -- "the SSHFS mount at $1 is present but not responding
Its sshfs process is gone, so every path inside it fails with ENXIO. ${unmount_advice}"
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

# ssh asks for a password on the controlling terminal, not on stdin, so a piped
# script still gets its prompt. Inside an agent session there is no terminal at
# all, and that is the case worth knowing about.
afws_has_controlling_terminal() {
  { : >/dev/tty } 2>/dev/null
}

# afws_control_ssh_options HOST
# Sets afws_ssh_control_options to the ssh options that reuse the connection a
# launcher authenticated, and afws_control_fallback to why there was nothing to
# reuse: empty when a connection was reused, "terminal" when ssh can still ask
# for a password itself, "batch" when there is nowhere to ask at all.
afws_control_ssh_options() {
  local ssh_host="$1" control_path

  afws_ssh_control_options=()
  afws_control_fallback=""
  afws_control_fallback_path=""
  [[ -n "${AFWS_NO_CONTROL_MASTER-}" ]] && return 0

  control_path="$(afws_resolve_control_path "$ssh_host")"
  if [[ -S "$control_path" ]]; then
    afws_ssh_control_options=(-S "$control_path")
    return 0
  fi

  afws_control_fallback_path="$control_path"

  # With no connection to reuse, ssh authenticates on its own and needs somewhere
  # to ask. Where it cannot ask -- no terminal, no askpass helper -- it tries an
  # askpass binary that macOS does not ship and reports that three times over,
  # which says nothing about what went wrong. BatchMode turns that into one
  # refusal, and key-based authentication still goes through untouched.
  if afws_has_controlling_terminal || [[ -n "${SSH_ASKPASS-}" ]]; then
    afws_control_fallback=terminal
    return 0
  fi

  afws_control_fallback=batch
  afws_ssh_control_options=(-o BatchMode=yes)

  return 0
}

# afws_report_control_fallback HOST SSH_EXIT_STATUS
# A fallback that worked needs no explaining: a key-authenticated host takes it
# on every call and gets where it was going. 255 is ssh's own failure, as
# opposed to the remote command's, and with nowhere to have asked for a password
# that is the failure worth explaining.
afws_report_control_fallback() {
  local ssh_host="$1" exit_status="$2"

  [[ "$afws_control_fallback" == batch ]] || return 0
  (( exit_status == 255 )) || return 0

  print -u2 -r -- "${AFWS_PROGRAM}: ssh failed. It said why above; this may be the reason."
  print -u2 -r -- "  There was no shared SSH connection to reuse at ${afws_control_fallback_path},"
  print -u2 -r -- "  and no terminal here, so a host that authenticates by password could not"
  print -u2 -r -- "  have been given one. Reopen the shared connection from the terminal you"
  print -u2 -r -- "  launched from, then try again:"
  print -u2 -r -- "    ssh -M -S ${(q)afws_control_fallback_path} -o ControlPersist=${AFWS_CONTROL_PERSIST} -f -N ${(q)ssh_host}"

  return 0
}

# --- mounting -------------------------------------------------------------

# afws_detached LOGFILE COMMAND [ARG ...]
# Runs the command with no controlling terminal, its output in LOGFILE. macOS
# ships no setsid, so perl's POSIX::setsid stands in; it has to fork first
# because setsid refuses to move a process that already leads its process
# group, which is exactly what a backgrounded job is. Without perl the command
# still runs -- detached from this shell, but sharing its terminal.
afws_detached() {
  local logfile="$1"
  shift

  if command -v perl >/dev/null 2>&1; then
    perl -e '
      use POSIX ();
      my $pid = fork();
      die "fork: $!\n" unless defined $pid;
      exit 0 if $pid;
      POSIX::setsid();
      exec { $ARGV[0] } @ARGV or die "exec: $!\n";
    ' -- "$@" </dev/null >"$logfile" 2>&1 &!
    return 0
  fi

  "$@" </dev/null >"$logfile" 2>&1 &!
  return 0
}


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
  # sshfs reconnects on its own after an interruption, and a reconnect that has
  # to authenticate has nobody to ask: this is a background mount. Left to
  # itself ssh would ask anyway, on the terminal the agent is drawing on.
  sshfs_options+=(-o BatchMode=yes)

  print -r -- "Mounting ${ssh_host}:${remote_dir}"
  print -r -- "  on ${workspace}"

  # macFUSE refuses the fork that sshfs performs to daemonize itself after
  # mounting, which leaves sshfs holding the terminal. Keeping sshfs in the
  # foreground with -f and detaching it from this shell avoids that fork.
  #
  # The redirections below are not enough on their own: ssh reads a password
  # from /dev/tty, which no redirection covers, so a controlling terminal is
  # something it can always reach around to. Giving sshfs a session of its own
  # takes that terminal away, and with it the ability to interfere with the
  # agent's. It also keeps sshfs out of the terminal's foreground process
  # group, so a Ctrl-C meant for the agent no longer lands on the mount.
  afws_detached "$logfile" sshfs -f "${ssh_host}:${remote_dir}" "$workspace" \
    "${sshfs_options[@]}"

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

# The same list, in the form each agent wants. Claude Code scopes its file tools
# to the working directory and takes extra directories with --add-dir; Codex
# reads outside its workspace already but writes only inside it, so the same
# directories become writable roots in its sandbox. Callers pass AFWS_ADD_DIR;
# which flag carries it is not their concern.
# afws_toml_string_list DIR... -> prints ["a","b"]
afws_toml_string_list() {
  local entry escaped list=""

  for entry in "$@"; do
    escaped="${entry//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    [[ -n "$list" ]] && list+=","
    list+="\"${escaped}\""
  done

  print -r -- "[${list}]"
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

  # .claude and .codex are normal in a project, alongside .git, so they say
  # nothing about this being a home directory. Only things that belong to a
  # login account do.
  home_signals=()
  [[ -e "${workspace}/.ssh" ]] && home_signals+=(.ssh)
  [[ -e "${workspace}/.zshrc" ]] && home_signals+=(.zshrc)
  [[ -e "${workspace}/.bashrc" ]] && home_signals+=(.bashrc)
  [[ -e "${workspace}/.bash_profile" ]] && home_signals+=(.bash_profile)
  [[ -e "${workspace}/.profile" ]] && home_signals+=(.profile)
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

# --- what a session is told --------------------------------------------------
# The facts and the rules that do not depend on which agent is running. Keeping
# them here means a change to them cannot reach one launcher and not the other.

afws_session_preamble() {
  print -r -- "This is an agent-for-work-station session backed by an SSHFS mount.
Session name: ${afws_session_name}
SSH config host: ${afws_ssh_host}
Local workspace: ${afws_local_workspace}
Remote working directory: ${afws_remote_dir}"
}

afws_shared_operating_rules() {
  print -r -- "- Read and edit files only within the current mounted workspace, and within any additional directory this session was given, unless the user explicitly expands scope.
- An additional directory is local to this Mac and is reference material: read from it, and write conclusions into the remote project rather than into it, unless the user says otherwise.
- Use local filesystem tools for inspection and editing; the workspace is the remote project itself, so every write lands on the remote host.
- Run Python, tests, builds, GPU jobs, and other commands that depend on the remote environment through: afws-run COMMAND ARG...
- To send a shell script through standard input, pipe it to: afws-run
- Do not install or update packages, alter shell startup files, or modify the remote system or user environment without explicit user approval.
- Show the remote command and its relevant stdout and stderr to the user.
- Ask before destructive operations or before starting expensive or long-running jobs.
- SSHFS is a network filesystem: prefer one remote command over many small local file operations when scanning large trees."
}

# The first multi-session rule is the same for both; the rest is not, because
# only Claude sessions can be addressed.
afws_shared_session_rules() {
  print -r -- "- Other sessions, of either agent, may be attached to this same workstation. Run 'afws-peers' to see which session is working on which SSH host and remote directory, and 'afws-peers --same' for the ones sharing this exact remote directory.
- Before using an exclusive remote resource (a GPU, a shared build or output directory, a dataset being rewritten, a single git worktree), claim it with: afws-lock acquire NAME
  Release it when finished with: afws-lock release NAME
  If the lock is held, 'afws-lock status NAME' names the holder; never take a held lock without the user saying so.
- Do not modify files another session is working on. Coordinate first."
}

# --- the parts of a launch that do not depend on the agent -----------------

# afws_resolve_session_name PREFIX HOST REMOTE_DIR PEERS DRY_RUN
# Honours AFWS_SESSION_NAME, otherwise allocates PREFIX-HOST-PROJECT-N.
afws_resolve_session_name() {
  local prefix="$1" ssh_host="$2" remote_dir="$3" peers="$4" dry_run="$5" base

  if (( ! dry_run )) && [[ -x "$peers" ]]; then
    "$peers" --prune --quiet 2>/dev/null || true
  fi

  if [[ -n "${AFWS_SESSION_NAME-}" ]]; then
    afws_validate_session_name "$AFWS_SESSION_NAME"
    print -r -- "$AFWS_SESSION_NAME"
    return 0
  fi

  base="${prefix}-$(afws_sanitize_component "$ssh_host")-$(afws_sanitize_component "${remote_dir:t}")"
  afws_allocate_session_name "$base" ||
    afws_die "could not allocate a session name; run afws-peers --prune"
}

# afws_open_session_connection HOST DRY_RUN
# Sets afws_control_socket_path, empty when the shared connection is turned off.
# It does not print the path: afws_open_control_master reports what it did on
# stdout, which a command substitution here would swallow.
afws_open_session_connection() {
  local ssh_host="$1" dry_run="$2"

  afws_control_socket_path=""
  [[ -n "${AFWS_NO_CONTROL_MASTER-}" ]] && return 0

  afws_control_socket_path="$(afws_control_socket "$ssh_host")"
  afws_check_socket_length "$afws_control_socket_path"

  if (( ! dry_run )); then
    afws_open_control_master "$ssh_host" "$afws_control_socket_path" ||
      afws_die "could not open an SSH connection to ${ssh_host}; run afws-doctor ${ssh_host}"
  fi

  return 0
}

# afws_establish_mount HOST REMOTE_DIR SOCKET_OR_EMPTY DRY_RUN LOG_NAME
# Sets afws_local_workspace and afws_mount_point, reusing a mount that already
# covers the directory, refusing one that no longer responds or that would hide
# another, and otherwise mounting.
afws_establish_mount() {
  local ssh_host="$1" remote_dir="$2" socket="$3" dry_run="$4" log_name="$5"

  if afws_find_existing_mount "$ssh_host" "$remote_dir"; then
    print -r -- "Reusing SSHFS mount: ${afws_mount_source}"
    return 0
  fi

  if [[ -n "$afws_stale_mount" ]]; then
    afws_die "$(afws_stale_mount_message "$afws_stale_mount" "$afws_stale_mount_reason")"
  fi

  afws_local_workspace="${AFWS_MOUNT_BASE}/${ssh_host}${remote_dir}"
  afws_mount_point="$afws_local_workspace"

  if afws_find_nested_mount "$afws_local_workspace"; then
    afws_die "refusing to mount ${ssh_host}:${remote_dir} on ${afws_local_workspace}
Another mount is already in use underneath it: ${afws_nested_mount}
That mount belongs to a session working on a subdirectory of this one. Start this
session on that deeper directory instead, or unmount it first. Run afws-peers to
see which session it belongs to."
  fi

  if (( dry_run )); then
    print -r -- "Would mount ${ssh_host}:${remote_dir}"
    print -r -- "  on ${afws_local_workspace}"
    [[ -n "$socket" ]] && print -r -- "  over a shared SSH connection at ${socket}"
    return 0
  fi

  afws_mount "$ssh_host" "$remote_dir" "$afws_local_workspace" "$socket" \
    "${AFWS_LOG_DIR}/${log_name}.sshfs.log" || exit 1
}

# afws_print_session_header TITLE PEERS DRY_RUN EXTRA_DIR...
afws_print_session_header() {
  local title="$1" peers="$2" dry_run="$3" extra peer_count
  shift 3

  print -r -- "$title"
  print -r -- "  session: ${afws_session_name}"
  print -r -- "  ssh:     ${afws_ssh_host}"
  print -r -- "  remote:  ${afws_remote_dir}"
  print -r -- "  local:   ${afws_local_workspace}"
  for extra in "$@"; do
    print -r -- "  also:    ${extra}"
  done

  [[ -x "$peers" ]] || return 0
  if (( dry_run )); then
    peer_count="$("$peers" --count --no-prune 2>/dev/null || print -r -- 0)"
  else
    peer_count="$("$peers" --count 2>/dev/null || print -r -- 0)"
  fi
  print -r -- "  peers:   ${peer_count}"
}

# What a session's own commands read to reach the same host without asking again.
afws_export_session_environment() {
  export AFWS_AGENT="$afws_agent"
  export AFWS_SESSION_NAME="$afws_session_name"
  export AFWS_SSH_HOST="$afws_ssh_host"
  export AFWS_REMOTE_DIR="$afws_remote_dir"
  export AFWS_LOCAL_WORKSPACE="$afws_local_workspace"

  [[ -S "$afws_control_socket_path" ]] && export AFWS_CONTROL_PATH="$afws_control_socket_path"

  return 0
}

# EXIT alone does not cover a signal: zsh runs it on a normal exit and on HUP,
# but not on TERM, so a 'kill' would otherwise leave the mount and the
# authenticated connection behind. afws_release_session is safe to call twice.
afws_install_release_traps() {
  # A global, not a local: a function defined here is global, so it would not
  # see a local of this one by the time a trap fires.
  afws_peers_command="$1"

  afws_release_for_traps() { afws_release_session "$afws_peers_command" }
  trap afws_release_for_traps EXIT
  trap 'afws_release_for_traps; exit 143' TERM
  trap 'afws_release_for_traps; exit 129' HUP
  # Ctrl+C belongs to the agent, which handles it itself; the launcher must stay
  # alive to clean up after it.
  trap '' INT
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

  if [[ "$host_users" == 0 && -n "$afws_control_socket_path" ]]; then
    if [[ -n "${AFWS_KEEP_CONTROL_MASTER-}" ]]; then
      print -r -- "Leaving the shared SSH connection to ${afws_ssh_host} open."
    else
      afws_close_control_master "$afws_ssh_host" "$afws_control_socket_path"
    fi
  fi

  return 0
}
