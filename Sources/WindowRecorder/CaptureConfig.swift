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

struct CaptureConfig {
    var window: SCWindow?
    var codec: AVVideoCodecType = .h264
    var outputName: String = "capture_output.mp4"
    var cropTop: Int = 0
    var cropBottom: Int = 0
    var cropLeft: Int = 0
    var cropRight: Int = 0
    var microphoneDeviceID: String?
    var microphoneName: String?
    var captureSystemAudio: Bool = true
    var ffmpeg: Bool = false
    var debug: Bool = false

    var hasCrop: Bool {
        cropTop != 0 || cropBottom != 0 || cropLeft != 0 || cropRight != 0
    }

    func summary() -> String {
        var lines: [String] = []
        lines.append("ウィンドウ: \(window?.title ?? "(未選択)")")
        lines.append("システム音声: \(captureSystemAudio ? "ON" : "OFF")")
        lines.append("マイク: \(microphoneName ?? "なし")")
        lines.append("コーデック: \(codec == .h264 ? "H.264" : "HEVC")")
        lines.append("出力: \(outputName)")
        if hasCrop {
            lines.append("クロップ: \(cropTop):\(cropBottom):\(cropLeft):\(cropRight)")
        }
        if ffmpeg {
            lines.append("エンコード: ffmpeg (libx264/libx265)")
        }
        return lines.joined(separator: "\n  ")
    }
}