# BabyMonitor project guidance

- This repository contains a native SwiftUI iPad app. Keep the minimum deployment target at iPadOS 15.0 and the app target restricted to iPad.
- Use Swift and public Apple SDK APIs only. Do not add jailbreak support, private APIs, undocumented entitlements, or code-signing bypasses.
- Assume the primary device is an iPad Air 2 running iPadOS 15.8.x. Favor low memory use, bounded buffers, conservative video resolution, and measured CPU/thermal load.
- Do not use an API introduced after iPadOS 15 unless it is guarded with `#available` and there is a working iPadOS 15 fallback.
- Preserve the user's signing team, bundle identifiers, provisioning settings, and privacy descriptions unless a task explicitly requires a change.
- Prefer Apple frameworks already available on iPadOS 15, including SwiftUI, AVFoundation, VideoToolbox, Network, and Bonjour. Ask before adding a third-party dependency.
- Keep camera, audio, networking, encoding, and UI concerns separate. Avoid placing capture or networking logic directly in SwiftUI views.
- Treat video and audio as sensitive local data. Default to local-network-only behavior, require explicit user-visible consent, and never add analytics or cloud upload implicitly.
- Add or update tests for behavior that can be tested without real camera hardware. Clearly identify checks that require the physical iPad.
- Before finishing a code change, run the narrowest relevant `xcodebuild` build or test command and report any device-only verification still needed.
