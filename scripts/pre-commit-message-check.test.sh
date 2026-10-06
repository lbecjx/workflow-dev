#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for pre-commit-message-check.sh, which is the one script here that has
# *two* enforcement levels — so it owns three words, not a boolean:
# `ok` (nothing to raise), `notify` (the Part 12 review) and `block` (the
# AI-attribution hard rule). All three are pinned, because OpenCode's plugin
# reads that word to decide whether to post a notice or stop the command, and a
# missing word would silently become "no reminder".
#
# The reviewed-marker path is exercised too: it is the only thing that turns
# `notify` into `ok`, and TMPDIR is redirected so the live marker store is
# untouched.
#
#   bash scripts/pre-commit-message-check.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/pre-commit-message-check.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

# Payload construction needs real JSON escaping, and the script's own jq-less
# extraction is best-effort *by design* (its comment says so: it handles the
# shapes this repo's own git conventions produce, and fails toward doing nothing
# otherwise). So rather than assert a decision table the fallback was never
# written to support, skip the way the other suites do — a jq-less host reads
# "not covered here", not eight failures that look like regressions.
if ! command -v jq >/dev/null 2>&1; then
  echo "  skip  jq isn't installed — payload construction for this suite needs it"
  exit 0
fi

export TMPDIR="$TMP/tmpdir"
mkdir -p "$TMPDIR"

# The review ask belongs to a workflow-dev project, so the hook looks for
# .workflow-dev/context in its working directory. Run it from a throwaway project
# that has one; PLAIN_DIR (section 10) has none.
PROJ="$TMP/proj"
PLAIN_DIR="$TMP/plain"
mkdir -p "$PROJ/.workflow-dev/context" "$PLAIN_DIR"

mk() { printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }
hook() { ( cd "$PROJ" && printf '%s' "$1" | bash "$SCRIPT" ); }
status() { ( cd "$PROJ" && bash "$SCRIPT" --status "$1" ); }
plain() { ( cd "$PROJ" && bash "$SCRIPT" --message "$1" ); }
envelope_reason() { printf '%s' "$1" | sed -E 's/.*"permissionDecisionReason":"(.*)"\}\}$/\1/'; }

ATTR="$(mk 'git commit -m "feat: x

Co-Authored-By: Claude <noreply@anthropic.com>"')"
CLEAN="$(mk 'git commit -m "feat: add a thing"')"
OTHER="$(mk 'ls -la')"
PR="$(mk 'gh pr create --title "Add a thing" --body "Some description."')"

# --- 1: not a commit/PR → ok, and silence -----------------------------------
[[ "$(status "$OTHER")" == "ok" ]] && ok "non-commit command → ok" || no "non-commit command → ok (got: $(status "$OTHER"))"
[[ -z "$(plain "$OTHER")" ]] && ok "non-commit command → --message silent" || no "non-commit command → --message silent"
[[ -z "$(hook "$OTHER")" ]] && ok "non-commit command → hook mode silent" || no "non-commit command → hook mode silent"

# --- 2: attribution → block, and the same text in both modes ----------------
[[ "$(status "$ATTR")" == "block" ]] && ok "AI attribution → block" || no "AI attribution → block (got: $(status "$ATTR"))"
ATTR_TEXT="$(plain "$ATTR")"
[[ -n "$ATTR_TEXT" ]] && ok "AI attribution → --message prints the reason" || no "AI attribution → --message prints the reason"
ATTR_JSON="$(hook "$ATTR")"
case "$ATTR_JSON" in
  *'"permissionDecision":"deny"'*) ok "AI attribution → hook mode still denies" ;;
  *) no "AI attribution → hook mode still denies (got: $ATTR_JSON)" ;;
esac
[[ "$(envelope_reason "$ATTR_JSON")" == "$ATTR_TEXT" ]] \
  && ok "attribution: hook JSON and --message carry the same text" \
  || no "attribution: hook JSON and --message carry the same text"
case "$ATTR_TEXT" in
  *"Part 12.3"*) ok "the block reason names the hard rule" ;;
  *) no "the block reason names the hard rule (got: $ATTR_TEXT)" ;;
esac

# --- 3: clean but unreviewed → notify, and the same text in both modes ------
[[ "$(status "$CLEAN")" == "notify" ]] && ok "clean unreviewed → notify" || no "clean unreviewed → notify (got: $(status "$CLEAN"))"
CLEAN_TEXT="$(plain "$CLEAN")"
CLEAN_JSON="$(hook "$CLEAN")"
case "$CLEAN_JSON" in
  *'"permissionDecision":"ask"'*) ok "clean unreviewed → hook mode still asks (never denies)" ;;
  *) no "clean unreviewed → hook mode still asks (got: $CLEAN_JSON)" ;;
esac
[[ "$(envelope_reason "$CLEAN_JSON")" == "$CLEAN_TEXT" ]] \
  && ok "review: hook JSON and --message carry the same text" \
  || no "review: hook JSON and --message carry the same text"

# --- 4: a reviewed message is ok, in both modes -----------------------------
# Same formula the script uses to key its marker: shasum of the extracted body.
BODY_HASH="$(printf '%s' 'feat: add a thing' | shasum | cut -d' ' -f1)"
mkdir -p "$TMPDIR/workflow-dev-validate/messages"
: > "$TMPDIR/workflow-dev-validate/messages/$BODY_HASH.json"
[[ "$(status "$CLEAN")" == "ok" ]] && ok "reviewed message → ok" || no "reviewed message → ok (got: $(status "$CLEAN"))"
[[ -z "$(plain "$CLEAN")" ]] && ok "reviewed message → --message silent" || no "reviewed message → --message silent"
[[ -z "$(hook "$CLEAN")" ]] && ok "reviewed message → hook mode silent" || no "reviewed message → hook mode silent"
# ...and it does not launder attribution: the deny does not consult the marker.
[[ "$(status "$ATTR")" == "block" ]] && ok "a reviewed marker never un-blocks attribution" || no "a reviewed marker never un-blocks attribution"
rm -rf "$TMPDIR/workflow-dev-validate/messages"

# --- 5: a PR's title+description is hashed together -------------------------
# The PR path is the one place HASH_TEXT is not just the body — pinned because
# summarize-changes marks a PR with the same concatenation, and the two must agree.
PR_TITLE="Add a thing"
PR_BODY="Some description."
PR_HASH="$(printf '%s\n\n%s' "$PR_TITLE" "$PR_BODY" | shasum | cut -d' ' -f1)"
mkdir -p "$TMPDIR/workflow-dev-validate/messages"
: > "$TMPDIR/workflow-dev-validate/messages/$PR_HASH.json"
[[ "$(status "$PR")" == "ok" ]] && ok "PR marked with title+body hash → ok" || no "PR marked with title+body hash → ok (got: $(status "$PR"))"
rm -rf "$TMPDIR/workflow-dev-validate/messages"
[[ "$(status "$PR")" == "notify" ]] && ok "PR with no marker → notify" || no "PR with no marker → notify (got: $(status "$PR"))"

# --- 6: the vocabulary is exactly three words -------------------------------
WORDS="$(status "$OTHER") $(status "$CLEAN") $(status "$ATTR")"
unknown=0
for w in $WORDS; do
  case "$w" in
    ok|notify|block) ;;
    *) no "unknown status word: $w"; unknown=1 ;;
  esac
done
# Conditional on the loop above: printing this unconditionally would report a
# pass for the property that just failed.
[[ $unknown -eq 0 ]] && ok "every verdict is one of ok|notify|block ($WORDS)"

# --- 7: a command that only *mentions* a commit/PR is data, not a command ---
# The false positives that motivated command-match.sh. Every fixture here is
# built in-process: typed as a literal into a shell command, the attribution
# text would trip the very hook this suite is testing.
ATTR_LINE='Co-Authored-By: Claude <noreply@anthropic.com>'

# The case that fired live: a heredoc that writes a doc mentioning the verbs.
MENTION_DOC="$(mk "$(printf 'cat > notes.md <<'"'"'EOF'"'"'\nRun git commit, then gh pr create.\nEOF')")"
[[ "$(status "$MENTION_DOC")" == "ok" ]] && ok "heredoc that writes about gh pr create → ok" || no "heredoc that writes about gh pr create → ok (got: $(status "$MENTION_DOC"))"
[[ -z "$(hook "$MENTION_DOC")" ]] && ok "…and hook mode is silent" || no "…and hook mode is silent"

# The false deny: the same doc, with attribution text as a fixture inside it.
MENTION_ATTR="$(mk "$(printf 'cat > notes.md <<'"'"'EOF'"'"'\nExample: git commit -m x\n%s\nEOF' "$ATTR_LINE")")"
[[ "$(status "$MENTION_ATTR")" == "ok" ]] && ok "mention + attribution fixture in a heredoc → ok, no deny" || no "mention + attribution fixture in a heredoc → ok, no deny (got: $(status "$MENTION_ATTR"))"
[[ -z "$(hook "$MENTION_ATTR")" ]] && ok "…and hook mode is silent" || no "…and hook mode is silent"

for c in 'echo "git commit"' 'grep -rn "gh pr edit" docs/' 'git commit-tree HEAD^{tree}' 'git commit-graph write' '# git commit later'; do
  [[ "$(status "$(mk "$c")")" == "ok" ]] && ok "mention stays quiet: $c" || no "mention stays quiet: $c (got: $(status "$(mk "$c")"))"
done

# A real commit still blocks, including the forms a substring match missed.
for c in 'git -C ../r commit -m "x"' 'git -c k=v commit -m "x"' 'git  commit -m "x"' 'echo "a" && git commit -m "x"'; do
  REAL_ATTR="$(mk "$(printf '%s\n\n%s' "$c" "$ATTR_LINE")")"
  [[ "$(status "$REAL_ATTR")" == "block" ]] && ok "real commit + attribution blocks: $c" || no "real commit + attribution blocks: $c (got: $(status "$REAL_ATTR"))"
done
REAL_PR_ATTR="$(mk "$(printf 'gh pr create --title "t" --body "b\n%s"' "$ATTR_LINE")")"
[[ "$(status "$REAL_PR_ATTR")" == "block" ]] && ok "real gh pr create + attribution → block" || no "real gh pr create + attribution → block (got: $(status "$REAL_PR_ATTR"))"

# `maybe` (wrapped where the matcher cannot see) with attribution: ask, never deny.
MAYBE_ATTR="$(mk "$(printf 'bash -c "git commit -m x\n%s"' "$ATTR_LINE")")"
[[ "$(status "$MAYBE_ATTR")" == "notify" ]] && ok "bash -c commit + attribution → notify, not block" || no "bash -c commit + attribution → notify, not block (got: $(status "$MAYBE_ATTR"))"
MAYBE_JSON="$(hook "$MAYBE_ATTR")"
case "$MAYBE_JSON" in
  *'"permissionDecision":"ask"'*) ok "…hook mode asks, never denies" ;;
  *) no "…hook mode asks, never denies (got: $MAYBE_JSON)" ;;
esac
MAYBE_TEXT="$(plain "$MAYBE_ATTR")"
case "$MAYBE_TEXT" in
  *"Part 12.3"*) ok "…and its reason names the attribution rule" ;;
  *) no "…and its reason names the attribution rule (got: $MAYBE_TEXT)" ;;
esac
[[ "$(envelope_reason "$MAYBE_JSON")" == "$MAYBE_TEXT" ]] && ok "…hook JSON and --message carry the same text" || no "…hook JSON and --message carry the same text"
[[ "$MAYBE_TEXT" != "$ATTR_TEXT" ]] && ok "…and it is not the deny's wording" || no "…and it is not the deny's wording"

# `maybe` without attribution is the ordinary Part 12 reminder (AC #6: err toward asking).
MAYBE_CLEAN="$(mk 'bash -c "git commit -m \"feat: add a thing\""')"
[[ "$(status "$MAYBE_CLEAN")" == "notify" || "$(status "$MAYBE_CLEAN")" == "ok" ]] && ok "bash -c commit, clean → never block" || no "bash -c commit, clean → never block (got: $(status "$MAYBE_CLEAN"))"

# --- 8: real commits that sit behind wrappers, options or heredocs -----------
# Each of these was `block` under the old substring match and went silent under
# the first matcher (a lost hard block, not just a lost reminder). `real` blocks;
# `maybe` (handed to a shell to run) asks and never denies.
HD="$(printf "cat <<EOF>n.md\nhi\nEOF\ngit commit -m \"x\n\n%s\"" "$ATTR_LINE")"
AR="$(printf 'n=$((1<<2))\ngit commit -m "x\n\n%s"' "$ATTR_LINE")"
for c in "$HD" "$AR" \
         "$(printf 'time -p git commit -m "x\n\n%s"' "$ATTR_LINE")" \
         "$(printf 'sudo -iu bob git commit -m "x\n\n%s"' "$ATTR_LINE")" \
         "$(printf 'flock /tmp/l git commit -m "x\n\n%s"' "$ATTR_LINE")" \
         "$(printf 'timeout 60 git commit -m "x\n\n%s"' "$ATTR_LINE")" \
         "$(printf 'echo a | xargs git commit -m "x\n\n%s"' "$ATTR_LINE")" \
         "$(printf '&>log git commit -m "x\n\n%s"' "$ATTR_LINE")"; do
  label="$(printf '%s' "$c" | head -1)"
  [[ "$(status "$(mk "$c")")" == "block" ]] && ok "real commit + attribution blocks: $label" || no "real commit + attribution blocks: $label (got: $(status "$(mk "$c")"))"
done
for c in "$(printf "bash <<'EOF'\ngit commit -m \"x\n\n%s\"\nEOF" "$ATTR_LINE")" \
         "$(printf 'git submodule foreach git commit -am "x\n\n%s"' "$ATTR_LINE")"; do
  label="$(printf '%s' "$c" | head -1)"
  got="$(status "$(mk "$c")")"
  [[ "$got" == "notify" ]] && ok "handed to a shell, with attribution → asks, never blocks: $label" || no "handed to a shell, with attribution → asks, never blocks: $label (got: $got)"
done

# A real commit inside an opaque span (`[[ ]]`, an array literal) is still a
# commit: the span used to be skipped whole, so the hard block never saw it.
for c in "$(printf '[[ -n "$(git commit -m "x\n\n%s")" ]] && echo ok' "$ATTR_LINE")" \
         "$(printf 'out=($(git commit -m "x\n\n%s"))' "$ATTR_LINE")"; do
  label="$(printf '%s' "$c" | head -1)"
  got="$(status "$(mk "$c")")"
  [[ "$got" == "block" ]] && ok "real commit inside an opaque span still blocks: $label" || no "real commit inside an opaque span still blocks: $label (got: $got)"
done

# A real PR's title is folded into the hash; a mention never takes that branch.
PR_HASH2="$(printf '%s\n\n%s' 'A title' 'A body.' | shasum | cut -d' ' -f1)"
mkdir -p "$TMPDIR/workflow-dev-validate/messages"
: > "$TMPDIR/workflow-dev-validate/messages/$PR_HASH2.json"
[[ "$(status "$(mk 'gh -R o/r pr create --title "A title" --body "A body."')")" == "ok" ]] \
  && ok "a real PR with -R: marker built from title+body matches" \
  || no "a real PR with -R: marker built from title+body matches"
[[ "$(status "$(mk 'echo "gh pr create --title \"A title\" --body \"A body.\""')")" == "ok" ]] \
  && ok "a mention of a PR command stays ok whatever the markers hold" \
  || no "a mention of a PR command stays ok whatever the markers hold"
rm -rf "$TMPDIR/workflow-dev-validate/messages"

# --- 9: without jq, the shared extractor reads past an escaped quote ----------
# The deny used to keep the old `[^"]*` extractor: the attribution sat after the
# first \" and the hard block never saw it.
NOJQ="$TMP/nojq-bin"
mkdir -p "$NOJQ"
for t in bash cat grep sed awk head cut sort tr git shasum dirname uname; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NOJQ/$t"
done
nojq_status() { ( cd "$PROJ" && PATH="$NOJQ" bash "$SCRIPT" --status "$1" ); }
if PATH="$NOJQ" command -v jq >/dev/null 2>&1; then
  echo "  skip  could not hide jq from the fallback checks"
else
  for c in "$(printf 'git commit -m "x\n\n%s"' "$ATTR_LINE")" \
           "$(printf 'echo "a" && git commit -m "x\n\n%s"' "$ATTR_LINE")" \
           "$(printf 'git commit -m "$(cat <<'"'"'EOF'"'"'\nx\n\n%s\nEOF\n)"' "$ATTR_LINE")"; do
    label="$(printf '%s' "$c" | head -1)"
    got="$(nojq_status "$(mk "$c")")"
    [[ "$got" == "block" ]] && ok "no jq: attribution still blocks: $label" || no "no jq: attribution still blocks: $label (got: $got)"
  done
  [[ "$(nojq_status "$(mk 'echo "run git commit later"')")" == "ok" ]] && ok "no jq: a mention stays ok" || no "no jq: a mention stays ok"
fi

# --- 10: outside a workflow-dev project the review ask stays quiet -----------
# The attribution rule is not part of that gate: it blocks in any directory.
in_plain() { ( cd "$PLAIN_DIR" && bash "$SCRIPT" "$@" ); }
in_plain_hook() { ( cd "$PLAIN_DIR" && printf '%s' "$1" | bash "$SCRIPT" ); }
[[ "$(in_plain --status "$CLEAN")" == "ok" ]] && ok "no workflow-dev project: a clean unreviewed commit → ok" || no "no workflow-dev project: a clean unreviewed commit → ok (got: $(in_plain --status "$CLEAN"))"
[[ -z "$(in_plain --message "$CLEAN")" ]] && ok "no workflow-dev project: --message silent" || no "no workflow-dev project: --message silent"
[[ -z "$(in_plain_hook "$CLEAN")" ]] && ok "no workflow-dev project: hook mode silent" || no "no workflow-dev project: hook mode silent"
[[ "$(in_plain --status "$PR")" == "ok" ]] && ok "no workflow-dev project: an unreviewed PR → ok" || no "no workflow-dev project: an unreviewed PR → ok"
[[ "$(in_plain --status "$ATTR")" == "block" ]] && ok "no workflow-dev project: attribution still blocks" || no "no workflow-dev project: attribution still blocks (got: $(in_plain --status "$ATTR"))"
case "$(in_plain_hook "$ATTR")" in
  *'"permissionDecision":"deny"'*) ok "no workflow-dev project: hook mode still denies attribution" ;;
  *) no "no workflow-dev project: hook mode still denies attribution" ;;
esac
# ...and the same clean commit does ask inside a project.
[[ "$(status "$CLEAN")" == "notify" ]] && ok "workflow-dev project: the same clean commit → notify" || no "workflow-dev project: the same clean commit → notify"

# --- 11: text the shell expands at run time is not guessed at ------------------
# `--body "$(cat file)"` used to be read as the fragment `$(cat ` and asked about
# although the real text sat in a file the hook cannot see.
for c in 'gh pr create --title "A title" --body "$(cat /tmp/pr-body.txt)"' \
         'gh pr create --title "$(cat /tmp/pr-title.txt)" --body "A body."' \
         'gh pr create --title "$(cat /tmp/t)" --body "$(cat /tmp/b)"' \
         'git commit -m "$(cat /tmp/msg.txt)"' \
         'git commit -m "fix: costs $5"' \
         'git commit -m "feat: `date`"'; do
  got="$(status "$(mk "$c")")"
  [[ "$got" == "ok" ]] && ok "unreadable text stays quiet: $c" || no "unreadable text stays quiet: $c (got: $got)"
done
# Readable text is still reviewed, and the prescribed heredoc form still is.
[[ "$(status "$(mk 'gh pr create --title "A title" --body "A body, not reviewed."')")" == "notify" ]] \
  && ok "a readable unreviewed PR still asks" || no "a readable unreviewed PR still asks"
HD_FORM="$(printf 'git commit -m "$(cat <<'"'"'EOF'"'"'\nfeat: not reviewed yet\nEOF\n)"')"
[[ "$(status "$(mk "$HD_FORM")")" == "notify" ]] && ok "the heredoc message form still asks" || no "the heredoc message form still asks"
# Attribution in a command that also reads its text from a file is still caught.
[[ "$(status "$(mk "$(printf 'gh pr create --title "t" --body "$(cat /tmp/b)"\n%s' "$ATTR_LINE")")")" == "block" ]] \
  && ok "attribution beside an unreadable body still blocks" || no "attribution beside an unreadable body still blocks"

# --- 12: a message kept in a file is read, hashed, and compared with the marker ---
# `--body "$(cat file)"`, `-F file` and `--body-file file` carry the text in a file
# the shell reads at run time. The hook reads the same file, so a text that was
# marked reviewed passes and one that was not still asks.
MSG_DIR="$TMPDIR/msgs"
mkdir -p "$MSG_DIR" "$TMPDIR/workflow-dev-validate/messages"
printf 'Add a thing\n' > "$MSG_DIR/title.txt"
printf 'A body that was reviewed.\n\nSecond paragraph.\n' > "$MSG_DIR/body.txt"
printf 'feat: a message kept in a file\n\nWith a body.\n' > "$MSG_DIR/commit.txt"
mark() { : > "$TMPDIR/workflow-dev-validate/messages/$(printf '%s' "$1" | shasum | cut -d' ' -f1).json"; }
unmark() { rm -f "$TMPDIR/workflow-dev-validate/messages/"*.json; }

PR_FILES='gh pr create --title "$(cat "$TMPDIR/msgs/title.txt")" --body "$(cat "$TMPDIR/msgs/body.txt")"'
PR_FILES_ABS="gh pr create --title \"\$(cat $MSG_DIR/title.txt)\" --body \"\$(cat $MSG_DIR/body.txt)\""
unmark
[[ "$(status "$(mk "$PR_FILES")")" == "notify" ]] && ok "PR text in files, not reviewed → asks" || no "PR text in files, not reviewed → asks (got: $(status "$(mk "$PR_FILES")"))"
mark "$(printf '%s\n\n%s' 'Add a thing' "$(cat "$MSG_DIR/body.txt")")"
[[ "$(status "$(mk "$PR_FILES")")" == "ok" ]] && ok "PR text in files, marked reviewed ($TMPDIR path) → ok" || no "PR text in files, marked reviewed → ok"
[[ "$(status "$(mk "$PR_FILES_ABS")")" == "ok" ]] && ok "PR text in files, absolute paths → ok" || no "PR text in files, absolute paths → ok"
printf 'A different body.\n' > "$MSG_DIR/body.txt"
[[ "$(status "$(mk "$PR_FILES")")" == "notify" ]] && ok "the file changed after review → asks again" || no "the file changed after review → asks again"
printf 'A body that was reviewed.\n\nSecond paragraph.\n' > "$MSG_DIR/body.txt"

unmark
GCF='git commit -F "$TMPDIR/msgs/commit.txt"'
[[ "$(status "$(mk "$GCF")")" == "notify" ]] && ok "git commit -F file, not reviewed → asks" || no "git commit -F file, not reviewed → asks"
mark "$(cat "$MSG_DIR/commit.txt")"
[[ "$(status "$(mk "$GCF")")" == "ok" ]] && ok "git commit -F file, marked reviewed → ok" || no "git commit -F file, marked reviewed → ok"
[[ "$(status "$(mk "git commit --file $MSG_DIR/commit.txt")")" == "ok" ]] && ok "git commit --file path, marked reviewed → ok" || no "git commit --file path, marked reviewed → ok"
[[ "$(status "$(mk 'git commit -m "$(cat "$TMPDIR/msgs/commit.txt")"')")" == "ok" ]] && ok "git commit -m \"\$(cat file)\", marked reviewed → ok" || no "git commit -m \"\$(cat file)\", marked reviewed → ok"
[[ "$(status "$(mk 'gh pr create --title "T" --body-file "$TMPDIR/msgs/commit.txt"')")" == "notify" ]] && ok "--body-file, a PR whose text was not marked → asks" || no "--body-file, a PR whose text was not marked → asks"

# What cannot be read stays quiet: a file that is not there, an unset variable, stdin.
[[ "$(status "$(mk 'git commit -F "$TMPDIR/msgs/missing.txt"')")" == "ok" ]] && ok "a file that does not exist → quiet" || no "a file that does not exist → quiet"
[[ "$(status "$(mk 'git commit -F "$NO_SUCH_VAR_XYZ/m.txt"')")" == "ok" ]] && ok "an unset variable in the path → quiet" || no "an unset variable in the path → quiet"
[[ "$(status "$(mk 'git commit -F -')")" == "ok" ]] && ok "-F - (stdin) → quiet" || no "-F - (stdin) → quiet"
[[ "$(status "$(mk 'gh pr create --title "$(cat "$TMPDIR/msgs/missing.txt")" --body "A body.")')")" == "ok" ]] && ok "a title file that cannot be read → quiet" || no "a title file that cannot be read → quiet"
unmark

# --- 13: message flags the extraction used to miss (WD-0028 AC #8) -----------
# `-qm` / `-am` (combined short clusters carrying m), `--message`, and a
# single-quoted body. Each is a real commit whose message is now read, so an
# unmarked one asks; the double-quoted `-m`/`--body` forms above pin the rest.
for c in 'git commit -qm "feat: quiet commit"' \
         'git commit -am "feat: all files commit"' \
         'git commit --message "feat: long message flag"'; do
  got="$(status "$(mk "$c")")"
  [[ "$got" == "notify" ]] && ok "reads the message body: $c" || no "reads the message body: $c (got: $got)"
done
SQ='git commit -m '"'"'feat: single quoted body'"'"''
[[ "$(status "$(mk "$SQ")")" == "notify" ]] && ok "reads a single-quoted message body" || no "reads a single-quoted message body"
# ...and a marked single-quoted body is recognized, so reading it does not move
# an already-reviewed message into the ask.
mark "feat: single quoted body"
[[ "$(status "$(mk "$SQ")")" == "ok" ]] && ok "a reviewed single-quoted body → ok" || no "a reviewed single-quoted body → ok"
unmark

# --- 14: a hook with no TMPDIR still reads a $TMPDIR path (WD-0028 AC #7) ------
# The command names its file under $TMPDIR, expanded by the shell that runs it;
# the hook's own env may not carry TMPDIR. resolve_path() falls back to the
# platform temp dir for a temp path, so the review still runs instead of going
# silently quiet.
PLATFORM_TMP="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"; PLATFORM_TMP="${PLATFORM_TMP%/}"
[[ -n "$PLATFORM_TMP" ]] || PLATFORM_TMP=/tmp
TEMPD="$PLATFORM_TMP/wd-0028-$$"
mkdir -p "$TEMPD"
printf 'feat: a message under the platform temp dir\n' > "$TEMPD/msg.txt"
CMD_TMPDIR="git commit -m \"\$(cat \"\$TMPDIR/wd-0028-$$/msg.txt\")\""
got="$( cd "$PROJ" && env -u TMPDIR bash "$SCRIPT" --status "$(mk "$CMD_TMPDIR")" )"
[[ "$got" == "notify" ]] && ok "a \$TMPDIR path is read when the hook env has no TMPDIR" \
                        || no "a \$TMPDIR path is read when the hook env has no TMPDIR (got: $got)"
rm -rf "$TEMPD"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail == 0 ? 0 : 1))
