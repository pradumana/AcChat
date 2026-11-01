# ACchat - Real-Time Voice Messaging App

## Overview

**ACchat** is an instant voice messaging app that replicates the simplicity and fun of classic walkie-talkies. Users join dynamic channels and communicate with friends in real-time over a live audio connection, with a sleek retro-styled interface. Beyond live talk, ACchat records conversations so both parties can replay voice notes or read a transcript later, and channel hosts get an admin panel to manage their room.

## Key Features

- **Real-Time Voice Communication**: Hold the talk button to broadcast; release to listen, walkie-talkie style.
- **Dynamic Channel Management**: Create, join, leave, and delete channels on the fly.
- **Conversation Recording (new)**: The host can start/stop a recording for a channel. The session is saved server-side as a playable voice note and, optionally, transcribed to a text document. Both parties (channel members) can open, play, and read recordings at any time.
- **Host Admin Panel (new)**: Channel creators get a panel listing members, currently connected clients, with the ability to kick a member and broadcast a notice to the whole channel.
- **Persistent Channel Selection**: ACchat remembers your last selected channel.
- **Robust Server Connectivity**: Heartbeat-based online/offline detection with automatic reconnection.

## Technology Stack

- **Frontend**: Flutter (cross-platform, Android/iOS/web/desktop).
- **Backend**: Node.js + Express + `ws` WebSocket for low-latency real-time audio. Recordings are persisted as WAV; transcription is opt-in via the OpenAI Whisper API (set `OPENAI_API_KEY`).

## Installation

1. Clone the repository.
2. Install Flutter dependencies:
   ```bash
   flutter pub get
   ```
3. Install server dependencies:
   ```bash
   npm install
   ```
4. Run the server:
   ```bash
   node server.js
   ```
5. Run the app:
   ```bash
   flutter run
   ```

> The app connects to the server address configured in `lib/services/api_service.dart` (`_serverBase`). Point it at your server's address before building.

### Transcription (optional)

Set an OpenAI API key on the server to enable "Transcribe" on recordings:
```bash
OPENAI_API_KEY=sk-... node server.js
```
Without a key, voice-note saving and playback still work; only transcription is unavailable.

## Usage

1. Launch ACchat and grant microphone permission.
2. Select or create a channel.
3. Hold the talk button to speak; release to listen.
4. Open Channel Options to view/record conversations or, if you are the host, open the Admin Panel.

## Future Enhancements

- End-to-end encryption for voice.
- Configurable server address in-app.
- Roles and permissions beyond host/member.

## License

MIT.
