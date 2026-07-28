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

import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

final class AssetWriterSession {
    private let assetWriter: AVAssetWriter
    private let sysAudioInput: AVAssetWriterInput?
    private let micAudioInput: AVAssetWriterInput?

    init(
        outputURL: URL,
        fileType: AVFileType,
        captureSystemAudio: Bool,
        captureMicrophone: Bool
    ) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 256000
        ]

        if captureSystemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if assetWriter.canAdd(input) {
                assetWriter.add(input)
                sysAudioInput = input
            } else {
                sysAudioInput = nil
            }
        } else {
            sysAudioInput = nil
        }

        if captureMicrophone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if assetWriter.canAdd(input) {
                assetWriter.add(input)
                micAudioInput = input
            } else {
                micAudioInput = nil
            }
        } else {
            micAudioInput = nil
        }
    }

    var capturesAudio: Bool {
        sysAudioInput != nil || micAudioInput != nil
    }

    func startWriting() {
        assetWriter.startWriting()
    }

    func add(_ input: AVAssetWriterInput) {
        precondition(assetWriter.canAdd(input), "AVAssetWriterInput を追加できません")
        assetWriter.add(input)
    }

    func startSession(at pts: CMTime) {
        assetWriter.startSession(atSourceTime: pts)
    }

    func append(_ sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard assetWriter.status == .writing else { return }

        switch type {
        case .audio:
            sysAudioInput?.append(sampleBuffer)
        case .microphone:
            micAudioInput?.append(sampleBuffer)
        default:
            break
        }
    }

    func finishSession(at pts: CMTime) {
        guard assetWriter.status == .writing else { return }

        sysAudioInput?.markAsFinished()
        micAudioInput?.markAsFinished()
        assetWriter.endSession(atSourceTime: pts)
    }

    func finishWriting() async {
        await assetWriter.finishWriting()
    }

    var isWriting: Bool {
        assetWriter.status == .writing
    }
}
