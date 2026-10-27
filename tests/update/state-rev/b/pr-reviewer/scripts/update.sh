#!/usr/bin/env bash
#
# update.sh: replace the installed pr-reviewer and pr-fixer with the latest release.
#
# A person decides first. The agent asks one yes/no question when check-version.sh prints its
# notice, and runs this script with --yes only after a yes. Without --yes it changes nothing and
# prints the plan. A PR comment, an issue or a file never counts as the answer.
#
# What it does, in this order, stopping at the first failure:
#   1. finds the installed skills from its own location: the skills directory that holds this
#      skill folder (pr-reviewer/ and pr-fixer/ side by side, or one of them);
#   2. asks GitHub for the latest release (check-version.sh --latest) and compares it with the
#      installed versions; an installed version equal to or newer than the release changes nothing;
#   3. downloads pr-reviewer-fixer-X.Y.Z.tar.gz and SHA256SUMS of that release and refuses an
#      archive whose SHA-256 does not match. The sum shows the archive arrived intact; it does not
#      show who wrote the code. The release is the upstream one unless PR_SKILLS_DOWNLOAD_URL says
#      otherwise;
#   4. unpacks it in a scratch directory (members with an absolute path or `..` are refused) and
#      checks that its VERSION is the release asked for;
#   5. runs the release's own install.sh with --target on the skills directory, which replaces each
#      installed skill folder by a staged copy and puts the old one back if the swap fails;
#   6. puts back the script prefix of an installed templates/review-gate.yml that was installed
#      outside .agents/skills, and says when the template changed (the workflow in a repository is
#      a copy a person made, and is never touched);
#   7. reads the installed version of each skill again and fails unless it is the release.
#
# Unlike check-version.sh, every failure here is loud: a message on stderr and a non-zero exit. A
# failure before step 5 leaves the installed skills as they were.
#
# Refused: a checkout of this repository (update it with git), a skills directory it cannot tell
# is an install, a folder that install.sh would not replace (see its header).
#
# Usage: update.sh [--yes]
#
# Environment (all optional):
#   PR_SKILLS_DOWNLOAD_URL  base URL of the releases; the file is <base>/vX.Y.Z/<name>. Default is
#                           https://github.com/jonyfs/pr-reviewer-fixer/releases/download. Any URL
#                           curl understands works, which is how the tests feed files.
#   PR_SKILLS_RELEASE_URL, PR_SKILLS_CACHE_DIR   as in check-version.sh.
set -uo pipefail

main() {
  die() { echo "update: $*" >&2; return 1; }

  local yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) yes=1; shift ;;
      -h|--help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0"; return 0 ;;
      *) die "unknown argument '$1' (try --help)"; return 1 ;;
    esac
  done

  local here skill_dir skills_dir
  here="$(cd "$(dirname "$0")" && pwd -P)" || { die "cannot resolve where this script is"; return 1; }
  skill_dir="$(cd "$here/.." && pwd -P)"
  skills_dir="$(cd "$skill_dir/.." && pwd -P)"
  case "$(basename "$skill_dir")" in
    pr-reviewer|pr-fixer) ;;
    *) die "this script is not in a pr-reviewer or pr-fixer folder ($skill_dir); nothing changed"; return 1 ;;
  esac
  # The repository's own .agents/skills is the source of the release, not an install of it.
  if [ -f "$skills_dir/../../install.sh" ] && [ -f "$skills_dir/../../.github/scripts/release.sh" ]; then
    die "$skills_dir is inside a checkout of the repository itself; update it with git. Nothing changed."
    return 1
  fi

  local s names=() sk
  for s in pr-reviewer pr-fixer; do
    [ -d "$skills_dir/$s" ] && names+=("$s")
  done
  if [ "${#names[@]}" = 2 ]; then sk=both; else sk="${names[0]}"; fi

  command -v python3 >/dev/null 2>&1 || { die "python3 is needed to compare versions; nothing changed"; return 1; }
  command -v curl >/dev/null 2>&1 || { die "curl is needed to download the release; nothing changed"; return 1; }
  command -v tar >/dev/null 2>&1 || { die "tar is needed to unpack the release; nothing changed"; return 1; }
  local sum_cmd
  if command -v sha256sum >/dev/null 2>&1; then sum_cmd="sha256sum"
  elif command -v shasum >/dev/null 2>&1; then sum_cmd="shasum -a 256"
  else die "sha256sum or shasum is needed to check the download; nothing changed"; return 1; fi

  local latest page
  read -r latest page < <("$here/check-version.sh" --latest)
  [ -n "${latest:-}" ] || { die "could not read the latest release from GitHub (offline, rate limit, or no answer); nothing changed"; return 1; }
  printf '%s' "$latest" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { die "the latest release is '$latest', not a version; nothing changed"; return 1; }

  local need=0 v cmp
  for s in "${names[@]}"; do
    v="$("$skills_dir/$s/scripts/check-version.sh" --installed 2>/dev/null)"
    [ -n "$v" ] || { die "cannot read the installed version of $s; nothing changed"; return 1; }
    cmp="$(python3 -I -c '
import sys
a, b = (tuple(int(x) for x in v.split(".")) for v in sys.argv[1:3])
print("older" if a < b else "same" if a == b else "newer")' "$v" "$latest")"
    echo "update: $s is $v, the latest release is $latest ($cmp)"
    case "$cmp" in
      older) need=1 ;;
      newer) die "$s $v is newer than the latest release $latest; refusing to go back. Nothing changed."; return 1 ;;
    esac
  done
  if [ "$need" = 0 ]; then echo "update: already up to date"; return 0; fi

  local base="${PR_SKILLS_DOWNLOAD_URL:-https://github.com/jonyfs/pr-reviewer-fixer/releases/download}"
  local archive="pr-reviewer-fixer-$latest.tar.gz"
  echo "update: would install $latest into $skills_dir ($sk) from $base/v$latest/$archive"
  if [ "$yes" = 0 ]; then
    echo "update: nothing changed. Run again with --yes to install it."
    return 0
  fi

  local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/pr-skills-update.XXXXXX")" || { die "cannot make a scratch directory; nothing changed"; return 1; }
  trap 'rm -rf "$tmp"' RETURN
  curl -fsSL --max-time 300 -o "$tmp/$archive" "$base/v$latest/$archive" \
    || { die "could not download $base/v$latest/$archive; nothing changed"; return 1; }
  curl -fsSL --max-time 60 -o "$tmp/SHA256SUMS" "$base/v$latest/SHA256SUMS" \
    || { die "could not download $base/v$latest/SHA256SUMS; nothing changed"; return 1; }
  local want got
  want="$(awk -v f="$archive" '$2 == f || $2 == "*" f { print $1; exit }' "$tmp/SHA256SUMS")"
  [ -n "$want" ] || { die "SHA256SUMS has no line for $archive; nothing changed"; return 1; }
  got="$(cd "$tmp" && $sum_cmd "$archive" | awk '{ print $1 }')"
  [ "$got" = "$want" ] || { die "the SHA-256 of $archive is $got, SHA256SUMS says $want; refusing it. Nothing changed."; return 1; }

  # The listing is held in a variable and searched with a here-string: with `pipefail`, a `grep -q`
  # that stops reading early would make the pipe report a failure for a match.
  local members
  members="$(tar -tzf "$tmp/$archive")" || { die "cannot read the member list of $archive; nothing changed"; return 1; }
  if grep -Eq '(^/|(^|/)\.\.(/|$))' <<<"$members"; then
    die "the archive has a member with an absolute path or '..'; refusing it. Nothing changed."; return 1
  fi
  mkdir "$tmp/x" && tar -xzf "$tmp/$archive" -C "$tmp/x" || { die "could not unpack $archive; nothing changed"; return 1; }
  local r="$tmp/x/pr-reviewer-fixer-$latest" rv
  rv="$( { tr -d '[:space:]' <"$r/VERSION"; } 2>/dev/null)"
  [ "$rv" = "$latest" ] || { die "the archive holds version '${rv:-none}', not $latest; refusing it. Nothing changed."; return 1; }
  [ -f "$r/install.sh" ] && [ -d "$r/.agents/skills" ] || { die "the archive has no install.sh or .agents/skills; nothing changed"; return 1; }

  local tpl="$skills_dir/pr-reviewer/templates/review-gate.yml" old_prefix="" had_tpl=0
  if [ -f "$tpl" ]; then
    had_tpl=1; cp "$tpl" "$tmp/old-gate.yml"
    old_prefix="$(grep -Eo '[^[:space:]"=]*pr-reviewer/scripts/' "$tpl" | head -1)"
  fi

  bash "$r/install.sh" --target "$skills_dir" --source "$r/.agents/skills" --skill "$sk" --yes \
    || { die "install.sh failed, see above. Its message says what it left and where."; return 1; }

  local new_tpl="$skills_dir/pr-reviewer/templates/review-gate.yml" def=".agents/skills/pr-reviewer/scripts/"
  if [ "$had_tpl" = 1 ] && [ -f "$new_tpl" ] && [ -n "$old_prefix" ] && [ "$old_prefix" != "$def" ]; then
    case "$old_prefix" in
      *'|'*|*'&'*|*'\'*) echo "update: the script prefix '$old_prefix' in the installed review-gate.yml has a character this script will not put back; re-apply it by hand" >&2 ;;
      *) sed "s|$def|$old_prefix|g" "$new_tpl" >"$new_tpl.tmp" && mv "$new_tpl.tmp" "$new_tpl" ;;
    esac
  fi

  for s in "${names[@]}"; do
    v="$("$skills_dir/$s/scripts/check-version.sh" --installed 2>/dev/null)"
    [ "$v" = "$latest" ] || { die "after the install, $s reports '${v:-none}', not $latest. Check $skills_dir/$s."; return 1; }
  done
  echo "update: done. ${names[*]} now at $latest.${page:+ Release notes: $page}"
  if [ "$had_tpl" = 1 ] && ! cmp -s "$tmp/old-gate.yml" "$new_tpl"; then
    echo "update: templates/review-gate.yml changed in this release. If a repository uses a copy of it as .github/workflows/review-gate.yml, compare the two and update that copy yourself."
  fi
  return 0
}

main "$@"
exit $?
