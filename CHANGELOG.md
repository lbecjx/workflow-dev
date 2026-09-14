<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Changelog

All notable changes to this plugin are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/), versioning follows
[Semantic Versioning](https://semver.org/).

## 1.0.1

- Corrected the React + TypeScript stack standard: plain typed function
  components are the recommended pattern, not `React.FC<Props>` — updated
  the rule, both code examples, and the anti-patterns table to match.
- Fixed the `PreCompact` hook to check every story file under
  `.workflow-dev/context/`, not just the first one found — with multiple
  story files present, an arbitrary pick could lack the Implementation
  Status line entirely, silently skipping the actual in-progress story.
- Fixed the same first-file issue in the `SessionStart` hook, and made its
  Plan-section check match any section number instead of assuming Plan is
  always section 5 — a story with an extra section before it shifts the
  number.

## 1.0.0

- Initial release.
