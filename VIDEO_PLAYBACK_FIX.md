# Viewer video corruption checkpoint

The Viewer no longer crashes after pairing, but the physical iPad was
reported to display smeared video from the first image. This checkpoint
repairs defects found in the H.264 playback path. Physical image quality
still needs the retest below; no image capture or device console was
available for this symptom.

## Findings and changes

1. **Dependent frames survived missing references.** Both the transport and
   Viewer deliberately drop compressed frames when their bounded queues
   fill. The Viewer did not check sequence numbers before submitting later
   H.264 P-frames, even though they can depend on a missing frame. The new
   continuity check runs at final decoder submission, after every app queue.
   A gap, duplicate, reordering, reset, or changed parameter sets requires
   a complete keyframe before playback continues. Recovery flushes decoder
   references before submitting that keyframe.
2. **Sample attachments were lost.** The old code passed
   `kCMSampleAttachmentKey_DisplayImmediately` to `CMSetAttachment` and
   omitted `NotSync` and `DependsOnOthers`. Apple's
   `AVSampleBufferDisplayLayer` SDK documentation explicitly requires
   `kCMSampleAttachmentKey_` values in the dictionary returned by
   `CMSampleBufferGetSampleAttachmentsArray`. Without `NotSync`, a sample
   is declared to be a sync frame. The replacement sets all three flags
   in the correct dictionary, preserving H.264 dependencies and letting
   the existing shared playout clock schedule delivery instead of
   interpreting the Monitor's uptime as the iPad's clock.
3. **Display readiness could generate redundant work.** The old callback
   remained registered with an empty queue and returned before an
   asynchronous MainActor task could feed the layer. The Viewer now
   registers only when frames are pending and the layer is full. A
   cancellable request stops itself synchronously before its single actor
   hop. A stale callback cannot cancel a newer request.
4. **View and stream lifecycle now discard old work.** Dismantling the
   SwiftUI video view calls the controller's detach operation. Replacing
   a layer resets continuity. Reset advances the stream generation
   synchronously; delayed or already-posted candidates from an old
   generation cannot reach a new session's decoder.

Changed app files:

- `BabyMonitor/Models/H264PlaybackContinuity.swift`
- `BabyMonitor/Services/H264SampleAttachments.swift`
- `BabyMonitor/Services/H264VideoPlaybackController.swift`
- `BabyMonitor/Features/Viewer/VideoPlaybackView.swift`

New tests: `BabyMonitorTests/H264PlaybackTests.swift`. Existing dirty work
and the Float32 audio fix are retained. Capture, encoding, pairing,
encryption, wire format, and the default **1080p/15** profile are unchanged.
The app-level video queue remains bounded at three frames. The existing
encoder produces keyframes about every two seconds; recovery may briefly
show “Waiting for a video key frame” rather than decoding invalid
dependent frames. A dropped recovery keyframe can extend that wait.

## Verification and artifact

- The unit suite passed **33 tests**, including initial keyframe gating,
  frame-loss recovery, duplicate/reordered-frame rejection, reset/profile
  recovery, and real CoreMedia attachment checks.
- The final rerun passed all **33 unit tests and both iPad UI checks**.
  Results: `.build/video-integrity-retest.xcresult`; the artifact summary
  is in `dist/BabyMonitor-validation.txt`.
- Simulator runtime: iOS 26.5. A final-run attempt failed before app launch
  because SpringBoard reported `Busy`; the simulator was rebooted before
  retrying. This was not an app crash or an assertion failure in the tests.
- The unsigned Release arm64 IPA passed archive integrity, one universal
  `Payload/BabyMonitor.app`, iOS 15.0 deployment, privacy/Bonjour metadata,
  icons, and absent Apple signing/provisioning/entitlements checks.

IPA: `dist/BabyMonitor.ipa` — **2,183,902 bytes**

SHA-256: `3475d7cd910f6782affbfee3e86a22d0813b6b708931b1abc4522cb0f74384fd`

Binary/dSYM UUID: `DDD6AEB7-833A-39C5-88CA-D5D92F9E38DA`

The previous IPA is retained under `.build/video-integrity-before/dist/`.
New symbols are retained with this checkpoint's build evidence.

## Physical retest

1. Install this same IPA on both target devices through TrollStore Lite
   (iPhone) and TrollStore (iPad), with their jailbreaks active.
2. Keep both apps foregrounded on the same Wi-Fi. On the iPhone select
   Monitor and **Start 1080p Monitor**; on the iPad select Viewer,
   **Find a Monitor**, and connect using saved trust or the six-digit code.
3. Aim the iPhone at a stationary scene with clear edges or printed text.
   The first displayed image should be coherent. Move a hand slowly,
   then pan across the scene; confirm edges remain distinct and previous
   images do not smear into the new image.
4. Disconnect and reconnect five times. On one run briefly toggle the
   iPad's Wi-Fi off and back on. After authentication, expect a clean
   keyframe before video resumes; confirm any short freeze clears
   rather than accumulating corruption.
5. Run at 1080p/15 for ten minutes. Confirm room audio still works and
   collect diagnostics from both devices: resolution/FPS, memory peak,
   thermal state, video drops/buffer depth, and audio underruns. Do not
   lower the profile to mask corruption.
6. If it still smears, provide a short screen recording or photograph
   showing the Viewer and note whether the iPhone's own preview is clear.
   Record the installed IPA checksum and both diagnostics snapshots so
   the next investigation can distinguish capture/encode corruption from
   Viewer decoding.

Linear and Google Drive tools remain unavailable in this task, so the live
Baby Monitor MVP tracker and stable Drive IPA have not been updated.
When the connectors are available, update the existing Drive file in
**BabyMonitor App** in place and verify its filename and byte size.

This checkpoint adds no cloud access, recording, background/lock-screen
monitoring, or automatic quality reduction. Physical hardware remains the
gate for image quality, end-to-end timing, and sustained CPU/thermal load.
