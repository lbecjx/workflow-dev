#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for config-env.sh. What it pins:
#   - get/set of each key, the other lines kept, the last line of a key wins;
#   - the file is data: a value that looks like code is never run;
#   - CRLF, empty values, `=` inside a value, bad keys and line breaks;
#   - the write replaces the file whole (mode and symlink kept, no temp left),
#     also with many writers at once;
#   - an older config.json is ignored; a repo's config never follows a link;
#   - the CLI the skills run.
#
#   bash scripts/config-env.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/config-env.sh"

TMP="$(mktemp -d)"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
check() { # check <name> <want> <got>
  if [[ "$3" == "$2" ]]; then ok "$1"; else no "$1 (want '$2', got '$3')"; fi
}

# shellcheck source=config-env.sh
. "$LIB"

# The sandbox PATH: only the system tools the lib needs (no jq, no perl).
SYS="$TMP/sys"
mkdir -p "$SYS"
for tool in cat cp mv rm ln mkdir mktemp readlink chmod wc tr grep; do
  real="$(command -v "$tool")" && ln -s "$real" "$SYS/$tool"
done

F="$TMP/a/config.env"
fresh() { rm -rf "$TMP/a"; mkdir -p "$TMP/a"; }

echo "--- 1. get and set --------------------------------------------------------"
fresh
for kv in notifications=on gitignored=true language=es agentCoauthorship=no tiering=default; do
  k="${kv%%=*}"; v="${kv#*=}"
  config_env_set "$F" "$k" "$v" || no "set $k"
  check "round trip: $k" "$v" "$(config_env_get "$F" "$k")"
done
check "every key on its own line" "5" "$(grep -c '=' "$F")"
config_env_set "$F" language en
check "set replaces the key's line" "language=en" "$(grep '^language=' "$F")"
check "set keeps the other keys" "on" "$(config_env_get "$F" notifications)"

fresh
config_env_get "$F" notifications >/dev/null; check "missing file: exit 1" "1" "$?"
check "missing file: nothing printed" "" "$(config_env_get "$F" notifications)"
printf 'language=es\n' > "$F"
config_env_get "$F" notifications >/dev/null; check "no such line: exit 1" "1" "$?"

printf 'notifications=on\nlanguage=es\nnotifications=off\n' > "$F"
check "repeated line: the last wins" "off" "$(config_env_get "$F" notifications)"
config_env_set "$F" notifications on
check "set leaves one line of the key" "1" "$(grep -c '^notifications=' "$F")"

printf 'language=\n' > "$F"
config_env_get "$F" language >/dev/null; check "empty value: found" "0" "$?"
check "empty value reads empty" "" "$(config_env_get "$F" language)"
printf 'language=a=b\n' > "$F"
check "a value keeps its own =" "a=b" "$(config_env_get "$F" language)"
printf ' language=es\nexport tiering=default\n' > "$F"
config_env_get "$F" language >/dev/null; check "a key counts only at column 0" "1" "$?"
config_env_get "$F" tiering >/dev/null; check "an export line is not the key" "1" "$?"
printf 'languages=xx\nlanguage=es\n' > "$F"
check "a longer key is another key" "es" "$(config_env_get "$F" language)"

echo "--- 2. data, never code ---------------------------------------------------"
fresh
# shellcheck disable=SC2016 # the code must reach the file unexpanded
printf 'notifications=$(touch %s/pwned)\nlanguage=`touch %s/pwned2`\ntiering="default"\n' "$TMP" "$TMP" > "$F"
check "\$(…) reads verbatim" "\$(touch $TMP/pwned)" "$(config_env_get "$F" notifications)"
check "backticks read verbatim" "\`touch $TMP/pwned2\`" "$(config_env_get "$F" language)"
check "quotes are part of the value" '"default"' "$(config_env_get "$F" tiering)"
config_env_set "$F" gitignored true
[[ ! -e "$TMP/pwned" && ! -e "$TMP/pwned2" ]] && ok "nothing ran on read or write" || no "a value was executed"
check "set copies a code-looking line as is" "\$(touch $TMP/pwned)" "$(config_env_get "$F" notifications)"

echo "--- 3. CRLF, line breaks, bad keys ----------------------------------------"
fresh
printf 'language=es\r\ntiering=default\r\n' > "$F"
check "CRLF: the CR is dropped" "es" "$(config_env_get "$F" language)"
config_env_set "$F" gitignored true
grep -q $'\r' "$F" && no "set left a CR" || ok "set rewrites without CRs"
check "CRLF: other keys kept" "default" "$(config_env_get "$F" tiering)"
printf 'language=es' > "$F"
check "no final newline: still read" "es" "$(config_env_get "$F" language)"
config_env_set "$F" tiering default
check "no final newline: kept on write" "es" "$(config_env_get "$F" language)"

fresh
printf '# a comment\nlanguage=es\n\nunknown=1\n' > "$F"
before="$(cat "$F")"
config_env_set "$F" "bad key" x; check "bad key refused" "1" "$?"
config_env_set "$F" "1abc" x; check "key starting with a digit refused" "1" "$?"
config_env_set "$F" language $'es\nnotifications=on'; check "value with a newline refused" "1" "$?"
config_env_set "$F" language $'es\r'; check "value with a CR refused" "1" "$?"
check "refused writes leave the file as it was" "$before" "$(cat "$F")"
config_env_get "$F" "a b" >/dev/null; check "bad key on read: exit 1" "1" "$?"
config_env_set "$F" tiering default
check "comments, blanks and unknown keys kept in order" $'# a comment\nlanguage=es\n\nunknown=1\ntiering=default' "$(cat "$F")"

echo "--- 4. the write -----------------------------------------------------------"
fresh
printf 'language=es\n' > "$F"; chmod 600 "$F"
config_env_set "$F" tiering default
check "mode kept" "600" "$(stat -f '%Lp' "$F" 2>/dev/null || stat -c '%a' "$F")"
check "no temp file left (only the empty lock file)" "" "$(ls -A "$TMP/a" | grep -v '^config.env$' | grep -v '^config.env.lock$')"

fresh
mkdir -p "$TMP/dots"
printf 'language=es\n' > "$TMP/dots/real.env"
ln -s "$TMP/dots/real.env" "$F"
config_env_set "$F" tiering default
[[ -L "$F" ]] && ok "a symlinked config stays a link" || no "the link was replaced"
check "the write lands where the link points" "default" "$(config_env_get "$TMP/dots/real.env" tiering)"
check "read through the link" "es" "$(config_env_get "$F" language)"

fresh
printf 'language=es\n' > "$TMP/a/l0"
for i in 1 2 3 4 5 6 7 8 9 10 11; do ln -s "$TMP/a/l$((i - 1))" "$TMP/a/l$i"; done
config_env_get "$TMP/a/l11" language >/dev/null; check "chain over ten links: read refused" "1" "$?"
config_env_set "$TMP/a/l11" language en; check "chain over ten links: write refused" "1" "$?"
check "chain over ten links: target untouched" "es" "$(config_env_get "$TMP/a/l0" language)"

fresh
mkdir -p "$TMP/a/ro"; printf 'language=es\n' > "$TMP/a/ro/config.env"; chmod 500 "$TMP/a/ro"
config_env_set "$TMP/a/ro/config.env" tiering default; check "read-only folder: exit 1" "1" "$?"
chmod 700 "$TMP/a/ro"
check "read-only folder: file untouched" "language=es" "$(cat "$TMP/a/ro/config.env")"
check "read-only folder: no temp left" "config.env" "$(ls -A "$TMP/a/ro" | grep -v '^config.env.lock$')"
mkdir -p "$TMP/a/dir.env"
config_env_set "$TMP/a/dir.env" tiering default; check "a folder in the file's place: exit 1" "1" "$?"
config_env_set "$TMP/a/new/sub/config.env" language es
check "missing folders are created" "es" "$(config_env_get "$TMP/a/new/sub/config.env" language)"

fresh
printf 'language=es\n' > "$F"
for round in 1 2 3 4 5; do
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if (( i % 2 )); then v=on; else v=off; fi
    config_env_set "$F" notifications "$v" &
  done
  wait
done
check "20 parallel writers: one line of the key" "1" "$(grep -c '^notifications=' "$F")"
case "$(config_env_get "$F" notifications)" in on|off) ok "20 parallel writers: a valid value" ;; *) no "20 parallel writers: value lost" ;; esac
check "20 parallel writers: the other key kept" "es" "$(config_env_get "$F" language)"
check "20 parallel writers: no temp left" "config.env config.env.lock" "$(ls -A "$TMP/a" | tr '\n' ' ' | sed 's/ $//')"

fresh
for i in 1 2 3 4 5 6 7 8 9 10; do
  rm -f "$F"
  config_env_set "$F" gitignored true & config_env_set "$F" language es & config_env_set "$F" tiering default & wait
  [[ "$(config_env_get "$F" gitignored)$(config_env_get "$F" language)$(config_env_get "$F" tiering)" == "trueesdefault" ]] || break
done
check "three parallel writers of different keys keep all three (10 rounds)" "10" "$i"
fresh
for i in $(seq 1 50); do
  rm -f "$F"
  config_env_set "$F" gitignored true & config_env_set "$F" language es & config_env_set "$F" tiering default & config_env_set "$F" agentCoauthorship no & wait
  [[ "$(grep -c = "$F")" == 4 ]] || break
done
check "four parallel writers of different keys keep all four (50 rounds)" "50" "$i"
( exec 9>>"$F.lock"; lockf -s 9 2>/dev/null || flock 9; exec sleep 30 ) & holder=$!
sleep 0.3; kill -9 "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
config_env_set "$F" language fr; check "a writer killed holding the lock does not block the next" "fr" "$(config_env_get "$F" language)"

echo "--- 5. an older config.json is ignored ---------------------------------------"
J="$TMP/r/.workflow-dev/config.json"
E="$TMP/r/.workflow-dev/config.env"
freshr() { rm -rf "$TMP/r"; mkdir -p "$TMP/r/.workflow-dev"; }
freshr; printf '{"gitignored": true, "agentCoauthorship": "yes", "tiering": "default"}\n' > "$J"; before="$(cat "$J")"
repo_config_get "$TMP/r" gitignored >/dev/null; check "config.json alone: no answer" "1" "$?"
repo_config_get "$TMP/r" agentCoauthorship >/dev/null; check "config.json alone: no co-authorship answer" "1" "$?"
[[ -e "$E" ]] && no "a read created config.env" || ok "a read creates nothing"
repo_config_set "$TMP/r" language es
check "set writes only its key" "language=es" "$(cat "$E")"
check "config.json is left as it was" "$before" "$(cat "$J")"

echo "--- 5a. hostile sizes stay linear ----------------------------------------"
freshr
{ printf 'tiering='; head -c 1000000 /dev/zero | tr '\0' a; printf '\r\n'; } > "$E"
start=$SECONDS; repo_config_get "$TMP/r" tiering >/dev/null; took=$((SECONDS - start))
[[ $took -le 2 ]] && ok "a 1 MB CRLF line is read in ${took}s" || no "a 1 MB line took ${took}s"

echo "--- 5b. a repo's config never follows a link out --------------------------"
VICTIM="$TMP/victim"
freshv() { freshr; rm -rf "$VICTIM"; mkdir -p "$VICTIM"; }
freshv; ln -s "$VICTIM/.zshenv" "$E"
repo_config_get "$TMP/r" language >/dev/null; check "dangling config.env link: get finds nothing" "1" "$?"
repo_config_set "$TMP/r" language es; check "dangling config.env link: set refused" "1" "$?"
[[ -e "$VICTIM/.zshenv" ]] && no "set wrote through a dangling link" || ok "set never writes through a dangling link"
freshv; printf 'export PATH=/usr/bin\n' > "$VICTIM/.bashrc"; ln -s "$VICTIM/.bashrc" "$E"
repo_config_set "$TMP/r" language es; check "config.env linked to a real file: set refused" "1" "$?"
check "...and that file is untouched" "export PATH=/usr/bin" "$(cat "$VICTIM/.bashrc")"
repo_config_get "$TMP/r" language >/dev/null; check "config.env linked to a real file: get finds nothing" "1" "$?"
freshv; rm -rf "$TMP/r/.workflow-dev"; mkdir -p "$VICTIM/wd"; ln -s "$VICTIM/wd" "$TMP/r/.workflow-dev"
repo_config_set "$TMP/r" language es; check ".workflow-dev linked out: set refused" "1" "$?"
check ".workflow-dev linked out: nothing written there" "" "$(ls -A "$VICTIM/wd")"
freshv; ln -s "$VICTIM/.zshenv" "$E.lock"
repo_config_set "$TMP/r" language es; check "a lock file planted as a link: set refused" "1" "$?"
[[ -e "$VICTIM/.zshenv" ]] && no "the planted lock link created a file outside" || ok "the planted lock link creates nothing outside"
freshr; mkdir -p "$E.lock"
repo_config_set "$TMP/r" language es; check "a folder at the lock path: set refused, never unlocked" "1" "$?"
freshr; printf 'language=es\n' > "$TMP/r/real.env"; ln -s "$TMP/r/real.env" "$E"
repo_config_get "$TMP/r" language >/dev/null; check "even a link inside the repo is not followed" "1" "$?"

echo "--- 5c. a strict key is never read two ways ---------------------------------"
fresh
printf 'agentCoauthorship=no\nagentCoauthorship=yes\n' > "$F"
config_env_get "$F" agentCoauthorship >/dev/null; check "agentCoauthorship twice: missing, not the last line" "1" "$?"
printf 'language=es\nlanguage=en\n' > "$F"
check "another key twice: the last wins" "en" "$(config_env_get "$F" language)"
printf 'agentCoauthorship=no\nagentCoauthorship=yes\n' > "$F"
config_env_set "$F" agentCoauthorship no
check "set over a doubled strict key leaves one line" "no" "$(config_env_get "$F" agentCoauthorship)"

echo "--- 6. the CLI -------------------------------------------------------------"
freshr
check "cli get: missing prints nothing" "" "$(cd "$TMP/r" && PATH="$SYS" /bin/bash "$LIB" get language)"
( cd "$TMP/r" && PATH="$SYS" /bin/bash "$LIB" get language >/dev/null ); check "cli get: missing exits 1" "1" "$?"
( cd "$TMP/r" && PATH="$SYS" /bin/bash "$LIB" set language es ); check "cli set: exit 0" "0" "$?"
check "cli get prints the value" "es" "$(cd "$TMP/r" && PATH="$SYS" /bin/bash "$LIB" get language)"
rm -rf "$TMP/r/.workflow-dev"
( cd "$TMP/r" && PATH="$SYS" /bin/bash "$LIB" set gitignored true ); check "cli set creates the folder" "gitignored=true" "$(cat "$E")"
( cd "$TMP/r" && PATH="$SYS" /bin/bash "$LIB" set "bad key" x ); check "cli set: bad key exits 1" "1" "$?"
( cd "$TMP/r" && PATH="$SYS" /bin/bash "$LIB" frob 2>/dev/null ); check "cli: usage error exits 2" "2" "$?"

echo
echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]
