# Screensaver — Build Plan

A macOS system screensaver (`.saver` bundle) that visualizes CPU usage on every
host Onyx is currently connected to as a slowly drifting 3D cube totem.

This document is the resume-point if the build is interrupted. It captures the
architecture, the design decisions, the phase breakdown, and the per-phase
acceptance criteria.

## Design summary

- **Activation:** selected as a third-party screensaver in System Settings
  (Settings → Lock Screen → Screen Saver). The OS launches it as a child of
  `legacyScreenSaver-arm64`.
- **Per-host visualization:** one "totem" per connected host. A totem is a
  vertical stack of horizontal rings of cubes; each ring is a time slice of CPU
  history with 4-fold rotational symmetry.
  - Newest sample is the top ring. Each frame older samples scroll downward.
  - Ring's cube count and radius is quantized from CPU% at that moment:
    `count = round(cpu/100 × 24)` clamped to `[4, 24]`, in multiples of 4.
  - ~40 rings → ~40 visible time slices.
- **Motion:** each totem has a 3D position and velocity, drifts slowly, rotates
  around its vertical axis. When two totems get within a threshold distance,
  apply mutual repulsion to their velocities (soft, no hard collisions).
- **Colors:** each host's totem uses a distinct color derived from the host's
  accent. Localhost defaults to the app accent.
- **Idle state:** when the stream file is missing or stale, show an empty
  starscape (or a single dim totem with idle pattern) — never a black screen.

## IPC — the shared stream file

Onyx (app) and the screensaver bundle are separate processes. They communicate
via a single JSON file in the Onyx Application Support directory:

```
~/Library/Application Support/Onyx/cpu-stream.json
```

The screensaver also writes a sentinel to the same directory so we can detect
whether anyone is reading (optional, for future "pause polling when idle").

### File format

```json
{
  "updatedAt": 1735507200.123,
  "hosts": [
    {
      "hostID": "localhost",
      "label": "localhost",
      "color": "#FF8800",
      "samples": [
        { "t": 1735507140.0, "cpu": 12.5 },
        { "t": 1735507145.0, "cpu": 18.3 }
      ]
    }
  ]
}
```

- `samples` is capped at ~120 entries per host (about 10 min @ 5s polling).
- Writes are atomic (write to temp file then rename) to avoid torn reads.
- File is rewritten on every MonitorManager sample tick (≈1s or 5s).

## Build target

macOS screensavers are `NSBundle` plugins with a `.saver` extension and a
`NSPrincipalClass` of an `NSView` (typically `ScreenSaverView`) subclass.
SPM does not directly produce `.saver` bundles, so we ship a build script.

Layout:

```
OnyxScreenSaver/
  Sources/
    OnyxScreenSaverView.swift     # ScreenSaverView subclass, root of the saver
    SculptureScene.swift          # SceneKit scene manager (camera, lights, root)
    HostTotem.swift               # one totem (SCNNode), grows/shrinks per CPU
    Motion.swift                  # drift + repulsion math
    CPUStreamReader.swift         # tails the JSON file
    StreamModels.swift            # Codable for the stream file
  Resources/
    Info.plist                    # NSPrincipalClass = OnyxScreenSaverView
  build.sh                        # swiftc → dylib → .saver bundle → install
```

`build.sh` compiles the Swift sources into a dynamic library, assembles the
`.saver` bundle (`Contents/MacOS/OnyxScreenSaver` + `Contents/Info.plist`), and
installs to `~/Library/Screen Savers/Onyx.saver`. macOS picks it up on the next
System Settings refresh.

The main `swift build` is untouched; the screensaver is built via
`./OnyxScreenSaver/build.sh`.

## Phase breakdown

Each phase ends in a working state and a commit.

### Phase 1 — Bundle skeleton + install loop [task #24]

Goal: prove the build + install flow works end-to-end.

- [ ] Create `OnyxScreenSaver/` with stub Swift source, Info.plist, build.sh.
- [ ] Stub `OnyxScreenSaverView` subclass that renders a slowly rotating cube
      against a dark background (placeholder).
- [ ] `build.sh` compiles a dylib, builds the `.saver` bundle, installs to
      `~/Library/Screen Savers/Onyx.saver`.
- [ ] Verify the saver appears in System Settings → Screen Saver and previews.

Acceptance: user can select "Onyx" in Screen Saver picker, see a moving cube.

### Phase 2 — Totem renderer w/ mock data [task #25]

Goal: get the visual right before adding real data.

- [ ] `SculptureScene` sets up SceneKit scene: camera, ambient + directional
      light, dark background.
- [ ] `HostTotem` builds the stacked rings from an array of CPU samples.
- [ ] Inject a fake stream (sine-wave CPU per host, 3 mock hosts).
- [ ] Verify rings appear, scroll downward as new samples come, look good.

Acceptance: 3 totems visible, sine-wave CPU produces visible scrolling rings.

### Phase 3 — Onyx CPU stream publisher [task #26]

Goal: make Onyx publish the data file.

- [ ] New service `Services/CPUStreamPublisher.swift` (stateless writer).
- [ ] `MonitorManager` calls publisher on each successful sample append.
- [ ] Publisher buffers per-host samples (cap 120), atomic-writes
      `cpu-stream.json` no faster than every ~500ms (coalesced).
- [ ] Color resolved from `HostConfig` accent or default.
- [ ] Tests for: file written, samples capped, atomic rename, idempotent reset.

Acceptance: while Onyx is running, `cpu-stream.json` is updated continuously
with realistic values from every connected host.

### Phase 4 — Screensaver reads live stream [task #27]

Goal: replace mock data with the real file.

- [ ] `CPUStreamReader` polls the file every 500ms (mtime check first).
- [ ] On change, decode and pass per-host arrays to `SculptureScene`.
- [ ] Scene adds/removes totems as hosts come and go.
- [ ] If file missing or older than 30s → show idle state (no totems +
      subtle "Waiting for Onyx" hint).

Acceptance: launch Onyx, see CPU graph appear; quit Onyx, see idle state.

### Phase 5 — Motion + repulsion [task #28]

Goal: totems wander without overlapping.

- [ ] Each totem has `position` + `velocity` in scene units.
- [ ] Per-frame: integrate position, slow Y-axis rotation.
- [ ] Per-frame: for each pair, if center distance < repulsionRadius, apply
      mutual force inversely proportional to distance.
- [ ] Soft bounds: when totem hits invisible box edge, reverse the relevant
      velocity component.

Acceptance: totems never visibly intersect, motion looks fluid not jittery.

### Phase 6 — Polish [task #29]

- [ ] Floating host label above each totem (3D billboard text).
- [ ] Per-host accent color driving cube material.
- [ ] Smooth ring scroll animation (interpolate between samples).
- [ ] Settings sheet (saver `configureSheet`) for ring count / drift speed.
- [ ] Idle-state visual.

## Open questions to address as we go

- **How do screensavers handle multi-monitor?** ScreenSaver framework spawns
  one instance per screen. We need each instance to read the same stream but
  vary its random seed so positions don't mirror.
- **Cost of SceneKit in a saver context** — verify it doesn't pin CPU when the
  user wants their machine *idle*. Cap to 30 fps; pause when not visible.
- **Code signing** — first-party use only for now, no notarization needed.
  Document the unsigned-saver allow-list step if macOS Gatekeeper complains.

## Resume hints

If picked up mid-phase:

1. Check `TaskList` for the in-progress task (#24–#29).
2. Read this doc + the in-progress task's description.
3. The phase's "Acceptance" line is the definition-of-done.
4. Each phase ends in a commit; `git log --oneline` shows what's already done.
