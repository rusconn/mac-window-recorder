// Copyright (C) 2026 rusconn
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, see <https://www.gnu.org/licenses/>.

import Foundation
import ScreenCaptureKit
import AppKit

@main
struct Main {
    static func main() async {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)

        let parsed = ArgumentParser.parse(CommandLine.arguments)

        if parsed.help {
            print("""
            使い方: accurec [options]

            必須設定は対話で収集します。CLIオプションを指定すると、対応する対話ステップをスキップできます。

            オプション:
              --window <title>          ウィンドウを選択（対話をスキップ）
              --crop <T:B:L:R>          上下左右のクロップピクセル数
              --system-audio            システム音声を収録（対話をスキップ）
              --no-system-audio         システム音声なし（対話をスキップ）
              --microphone <name>       マイクを選択（対話をスキップ）
              --no-microphone           マイクなしを選択（対話をスキップ）
              --codec <h264|hevc>       コーデックを選択（対話をスキップ）
              --chroma-subsampling <420|444>  クロマサブサンプルを選択（デフォルト: 420）
              --ffmpeg <preset>         ffmpegを使用（preset: ultrafast/superfast/veryfast/faster/fast/medium/slow/slower/veryslow）
              --output <file>           出力ファイル名を指定（対話をスキップ）
              --debug                   ffmpeg/libx264/libx265の詳細ログを表示
              -h, --help                このメッセージを表示

            例:
              accurec                                        全て対話
              accurec --window Safari --no-system-audio       ウィンドウと音声をプリセット
              accurec --window Safari --no-system-audio \\
                  --no-microphone --codec h264 --output out.mp4    全プリセット（対話なし）
            """)
            exit(0)
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            print("画面収録の権限が必要です。システム設定 > プライバシーとセキュリティ > 画面収録 で許可してください。")
            exit(1)
        }
        let windows = content.windows.filter { $0.title != nil && !$0.title!.isEmpty }
        guard !windows.isEmpty else {
            print("録画可能なウィンドウが見つかりません。")
            exit(1)
        }

        let micDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices

        Terminal.enableRawMode()
        let config = InteractiveUI.configure(
            windows: windows,
            micDevices: micDevices,
            parsed: parsed
        )
        Terminal.restore()

        print("\n--- 録画設定 ---")
        print("  \(config.summary())")
        print("")

        let engine = CaptureEngine(config: config)
        do {
            try await engine.start()
        } catch {
            print("エラー: \(error)")
            exit(1)
        }
    }
}
