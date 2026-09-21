# Mac Viewer checkpoint

This records the original Mac-support checkpoint. The active iOS media path is
now described in [`WEBRTC_CHECKPOINT.md`](WEBRTC_CHECKPOINT.md). No new signed Mac
archive was produced for that migration. The prior Mac archive uses protocol 1
and cannot connect to the new protocol-2 iOS build.

## Current status

Mac Catalyst support is implemented in the existing BabyMonitor app target.
Select **BabyMonitor → My Mac (Mac Catalyst)** in Xcode. First launch defaults to
Viewer; saved role choices still take precedence. The universal Mac Release
binary compiles for both Apple Silicon and Intel with a macOS 12.0 minimum.

The signed Mac development package is built and validated at
`dist/BabyMonitor-Mac.zip`. After the user authorized the retry and granted
certificate access, Xcode prepared the matching Mac profile with the existing
team. All 37 Mac unit tests and five UI/launch checks pass, including an actual
Keychain save/read/delete round-trip.

This profile permits the current Mac and expires **September 16, 2026 at
9:42:01 p.m. Pacific** (`2026-09-17T04:42:01Z`). This is a development build,
not a notarized public-distribution package. A fresh profile/build is required
after expiry.

The refreshed iPhone/iPad `dist/BabyMonitor.ipa` is built, validated, and replaced.
The minimum remains iOS/iPadOS 15.0. It is unsigned, exactly arm64, supports both
device families, and contains no Apple provisioning profile or entitlements.

## Changes in this checkpoint

- `BabyMonitor.xcodeproj/project.pbxproj`: enable Catalyst for app and test
  targets, preserve the existing app identifier, and apply Mac Keychain
  entitlements only when building with the macOS SDK. Existing team and iOS
  signing settings are preserved.
- `Config/Mac.entitlements`: the app's own provisioned Keychain access group.
- `BabyMonitor/Models/DeviceRole.swift`, `App/AppRoleStore.swift`, and
  `BabyMonitorApp.swift`: injectable first-launch default, Viewer only on Mac;
  saved selections win.
- `BabyMonitor/ContentView.swift` and `Features/Viewer/ViewerView.swift`:
  minimum Mac window dimensions and a wider resizable Viewer.
- `BabyMonitor/Features/RoleSelection/RoleSelectionView.swift` and
  `Features/Permissions/PermissionOnboardingView.swift`: explain Mac viewing
  and current streaming behavior; Mac-specific permission recovery guidance.
- `BabyMonitor/Services/CameraCaptureController.swift`: use the system default
  camera if the secondary Monitor role is selected on Mac.
- `BabyMonitor/Services/RoomAudioCaptureController.swift`: import CoreAudio
  explicitly for the audio buffer-list API used when compiling for Catalyst.
- `BabyMonitorTests/MacViewerDefaultsTests.swift`: saved-role precedence,
  invalid-role fallback, platform default, and actual Mac Keychain round-trip.
- `BabyMonitorUITests/BabyMonitorUITests.swift`: adapt role tests for the Mac
  default and add Viewer-first launch with denied capture permissions.
- `Scripts/build-mac-app.sh`: build and validate a provisioned universal Mac
  development ZIP using existing signing resources; publish only after validation.
- `README.md`: Mac setup, use, packaging, and signing requirements.

The prior audio crash and H.264 continuity/attachment fixes are preserved.
The pre-Mac dirty working tree and previous IPA were copied to
`.build/mac-viewer-before`; no source work was discarded or committed.

## Evidence and checks

| Check | Result |
| --- | --- |
| Mac arm64 compile | Passed |
| Mac Release arm64 + x86_64 compile | Passed |
| Mac minimum OS, identifier, Bonjour, privacy descriptions, icon | Passed |
| Mac unit tests including actual Keychain save/read/delete | 37 passed |
| Mac role/default/permission UI checks | 3 passed |
| Mac light/dark launch checks | 2 passed |
| iPad simulator unit tests | 36 passed |
| iPad simulator role/permission UI checks | 2 passed |
| iPad simulator launch variants | 4 passed |
| Unsigned physical-device arm64 Release + extracted IPA audit | Passed |
| Mac package script syntax and whitespace checks | Passed |
| Provisioned universal Mac package, extracted signature, expiry and entitlement audit | Passed |
| Extracted Release app launch on this Mac | Passed; app opened and running |
| Physical iPhone → Mac stream / Intel Mac runtime / macOS 12 runtime | Pending hardware checks |

The original Mac storage failure was measured in the actual Catalyst test host:
ad hoc signing produced `errSecMissingEntitlement` (`-34018`). Catalyst's Data
Protection Keychain requires the appropriate application identity/access group.
The same regression test now passes with the provisioned signing configuration.
The original secure store is preserved; no plaintext or in-memory persistence
fallback was added. The earlier Mac UI automation failure also cleared on retry,
and the full Mac UI suite passes.

Results are saved under:

- `.build/mac-checkpoint-ios.xcresult`
- `.build/mac-viewer-provisioned-retry.xcresult` (37 unit tests passed)
- `.build/mac-viewer-provisioned-ui.xcresult` (five UI/launch checks passed)
- `.build/mac-viewer-keychain2.xcresult` (original measured Keychain failure)
- `.build/mac-checkpoint-package-retry.log` (validated signed package)

## Mac artifact

- File: `dist/BabyMonitor-Mac.zip`
- Size: **2,136,881 bytes**
- SHA-256: `e1320173a7ac5bec5bf9994ae4cc7ed2c439982cc9d3bcd8658f5f828f898029`
- Minimum macOS: **12.0**
- Architectures: **arm64 and x86_64**
- Binary/dSYM UUIDs:
  - arm64: `75A1CD75-EA34-3978-BD6C-B9C6B3E0697D`
  - x86_64: `A5EC149C-C56C-3875-9434-720B756945F9`
- Symbols, executable, entitlements, and source:
  `.build/mac-checkpoint-evidence/Mac-75A1CD75-EA34-3978-BD6C-B9C6B3E0697D/`
- Validation: `dist/BabyMonitor-Mac-validation.txt`
- Profile permits one registered Mac; expiry: `2026-09-17T04:42:01Z`.

## iPhone/iPad artifact

- File: `dist/BabyMonitor.ipa`
- Size: **2,184,333 bytes**
- SHA-256: `3033366584f0923ac5ec59ecaf5f3d99726beb620cf5015dfb75c415ce56e345`
- Binary/dSYM UUID: `67127813-3787-3ABF-B068-D0141B69788C`
- Symbols, executable, and source snapshot:
  `.build/mac-checkpoint-evidence/67127813-3787-3ABF-B068-D0141B69788C/`
- Validation: `dist/BabyMonitor-validation.txt`

## Physical retest

1. Install the refreshed IPA on the iPhone 8 and iPad Air 2 through their existing
   TrollStore installers. Keep the jailbreak active. Keep all devices on the same
   trusted Wi-Fi.
2. On iPhone, select Monitor, grant camera/microphone access if needed, start
   monitoring, and retain the **1080p / 15 FPS** profile.
3. Unzip `BabyMonitor-Mac.zip` and open `BabyMonitor.app` on the permitted Mac.
   Verify Viewer opens by default and does not request camera/microphone access.
   Click **Find a Monitor**, allow local-network access if requested, select the
   iPhone, and submit the current six-digit code.
4. Confirm authentication succeeds, the first picture is clear, movement remains
   clear, and room audio plays. Resize the Mac window and observe for 10 minutes.
5. Disconnect, quit/reopen the Mac app, find/select the same Monitor, and verify
   the saved pairing reconnects without another code. Briefly interrupt Wi-Fi
   and verify recovery. Keep the Mac awake and the apps visible.
6. Disconnect the Mac and repeat pairing/playback on iPad. Check the first frame,
   movement, audio, and three disconnect/reconnect cycles. Record any smearing,
   crash, freeze, delay, or increasing memory with the exact device/build.
7. On Mac while disconnected, change to Monitor and back to Viewer; verify the
   role is remembered. Mac capture is secondary and still requires a separate
   physical camera/microphone check.

General Mac distribution/notarization, background/sleep monitoring, recording,
and cloud access are not implemented. Physical first-frame video quality remains
unconfirmed. Linear and Google Drive integrations are not exposed in this session;
the Baby Monitor MVP tracker and existing Drive file were not updated.
