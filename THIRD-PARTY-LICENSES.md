# Third-Party Licenses

本プロジェクトは以下のサードパーティライブラリに依存しています。

## FFmpeg

- **サイト**: https://ffmpeg.org/
- **ライセンス**: GPL 2 or later（libx264, libx265 を含むため）
- **ライセンス詳細**: https://ffmpeg.org/legal.html
- **ソースコード**: https://ffmpeg.org/download.html
- **バイナリの同梱**: `vendor/ffmpeg/lib/` に含まれる動的ライブラリは `scripts/vendor-ffmpeg.py` で Homebrew からコピーしています。各ライブラリのソースコード入手先は `vendor/ffmpeg/SOURCES.md` を参照してください。
