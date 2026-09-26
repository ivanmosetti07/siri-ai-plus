#!/bin/zsh
set -euo pipefail

install_update() {
  local source_app="$1" target_app="$2" expected_team="$3"
  local parent="${target_app:h}"
  local replacement="$parent/.Siri AI+ update-$$.app"
  local backup="$parent/.Siri AI+ previous-$$.app"
  [[ -d "$source_app" && -d "$target_app" && ! -e "$replacement" && ! -e "$backup" ]] || return 1
  /usr/bin/ditto "$source_app" "$replacement"
  /usr/bin/codesign --verify --deep --strict "$replacement"
  local identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$replacement/Contents/Info.plist")
  local team=$(/usr/bin/codesign -dv "$replacement" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')
  [[ "$identifier" == "com.ivanmosetti.siriaiplus" && "$team" == "$expected_team" ]] || return 1
  /bin/mv "$target_app" "$backup"
  if ! /bin/mv "$replacement" "$target_app"; then
    /bin/mv "$backup" "$target_app"
    return 1
  fi
  if ! /usr/bin/open -a "$target_app"; then
    /bin/mv "$target_app" "$replacement"
    /bin/mv "$backup" "$target_app"
    /usr/bin/open -a "$target_app" || true
    return 1
  fi
  /bin/rm -rf "$backup"
}

if [[ "${1:-}" == "--install" ]]; then
  install_update "$2" "$3" "$4"
  exit $?
fi

[[ $# == 4 ]] || exit 2
old_pid="$1"
source_app="$2"
target_app="$3"
expected_team="$4"

# Il binario corrente deve uscire prima che il bundle venga sostituito.
for (( attempt = 0; attempt < 120; attempt++ )); do
  if ! /bin/kill -0 "$old_pid" 2>/dev/null; then break; fi
  /bin/sleep 0.5
done
if /bin/kill -0 "$old_pid" 2>/dev/null; then exit 1; fi

if [[ -w "${target_app:h}" ]]; then
  install_update "$source_app" "$target_app" "$expected_team"
else
  /usr/bin/osascript \
    -e 'on run argv' \
    -e 'do shell script "/bin/zsh " & quoted form of (item 1 of argv) & " --install " & quoted form of (item 2 of argv) & " " & quoted form of (item 3 of argv) & " " & quoted form of (item 4 of argv) with administrator privileges' \
    -e 'end run' \
    "$0" "$source_app" "$target_app" "$expected_team" || /usr/bin/open -a "$target_app"
fi
