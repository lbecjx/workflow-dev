#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for release.sh: the version bump from the waiting fragments, the no-op
# without fragments, the refusals, and the files it writes. Most cases use a
# stand-in for towncrier; the last one uses the real thing when it is installed.
# Run directly: bash .github/scripts/release.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RELEASE="$HERE/release.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
check() { # $1 label, then a test command
  local label="$1"
  shift
  if "$@"; then ok "$label"; else no "$label"; fi
}

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# A stand-in for towncrier: --draft prints status lines and the notes, --yes
# removes the fragments and writes the section under the marker. STUB_FAIL=1
# makes the draft fail.
STUB="$TMP/towncrier-stub"
cat > "$STUB" <<'STUBEOF'
#!/bin/bash
mode=""; ver=""
while [ $# -gt 0 ]; do
  case "$1" in
    build) ;;
    --draft) mode=draft ;;
    --yes) mode=yes ;;
    --version) ver="$2"; shift ;;
  esac
  shift
done
body=""
for f in changes/*.md; do
  [ "$(basename "$f")" = ".gitkeep" ] && continue
  [ -f "$f" ] && body="$body- $(cat "$f")
"
done
if [ "$mode" = draft ]; then
  [ "${STUB_FAIL:-0}" = 1 ] && { echo "boom"; exit 1; }
  [ "${STUB_NOHEAD:-0}" = 1 ] && { printf 'Loading template...\nDraft only\n'; exit 0; }
  printf 'Loading template...\nDraft only\n\n## %s\n\n%s\n' "$ver" "$body"
  exit 0
fi
for f in changes/*.md; do
  [ "$(basename "$f")" = ".gitkeep" ] && continue
  git rm -q -f "$f"
done
V="$ver" B="$body" awk '{print} /towncrier release notes start/ {print ""; print "## " ENVIRON["V"]; print ""; printf "%s", ENVIRON["B"]}' CHANGELOG.md > CHANGELOG.new
mv CHANGELOG.new CHANGELOG.md
STUBEOF
chmod +x "$STUB"

# mkrepo <name>: a repo shaped like this one, at version 1.49.1, one commit.
mkrepo() {
  local d="$TMP/$1"
  mkdir -p "$d/.claude-plugin" "$d/.github" "$d/changes"
  printf '{\n  "name": "workflow-dev",\n  "description": "Plain \\u2014 dash",\n  "version": "1.49.1",\n  "author": {\n    "name": "lbecjx"\n  }\n}' > "$d/.claude-plugin/plugin.json"
  printf '# Changelog\n\nIntro.\n\n<!-- towncrier release notes start -->\n\n## 1.49.1\n\n- Older note.\n' > "$d/CHANGELOG.md"
  cp "$ROOT/.github/towncrier.toml" "$ROOT/.github/towncrier-template.md.jinja" "$d/.github/"
  : > "$d/changes/.gitkeep"
  git -C "$d" init -q
  git -C "$d" add -A
  git -C "$d" commit -q -m init
  echo "$d"
}
note() { printf '%s\n' "$2" > "$1"; } # note <path> <text>
version_of() { jq -r .version "$1/.claude-plugin/plugin.json"; }
commits_of() { git -C "$1" rev-list --count HEAD; }
run_release() { # run_release <repo> [env assignments ...]
  local d="$1"
  shift
  (cd "$d" && env TOWNCRIER="$STUB" GITHUB_OUTPUT="$d/out.txt" "$@" "$RELEASE" > "$d/run.log" 2>&1)
}
clean_tree() { [ -z "$(git -C "$1" status --porcelain -- . ':!out.txt' ':!run.log')" ]; }

echo "no fragments"
R="$(mkrepo none)"
run_release "$R"; rc=$?
check "exits 0" [ "$rc" -eq 0 ]
check "no commit" [ "$(commits_of "$R")" -eq 1 ]
check "no tag" [ -z "$(git -C "$R" tag)" ]
check "version untouched" [ "$(version_of "$R")" = 1.49.1 ]
check "reports released=false" grep -qx 'released=false' "$R/out.txt"

echo "bump"
bump_case() { # bump_case <label> <expected> <file...>
  local label="$1" want="$2"
  shift 2
  local d
  d="$(mkrepo "bump-$want-$RANDOM")"
  for f in "$@"; do note "$d/changes/$f" "A note for $f."; done
  git -C "$d" add -A
  run_release "$d"; local rc=$?
  check "$label: exits 0" [ "$rc" -eq 0 ]
  check "$label: version is $want" [ "$(version_of "$d")" = "$want" ]
  check "$label: tag v$want on HEAD" [ "$(git -C "$d" rev-parse "v$want^{commit}" 2>/dev/null)" = "$(git -C "$d" rev-parse HEAD)" ]
}
bump_case "fix only" 1.49.2 WD-1.fix.md
bump_case "misc only" 1.49.2 WD-1.misc.md
bump_case "feat and fix" 1.50.0 WD-1.feat.md WD-2.fix.md
bump_case "numbered feat" 1.50.0 WD-1.feat.1.md WD-1.feat.2.md
bump_case "breaking and feat" 2.0.0 WD-1.breaking.md WD-2.feat.md

echo "what a release writes"
R="$(mkrepo writes)"
note "$R/changes/WD-1.feat.md" "Added a thing."
note "$R/changes/WD-2.fix.md" "Fixed a thing."
git -C "$R" add -A
run_release "$R"; rc=$?
check "commit message is 'Release 1.50.0'" [ "$(git -C "$R" log -1 --format=%s)" = "Release 1.50.0" ]
check "one commit added" [ "$(commits_of "$R")" -eq 2 ]
check "fragments are gone, .gitkeep stays" [ ! -e "$R/changes/WD-1.feat.md" ] && [ -e "$R/changes/.gitkeep" ]
check "tree is clean after the release" clean_tree "$R"
check "plugin.json still has no newline at the end, as before" [ "$(tail -c1 "$R/.claude-plugin/plugin.json")" = "}" ]
check "plugin.json keeps its escaped dash" grep -q '\\u2014' "$R/.claude-plugin/plugin.json"
check "plugin.json changes only the version" [ "$(git -C "$R" show HEAD~1:.claude-plugin/plugin.json | jq -S 'del(.version)')" = "$(jq -S 'del(.version)' "$R/.claude-plugin/plugin.json")" ]
check "CHANGELOG keeps the older section" grep -qx '## 1.49.1' "$R/CHANGELOG.md"
check "CHANGELOG has the new section" grep -qx '## 1.50.0' "$R/CHANGELOG.md"
check "the tag is annotated, so push --follow-tags sends it" [ "$(git -C "$R" cat-file -t v1.50.0)" = tag ]
check "output: released=true" grep -qx 'released=true' "$R/out.txt"
check "output: version" grep -qx 'version=1.50.0' "$R/out.txt"
NOTES="$(sed -n 's/^notes_file=//p' "$R/out.txt")"
check "output: notes file holds the bullets" grep -q '^- Added a thing\.' "$NOTES"
check "output: notes file has no heading" [ -z "$(grep '^## ' "$NOTES")" ]

echo "a second run"
run_release "$R"; rc=$?
check "exits 0" [ "$rc" -eq 0 ]
check "no new commit" [ "$(commits_of "$R")" -eq 2 ]
check "no second tag" [ "$(git -C "$R" tag | wc -l | tr -d ' ')" -eq 1 ]

echo "names that are not fragments"
for bad in notes.md WD-1.feature.md README.md "ñotes.md" WD-1.fix.txt .DS_Store .foo; do
  R="$(mkrepo "stray-$RANDOM")"
  note "$R/changes/WD-2.fix.md" "A real note."
  note "$R/changes/$bad" "Not a fragment."
  git -C "$R" add -A
  run_release "$R"; rc=$?
  check "'$bad': exits 1" [ "$rc" -eq 1 ]
  check "'$bad': names the file" grep -q "changes/$bad" "$R/run.log"
  check "'$bad': nothing is touched" [ "$(version_of "$R")" = 1.49.1 ] && [ -e "$R/changes/WD-2.fix.md" ] && [ -z "$(git -C "$R" tag)" ]
done

echo "a note with nothing in it"
for body in "" "   "; do
  R="$(mkrepo "blank-$RANDOM")"
  note "$R/changes/WD-1.fix.md" "A real note."
  printf '%s\n' "$body" > "$R/changes/WD-2.fix.md"
  git -C "$R" add -A
  run_release "$R"; rc=$?
  check "blank note '$body': exits 1" [ "$rc" -eq 1 ]
  check "blank note '$body': names the file and says it is empty" grep -q 'changes/WD-2.fix.md: the note is empty' "$R/run.log"
  check "blank note '$body': nothing is touched" [ "$(version_of "$R")" = 1.49.1 ] && [ -e "$R/changes/WD-1.fix.md" ] && [ -z "$(git -C "$R" tag)" ]
done

echo "the changes folder"
R="$(mkrepo nokeep)"
git -C "$R" rm -q -f changes/.gitkeep
mkdir -p "$R/changes"
note "$R/changes/WD-1.fix.md" "A fix."
git -C "$R" add -A
git -C "$R" commit -q -m "no keep"
run_release "$R"; rc=$?
check "without .gitkeep: exits 0" [ "$rc" -eq 0 ]
check "without .gitkeep: the version bump is in the release commit" [ "$(git -C "$R" show HEAD:.claude-plugin/plugin.json | jq -r .version)" = 1.49.2 ]
check "without .gitkeep: the folder is kept with .gitkeep" [ -e "$R/changes/.gitkeep" ] && git -C "$R" cat-file -e HEAD:changes/.gitkeep

echo "a step fails after the notes are built"
rolled_back() { # rolled_back <repo> <fragment>: everything is as it was at HEAD (fragment committed)
  local d="$1" frag="$2"
  [ "$(version_of "$d")" = 1.49.1 ] && [ -e "$d/changes/$frag" ] \
    && [ -z "$(git -C "$d" tag)" ] && [ "$(commits_of "$d")" -eq 2 ] \
    && [ -z "$(git -C "$d" status --porcelain -- . ':!out.txt' ':!run.log')" ]
}
R="$(mkrepo hookfail)"
note "$R/changes/WD-1.fix.md" "A fix."
git -C "$R" add -A
git -C "$R" commit -q -m fragments
printf '#!/bin/sh\nexit 1\n' > "$R/.git/hooks/pre-commit"
chmod +x "$R/.git/hooks/pre-commit"
run_release "$R"; rc=$?
check "a failing commit: exits 1" [ "$rc" -eq 1 ]
check "a failing commit: changes/, CHANGELOG.md and plugin.json are back at HEAD" rolled_back "$R" WD-1.fix.md
check "a failing commit: CHANGELOG has no new section" [ -z "$(grep -x '## 1.49.2' "$R/CHANGELOG.md")" ]

R="$(mkrepo emptynotes)"
note "$R/changes/WD-1.fix.md" "A fix."
git -C "$R" add -A
git -C "$R" commit -q -m fragments
run_release "$R" STUB_NOHEAD=1; rc=$?
check "empty notes: exits 1" [ "$rc" -eq 1 ]
check "empty notes: everything is back at HEAD" rolled_back "$R" WD-1.fix.md

echo "refusals"
R="$(mkrepo tagged)"
note "$R/changes/WD-1.fix.md" "A fix."
git -C "$R" add -A
git -C "$R" tag v1.49.2
run_release "$R"; rc=$?
check "an existing tag: exits 1" [ "$rc" -eq 1 ]
check "an existing tag: says so" grep -q 'tag v1.49.2 already exists' "$R/run.log"
check "an existing tag: fragment and version untouched" [ -e "$R/changes/WD-1.fix.md" ] && [ "$(version_of "$R")" = 1.49.1 ]

R="$(mkrepo headed)"
printf '# Changelog\n\n<!-- towncrier release notes start -->\n\n## 1.49.2\n\n- Hand written.\n\n## 1.49.1\n' > "$R/CHANGELOG.md"
note "$R/changes/WD-1.fix.md" "A fix."
git -C "$R" add -A
run_release "$R"; rc=$?
check "a heading already there: exits 1" [ "$rc" -eq 1 ]
check "a heading already there: no commit" [ "$(commits_of "$R")" -eq 1 ]

R="$(mkrepo failing)"
note "$R/changes/WD-1.fix.md" "A fix."
git -C "$R" add -A
run_release "$R" STUB_FAIL=1; rc=$?
check "towncrier failing: exits 1" [ "$rc" -eq 1 ]
check "towncrier failing: nothing changed" [ "$(version_of "$R")" = 1.49.1 ] && [ -e "$R/changes/WD-1.fix.md" ] && [ "$(commits_of "$R")" -eq 1 ]

echo "with the real towncrier"
if command -v towncrier >/dev/null 2>&1; then
  R="$(mkrepo real)"
  note "$R/changes/WD-1.fix.md" "Fixed a real thing."
  git -C "$R" add -A
  (cd "$R" && env TOWNCRIER=towncrier GITHUB_OUTPUT="$R/out.txt" "$RELEASE" > "$R/run.log" 2>&1); rc=$?
  check "exits 0" [ "$rc" -eq 0 ]
  check "CHANGELOG gets the section above the older one" [ "$(grep -n '^## ' "$R/CHANGELOG.md" | head -2 | sed 's/^[0-9]*://' | tr '\n' ' ')" = "## 1.49.2 ## 1.49.1 " ]
  NOTES="$(sed -n 's/^notes_file=//p' "$R/out.txt")"
  check "notes file is the bullets without heading" [ "$(cat "$NOTES")" = "$(printf '%s\n' '- Fixed a real thing.')" ] || [ "$(tr -d '\n' < "$NOTES" | sed 's/ *$//')" = "- Fixed a real thing." ]
else
  echo "  SKIP towncrier is not installed (pip install towncrier)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
