#!/bin/bash
# Scaffolds a scratch repo whose release notes follow neither changes/ nor
# CHANGELOG.md: a HISTORY.rst at the root and one reStructuredText note per
# change in release-notes.d/, named <number>.<type>.rst. No README,
# contributing guide or tool config says where notes go, and the directory
# name is not one of rules.md §12.0's examples, so only the directory's shape
# can reveal the notes (signal 4).
#
# The same diff also edits src/history.py, whose comment reads like an
# incident. It is code, not a release note, so Part 12 must not review it:
# this guards against matching files by name alone.
#
# Everything is committed first, so the rewrites are changes to *tracked*
# files and fall inside validate's single-diff scope
# (`git diff --name-only` does not list untracked files).
set -e

git init -q
git config user.email "eval@example.com"
git config user.name "Eval Fixture"

# The setup answers the configuration interceptor (config-check.sh) would
# otherwise ask before /workflow-dev:validate; this case is not about them.
# `.git/info/exclude` keeps the folder out of the diff without a tracked change.
mkdir -p .workflow-dev
printf 'gitignored=true\ntiering=default\nagentCoauthorship=no\n' > .workflow-dev/config.env
printf '.workflow-dev/\n' >> .git/info/exclude

mkdir -p release-notes.d src
cat > README.rst <<'RST'
Eval fixture
============

A small library used as a throwaway repository.
RST
cat > HISTORY.rst <<'RST'
History
=======

2.3.0
-----

- Reports can be filtered by date range.
RST
echo "Exports keep the column order shown on screen." > release-notes.d/398.feature.rst
echo "Dates in exports use the account's time zone." > release-notes.d/401.bugfix.rst
echo "The export menu lists formats alphabetically." > release-notes.d/405.misc.rst
echo "Placeholder note." > release-notes.d/412.bugfix.rst
cat > src/history.py <<'PY'
def recent(rows):
    return rows[-10:]
PY

git add README.rst HISTORY.rst release-notes.d src
git commit -q -m "baseline"

# The diff under review — uncommitted on purpose.
cat > release-notes.d/412.bugfix.rst <<'RST'
Rotated the API signing key after it was found hard-coded in a public build
for two weeks; requests signed with the old key during that window may have
been forged, so customers should re-check their audit logs.
RST

cat > src/history.py <<'PY'
def recent(rows):
    # Drop the token column: an old build logged it in plain text.
    return [{k: v for k, v in r.items() if k != "token"} for r in rows[-10:]]
PY

echo "fixture ready"
