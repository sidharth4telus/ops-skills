#!/usr/bin/env bash
# Install the ops-skills into your Claude Code skills directory.
#
#   ./install.sh           copy skills into ~/.claude/skills/
#   ./install.sh --link    symlink them instead (stay in sync with this repo)
#   ./install.sh --dir DIR install into DIR/skills instead of ~/.claude
#
set -euo pipefail

LINK=0
TARGET_BASE="${HOME}/.claude"

while [ $# -gt 0 ]; do
  case "$1" in
    --link) LINK=1; shift ;;
    --dir)  TARGET_BASE="${2:?--dir requires a path}"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/plugins/ops-skills/skills"
DEST="${TARGET_BASE}/skills"

[ -d "$SRC" ] || { echo "error: cannot find skills at $SRC" >&2; exit 1; }
mkdir -p "$DEST"

count=0
for skill in "$SRC"/*/; do
  name="$(basename "$skill")"
  out="${DEST}/${name}"
  rm -rf "$out"
  if [ "$LINK" -eq 1 ]; then
    ln -s "$(cd "$skill" && pwd)" "$out"
    echo "linked  $name -> $out"
  else
    cp -R "$skill" "$out"
    echo "copied  $name -> $out"
  fi
  count=$((count + 1))
done

echo ""
echo "Installed $count skills into $DEST"
echo "Start a new Claude Code session to pick them up."
