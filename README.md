# BabyMonitor

A clean native SwiftUI starter project for an iPad-only baby monitor. The app currently contains only the Xcode template UI and test targets; it does not yet capture, stream, or transmit camera/audio data.

## Current project settings

| Setting | Value |
| --- | --- |
| Xcode template | iOS App |
| Product name | `BabyMonitor` |
| Interface | SwiftUI |
| Language | Swift |
| Storage | None |
| Unit tests | Swift Testing |
| UI tests | XCTest |
| App destination | iPad only |
| Minimum deployment | iPadOS 15.0 on the project, app, unit-test, and UI-test targets |
| Swift language mode | Swift 5 |
| Signing | Automatic; no development team selected |
| Placeholder bundle ID | `com.example.BabyMonitor` |

Xcode 26 can compile against its current SDK while producing an app whose minimum runtime is iPadOS 15. The deployment target does not downgrade the SDK; it makes newer APIs require availability checks and fallbacks.

## Required one-time signing setup

Before installing on the physical iPad:

1. Open `BabyMonitor.xcodeproj` in Xcode.
2. Choose **Xcode > Settings > Accounts**, add the Apple Account you use for development, and return to the project.
3. Select the blue **BabyMonitor** project in the navigator, then **Targets > BabyMonitor > Signing & Capabilities**.
4. Leave **Automatically manage signing** enabled.
5. Choose your personal or paid **Team**.
6. Replace `com.example.BabyMonitor` with a unique reverse-domain bundle identifier, such as `com.yourname.BabyMonitor`. Xcode updates the test bundle identifiers from the app identifier.
7. Do not commit a personal provisioning profile. Xcode manages it outside the repository.

A free Apple Account is enough for local device experiments, but locally signed apps generally need periodic re-signing. A paid Apple Developer Program membership is needed for normal App Store/TestFlight distribution.

## Verify the deployment settings in Xcode

1. Select the blue **BabyMonitor** project.
2. Under **Targets**, select **BabyMonitor**.
3. In **General**:
   - **Supported Destinations** contains only **iPad**.
   - **Minimum Deployments > iOS** is `15.0`. Xcode labels the platform “iOS” even for an iPad-only target.
4. Select **BabyMonitorTests** and confirm **Deployment Info > iOS** is `15.0`.
5. Select **BabyMonitorUITests** and confirm **Deployment Info > iOS** is `15.0`.
6. Select the project-level **BabyMonitor** entry, open **Build Settings**, search for `iOS Deployment Target`, and confirm Debug and Release are `15.0`.
7. In the app target's **Build Settings**, search for `Targeted Device Family`; the resolved value should be `iPad` / `2`.

Leave **Background Modes** and other capabilities off until the app architecture requires them. Camera, microphone, and local-network privacy descriptions should be added with the feature implementation, so the text accurately describes what the finished app does.

## Repository layout

```text
BabyMonitor/
├── AGENTS.md                     # Durable guidance for Codex and compatible agents
├── README.md                     # Setup and development notes
├── .gitignore
├── BabyMonitor.xcodeproj/        # Xcode project metadata (commit this)
├── BabyMonitor/                  # App target
│   ├── BabyMonitorApp.swift      # SwiftUI entry point
│   ├── ContentView.swift         # Template root view
│   └── Assets.xcassets/          # App icon, accent color, images
├── BabyMonitorTests/             # Swift Testing unit tests
└── BabyMonitorUITests/           # XCTest UI tests
```

As implementation begins, grow the app target by responsibility rather than adding a large generic `Helpers` folder:

```text
BabyMonitor/
├── App/
├── Features/Monitor/
├── Models/
├── Services/Capture/
├── Services/Encoding/
├── Services/Networking/
└── Resources/
```

Do not create those folders until they contain real code; empty folders add noise and Git does not track them.

## First device run

1. Connect the iPad to the Mac by USB and unlock it.
2. Trust the Mac if the iPad asks.
3. In Xcode's run-destination menu, select the physical iPad.
4. If prompted, enable Developer Mode on the iPad and restart it.
5. Press **Run** (`Command-R`).

An iOS simulator is useful for ordinary UI work, but camera behavior, microphone routing, thermal load, network discovery, and sustained streaming must be tested on the iPad Air 2 itself.

## Git workflow

The repository intentionally tracks the project file, shared workspace data, source, assets, tests, `README.md`, and `AGENTS.md`. It ignores per-user Xcode state, build products, derived data, local configuration, and secrets. Commit `Package.resolved` if Swift packages are added later; it pins the dependency graph for an application.

Useful checks:

```bash
git status --short
git diff --check
xcodebuild -project BabyMonitor.xcodeproj -scheme BabyMonitor \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .derived-data CODE_SIGNING_ALLOWED=NO build
```

If `.derived-data` is used inside the repository, either delete it after the check or add it to `.gitignore` first. The provided ignore file already excludes `DerivedData/`; the verification performed when this scaffold was created used a temporary directory outside the repository.

## Open and use the repository in Codex

1. In the Codex desktop app, choose **Open folder** (or create a local project) and select this repository's top-level `BabyMonitor` folder—not the `.xcodeproj` bundle and not only the inner source folder.
2. Start a Codex task in the local environment so it can inspect and edit the working tree and use the installed Xcode toolchain.
3. Give outcome-oriented prompts with constraints and verification, for example:

   > Add an iPadOS 15-compatible camera permission onboarding screen. Use public Apple APIs only, do not add dependencies, preserve signing settings, add focused tests, and build the BabyMonitor scheme before finishing.

4. Review `git diff` and the Xcode build result before committing each logical change.
5. Keep physical-device-only work explicit in prompts; an AI tool can build the code but cannot prove camera, microphone, heat, or Wi-Fi behavior without running on the real iPad.

`AGENTS.md` gives Codex durable project constraints, including iPadOS 15 compatibility, public-API-only development, iPad Air 2 performance considerations, and the current ban on jailbreak-specific work.

## Suggested next milestone

Build a non-streaming camera preview on the physical iPad with explicit camera and microphone permission UX. Measure CPU, memory, temperature, and frame stability before choosing an encoder or network transport.
