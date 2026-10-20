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
# Every path check resolves physical paths (links and `..` resolved the way the kernel resolves them),
# and the copy then writes to those resolved paths. Overlap is decided by folder identity (device and
# inode, `test -ef`) as well as by spelling, so one folder reached under two names, in another letter
# case on a case-insensitive file system or through a mount, still counts as one. Before any change,
# in the dry run too, it refuses when a source skill folder and the destination skill folder of the
# same name are one folder or one lies inside the other (the repository cloned as
# ~/.claude/skills/pr-reviewer, say), when the folder this script runs from lies inside a destination
# skill folder, and when the destination lies inside the source.
#
# Whatever the path checks miss, it only ever removes a folder that looks like a copy it made. One
# rule decides that, for the source and the destination alike: a real folder, nothing named .git in
# any letter case at any depth, and a SKILL.md whose frontmatter (the first `---` block) has the line
# `name: <skill>`, a trailing CR allowed. A source skill folder that fails it is refused before any
# change, so an install never writes a copy it would refuse to replace on the next run; an existing
# destination skill folder that fails it is refused before the plan is printed. The copy's folders
# are made writable by their owner, so the next run can remove it. With --yes it also refuses a
# leftover folder with the name of this run's stage or set-aside copy, which it never removes.
#
# Limits: the rule cannot tell a person's edited install from a fresh one, so local edits inside an
# installed skill folder are replaced, and a .git above the skill folder (a dotfiles repository at
# ~/.claude, say) is not looked for. A file system mounted inside a destination skill folder is not
# detected.
#
# EXIT CODES. 0 = done, or a dry run. 1 = refused (bad arguments, unknown harness, a source folder
# that is not a skill, holds a symbolic link or would not pass the rule, a path it cannot resolve, a
# source and destination that overlap, a destination that is not safe to replace), or an old copy
# that could not be removed in full after the new one was put in place (the message names where it
# is). It installs nothing it cannot check.
set -uo pipefail

die() { echo "install: $*" >&2; exit 1; }

HARNESS="" SCOPE=project SKILL=both TARGET="" SOURCE="" YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --harness|--scope|--skill|--target|--source)
      # Given last with no value, `shift 2` fails and the loop would spin forever.
      [ $# -ge 2 ] || die "$1 needs a value"
      case "$1" in
        --harness) HARNESS="$2" ;; --scope) SCOPE="$2" ;; --skill) SKILL="$2" ;;
        --target) TARGET="$2" ;; --source) SOURCE="$2" ;;
      esac
      shift 2 ;;
    --yes)     YES=1; shift ;;
    # The header is every comment line from line 2 down to the first line that is not one.
    -h|--help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0"; exit 0 ;;
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

# Physical path of a folder that may not exist yet: the nearest existing parent, resolved with
# `cd -P`, plus the missing rest as written. The path is made absolute first, so `cd` never consults
# CDPATH; clearing it as well is belt and braces, in case that first line ever changes. It fails
# closed: a `.` or `..` in the missing rest, a missing part that exists as a file or a dangling
# link, or a parent `cd -P` cannot enter makes it print nothing and return 1.
physical() {
  local p="$1" rest="" base r
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  while [ ! -d "$p" ]; do
    { [ -e "$p" ] || [ -L "$p" ]; } && return 1
    base="$(basename -- "$p")"
    case "$base" in .|..|"") return 1 ;; esac
    rest="/$base$rest"; p="$(dirname -- "$p")"
  done
  r="$(CDPATH='' cd -P -- "$p" 2>/dev/null && pwd -P)" || return 1
  case "$r" in /*) ;; *) return 1 ;; esac
  case "$r" in *$'\n'*) return 1 ;; esac
  r="${r%/}$rest"
  [ -n "$r" ] || return 1
  printf '%s\n' "$r"
}
# True when $1 is $2 or lies inside it. The trailing `/` keeps `/a/skills2` out of `/a/skills`.
within() { case "$1/" in "$2/"*) return 0 ;; esac; return 1; }
# True when the existing folder $2 is $1 or one of $1's parents by identity (`-ef`: same device and
# inode), whatever the spelling: on a case-insensitive file system `skills/Pr-Reviewer` and
# `skills/pr-reviewer` are one folder. $1 need not exist; the walk starts at its nearest existing parent.
same_or_inside() {
  local a="$1" b="$2"
  # dirname of a relative path settles on `.`, so the walk below would never end.
  case "$a" in /*) ;; *) return 1 ;; esac
  [ -d "$b" ] || return 1
  while :; do
    if [ -e "$a" ] && [ "$a" -ef "$b" ]; then return 0; fi
    case "$a" in /|"") return 1 ;; esac
    a="$(dirname -- "$a")"
  done
}
# $1 is $2 or lies inside it, by spelling or by identity.
overlaps() { within "$1" "$2" || same_or_inside "$1" "$2"; }
# The one rule for "folder $1 looks like an install of skill $2". It is applied to each source skill
# folder before any change and to an existing destination skill folder before it is replaced, so a
# copy the install made always passes it on the next run. The folder is a real folder, not a link;
# nothing in it is named .git in any letter case, at any depth; it holds a SKILL.md, not a link, whose
# first line is `---` and whose frontmatter, up to the next `---`, has the line `name: $2`. A trailing
# CR is ignored on every line, so a checkout with CRLF line endings passes. On failure it returns 1
# with the reason in WHY.
WHY=""
looks_like_install() {
  local d="$1" s="$2" gitp
  WHY=""
  if [ -L "$d" ]; then WHY="is a symbolic link"; return 1; fi
  [ -d "$d" ] || { WHY="is not a folder"; return 1; }
  gitp="$(find "$d" -iname .git -print -quit 2>/dev/null)" || { WHY="cannot be read in full"; return 1; }
  [ -z "$gitp" ] || { WHY="is or holds a repository ($gitp, a .git), which an install never is"; return 1; }
  if [ -L "$d/SKILL.md" ] || [ ! -f "$d/SKILL.md" ]; then WHY="does not look like an install of $s (no SKILL.md)"; return 1; fi
  awk -v want="name: $s" '
    { sub(/\r$/, "") }
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { closed = 1; exit }
    $0 == want { found = 1 }
    END { exit !(closed && found) }' "$d/SKILL.md" 2>/dev/null \
    || { WHY="does not look like an install of $s (no SKILL.md whose frontmatter has 'name: $s')"; return 1; }
}

SELF_P="$(physical "$(dirname -- "$0")")" || die "cannot resolve the folder install.sh runs from"
if [ -z "$SOURCE" ]; then SOURCE="$SELF_P/.agents/skills"; fi
SRC_P="$(physical "$SOURCE")" || die "cannot resolve the source $SOURCE to a physical path"
[ -d "$SRC_P" ] || die "$SOURCE is not a folder; --source must hold the skill folders"
SOURCE="$SRC_P"
DEST_P="$(physical "$DEST_ROOT")" || die "cannot resolve the destination $DEST_ROOT to a physical path (a '..' after a folder that does not exist, a file in the way, or a folder it cannot enter)"
[ "$DEST_P" != "/" ] || die "refusing an empty or root destination"
SKILLS=(); case "$SKILL" in both) SKILLS=(pr-reviewer pr-fixer) ;; *) SKILLS=("$SKILL") ;; esac
for s in "${SKILLS[@]}"; do
  [ -f "$SRC_P/$s/SKILL.md" ] || die "$SOURCE/$s/SKILL.md not found; --source must hold the skill folders"
  # `cp -R` copies a link as a link, at any depth, so the install would point into the source and
  # the template rewrite below would edit the source's own file. Any link under the skill folder,
  # the folder itself included, is refused.
  [ ! -L "$SRC_P/$s" ] || die "$SOURCE/$s is a symbolic link; give --source the real folder"
  link="$(find "$SRC_P/$s" -type l -print 2>/dev/null | head -n 1)"
  [ -z "$link" ] || die "$link is a symbolic link inside the source; replace it with the real files"
  # A source the destination rule would refuse installs once and then locks its own copy.
  looks_like_install "$SRC_P/$s" "$s" || die "the source $SOURCE/$s $WHY; an install of it could not be replaced later, so nothing is installed"
done
# Physical paths, so a destination that is a link to the source, such as
# `.claude/skills -> ../.agents/skills`, or `<link to a skill>/..`, is caught here instead of being
# replaced by a copy of itself.
{ [ "$SRC_P" = "$DEST_P" ] || { [ -d "$DEST_P" ] && [ "$SRC_P" -ef "$DEST_P" ]; }; } \
  && die "source and destination are the same folder ($SRC_P)"
overlaps "$DEST_P" "$SRC_P" && die "the destination $DEST_ROOT is inside the source $SOURCE"
for s in "${SKILLS[@]}"; do
  # The swap below moves $DEST_P/$s aside and removes it, so a source inside it would go too.
  overlaps "$SRC_P/$s" "$DEST_P/$s" && die "the source $SOURCE/$s is inside the destination skill folder $DEST_ROOT/$s, which the install would remove; run install.sh from a clone outside the skills folder"
  overlaps "$DEST_P/$s" "$SRC_P/$s" && die "the destination $DEST_ROOT/$s is inside the source $SOURCE/$s"
  # The same holds for the clone this script runs from, when --source names another folder.
  overlaps "$SELF_P" "$DEST_P/$s" && die "install.sh runs from inside the destination skill folder $DEST_ROOT/$s, which the install would remove; run it from a clone outside the skills folder"
done

# Refuse before the first removal, and before the plan below, so the plan never promises to replace a
# folder it then refuses: a destination that is a symbolic link, a name this script does not own, or
# a folder that does not pass looks_like_install stops the whole run, in the dry run too. This holds
# whatever the path checks above concluded, so no path bug can remove a repository or a person's own
# folder.
for s in "${SKILLS[@]}"; do
  dest="$DEST_P/$s"
  case "$dest" in */pr-reviewer|*/pr-fixer) ;; *) die "refusing to replace '$dest'" ;; esac
  if [ -L "$dest" ]; then die "$DEST_ROOT/$s is a symbolic link; remove it yourself first"; fi
  [ -e "$dest" ] || continue
  looks_like_install "$dest" "$s" || die "$DEST_ROOT/$s $WHY, so it is never replaced; move it away yourself first (and clone outside the skills folder)"
done

echo "install: skills  ${SKILLS[*]}"
echo "install: from    $SOURCE"
echo "install: to      $DEST_ROOT"
[ "$DEST_P" = "$DEST_ROOT" ] || echo "install: which is $DEST_P"
for s in "${SKILLS[@]}"; do
  if [ -e "$DEST_P/$s" ]; then echo "install: will REPLACE $DEST_ROOT/$s with the new copy"
  else echo "install: will create $DEST_ROOT/$s"; fi
done
[ -z "$REL" ] || [ "$REL" = ".agents/skills" ] || echo "install: will point templates/review-gate.yml at $REL/pr-reviewer/scripts/"

if [ "$YES" -ne 1 ]; then
  echo "install: dry run. Nothing changed. Run again with --yes to install."
  exit 0
fi

mkdir -p -- "$DEST_P" || die "cannot create $DEST_ROOT"
# The folders it just created must resolve to the path it checked.
[ "$(physical "$DEST_P")" = "$DEST_P" ] || die "$DEST_ROOT resolved to another folder after it was created; nothing installed"
# The stage and set-aside names must be free: a folder already there is not this run's to remove.
for s in "${SKILLS[@]}"; do
  for f in "$DEST_P/.$s.new.$$" "$DEST_P/.$s.old.$$"; do
    if [ -e "$f" ] || [ -L "$f" ]; then die "$f already exists and is not this run's; move it away, nothing installed"; fi
  done
done
LEFT=0
for s in "${SKILLS[@]}"; do
  dest="$DEST_P/$s"
  # Copy to a sibling first and move it into place, so a failed copy leaves the old install alone.
  stage="$DEST_P/.$s.new.$$"
  cp -R "$SRC_P/$s" "$stage" || { chmod -R u+w -- "$stage" 2>/dev/null; rm -rf -- "$stage"; die "copy of $s failed; the old install is untouched"; }
  # `cp -R` keeps a read-only folder read-only, and the next run could not remove the copy.
  find "$stage" -type d -exec chmod u+w {} + || { rm -rf -- "$stage"; die "could not make the copy of $s writable; the old install is untouched"; }
  old="$DEST_P/.$s.old.$$"
  if [ -e "$dest" ]; then mv -- "$dest" "$old" || { rm -rf -- "$stage"; die "could not set the old $s aside; it is untouched"; }; fi
  if ! mv -- "$stage" "$dest"; then
    rm -rf -- "$stage"
    if [ ! -e "$old" ]; then die "could not move the new $s into place; there was no old one"; fi
    mv -- "$old" "$dest" && die "could not move the new $s into place; the old one is back"
    die "could not move the new $s into place, nor the old one back; it is at $old"
  fi
  # The old copy passed looks_like_install; an install made before its folders were made writable
  # can still hold a read-only one, which rm -rf cannot empty.
  [ -e "$old" ] && find "$old" -type d ! -perm -u+w -exec chmod u+w {} + 2>/dev/null
  if [ -e "$old" ] && ! rm -rf -- "$old"; then
    echo "install: the old copy of $s could not be removed in full; it is at $old, remove it yourself" >&2
    LEFT=1
  fi
  if [ -n "$REL" ] && [ "$REL" != ".agents/skills" ] && [ -f "$dest/templates/review-gate.yml" ]; then
    tmp="$dest/templates/review-gate.yml.tmp"
    sed "s|\.agents/skills/pr-reviewer/scripts/|$REL/pr-reviewer/scripts/|g" "$dest/templates/review-gate.yml" >"$tmp" \
      && mv "$tmp" "$dest/templates/review-gate.yml"
  fi
  # The braces put the redirection of stderr around the `<`, so a missing VERSION prints no error.
  ver="$( { tr -d '[:space:]' <"$SRC_P/../../VERSION"; } 2>/dev/null)" || ver=""
  echo "install: installed $DEST_ROOT/$s (${ver:-unknown})"
done
echo "install: next, set REVIEW_MARKER_AUTHORS and run review-cycle.sh ensure-labels (README, 'Check the install')."
[ "$LEFT" = 0 ] || exit 1
