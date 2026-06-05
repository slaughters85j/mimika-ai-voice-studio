# Privacy Policy for Pocket TTS

**Last updated:** May 23, 2026

## Summary

Pocket TTS is a fully on-device macOS application. It does not collect,
store, or transmit any personal data, usage analytics, or crash reports.
This document explains exactly what does and does not leave your Mac.

## What we do not collect

Pocket TTS contains no analytics framework, no telemetry, no
crash-reporting SDK, no advertising SDK, and no user-tracking code.
Specifically:

- No personal information (name, email, phone, address)
- No account or sign-up — the app has no concept of a user account
- No usage analytics or feature-use tracking
- No crash reports
- No device identifiers, advertising identifiers, or fingerprints
- No location data
- No contacts, photos, calendars, or other system data outside the
  files you explicitly open in the app
- No iCloud sync or any other cloud synchronization of user data

## What stays on your Mac

The following are stored only on your Mac, inside the application's
sandbox container, and never leave the device unless you explicitly
export them:

- Audio files you import for voice cloning or re-voicing
- Voice presets you create (audio waveforms + extracted voice
  conditioning features)
- Chat history and AI-generated scripts when you use the Chat or
  AI Write features
- Application preferences

You can delete any of this at any time by removing entries in the
Voice Manager, clearing chat history from within the app, or removing
the app entirely.

## What does leave your Mac

There are three categories of outbound network traffic, all initiated
by your explicit action:

### 1. Model downloads

When you first use a feature that requires an additional model, that
model is downloaded from Hugging Face (huggingface.co):

- **Parakeet TDT v3** (~450 MB) — downloaded on first use of any
  transcription feature (Voice Changer, Speaker Isolation, AI Chat
  dictation)
- **FluidAudio diarizer** (~50 MB) — downloaded on first use of
  Speaker Isolation
- **HTDemucs** (~287 MB) — only downloaded if you opt into background-
  preservation under Speaker Isolation
- **Fish Audio S2 Pro** (~3.5 GB) — only downloaded if you select the
  Fish Audio TTS engine

Each download transmits your IP address and a standard User-Agent
string to Hugging Face's servers — the same information sent by any
browser visiting their site. Hugging Face's own privacy policy governs
how they handle that connection. Pocket TTS does not send any other
information with these requests.

If you never use a given feature, the corresponding model is never
downloaded.

### 2. Local LLM endpoint connections

The Chat and AI Script Writer features connect to a Large Language
Model endpoint that *you* configure (default `http://localhost:1234/v1`,
or any OpenAI-compatible URL you set in Settings). When you send a
message, that message is transmitted to the endpoint you configured.

If the endpoint you configure is a local server on your own machine
(LM Studio, Ollama, llama.cpp, etc.), the data does not leave your
Mac. If you configure a remote URL, the data is sent there. The
choice is yours; Pocket TTS does not monitor or proxy those
connections.

If you do not use the Chat or AI Write features, no LLM traffic
occurs.

### 3. Standard macOS background traffic

Like any macOS application, the operating system may make standard
background connections on behalf of the app (notarization stapling
checks, certificate revocation lookups, etc.). These are governed by
macOS and Apple, not by Pocket TTS.

## Camera, microphone, and other system permissions

Pocket TTS does not request access to your camera or contacts.
Microphone access is requested only if you use the dictation feature
in the Chat tab; recorded audio is transcribed locally and never
transmitted. File-system access is requested only when you import
audio or save output, and is limited to files you explicitly choose.

## Children

Pocket TTS is not directed at children under 13 and does not
knowingly collect any data that could identify a child. The
application has no concept of a user account or user identity.

## Changes to this policy

If we update this policy, the "Last updated" date at the top will
change. Significant changes will also be noted in the application's
release notes on GitHub.

## Contact

For questions about this policy, please open an issue at:

https://github.com/slaughters85j/mimika-ai-voice-studio/issues
