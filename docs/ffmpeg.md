# ffmpeg

## 導入理由

VideoToolboxによるハードウェアエンコード結果には僅かな変色が見られた。これを嫌う場合のオプションとしてffmpeg(libx264/libx265)によるソフトウェアエンコードをサポートした。

## VFRエンコードの実現

ハードウェアエンコードがVFRで書き出すのでソフトウェアエンコード(ffmpeg)でもVFRにしたい。ffmpegプロセスへstdinパイプでエンコードさせる方法があるが、フレームの到着タイミングや表示時刻を伝達するメカニズムがない。そこでlibav C API（libx264/libx265）を利用することにした。

### 検討した手段

| 手段 | 判定 | 理由 |
|------|------|------|
| rawvideo stdin + `-vsync vfr` | 却下 | 入力PTSが固定間隔のため出力もCFRのまま |
| パイプにPTSを埋め込む独自プロトコル | 却下 | ffmpegのカスタムdemuxerをC言語で実装する必要がある |
| AVFoundation直接キャプチャ | 却下 | ウィンドウ単位キャプチャ（SCStream）が失われる |
| raw一時ファイル + concat demuxer | 却下 | ピクセルフォーマットや解像度のper-file指定が困難 |
| BMP一時ファイル + concat demuxer | 却下 | ディスク使用量が巨大（約57GB/2分） |
| **libav C API直接利用** | **採用** | リアルタイムエンコード、ディスクI/O不要、VFR対応 |

### libav C API方式の処理フロー

1. `avformat_alloc_output_context2` で出力コンテキストを確保
2. `avcodec_find_encoder_by_name` でlibx264/libx265エンコーダを取得
3. `sws_scale` でBGRA→YUV420P変換（BT.709カラースペース指定）
4. `avcodec_send_frame` / `avcodec_receive_packet` でフレームごとにエンコード
5. `av_interleaved_write_frame` で各パケットに実際のPTSを付与して書き出し

### 外部依存

コンパイル時に以下のffmpeg Cライブラリが必要

| ライブラリ | 用途 |
|---|---|
| libavcodec | エンコード |
| libavformat | コンテナ書き込み・mux |
| libavutil | フレーム管理 |
| libswscale | BGRA→YUV420P変換 |

## ffmpeg の同梱（ベンダリング）

### 経緯

コンパイル時に `$(brew --prefix ffmpeg)` へ、実行時に `/opt/homebrew/opt/ffmpeg/lib/` への依存があった。
ユーザーの環境に Homebrew + ffmpeg がインストールされていないと動作しない問題を解消するため、
ffmpeg の動的ライブラリとヘッダーをリポジトリに同梱した。

Apple Silicon 向けの pre-built ffmpeg dylib は外部で提供されていないため、
Homebrew ffmpeg から抽出する方式を採用した。

### ベンダリング手順

```sh
./scripts/vendor-ffmpeg.py
```

スクリプトは Homebrew ffmpeg の dylib 依存を再帰的に探索し、`vendor/ffmpeg/lib/` にコピーする。
各 dylib の install_name は `@rpath/<filename>` に書き換えられる。

## クロマ補間の品質

BGRA→YUV420P変換時、クロマ平面を2x縮小する補間アルゴリズムが境界線の変色に影響する。

| アルゴリズム | 品質 | 備考 |
|---|---|---|
| SWS_BILINEAR | 低 | ブロック境界でクロマが不連続になりやすい |
| **SWS_LANCZOS** | 高 | 窓関数による高品質補間、境界変色を軽減 |

現状 `SWS_LANCZOS` を使用。sws_scale内部でクロマ平面に対してランクス補間が適用され、境界近傍のピクセルを広範囲から参照することでクロマ値の連続性が改善される。

## ライセンス

同梱する ffmpeg の動的ライブラリは GPL 2+ である。詳細は `THIRD-PARTY-LICENSES.md` を参照。
