# BabyMonitor

A native, privacy-first baby monitor for two older Apple devices on the same trusted Wi-Fi network:

- An **iPhone 8 running iOS 16.7.16** uses the Monitor role to capture video and one-way room audio, show a local preview, and host the local stream.
- A **jailbroken iPad Air 2 running iPadOS 15.8.x** uses the Viewer role to discover or pair with the iPhone and play the live video and audio natively.

The repository currently contains the Xcode template UI and test targets; capture, streaming, discovery, pairing, and playback are not implemented yet. The **Baby Monitor MVP** project in Linear is the source of truth for current requirements, milestones, issue status, and acceptance criteria.

## Product boundaries

- One universal SwiftUI app supports both iPhone and iPad with explicit Monitor and Viewer roles.
- The deployment target remains iOS/iPadOS 15.0 so the app runs on the iPad Air 2; the same build supports the iPhone 8 on iOS 16.7.16.
- Media stays on the local network. The MVP has no cloud relay, account, analytics, recording, or remote internet access.
- The iPad viewer is native. Browser playback is not required for the MVP.
- Discovery alone must not expose the stream; pairing or authenticated sessions are required.
- The iPhone 8 runs iOS 16.7.16 with palera1n in rootless mode and already has TrollStore Lite installed. TrollStore Lite installation depends on the jailbreak being active.
- The TrollStore Lite build uses only public Apple APIs but is built for physical-device `arm64` without Apple code signing or an Apple provisioning profile.
- The same universal IPA is installed on both jailbroken devices; Monitor and Viewer are runtime roles, not separate app targets or packages.
- The target live-video profile is 1080p at 15 FPS using hardware H.264, with a 720p fallback retained for evidence-based thermal or network recovery.
- Foreground-only operation is the baseline until physical-device testing proves a supported alternative. The MVP currently does not promise monitoring while the iPhone app is suspended, force-quit, or the device is locked.

## Current project settings

| Setting | Value |
| --- | --- |
| Xcode template | iOS App |
| Product name | `BabyMonitor` |
| Interface | SwiftUI |
| Language | Swift 5 |
| Storage | None |
| Unit tests | Swift Testing |
| UI tests | XCTest |
| Supported devices | iPhone and iPad |
| Minimum deployment | iOS/iPadOS 15.0 on the project, app, unit-test, and UI-test targets |
| TrollStore Lite signing | Apple signing disabled by the packaging script; TrollStore Lite handles installation on the jailbroken device |
| Bundle ID | `com.armaanbutt.BabyMonitor` |

Xcode can compile against its current SDK while producing an app whose minimum runtime is iOS/iPadOS 15. The deployment target does not downgrade the SDK; it makes newer APIs require availability checks and working fallbacks.

## TrollStore Lite IPA build and installation

The primary deliverable is `dist/BabyMonitor.ipa`. Build and validate it without AltStore, Sideloadly, an Apple ID, or an Apple development certificate:

```bash
./Scripts/build-trollstore-ipa.sh
```

The script:

- Builds the Release configuration with the physical `iphoneos` SDK and exactly the `arm64` architecture.
- Sets `CODE_SIGNING_ALLOWED=NO` and `CODE_SIGNING_REQUIRED=NO`.
- Verifies that `MinimumOSVersion` is no newer than iOS 16.7.16.
- Requires camera, microphone, and local-network usage descriptions in the built `Info.plist`.
- Rejects an embedded Apple provisioning profile.
- Audits a configured entitlements file and flags push notifications, iCloud, associated domains, and Sign in with Apple as provisioning-sensitive. If intended entitlements exist, a current `ldid` must be available so they can be preserved by fake-signing before packaging.
- Packages exactly one top-level app bundle as `Payload/BabyMonitor.app`.
- Extracts the finished IPA and revalidates its structure, archive integrity, permission metadata, and `arm64` executable.
- Writes `dist/BabyMonitor-validation.txt` with the checksum and results.

To install, transfer the same `BabyMonitor.ipa` to each device using AirDrop or another file-transfer method. On the iPhone, select **Open in TrollStore Lite**. On the jailbroken iPad, select **Open in TrollStore**.

After a full reboot, reactivate palera1n rootless mode if necessary before launching the app. TrollStore Lite apps on this setup depend on the jailbreak being active.

## Incremental device builds

Development is organized around installable checkpoints. Every checkpoint produces the same universal `dist/BabyMonitor.ipa`, reruns archive validation, and includes only the device behavior listed for that checkpoint.

After local validation succeeds, the build replaces `BabyMonitor.ipa` in the Google Drive folder **BabyMonitor App** through the connected Google Drive integration. Updating the existing file preserves one stable download link and Drive revision history. Failed or partially validated builds are never uploaded.

| Build | IPA behavior to verify |
| --- | --- |
| 0 — Universal baseline | The same IPA installs and launches on both jailbroken devices. |
| 1 — Role shell | Both devices can select, persist, and switch Monitor or Viewer roles while idle. |
| 2 — Monitor preview | The iPhone requests permissions only in Monitor mode and shows a stable 1080p preview with start/stop and diagnostics. |
| 3 — Video encode | The iPhone hardware-encodes a bounded 1080p/15 H.264 stream and reports bitrate, dropped frames, memory, and thermal state without networking. |
| 4 — Private connection | The iPhone advertises a local service; the iPad discovers it, pairs intentionally, and establishes an authenticated control connection without receiving media yet. |
| 5 — Live video | The paired iPad displays the 1080p/15 video stream with bounded latency and a selectable 720p fallback. |
| 6 — Live audio | One-way room audio is added and synchronized with video; interruptions and audio routes are visible and recoverable. |
| 7 — Release candidate | Reconnect, stop/revoke, Wi-Fi interruption, repeated lifecycle, and sustained thermal/memory tests pass on both devices. |

Do not begin the next checkpoint until the current IPA has been installed and its checklist has either passed or produced a recorded defect in Linear.

## Verify deployment settings

In Xcode, verify that:

- **Supported Destinations** contains both **iPhone** and **iPad**.
- **Minimum Deployments > iOS** is `15.0` for the app and test targets.
- The project-level iOS Deployment Target is `15.0` for Debug and Release.
- The resolved Targeted Device Family is `iPhone, iPad` / `1,2`.

Leave Background Modes and other capabilities off until an accepted design requires them. Add camera, microphone, and local-network privacy descriptions with the corresponding features so the text accurately describes the finished behavior.

## Planned architecture

Keep device roles and technical concerns separate even though they ship in one app:

```text
BabyMonitor/
├── App/                         # Role selection and shared app lifecycle
├── Features/Monitor/            # iPhone capture/server experience
├── Features/Viewer/             # iPad discovery/playback experience
├── Models/                      # Shared session and protocol models
├── Services/Capture/            # Camera and microphone capture
├── Services/Encoding/           # Bounded media encode/decode
├── Services/Networking/         # Listener, discovery, pairing, transport
└── Resources/
```

Create these folders only when they contain real code. Capture, encoding, networking, and playback logic should remain outside SwiftUI views.

## Physical-device verification

Simulators remain useful for UI and deterministic logic, but the following require the real target devices:

- Camera capture, microphone routing, and foreground lifecycle on the iPhone 8
- Native decode, rendering, and audio playback on the iPad Air 2
- Bonjour discovery, pairing, Wi-Fi interruption, and reconnect behavior across both devices
- End-to-end latency and audio/video synchronization
- Sustained CPU, memory, battery, and thermal behavior on both devices
- Installation and runtime behavior on both jailbroken devices, with each installer, jailbreak state, reboot behavior, and relevant tweaks recorded in the test results

## Repository workflow

The repository tracks project metadata, source, assets, tests, `README.md`, and `AGENTS.md`. It ignores per-user Xcode state, build products, derived data, local configuration, and secrets.

Useful checks:

```bash
git status --short
git diff --check
./Scripts/build-trollstore-ipa.sh
```

Review the Linear issue and acceptance criteria before starting each change, and review the Git diff and relevant build or test result before committing.

## Suggested next work

Resolve the measurable operating targets and native transport spike in Linear, then build a conservative foreground camera preview and capture lifecycle on the physical iPhone 8. The first end-to-end prototype should stream to native playback on the physical iPad Air 2 before production transport decisions are finalized.
