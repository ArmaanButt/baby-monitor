# BabyMonitor

A native, privacy-first baby monitor for Apple devices on the same trusted Wi-Fi network:

- An **iPhone 8 running iOS 16.7.16** uses the Monitor role to capture video and one-way room audio, show a local preview, and host the local stream.
- A **jailbroken iPad Air 2 running iPadOS 15.8.x** uses the Viewer role to discover or pair with the iPhone and play the live video and audio natively.
- A **Mac running macOS 12 or later** uses the Mac Catalyst destination and opens in Viewer mode by default. Apple Silicon and Intel are build destinations.

The release-candidate app contains the universal role shell, Monitor permission onboarding, a bounded 1080p/15 camera preview, a two-frame hardware H.264 encoder, an on-device performance diagnostics harness, Bonjour discovery, intentional six-digit pairing, Keychain-backed peer trust, and an authenticated local control connection. H.264 video uses compact binary framing, per-session authenticated encryption, and bounded native playback on the Viewer. One-way 24 kHz mono room audio uses the same encrypted session with bounded capture, network, and playback queues plus visible interruption and route state. Both playback paths use the same source timestamps and a bounded 150 ms playout clock. The Viewer automatically reconnects with capped backoff and re-authenticates saved pairings after transient local-network loss. The Monitor exposes the 720p/15 fallback explicitly instead of lowering quality silently. The **Baby Monitor MVP** project in Linear is the source of truth for current requirements, milestones, issue status, and acceptance criteria.

## Product boundaries

- One SwiftUI app supports iPhone, iPad, and Mac Catalyst with explicit Monitor and Viewer roles.
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
| Supported devices | iPhone, iPad, and Mac (Catalyst) |
| Minimum deployment | iOS/iPadOS 15.0 on the project, app, unit-test, and UI-test targets |
| TrollStore Lite signing | Apple signing disabled by the packaging script; TrollStore Lite handles installation on the jailbroken device |
| Bundle ID | `com.armaanbutt.BabyMonitor` |

Xcode can compile against its current SDK while producing an app whose minimum runtime is iOS/iPadOS 15. The deployment target does not downgrade the SDK; it makes newer APIs require availability checks and working fallbacks.

## Mac Viewer

In Xcode, select the **BabyMonitor** scheme and **My Mac (Mac Catalyst)** destination. The Mac app opens in Viewer mode on first launch; a role selected later is remembered. The Viewer has a resizable window and uses the same discovery, six-digit pairing, encrypted video, and room audio as the iPad.

1. Start the Monitor on the iPhone and keep both devices on the same trusted Wi-Fi.
2. Open BabyMonitor on the Mac and click **Find a Monitor**. Allow local-network access if macOS requests it.
3. Select the iPhone and enter its six-digit pairing code.
4. Verify the picture is clear from the first frame and room audio plays. Keep the app open and the Mac awake.
5. Disconnect before using **Change Role**. Mac Monitor remains available as a secondary role and uses the system's default camera; physical camera/microphone validation is still required.

Viewing does not request camera or microphone permission. Saved pairings use Apple's Keychain. Catalyst requires a provisioned signing identity for Keychain access; an ad hoc signed app can show the UI but cannot save pairings. `Config/Mac.entitlements` applies only to Mac builds. The iOS/iPadOS IPA continues to be unsigned and has no provisioning profile.

With the project's existing Mac signing identity and a matching provisioning profile installed, build and validate the development archive:

```bash
./Scripts/build-mac-app.sh
```

The script produces `dist/BabyMonitor-Mac.zip` for Apple Silicon and Intel and validates its signature, Keychain entitlement, profile expiry, minimum OS, privacy descriptions, and extracted archive. It does not create or update Apple signing resources. This is a development build for Macs permitted by the profile; Developer ID distribution and notarization are not implemented. The profile expiry is recorded in `dist/BabyMonitor-Mac-validation.txt`; rebuild with a renewed profile before it expires. The current package and device checklist are recorded in [`MAC_VIEWER_CHECKPOINT.md`](MAC_VIEWER_CHECKPOINT.md).

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

The exact Build 7 physical-device acceptance steps are in [`RELEASE_CHECKLIST.md`](RELEASE_CHECKLIST.md).

## Verify deployment settings

In Xcode, verify that:

- **Supported Destinations** contains **iPhone**, **iPad**, and **Mac (Mac Catalyst)**.
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

### Performance checkpoint protocol

The diagnostics panel samples app memory, memory change and peak, thermal state, power state, and elapsed time once per second. Monitor mode also reports effective capture resolution and frame rate, captured and dropped frames, average capture callback work, and the deliberately one-frame capture buffer. Collection can be disabled from either role and that preference is saved; the app never writes video, audio, pairing material, or session credentials to diagnostics.

For the current capture-and-encode baseline:

1. Install this checkpoint's exact IPA on the iPhone 8 and confirm palera1n is active.
2. Open Monitor mode, expand **Physical test details**, record ambient conditions, leave connected viewers at zero, and note whether the phone is charging.
3. Start the 1080p preview and leave BabyMonitor visible for 10 minutes without changing its power conditions.
4. Confirm the effective resolution remains 1920×1080, observed rate remains near 15 FPS, the encoder reads **Hardware**, and the encode buffer never exceeds two frames. Note capture/encode drops, bitrate, encode timing, memory change/peak, and the worst thermal state.
5. Tap **Copy Test Snapshot** and paste the result into ARM-209 in Linear.

The Viewer panel samples device-level memory, thermal, power, and duration together with decode/render timing, video buffer depth, viewer drops, and audio underruns. Repeat the protocol on the iPad during Build 7 playback and attach that second snapshot before ARM-209 is closed.

## Repository workflow

The repository tracks project metadata, source, assets, tests, `README.md`, and `AGENTS.md`. It ignores per-user Xcode state, build products, derived data, local configuration, and secrets.

Useful checks:

```bash
git status --short
git diff --check
./Scripts/build-trollstore-ipa.sh
```

Review the Linear issue and acceptance criteria before starting each change, and review the Git diff and relevant build or test result before committing.

## Release gate

Install the validated Build 7 IPA on both target devices and complete [`RELEASE_CHECKLIST.md`](RELEASE_CHECKLIST.md). Physical hardware remains the release gate for camera/microphone routes, H.264 hardware acceleration, A/V synchronization, Wi-Fi recovery, jailbreak installation, and sustained thermal/memory behavior.
