# WebRTC media checkpoint — September 20, 2026

The active Monitor/Viewer media path now uses WebRTC 153.0.0 for H.264 video
and one-way Opus room audio. Both devices must install this checkpoint:
the setup protocol is version 2 and cannot stream to the previous custom
H.264/TCP build. Existing saved pairings and bundle identifiers are preserved.

## Implementation

- Bonjour discovery, six-digit pairing, Keychain trust, and automatic control
  reconnection remain in `LocalConnectionController`.
- WebRTC offers, answers, and ICE candidates use a new encrypted packet type
  over that authenticated TCP connection. Direction and sequence checks reject
  reflected/replayed messages; channel and stream IDs reject stale callbacks.
- Media travels directly over UDP using WebRTC DTLS-SRTP. No cloud account,
  external signaling server, STUN/TURN server, or analytics is configured.
  Cellular and VPN adapters are ignored. Candidate validation permits local
  host addresses and multicast DNS; it rejects public, relay, and TCP candidates.
- The existing AVFoundation camera sends raw frames into WebRTC. There is one
  application capture slot; pressure can drop a raw frame before encoding.
  Already-encoded frames no longer pass through the old application drop queues.
- `WebRTCH264Factories` advertises H.264 level 4.0 and creates WebRTC's own
  VideoToolbox encoder/decoder. Its default convenience factories advertised
  level 3.1: the real 1080p test produced zero encoded frames until this was
  corrected. There is no SDP text rewriting or custom decoder.
- The default target remains 1920×1080 at 15 FPS with a 4 Mbps video cap.
  720p/15 remains an explicit user selection. Spatial/frame-rate adaptation is
  disabled in sender parameters. Diagnostics report the actual resolution,
  frame rate, codec, implementation, loss, retransmission, PLI, and audio counts.
  A delivered-resolution mismatch is visible in the UI.
- The Viewer creates no local media tracks. Its output-only `RTCAudioDevice`
  adapter pulls decoded audio from WebRTC into an AVAudioSourceNode using a
  fixed 4096-sample conversion buffer and the `.playback` audio-session category.
  This avoids the default WebRTC iOS voice unit's requirement for microphone
  input during playback. WebRTC owns Opus, buffering, and timing.
- Peer/stream teardown closes media and clears the remote track. ICE failure
  or a sustained video stall reconnects through the paired control endpoint.
  The Metal video view receives WebRTC's decoded frames directly.

The legacy H.264/audio implementations and their tests remain in the repository
for comparison with the preserved checkpoint, but `BabyMonitorApp` no longer
constructs or connects them. Existing uncommitted work was preserved. The
pre-migration source and IPA are under `.build/webrtc-before/`.

## Verification

- **37 relevant regression checks passed** on iPad Simulator, iOS 26.5:
  35 unit/integration checks and two role/permission UI checks.
- Real H.264 loopback uses changing synthetic 1080p pixels, verifies multiple
  decoded frames and luma changes, then stops/restarts at 720p and rejects stale
  signaling. This exercises real WebRTC ICE, DTLS-SRTP, encoding, and decoding.
- The output-only audio adapter pulls audio and restarts with unchanged
  microphone permission; PCM conversion and failed-pull silence are tested.
- Signaling tests cover encryption, tampering, reflection, replay, fresh session
  keys, local candidate rules, payload limits, and incompatible protocol versions.
- Existing pairing, permission, role persistence, and framing regressions pass.
  The retired custom audio/playback suites were not used as WebRTC verification.
- The release packaging script validates the extracted archive and every Mach-O
  executable, including WebRTC: arm64, iOS 15-compatible deployment, public
  framework dependencies, no Apple certificate signature or provisioning profile.
  It replaces `dist/BabyMonitor.ipa` only after those checks pass.

Final artifact: `dist/BabyMonitor.ipa`, **7,900,770 bytes**, app build **2**.
SHA-256: `5f40882c1bd643cde172294803184d11858d9e6a9a8716cfa2fc5c3c06172637`.
Binary/dSYM UUID: `15143F58-1E70-3B7E-8CF6-385368FD6F37`.
The full binary audit is in `dist/BabyMonitor-validation.txt`; matching build
products and symbols are in `.build/webrtc-release-final/DerivedData/Build/Products/`.
Test evidence: `.build/webrtc-final.xcresult`.
Mac Catalyst arm64 build: passed (`.build/webrtc-catalyst-final.log`).
The WebRTC binary itself declares iOS 12.0; the app retains iOS/iPadOS 15.0.

## Device checklist

1. Install `dist/BabyMonitor.ipa` over the existing app on **both** the iPhone 8
   and iPad Air 2 with their existing TrollStore installers. Keep their
   jailbreaks active and retain saved pairings.
2. Keep both apps foregrounded on the same Wi-Fi. Start **1080p Monitor** on
   the iPhone, then connect the iPad Viewer. Confirm continuous movement and
   clear video. The old “Waiting for a video key frame” cycle should be absent.
3. Confirm room audio, including quiet sounds, and that the Viewer does not
   request microphone/camera permission. Check speaker/headphone route changes
   and an audio interruption.
4. Stop/start monitoring three times, disconnect/reconnect five times, and
   briefly interrupt Wi-Fi. Confirm fresh video/audio and saved-pairing recovery.
5. Run 1080p/15 for at least ten minutes. Copy diagnostics from both devices:
   actual resolution/FPS, codec implementation, frame counts, loss/PLI,
   memory, thermal state, and audio output. Check end-to-end delay visually.
   Do not switch to 720p to mask a failure; record the physical evidence first.
6. Separately exercise the explicit 720p fallback and switch back after stopping.

Physical-device video, microphone audio quality, A/V synchronization, sustained
CPU/thermal load, and TrollStore launch remain device verification gates.
Simulator success is not a substitute for those checks.

## Scope and delivery

This checkpoint does not implement recording, cloud access, multiple viewers,
background/locked-screen monitoring, automatic resolution fallback, or internet
NAT traversal. No signed Mac release was produced in this checkpoint; an older
Mac package using protocol 1 cannot stream to the new iOS build.

Linear and Google Drive connector tools were unavailable during implementation.
The **Baby Monitor MVP** issue status/acceptance criteria could not be verified.
The validated local IPA still needs to replace the existing **BabyMonitor.ipa**
inside **BabyMonitor App** in Google Drive, preserving its file ID and revision
history. No new Drive file was created.
