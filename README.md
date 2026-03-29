# media-player-ios

An iOS media player built around an FFmpeg-based playback pipeline (demux → decode → render), with SwiftUI UI and a full-screen player experience.

## Project entry points

- App entry: `player/player/playerApp.swift` → `AppView`
- Home URL input: `player/player/Screen/HomeScreen/HomeScreenView.swift`
- Settings: `player/player/Screen/SettingScreen/SettingScreenView.swift`
- Player UI: `player/player/Screen/PlayerScreen/PlayerView.swift`
- Playback logic: `player/player/Core/Player/FFmpegPlaybackEngine.swift`

## Docs

See `docs/` (especially `docs/references/`) for architecture, threading/seek rules, FFmpeg integration, and build scripts.
