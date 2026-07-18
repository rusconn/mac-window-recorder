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
import AVFoundation

struct ParsedArguments {
    var help = false
    var windowQuery: String?
    var outputName: String?
    var codec: AVVideoCodecType?
    var cropTop: Int?
    var cropBottom: Int?
    var cropLeft: Int?
    var cropRight: Int?
    var microphoneQuery: String?
    var noMicrophone: Bool?
    var systemAudio: Bool?
    var ffmpeg: Bool?
    var debug: Bool?

    var hasWindow: Bool { windowQuery != nil }
    var hasOutput: Bool { outputName != nil }
    var hasCodec: Bool { codec != nil }
    var hasCrop: Bool { cropTop != nil }
    var hasMicrophone: Bool { microphoneQuery != nil }
    var hasNoMicrophone: Bool { noMicrophone == true }
    var hasSystemAudio: Bool { systemAudio == true }
    var hasNoSystemAudio: Bool { systemAudio == false }
    var hasFfmpeg: Bool { ffmpeg == true }
}

struct ArgumentParser {
    static func parse(_ args: [String]) -> ParsedArguments {
        var parsed = ParsedArguments()
        var i = 1

        while i < args.count {
            switch args[i] {
            case "--help", "-h":
                parsed.help = true
                i += 1
            case "--window" where i + 1 < args.count:
                parsed.windowQuery = args[i + 1]
                i += 2
            case "--output" where i + 1 < args.count:
                parsed.outputName = args[i + 1]
                i += 2
            case "--codec" where i + 1 < args.count:
                guard let codec = parseCodec(args[i + 1]) else {
                    print("エラー: --codec は h264 または hevc を指定してください。")
                    exit(1)
                }
                parsed.codec = codec
                i += 2
            case "--crop" where i + 1 < args.count:
                let parts = args[i + 1].split(separator: ":").map { Int($0) ?? 0 }
                guard parts.count == 4 else {
                    print("エラー: --crop は T:B:L:R の形式で指定してください（例: --crop 0:0:0:0）。")
                    exit(1)
                }
                parsed.cropTop = parts[0]
                parsed.cropBottom = parts[1]
                parsed.cropLeft = parts[2]
                parsed.cropRight = parts[3]
                i += 2
            case "--microphone" where i + 1 < args.count:
                guard parsed.noMicrophone == nil else {
                    print("エラー: --microphone と --no-microphone を同時に指定できません。")
                    exit(1)
                }
                parsed.microphoneQuery = args[i + 1]
                i += 2
            case "--no-microphone":
                guard parsed.microphoneQuery == nil else {
                    print("エラー: --microphone と --no-microphone を同時に指定できません。")
                    exit(1)
                }
                parsed.noMicrophone = true
                i += 1
            case "--system-audio":
                guard parsed.systemAudio == nil else {
                    print("エラー: --system-audio と --no-system-audio を同時に指定できません。")
                    exit(1)
                }
                parsed.systemAudio = true
                i += 1
            case "--no-system-audio":
                guard parsed.systemAudio == nil else {
                    print("エラー: --system-audio と --no-system-audio を同時に指定できません。")
                    exit(1)
                }
                parsed.systemAudio = false
                i += 1
            case "--ffmpeg":
                parsed.ffmpeg = true
                i += 1
            case "--debug":
                parsed.debug = true
                i += 1
            default:
                if args[i].hasPrefix("--") || args[i].hasPrefix("-") {
                    print("エラー: 不明なオプション '\(args[i])'。--help で使い方を確認できます。")
                    exit(1)
                }
                i += 1
            }
        }

        return parsed
    }

    private static func parseCodec(_ value: String) -> AVVideoCodecType? {
        switch value.lowercased() {
        case "h264": return .h264
        case "hevc", "h265": return .hevc
        default: return nil
        }
    }
}
