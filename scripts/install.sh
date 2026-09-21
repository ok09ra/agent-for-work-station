#!/bin/zsh

set -eu

readonly REPOSITORY_ROOT="${0:A:h:h}"
readonly INSTALL_DIRECTORY="${AFWS_INSTALL_DIR:-${HOME}/.local/bin}"
readonly LIBRARY_DIRECTORY="${INSTALL_DIRECTORY:h}/lib"
readonly PROFILE_FILE="${HOME}/.zprofile"
readonly PROFILE_BEGIN="# >>> agent-for-work-station >>>"
readonly PROFILE_END="# <<< agent-for-work-station <<<"
configure_shell=1

readonly COMMANDS=(claudefws codexfws afws-run afws-peers afws-lock afws-remount afws-umount
  afws-shell afws-doctor)

usage() {
  print -r -- "Usage: ./scripts/install.sh [--no-shell-config]"
  print -r -- ""
  print -r -- "Environment:"
  print -r -- "  AFWS_INSTALL_DIR  Installation directory (default: HOME/.local/bin)"
  print -r -- ""
  print -r -- "The shared library is installed next to it, in ../lib, which is where every"
  print -r -- "command looks for it."
}

while (( $# > 0 )); do
  case "$1" in
    --no-shell-config) configure_shell=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      print -u2 -r -- "install.sh: unknown option: $1"
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  print -u2 -r -- "install.sh: agent-for-work-station supports macOS only"
  exit 1
fi

if [[ "$INSTALL_DIRECTORY" != /* ]]; then
  print -u2 -r -- "install.sh: AFWS_INSTALL_DIR must be an absolute directory"
  exit 1
fi

if (( configure_shell )) && [[ "$INSTALL_DIRECTORY" != "${HOME}/.local/bin" ]]; then
  print -u2 -r -- "install.sh: automatic shell configuration is only available for the default install directory"
  print -u2 -r -- "Use --no-shell-config and add the selected directory to PATH yourself."
  exit 1
fi

mkdir -p "$INSTALL_DIRECTORY" "$LIBRARY_DIRECTORY"
# Every command sources the library, so it must not be group- or world-writable
# whatever umask happens to be in effect.
chmod 755 "$LIBRARY_DIRECTORY"

install -m 0644 "${REPOSITORY_ROOT}/lib/afws-common.zsh" "${LIBRARY_DIRECTORY}/afws-common.zsh"
for command_name in $COMMANDS; do
  install -m 0755 "${REPOSITORY_ROOT}/bin/${command_name}" "${INSTALL_DIRECTORY}/${command_name}"
done

if (( configure_shell )); then
  touch "$PROFILE_FILE"
  if ! grep -Fq "$PROFILE_BEGIN" "$PROFILE_FILE"; then
    {
      print -r -- ""
      print -r -- "$PROFILE_BEGIN"
      print -r -- 'export PATH="${HOME}/.local/bin:${PATH}"'
      print -r -- "$PROFILE_END"
    } >> "$PROFILE_FILE"
    print -r -- "Added the install directory to PATH in the zsh login profile."
  else
    print -r -- "The PATH block already exists; left it unchanged."
  fi
fi

print -r -- "Installed:"
for command_name in $COMMANDS; do
  print -r -- "  ${INSTALL_DIRECTORY}/${command_name}"
done
print -r -- "  ${LIBRARY_DIRECTORY}/afws-common.zsh"

# The separate claudefws / codexfws installations this replaces are left alone:
# removing another tool's files is the user's decision, not the installer's.
typeset -a superseded
superseded=()
for stale in claudefws-run claudefws-peers claudefws-lock claudefws-umount \
  claudefws-doctor claudefws-shell ws-run codexfws-run codexfws-doctor; do
  [[ -e "${INSTALL_DIRECTORY}/${stale}" ]] && superseded+=("${INSTALL_DIRECTORY}/${stale}")
done
for stale in "${HOME}/.claudefws" "${HOME}/.codexfws" \
  "${HOME}/claudefws-mounts" "${HOME}/codexfws-mounts"; do
  [[ -e "$stale" ]] && superseded+=("$stale")
done

if (( ${#superseded} > 0 )); then
  print -r -- ""
  print -r -- "These belong to the separate claudefws / codexfws installations that this"
  print -r -- "replaces. Nothing here deletes them. Release any mount first, then remove:"
  for stale in "${superseded[@]}"; do
    print -r -- "  ${stale}"
  done
  print -r -- ""
  print -r -- "Check for mounts still in use with: mount | grep macfuse"
fi

print -r -- ""
print -r -- "Open a new Terminal window, or run: exec zsh -l"
