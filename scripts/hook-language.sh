#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# The one owner of "which language does this hook speak" and of the text the
# commit hooks put in a permission dialog. Sourced, like command-match.sh and
# marker-dir.sh, so both hooks share one resolver and one message table.
#
# Claude Code shows a hook's `permissionDecisionReason` verbatim. The skills
# follow the conversation's language (references/user-language.md), but a hook
# is a shell script that the model never sees before the dialog opens: an
# `additionalContext` beside an `ask` only reaches the model next to the tool
# result, after the human already answered. So the texts are written here ahead
# of time, and the script finds the language itself.
#
# `hook_language "$INPUT"` prints one code of HOOK_LANG_CODES and nothing else.
# It asks four sources in order; one that cannot answer passes to the next:
#   1. the conversation: the newest typed prompts in the payload's transcript
#   2. Claude Code's own `language` setting
#   3. `language` in .workflow-dev/config.json (init writes it)
#   4. English
# A source that does answer stops the chain, even with a language this file has
# no text for: the human said which language they want, so a lower source must
# not override it, and that answer falls to English.
#
# Nothing read from a file ever leaves this file. Every source is reduced to a
# fixed code before a caller sees it, so a crafted transcript or setting can only
# choose between built-in texts — it can never reach the JSON a hook prints or a
# shell.
#
# To add a language: add its code to HOOK_LANG_CODES, its names to
# `normalize_lang`, its words (or its script) to the transcript scorer, and one
# arm per key to `hook_msg`.

HOOK_LANG_CODES="en es fr pt de it zh ja ko ru"

# The two commit hooks run under a 5 s timeout (hooks/hooks.json), and one
# tool-result line in a transcript can be megabytes, so the read is bounded in
# bytes, not lines. An autonomous run can pile megabytes of tool output after
# the human's last prompt (2 MB missed it in a real run), and the parse is
# linear — 16 MB took 0.4 s — so the tail is generous. A run whose tail is all
# tool output simply passes to the next source.
HOOK_LANG_TAIL_BYTES=16000000
# How many typed prompts the scorer looks at, newest first.
HOOK_LANG_PROMPTS=5
# How much of each prompt is scored. jq's gsub costs grow with matches times
# length — a 100 KB pasted prompt took 8 s through the cleanup below, past the
# hook's timeout, and a hook that times out prints no decision at all, the
# attribution deny included. The opening of a prompt is where the human's own
# words are; a paste usually follows them ("me sale esto: Error: …"), so a short
# cut also keeps a pasted English log from outvoting them. 400 characters is
# some 60 words, plenty for the scorer.
HOOK_LANG_PROMPT_CHARS=400

# A free-form language name (a setting is not validated by Claude Code: any
# spelling reaches it) reduced to a code this file has text for. Lowercased with
# `tr` because Bash 3.2 (macOS) has no `${v,,}`; a pattern never relies on a
# non-ASCII letter being lowercased (`espa*ol`, `fran*ais`, `*усск*`), since a C
# locale leaves those bytes alone. Whitespace is dropped and names match
# anywhere in the value, so "Spanish (Latin America)", "español latino" and a
# padded " spanish" all count.
normalize_lang() {
  local v
  v="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "$v" in
    *spanish*|*espa*ol*|*castellano*|*castilian*|es|es-*|es_*) printf 'es' ;;
    *french*|*fran*ais*|fr|fr-*|fr_*) printf 'fr' ;;
    *portugu*|*brazil*|*brasil*|pt|pt-*|pt_*) printf 'pt' ;;
    *german*|*deutsch*|de|de-*|de_*) printf 'de' ;;
    *italian*|it|it-*|it_*) printf 'it' ;;
    *chinese*|*mandarin*|*中文*|*汉语*|*漢語*|*普通话*|zh|zh-*|zh_*) printf 'zh' ;;
    *japanese*|*日本語*|ja|ja-*|ja_*|jp) printf 'ja' ;;
    *korean*|*한국어*|*조선말*|ko|ko-*|ko_*) printf 'ko' ;;
    *russian*|*усск*|*УССК*|ru|ru-*|ru_*) printf 'ru' ;;
    *) printf 'en' ;;
  esac
}

# A top-level string `language` from a JSON file, or nothing (no file, no key,
# not a string, or not valid JSON). jq only: a hand-rolled grep could read a
# `language` nested anywhere, and when unsure this source passes.
json_language() {
  [[ -f "$1" && -r "$1" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r 'if type == "object" and (.language | type) == "string" then .language else empty end' "$1" 2>/dev/null | head -1
}

# Source 1. Prints one code, or nothing.
#
# A typed prompt is a `type: user` line whose content is a plain string and
# that is not `isMeta` (skill bodies are). Tool results, so also the answers
# given through the ask-question tool, are array content and never count. Some
# string lines are still not the human: a background agent's
# `<task-notification>` (`origin.kind` other than `human`) and the summary that
# opens a compacted session (`isCompactSummary`) are English whatever the human
# speaks, and either can be the newest line right before a commit. A line with
# no `origin` (older Claude Code) still counts.
# Inside a prompt, tool output the harness logs as a prompt (`<bash-stdout>`,
# `<local-command-stdout>`, …), code and paths say nothing about the human, so
# they are removed before scoring.
#
# Two jq passes on purpose: the first only selects and cuts each prompt to
# HOOK_LANG_PROMPT_CHARS, `tail` keeps the newest few, and only those reach the
# costly cleanup. Cleanup on every prompt of the tail made one big paste slow
# every later hook call.
#
# Scoring, per prompt: Chinese, Japanese, Korean and Russian are told apart by
# their script — kana means Japanese (it writes Han too), then Hangul, Han,
# Cyrillic — when that script outweighs every Latin-script vote. The Latin
# languages vote with their common words and their own accents. A language wins
# a prompt when it leads the runner-up by at least one vote and by a third of
# its own score: "creando rama desde main" (1 to 0) decides, "use la API" (a tie
# of `la` in three languages) does not. The newest decided prompt wins: that is
# the language the human writes in now, so a session that switched language
# follows the switch. No decided prompt → pass.
transcript_lang() {
  local path
  # Same extraction as pre-compact-check.sh (TRANSCRIPT_PATH) — keep them alike.
  path="$(printf '%s' "$1" | grep -o '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)"
  [[ -n "$path" && -f "$path" && -r "$path" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  # `fromjson?` drops the partial first line of the byte tail and any malformed
  # line. Each program is one single-quoted string: never put an apostrophe in it.
  # The cut can leave a tag open, so the cleanup also drops an unclosed one to
  # the end. Only the first line with letters is scored: that is where the
  # human writes, and a pasted log or error goes on the lines below it. On that
  # line, the words before a colon decide first (see the scorer).
  tail -c "$HOOK_LANG_TAIL_BYTES" "$path" 2>/dev/null \
    | jq -R -c --argjson max "$HOOK_LANG_PROMPT_CHARS" '
        fromjson?
        | select(type == "object" and .type == "user"
                 and (.isMeta // false) == false
                 and (.isCompactSummary // false) == false
                 and (.isVisibleInTranscriptOnly // false) == false
                 and (((.origin | if type == "object" then .kind else null end) // "human") == "human")
                 and (.message.content | type) == "string")
        | .message.content[0:$max]' 2>/dev/null \
    | tail -n "$HOOK_LANG_PROMPTS" \
    | jq -r '
        gsub("<(bash-input|bash-stdout|bash-stderr|local-command-stdout|local-command-stderr|local-command-caveat|system-reminder|task-notification|command-name|command-message)>.*?</\\1>"; " "; "p")
        | gsub("<(bash-input|bash-stdout|bash-stderr|local-command-stdout|local-command-stderr|local-command-caveat|system-reminder|task-notification)>.*$"; " "; "p")
        | gsub("```.*?(```|$)"; " "; "p")
        | gsub("`[^`]*`"; " ")
        | gsub("<[^>]*>"; " ")
        | gsub("[^[:space:]]*[/\\\\][^[:space:]]*"; " ")
        | [split("\n")[] | select(test("[[:alpha:]]"))] | (.[0] // "")' 2>/dev/null \
    | LC_ALL=C awk '
        function add(code, words,    n, i, w) {
          n = split(words, w, " ")
          for (i = 1; i <= n; i++) V[code SUBSEP w[i]] = 1
        }
        BEGIN {
          nl = split("en es fr pt de it", L, " ")
          add("en", "the and is are was were be to of you your what which who please this that these those it its with for on in from by can could do does did should would will not have has had how why when where there here an but if then just my i we they them")
          # Each list holds only words that are not also everyday English (or
          # Spanish, for the others): "no", "as", "do", "um", "come", "fare",
          # "die", "was", "non" each flipped a real prompt to the wrong language.
          add("es", "que de del el la los las un una por para con sin sobre entre desde hasta es está están esto este esta estos estas eso ese esa como cómo qué cuál cuando cuándo donde dónde pero porque también sí muy hay hacer haz hazlo puedes puedo quiero tengo necesito ya mi mis tu tus su sus se lo le les nos y al todo todos ahora luego después antes bien gracias dale sigue vamos")
          add("fr", "le la les un une des du de et est sont ce cette ces que qui quoi avec sans dans sur pas ne je tu il nous vous mais ou où comment pourquoi quand faire fais peux veux merci très aussi oui au aux")
          add("pt", "que de da dos das uma por para com sem é são está estão isso este esta como quando onde mas porque também sim muito tem fazer faz pode posso quero tenho preciso já meu minha seu sua você obrigado não ao os na")
          add("de", "der das und ist sind nicht ein eine einen mit für auf ich du wir sie wie warum wann wo aber oder auch bitte danke kannst machen mach noch schon zu im dem")
          add("it", "il lo la gli le un una che di del della per con senza è sono questo questa quando dove ma perché anche sì molto fai puoi posso voglio grazie ho hai")
        }
        # One code, or "" when no language clearly leads, for one piece of text.
        function decide(text,    t, s, kana, hangul, han, cyr, acc, ced, m, j, k, l, best, bl, second, latin) {
          t = text
          kana = gsub(/\343[\201-\203][\200-\277]/, "&", t)
          hangul = gsub(/(\352[\260-\277]|[\353\354][\200-\277]|\355[\200-\236])[\200-\277]/, "&", t)
          han = gsub(/(\344[\270-\277]|[\345-\350][\200-\277]|\351[\200-\276])[\200-\277]/, "&", t)
          cyr = gsub(/[\320\321][\200-\277]/, "&", t)
          t = tolower(t)
          for (k = 1; k <= nl; k++) s[L[k]] = 0
          s["es"] += gsub(/¿|¡|ñ/, "&", t)
          acc = gsub(/á|í|ó|ú/, "&", t); s["es"] += acc; s["pt"] += acc
          s["pt"] += gsub(/ã|õ/, "&", t)
          ced = gsub(/ç/, "&", t); s["fr"] += ced; s["pt"] += ced
          s["fr"] += gsub(/è|ê|à|ù|â|î|û|œ|ë/, "&", t)
          s["de"] += gsub(/ä|ö|ü|ß/, "&", t)
          s["it"] += gsub(/ì|ò/, "&", t)
          gsub(/[][(){}.,;:!?"=<>*#|+~^%$&@_0-9-]/, " ", t)
          m = split(t, word, " ")
          latin = 0
          for (j = 1; j <= m; j++) {
            if (word[j] ~ /[a-z]/) latin++
            for (k = 1; k <= nl; k++)
              if ((L[k] SUBSEP word[j]) in V) s[L[k]]++
          }
          best = 0; bl = ""; second = 0
          for (k = 1; k <= nl; k++) {
            l = L[k]
            if (s[l] > best) { second = best; best = s[l]; bl = l }
            else if (s[l] > second) second = s[l]
          }
          # A script wins only when it outweighs the Latin words around it: a
          # CJK character against a word, a Cyrillic letter against a third of
          # one. "add 한국어 to the language picker" stays English.
          if (kana >= 2 && kana >= latin) return "ja"
          if (hangul >= 2 && hangul >= latin) return "ko"
          if (han >= 2 && han >= latin) return "zh"
          if (cyr >= 3 && cyr >= 3 * latin) return "ru"
          if (best >= 1 && best - second >= 1 && best - second >= int((best + 2) / 3)) return bl
          return ""
        }
        { line[NR] = $0 }
        END {
          for (k = NR; k >= 1; k--) {
            # A paste on the same line usually follows a colon ("me sale esto:
            # Error: …"): the words before it are the human, so they decide
            # first, and the whole line only when they cannot.
            c = index(line[k], ":"); r = ""
            if (c > 1) r = decide(substr(line[k], 1, c - 1))
            if (r == "") r = decide(line[k])
            if (r != "") { print r; exit }
          }
        }'
}

# Where the project's own files live. A hook runs in Claude Code's current
# directory, which follows a `cd` into a subfolder; the project's settings and
# config sit at the directory the session started in, which Claude Code hands
# every hook as CLAUDE_PROJECT_DIR. Without it, the current directory.
project_dir() {
  if [[ -n "${CLAUDE_PROJECT_DIR:-}" && -d "${CLAUDE_PROJECT_DIR}" ]]; then
    printf '%s' "$CLAUDE_PROJECT_DIR"
  else
    printf '.'
  fi
}

# Source 2: Claude Code reads `language` from any settings file; the first one
# that sets it, in Claude Code's precedence, wins. Managed settings and
# `--settings` are invisible to a hook, so they are not consulted.
settings_lang() {
  local f v root
  root="$(project_dir)"
  for f in "$root/.claude/settings.local.json" "$root/.claude/settings.json" "${HOME:-}/.claude/settings.json"; do
    v="$(json_language "$f")"
    if [[ -n "$v" ]]; then normalize_lang "$v"; return 0; fi
  done
}

# Source 3: what init recorded for this project.
config_lang() {
  local v
  v="$(json_language "$(project_dir)/.workflow-dev/config.json")"
  [[ -n "$v" ]] && normalize_lang "$v"
  return 0
}

# Source 1 under a hard time limit. A PreToolUse hook that outlives its timeout
# does not block the call — Claude Code lets it run — so a slow language lookup
# would turn the attribution deny into a pass. The scan is bounded already
# (byte tail, cut prompts), but a slow disk or a loaded machine is not, so the
# scan gets HOOK_LANG_BUDGET_TICKS checks 50 ms apart (2 s) and, past it,
# passes to the next source.
#
# The scan runs as its own process group (`set -m`), so a kill reaches every
# process of its pipeline: a lone jq left holding the output open would keep
# the caller waiting just the same. Output goes through a private temp file for
# that reason too, never through a pipe the stragglers could hold.
HOOK_LANG_BUDGET_TICKS=40
transcript_lang_bounded() {
  local out pid n=0
  out="$(mktemp "${TMPDIR:-/tmp}/wd-hook-lang.XXXXXX" 2>/dev/null)" || return 0
  (
    set -m
    transcript_lang "$1" > "$out" 2>/dev/null &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
      if [[ $n -ge $HOOK_LANG_BUDGET_TICKS ]]; then
        kill -TERM -- "-$pid" 2>/dev/null
        : > "$out"
        break
      fi
      sleep 0.05
      n=$((n + 1))
    done
    wait "$pid" 2>/dev/null
  ) >/dev/null 2>&1
  head -c 2 "$out" 2>/dev/null
  rm -f "$out"
}

hook_language() {
  local code
  code="$(transcript_lang_bounded "$1")"
  [[ -n "$code" ]] || code="$(settings_lang)"
  [[ -n "$code" ]] || code="$(config_lang)"
  case " $HOOK_LANG_CODES " in
    *" $code "*) [[ -n "$code" ]] && printf '%s' "$code" || printf 'en' ;;
    *) printf 'en' ;;
  esac
}

# The text for one message key in one language. English is the fallback for
# any code, so a reason is never empty for a known key. Each text goes into a
# JSON string through printf %s: never put a double quote or a backslash in one.
# The English texts are the hooks' original wording, byte for byte.
#
# `trust_note` is a printf format with one %s, the reason the marker directory
# is not trusted; marker-dir.sh fills it and sanitizes the reason. It must hold
# no other % sequence.
hook_msg() {
  local code="$1" key="$2"
  case "$code:$key" in
    es:validate_deferred) printf '%s' "Validación diferida para este grupo de tareas, según lo previsto — se ejecutará una vez al final de la story." ;;
    es:validate_unrecorded) printf '%s' "Este proyecto usa los controles de calidad de workflow-dev. No hay un registro de /workflow-dev:validate que coincida con los cambios actuales — confirma que este commit se validó antes de aprobarlo, o apruébalo igual si omite validate a propósito." ;;
    es:attribution_deny) printf '%s' "Este commit/PR contiene atribución o coautoría de una IA, un agente o un LLM (validate Part 12.3 — regla estricta, sin excepciones). Todo commit y PR de aquí se atribuye solo a la persona. Quita la atribución y vuelve a ejecutarlo." ;;
    es:attribution_ask) printf '%s' "Este comando puede ser un commit/PR (va dentro de algo que el hook no puede leer) y contiene atribución o coautoría de una IA, un agente o un LLM (validate Part 12.3 — regla estricta). Si es un commit/PR, quita la atribución antes de ejecutarlo; todo commit y PR de aquí se atribuye solo a la persona." ;;
    es:review_ask) printf '%s' "Este mensaje de commit / descripción de PR no pasó la revisión de Git History Disclosure (validate Part 12 — formalidad, sin narrar incidentes de seguridad, sin exponer datos personales ni el flujo de trabajo interno). Confirma que se puede usar tal cual, o ejecuta la revisión y márcalo como revisado antes con git-message-mark-reviewed.sh." ;;
    es:trust_note) printf '%s' " (No se puede confiar en el directorio de marcadores: %s.)" ;;

    fr:validate_deferred) printf '%s' "Validation reportée pour ce groupe de tâches, comme prévu — elle sera exécutée une seule fois à la fin de la story." ;;
    fr:validate_unrecorded) printf '%s' "Ce projet utilise les contrôles qualité de workflow-dev. Aucun enregistrement /workflow-dev:validate ne correspond aux changements actuels — confirmez que ce commit a bien été validé avant de l'approuver, ou approuvez-le quand même s'il saute validate volontairement." ;;
    fr:attribution_deny) printf '%s' "Ce commit/PR contient une attribution ou une co-paternité IA/agent/LLM (validate Part 12.3 — règle stricte, sans exception). Ici, chaque commit et chaque PR est attribué à la personne seule. Retirez l'attribution et relancez." ;;
    fr:attribution_ask) printf '%s' "Cette commande est peut-être un commit/PR (elle est enveloppée dans quelque chose que le hook ne peut pas lire) et elle contient une attribution ou une co-paternité IA/agent/LLM (validate Part 12.3 — règle stricte). Si c'est un commit/PR, retirez l'attribution avant de l'exécuter ; ici, chaque commit et chaque PR est attribué à la personne seule." ;;
    fr:review_ask) printf '%s' "Ce message de commit / cette description de PR n'est pas passé par la revue Git History Disclosure (validate Part 12 — ton formel, pas de récit d'incident de sécurité, pas d'exposition de données personnelles ni du flux de travail interne). Confirmez qu'il peut être utilisé tel quel, ou lancez la revue et marquez-le comme revu avec git-message-mark-reviewed.sh." ;;
    fr:trust_note) printf '%s' " (Le répertoire des marqueurs n'est pas fiable : %s.)" ;;

    pt:validate_deferred) printf '%s' "Validação adiada para este grupo de tarefas, conforme previsto — será executada uma vez no fim da story." ;;
    pt:validate_unrecorded) printf '%s' "Este projeto usa os controles de qualidade do workflow-dev. Não há registro de /workflow-dev:validate que corresponda às mudanças atuais — confirme que este commit foi validado antes de aprová-lo, ou aprove mesmo assim se ele pula o validate de propósito." ;;
    pt:attribution_deny) printf '%s' "Este commit/PR contém atribuição ou coautoria de IA/agente/LLM (validate Part 12.3 — regra rígida, sem exceções). Aqui, todo commit e PR é atribuído só à pessoa. Remova a atribuição e execute de novo." ;;
    pt:attribution_ask) printf '%s' "Este comando pode ser um commit/PR (está dentro de algo que o hook não consegue ler) e contém atribuição ou coautoria de IA/agente/LLM (validate Part 12.3 — regra rígida). Se for um commit/PR, remova a atribuição antes de executá-lo; aqui, todo commit e PR é atribuído só à pessoa." ;;
    pt:review_ask) printf '%s' "Esta mensagem de commit / descrição de PR não passou pela revisão Git History Disclosure (validate Part 12 — formalidade, sem narrar incidentes de segurança, sem expor dados pessoais nem o fluxo de trabalho interno). Confirme que pode ser usada como está, ou rode a revisão e marque-a como revisada antes com git-message-mark-reviewed.sh." ;;
    pt:trust_note) printf '%s' " (Não é possível confiar no diretório de marcadores: %s.)" ;;

    de:validate_deferred) printf '%s' "Validierung für diese Aufgabengruppe wie geplant aufgeschoben — sie läuft einmal am Ende der Story." ;;
    de:validate_unrecorded) printf '%s' "Dieses Projekt nutzt die Qualitätsprüfungen von workflow-dev. Für die aktuellen Änderungen gibt es keinen passenden /workflow-dev:validate-Eintrag — bestätige vor dem Freigeben, dass dieser Commit validiert wurde, oder gib ihn trotzdem frei, wenn er validate absichtlich auslässt." ;;
    de:attribution_deny) printf '%s' "Dieser Commit/PR enthält eine KI-/Agenten-/LLM-Zuschreibung oder Co-Autorschaft (validate Part 12.3 — feste Regel, ohne Ausnahme). Jeder Commit und PR hier wird allein dem Menschen zugeschrieben. Entferne die Zuschreibung und führe ihn erneut aus." ;;
    de:attribution_ask) printf '%s' "Dieser Befehl ist vielleicht ein Commit/PR (er steckt in etwas, das der Hook nicht lesen kann) und enthält eine KI-/Agenten-/LLM-Zuschreibung oder Co-Autorschaft (validate Part 12.3 — feste Regel). Wenn es ein Commit/PR ist, entferne die Zuschreibung, bevor du ihn ausführst; jeder Commit und PR hier wird allein dem Menschen zugeschrieben." ;;
    de:review_ask) printf '%s' "Diese Commit-Nachricht / PR-Beschreibung hat das Git-History-Disclosure-Review nicht durchlaufen (validate Part 12 — formeller Ton, keine Schilderung von Sicherheitsvorfällen, keine Preisgabe persönlicher Daten oder interner Abläufe). Bestätige, dass sie so verwendet werden kann, oder führe das Review aus und markiere sie vorher mit git-message-mark-reviewed.sh als geprüft." ;;
    de:trust_note) printf '%s' " (Dem Marker-Verzeichnis kann nicht vertraut werden: %s.)" ;;

    it:validate_deferred) printf '%s' "Validazione rimandata per questo gruppo di attività, come previsto — verrà eseguita una sola volta alla fine della story." ;;
    it:validate_unrecorded) printf '%s' "Questo progetto usa i controlli di qualità di workflow-dev. Non c'è un registro di /workflow-dev:validate che corrisponda alle modifiche attuali — conferma che questo commit è stato validato prima di approvarlo, oppure approvalo comunque se salta validate di proposito." ;;
    it:attribution_deny) printf '%s' "Questo commit/PR contiene un'attribuzione o una coautorialità di IA/agente/LLM (validate Part 12.3 — regola rigida, senza eccezioni). Qui ogni commit e PR è attribuito solo alla persona. Rimuovi l'attribuzione e riesegui." ;;
    it:attribution_ask) printf '%s' "Questo comando potrebbe essere un commit/PR (è racchiuso in qualcosa che l'hook non riesce a leggere) e contiene un'attribuzione o una coautorialità di IA/agente/LLM (validate Part 12.3 — regola rigida). Se è un commit/PR, rimuovi l'attribuzione prima di eseguirlo; qui ogni commit e PR è attribuito solo alla persona." ;;
    it:review_ask) printf '%s' "Questo messaggio di commit / descrizione di PR non è passato dalla revisione Git History Disclosure (validate Part 12 — tono formale, nessun racconto di incidenti di sicurezza, nessuna esposizione di dati personali o del flusso di lavoro interno). Conferma che si può usare così com'è, oppure esegui la revisione e segnalo come revisionato prima con git-message-mark-reviewed.sh." ;;
    it:trust_note) printf '%s' " (La directory dei marcatori non è affidabile: %s.)" ;;

    zh:validate_deferred) printf '%s' "已按计划推迟此任务组的验证 — 将在 story 结束时统一运行一次。" ;;
    zh:validate_unrecorded) printf '%s' "此项目使用 workflow-dev 的质量检查。当前改动没有对应的 /workflow-dev:validate 记录 — 批准前请确认此 commit 已经验证；如果是有意跳过 validate，也可以直接批准。" ;;
    zh:attribution_deny) printf '%s' "此 commit/PR 含有 AI/智能体/LLM 署名或共同作者信息（validate Part 12.3 — 硬性规则，没有例外）。这里的每个 commit 和 PR 只归属于人本人。请删除署名后重新运行。" ;;
    zh:attribution_ask) printf '%s' "此命令可能是一个 commit/PR（它被包在 hook 无法读取的内容里），并且含有 AI/智能体/LLM 署名或共同作者信息（validate Part 12.3 — 硬性规则）。如果它是 commit/PR，请在运行前删除署名；这里的每个 commit 和 PR 只归属于人本人。" ;;
    zh:review_ask) printf '%s' "此 commit 信息 / PR 描述尚未通过 Git History Disclosure 审查（validate Part 12 — 正式语气，不叙述安全事件，不暴露个人信息或内部工作流程）。请确认它可以原样使用，或先运行审查并用 git-message-mark-reviewed.sh 将其标记为已审查。" ;;
    zh:trust_note) printf '%s' "（标记目录不可信：%s。）" ;;

    ja:validate_deferred) printf '%s' "計画どおり、このタスクグループの検証は延期されました — story の最後に一度だけ実行されます。" ;;
    ja:validate_unrecorded) printf '%s' "このプロジェクトは workflow-dev の品質チェックを使っています。現在の変更に一致する /workflow-dev:validate の記録がありません — 承認する前にこの commit が検証済みか確認してください。意図的に validate を省く場合は、そのまま承認してもかまいません。" ;;
    ja:attribution_deny) printf '%s' "この commit/PR には AI・エージェント・LLM による帰属表示または共同著者の記載が含まれています（validate Part 12.3 — 例外のない厳格なルール）。ここでは、すべての commit と PR は人間だけに帰属します。帰属表示を削除して再実行してください。" ;;
    ja:attribution_ask) printf '%s' "このコマンドは commit/PR かもしれません（hook が読めない形で包まれています）。また、AI・エージェント・LLM による帰属表示または共同著者の記載が含まれています（validate Part 12.3 — 厳格なルール）。commit/PR であれば、実行前に帰属表示を削除してください。ここでは、すべての commit と PR は人間だけに帰属します。" ;;
    ja:review_ask) printf '%s' "この commit メッセージ / PR 説明は Git History Disclosure のレビューを通っていません（validate Part 12 — 丁寧な文体、セキュリティインシデントの経緯を書かない、個人情報や内部の作業手順を出さない）。このまま使ってよいか確認するか、先にレビューを実行し、git-message-mark-reviewed.sh でレビュー済みにしてください。" ;;
    ja:trust_note) printf '%s' "（マーカーディレクトリは信頼できません: %s。）" ;;

    ko:validate_deferred) printf '%s' "계획대로 이 작업 그룹의 검증을 미뤘습니다 — story 마지막에 한 번 실행됩니다." ;;
    ko:validate_unrecorded) printf '%s' "이 프로젝트는 workflow-dev 품질 검사를 사용합니다. 현재 변경 사항과 일치하는 /workflow-dev:validate 기록이 없습니다 — 승인하기 전에 이 commit이 검증되었는지 확인하세요. 의도적으로 validate를 건너뛰는 경우라면 그대로 승인해도 됩니다." ;;
    ko:attribution_deny) printf '%s' "이 commit/PR에 AI/에이전트/LLM 귀속 표기 또는 공동 저자 표기가 있습니다 (validate Part 12.3 — 예외 없는 엄격한 규칙). 여기서는 모든 commit과 PR이 사람에게만 귀속됩니다. 귀속 표기를 지우고 다시 실행하세요." ;;
    ko:attribution_ask) printf '%s' "이 명령은 commit/PR일 수 있습니다 (hook이 읽을 수 없는 형태로 감싸져 있습니다). 또한 AI/에이전트/LLM 귀속 표기 또는 공동 저자 표기가 있습니다 (validate Part 12.3 — 엄격한 규칙). commit/PR이라면 실행하기 전에 귀속 표기를 지우세요. 여기서는 모든 commit과 PR이 사람에게만 귀속됩니다." ;;
    ko:review_ask) printf '%s' "이 commit 메시지 / PR 설명은 Git History Disclosure 검토를 거치지 않았습니다 (validate Part 12 — 격식 있는 어조, 보안 사고 경위 서술 금지, 개인 정보나 내부 작업 흐름 노출 금지). 그대로 써도 되는지 확인하거나, 먼저 검토를 실행하고 git-message-mark-reviewed.sh로 검토 완료 표시를 하세요." ;;
    ko:trust_note) printf '%s' " (마커 디렉터리를 신뢰할 수 없습니다: %s.)" ;;

    ru:validate_deferred) printf '%s' "Проверка этой группы задач отложена, как и планировалось, — она запустится один раз в конце story." ;;
    ru:validate_unrecorded) printf '%s' "В этом проекте используются проверки качества workflow-dev. Для текущих изменений нет подходящей записи /workflow-dev:validate — перед одобрением убедитесь, что этот commit прошёл проверку, или одобрите его всё равно, если validate пропущен намеренно." ;;
    ru:attribution_deny) printf '%s' "Этот commit/PR содержит указание авторства или соавторства ИИ/агента/LLM (validate Part 12.3 — жёсткое правило, без исключений). Здесь каждый commit и PR приписывается только человеку. Уберите указание авторства и запустите снова." ;;
    ru:attribution_ask) printf '%s' "Эта команда может быть commit/PR (она обёрнута во что-то, что hook не может прочитать) и содержит указание авторства или соавторства ИИ/агента/LLM (validate Part 12.3 — жёсткое правило). Если это commit/PR, уберите указание авторства перед запуском; здесь каждый commit и PR приписывается только человеку." ;;
    ru:review_ask) printf '%s' "Это сообщение commit / описание PR не прошло проверку Git History Disclosure (validate Part 12 — деловой тон, без описания инцидентов безопасности, без раскрытия личных данных или внутреннего порядка работы). Подтвердите, что его можно использовать как есть, или сначала запустите проверку и отметьте его как проверенное с помощью git-message-mark-reviewed.sh." ;;
    ru:trust_note) printf '%s' " (Каталогу маркеров нельзя доверять: %s.)" ;;

    *:validate_deferred) printf '%s' "Validation deferred for this task group, as planned — will run once at story end." ;;
    *:validate_unrecorded) printf '%s' "This project uses workflow-dev quality gates. No matching /workflow-dev:validate record found for the current changes — confirm this commit was actually validated before approving it, or approve anyway if this intentionally skips validate." ;;
    *:attribution_deny) printf '%s' "This commit/PR contains AI/agent/LLM attribution or co-authorship (validate Part 12.3 — hard rule, no exceptions). Every commit and PR here is attributed to the human alone. Remove the attribution and re-run." ;;
    *:attribution_ask) printf '%s' "This command may be a commit/PR (it is wrapped in something the hook cannot read) and it contains AI/agent/LLM attribution or co-authorship (validate Part 12.3 — hard rule). If it is a commit/PR, remove the attribution before running it; every commit and PR here is attributed to the human alone." ;;
    *:review_ask) printf '%s' "This commit message / PR description has not been through the Git History Disclosure review (validate Part 12 — formality, no security-incident narration, no personal or internal-workflow exposure). Confirm it is safe to use as-is, or run the check and mark it reviewed first with git-message-mark-reviewed.sh." ;;
    *:trust_note) printf '%s' " (The marker directory cannot be trusted: %s.)" ;;
  esac
}
