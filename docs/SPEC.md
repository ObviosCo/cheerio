# Cheerio — Spec

An open-source, single-user meeting-transcript app for macOS (and later iOS), built around the idea that a transcript is something an AI agent can act on, not just something you reread. Local models are how it gets there without a subscription or a third-party service: Apple's local models for speech and summarization, plus a bundled Sortformer model for telling speakers apart. No accounts, no cloud, no telemetry.

## Problem

Meeting transcripts are already used as instructions for AI agents — record a call, or a session of thinking out loud, then paste the transcript into an agent and let it act on what was said. That workflow is manual today, and a chat box is the wrong container for it: prompt boxes are size-limited, whereas a transcript's whole value is being long-form. Granola-style AI notes handle the note-taking half of this well, but require sending your meetings to someone else's servers and paying a subscription for it. Apple now ships everything needed to do the note-taking locally — SpeechAnalyzer/SpeechTranscriber for transcription (macOS 26+) and the Foundation Models framework for summarization — which removes the subscription and the third party, and leaves room to build the second half: making the transcript something an agent can pick up directly instead of something you copy and paste.

## Goals (v1)

1. **Capture** — Record both sides of a meeting: microphone (you) and system audio (everyone else on Zoom/Meet/Teams), via Core Audio process taps. Works with any meeting app — no bots joining calls.
2. **Transcribe** — Live, on-device transcription of both streams via SpeechTranscriber, labeled "Me" / "Them", with timestamps.
3. **Notes** — A Markdown scratchpad during the meeting: entered and rendered as Markdown, since rough notes want structure and that's what people expect a text box to accept now. Rough notes are first-class input. (Plain text is what's built today.)
4. **Enhance** — After the meeting, the on-device Foundation Model merges your rough notes with the transcript into structured enhanced notes: summary, key points, decisions, action items.
5. **Calendar** — Read today's events via EventKit; suggest recording when a meeting starts; attach notes to the event.
6. **Library** — Browse, search, and export past meetings (Markdown export).
7. **Speakers** — Tell people apart *within* a channel, not just Me vs Them: Sortformer diarization as a post-pass over the recorded audio, voices enrolled by name, and a per-meeting roster of who was there. Hand corrections outrank the model. Originally a v1 non-goal; it turned out to be the difference between a usable in-person transcript and one where three people are all "Me".
8. **Menu-bar first** — The `MenuBarExtra` is the primary surface, not a mirror of the sidebar: start, stop, and tell at a glance whether it's recording, without finding a window first. The window becomes the library — where you read, search, and correct. The reasoning is that the moment you need to start recording is the moment you have the least attention to spare, and it should cost one click from wherever you already are.
9. **Actionable** — transcripts are built to be consumed by the AI agents already running on your machine, not just read by you. Local surfaces for this: an MCP server that local agents can query, a transcript-ready callback that fires when a meeting finishes processing, and a directive-capture mode for talking instructions at the app instead of narrating a meeting. Speaker identity doubles as a trust signal: when the owner (`EnrolledSpeaker.isMe`) commits to something, their agent can treat it as an instruction to act on directly; when someone else does, it becomes a follow-up to track and prepare for — never an action taken on their behalf.

## Non-goals (v1)

- Multi-user, sharing, sync, or any server component — a local stdio MCP endpoint that only speaks to agents on the same machine doesn't count as a server in this sense; it never listens on a network socket or accepts a remote connection
- Real-time speaker naming *during* a recording — diarization is a post-pass over the CAF files, so the live transcript shows Me/Them and names appear once the meeting stops
- More than four distinct speakers resolved per channel (Sortformer's hard limit)
- Meeting bots or calendar-service integrations beyond local EventKit
- Windows/Linux
- iOS (v2 — core logic lives in a shared package to make this cheap)

## Requirements

- macOS 26 (Tahoe)+, Apple Silicon
- Permissions: microphone, system audio capture (TCC), calendar (optional)
- Transcription model downloaded on first run via `AssetInventory` (one-time, per-locale)
- Diarization model (~93 MB, CC BY 4.0 — attribution in `THIRD-PARTY-NOTICES.md`) fetched at build time by `Scripts/fetch-models.sh` and bundled — never downloaded at runtime
- Distributed outside the Mac App Store. App Sandbox has to be off for process taps to capture anything at all, which makes the App Store unavailable; see [ARCHITECTURE.md](ARCHITECTURE.md#permissions--entitlements)

## Success criteria

- Zero-config record button that captures a Zoom call with no bot
- Starting a recording takes one click from the menu bar, without surfacing the window
- Whether a recording is running is answerable at a glance, with the app in the background
- Live transcript visible during the meeting with < 2s lag
- Enhanced notes generated in < 30s for a 60-minute meeting
- Audio optionally discarded after transcription (privacy default: keep 7 days)

## v2 candidates

- iOS app (in-person meetings, mic-only)
- Pluggable summarization models via the `LanguageModel` protocol (WWDC26) — Claude, local MLX models
- Semantic search across meetings
- Real-time speaker naming during capture (streaming Sortformer alongside the engines, rather than a post-pass)
- Obsidian/Markdown folder auto-export
- A first-party CLI, once the transcript-ready callback and MCP server (v1) prove out the shape agents actually want
