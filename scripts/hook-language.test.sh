#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for hook-language.sh. Every case runs from a throwaway project with a
# throwaway HOME, so the tester's own Claude Code `language` setting can never
# decide a result.
#
# What it pins:
#   - the source order: conversation → Claude Code setting → config.json → en;
#   - which transcript lines count as the human (typed prompts only);
#   - every bad input (missing, empty, malformed, oversized, crafted) passes to
#     the next source or lands on English — never an error, never raw text;
#   - every message exists in both languages and is safe inside a JSON string.
#
#   bash scripts/hook-language.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

if ! command -v jq >/dev/null 2>&1; then
  echo "  skip  jq isn't installed — the transcript and settings sources need it"
  exit 0
fi

# shellcheck source=hook-language.sh
source "$HERE/hook-language.sh"

PROJ="$TMP/proj"
export HOME="$TMP/home"
export TMPDIR="$TMP/tmpdir"
mkdir -p "$PROJ/.claude" "$PROJ/.workflow-dev" "$HOME/.claude" "$TMPDIR"

# A transcript line for one typed prompt, and the two shapes that must not count.
typed() { jq -cn --arg t "$1" '{type:"user",message:{role:"user",content:$t}}'; }
meta()  { jq -cn --arg t "$1" '{type:"user",isMeta:true,message:{role:"user",content:[{type:"text",text:$t}]}}'; }
toolr() { jq -cn --arg t "$1" '{type:"user",message:{role:"user",content:[{type:"tool_result",content:$t}]}}'; }
reply() { jq -cn --arg t "$1" '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$t}]}}'; }
payload() { jq -cn --arg p "$1" '{tool_name:"Bash",transcript_path:$p,tool_input:{command:"git commit -m x"}}'; }

lang_of() { ( cd "$PROJ" && hook_language "$1" ); }
reset() { rm -f "$PROJ/.claude/"*.json "$PROJ/.workflow-dev/config.json" "$HOME/.claude/settings.json" "$TMP"/t*.jsonl; }
expect() { [[ "$2" == "$3" ]] && ok "$1" || no "$1 (got: $2, want: $3)"; }

ES_PROMPT="¿Puedes revisar el plan y decirme qué falta?"
EN_PROMPT="Can you check the plan and tell me what is missing?"

# --- 1: nothing anywhere → en ------------------------------------------------
reset
expect "no source at all → en" "$(lang_of '{}')" en
expect "no transcript_path in the payload → en" "$(lang_of '{"tool_input":{"command":"git commit"}}')" en

# --- 2: the conversation decides --------------------------------------------
reset
typed "$ES_PROMPT" > "$TMP/t1.jsonl"
expect "Spanish typed prompt → es" "$(lang_of "$(payload "$TMP/t1.jsonl")")" es
typed "$EN_PROMPT" > "$TMP/t2.jsonl"
expect "English typed prompt → en" "$(lang_of "$(payload "$TMP/t2.jsonl")")" en
typed "wd init-auto wd48 creando rama desde main." > "$TMP/t3.jsonl"
expect "short Spanish prompt with one function word → es" "$(lang_of "$(payload "$TMP/t3.jsonl")")" es

# Only typed prompts count: skill bodies (isMeta), tool results (also the answers
# to the ask-question tool) and the assistant's own text say nothing about the
# human, so a transcript with Spanish only there falls to the next source.
reset
{ meta "$ES_PROMPT"; toolr "$ES_PROMPT"; reply "$ES_PROMPT"; } > "$TMP/t4.jsonl"
expect "Spanish only in meta/tool/assistant lines → passes (en)" "$(lang_of "$(payload "$TMP/t4.jsonl")")" en
printf '{"language":"spanish"}' > "$HOME/.claude/settings.json"
expect "…and the next source then answers (setting → es)" "$(lang_of "$(payload "$TMP/t4.jsonl")")" es

# Tool output the harness logs as a prompt, code and paths are not the human.
reset
typed "<bash-input>que de la los para con</bash-input><bash-stdout>qué está también</bash-stdout> $EN_PROMPT" > "$TMP/t5.jsonl"
expect "bash-mode tags are dropped before scoring" "$(lang_of "$(payload "$TMP/t5.jsonl")")" en
typed "<command-name>/workflow-dev:plan</command-name><command-args>haz el plan para la story</command-args>" > "$TMP/t6.jsonl"
expect "slash command: its args are scored, the tags are not" "$(lang_of "$(payload "$TMP/t6.jsonl")")" es
typed 'run `que de la los para con` and /que/de/la/los' > "$TMP/t7.jsonl"
expect "code spans and paths are dropped (nothing left decides → en)" "$(lang_of "$(payload "$TMP/t7.jsonl")")" en

# A session that switched language follows the switch: the newest decided prompt wins.
reset
{ typed "$EN_PROMPT"; typed "$EN_PROMPT"; typed "$ES_PROMPT"; } > "$TMP/t8.jsonl"
expect "newest decided prompt wins (en, en, es → es)" "$(lang_of "$(payload "$TMP/t8.jsonl")")" es
{ typed "$ES_PROMPT"; typed "ok"; typed "use la API"; } > "$TMP/t9.jsonl"
expect "undecided newest prompts are skipped (es, ok, tie → es)" "$(lang_of "$(payload "$TMP/t9.jsonl")")" es

# --- 3: a bad transcript passes, never fails ---------------------------------
reset
printf '{"language":"es"}' > "$PROJ/.workflow-dev/config.json"
expect "nonexistent transcript → next source" "$(lang_of "$(payload "$TMP/nope.jsonl")")" es
: > "$TMP/t10.jsonl"
expect "empty transcript → next source" "$(lang_of "$(payload "$TMP/t10.jsonl")")" es
printf 'not json\n{"type":"user","message":\n%s\n' "$(typed "$EN_PROMPT")" > "$TMP/t11.jsonl"
expect "malformed lines are skipped, the good one still decides" "$(lang_of "$(payload "$TMP/t11.jsonl")")" en
mkdir -p "$TMP/t12.jsonl"
expect "transcript path is a directory → next source" "$(lang_of "$(payload "$TMP/t12.jsonl")")" es
rmdir "$TMP/t12.jsonl"

# Oversized: the prompt sits at the end of a big file, behind lines far longer
# than any line count would bound. The read stays inside the hook's 5 s budget.
reset
BIG="$(printf '%*s' 200000 '' | tr ' ' 'x')"
{ for _ in $(seq 1 30); do toolr "$BIG"; done; typed "$ES_PROMPT"; } > "$TMP/t13.jsonl"
START=$(date +%s)
GOT="$(lang_of "$(payload "$TMP/t13.jsonl")")"
ELAPSED=$(( $(date +%s) - START ))
expect "6 MB transcript, prompt at the end → es" "$GOT" es
[[ $ELAPSED -le 2 ]] && ok "6 MB transcript read in ${ELAPSED}s (≤ 2 s)" || no "6 MB transcript read in ${ELAPSED}s (> 2 s)"
{ typed "$ES_PROMPT"; for _ in $(seq 1 90); do toolr "$BIG"; done; } > "$TMP/t14.jsonl"
START=$(date +%s)
GOT="$(lang_of "$(payload "$TMP/t14.jsonl")")"
ELAPSED=$(( $(date +%s) - START ))
expect "prompt 18 MB back, before the 16 MB tail → passes (en)" "$GOT" en
[[ $ELAPSED -le 2 ]] && ok "18 MB transcript read in ${ELAPSED}s (≤ 2 s)" || no "18 MB transcript read in ${ELAPSED}s (> 2 s)"

# Big pastes inside the typed prompts themselves: the cleanup cost grows with
# the prompt, so each prompt is cut before it. 100 KB of prose took 8 s before
# the cut — past the hook's 5 s timeout, which would drop even the attribution
# deny. Several big pastes in a row must not add up either.
reset
PROSE="$(for _ in $(seq 1 2500); do printf 'la casa de la playa es muy bonita '; done)"
{ for _ in $(seq 1 8); do typed "$PROSE"; done; } > "$TMP/t16.jsonl"
START=$(date +%s)
GOT="$(lang_of "$(payload "$TMP/t16.jsonl")")"
ELAPSED=$(( $(date +%s) - START ))
expect "eight ~85 KB prose prompts → es" "$GOT" es
[[ $ELAPSED -le 2 ]] && ok "eight ~85 KB prose prompts read in ${ELAPSED}s (≤ 2 s)" || no "eight ~85 KB prose prompts read in ${ELAPSED}s (> 2 s)"
OPEN="$(for _ in $(seq 1 20000); do printf '<bash-stdout>x '; done)"
typed "$OPEN" > "$TMP/t17.jsonl"
START=$(date +%s)
lang_of "$(payload "$TMP/t17.jsonl")" >/dev/null
ELAPSED=$(( $(date +%s) - START ))
[[ $ELAPSED -le 2 ]] && ok "20000 unclosed tags read in ${ELAPSED}s (≤ 2 s)" || no "20000 unclosed tags read in ${ELAPSED}s (> 2 s)"
typed "$(printf 'me sale esto al correr los tests:\n%s' "$(for _ in $(seq 1 400); do printf 'Error: the module was not found in the path\n'; done)")" > "$TMP/t18.jsonl"
expect "Spanish first line + an English paste below → es (the first line is scored)" "$(lang_of "$(payload "$TMP/t18.jsonl")")" es
typed "$(printf '\n\n¿Qué falta para cerrar la story?\nThe tests are green.')" > "$TMP/t18b.jsonl"
expect "leading blank lines are skipped" "$(lang_of "$(payload "$TMP/t18b.jsonl")")" es

# A paste on the same line usually follows a colon; the words before it decide.
reset
{ typed "$ES_PROMPT"; typed "me sale esto: Error: Cannot find module react from the current directory"; } > "$TMP/t24.jsonl"
expect "Spanish words before a colon + English paste on the same line → es" "$(lang_of "$(payload "$TMP/t24.jsonl")")" es
{ typed "$ES_PROMPT"; typed "revisa esto: The function returns the wrong value when the input is empty and the user is not logged in"; } > "$TMP/t25.jsonl"
expect "revisa esto: <English sentence> → es" "$(lang_of "$(payload "$TMP/t25.jsonl")")" es
{ typed "$ES_PROMPT"; typed "Error: the build fails because the path is wrong and the tests do not run"; } > "$TMP/t26.jsonl"
expect "undecided words before the colon → the whole line decides (en)" "$(lang_of "$(payload "$TMP/t26.jsonl")")" en
{ typed "$EN_PROMPT"; typed "me puedes ayudar a arreglar el bug"; } > "$TMP/t27.jsonl"
expect "\"me\" is not an English vote any more → es" "$(lang_of "$(payload "$TMP/t27.jsonl")")" es

# Lines that are strings but not the human: a background agent's notification
# and the summary that opens a compacted session. Both are English.
reset
NOTE='<task-notification><task-id>x</task-id><status>completed</status><summary>Agent "hunt" finished</summary><result>The hunt found two issues in the script and they should be fixed before commit.</result></task-notification>'
{ typed "$ES_PROMPT"; jq -cn --arg t "$NOTE" '{type:"user",origin:{kind:"task-notification"},message:{role:"user",content:$t}}'; } > "$TMP/t19.jsonl"
expect "background-agent notification after a Spanish prompt → es" "$(lang_of "$(payload "$TMP/t19.jsonl")")" es
{ typed "$ES_PROMPT"; jq -cn --arg t "$NOTE" '{type:"user",message:{role:"user",content:$t}}'; } > "$TMP/t20.jsonl"
expect "…also with no origin field (its tags drop the body)" "$(lang_of "$(payload "$TMP/t20.jsonl")")" es
{ typed "$ES_PROMPT"; jq -cn '{type:"user",isCompactSummary:true,isVisibleInTranscriptOnly:true,message:{role:"user",content:"This session is being continued from a previous conversation that ran out of context. The summary below covers the earlier portion of the conversation."}}'; } > "$TMP/t21.jsonl"
expect "compaction summary after a Spanish prompt → es" "$(lang_of "$(payload "$TMP/t21.jsonl")")" es
{ jq -cn --arg t "$EN_PROMPT" '{type:"user",origin:"odd",message:{role:"user",content:$t}}'; jq -cn --arg t "$ES_PROMPT" '{type:"user",origin:{kind:"human"},message:{role:"user",content:$t}}'; } > "$TMP/t22.jsonl"
expect "a prompt marked origin human counts" "$(lang_of "$(payload "$TMP/t22.jsonl")")" es

# --- 4: Claude Code's language setting ---------------------------------------
reset
printf '{"language":"Spanish"}' > "$HOME/.claude/settings.json"
expect "user setting Spanish → es" "$(lang_of '{}')" es
printf '{"language":"ESPAÑOL"}' > "$HOME/.claude/settings.json"
expect "user setting ESPAÑOL → es" "$(lang_of '{}')" es
printf '{"language":"english"}' > "$PROJ/.claude/settings.json"
expect "project setting beats user setting" "$(lang_of '{}')" en
printf '{"language":"es-MX"}' > "$PROJ/.claude/settings.local.json"
expect "local setting beats project setting" "$(lang_of '{}')" es
reset
printf '{"language":"esperanto"}' > "$HOME/.claude/settings.json"
printf '{"language":"es"}' > "$PROJ/.workflow-dev/config.json"
expect "a language with no text stops the chain at en (config not read)" "$(lang_of '{}')" en
reset
printf '{"language":' > "$HOME/.claude/settings.json"
printf '{"language":"es"}' > "$PROJ/.workflow-dev/config.json"
expect "malformed settings → next source" "$(lang_of '{}')" es
printf '{"language":42}' > "$HOME/.claude/settings.json"
expect "non-string setting → next source" "$(lang_of '{}')" es
printf '{"env":{"language":"english"}}' > "$HOME/.claude/settings.json"
expect "a nested language key is not the setting → next source" "$(lang_of '{}')" es

# A hook runs in Claude Code's current directory, which follows a `cd`; the
# project's files are found through CLAUDE_PROJECT_DIR.
reset
mkdir -p "$PROJ/sub/dir"
printf '{"language":"spanish"}' > "$PROJ/.claude/settings.json"
GOT="$( cd "$PROJ/sub/dir" && CLAUDE_PROJECT_DIR="$PROJ" hook_language '{}' )"
expect "cwd in a subfolder, CLAUDE_PROJECT_DIR set → project setting read (es)" "$GOT" es
rm -f "$PROJ/.claude/settings.json"
printf '{"language":"es"}' > "$PROJ/.workflow-dev/config.json"
GOT="$( cd "$PROJ/sub/dir" && CLAUDE_PROJECT_DIR="$PROJ" hook_language '{}' )"
expect "…and the project config.json too (es)" "$GOT" es
GOT="$( cd "$PROJ/sub/dir" && CLAUDE_PROJECT_DIR="$TMP/gone" hook_language '{}' )"
expect "CLAUDE_PROJECT_DIR not a directory → the current directory (en)" "$GOT" en

# Claude Code passes the value as written, so any spelling of Spanish counts.
for v in "castellano" "Castilian" "es_ES" "Spanish (Latin America)" "Spanish - Mexico" "español latino" " spanish " "ES"; do
  expect "normalize_lang '$v' → es" "$(normalize_lang "$v")" es
done
for v in "english" "" "esperanto" "klingon" "latin"; do
  expect "normalize_lang '$v' → en" "$(normalize_lang "$v")" en
done

# Without jq nothing is parsed by hand: every file source passes, and English stays.
reset
printf '{"language":"spanish"}' > "$HOME/.claude/settings.json"
typed "$ES_PROMPT" > "$TMP/t23.jsonl"
NOJQ="$TMP/nojq"; mkdir -p "$NOJQ"
for t in cat grep head cut tail tr awk date; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NOJQ/$t"
done
# A subshell with a fresh command hash: jq ran above, so bash remembers its path
# and a PATH change alone would not hide it.
P23="$(payload "$TMP/t23.jsonl")"
GOT="$( cd "$PROJ" && hash -r && PATH="$NOJQ" && { command -v jq >/dev/null 2>&1 && echo skip || hook_language "$P23"; } )"
if [[ "$GOT" == "skip" ]]; then
  echo "  skip  could not hide jq for the no-jq case"
else
  expect "no jq → every file source passes → en" "$GOT" en
fi

# --- 5: config.json ----------------------------------------------------------
reset
printf '{"gitignored":true,"language":"es"}' > "$PROJ/.workflow-dev/config.json"
expect "config language es → es" "$(lang_of '{}')" es
printf '{"gitignored":true,"language":"en"}' > "$PROJ/.workflow-dev/config.json"
expect "config language en → en" "$(lang_of '{}')" en

# --- 6: crafted values only ever pick a built-in code ------------------------
reset
printf '%s' '{"language":"es\"}],\"x\":\"$(touch '"$TMP"'/pwned)"}' > "$HOME/.claude/settings.json"
GOT="$(lang_of '{}')"
[[ "$GOT" == "es" || "$GOT" == "en" ]] && ok "crafted setting → a fixed code ($GOT)" || no "crafted setting → a fixed code (got: $GOT)"
[[ ! -e "$TMP/pwned" ]] && ok "crafted setting runs nothing" || no "crafted setting runs nothing"
reset
typed '$(touch '"$TMP"'/pwned2) "}] que de la para' > "$TMP/t15.jsonl"
GOT="$(lang_of "$(payload "$TMP/t15.jsonl")")"
[[ "$GOT" == "es" || "$GOT" == "en" ]] && ok "crafted prompt → a fixed code ($GOT)" || no "crafted prompt → a fixed code (got: $GOT)"
[[ ! -e "$TMP/pwned2" ]] && ok "crafted prompt runs nothing" || no "crafted prompt runs nothing"

# --- 6b: the transcript scan has a hard time limit ---------------------------
# A timed-out PreToolUse hook does not block the call, so the scan must never
# hold the hook past its budget — not even when it hangs, and not even when the
# hang is a child process of its pipeline. Stand-in scan: a pipeline whose first
# stage sleeps far past the budget; the next source must answer, in time.
reset
printf '{"language":"es"}' > "$PROJ/.workflow-dev/config.json"
GOT="$( cd "$PROJ" && transcript_lang() { sleep 47 | cat; echo en; } && HOOK_LANG_BUDGET_TICKS=10 && START=$(date +%s) && r="$(hook_language '{}')" && printf '%s %s' "$r" $(( $(date +%s) - START )) )"
expect "a hanging scan is cut off and the next source answers (es)" "${GOT% *}" es
[[ "${GOT#* }" -le 2 ]] && ok "…within the budget (${GOT#* }s for a 0.5 s budget)" || no "…within the budget (took ${GOT#* }s)"
sleep 1
pgrep -f 'sleep 47' >/dev/null 2>&1 && no "the hung pipeline is not left running" || ok "the hung pipeline is not left running"
GOT="$( cd "$PROJ" && transcript_lang() { printf 'en'; } && START=$(date +%s) && r="$(hook_language '{}')" && printf '%s %s' "$r" $(( $(date +%s) - START )) )"
expect "a quick scan still answers (en, config not read)" "${GOT% *}" en
[[ "${GOT#* }" -le 1 ]] && ok "…at once" || no "…at once (took ${GOT#* }s)"
ls "$TMPDIR"/wd-hook-lang.* >/dev/null 2>&1 && no "no temp file left behind" || ok "no temp file left behind"

# --- 7: the message table ----------------------------------------------------
# Every code × key: present, its own text, safe inside a JSON string, and the
# names a reader must still recognize kept as they are.
for code in $HOOK_LANG_CODES; do
  for key in validate_deferred validate_unrecorded attribution_deny attribution_ask review_ask trust_note; do
    m="$(hook_msg "$code" "$key")"
    [[ -n "$m" ]] || { no "$key/$code is not empty"; continue; }
    printf '{"r":"%s"}' "$m" | jq -e . >/dev/null 2>&1 || no "$key/$code is JSON-safe"
    [[ "$code" == "en" || "$m" != "$(hook_msg en "$key")" ]] || no "$key/$code has its own text"
  done
  case "$(hook_msg "$code" attribution_deny)" in *"Part 12.3"*) ;; *) no "$code deny keeps the Part 12.3 reference" ;; esac
  case "$(hook_msg "$code" attribution_ask)" in *"Part 12.3"*) ;; *) no "$code wrapped-attribution ask keeps Part 12.3" ;; esac
  case "$(hook_msg "$code" review_ask)" in *"Part 12"*"git-message-mark-reviewed.sh"*) ;; *) no "$code review ask keeps Part 12 and the script name" ;; esac
  case "$(hook_msg "$code" validate_unrecorded)" in *"/workflow-dev:validate"*) ;; *) no "$code validate ask keeps the command" ;; esac
  # The trust note is a printf format: exactly one %s, no other % sequence.
  tn="$(hook_msg "$code" trust_note)"; rest="${tn/\%s/}"
  [[ "$tn" == *"%s"* && "$rest" != *"%"* ]] || no "$code trust_note has one %s and nothing else"
  ok "$code: every message present, distinct, JSON-safe, names kept"
done
for key in validate_deferred validate_unrecorded attribution_deny attribution_ask review_ask trust_note; do
  [[ "$(hook_msg xx "$key")" == "$(hook_msg en "$key")" ]] && ok "$key: unknown code → English" || no "$key: unknown code → English"
done
[[ -z "$(hook_msg es no_such_key)" ]] && ok "unknown key → nothing" || no "unknown key → nothing"

# --- 8: every language, end to end -------------------------------------------
# Each name a setting may carry, and each language's own writing in a prompt.
expect_names() { local want="$1" v; shift; for v in "$@"; do expect "normalize_lang '$v' → $want" "$(normalize_lang "$v")" "$want"; done; }
expect_names fr "French" "français" "FRANÇAIS" "fr-CA"
expect_names pt "Portuguese" "português" "Brazilian Portuguese" "pt_BR"
expect_names de "German" "Deutsch" "de-AT"
expect_names it "Italian" "italiano" "it_IT"
expect_names zh "Chinese" "中文" "简体中文" "zh-TW" "Mandarin"
expect_names ja "Japanese" "日本語" "ja_JP" "jp"
expect_names ko "Korean" "한국어" "ko-KR"
expect_names ru "Russian" "русский" "Русский" "ru_RU"

reset
lang_case() {
  typed "$2" > "$TMP/l.jsonl"
  expect "$3" "$(lang_of "$(payload "$TMP/l.jsonl")")" "$1"
}
lang_case fr "Peux-tu vérifier le plan et me dire ce qui manque pour la story ?" "French prompt → fr"
lang_case pt "Você pode revisar o plano e me dizer o que falta para terminar isso?" "Portuguese prompt → pt"
lang_case de "Kannst du bitte den Plan prüfen und mir sagen, was noch fehlt?" "German prompt → de"
lang_case it "Puoi controllare il piano e dirmi che cosa manca per finire la story?" "Italian prompt → it"
lang_case zh "你能检查一下计划，告诉我还缺什么吗？" "Chinese prompt → zh"
lang_case ja "計画を確認して、足りないものを教えてください。" "Japanese prompt → ja"
lang_case ko "계획을 확인하고 무엇이 빠졌는지 알려 주세요." "Korean prompt → ko"
lang_case ru "Проверь план и скажи, чего не хватает." "Russian prompt → ru"
lang_case es "la casa de la playa es muy bonita" "Spanish with words French shares → es"
# Short or mixed prompts that once flipped a session to the wrong language
# (story-end verify): they must not decide for a language they are not in.
for p in "no" "no, use main" "same as before" "do it as before" "no anda" "no, así no"; do
  { typed "$EN_PROMPT"; typed "$p"; } > "$TMP/l.jsonl"
  got="$(lang_of "$(payload "$TMP/l.jsonl")")"
  [[ "$got" == "en" || "$got" == "es" ]] && ok "'$p' after English → not another language ($got)" || no "'$p' after English → $got"
done
{ typed "$ES_PROMPT"; typed "no anda"; } > "$TMP/l.jsonl"
expect "'no anda' after Spanish → es (never pt)" "$(lang_of "$(payload "$TMP/l.jsonl")")" es
for p in "translate Save as 保存 in the ja locale" "fix the Привет string in ru.json" "add 한국어 to the language picker" "show 日本語 in the picker please"; do
  { typed "$EN_PROMPT"; typed "$p"; } > "$TMP/l.jsonl"
  expect "English naming a few non-Latin characters → en: $p" "$(lang_of "$(payload "$TMP/l.jsonl")")" en
done
lang_case ja "この commit を確認してください" "Japanese with an English term → ja"
lang_case ru "Сделай git commit и проверь тесты" "Russian with an English command → ru"
lang_case en "Can you check whether the 日本 build passes?" "English with two Han characters → en"

# The hooks print the right language, still as valid JSON. The review ask needs
# a workflow-dev project and a message the hook can read.
mkdir -p "$PROJ/.workflow-dev/context"
payload() { jq -cn --arg p "$1" '{tool_name:"Bash",transcript_path:$p,tool_input:{command:"git commit -m \"Add a thing\""}}'; }
for pair in "fr:Peux-tu vérifier le plan et me dire ce qui manque ?" "ja:計画を確認して、足りないものを教えてください。" "ru:Проверь план и скажи, чего не хватает."; do
  code="${pair%%:*}"; typed "${pair#*:}" > "$TMP/h.jsonl"
  out="$( cd "$PROJ" && printf '%s' "$(payload "$TMP/h.jsonl")" | bash "$HERE/pre-commit-message-check.sh" )"
  case "$out" in
    *'"permissionDecision":"ask"'*"$(hook_msg "$code" review_ask)"*) ok "message hook speaks $code" ;;
    *) no "message hook speaks $code (got: $out)" ;;
  esac
  printf '%s' "$out" | jq -e . >/dev/null 2>&1 && ok "…as valid JSON ($code)" || no "…as valid JSON ($code)"
done

echo
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
