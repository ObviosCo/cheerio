# Cheerio

Open-source AI meeting notes for macOS. Like Granola, but single-user, local-only, and free.

- **No bots, no cloud, no accounts.** Captures your mic and system audio directly — works with Zoom, Meet, Teams, anything.
- **On-device transcription** via Apple's SpeechAnalyzer/SpeechTranscriber (macOS 26+).
- **On-device summarization** via the Foundation Models framework: your rough notes + the transcript → structured enhanced notes.
- **Calendar-aware** via EventKit (optional).

## Requirements

- macOS 26 (Tahoe) or later, Apple Silicon
- Xcode 26+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Building

```sh
xcodegen generate
open Cheerio.xcodeproj
```

Build and run the `Cheerio` scheme. First run downloads the transcription model for your locale and prompts for microphone + system-audio permissions.

## Project structure

- `CheerioKit/` — platform-portable core (models, transcription, summarization, calendar). Swift package with tests.
- `Cheerio/` — macOS app: audio capture (Core Audio process taps + AVAudioEngine) and SwiftUI.
- `docs/` — [spec](docs/SPEC.md) and [architecture](docs/ARCHITECTURE.md).

## Status

Early scaffold. See [docs/SPEC.md](docs/SPEC.md) for the v1 plan.

## License

MIT
