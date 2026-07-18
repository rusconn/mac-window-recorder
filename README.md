# mac-window-recorder

A macOS command-line tool for recording individual application windows with accurate colors and minimal stutter.

**This is a vibe coding project.**

## Features

- Per-window capture via ScreenCaptureKit
- Accurate color reproduction (avoids VideoToolbox color tint issues)
- Hardware encoding (VideoToolbox) and software encoding (ffmpeg/libx264/libx265)
- VFR (Variable Frame Rate) support
- System audio and microphone capture
- Crop support
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
window-recorder --window Safari --output out.mp4 --codec h264 --no-system-audio --no-microphone
```

### Options

| Option | Description |
|---|---|
| `--window <title>` | Select window by title |
| `--output <file>` | Output filename |
| `--codec <h264\|hevc>` | Select codec |
| `--crop <T:B:L:R>` | Crop pixels from top, bottom, left, right |
| `--ffmpeg` | Use software encoding (libx264/libx265) instead of hardware |
| `--system-audio` | Capture system audio |
| `--microphone <name>` | Select microphone by name |
| `--no-system-audio` | Disable system audio |
| `--no-microphone` | Disable microphone |
| `--debug` | Show some debug logs |
| `-h, --help` | Show help |

## License

[GPL-2.0](LICENSE)
