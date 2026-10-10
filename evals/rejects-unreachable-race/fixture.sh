#!/bin/bash
# Builds a scratch repo shaped like WD-0055: a per-session keeper script whose
# only caller runs `start` once, in sequence. The uncommitted change adds an
# "only one per session" check that is a plain check-then-act: two parallel
# starts could both pass it, but no caller makes parallel starts. `sleep`
# stands in for `caffeinate`, so the case runs on any OS.
set -e

git init -q
git config user.email "eval@example.com"
git config user.name "Eval Fixture"

mkdir -p .workflow-dev/context

# Phase 0 already answered, as in the init-* cases: the repo default
# (`"tiering": "default"`) keeps the model-tiering question out of the run, a
# question this case is not about. `.workflow-dev/` and `fixture.sh` are ignored
# so the only change under review is keeper.sh.
printf '{ "gitignored": true, "tiering": "default" }\n' > .workflow-dev/config.json
printf '.workflow-dev/\nfixture.sh\n' > .gitignore

cat > .workflow-dev/context/REPO.md <<'MD'
# REPO.md — eval fixture

## 1. What this is
A throwaway repo with two shell scripts. No build step, no test suite.
MD

cat > .workflow-dev/context/EVAL-0057.md <<'MD'
# EVAL-0057: one keeper per session
> Repo context: [REPO.md](./REPO.md)

## 1. Base Context

### 1.1 Story
**ID:** eval-fixture
**Status:** In Progress

**Acceptance Criteria:**
1. `keeper.sh start <session-id>` launches a keeper for the session and saves its PID.
2. Only one keeper per session: when the saved keeper is still running, `start` prints `running <pid>` and launches nothing.
3. `keeper.sh stop <session-id>` ends that keeper and removes the saved PID.

## 2. Working Memory

### Decisions
| Date | Decision | Decided by |
|------|----------|------------|
| 2026-01-01 | Validation mode for this story: once at the end | Human |
| 2026-01-01 | Manual QA for this story: no | Human |

## 3. Progress

### Implementation Status: In Progress

## 5. Plan

**Concurrency model:** one sequential caller: `session.sh` runs `start` once, then `stop`.
MD

# The only caller: one session, one sequential start, then the work, then stop.
cat > session.sh <<'SCRIPT'
#!/bin/bash
# Runs one session: starts its keeper once, does the work, stops the keeper.
set -e
SESSION_ID="${1:?session id}"
./keeper.sh start "$SESSION_ID"
echo "working in session $SESSION_ID"
./keeper.sh stop "$SESSION_ID"
SCRIPT
chmod +x session.sh

# Baseline keeper, already reviewed and committed: no "only one" check yet.
cat > keeper.sh <<'SCRIPT'
#!/bin/bash
# Keeps a stand-in process alive for a session.
ACTION="$1"
SESSION_ID="${2:?session id}"
PIDFILE="${TMPDIR:-/tmp}/keeper-$SESSION_ID.pid"

case "$ACTION" in
  start)
    sleep 300 >/dev/null 2>&1 &
    echo $! > "$PIDFILE"
    echo "started $!"
    ;;
  stop)
    [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null
    rm -f "$PIDFILE"
    echo "stopped"
    ;;
esac
SCRIPT
chmod +x keeper.sh

git add .gitignore session.sh keeper.sh
git commit -q -m "chore: baseline keeper"

# The diff under review — uncommitted on purpose, on a tracked file.
cat > keeper.sh <<'SCRIPT'
#!/bin/bash
# Keeps a stand-in process alive for a session. Only one per session.
ACTION="$1"
SESSION_ID="${2:?session id}"
PIDFILE="${TMPDIR:-/tmp}/keeper-$SESSION_ID.pid"

case "$ACTION" in
  start)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "running $(cat "$PIDFILE")"
      exit 0
    fi
    sleep 300 >/dev/null 2>&1 &
    echo $! > "$PIDFILE"
    echo "started $!"
    ;;
  stop)
    [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null
    rm -f "$PIDFILE"
    echo "stopped"
    ;;
esac
SCRIPT

echo "fixture ready"
