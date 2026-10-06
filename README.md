# HAMODYBR TikTok Lab 0.2

Native iPhone app for local MP4/MOV inspection, media timing diagnostics, original/TikTok comparison and JSON report export.

Version 0.2 adds a native Files picker, streaming import/hash progress, cancellation, a bounded AVFoundation probe, saved sessions, media sharing and a bundled sample video. The analyzer preserves the source media bytes.

**Verified:** 22 Swift core tests and four iPhone simulator UI tests passed. The UI tests cover normal Files selection, thumbnail selection with session restoration, picker cancellation and an explicit empty-file error. The iOS arm64 Release IPA built successfully with Xcode 16.4. [Build log and artifact](https://github.com/hamodybr/hamodybr-tiktok-lab/actions/runs/37450623011). Sign the unsigned IPA in Feather before installing. Version 0.2 physical iPhone and iCloud-provider testing is pending.

See [the Arabic guide](README_AR.md) for installation and usage instructions.

Minimum deployment target: iOS 16.
