# media-player-ios

An iOS media player built around an FFmpeg-based playback pipeline (demux → decode → render), with SwiftUI UI and a full-screen player experience.

# PREVIEW

<table>
  <tr>
    <td><img src="demo/home.png" width="300" /></td>
    <td><img src="demo/setting.png" width="300" /></td>
    <td><img src="demo/player.png" width="300" /></td>
  </tr>
</table>

## Project entry points

- App entry: `player/player/playerApp.swift` → `AppView`
- Home URL input: `player/player/Screen/HomeScreen/HomeScreenView.swift`
- Settings: `player/player/Screen/SettingScreen/SettingScreenView.swift`
- Player UI: `player/player/Screen/PlayerScreen/PlayerView.swift`
- Playback logic: `player/player/Core/Player/FFmpegPlaybackEngine.swift`

## Subtitles (style + settings)

The player renders **text subtitles** as an RGBA bitmap overlay (CoreGraphics/CoreText) and displays it on top of video.

- **Where style is defined**: `player/player/Core/SubtitleOverlay/SubtitleBitmapRenderer.swift`
- **Where user settings live (SwiftData)**: `player/player/Core/Settings/SubtitleSettings.swift`
- **Where settings are applied during playback**: `player/player/Screen/PlayerScreen/PlayerView.swift` → `PlayerController.applySubtitleSettings(...)`

### Enable Bold (OLED-style drop shadow)

The Settings screen includes **Enable Bold** which switches subtitle rendering to:

- **Bold text**
- **Drop shadow** (Media3-like `EDGE_TYPE_DROP_SHADOW` look)
- **No background box** (sets background to Clear when enabled)

Implementation notes:

- Setting key: `SubtitleSettings.isBoldEnabled`
- Render behavior: when `isBoldEnabled = true`, `SubtitleBitmapRenderer` draws text with a CoreGraphics shadow instead of the outline/stroke path.