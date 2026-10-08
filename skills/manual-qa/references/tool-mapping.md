# Tool mapping — capability → concrete tooling

`SKILL.md` is written against a **capability contract**, not any single tool.
This file maps that contract to the concrete browser/device tooling an agent
might have, per platform, so the skill stays portable across whatever browser
or device tooling a session has connected.

## The capability contract

Whatever tooling is used must provide these operations:

| Capability | Web | Mobile (iOS/Android) |
|---|---|---|
| navigate / launch | open a URL | launch the app by id |
| snapshot | accessibility tree | view hierarchy |
| interact | click, type/fill, key | tap, input text, key |
| assert | visible text/state | visible text/state |
| evidence | console, network, screenshot | device logs, screenshot |

Anything that provides all five for a platform is a valid driver. Choose by
capability, never by a hardcoded tool name.

## Web

| Tool | How it's reached | Ops it provides |
|---|---|---|
| **Playwright MCP** | MCP server (`@playwright/mcp`); tools named `mcp__playwright__*` | `browser_navigate`, `browser_snapshot` (accessibility tree), `browser_click`, `browser_type`/`browser_fill_form`, `browser_console_messages`, `browser_network_requests`, `browser_take_screenshot` |
| **playwright-cli** | `@playwright/cli` on `PATH` (shell) | `playwright-cli open/goto`, `--raw snapshot`, `click`, `type`, `screenshot` — token-efficient, headless |
| **Claude-in-Chrome** | Claude Code's Chrome extension (`mcp__claude-in-chrome__*`) | drives the user's real Chrome with its logins |

Preferred for a local app under test: Playwright MCP (stateful, good for
iterating) or playwright-cli (cheaper in tokens).

## iOS (native)

| Tool | How it's reached | Notes |
|---|---|---|
| **Maestro MCP** | `maestro mcp` (bundled in the Maestro CLI) | `list_devices`, `inspect_screen`, `run` (flows), `take_screenshot` — accessibility layer; same flow YAML as Android/web |
| **Appium MCP** | `appium-mcp` | cross-platform via XCUITest (iOS) / UiAutomator2 (Android) |
| **Mobilewright** | Playwright-style TS library | simulators **and real iOS devices** |
| **ios-simulator-mcp** | `ios-simulator-mcp` | wraps `xcrun simctl` + AppleScript; **coordinate** taps → less deterministic |

iOS simulators are **macOS-only**.

## Android

| Tool | How it's reached | Notes |
|---|---|---|
| **Maestro MCP** | `maestro mcp` | emulators **and real devices** (same YAML as iOS) |
| **adb + uiautomator** | `adb` on `PATH` (shell) — no MCP needed | `adb shell am start -n pkg/.Activity`, `adb shell input tap/text`, `adb exec-out uiautomator dump`, `adb exec-out screencap -p`, `adb logcat`, `adb shell screenrecord` |
| **Appium MCP / Mobilewright** | as above | cross-platform, real devices |

Android runs on any host OS (macOS/Linux/Windows) — no macOS constraint.

## Detecting capability at runtime

- **MCP tools** appear in the agent's tool catalog as `mcp__<server>__<tool>`,
  where `<server>` is whatever name the session configured. A server that is *configured but not connected* is
  **not** a capability — treat it as unavailable.
- **CLIs**: check availability before relying on one (`which playwright-cli`,
  `which adb`, `which maestro`).
- Nothing available for a detected platform → report `NOT VERIFIED` (see
  `SKILL.md` Step 3). Never fall back to a by-hand screenshot and call it a pass.

## Naming differences (why the skill must stay capability-based)

The same capability can carry a different tool name per session — e.g.
Playwright MCP's navigate is `mcp__playwright__browser_navigate` only when the
server was configured as `playwright`; under another server name the prefix
changes. Hardcoding one name breaks the others. Name the **operation**, then use whichever tool the catalog actually
offers.

This file covers browser and device tooling. The same rule for the non-browser
capabilities — running a command, reading or editing a file, searching, spawning
a sub-agent, asking the human, loading a skill — is mapped once, with the names
as examples rather than as the name, in `references/harness-tools.md` at the
plugin root (not this skill's own `references/`).
