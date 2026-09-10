# Viewer post-pairing crash fix

## Physical evidence and root cause

The supplied `BabyMonitor-2026-09-08-232029.ips` records an uncaught
Objective-C exception (`EXC_CRASH / SIGABRT`) on an iPad Air 2 (`iPad5,3`)
running iPadOS 15.8.1. The failing queue is
`com.armaanbutt.BabyMonitor.audio.playback`.

Its application UUID, `C1ECA168-2248-303A-B1C7-A57C90698EE8`, matches the
previous IPA and its saved arm64 dSYM. With load address `0x101258000`,
application address `0x1012c8730` (image offset `0x70730`) symbolicates to
`closure #1 in RoomAudioPlaybackEngine.start()`. Release optimization gives
that instruction a compiler-generated line; the framework frames identify
the call unambiguously:

```text
RoomAudioPlaybackEngine.start()
  -[AVAudioEngine connect:to:format:]
  AVAudioEngineImpl::Connect
  AVAudioEngineGraph::Connect / _Connect
  AVAudioPlayerNodeImpl::SetOutputFormat
  AUInterfaceBaseV3::SetFormat
  _AVAE_CheckSuccessAndNoNSError
  AVAE_RaiseException
```

The old source connects the player to the main mixer using noninterleaved
24 kHz mono **Int16** PCM. The iPad's player audio unit rejects that output
format during connection. This happens after authentication initiates
audio startup, before the player can schedule its first buffer.
`connect` raises an Objective-C exception; the surrounding Swift
`do/catch` cannot catch it. Removing `disconnectNodeOutput` in the earlier
attempt left this separate format failure intact.

The report does not include an exception reason string or an OSStatus, so
neither is inferred. The old dSYM, executable, source snapshot, and
symbolication are retained under
`.build/viewer-crash-evidence/C1ECA168-2248-303A-B1C7-A57C90698EE8/`.

## Post-pairing trace

| Stage | Existing path and relation to this crash |
| --- | --- |
| Code submission and trust storage | `LocalConnectionEngine.submitPairingCode` derives the pairing proof. On `.pairingAccepted`, `handleViewer` decrypts the shared secret, calls `KeychainPairingSecretStore.save`, and sends the authentication response. Keychain status failures throw into the protocol failure handler. |
| Authentication | `.authenticated` calls `completeAuthentication`, derives the media session key, and publishes the authenticated state on the main queue. Reaching `RoomAudioPlaybackEngine.start` through the Viewer transition establishes that this step completed for the reported crash. |
| SwiftUI transition | `ViewerView` reveals the video/audio UI and its state-change handler calls `videoPlayback.prepareForStream()` followed by `audioPlayback.prepareForStream()`. Mounting the video view and media arrival can interleave with asynchronous audio setup. |
| Video setup | `VideoPlaybackView.makeUIView` attaches an `AVSampleBufferDisplayLayer`; `H264VideoPlaybackController` resets its clock and format state and handles bounded frame delivery. These calls are not on the reported exception stack. |
| Audio setup | The playback queue configures the audio session, then connects the player to the mixer. **This connection is the failing operation.** Engine preparation/start and sample scheduling occur afterward. |
| First media packets | The network framer dispatches authenticated packets through decryption and `VideoWireCodec` / `AudioWireCodec`. App-level handlers enqueue them in the separate playback engines. Video constructs H.264 format/sample buffers; audio reserves queue capacity and builds PCM buffers before scheduling. This report identifies a format failure during graph connection, not a packet-decode or sample-scheduling failure. |

## Changes

- `BabyMonitor/Services/RoomAudioPlaybackController.swift`: connect and
  reuse the player with the same standard Float32 format used by its
  playback buffers.
- `BabyMonitor/Services/RoomAudioPlaybackPCM.swift`: create standard
  noninterleaved Float32 PCM and convert signed little-endian Int16 samples
  with `Float(sample) / 32768`. Validate payload length before allocating,
  support unaligned/sliced Data, and report allocation/format errors.
- `BabyMonitorTests/RoomAudioPlaybackTests.swift`: conversion checks for
  silence, positive/negative samples and both Int16 endpoints; malformed
  payload rejection; real Viewer audio startup and first-buffer scheduling
  over three reconnects.
- This report records evidence and the physical retest procedure.

The wire format remains encrypted 24 kHz mono Int16. Sample counts,
timestamps, the shared playout clock, and the eight-packet admission limit
are unchanged. Conversion allocates one Float32 playback buffer per
admitted packet, without an intermediate PCM buffer or resampler.
The iOS 15 minimum, universal device families, signing settings,
identifiers, privacy descriptions, and 1080p/15 target remain unchanged.
No third-party dependency or entitlement was added.

## Verification

- All **28 unit tests passed** on the iPad simulator, including the three
  new regressions. Results: `.build/viewer-crash-green.xcresult`.
- Both role/permission UI checks passed on **iPad (A16)** and **iPhone 17
  Pro** simulators (**four checks total**). Results:
  `.build/viewer-crash-ui.xcresult`.
- The simulator runtime is **iOS 26.5**. It accepted the old Int16 graph;
  it does not reproduce the physical iPadOS 15 format exception. An initial
  startup test also exposed a test assertion racing the separate state and
  diagnostics publications; the test now waits for both. The crash
  diagnosis comes from the matched physical report.
- The Release `iphoneos` arm64 build succeeded with Apple signing disabled.
  The IPA passed archive extraction/integrity, single-app structure, exact
  iOS 15.0 minimum, device families `[1,2]`, executable architecture, privacy
  and Bonjour metadata, icons, absent provisioning profile, absent Apple
  signature, and entitlements checks.

Validated IPA SHA-256:
`81ec9719e4ff4ce3cc8b884c64819d153ef64b40c645f9550f7e8737cae22d6a`

Size: **2,174,507 bytes**. New binary/dSYM UUID:
`FDAB17EA-DF77-3F57-9EFB-265CF89688A2`.

## Physical retest

1. Install the same replacement `dist/BabyMonitor.ipa` on the iPhone 8
   through TrollStore Lite and on the iPad Air 2 through TrollStore.
   Confirm each jailbreak is active; reactivate palera1n after a full
   iPhone reboot if needed. Record the IPA checksum and both OS versions.
2. Keep both devices on the same Wi-Fi, foregrounded, and initially use
   the built-in audio routes. On the iPhone choose **Monitor** and
   **Start 1080p Monitor**. Leave the default **1080p / 15 FPS** profile.
3. On the iPad choose **Viewer**, tap **Find a Monitor**, and select the
   iPhone. If an existing pairing authenticates automatically, first confirm
   that playback starts. On the **iPhone**, tap **Revoke Private Pairing**,
   then **Make Monitor Discoverable**. On the iPad, disconnect if needed,
   tap **Find a Monitor**, and select the iPhone again. Removing the
   Monitor's saved trust forces the six-digit handshake without deleting
   either app.
4. Enter the Monitor's six-digit code and tap **Pair Privately**.
   Confirm the iPad remains open, becomes authenticated, shows live video,
   and plays room audio. Speak or clap near the iPhone to verify audible,
   undistorted sound and approximate A/V alignment.
5. Tap **Disconnect**, discover/select the Monitor again, and confirm
   saved trust reconnects without another code. Repeat ten times without
   relaunching. Then repeat the iPhone revocation/re-advertising steps and
   complete another fresh six-digit pairing.
6. Run for ten minutes at 1080p/15. Save diagnostics from both devices:
   memory/peak, thermal state, frame drops, audio drops/underruns, and
   playback buffer depths (at most three video frames/eight audio packets).
   Check an audio route change and background/foreground recovery.
7. If any crash recurs, share the new full `.ips` report and record whether
   it was fresh pairing, saved reconnect, first audio, or a route change.
   Match it to the new binary UUID above.

Actual iPadOS 15 playback, device CPU/thermal cost, audio routes and
end-to-end A/V behavior still require these physical checks.

## Remaining external steps and scope

Linear and Google Drive connector tools were not exposed in this task.
The live **Baby Monitor MVP** tracker could not be consulted or updated,
and the existing Drive file has not been replaced. When access is restored,
record this defect and the physical result in that project; replace the
existing `BabyMonitor.ipa` in **BabyMonitor App** in place and verify its
reported name and size. Preserve its stable link and revision history.

This checkpoint fixes the reported Viewer crash. Background/lock-screen
monitoring, cloud relay, recording, two-way talk, notifications, multiple
Viewers, and automatic quality reduction remain outside the implemented
MVP. The wider release gates remain in `RELEASE_CHECKLIST.md`.
