# Cheerio — Spec

An open-source, single-user Granola alternative for macOS (and later iOS). Everything runs on-device using Apple's local models. No accounts, no cloud, no telemetry.

## Problem

Granola-style AI meeting notes require sending your meetings to someone else's servers and paying a subscription. Apple now ships everything needed to do this locally: SpeechAnalyzer/SpeechTranscriber for transcription (macOS 26+) and the Foundation Models framework for summarization.

## Goals (v1)

1. **Capture** — Record both sides of a meeting: microphone (you) and system audio (everyone else on Zoom/Meet/Teams), via Core Audio process taps. Works with any meeting app — no bots joining calls.
2. **Transcribe** — Live, on-device transcription of both streams via SpeechTranscriber, labeled "Me" / "Them", with timestamps.
3. **Notes** — A plain-text scratchpad during the meeting. Rough notes are first-class input.
4. **Enhance** — After the meeting, the on-device Foundation Model merges your rough notes with the transcript into structured enhanced notes: summary, key points, decisions, action items.
5. **Calendar** — Read today's events via EventKit; suggest recording when a meeting starts; attach notes to the event.
6. **Library** — Browse, search, and export past meetings (Markdown export).

## Non-goals (v1)

- Multi-user, sharing, sync, or any server component
- Speaker diarization beyond Me/Them channel separation
- Meeting bots or calendar-service integrations beyond local EventKit
- Windows/Linux
- iOS (v2 — core logic lives in a shared package to make this cheap)

## Requirements

- macOS 26 (Tahoe)+, Apple Silicon
- Permissions: microphone, system audio capture (TCC), calendar (optional)
- Transcription model downloaded on first run via `AssetInventory` (one-time, per-locale)

## Success criteria

- Zero-config record button that captures a Zoom call with no bot
- Live transcript visible during the meeting with < 2s lag
- Enhanced notes generated in < 30s for a 60-minute meeting
- Audio optionally discarded after transcription (privacy default: keep 7 days)

## v2 candidates

- iOS app (in-person meetings, mic-only)
- Pluggable summarization models via the `LanguageModel` protocol (WWDC26) — Claude, local MLX models
- Semantic search across meetings
- Speaker diarization within the system-audio channel
- Obsidian/Markdown folder auto-export
