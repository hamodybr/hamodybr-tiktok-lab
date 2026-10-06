# Changes

## 0.2.0

- Replaced SwiftUI fileImporter with a native UIDocumentPickerViewController sheet using asCopy=true, an explicit delegate, and synchronous acquisition of security-scoped access. The picker accepts provider-reported item types and the MP4 reader validates the selected bytes.
- Added explicit Info.plist boolean keys for Files integration and verified them in the built device app.
- Removed the second coordinated provider read; only app-owned bytes are copied to persistent application storage.
- Added selected-file feedback, streaming copy/hash progress and cooperative cancellation with partial-copy cleanup.
- Added an independent seven-second deadline for AVFoundation property reads. MP4 results become visible before those reads finish.
- Persisted original/TikTok analyses and owned media across launches, with clearing and media sharing.
- Included a sample video and failure details in JSON reports.
- Added eight Swift import/deadline tests and four iPhone UI regression tests for Files selection, cancellation, empty-file errors and persistence.

## 0.1.0

Initial local MP4/MOV inspector, metadata comparison, media payload hashing and JSON report export.
