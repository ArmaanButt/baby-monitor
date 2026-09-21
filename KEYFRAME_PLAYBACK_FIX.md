# Repeated keyframe buffering — September 13, 2026

The physical iPad was reported to display a frame, return to “Waiting for a
video key frame,” and repeat. This checkpoint fixes a reproducible receive-queue
defect that can cause that cycle. The iPad was not connected for console access,
and no physical diagnostics snapshot was received during implementation.
On-device playback quality still requires the retest below.

## Cause and fix

TCP can deliver several complete video packets in one read. The receive loop
submitted all of them immediately, but playback admitted only three compressed
frames and held those slots through the 150 ms playout delay. A fourth frame
arriving before a slot was released was discarded, even when the stream was
valid and the network had delivered every byte.

Losing an H.264 reference frame invalidates later dependent frames. The existing
continuity guard correctly waited for the next keyframe, ordinarily up to two
seconds later. Repeated queue overruns could therefore turn the stream into
brief pictures separated by keyframe waits.

The receiver now acknowledges each packet's handoff. Playback immediately
accepts frames while a slot is available; when full, it holds one producer
waiting for the next slot instead of dropping that frame. Until admission is
acknowledged, the receiver retains its current bounded TCP batch and issues no
further receive. It does not block a thread. The three playback slots remain
bounded, and normal admission does not wait for presentation, allowing
interleaved audio to remain buffered ahead.

Disconnects cancel the current delivery batch. Late or duplicate acknowledgements
cannot advance another connection. The existing H.264 continuity checks, sample
attachments, and decoder recovery remain intact for genuine frame loss.
The wire protocol, six-digit pairing, encryption, and **1080p / 15 FPS** target
are unchanged.

Copied Viewer diagnostics now include:

- **Video input overflows** — frames rejected because a caller exceeded admission.
- **Video decoder failures** — display-layer failure/reset count.
- **Last video recovery** — a reference-chain loss or the actual decoder error.

These contain counts and error descriptions, not media or pairing secrets.

## Changed files

- `BabyMonitor/Models/VideoFrameAdmission.swift`: bounded asynchronous admission.
- `BabyMonitor/Services/Networking/WirePacketDelivery.swift`: ordered batch
  delivery with consumption acknowledgements and cancellation.
- `BabyMonitor/Services/Networking/LocalConnectionController.swift`: integrate
  delivery and reject callbacks from replaced connections.
- `BabyMonitor/Models/VideoStreamingModels.swift` and `BabyMonitor/BabyMonitorApp.swift`:
  connect the admission acknowledgement between networking and playback.
- `BabyMonitor/Services/H264VideoPlaybackController.swift`: defer admission when
  full, release slots on every exit, cancel pending admission on reset, and
  retain recovery diagnostics.
- `BabyMonitor/Models/PerformanceDiagnostics.swift`: include recovery details
  in copied snapshots.
- `BabyMonitorTests/VideoFrameAdmissionTests.swift` and
  `BabyMonitorTests/WirePacketDeliveryTests.swift`: six focused regressions.
- `README.md`, `MAC_VIEWER_CHECKPOINT.md`, and this report: current artifact
  and validation references.

## Verification

- An isolated copy reproducing the former immediate-rejection policy **fails**
  the full-queue regression at the fourth frame:
  `.build/keyframe-old-policy2.xcresult`.
- The fixed implementation passes all six new regressions on iPad Simulator
  and Mac. These cover bounded admission, cancellation, duplicate callbacks,
  malformed batches, and a synthetic 60-frame protocol/continuity sequence.
  This is a sequencing test, not a hardware H.264 image-quality test.
- All five existing H.264 continuity/attachment tests pass.
- iPad Simulator: **41 of 42 unit tests pass**. Five interface/launch checks
  passed in the full run; the remaining role-switch check passed on a clean
  temporary simulator. The original simulator also showed launch timeouts.
- Mac: **42 of 43 unit tests pass**, including actual Keychain save/read/delete.
- The remaining test failure on both platforms is the existing
  `viewerAudioStartsAndSchedulesPacketsAcrossReconnects` startup timeout.
  It also fails against an isolated copy of **unchanged main**, and on the
  clean simulator. No audio implementation or test was changed to hide it.
  The full test suites are therefore **not completely green**.
- Unsigned universal iPhone/iPad Release build and extracted IPA audit: **passed**.
- Signed arm64/x86_64 Mac Release build, extracted signature, profile expiry,
  and entitlement audit: **passed**.
- Whitespace checks: **passed**.

Results:

- `.build/keyframe-flow-ios.xcresult`
- `.build/keyframe-flow-clean-simulator.xcresult`
- `.build/keyframe-audio-baseline.xcresult` (same audio timeout on unchanged main)
- `.build/keyframe-mac-unit2.xcresult`
- `.build/keyframe-flow-package.log`
- `.build/keyframe-flow-mac-package.log`

## Downloads

**iPhone/iPad:** `dist/BabyMonitor.ipa`

- Size: **2,196,954 bytes**
- SHA-256: `a69010070a294802647a579e0aa93cb3bc9032e91ed001b15d549ca745e7953c`
- Binary/dSYM UUID: `B4E641B4-B717-3FAC-851F-016C1A3ED491`
- Exactly arm64; iOS/iPadOS **15.0** minimum; device families **1,2**.
- Apple signature, provisioning profile, and signing entitlements: **absent**.
- Archive structure, privacy descriptions, Bonjour declaration, and icons: **validated**.

**Mac:** `dist/BabyMonitor-Mac.zip`

- Size: **2,163,608 bytes**
- SHA-256: `5e50a0a473b0713e48013acb163a02bd3400a1bb6fe9fb01a0fd88456583a434`
- arm64 UUID: `D4037452-2232-3EA6-BCF8-8B64E64D3CEC`
- x86_64 UUID: `319E5A20-C284-3470-934D-8483C7F59825`
- macOS **12.0** minimum; development signing for the registered Mac.
- Existing profile expires **September 16, 2026 at 9:42 p.m. Pacific**
  (`2026-09-17T04:42:01Z`). No profile renewal was performed.

Previous downloads are preserved in `.build/keyframe-flow-before/dist`.
Matching binaries, dSYMs, and source snapshots are preserved under
`.build/keyframe-flow-evidence/<UUID>/`.

## Physical iPad retest

1. Install the new `dist/BabyMonitor.ipa` over the existing app on both the
   iPhone 8 and iPad Air 2 using their existing TrollStore installers. Keep the
   jailbreak active. Do not delete the apps or their saved pairings.
2. Quit/reopen BabyMonitor on both devices and keep them on the same Wi-Fi.
   Start the iPhone Monitor at **1080p / 15 FPS**.
3. On iPad, select Viewer, find/select the Monitor, and use saved pairing or
   enter its current six-digit code. One initial keyframe wait can occur;
   playback should then continue instead of cycling between a frame and a wait.
4. Move a hand across the camera for a minute, then observe for ten minutes.
   Check continuous movement, clear edges, and room audio. Disconnect/reconnect
   five times and check recovery after a brief Wi-Fi interruption.
5. If the cycle remains, tap **Copy Test Snapshot** on the iPad and paste it,
   including **Video input overflows**, **Video decoder failures**, and
   **Last video recovery**. Also capture the Monitor's snapshot. This will
   distinguish an input overrun, upstream missing frames, and a decoder error.

Physical iPhone/iPad playback, A/V timing, and sustained load remain unverified.
This checkpoint adds no recording, cloud transport, background monitoring, or
automatic quality reduction. Linear and Google Drive integrations were not
available in this session, so the Baby Monitor MVP tracker and Drive file were
not updated.
