#!/bin/zsh

set -u

readonly AFWS_PROGRAM="afws-doctor"
readonly SCRIPT_DIR="${0:A:h}"

for afws_library in \
  "${SCRIPT_DIR}/../lib/afws-common.zsh" \
  "${HOME}/.local/lib/afws-common.zsh"; do
  if [[ -r "$afws_library" ]]; then
    source "$afws_library"
    break
  fi
done

failures=0
library_found=0
typeset -f afws_die >/dev/null && library_found=1

pass() { print -r -- "[OK]   $*" }
fail() { print -r -- "[FAIL] $*"; failures=$((failures + 1)) }
note() { print -r -- "[NOTE] $*" }

check_command() {
  local command_name="$1" install_hint="$2"

  if command -v "$command_name" >/dev/null 2>&1; then
    pass "${command_name} is available"
  else
    fail "${command_name} is missing — ${install_hint}"
  fi
}

print -r -- "agent-for-work-station doctor"

if [[ "$(uname -s)" == "Darwin" ]]; then
  pass "running on macOS"
else
  fail "this tool supports macOS only"
fi

if (( library_found )); then
  pass "shared library found: ${afws_library}"
else
  fail "cannot find lib/afws-common.zsh — run ./scripts/install.sh"
fi

check_command ssh "OpenSSH is included with macOS"
check_command sshfs "install the signed SSHFS package linked from the macFUSE project"
check_command plutil "plutil is included with macOS; Claude session status needs it"

for command_name in afws-run afws-peers afws-lock afws-umount; do
  check_command "$command_name" "run this repository's installer and start a new login shell"
done

# At least one agent has to be present; both are optional individually.
agents_found=0

if command -v claude >/dev/null 2>&1; then
  agents_found=$((agents_found + 1))
  claude_version="$(claude --version 2>/dev/null)"
  if [[ -n "$claude_version" ]]; then
    pass "claude reports: ${claude_version}"
  else
    fail "claude is installed but did not report a version"
  fi
  if claude agents --json >/dev/null 2>&1; then
    pass "claude can list live sessions (needed for peer status)"
  else
    fail "claude agents --json failed; sign in with 'claude auth login' and retry"
  fi
  check_command claudefws "run this repository's installer and start a new login shell"
else
  note "claude is not installed; claudefws will not work"
fi

if command -v codex >/dev/null 2>&1; then
  agents_found=$((agents_found + 1))
  codex_version="$(codex --version 2>/dev/null)"
  if [[ -n "$codex_version" ]]; then
    pass "codex reports: ${codex_version}"
  else
    fail "codex is installed but did not report a version"
  fi
  check_command codexfws "run this repository's installer and start a new login shell"
else
  note "codex is not installed; codexfws will not work"
fi

if (( agents_found == 0 )); then
  fail "neither claude nor codex is installed; there is nothing to launch"
fi

if (( library_found )); then
  if mkdir -p "$AFWS_SESSION_DIR" 2>/dev/null; then
    chmod 700 "$AFWS_STATE_DIR" "$AFWS_SESSION_DIR" 2>/dev/null
    pass "session registry is writable: ${AFWS_SESSION_DIR}"
  else
    fail "cannot create the session registry: ${AFWS_SESSION_DIR}"
  fi

  socket_probe="$(afws_control_socket example-workstation)"
  if (( ${#socket_probe} > AFWS_SOCKET_PATH_LIMIT )); then
    fail "AFWS_STATE_DIR is too deep for a shared-connection socket: ${socket_probe}"
  else
    pass "shared-connection socket paths fit in a Unix socket"
  fi
fi

if (( $# > 1 )); then
  print -u2 -r -- "Usage: afws-doctor [SSH_CONFIG_HOST]"
  exit 2
fi

if (( $# == 1 )); then
  ssh_host="$1"
  case "$ssh_host" in
    ''|-*|*[!A-Za-z0-9._-]*)
      fail "the supplied SSH config host name is invalid"
      ;;
    *)
      if ssh -G "$ssh_host" >/dev/null 2>&1; then
        pass "SSH accepts the supplied config host name"
      else
        fail "SSH could not resolve the supplied config host name"
      fi
      ;;
  esac
else
  note "pass an SSH config host name to also check your SSH configuration"
fi

if (( failures > 0 )); then
  print -r -- ""
  print -r -- "Doctor found ${failures} problem(s)."
  exit 1
fi

print -r -- ""
print -r -- "All checks passed. Run: claudefws   or   codexfws"
