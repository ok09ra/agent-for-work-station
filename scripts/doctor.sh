#!/bin/zsh

set -u

readonly STATE_DIR="${CLAUDEFWS_STATE_DIR:-${HOME}/.claudefws}"

failures=0

pass() {
  print -r -- "[OK]   $*"
}

fail() {
  print -r -- "[FAIL] $*"
  failures=$((failures + 1))
}

note() {
  print -r -- "[NOTE] $*"
}

check_command() {
  local command_name="$1"
  local install_hint="$2"

  if command -v "$command_name" >/dev/null 2>&1; then
    pass "${command_name} is available"
  else
    fail "${command_name} is missing — ${install_hint}"
  fi
}

print -r -- "claudefws doctor"

if [[ "$(uname -s)" == "Darwin" ]]; then
  pass "running on macOS"
else
  fail "this tool supports macOS only"
fi

check_command ssh "OpenSSH is included with macOS"
check_command sshfs "install the signed SSHFS package linked from the macFUSE project"
check_command claude "install Claude Code from the official Anthropic documentation"
check_command plutil "plutil is included with macOS; session status reporting needs it"
check_command claudefws-run "run this repository's installer and start a new login shell"
check_command claudefws-peers "run this repository's installer and start a new login shell"
check_command claudefws-lock "run this repository's installer and start a new login shell"
check_command claudefws-umount "run this repository's installer and start a new login shell"

if command -v claude >/dev/null 2>&1; then
  claude_version="$(claude --version 2>/dev/null)"
  if [[ -n "$claude_version" ]]; then
    pass "claude reports: ${claude_version}"
  else
    fail "claude is installed but did not report a version"
  fi

  if claude agents --json >/dev/null 2>&1; then
    pass "claude can list live sessions (needed for peer status)"
  else
    fail "claude agents --json failed; sign in with 'claude auth' and retry"
  fi
fi

if mkdir -p "${STATE_DIR}/sessions" 2>/dev/null; then
  chmod 700 "$STATE_DIR" "${STATE_DIR}/sessions" 2>/dev/null
  pass "session registry is writable: ${STATE_DIR}/sessions"
else
  fail "cannot create the session registry: ${STATE_DIR}/sessions"
fi

if (( $# > 1 )); then
  print -u2 -r -- "Usage: claudefws-doctor [SSH_CONFIG_HOST]"
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
print -r -- "All checks passed. Run: claudefws"
