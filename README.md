# Blitztext App – Extended Fork

This is a fork of [Blitztext App](https://github.com/cmagnussen/blitztext-app), the open-source macOS dictation menubar app. We took the original invitation to "use, fork, adapt and share" seriously: this fork is in daily production use at a German mortgage brokerage and grew from a dictation tool into a full dictation + meeting-transcription workflow.

All credit for the foundation, the app concept and the original codebase goes to the upstream project. License stays MIT.

## What this fork adds

### History window
- Every dictation and meeting transcript is kept locally (`history.json`, max 1000 entries), searchable, copyable.
- Two tabs: **Diktate | Meetings**. Meeting entries show date, duration, participants, summary, and a collapsible transcript.
- Inline renaming of meeting titles and speakers (the transcript re-renders live).

### Meeting mode
- Records **microphone + system audio** (ScreenCaptureKit), so it works with headphones in Zoom/Teams/Webex/Google Meet.
- Transcription after the meeting (no live streaming), selectable per recording:
  - **Cloud**: ElevenLabs **Scribe v2** with speaker diarization ("Anna: … / Speaker 2: …"), routed through the optional self-hosted server (below).
  - **Local**: WhisperKit on-device, no audio leaves the Mac (no speaker labels).
- Auto-generated title + bullet summary via LLM after transcription.
- Manual participants can be added when diarization merges voices (e.g. phone on speaker).
- Optional **second-brain export**: each meeting as a Markdown file with frontmatter into a folder of your choice (works great with Obsidian).

### Meeting detection
- Detects running meetings two ways: meeting-app launch (Zoom/Teams/Webex) plus a microphone-activity signal (CoreAudio, 5 s polling), and Google Meet via browser window titles.
- Shows a floating prompt banner ("Zoom-Meeting erkannt – aufzeichnen?") instead of a macOS notification, so no notification permission is needed. 60 s dedupe; the app's own recordings never trigger it.

### Dictation improvements
- **F13 dictation key** via CGEvent tap: one physical key starts/stops dictation system-wide; the keypress is swallowed so it doesn't type anything.
- Recording overlay at the bottom of the screen with level meter and timer, plus an optional short start sound.
- Long dictations no longer die on timeouts (120 s request / 900 s resource); failed recordings are rescued to a `gerettete-aufnahmen` folder instead of being lost.
- First-word-swallowed bug fixed (`prepareToRecord()` before `record()`).
- **E-mail tone** as a fourth mode in the text improver: formats the dictation as a ready-to-send mail, keeps Du/Sie exactly as dictated, invents nothing.

### Optional self-hosted server (`server/`)
A zero-dependency Node.js proxy (one file, systemd unit included) that solves two things:

1. **Key protection for teams**: the real OpenAI key lives only on the server. Each user gets an app password (`APP_PASSWORD_<NAME>` env vars), enters it in the app instead of an API key, and can be revoked individually. The log shows per-user usage, never content.
2. **Meeting route**: `/v1/meeting/transcriptions` accepts the finished m4a, submits it to fal.ai's Scribe v2 queue, polls until done and returns speaker-labeled words. The app sees one long POST.

The app works without it: leave the new **Server (optional)** field in the settings empty and the app talks directly to the OpenAI API with your own key, exactly like upstream. Cloud meeting transcription requires the server; local WhisperKit meetings work either way.

## Build and run

Same as upstream:

```bash
brew install xcodegen
./build.sh --install --run
```

Optional fixed code-signing identity, so macOS TCC grants (Accessibility, Screen Recording) survive rebuilds:

```bash
BLITZTEXT_SIGN_IDENTITY="My Dev Cert" ./build.sh --install
```

Permissions: Microphone and Accessibility as upstream; **Screen Recording** additionally for meeting mode and Google Meet detection.

Server setup: copy `server/` to a host, create `.env` from `.env.example` (`OPENAI_API_KEY`, `APP_PASSWORD…`, optional `FAL_API_KEY` for meeting diarization), run it via the included systemd unit behind any HTTPS reverse proxy, and put the base URL into the app's server field.

## Tests

```bash
cd BlitztextMac
xcodebuild -project BlitztextMac.xcodeproj -scheme BlitztextMac -destination 'platform=macOS' ONLY_ACTIVE_ARCH=YES test
```

61 unit tests cover the transcript store, speaker segmentation and rendering, meeting detection, recorder mixing and the second-brain exporter.

## Practical numbers from daily use

- Dictation: ~0.6 ct per minute (Whisper via OpenAI).
- Meetings: ~0.22 $ per hour (Scribe v2 via fal.ai), recordings up to ~2 h (data-URI upload limit).
- Multiple users on one server with individual passwords; transcripts stay on each user's Mac.

## Data flow

```text
Dictation (direct mode):  Your Mac -> OpenAI API (your key, as upstream)
Dictation (server mode):  Your Mac -> your server -> OpenAI API (key stays on server)
Meeting cloud:            Your Mac -> your server -> fal.ai (ElevenLabs Scribe v2)
Meeting local:            Your Mac -> WhisperKit/CoreML on device
History:                  local JSON on your Mac, nothing leaves the machine
```

## Upstream documentation, license, credits

Setup walkthrough, privacy notes, local models, contributing, trademarks and legal: see the original repo [cmagnussen/blitztext-app](https://github.com/cmagnussen/blitztext-app) and the `docs/` folder. The name "Blitztext" belongs to the upstream project (see [TRADEMARKS.md](TRADEMARKS.md)); this fork exists as a thank-you and feedback, not as a competing product.

License: MIT, unchanged from upstream (see [LICENSE](LICENSE)). Same disclaimer applies: experimental, no warranty, no support guarantee.
