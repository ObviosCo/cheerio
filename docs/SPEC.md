# Cheerio — Spec

An open-source, single-user Granola alternative for macOS (and later iOS). Everything runs on-device: Apple's local models for speech and summarization, plus a bundled Sortformer model for telling speakers apart. No accounts, no cloud, no telemetry.

## Problem

Granola-style AI meeting notes require sending your meetings to someone else's servers and paying a subscription. Apple now ships everything needed to do this locally: SpeechAnalyzer/SpeechTranscriber for transcription (macOS 26+) and the Foundation Models framework for summarization.

## Goals (v1)

1. **Capture** — Record both sides of a meeting: microphone (you) and system audio (everyone else on Zoom/Meet/Teams), via Core Audio process taps. Works with any meeting app — no bots joining calls.
2. **Transcribe** — Live, on-device transcription of both streams via SpeechTranscriber, labeled "Me" / "Them", with timestamps.
3. **Notes** — A Markdown scratchpad during the meeting: entered and rendered as Markdown, since rough notes want structure and that's what people expect a text box to accept now. Rough notes are first-class input. (Plain text is what's built today.)
4. **Enhance** — After the meeting, the on-device Foundation Model merges your rough notes with the transcript into structured enhanced notes: summary, key points, decisions, action items.
5. **Calendar** — Read today's events via EventKit; suggest recording when a meeting starts; attach notes to the event.
6. **Library** — Browse, search, and export past meetings (Markdown export).
7. **Speakers** — Tell people apart *within* a channel, not just Me vs Them: Sortformer diarization as a post-pass over the recorded audio, voices enrolled by name, and a per-meeting roster of who was there. Hand corrections outrank the model. Originally a v1 non-goal; it turned out to be the difference between a usable in-person transcript and one where three people are all "Me".

## Non-goals (v1)

- Multi-user, sharing, sync, or any server component
- Real-time speaker naming *during* a recording — diarization is a post-pass over the CAF files, so the live transcript shows Me/Them and names appear once the meeting stops
- More than four distinct speakers resolved per channel (Sortformer's hard limit)
- Meeting bots or calendar-service integrations beyond local EventKit
- Windows/Linux
- iOS (v2 — core logic lives in a shared package to make this cheap)

## Requirements

- macOS 26 (Tahoe)+, Apple Silicon
- Permissions: microphone, system audio capture (TCC), calendar (optional)
- Transcription model downloaded on first run via `AssetInventory` (one-time, per-locale)
- Diarization model (~93 MB, NVIDIA Open Model License) fetched at build time by `Scripts/fetch-models.sh` and bundled — never downloaded at runtime
- Distributed outside the Mac App Store. App Sandbox has to be off for process taps to capture anything at all, which makes the App Store unavailable; see [ARCHITECTURE.md](ARCHITECTURE.md#permissions--entitlements)

## Success criteria

- Zero-config record button that captures a Zoom call with no bot
- Live transcript visible during the meeting with < 2s lag
- Enhanced notes generated in < 30s for a 60-minute meeting
- Audio optionally discarded after transcription (privacy default: keep 7 days)

## v2 candidates

- iOS app (in-person meetings, mic-only)
- Pluggable summarization models via the `LanguageModel` protocol (WWDC26) — Claude, local MLX models
- Semantic search across meetings
- Real-time speaker naming during capture (streaming Sortformer alongside the engines, rather than a post-pass)
- Obsidian/Markdown folder auto-export
