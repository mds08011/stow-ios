# Stow for iOS

The iPhone and iPad version of [Stow](https://github.com/mds08011/stow), the Android dictation app. Record a voice note, and Groq's `whisper-large-v3-turbo` turns it into text on the clipboard.

It exists because [Stow Web](https://github.com/mds08011/stow-web) cannot do three things on iOS, and a native app can:

1. Keep recording with the screen locked or another app in front.
2. Finish an upload after the phone is locked, and wait for signal when there is none.
3. Start from the Action Button or the Lock Screen. This one is planned, not built.

This is a personal build installed through TestFlight. It is not on the App Store.

**Status: scaffold.** It compiles: the first push built the app unsigned on a macOS runner (Xcode 16.4) and passed the `StowCore` tests. It has never run on a device, because it is not signed yet. See [docs/plan.md](docs/plan.md).

## Layout

| Path | What it is |
|---|---|
| `StowCore/` | A Swift package holding everything that is plain logic: request building, response parsing, retry timing, history. It builds and tests on Linux. |
| `Stow/` | The app: SwiftUI screens, the recorder, the background uploader, the Keychain. It builds only on macOS. |
| `project.yml` | The Xcode project, as [XcodeGen](https://github.com/yonaskolb/XcodeGen) input. The `.xcodeproj` is generated and never committed. |
| `.github/workflows/build.yml` | Compiles both on every push. No signing, no secrets. |
| `docs/plan.md` | What is built, what is next, and what is deliberately left out. |
| `docs/signing.md` | The one-time Apple setup, and how a build reaches the phone. |

## Building

There is no Mac behind this repo. GitHub Actions is the compiler:

1. Push. The **Build check** workflow runs the `StowCore` tests on Linux and builds the app, unsigned, on a macOS runner.
2. Read the run. A red build is a compile error to fix and push again.

The `StowCore` tests also run on any machine with Docker:

```bash
docker run --rm -v "$PWD/StowCore":/pkg -w /pkg swift:5.10 swift test
```

On a Mac, `brew install xcodegen && xcodegen generate` produces `Stow.xcodeproj`.

## What it shares with the other two apps

The transcription request, the retry timing and the quality thresholds are ports of Android's, and the comments name the function each one came from. [stow/docs/parity.md](https://github.com/mds08011/stow/blob/main/docs/parity.md) is the source of truth for what the apps share. The polish prompts are not here yet. When they arrive they join the drift check in stow-web, as a third copy that is compared by machine.

## Privacy

The Groq API key is stored in the iOS Keychain on the device and sent only to `api.groq.com`. Notes and recordings stay in the app's own storage. Nothing else leaves the phone. No key, certificate or signing file belongs in this repository, and `.gitignore` blocks the usual file types.

## License

GPL-3.0, the same as Android Stow. See [LICENSE](LICENSE).
