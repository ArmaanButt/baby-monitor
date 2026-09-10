# BabyMonitor Build 7 release checklist

Use the exact `dist/BabyMonitor.ipa` whose checksum appears in `dist/BabyMonitor-validation.txt`. Install that same IPA on the iPhone 8 and iPad Air 2. Record results and defects in the **Baby Monitor MVP** Linear project.

## Installation and baseline

- Confirm the IPA installs through TrollStore Lite on the iPhone and TrollStore on the iPad without an Apple ID, development certificate, or provisioning profile.
- Launch both roles and confirm the app icon, role persistence, and iPhone/iPad layouts.
- After a full reboot, reactivate palera1n rootless mode where required and confirm the installed app launches again.

## Private connection

- Start the Monitor listener, discover it from the Viewer, and complete the six-digit pairing.
- On a fresh Viewer install, enter the first pairing code and confirm the app stays open while it transitions to authenticated playback.
- Confirm no video or audio appears before authentication.
- Disconnect and reconnect; confirm the saved pairing authenticates without another code.
- Turn Wi-Fi off and on during a stream. Confirm the Viewer shows waiting/reconnecting state and returns to authenticated playback automatically.
- Revoke the pairing, reconnect, and confirm a new code is required.

## Live media

- Start the default 1080p/15 profile. Confirm the Monitor diagnostics report 1920×1080 near 15 FPS and a hardware H.264 encoder.
- Confirm the Viewer video remains bounded at no more than three frames and the audio playback queue at no more than eight packets.
- Use a visible clap or equivalent event to check A/V alignment and verify there is no persistent drift during a 10-minute run.
- Exercise microphone and speaker route changes plus an audio interruption. Confirm visible state changes and recovery.
- Select 720p manually and confirm both devices report the explicit fallback. Return to 1080p; the app must never lower resolution on its own.

## Lifecycle and sustained run

- Repeat Monitor start/stop and Viewer connect/disconnect ten times without relaunching either app.
- Background and foreground each role during an active session. Confirm foreground-only behavior is clear and a new foreground session recovers.
- Run 1080p/15 video and audio for 30 minutes under normal charging conditions, then repeat while unplugged.
- Save diagnostics from both devices. Record memory baseline/change/peak, drops, encode/decode timing, audio underruns, battery state, and worst thermal state.
- If 1080p is unstable, record the physical evidence before accepting 720p for that environment.

## Intentionally outside this MVP

- Background or lock-screen monitoring
- Cloud relay, remote internet access, accounts, analytics, or recording
- Two-way talk, notifications, multiple simultaneous Viewers, or browser playback
- Automatic quality reduction

Simulator and local archive validation cannot replace the physical checks above.
