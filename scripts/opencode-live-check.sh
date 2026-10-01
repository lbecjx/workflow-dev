#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Is workflow-dev's OpenCode plugin actually running in the long-lived service?
#
# "Installed" is not the answer. A plugin that fails to load leaves only a WARN
# in a rotating log, the service caches that failure until it restarts,
# `opencode plugin list` lags the filesystem, and `opencode run --standalone`
# starts a private server that can pass while the service is stuck. So this
# never asks OpenCode what it thinks is loaded. It reads the evidence only a
# running plugin produces — `~/.workflow-dev/opencode-live.json`, written by
# `opencode/plugin.ts` from inside the service process — and checks it against
# the service that is running now and the file that is installed now.
#
#   opencode-live-check.sh
#       A verdict and its explanation for a human. Exit 0 only when live — the
#       shape an install or update step can check.
#   opencode-live-check.sh --status
#       One word, exit 0: live | stale | not-loaded | not-firing.
#   opencode-live-check.sh --message
#       The explanation when not live; nothing when live. For a caller that
#       only speaks up when something is wrong.
#
# Verdicts:
#   not-loaded  no evidence from the running service's pid — the service is not
#               running, the entry file is missing, no session has opened a
#               workflow-dev project since the service started, or the plugin
#               failed to load. The marker a private server would leave is not
#               written at all (the plugin only writes it as the service), so a
#               standalone run can never make this read as live.
#   stale       loaded, but the installed file's bytes differ from the ones the
#               service loaded — it is still running the old version.
#   not-firing  loaded from the current file, but the tool-catalog notice has
#               not gone out yet.
#   live        all of the above hold.
#
# The hash must match the plugin's own formula exactly: sha256 of the file's raw
# bytes, lowercase hex. Change one side and every check reads as stale.
#
# Test seams (the real values are the defaults): WD_OPENCODE_PLUGIN is the
# installed entry file, WD_OPENCODE_SERVICE_PID the service's pid ("" = not
# running) — set, it replaces the `pgrep` lookup entirely. The marker is always
# read from $HOME.
#
# Accepted residual: identity is pid + file hash. A restarted service that is
# handed the old pid back, and then fails to load the plugin, would match a
# leftover marker. Both coincidences are needed, and the hash is taken when the
# module is evaluated, so a changed file still reads as stale.

set -u

MODE="report"
case "${1:-}" in
  --status) MODE="status" ;;
  --message) MODE="message" ;;
esac

PLUGIN="${WD_OPENCODE_PLUGIN-$HOME/.config/opencode/plugins/workflow-dev.ts}"
MARKER="$HOME/.workflow-dev/opencode-live.json"

# One flat field from the marker. jq when present; the fallback relies on the
# marker being the single-line object the plugin writes.
field() {
  [ -f "$MARKER" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$1" '.[$k] // empty' "$MARKER" 2>/dev/null
  else
    sed -n "s/.*\"$1\":\"\{0,1\}\([^\",}]*\).*/\1/p" "$MARKER" | head -1
  fi
}

if [ "${WD_OPENCODE_SERVICE_PID+set}" = "set" ]; then
  SERVICE_PID="$WD_OPENCODE_SERVICE_PID"
else
  # `serve --service` is the long-lived service; `serve --stdio` is a private
  # server started by `opencode run`, which is exactly what must not count.
  # Anchored to the whole command line (`/…/opencode serve --service`, as `ps`
  # shows it on 2.0.20): a looser match also catches a shell or a grep whose
  # command merely mentions the text. Such a process must never be a candidate —
  # preferring the marker's pid among candidates would otherwise let a leftover
  # marker that happens to name one read as live.
  #
  # `ps`, not `pgrep`: BSD `pgrep` leaves out its own ancestors unless given
  # `-a` (which means something else on Linux), and when `resume` or `help` run
  # this from OpenCode's shell tool the service *is* an ancestor — so it was
  # never found, and the check reported a running service as not running.
  CANDIDATES="$(ps -U "$(id -u)" -o pid=,args= 2>/dev/null \
    | awk '$0 ~ /^ *[0-9]+ ([^ ]*\/)?opencode serve --service$/ { print $1 }')"
  MARKED="$(field pid)"
  SERVICE_PID=""
  if [ -n "$MARKED" ] && printf '%s\n' "$CANDIDATES" | grep -qx "$MARKED"; then
    SERVICE_PID="$MARKED"
  else
    SERVICE_PID="$(printf '%s\n' "$CANDIDATES" | head -1)"
  fi
fi

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    sha256sum "$1" | cut -d' ' -f1
  fi
}

VERDICT=""
TEXT=""
if [ -z "$SERVICE_PID" ]; then
  VERDICT="not-loaded"
  TEXT="OpenCode's background service is not running, so workflow-dev's OpenCode plugin is not active. Start it with \`opencode service start\`, open a session in a workflow-dev project, then run this check again."
elif [ ! -f "$PLUGIN" ]; then
  VERDICT="not-loaded"
  TEXT="workflow-dev's OpenCode plugin entry \`$PLUGIN\` does not exist, so the service cannot load it. Install it as the README's Installation section describes, then run \`opencode service restart\`."
elif [ "$(field pid)" != "$SERVICE_PID" ]; then
  VERDICT="not-loaded"
  TEXT="The running OpenCode service (pid $SERVICE_PID) has no record of loading workflow-dev's plugin. Either no session has opened a workflow-dev project since the service started, or the plugin failed to load — which OpenCode only logs as a warning. Open a session in a workflow-dev project and run this check again; if it still says this, run \`opencode service restart\`."
elif [ "$(field hash)" != "$(sha256_of "$PLUGIN")" ]; then
  VERDICT="stale"
  TEXT="workflow-dev's OpenCode plugin changed on disk after the running service (pid $SERVICE_PID) loaded it, so the service is still running the old version. Run \`opencode service restart\`."
elif [ -z "$(field firedAt)" ]; then
  VERDICT="not-firing"
  TEXT="workflow-dev's OpenCode plugin is loaded in the running service (pid $SERVICE_PID) from the current file, but its tool-catalog notice has not gone out yet. It goes out on a model call in a workflow-dev project; if one has happened and this persists, the plugin's context hook is not being called."
else
  VERDICT="live"
  TEXT="workflow-dev's OpenCode plugin is live: the running service (pid $SERVICE_PID) loaded the current file, and its tool-catalog notice went out at $(field firedAt)."
fi

case "$MODE" in
  status) echo "$VERDICT" ;;
  message) [ "$VERDICT" = "live" ] || echo "$TEXT" ;;
  report)
    echo "$VERDICT — $TEXT"
    [ "$VERDICT" = "live" ]
    ;;
esac
