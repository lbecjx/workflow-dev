#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Prints the content hash of the role registry
# (skills/setup-models/references/roles.md) — the one value that tells a
# current generated agent from a stale one.
#
# One script, two callers, deliberately (the hash-marker rule in REPO.md §4):
# /workflow-dev:setup-models embeds this value in every agent file it generates,
# and model-tiering-check.sh recomputes it to decide whether such a file is
# stale. If each computed it on its own they could drift, and the hook would
# then nag forever over a setup that is actually in sync — the same failure mode
# the diff-hash and message-hash markers already document.
#
# Usage: roles-hash.sh
# Output: one line, the hash. Exit 1 (message on stderr) if the registry can't
# be read — never an empty hash, which would silently match nothing.

set -u

# Resolve through symlinks: on OpenCode the plugin is reached via a symlinked
# skills directory, so a logical path would compute the wrong location.
HERE="$(cd -P "$(dirname "$0")" && pwd -P)"
ROLES="$HERE/../skills/setup-models/references/roles.md"

if [[ ! -r "$ROLES" ]]; then
  echo "roles-hash: cannot read the role registry at $ROLES" >&2
  exit 1
fi

# Same idiom as the diff/message markers (scripts/*-check.sh): shasum, first field.
shasum "$ROLES" | cut -d' ' -f1
