#!/bin/bash

# Omarchy Zen web font.
#
# Applies the Omarchy system font (or an explicit family) to Zen's browser
# chrome AND to web page content. Chrome is styled through a generated
# chrome/custom-zen-font.css (imported by zen-auto-style-chrome.css); content is
# forced through prefs in the profile's user.js. Both are kept in their own
# managed blocks so the rice's ZEN AUTO STYLE block is never touched.
#
# Enable it by creating ~/.config/omarchy-zen-font.conf whose first non-comment
# line is a family name, or `system` for the Omarchy font. Set ZEN_WEB_FONT to
# override. Absent config (or `off`) disables the feature and cleans up.
#
# Usage: zen-font.sh [apply|disable|status] [--profile DIR] [--quiet]
#
# Environment:
#   ZEN_WEB_FONT        Family name, or `system`, or `off`.
#   OMARCHY_ZEN_FONT_CONF  Config path (default: ~/.config/omarchy-zen-font.conf).
#   ZEN_FONT_CONTENT    Set to 0 to theme chrome only (skip the user.js prefs).
#   ZEN_PROFILE         Absolute profile path (skips discovery).
#   ZEN_CONFIG_DIR      Zen config root (default: ~/.zen if present, else ~/.config/zen).

set -euo pipefail

font_conf="${OMARCHY_ZEN_FONT_CONF:-$HOME/.config/omarchy-zen-font.conf}"
font_begin="// BEGIN OMARCHY ZEN FONT"
font_end="// END OMARCHY ZEN FONT"
state_dir="$HOME/.local/state/zen-auto-style"

action="apply"
quiet=0
profile_override=""

usage() {
  cat >&2 <<'USAGE'
Usage: zen-font.sh [apply|disable|status] [--profile DIR] [--quiet]

  apply    Write the chrome CSS + user.js prefs for the resolved font.
  disable  Remove the generated CSS and the managed user.js block.
  status   Exit 0 when the profile matches the config, 1 otherwise.
USAGE
}

while (( $# > 0 )); do
  case "$1" in
    apply|disable|status) action="$1" ;;
    --profile) profile_override="${2:-}"; shift ;;
    --quiet) quiet=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'zen-font: unknown argument: %s\n' "$1" >&2; usage; exit 2 ;;
  esac
  shift
done

log() { (( quiet )) || printf '%s\n' "$*"; }
warn() { printf 'zen-font: %s\n' "$*" >&2; }

system_font() {
  local family=""
  if command -v omarchy >/dev/null 2>&1; then
    family="$(omarchy font current 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z $family ]] && command -v fc-match >/dev/null 2>&1; then
    family="$(fc-match monospace -f '%{family}\n' 2>/dev/null | head -n1 | cut -d, -f1 || true)"
  fi
  printf '%s\n' "$family"
}

# Resolves the config into enabled (0/1) + font_family + content_enabled.
font_enabled=0
font_family=""
content_enabled=1
if [[ ${ZEN_FONT_CONTENT:-1} == 0 ]]; then
  content_enabled=0
fi
if [[ -n ${ZEN_WEB_FONT:-} ]]; then
  font_enabled=1
  font_family="$ZEN_WEB_FONT"
elif [[ -f $font_conf ]]; then
  font_enabled=1
  font_family="$(grep -vE '^[[:space:]]*(#|$)' "$font_conf" | head -n1 | sed 's/[[:space:]]*$//' || true)"
fi
case "$font_family" in
  off|OFF) font_enabled=0 ;;
  ""|system) (( font_enabled )) && font_family="$(system_font)" ;;
esac

if (( font_enabled )); then
  if [[ -z $font_family ]]; then
    warn "no font family resolved; disabling"
    font_enabled=0
  elif [[ $font_family == *\"* || $font_family == *$'\n'* ]]; then
    warn "unsupported characters in font family: $font_family"
    exit 1
  fi
fi

find_zen_profile() {
  local zen_root installs profiles path

  if [[ -n ${ZEN_PROFILE:-} ]]; then
    [[ -d $ZEN_PROFILE ]] && printf '%s\n' "$ZEN_PROFILE"
    return 0
  fi

  if [[ -n ${ZEN_CONFIG_DIR:-} ]]; then
    zen_root="$ZEN_CONFIG_DIR"
  elif [[ -d $HOME/.zen ]]; then
    zen_root="$HOME/.zen"
  else
    zen_root="$HOME/.config/zen"
  fi

  installs="$zen_root/installs.ini"
  profiles="$zen_root/profiles.ini"

  if [[ -f $installs ]]; then
    path="$(awk -F= '$1 == "Default" { v = substr($0, index($0, "=") + 1); if (v != "") { print v; exit } }' "$installs")"
    if [[ -n $path && -d $zen_root/$path ]]; then
      printf '%s\n' "$zen_root/$path"
      return 0
    fi
  fi

  if [[ -f $profiles ]]; then
    path="$(awk -F= '$1 == "Path" { p = substr($0, index($0, "=") + 1) } $1 == "Default" && $2 == "1" && p != "" { print p; exit }' "$profiles")"
    if [[ -n $path && -d $zen_root/$path ]]; then
      printf '%s\n' "$zen_root/$path"
      return 0
    fi
  fi

  if [[ -d $zen_root ]]; then
    while IFS= read -r dir; do
      printf '%s\n' "$dir"
      return 0
    done < <(find "$zen_root" -maxdepth 2 -name prefs.js -printf '%h\n' 2>/dev/null)
  fi

  return 1
}

profile="${profile_override:-}"
if [[ -z $profile ]]; then
  profile="$(find_zen_profile || true)"
fi
if [[ -z $profile || ! -d $profile ]]; then
  warn "could not find the Zen profile; start Zen once or set ZEN_PROFILE"
  exit 1
fi

chrome_dir="$profile/chrome"
font_css="$chrome_dir/custom-zen-font.css"
userjs="$profile/user.js"

build_css() {
  printf ':root, :root * {\n  font-family: "%s", monospace !important;\n}\n' "$font_family"
}

build_userjs() {
  cat <<EOF
user_pref("browser.display.use_document_fonts", 0);
user_pref("font.default.x-western", "monospace");
user_pref("font.name.monospace.x-western", "$font_family");
user_pref("font.name.sans-serif.x-western", "$font_family");
user_pref("font.name.serif.x-western", "$font_family");
user_pref("font.name.monospace.x-unicode", "$font_family");
user_pref("font.name.sans-serif.x-unicode", "$font_family");
user_pref("font.name.serif.x-unicode", "$font_family");
EOF
}

strip_font_block() {
  awk -v b="$font_begin" -v e="$font_end" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip { print }
  ' "$1"
}

# Emits the desired user.js: the font block (when content is on) followed by the
# file with any previous font block removed, so the rice's own block survives.
build_target_userjs() {
  local body=""
  if [[ -f $userjs ]]; then
    body="$(strip_font_block "$userjs")"
  fi
  if (( font_enabled )) && (( content_enabled )); then
    printf '%s\n%s\n%s\n' "$font_begin" "$(build_userjs)" "$font_end"
  fi
  [[ -n $body ]] && printf '%s\n' "$body"
  return 0
}

backup_file() {
  [[ -e $1 || -L $1 ]] || return 0
  local backup_root="$state_dir/font-backups"
  mkdir -p "$backup_root"
  cp -a "$1" "$backup_root/$(basename "$1").$(date +%Y%m%d-%H%M%S-%N)"
}

apply_font() {
  mkdir -p "$chrome_dir"
  local tmp changed_css=0 changed_js=0

  tmp="$(mktemp)"
  if (( font_enabled )); then
    build_css >"$tmp"
    if [[ -f $font_css ]] && cmp -s "$tmp" "$font_css"; then
      :
    else
      backup_file "$font_css"
      install -m 644 "$tmp" "$font_css"
      changed_css=1
    fi
  elif [[ -e $font_css ]]; then
    rm -f "$font_css"
    changed_css=1
  fi
  rm -f "$tmp"

  tmp="$(mktemp)"
  build_target_userjs >"$tmp"
  if [[ -f $userjs ]] && cmp -s "$tmp" "$userjs"; then
    :
  elif [[ ! -f $userjs && ! -s $tmp ]]; then
    :
  else
    backup_file "$userjs"
    install -m 600 "$tmp" "$userjs"
    changed_js=1
  fi
  rm -f "$tmp"

  if (( font_enabled )); then
    if (( changed_css || changed_js )); then
      log "Zen font applied: $font_family (chrome $([[ $changed_css == 1 ]] && echo yes || echo no), content $([[ $changed_js == 1 ]] && echo yes || echo no))."
    else
      log "Zen font already in sync: $font_family"
    fi
  else
    log "Zen font disabled."
  fi
}

status_font() {
  local tmp in_sync=0

  if (( font_enabled )); then
    tmp="$(mktemp)"; build_css >"$tmp"
    [[ -f $font_css ]] && cmp -s "$tmp" "$font_css" || in_sync=1
    rm -f "$tmp"

    tmp="$(mktemp)"; build_target_userjs >"$tmp"
    [[ -f $userjs ]] && cmp -s "$tmp" "$userjs" || in_sync=1
    rm -f "$tmp"
  else
    [[ -e $font_css ]] && in_sync=1
    [[ -f $userjs ]] && grep -Fqx "$font_begin" "$userjs" && in_sync=1
  fi

  if (( in_sync == 0 )); then
    log "Zen font in sync: ${font_family:-disabled}"
    return 0
  fi
  log "Zen font out of sync: ${font_family:-disabled}"
  return 1
}

case $action in
  apply) apply_font ;;
  disable) font_enabled=0; apply_font ;;
  status) status_font ;;
esac
