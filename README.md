# MediaSlim

An iOS app that frees space by re-encoding photos (HEIC) and videos (HEVC) at the lowest quality
that still looks identical to the original, measured per file. Everything runs on the device.

Research behind the defaults: re-encoding iPhone originals saved about **45%** on photos (including
the HDR gain map) and **72%** on iPhone videos at SSIM 0.98 / VMAF 95, with no visible difference at
1:1 crops. Files that are already compressed hard (for example, received through messaging apps)
are detected and left alone.

## What it does

1. The user picks a source: the whole library, an album, or specific items.
2. A scan estimates the savings and lists what will be skipped, and why.
3. The user picks a quality level and, **every run**, whether to replace originals or keep both.
4. Each file is exported, re-encoded with a quality search, verified, and saved as a new asset
   with the original's date, location, favorite state and albums.
5. In replace mode, originals are deleted in one batch through the system dialog. Photos keeps
   them in Recently Deleted for 30 days.

Skipped in v1, by design (replacing them could break them): Live Photos, edited photos, RAW,
slow motion, cinematic and spatial media, shared or synced items.

## Project layout

```
App/                       SwiftUI app (iOS 17+), English and Hebrew
  Model/                   AppModel (state), AppSettings, background processing
  Views/                   Screens and shared components
  Resources/               String catalogs, assets, privacy manifest
AppUITests/                End-to-end UI tests with accessibility audits
Packages/MediaSlimKit/     All logic, as a Swift package
  MediaSlimCore            Models, eligibility, SSIM, quality search, secure temp store
  MediaSlimEngine          HEIC (ImageIO) and HEVC (AVFoundation / VideoToolbox) encoders
  MediaSlimLibrary         PhotoKit access
  MediaSlimPipeline        Crash-safe journal, resource governor, processing coordinator, demo services
project.yml                XcodeGen project definition (the .xcodeproj is generated)
tools/make_strings.py      Generates the English/Hebrew string catalogs
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/SECURITY.md](docs/SECURITY.md).

## Building

### On a Mac

```sh
brew install xcodegen
xcodegen generate
open MediaSlim.xcodeproj
```

Package tests run without the app: `swift test --package-path Packages/MediaSlimKit`.

### From Windows (no Mac)

Every push runs [.github/workflows/ci.yml](.github/workflows/ci.yml) on a GitHub-hosted Mac: it
builds the app, runs the package tests, and runs the UI tests with Xcode's accessibility audit
on an iPhone simulator. Logs and the `.xcresult` bundle are attached to each run.

To install on an iPhone you need an Apple Developer account. After it is active:

1. Create the app record in App Store Connect with bundle ID `com.mediaslim.app`.
2. Create an App Store Connect API key and add it to the repository secrets.
3. Add a release workflow that signs and uploads to TestFlight (planned next step).

## Demo mode

Launch with `-demo` to use an in-memory library and a simulated encoder. The real Photos library
is never touched. UI tests run in this mode. Extra flags: `-resetState`, `-skipOnboarding`.

## Localization

Strings live in `App/Resources/Localizable.xcstrings` and `InfoPlist.xcstrings`. To change a
translation, edit `tools/make_strings.py` and run `python3 tools/make_strings.py`.
