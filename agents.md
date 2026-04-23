# HUDini Codebase Guide

## What this project is

HUDini is an iOS app (SwiftUI) that connects to [Brilliant Frame](https://brilliant.xyz) AR glasses via BLE. It provides real-time speech transcription and translation — you speak in one language, and the translated text appears on both the iPhone screen and the Frame glasses display.

## Architecture overview

```
iPhone App (Swift/SwiftUI)          Frame Glasses (Lua)
┌─────────────────────────┐         ┌──────────────────┐
│  HUDLiveView (main UI)  │         │  FrameEmbeddedApp │
│         │                │         │  (main.lua)       │
│  FrameBluetoothManager  │◄──BLE──►│                    │
│    │          │          │         │  Mic always on     │
│    │    SFSpeechRecognizer         │  Streams audio     │
│    │          │          │         │  Displays captions │
│    │   Apple Translation │         │  Tap = toggle      │
│    │          │          │         └──────────────────┘
│    ▼          ▼          │
│  renderedText → iPhone UI│
│  SHOW_CAPTION → Glasses  │
└─────────────────────────┘
```

## Core data flow

1. Frame mic records audio (8kHz/16bit), batches into ~240-byte BLE packets
2. `FrameBluetoothManager` receives packets, feeds to `SFSpeechRecognizer`
3. Recognition produces partial transcripts → sent to translation pipeline
4. `HUDTranslationClient` → `AppleTranslationService` translates text
5. Result updates `renderedText` (iPhone display) and sends `SHOW_CAPTION` to Frame

## Key files

### Critical path (touch these carefully)

| File | Purpose |
|------|---------|
| `Managers/FrameBluetoothManager.swift` | Core BLE connection, audio processing, recognition, translation pipeline. The most important file. |
| `Managers/FrameEmbeddedApp.swift` | Lua script uploaded to Frame glasses. Controls mic, display, tap handling, audio streaming. |
| `Views/HUDLiveView.swift` | Main UI — display card, language pickers, start/stop button, connection status. |
| `Services/AppleTranslationService.swift` | Apple Translation framework wrapper. Uses `installedSource:target:` — requires downloaded language packs. |
| `Services/HUDTranslationClient.swift` | Translation entry point. Routes to AppleTranslationService. |

### Supporting files

| File | Purpose |
|------|---------|
| `Managers/TranscriptionManager.swift` | iPhone mic fallback path (used when Frame is NOT connected) |
| `Services/HUDTranscriptionService.swift` | AVAudioEngine + SFSpeechRecognizer for iPhone mic |
| `Services/HUDTranscriptionTranslationPipeline.swift` | Combined transcription+translation for iPhone mic path |
| `Managers/HUDSuggestionManager.swift` | AI-generated reply suggestions (OpenAI GPT-4o-mini) |
| `Managers/SuggestionManager.swift` | Contains `HUDOpenAISuggestionService` used by HUDSuggestionManager |
| `Managers/AuthenticationManager.swift` | Email/password + Google OAuth sign-in |
| `Managers/HUDConversationHistoryStore.swift` | JSON file persistence for conversation history |
| `Models/TranslationLanguageOptions.swift` | Supported languages list (EN, ES, FR, AR, DE, HI, JA, KO, PT, RU, ZH) |
| `Managers/TranslationManager.swift` | Contains `TranslationService` protocol + `TranslationError` enum (shared types) |
| `Config/APIConfig.swift` | Base URLs, feature flags, Google OAuth client IDs |
| `Views/AdminFrameLogView.swift` | Admin panel — dev log viewer, send-to-glasses text field, reset button |
| `Views/BluetoothDemoView.swift` | Settings > Bluetooth — device discovery, connect/disconnect, prefs |

## Frame glasses Lua app

The Lua script in `FrameEmbeddedApp.swift` is uploaded to the Frame over BLE on first connection (or version mismatch). Key behavior:

- **Mic is always on** — starts recording on boot, never stops
- **Audio batching** — accumulates small mic reads into full-size BLE packets (~240 bytes) before sending, reducing per-packet overhead
- **BLE send is bounded** — 3 retry attempts then drops the packet (prevents main loop stall)
- **SYNC_STATE** — only controls the display indicator (Mic: ON/OFF), not the mic hardware
- **SHOW_CAPTION** — displays text on the OLED (partial or final)
- **RESET** — stops mic, clears all state, restarts mic fresh
- **Tap** — sends `MIC_REQUEST` event to iOS app, which toggles recognition on/off

The app version is embedded in both `FrameEmbeddedApp.swift` (Lua) and `FrameBluetoothManager.swift` (Swift). Both must match. Bumping triggers re-upload on next connection.

## Audio pipeline details

- Frame records at **8kHz, 16-bit signed PCM**
- Packets: 3-byte header (0x20 + 2-byte sequence) + audio payload
- iOS side: DC offset removal → auto gain control → upsample 8kHz→16kHz (linear interpolation) → feed to `SFSpeechRecognizer`
- Recognition produces partial results → translation pipeline → display
- Translation bypass: when source==target language (e.g., en→en), skip translation entirely

## Translation

- Uses Apple's `Translation` framework (iOS 26+) via `AppleTranslationService`
- Requires language packs downloaded in Apple's Translate app
- `TranslationSession(installedSource:target:)` — fails with `.notInstalled` if pack missing
- Pre-warmed on app init to avoid ~700ms cold start
- Typical latency after warm-up: 30-50ms per call

## Known limitations

- **8kHz BLE audio quality** — lower quality than iPhone mic. SFSpeechRecognizer struggles more with Spanish and accented speech at this sample rate
- **16kHz/8-bit recording was attempted but the 8-bit PCM encoding from Frame is not correctly understood** — needs investigation with audio playback verification before trying again
- **BLE throughput ceiling** — ~100 packets/sec max, delivering ~80% of real-time audio with batching
- **SFSpeechRecognizer with Spanish locale still transcribes English words** — it doesn't reject non-target-language audio

## Important patterns

- `FrameBluetoothManager` is `@MainActor` and the central hub for all Frame communication
- The `isStreaming` flag means "recognition is active", NOT "mic is on" (mic is always on)
- `startListening()` / `stopListening()` control recognition, not the mic
- Suggestion generation (OpenAI) happens on iPhone only — not sent to Frame
- Conversation history persists to JSON when listening stops
- Dev logs are viewable in Admin panel and can be copied to clipboard

## Build & run

- Xcode project at `app/HUDini.xcodeproj`
- Requires iOS 26+ device (Translation framework)
- Requires Brilliant Frame glasses for BLE features
- iPhone mic fallback works without Frame connected

## Debugging tips

- **Admin panel** (`Settings > Admin`) shows real-time BLE log with timestamps
- **Copy Log** button exports full session log for analysis
- **Reset Frame** button clears Frame state and restarts mic
- Look for `[TIMING]` prefixed log entries for pipeline latency measurements
- `audioPacket milestone` entries show throughput (count=100 every ~1 second is good)
- `recognitionTask ignored cancellation error No speech detected` means audio reached recognizer but wasn't intelligible
