# mac-window-recorder

A macOS command-line tool for recording individual application windows with accurate colors and minimal stutter.

**This is a vibe coding project.**

## Features

- Per-window capture via ScreenCaptureKit
- Crop support
- System audio and microphone capture
- Accurate color reproduction
- Hardware encoding (VideoToolbox) and software encoding (ffmpeg/libx264/libx265)
- VFR (Variable Frame Rate) support
- Interactive terminal UI with full CLI override

## Requirements

- macOS 15.0+
- Swift 6.0+ (Xcode not required)
- Screen Recording permission (System Settings > Privacy & Security)

## Build

```sh
swift build -c release
```

The binary is at `.build/release/window-recorder`.

## Usage

Run interactively:

```sh
window-recorder
```

Or fully non-interactive:

```sh
window-recorder --window Safari --system-audio --no-microphone --codec h264 --output out.mp4 
```

### Options

| Option | Description |
|---|---|
| `--window <title>` | Select window by title |
| `--crop <T:B:L:R>` | Crop pixels from top, bottom, left, right |
| `--system-audio` | Capture system audio |
| `--no-system-audio` | Disable system audio |
| `--microphone <name>` | Select microphone by name |
| `--no-microphone` | Disable microphone |
| `--codec <h264\|hevc>` | Select codec |
| `--ffmpeg <preset>` | Use software encoding (libx264/libx265). Preset: ultrafast/superfast/veryfast/faster/fast/medium/slow/slower/veryslow |
| `--output <file>` | Output filename |
| `--debug` | Show some debug logs |
| `-h, --help` | Show help |

## License

[GPL-2.0-or-later](LICENSE)
