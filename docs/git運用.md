# Git運用

## コミットメッセージ

[Conventional Commits](https://www.conventionalcommits.org/ja/) の形式に従う。

### type

| type | 用途 |
|------|------|
| feat | 新機能 |
| fix | バグ修正 |
| perf | パフォーマンス改善 |
| refactor | リファクタリング（機能変更なし） |
| docs | ドキュメントやコメントのみの変更 |
| chore | ビルド・ツール・依存関係などの変更 |
| change | 仕様変更 |

### subject（1行目）

**コードの変更内容ではなく、アプリがどう変わったかを書く。**

手段や内部実装ではなく、結果や効果を書く。

```
# NG（内部実装）
feat: vendor ffmpeg into repository
perf: use NV12 pixel format

# OK（アプリの変化）
feat: remove Homebrew ffmpeg dependency at compile and runtime
perf: reduce encoding latency by using NV12 input
```

```
# NG（手段）
fix: add session start in audio callback

# OK（結果）
fix: prevent crash when recording audio in ffmpeg mode
```

### body（3行目以降）

細かい変更内容、手段、背景、メモ等を記載する。任意。

```
perf: reduce encoding latency by using NV12 input

- Use NV12 pixel format for AVAssetWriter path (ffmpeg path stays BGRA)
- SCStream delivers NV12 directly, eliminating BGRA→YUV conversion step
- May slightly reduce color edge artifacts due to better HW encoder affinity
```
