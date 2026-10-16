#!/usr/bin/env bash
#
# install.sh: copy pr-reviewer and pr-fixer into the folder a harness reads skills from.
#
# Usage: install.sh --harness <name> [--scope project|user] [--skill pr-reviewer|pr-fixer|both]
#                   [--target <dir>] [--source <dir>] [--yes]
#
# Without --yes it only prints what it would do and changes nothing. With --yes it replaces each
# installed skill folder: the new copy is made next to the old one and swapped in, so a failed copy
# leaves that skill's old install in place and a file the new release dropped does not stay behind.
# With --skill both the swap is per skill. Only the two folders named pr-reviewer and pr-fixer are
# ever replaced, and only inside the skills directory it resolved.
#
# --harness  claude-code | codex | copilot | gemini | cursor | opencode | amp | roo | cline |
#            kiro | windsurf | zed | junie. The table below mirrors the install table in README.md.
# --scope    project (default) installs under the current directory; user installs under $HOME.
# --target   a skills directory to use instead of the harness table (needs no --harness).
# --source   the folder that holds pr-reviewer/ and pr-fixer/ (default: .agents/skills next to
#            this script).
#
# After a project install into a folder other than .agents/skills it rewrites the script prefix in
# the installed copy of templates/review-gate.yml, so the gate calls the scripts where they now
# live. The template in the source tree is not touched.
#
# EXIT CODES. 0 = done, or a dry run. 1 = refused (bad arguments, unknown harness, a source folder
# that is not a skill, a destination that is not safe to replace). It installs nothing it cannot
# check.
set -uo pipefail

die() { echo "install: $*" >&2; exit 1; }

HARNESS="" SCOPE=project SKILL=both TARGET="" SOURCE="" YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --harness) HARNESS="${2:-}"; shift 2 ;;
    --scope)   SCOPE="${2:-}"; shift 2 ;;
    --skill)   SKILL="${2:-}"; shift 2 ;;
    --target)  TARGET="${2:-}"; shift 2 ;;
    --source)  SOURCE="${2:-}"; shift 2 ;;
    --yes)     YES=1; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) die "unknown argument '$1' (try --help)" ;;
  esac
done

case "$SCOPE" in project|user) ;; *) die "--scope must be project or user" ;; esac
case "$SKILL" in pr-reviewer|pr-fixer|both) ;; *) die "--skill must be pr-reviewer, pr-fixer or both" ;; esac

# project path | user path, per harness. Dated 2026-10-14 in README.md; confirm against vendor docs.
paths_for() {
  case "$1" in
    claude-code) echo ".claude/skills|.claude/skills" ;;
    codex)       echo ".agents/skills|.agents/skills" ;;
    copilot)     echo ".github/skills|.copilot/skills" ;;
    gemini)      echo ".gemini/skills|.gemini/skills" ;;
    cursor)      echo ".cursor/skills|.claude/skills" ;;
    opencode)    echo ".opencode/skills|.config/opencode/skills" ;;
    amp)         echo ".agents/skills|.config/agents/skills" ;;
    roo)         echo ".roo/skills|.roo/skills" ;;
    cline)       echo ".cline/skills|.cline/skills" ;;
    kiro)        echo ".kiro/skills|.kiro/skills" ;;
    windsurf)    echo ".windsurf/skills|.codeium/windsurf/skills" ;;
    zed)         echo ".agents/skills|.agents/skills" ;;
    junie)       echo ".junie/skills|.junie/skills" ;;
    aider)       return 2 ;;
    *)           return 1 ;;
  esac
}

REL=""
if [ -n "$TARGET" ]; then
  DEST_ROOT="$TARGET"
else
  [ -n "$HARNESS" ] || die "give --harness <name> or --target <dir>"
  entry="$(paths_for "$HARNESS")"; rc=$?
  [ "$rc" -ne 2 ] || die "aider has no skills feature; load SKILL.md with --read instead"
  [ "$rc" -eq 0 ] || die "unknown harness '$HARNESS'"
  if [ "$SCOPE" = project ]; then REL="${entry%%|*}"; DEST_ROOT="$PWD/$REL"; else DEST_ROOT="$HOME/${entry##*|}"; fi
fi
[ -n "$DEST_ROOT" ] && [ "$DEST_ROOT" != "/" ] || die "refusing an empty or root destination"

if [ -z "$SOURCE" ]; then SOURCE="$(cd "$(dirname "$0")" && pwd)/.agents/skills"; fi
SKILLS=(); case "$SKILL" in both) SKILLS=(pr-reviewer pr-fixer) ;; *) SKILLS=("$SKILL") ;; esac
for s in "${SKILLS[@]}"; do
  [ -f "$SOURCE/$s/SKILL.md" ] || die "$SOURCE/$s/SKILL.md not found; --source must hold the skill folders"
done
if [ -d "$DEST_ROOT" ] && [ "$(cd "$SOURCE" && pwd)" = "$(cd "$DEST_ROOT" && pwd)" ]; then
  die "source and destination are the same folder"
fi

echo "install: skills  ${SKILLS[*]}"
echo "install: from    $SOURCE"
echo "install: to      $DEST_ROOT"
for s in "${SKILLS[@]}"; do
  if [ -e "$DEST_ROOT/$s" ]; then echo "install: will REPLACE $DEST_ROOT/$s with the new copy"
  else echo "install: will create $DEST_ROOT/$s"; fi
done
[ -z "$REL" ] || [ "$REL" = ".agents/skills" ] || echo "install: will point templates/review-gate.yml at $REL/pr-reviewer/scripts/"

# Refuse before the first removal: a destination that is a symbolic link, or a name this script
# does not own, stops the whole run, in the dry run too.
for s in "${SKILLS[@]}"; do
  dest="$DEST_ROOT/$s"
  case "$dest" in */pr-reviewer|*/pr-fixer) ;; *) die "refusing to replace '$dest'" ;; esac
  if [ -L "$dest" ]; then die "$dest is a symbolic link; remove it yourself first"; fi
done

if [ "$YES" -ne 1 ]; then
  echo "install: dry run. Nothing changed. Run again with --yes to install."
  exit 0
fi

mkdir -p "$DEST_ROOT" || die "cannot create $DEST_ROOT"
for s in "${SKILLS[@]}"; do
  dest="$DEST_ROOT/$s"
  # Copy to a sibling first and move it into place, so a failed copy leaves the old install alone.
  stage="$DEST_ROOT/.$s.new.$$"
  rm -rf -- "$stage"
  cp -R "$SOURCE/$s" "$stage" || { rm -rf -- "$stage"; die "copy of $s failed; the old install is untouched"; }
  old="$DEST_ROOT/.$s.old.$$"
  rm -rf -- "$old"
  if [ -e "$dest" ]; then mv "$dest" "$old" || { rm -rf -- "$stage"; die "could not set the old $s aside; it is untouched"; }; fi
  mv "$stage" "$dest" || { [ ! -e "$old" ] || mv "$old" "$dest"; rm -rf -- "$stage"; die "could not move the new $s into place; the old one is back"; }
  rm -rf -- "$old"
  if [ -n "$REL" ] && [ "$REL" != ".agents/skills" ] && [ -f "$dest/templates/review-gate.yml" ]; then
    tmp="$dest/templates/review-gate.yml.tmp"
    sed "s|\.agents/skills/pr-reviewer/scripts/|$REL/pr-reviewer/scripts/|g" "$dest/templates/review-gate.yml" >"$tmp" \
      && mv "$tmp" "$dest/templates/review-gate.yml"
  fi
  echo "install: installed $dest ($(tr -d '[:space:]' <"$SOURCE/../../VERSION" 2>/dev/null || echo unknown))"
done
echo "install: next, set REVIEW_MARKER_AUTHORS and run review-cycle.sh ensure-labels (README, 'Check the install')."
