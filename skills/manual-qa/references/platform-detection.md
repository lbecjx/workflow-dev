# Platform detection — repo signals → platform

`SKILL.md` Step 2 uses this to decide which platform(s) a run should cover. A
repo can target several at once; the change's files narrow it further.

## Signals

| Signal in the repo | Platform |
|---|---|
| `package.json` + `.tsx`/`.jsx`/`.vue`/`.svelte`, or `index.html`/Vite/Next config | **Web** |
| `*.xcodeproj`, `*.xcworkspace`, `Package.swift`, `Info.plist`, Swift/Obj-C sources | **iOS** (native) |
| `AndroidManifest.xml`, `build.gradle`/`build.gradle.kts`, `app/src/main/`, Kotlin/Java sources | **Android** |
| `pubspec.yaml` (Flutter) | **Web + iOS + Android** (multi) |
| `react-native` in `package.json` | **iOS + Android** (multi) |
| `expo` dependency / `app.json` | **iOS + Android** (+ web) |
| Kotlin Multiplatform (`kotlin-multiplatform` / `commonMain`) | **iOS + Android** (multi) |
| plain server/CLI repo (no UI signals) | **none** — manual QA is not applicable for this change |

## Rules

- **A repo can be several platforms.** Run every detected platform that the
  change actually touches — don't pick one arbitrarily.
- **Narrow with the diff.** Use `git diff --name-only`: e.g. files under
  `src/components/` → web; paths under `ios/` or `*.swift` → iOS; paths under
  `android/` or `*.kt` in an Android module → Android.
- **Ambiguous → ask.** If the platform can't be determined confidently from the
  repo and the diff, ask via the ask-question tool rather than guessing.
- **Detected but no tooling → `NOT VERIFIED`.** If a platform is clearly in
  scope but the agent has no capable tool for it (see `tool-mapping.md`), report
  `NOT VERIFIED` for it and stop on it — never silently skip or fake a pass.
