# Authenticator for macOS

> **Just for fun.** I built this out of boredom one evening. It isn't maintained and won't get updates, but feel free to use it, fork it, or borrow from it.

A small native macOS 2FA (TOTP) authenticator in the spirit of Google Authenticator, written in Swift + SwiftUI.

- **Bundle id:** `org.sinoussi.authenticator`
- **Requires:** macOS 14 Sonoma or later, Apple Silicon. Built with Swift 6.x / Xcode 16+.

## Features

- **Account list:** shows the issuer, account name, and the current 6- or 8-digit code in large monospaced digits (`123 456`), plus a circular countdown for the 30 s or 60 s period. The code and ring turn red in the last 5 seconds.
- **Click a row to copy** the code. You see a "Copied" confirmation. The clipboard entry is marked concealed/transient so clipboard managers skip it, and it is cleared after 30 s by default (you can change this in Settings).
- **Search** by issuer or account name. Matching ignores case and diacritics.
- **Right-click menu:** Copy Code, Edit (rename issuer/account, reveal the secret key), Show QR Code (to move the account to a phone; the code stays blurred until you click), Copy Setup Link, Delete (asks for confirmation). Swipe-to-delete and drag-to-reorder also work.
- **Add an account:**
  - **Camera:** hold a QR code (for example Google Authenticator's Transfer accounts export) up to your Mac's camera; the sheet closes as soon as it reads a code.
  - **Scan QR Code:** drop an image onto the sheet or the main window, choose files with the open panel, paste a screenshot from the clipboard, or click **Scan Screen**. Scan Screen uses ScreenCaptureKit to capture every display, leaves out Authenticator's own windows, and finds every QR code it can see.
  - **Setup Link:** paste or type one or more `otpauth://totp/...` URIs. Google Authenticator "Transfer accounts" exports (`otpauth-migration://offline?data=…`) are decoded too.
  - **Setup Key:** enter the issuer, account, Base32 secret, digits (6/8), period (30/60) and algorithm (SHA-1/SHA-256/SHA-512) by hand. A live preview of the code is shown.
  - Before you add anything you get a review list where you can edit names and remove entries. Duplicates are skipped.
- **Clicking an `otpauth://` link** in a browser opens the app with the account pre-filled (the URL scheme is registered in `Info.plist`, so this needs the `.app` bundle).
- **Menu bar extra** (you can turn it off in Settings): click the shield icon to see all codes with countdowns and copy one with a click.
- **Optional Touch ID / password lock** (Settings). The app locks at launch, when the screen locks or sleeps, and with ⌃⌘L.
- **Import / Export:** File › Export writes a plain-text backup with one `otpauth://` URI per line and file mode 0600. File › Import reads such files and QR images.
- Uses only native UI: `List`, SF Symbols, system colors and materials. Works in light and dark mode.

### Keyboard shortcuts
| | |
|---|---|
| ⌘N | Add Account |
| ⇧⌘S | Scan screen for a QR code |
| ⇧⌘V | Add from clipboard (link or image) |
| ⇧⌘I / ⇧⌘E | Import / Export |
| ⌃⌘L | Lock (when the lock is enabled) |
| ⌘, | Settings |

## Build and run

```sh
swift build                 # debug build
swift run Authenticator     # run as a bare executable (good for development)
swift test                  # unit tests for the core logic

scripts/build-app.sh        # release build → build/Authenticator.app (ad-hoc signed)
open build/Authenticator.app
cp -R build/Authenticator.app /Applications/
```

To use a real signing identity, run `SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh`. The script also turns `Support/AppIcon.png` into the app icon using `sips` and `iconutil`.

You can also open `Package.swift` in Xcode (File › Open…) and run the `Authenticator` scheme.

### Notes
- **Keychain prompts:** secrets are stored as a single generic-password item (service `org.sinoussi.authenticator`, account `vault`) in the login keychain. Ad-hoc signed builds get a new code signature on every rebuild, so macOS may ask once per build whether Authenticator can use the keychain item. Choose **Always Allow**. Signing with a stable identity avoids this. If reading the keychain fails, the app refuses to save, so it never overwrites your existing accounts.
- **Screen scanning** needs Screen Recording permission (System Settings › Privacy & Security › Screen & System Audio Recording). On first use the app asks for it. After you grant it you may need to relaunch. With `swift run`, the permission belongs to your terminal app, not to Authenticator.
- `swift run` sets the activation policy to `.regular` and embeds `Support/Info.plist` into the binary, so the bare executable gets a Dock icon, a menu bar and a bundle id. URL-scheme handling needs the `.app` bundle.

## Layout

```
Package.swift
Sources/
  AuthenticatorCore/            pure Swift, no Apple-only APIs (builds/tests on Linux)
    Hash.swift                  SHA-1/256/512 + HMAC (pure Swift, so one code path everywhere)
    Base32.swift                RFC 4648 Base32 (lenient decode: case, spaces, '-', padding)
    OTP.swift                   HOTP (RFC 4226) / TOTP (RFC 6238), countdown math, "123 456" grouping
    OTPAccount.swift            account model, manual-entry validation, search, errors
    OTPAuthURI.swift            otpauth:// parse/build, multi-URI text parsing
    GoogleAuthenticatorMigration.swift   otpauth-migration:// protobuf decoder
    AccountVault.swift          ordered account list: add (dedupe), update, delete, move, JSON, export
  Authenticator/                SwiftUI app (macOS only; added to the package only on macOS)
    AuthenticatorApp.swift      scenes (Window, MenuBarExtra, Settings), menu commands
    AppModel.swift              state, persistence, lock, import/export
    KeychainStore.swift         Security.framework wrapper
    ContentView.swift           main list, search, context menu, drag & drop
    AccountRow.swift            row, live code, countdown ring, issuer badge
    AddAccountView.swift        scan / link / manual entry + review list
    EditAccountView.swift       rename + QR export sheet
    MenuBarView.swift           menu bar extra
    SettingsView.swift, LockView.swift, Clipboard.swift, QRScanner.swift (Vision + ScreenCaptureKit)
Tests/AuthenticatorCoreTests/   XCTest
Support/Info.plist, Support/AppIcon.png
scripts/build-app.sh
```

## Testing

`swift test` runs on both macOS and Linux. On Linux, `Package.swift` leaves out the macOS-only app target. The tests cover:

- SHA-1/256/512 against FIPS test vectors (including the million-`a` SHA-1 case) and HMAC against RFC 2202/4231.
- HOTP against RFC 4226 Appendix D, and TOTP against RFC 6238 Appendix B for all three algorithms with 8 digits. 6 digits and 60 s periods are also tested.
- 40 random HMAC cases and 30 random TOTP cases (random algorithm, digits, period, key length and time) checked against Python's `hmac` and `hashlib` (`ReferenceVectorTests.swift`).
- Base32 against RFC 4648 vectors, lenient input, invalid input and round-trips.
- `otpauth://` parsing: issuer in the label vs. the parameter, `%3A` and `+` handling, case, error cases, build→parse round-trip, multiple URIs in one text, and the Google Authenticator migration payload (protobuf built by hand, HOTP entries skipped).
- Account vault: dedupe, move semantics matching `onMove`, update/remove, JSON round-trip, export.
