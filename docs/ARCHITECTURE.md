# Architecture

## Layers

```
┌──────────────────────────── App (SwiftUI, @MainActor) ────────────────────────────┐
│  Views ──read──▶ AppModel (@Observable) ──calls──▶ ProcessingCoordinator (actor)  │
└──────────────────────────────────────────────┬─────────────────────────────────────┘
                                               │ protocols from MediaSlimCore
          ┌────────────────────────────────────┼─────────────────────────────┐
          ▼                                    ▼                             ▼
 PhotoLibraryService                   MediaCompressing                JournalStore (actor)
 PhotoKitLibrary (MediaSlimLibrary)    MediaCompressor (MediaSlimEngine)  journal.log + state.json
 DemoPhotoLibrary (MediaSlimPipeline)  DemoCompressor (MediaSlimPipeline)
```

- **MediaSlimCore** has no Apple media frameworks. It defines the models, the protocols the
  other layers implement, the eligibility policy, SSIM, the quality search and the secure temp
  store. It is fully unit tested.
- **MediaSlimEngine** turns one file into a smaller file, or reports that it is not worth it.
- **MediaSlimLibrary** is the only code that touches PhotoKit.
- **MediaSlimPipeline** orchestrates a run. It depends only on Core protocols, so the whole flow
  is tested with in-memory fakes.
- **App** owns UI state. Views never call services directly; they call `AppModel`.

Swift 6 language mode with complete concurrency checking. Services are `Sendable` value types
or actors; UI state is `@MainActor`.

## A run, step by step

| Step | Journal state | If the app dies here |
|---|---|---|
| Item queued | `queued` | Nothing touched. Offered as "Continue" on next launch. |
| Original exported to temp, encoded, verified | `encoding` | Temp files purged at launch. Original untouched. |
| Copy saved to the library | `savedNewAsset` | Both versions in the library. |
| Copy confirmed to exist | `awaitingDeletion` (replace) / `completed` (keep both) | Home screen offers to delete originals. |
| Originals deleted (one system dialog) | `completed` | Done. Originals in Recently Deleted for 30 days. |

The journal line is flushed to disk (`fsync`) before the next irreversible step. Just before
deletion, every copy is checked again; an original whose copy is missing is never deleted.

## Quality search

Photos: the image is decoded once; up to 7 HEIC encodes bisect `kCGImageDestinationLossyCompressionQuality`
between 0.30 and 0.95. Each candidate is decoded and compared to the original with SSIM on 8
tiles (the 4 most detailed and 4 spread across the frame). The smallest passing file wins.
Gain map, depth and mattes are re-attached, and orientation, size, location and auxiliary images
are verified on the written file.

Videos: three 2-second samples (or the whole clip if under 8 s) are encoded per trial, and 12
frames are compared with SSIM. The score is the mean, capped at the worst frame + 0.03 so a
single damaged frame fails the trial. The full video is then encoded once with the chosen
setting, and duration, rotation and frame quality are verified. HEVC quality mode is preferred;
if the encoder rejects it, a bitrate search is used instead.

Thresholds (`QualityLevel`): photos SSIM 0.99 / 0.98 / 0.97; videos 0.985 / 0.975 / 0.965 as an
on-device proxy for VMAF 95. **These need calibration on real hardware** with the Apple encoder.

## Resource governance

Before each item the coordinator checks: user pause, thermal state (`serious` or worse), Low
Power Mode, and free space. Any of these pauses the run and the UI explains why. Processing is
sequential (one item at a time) to keep memory and heat low; video encoding uses the hardware
encoder.

Background: when the app leaves the foreground during a run and "Continue while charging" is on,
a `BGProcessingTask` that requires external power is scheduled. Deletion is never done in the
background.

## Accessibility

- Dynamic Type everywhere (text styles only); layouts switch to vertical at accessibility sizes.
- Every control has a VoiceOver label; decorative images are hidden; related text is combined.
- Progress is announced every 10%, plus pause, resume and finish.
- Reduce Motion disables the progress animation.
- Meaning never depends on color alone; contrast is at least 4.5:1 (checked for both themes).
- Choices are full-width rows with explanations instead of segmented controls.
- Right-to-left layout for Hebrew via leading/trailing alignment.
- UI tests run Xcode's `performAccessibilityAudit()` on every screen, at the default size, at
  the largest accessibility size, and in Hebrew.

## Known limits and next steps

1. Calibrate SSIM thresholds against the Apple hardware encoder on a real iPhone.
2. Dolby Vision: HDR (HLG, 10-bit) is preserved, but the Dolby Vision configuration may not be
   re-signaled; verify on device.
3. Live Photos: compress the still and keep the paired video linked.
4. Share extension ("Send to MediaSlim") and TestFlight release workflow.
5. iOS 26 `BGContinuedProcessingTask` for long user-started runs with system progress UI.
