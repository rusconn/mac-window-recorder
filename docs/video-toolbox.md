# VideoToolbox

## 概要

macOSのハードウェアエンコーダ。AVAssetWriter経由でBGRA入力を内部変換しH.264/HEVCを出力する。

## クロマサブサンプル対応状況

| コーデック | YUV420 | YUV444 |
|---|---|---|
| H.264 | 対応 | 非対応 |
| HEVC | 対応 | 対応 (Apple Siliconで動作) |
