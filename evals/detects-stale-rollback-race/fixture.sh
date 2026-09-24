#!/bin/bash
# Builds a scratch repo whose only uncommitted change is a handler with a
# real, previously-found bug: a rollback that restores a status value read
# before a forward write, instead of whatever a concurrent caller left it
# as. Isolated and simplified from the actual fix in local-backlog's
# idle_server.py/_handle_archive (2026-09-23) — this fixture doesn't
# depend on that repo so the eval stays self-contained.
set -e

git init -q
git config user.email "eval@example.com"
git config user.name "Eval Fixture"

# Baseline, already reviewed and committed — out of scope for this diff.
cat > update_status.sh <<'SCRIPT'
#!/bin/bash
# Stand-in for a real status-update script: reads/writes the Status line,
# always succeeds. Callable concurrently for the same file by design (a
# real caller here is a write endpoint on a local server).
STORY_FILE="$1"
NEW_STATUS="$2"
sed -i.bak "s/^Status:.*/Status: $NEW_STATUS/" "$STORY_FILE"
rm -f "$STORY_FILE.bak"
echo "Status updated to $NEW_STATUS"
SCRIPT
chmod +x update_status.sh

cat > story.txt <<'STORY'
Title: Example story
Status: Not Started
STORY

git add update_status.sh story.txt
git commit -q -m "chore: baseline story tracker"

# The actual diff under review — uncommitted on purpose.
cat > archive_handler.py <<'PYEOF'
import subprocess


def read_status(story_file):
    with open(story_file) as f:
        for line in f:
            if line.startswith("Status:"):
                return line.split(":", 1)[1].strip()
    return None


def handle_archive(story_file, board_args, update_status_script="./update_status.sh"):
    """Archives a story: sets Status to Done, then records it on a shared
    board file (the board_args command does that write). If the board
    write fails, rolls back Status to what it was before this request
    started."""
    old_status = read_status(story_file)

    if old_status == "Done":
        return {"status": 200, "result": "already done"}

    result = subprocess.run(
        [update_status_script, story_file, "Done"], capture_output=True, text=True
    )
    if result.returncode != 0:
        return {"status": 500, "error": result.stderr}

    board_result = subprocess.run(board_args, capture_output=True, text=True)
    if board_result.returncode != 0:
        # Roll back to the status this request saw when it started.
        subprocess.run(
            [update_status_script, story_file, old_status], capture_output=True, text=True
        )
        return {"status": 500, "error": "archiving failed, status rolled back"}

    return {"status": 200, "result": "archived"}
PYEOF

echo "fixture ready"
