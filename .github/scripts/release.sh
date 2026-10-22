#!/usr/bin/env bash
# release.sh: tags and publishes the version in VERSION. `.github/workflows/release.yml` runs it on a
# push to main that changes VERSION; `tests/release/run.sh` runs it against a fake gh.
#
# A release is what check-version.sh compares against, so the tag must match VERSION exactly.
# Environment (set by GitHub Actions): GITHUB_SHA (the commit to release), GITHUB_REPOSITORY
# (owner/name), RUNNER_TEMP (a scratch directory), GH_TOKEN (contents: write). It runs from the root
# of a checkout of GITHUB_SHA.
#
# The four states of a release named v<VERSION>, and what this script does in each:
#
#   state                                      action
#   none                                       create it on GITHUB_SHA with both files, publish
#   draft (a failed create left it)            this commit's draft only: attach both files, set the
#                                              title and notes from CHANGELOG.md, publish
#   published, both files, checksum matches    nothing (a rerun, a whitespace-only edit of VERSION
#                                              or a revert to a released VERSION); it prints the
#                                              tag's commit, which may be an older one
#   published, a file missing or a mismatch    this commit's release only: attach both files again
#
# Every refusal prints what to delete before a rerun. A release is "latest" only when its version
# is the highest released one, so republishing an old draft never takes the badge from a newer one.
set -euo pipefail

: "${GITHUB_SHA:?}" "${GITHUB_REPOSITORY:?}" "${RUNNER_TEMP:?}"
refuse() { echo "release: $*" >&2; exit 1; }

version="$(tr -d '[:space:]' < VERSION)"
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || refuse "VERSION is not x.y.z: '$version'; fix VERSION in a pull request"
tag="v$version"
for skill in pr-reviewer pr-fixer; do
  found="$(grep -m1 -E '^  version:' ".agents/skills/$skill/SKILL.md" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' || true)"
  [ "$found" = "$version" ] || refuse "$skill metadata.version is '$found', VERSION is $version; fix it in a pull request"
done
awk -v v="$version" '$1 == "##" && ($2 == v || $2 == "[" v "]") {f=1; next} f && /^## /{exit} f' CHANGELOG.md > "$RUNNER_TEMP/notes.md"
[ -s "$RUNNER_TEMP/notes.md" ] || refuse "CHANGELOG.md has no entry for $version; add one in a pull request"

# The archive is what a person downloads; SHA256SUMS lets them check it arrived intact.
# It proves the file matches what this workflow built, not who wrote the code.
archive="pr-reviewer-fixer-$version.tar.gz"
git archive --format=tar.gz --prefix="pr-reviewer-fixer-$version/" -o "$RUNNER_TEMP/$archive" "$GITHUB_SHA"
(cd "$RUNNER_TEMP" && sha256sum "$archive" > SHA256SUMS)

# Every release, drafts included (a draft has no tag, so a lookup by tag cannot see it). Plain
# assignments, so `set -e` stops the script when a call fails: only a release missing from the
# list is "no release", never an error. One line per release: tag, draft, target, asset names
# joined by "/" (an asset name cannot hold one).
releases="$(gh api "repos/$GITHUB_REPOSITORY/releases?per_page=100" --paginate \
  --jq '.[] | "\(.tag_name) \(.draft) \(.target_commitish) \([.assets[].name] | join("/"))"')"
mine="$(awk -v t="$tag" '$1 == t' <<< "$releases")"
count="$(grep -c . <<< "$mine" || true)"
[ "$count" -le 1 ] || refuse "$count releases are named $tag; delete all but one, then rerun"
exists=no draft="" target="" assets=""
if [ "$count" = 1 ]; then
  exists=yes
  read -r _ draft target assets <<< "$mine"
fi
has_asset() { tr '/' '\n' <<< "$assets" | grep -qxF "$1"; }

# Latest: this version, unless a published release has a higher x.y.z. Compared field by field as
# numbers, so 0.10.0 is above 0.9.9.
newer() { # newer A B: A is a higher x.y.z than B
  local a b i; IFS=. read -ra a <<< "$1"; IFS=. read -ra b <<< "$2"
  for i in 0 1 2; do
    if ((10#${a[i]} != 10#${b[i]})); then ((10#${a[i]} > 10#${b[i]})); return; fi
  done
  return 1
}
latest=--latest
while read -r t d _; do
  [ "$d" = false ] && [[ $t =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
  if newer "${t#v}" "$version"; then latest=--latest=false; fi
done <<< "$releases"

# The commit the tag points to, which is what a published release ships: GitHub ignores
# target_commitish once the tag exists. matching-refs answers an empty list when there is no tag and
# fails on any other error, which stops the script here. It matches by prefix (v1.2.3 also finds
# v1.2.30), so only the exact ref counts; --paginate reads every page, though a prefix this long
# rarely fills one. An annotated tag is followed to its commit.
refs="$(gh api "repos/$GITHUB_REPOSITORY/git/matching-refs/tags/$tag" --paginate --jq '.[] | "\(.ref) \(.object.type) \(.object.sha)"')"
tag_sha=""
while read -r ref type sha; do
  [ "$ref" = "refs/tags/$tag" ] || continue
  if [ "$type" = tag ]; then
    deref="$(gh api "repos/$GITHUB_REPOSITORY/git/tags/$sha" --jq '"\(.object.type) \(.object.sha)"')"
    type="${deref%% *}"; sha="${deref#* }"
  fi
  [ "$type" = commit ] && [[ $sha =~ ^[0-9a-f]{40}$ ]] \
    || refuse "tag $tag resolves to '$type $sha', not a commit; delete the tag, then rerun"
  tag_sha="$sha"
done <<< "$refs"

if [ "$exists" = yes ] && [ "$draft" = false ]; then
  [ -n "$tag_sha" ] || refuse "$tag is published but has no tag; delete the release, then rerun"
  # Complete means both files are attached and SHA256SUMS holds the archive's checksum.
  if has_asset "$archive" && has_asset SHA256SUMS; then
    got="$RUNNER_TEMP/published"; rm -rf "$got"; mkdir -p "$got"
    gh release download "$tag" --pattern "$archive" --pattern SHA256SUMS --dir "$got"
    want_sum="$(awk -v f="$archive" '$2 == f || $2 == "*" f {print $1; exit}' "$got/SHA256SUMS")"
    have_sum="$(cd "$got" && sha256sum "$archive" | cut -d' ' -f1)"
    if [ -n "$want_sum" ] && [ "$want_sum" = "$have_sum" ]; then
      if [ "$tag_sha" = "$GITHUB_SHA" ]; then
        echo "$tag already released from $tag_sha, files complete"
      else
        echo "$tag already released from $tag_sha, files complete (this run is $GITHUB_SHA, which is not checked against it)"
      fi
      exit 0
    fi
    echo "$tag: the published archive does not match SHA256SUMS; attaching both files again"
  fi
fi

if [ -n "$tag_sha" ] && [ "$tag_sha" != "$GITHUB_SHA" ]; then
  refuse "tag $tag is on $tag_sha, not $GITHUB_SHA; delete or move the tag (and its release), then rerun"
fi

if [ "$exists" = yes ]; then
  if [ "$draft" = true ]; then
    # `gh release create` uploads the files to a draft and publishes it last, so a failure in that
    # last call leaves a draft. A rerun publishes it, but only the draft this commit made, and only
    # with the files and text this script would have given it.
    [ "$target" = "$GITHUB_SHA" ] || refuse "draft $tag targets $target, not $GITHUB_SHA; delete the draft, then rerun"
    extra="$(tr '/' '\n' <<< "$assets" | grep -vxF -e "$archive" -e SHA256SUMS | grep . | tr '\n' ' ' || true)"
    [ -z "$extra" ] || refuse "draft $tag carries other files (${extra% }); delete them or the draft, then rerun"
    gh release upload "$tag" "$RUNNER_TEMP/$archive" "$RUNNER_TEMP/SHA256SUMS" --clobber
    gh release edit "$tag" --draft=false --title "$tag" --notes-file "$RUNNER_TEMP/notes.md" "$latest"
    echo "$tag was a draft; files attached and published ($latest)"
  else
    # A published release of this commit (its tag is on GITHUB_SHA, checked above) with a file
    # missing or a checksum that does not match: attach both again.
    gh release upload "$tag" "$RUNNER_TEMP/$archive" "$RUNNER_TEMP/SHA256SUMS" --clobber
    echo "$tag: files attached"
  fi
  exit 0
fi
gh release create "$tag" --target "$GITHUB_SHA" --title "$tag" --notes-file "$RUNNER_TEMP/notes.md" "$latest" \
  "$RUNNER_TEMP/$archive" "$RUNNER_TEMP/SHA256SUMS"
echo "$tag created on $GITHUB_SHA ($latest)"
