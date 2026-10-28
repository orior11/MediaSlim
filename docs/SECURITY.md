# Security and privacy

## Principles

1. **Nothing leaves the device.** The app has no networking code, no third-party SDKs, no
   analytics, no accounts. App Transport Security stays at its strict default. The only network
   use is optional and indirect: Photos may download an iCloud original if the user enables it.
2. **No silent data loss.** An original is deleted only after its copy is saved, re-read and
   verified, only through the system confirmation dialog, and Photos keeps it for 30 days.
3. **Least privilege.** Photo access is requested only when the user taps the button, with a clear
   explanation; limited access is fully supported.
4. **Minimal, protected local data.**

## Data the app stores

| Data | Where | Protection | Lifetime |
|---|---|---|---|
| Original and encoded media (temporary) | `Caches/MediaSlimWork`, random names | `completeUntilFirstUserAuthentication`, excluded from backup | Deleted when each item ends; folder purged at launch and after each run |
| Journal: asset identifiers, byte sizes, states | `Application Support/MediaSlim/journal` | Same as above | Finished entries compacted after each run |
| Run history: dates, counts, bytes | Same folder | Same | Until "Erase App Records" |
| Settings | UserDefaults | System default | Until reset |

No image content, thumbnails, locations, file names or faces are ever stored by the app.

`completeUntilFirstUserAuthentication` (rather than `complete`) is used so a charging, locked
phone can keep processing in the background; files are still encrypted at rest and unreadable
before the first unlock after a reboot.

## Threats considered

| Threat | Mitigation |
|---|---|
| Crash or kill mid-replace loses a photo | Append-only journal with `fsync` before each irreversible step; deletion only of verified copies; recovery UI on launch |
| Bug deletes user files outside the app | `SecureTempStore` refuses any path outside its own folder (tested) |
| Corrupt or wrong output replaces a good original | Output decoded and compared (SSIM), dimensions, orientation, location, auxiliary images, duration and rotation verified before saving |
| Malformed input crashes the app | All decoding goes through ImageIO / AVFoundation error paths; failures are per-item and reported |
| Leftover decrypted media in temp storage | Random names, file protection, immediate deletion, purge at launch |
| Sensitive data in logs | `os.Logger`; only error codes and numbers are logged as public; no identifiers or paths |
| Private API rejection or breakage | One KVC read of `PHAssetResource.fileSize`, guarded by `responds(to:)` and optional; size falls back to measuring the exported file |
| Supply chain | Zero third-party dependencies; CI uses pinned major versions of official actions |

## Privacy manifest

`App/Resources/PrivacyInfo.xcprivacy` declares no tracking, no collected data, and the
required-reason APIs used: UserDefaults (CA92.1), disk space (E174.1), file metadata (C617.1).
