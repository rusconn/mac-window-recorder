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
import AVFoundation

struct InteractiveUI {

    static func configure(
        windows: [SCWindow],
        micDevices: [AVCaptureDevice],
        parsed: ParsedArguments
    ) -> CaptureConfig {
        var config = CaptureConfig()

        config.window = selectWindow(from: windows, preset: parsed.windowQuery)
        config.captureSystemAudio = selectSystemAudio(preset: parsed.systemAudio)
        let mic = selectMicrophone(
            from: micDevices,
            preset: parsed.microphoneQuery,
            noMic: parsed.noMicrophone
        )
        config.microphoneDeviceID = mic.uniqueID
        config.microphoneName = mic.localizedName
        config.codec = selectCodec(preset: parsed.codec)
        config.outputName = selectOutputName(preset: parsed.outputName)

        if let top = parsed.cropTop, let bottom = parsed.cropBottom,
           let left = parsed.cropLeft, let right = parsed.cropRight {
            config.cropTop = top
            config.cropBottom = bottom
            config.cropLeft = left
            config.cropRight = right
        }

        if parsed.hasFfmpeg {
            config.ffmpeg = true
        }
        if parsed.debug == true {
            config.debug = true
        }

        return config
    }

    static func select(
        prompt: String,
        items: [String],
        defaultIndex: Int = 0
    ) -> Int {
        var index = defaultIndex
        let count = items.count

        print(prompt)
        renderItems(items: items, selected: index)

        while true {
            let (input, _) = Terminal.readInputOrArrow()
            switch input {
            case .up:
                index = (index - 1 + count) % count
            case .down:
                index = (index + 1) % count
            case .enter:
                print("")
                return index
            case .quit:
                Terminal.restore()
                exit(0)
            default:
                continue
            }
            print("\u{1b}[\(count)A", terminator: "")
            renderItems(items: items, selected: index)
        }
    }

    static func confirm(
        prompt: String,
        defaultYes: Bool = true
    ) -> Bool {
        var yes = defaultYes
        print(prompt)
        renderToggle(yes: yes)

        while true {
            let (input, _) = Terminal.readInputOrArrow()
            switch input {
            case .up, .down:
                yes.toggle()
                print("\u{1b}[2A", terminator: "")
                renderToggle(yes: yes)
            case .enter:
                print("")
                return yes
            case .quit:
                Terminal.restore()
                exit(0)
            default:
                break
            }
        }
    }

    static func textInput(
        prompt: String,
        defaultValue: String
    ) -> String {
        Terminal.restore()
        print("\(prompt) [\(defaultValue)]: ", terminator: "")
        fflush(stdout)
        let input = readLine() ?? ""
        return input.trimmingCharacters(in: .whitespaces).isEmpty
            ? defaultValue
            : input.trimmingCharacters(in: .whitespaces)
    }

    private static func selectWindow(
        from windows: [SCWindow],
        preset: String?
    ) -> SCWindow {
        if let query = preset {
            guard let found = windows.first(where: {
                ($0.title ?? "").localizedCaseInsensitiveContains(query)
            }) else {
                Terminal.restore()
                print("ウィンドウが見つかりません（タイトルに '\(query)' を含むもの）。")
                exit(1)
            }
            return found
        }

        let items = windows.map { w in
            "\(w.owningApplication?.applicationName ?? "?"): \(w.title!)"
        }
        let index = select(prompt: "ウィンドウを選択:", items: items)
        return windows[index]
    }

    private static func selectSystemAudio(preset: Bool?) -> Bool {
        if let preset = preset {
            return preset
        }
        return confirm(prompt: "システム音声を収録しますか？", defaultYes: true)
    }

    private static func selectMicrophone(
        from devices: [AVCaptureDevice],
        preset: String?,
        noMic: Bool?
    ) -> (uniqueID: String?, localizedName: String?) {
        if noMic == true {
            return (nil, nil)
        }
        if let query = preset {
            guard let device = devices.first(where: {
                $0.localizedName.localizedCaseInsensitiveContains(query)
            }) else {
                Terminal.restore()
                print("マイクが見つかりません（名前に '\(query)' を含むもの）。")
                print("利用可能なマイク一覧:")
                for d in devices {
                    print(" - \(d.localizedName)")
                }
                exit(1)
            }
            return (device.uniqueID, device.localizedName)
        }

        var items = ["収録しない"]
        items += devices.map { $0.localizedName }
        let index = select(prompt: "マイクを選択:", items: items)
        if index > 0 {
            let device = devices[index - 1]
            return (device.uniqueID, device.localizedName)
        }
        return (nil, nil)
    }

    private static func selectCodec(preset: AVVideoCodecType?) -> AVVideoCodecType {
        if let codec = preset {
            return codec
        }
        let index = select(prompt: "コーデックを選択:", items: ["h264", "hevc"])
        return index == 0 ? .h264 : .hevc
    }

    private static func selectOutputName(preset: String?) -> String {
        if let name = preset {
            return name
        }
        return textInput(prompt: "出力ファイル名", defaultValue: "capture_output.mp4")
    }

    private static func renderItems(items: [String], selected: Int) {
        for (i, item) in items.enumerated() {
            let marker = i == selected ? "  > " : "    "
            print("\u{1b}[2K\(marker)\(item)")
        }
    }

    private static func renderToggle(yes: Bool) {
        print("\u{1b}[2K\(yes ? "  > " : "    ")はい")
        print("\u{1b}[2K\(!yes ? "  > " : "    ")いいえ")
    }
}
