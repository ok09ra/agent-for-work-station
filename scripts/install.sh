#!/bin/zsh

set -eu

readonly REPOSITORY_ROOT="${0:A:h:h}"
readonly INSTALL_DIRECTORY="${CLAUDEFWS_INSTALL_DIR:-${HOME}/.local/bin}"
readonly PROFILE_FILE="${HOME}/.zprofile"
readonly PROFILE_BEGIN="# >>> claudefws >>>"
readonly PROFILE_END="# <<< claudefws <<<"
configure_shell=1

usage() {
  print -r -- "Usage: ./scripts/install.sh [--no-shell-config]"
  print -r -- ""
  print -r -- "Environment:"
  print -r -- "  CLAUDEFWS_INSTALL_DIR  Installation directory (default: HOME/.local/bin)"
}

while (( $# > 0 )); do
  case "$1" in
    --no-shell-config)
      configure_shell=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      print -u2 -r -- "install.sh: unknown option: $1"
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  print -u2 -r -- "install.sh: claudefws supports macOS only"
  exit 1
fi

if [[ "$INSTALL_DIRECTORY" != /* ]]; then
  print -u2 -r -- "install.sh: CLAUDEFWS_INSTALL_DIR must be an absolute directory"
  exit 1
fi

if (( configure_shell )) && [[ "$INSTALL_DIRECTORY" != "${HOME}/.local/bin" ]]; then
  print -u2 -r -- "install.sh: automatic shell configuration is only available for the default install directory"
  print -u2 -r -- "Use --no-shell-config and add the selected directory to PATH yourself."
  exit 1
fi

mkdir -p "$INSTALL_DIRECTORY"
install -m 0755 "${REPOSITORY_ROOT}/bin/claudefws" "${INSTALL_DIRECTORY}/claudefws"
install -m 0755 "${REPOSITORY_ROOT}/bin/claudefws-run" "${INSTALL_DIRECTORY}/claudefws-run"
install -m 0755 "${REPOSITORY_ROOT}/bin/claudefws-peers" "${INSTALL_DIRECTORY}/claudefws-peers"
install -m 0755 "${REPOSITORY_ROOT}/bin/claudefws-lock" "${INSTALL_DIRECTORY}/claudefws-lock"
install -m 0755 "${REPOSITORY_ROOT}/bin/claudefws-umount" "${INSTALL_DIRECTORY}/claudefws-umount"
install -m 0755 "${REPOSITORY_ROOT}/bin/ws-run" "${INSTALL_DIRECTORY}/ws-run"
install -m 0755 "${REPOSITORY_ROOT}/bin/claudefws-shell" "${INSTALL_DIRECTORY}/claudefws-shell"
install -m 0755 "${REPOSITORY_ROOT}/scripts/doctor.sh" "${INSTALL_DIRECTORY}/claudefws-doctor"

if (( configure_shell )); then
  touch "$PROFILE_FILE"
  if ! grep -Fq "$PROFILE_BEGIN" "$PROFILE_FILE"; then
    {
      print -r -- ""
      print -r -- "$PROFILE_BEGIN"
      print -r -- 'export PATH="${HOME}/.local/bin:${PATH}"'
      print -r -- "$PROFILE_END"
    } >> "$PROFILE_FILE"
    print -r -- "Added claudefws to PATH in the zsh login profile."
  else
    print -r -- "The claudefws PATH block already exists; left it unchanged."
  fi
fi

print -r -- "Installed:"
for installed_command in claudefws claudefws-run claudefws-peers claudefws-lock \
  claudefws-umount claudefws-doctor ws-run claudefws-shell; do
  print -r -- "  ${INSTALL_DIRECTORY}/${installed_command}"
done
print -r -- ""
print -r -- "Open a new Terminal window, or run: exec zsh -l"
