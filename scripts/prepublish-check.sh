#!/bin/zsh

set -eu

readonly REPOSITORY_ROOT="${0:A:h:h}"
cd "$REPOSITORY_ROOT"

findings=0

scan() {
  local label="$1"
  local pattern="$2"
  shift 2

  local matches
  matches="$(grep -EnI "$pattern" "$@" 2>/dev/null || true)"
  if [[ -n "$matches" ]]; then
    print -u2 -r -- "[FAIL] ${label}"
    print -u2 -r -- "$matches"
    findings=$((findings + 1))
  else
    print -r -- "[OK]   ${label}"
  fi
}

files=(
  README*.md
  .gitignore
  .gitattributes
  bin/claudefws
  bin/claudefws-run
  bin/claudefws-peers
  bin/claudefws-lock
  bin/claudefws-umount
  bin/ws-run
  bin/claudefws-shell
  docs/*.md
  examples/*
  scripts/install.sh
  scripts/doctor.sh
  scripts/test.sh
  scripts/prepublish-check.sh
)

for file in $files; do
  [[ -f "$file" ]] || {
    print -u2 -r -- "[FAIL] expected file is missing: ${file}"
    exit 1
  }
done

private_key_pattern='BEGIN [A-Z0-9 ]*PRIVATE '"KEY"
access_token_pattern='(github_'"pat_"'|gh[pousr]_|s'"k-"'[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16})'
mac_user_path_pattern='/Use'"rs/"'[A-Za-z0-9._-]+/'
linux_user_path_pattern='/ho'"me/"'[A-Za-z0-9._-]+/'

scan "no private-key material" "$private_key_pattern" $files
scan "no common access-token formats" "$access_token_pattern" $files
scan "no IPv4 address literals" '(^|[^0-9])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9]|$)' $files
scan "no macOS user-home absolute paths" "$mac_user_path_pattern" $files
scan "no Linux user-home absolute paths" "$linux_user_path_pattern" $files
scan "no likely assigned passwords" '(password|passwd)[[:space:]]*[:=][[:space:]]*[^[:space:]]+' $files
scan "no leftover names from the Codex port" 'code'"xfws" $files

if find . -path './.git' -prune -o -type l -print | grep -q .; then
  print -u2 -r -- "[FAIL] symbolic links are not allowed in the publishable tree"
  findings=$((findings + 1))
else
  print -r -- "[OK]   no symbolic links"
fi

not_executable=()
for file in bin/claudefws bin/claudefws-run bin/claudefws-peers bin/claudefws-lock \
  bin/claudefws-umount bin/ws-run bin/claudefws-shell \
  scripts/install.sh scripts/doctor.sh scripts/test.sh scripts/prepublish-check.sh; do
  [[ -x "$file" ]] || not_executable+=("$file")
done

if (( ${#not_executable} > 0 )); then
  print -u2 -r -- "[FAIL] these files are not executable: ${not_executable}"
  findings=$((findings + 1))
else
  print -r -- "[OK]   all commands and scripts are executable"
fi

if (( findings > 0 )); then
  print -u2 -r -- ""
  print -u2 -r -- "Pre-publish check failed with ${findings} finding(s)."
  exit 1
fi

print -r -- ""
print -r -- "Pre-publish check passed. Review git diff before publishing."
