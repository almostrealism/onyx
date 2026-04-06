# Static analysis in Onyx

## Overview

Onyx uses [SwiftLint](https://github.com/realm/SwiftLint) for static analysis.
The configuration lives in [`.swiftlint.yml`](../.swiftlint.yml) at the repo
root, and is invoked through a small wrapper script:

```sh
scripts/lint.sh           # lint everything (warnings allowed, exits 0)
scripts/lint.sh --strict  # warnings cause non-zero exit (CI mode)
scripts/lint.sh --fix     # apply auto-fixes
```

The first invocation downloads a pinned SwiftLint binary release into
`.build/tools/swiftlint/<version>/swiftlint`. Subsequent runs reuse the
cached binary. If a `swiftlint` is already on `PATH` (e.g. from Homebrew),
the script uses that instead.

`swift build` does **not** run SwiftLint — see "Why no SwiftPM plugin"
below.

## Why no SwiftPM plugin

We tried two SwiftPM plugin packages:

- `https://github.com/realm/SwiftLint` (`SwiftLintBuildToolPlugin`)
- `https://github.com/SimplyDanny/SwiftLintPlugins` (binary-backed variant)

Both failed under Swift 6.1 / SwiftPM 6 with:

```
error: a prebuild command cannot use executables built from source,
       including executable target 'swiftlint'
```

This is a known SwiftPM limitation: build-tool plugins that use the
**prebuild** capability are forbidden from invoking any executable that
isn't a system tool, even when the executable is delivered as a binary
artifact bundle. Both available SwiftLint plugins use prebuild today, so
neither can be wired in.

When SwiftLint ships a `buildCommand`-based plugin we can revisit this and
add it to the `OnyxLib`, `Onyx`, and `OnyxMCP` targets.

In the meantime, the `scripts/lint.sh` wrapper provides:

- one-time, no-sudo install of a pinned SwiftLint version
- the same `.swiftlint.yml` everyone agrees on
- a single entry point for local dev and CI

## Rule philosophy

`.swiftlint.yml` enables roughly 35 opt-in rules that catch real issues
(dead branches, redundant initializations, missing `for ... where`,
preferring `isEmpty` over `count == 0`, etc.) and disables a handful of
noisy default rules:

| Disabled rule | Reason |
|---|---|
| `line_length` | Too noisy; rely on reviewer judgment. |
| `identifier_name`, `type_name` | Short names like `i`, `id`, `wv` are fine. |
| `nesting` | SwiftUI views nest deeply by nature. |
| `force_cast`, `force_try` | Used deliberately in a few places and in tests. |
| `function_parameter_count`, `function_body_length`, `cyclomatic_complexity` | Covered by `type_body_length` / `file_length` instead. |
| `trailing_comma` | We allow optional trailing commas. |
| `todo` | TODOs are tracked elsewhere. |

### File and type length limits

```yaml
file_length:
  warning: 1000
  error: 2000     # target: 1500 — see note below
type_body_length:
  warning: 500
  error: 1500     # target: 800 — see note below
```

The `file_length` warning is set at **1000 lines** and the `type_body_length`
warning at **500 lines**. Files / types that exceed these warn but do not
fail the lint pass.

The error thresholds were intentionally raised above the documented targets
of 1500 / 800 because three files currently exceed them and refactoring is
tracked separately:

| File / type | Lines | Notes |
|---|---|---|
| `Sources/OnyxLib/Managers/TerminalSessionManager.swift` | 1519 (file), 1054 (type) | pending split |
| `Sources/OnyxLib/App/AppState.swift` | 1367 (file), 971 (type) | pending split |
| `Sources/OnyxLib/Views/MonitorView.swift` | 1278 (file) | pending split |

Once those files are refactored, restore `file_length.error` to `1500` and
`type_body_length.error` to `800`.

## Adding exceptions

Use inline disables sparingly and always explain why:

```swift
// swiftlint:disable:next force_try
let payload = try! JSONEncoder().encode(value)  // input is a literal in tests
```

For broader scopes:

```swift
// swiftlint:disable type_body_length
final class BigType { ... }
// swiftlint:enable type_body_length
```

## Future work

### Periphery (dead-code detection)

[Periphery](https://github.com/peripheryapp/periphery) finds unused code
across SwiftPM targets. It is **not** integrated yet because:

- It needs a system install (Homebrew or a manual binary), which we did
  not want to add silently.
- Its SwiftPM plugin has the same prebuild limitation as SwiftLint.

Suggested manual usage once installed:

```sh
brew install peripheryapp/periphery/periphery
periphery scan --project Package.swift --schemes Onyx --targets OnyxLib Onyx OnyxMCP
```

### `unused_import`

`unused_import` requires SwiftLint's analyze mode (`swiftlint analyze`),
which in turn needs a SourceKit compilation database from `xcodebuild` or
`swift build --build-tests -Xswiftc -index-store-path …`. This is workable
but slow; it is listed under `analyzer_rules` in `.swiftlint.yml` so it
runs only when explicitly requested.

### CI: `-warnings-as-errors`

Once the warning count is comfortably at zero, add a CI workflow step:

```yaml
- name: Lint
  run: scripts/lint.sh --strict
- name: Build (warnings-as-errors)
  run: swift build -Xswiftc -warnings-as-errors
```

For now we deliberately do **not** pass `-warnings-as-errors` because the
codebase still has compiler warnings unrelated to lint rules.
