#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Generates the two QR codes `init` shows when the phone notices are set up
# (WD-0109): one to the ntfy app in each store, as text the agent pastes into
# the conversation. Kept for provenance only: the .txt files are committed, and
# neither CI nor any test runs this file, so the plugin never needs Node or a QR
# tool at runtime (macOS ships none).
#
#   qr-app-store.txt     https://apps.apple.com/us/app/ntfy/id1625396347
#   qr-google-play.txt   https://play.google.com/store/apps/details?id=io.heckel.ntfy
#
# Only public store links are drawn. The topic is never put in a QR: it is the
# one secret of the notices, so the human pastes or types it in the app.
#
# Each file is the code in Unicode half blocks with the link on a last line, for
# a terminal or a font that draws the blocks badly. On a dark theme the code
# shows inverted (light modules on dark), which phone cameras read too.
#
#   bash assets/make-qr-codes.sh     (needs npx; downloads qrcode 1.5.4 once)

set -eu

cd "$(dirname "$0")"
draw() { # draw <file> <url>
  npx --yes qrcode@1.5.4 -t utf8 -o "$1" "$2" >/dev/null
  # qrcode ends its last row without a newline.
  printf '\n%s\n' "$2" >> "$1"
}
draw qr-app-store.txt 'https://apps.apple.com/us/app/ntfy/id1625396347'
draw qr-google-play.txt 'https://play.google.com/store/apps/details?id=io.heckel.ntfy'
