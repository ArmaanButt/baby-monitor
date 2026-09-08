# BabyMonitor project guidance

- The project tracker and source of truth for outstanding work is the **Baby Monitor MVP** project in Linear. Consult Linear for current priorities, statuses, milestones, and acceptance criteria instead of inferring the backlog from repository TODOs or documentation alone.
- This repository contains one native SwiftUI app with explicit Monitor and Viewer roles. Keep the minimum deployment target at iOS/iPadOS 15.0 and support both iPhone and iPad.
- Use Swift and public Apple SDK APIs only. No private APIs, undocumented entitlements.
- The Monitor/server role targets an iPhone 8 running iOS 16.7.16 with palera1n in rootless mode and TrollStore Lite. The native Viewer/client role targets a jailbroken iPad Air 2 running iPadOS 15.8.x with TrollStore. Both devices run the same universal IPA. Favor low memory use, bounded buffers, and measured CPU/thermal load on both devices.
- Target a high-quality 1080p-at-15-FPS H.264 video profile for the live stream, with a 720p profile available as a measured fallback when sustained device testing shows thermal, memory, or network instability. Do not silently lower the target resolution without reporting the physical-device evidence.
- For TrollStore Lite deliverables, do not use AltStore, Sideloadly, an Apple ID, or an Apple development certificate. Build the physical-device `arm64` app with Apple code signing disabled, package it as `Payload/BabyMonitor.app` in an IPA, audit entitlements that require Apple provisioning, and validate the archive before delivery.
- Apps installed through TrollStore Lite on this iPhone depend on the rootless jailbreak being active. After a full reboot, palera1n may need to be reactivated before the app works.
- Build the app in small, independently verifiable vertical checkpoints. Every implementation checkpoint must end with a validated universal IPA, a concise device test checklist, and a clear statement of what is intentionally not implemented yet. Keep partially completed checkpoint work resumable and avoid combining unrelated Linear issues into one coding turn.
- After every successful checkpoint build and local IPA validation, update `BabyMonitor.ipa` in the Google Drive folder **BabyMonitor App** using the connected Google Drive integration. Replace the existing Drive file in place so its stable link and revision history are preserved, then verify the reported Drive filename and size. Never upload a failed or unvalidated build.
- Do not use an API introduced after iOS/iPadOS 15 unless it is guarded with `#available` and there is a working iOS/iPadOS 15 fallback.
- Preserve the user's signing team, bundle identifiers, provisioning settings, and privacy descriptions unless a task explicitly requires a change.
- Prefer Apple frameworks already available on iOS/iPadOS 15, including SwiftUI, AVFoundation, VideoToolbox, Network, and Bonjour. Ask before adding a third-party dependency.
- Keep camera, audio, networking, encoding, and UI concerns separate. Avoid placing capture or networking logic directly in SwiftUI views.
- Treat video and audio as sensitive local data. Default to local-network-only behavior, require explicit user-visible consent, and never add analytics or cloud upload implicitly.
- Add or update tests for behavior that can be tested without real camera hardware. Clearly identify checks that require the physical iPhone 8, the physical iPad Air 2, or both.
- Before finishing a code change, run the narrowest relevant `xcodebuild` build or test command and report any device-only verification still needed.
