# Vendored FFmpeg Sources

本プロジェクトの `vendor/ffmpeg/lib/` に含まれる動的ライブラリは
Homebrew でビルドされた ffmpeg を `scripts/vendor-ffmpeg.sh` で同梱しています。

## ソースコードの入手方法

これらのライブラリは GPL ライセンスで配布されています。GPL の要求により、
バイナリを配布する場合はソースコードまたはソースコードの入手方法を提供します。

| ライブラリ | リポジトリ |
|---|---|
| FFmpeg | https://ffmpeg.org/download.html |
| libx264 | https://code.videolan.org/videolan/x264 |
| libx265 | https://bitbucket.org/multicoreware/x265_git |
| SvtAv1 | https://gitlab.com/AOMediaCodec/SVT-AV1 |
| libvpx | https://chromium.googlesource.com/webm/libvpx |
| libaom | https://aomedia.googlesource.com/aom |
| libdav1d | https://code.videolan.org/videolan/dav1d |
| libopus | https://github.com/xiph/opus |
| libvorbis | https://github.com/xiph/vorbis |
| libtheora | https://github.com/xiph/theora |
| libmp3lame | https://github.com/lameproject/lame |
| libmpg123 | https://github.com/mk100122/mpg123 |
| libogg | https://github.com/xiph/ogg |
| libvmaf | https://github.com/Netflix/vmaf |
| libsnappy | https://github.com/google/snappy |
| liblzma | https://github.com/tukaani-project/xz |

## ビルド方法

`scripts/vendor-ffmpeg.sh` を参照してください。Homebrew の ffmpeg を
コピーし、インストール名を修正するスクリプトです。
