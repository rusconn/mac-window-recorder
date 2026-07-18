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
import CoreMedia
import CoreVideo
import AVFoundation
import CFFmpeg

struct CaptureEngine {
    let config: CaptureConfig

    private struct Dimensions {
        let scale: CGFloat
        let videoWidth: Int
        let videoHeight: Int
    }

    private func computeDimensions(window: SCWindow) -> Dimensions {
        let windowFrame = window.frame
        let scale = NSScreen.screens
            .first(where: { NSIntersectsRect($0.frame, windowFrame) })?
            .backingScaleFactor ?? 2.0
        let fullWidth = Int(windowFrame.width * scale)
        let fullHeight = Int(windowFrame.height * scale)
        var videoWidth = fullWidth - config.cropLeft - config.cropRight
        var videoHeight = fullHeight - config.cropTop - config.cropBottom

        let origW = videoWidth
        let origH = videoHeight
        if videoWidth % 2 != 0 { videoWidth -= 1 }
        if videoHeight % 2 != 0 { videoHeight -= 1 }
        if videoWidth != origW || videoHeight != origH {
            print("奇数サイズ検出: \(origW)x\(origH) → \(videoWidth)x\(videoHeight)にクロップ")
        }

        return Dimensions(scale: scale, videoWidth: videoWidth, videoHeight: videoHeight)
    }

    func start() async throws {
        if config.debug {
            swift_av_log_set_default()
        } else {
            swift_av_log_set_quiet()
        }

        guard let window = config.window else {
            print("エラー: ウィンドウが選択されていません。")
            exit(1)
        }

        let dims = computeDimensions(window: window)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let streamConfig = buildStreamConfiguration(window: window, dims: dims)

        var ffmpegEncoder: FFmpegEncoder?
        var assetWriter: AVAssetWriter?
        var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
        var sysAudioInput: AVAssetWriterInput?
        var micAudioInput: AVAssetWriterInput?

        if config.ffmpeg {
            let outputURL = URL(fileURLWithPath: config.outputName)
            if FileManager.default.fileExists(atPath: config.outputName) {
                try FileManager.default.removeItem(at: outputURL)
            }
            let codecName = config.codec == .hevc ? "libx265" : "libx264"
            let crf = config.codec == .hevc ? 18 : 16
            ffmpegEncoder = FFmpegEncoder(
                width: dims.videoWidth,
                height: dims.videoHeight,
                codec: codecName,
                crf: crf,
                outputURL: outputURL,
                debug: config.debug
            )
            guard ffmpegEncoder != nil else {
                print("FFmpegEncoder初期化失敗")
                return
            }

            if config.captureSystemAudio || config.microphoneDeviceID != nil {
                let audioURL = URL(fileURLWithPath: config.outputName + ".audio.m4a")
                if FileManager.default.fileExists(atPath: audioURL.path) {
                    try FileManager.default.removeItem(at: audioURL)
                }
                assetWriter = try AVAssetWriter(outputURL: audioURL, fileType: .m4a)
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 256000
                ]
                if config.captureSystemAudio {
                    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                    input.expectsMediaDataInRealTime = true
                    if assetWriter!.canAdd(input) {
                        assetWriter!.add(input)
                        sysAudioInput = input
                    }
                }
                if config.microphoneDeviceID != nil {
                    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                    input.expectsMediaDataInRealTime = true
                    if assetWriter!.canAdd(input) {
                        assetWriter!.add(input)
                        micAudioInput = input
                    }
                }
                assetWriter!.startWriting()
            }
        } else {
            let result = try buildAssetWriter(window: window, dims: dims)
            assetWriter = result.writer
            pixelBufferAdaptor = result.adaptor
            sysAudioInput = result.sysAudioInput
            micAudioInput = result.micAudioInput
            assetWriter!.startWriting()
        }

        let writer = FrameWriter(
            assetWriter: assetWriter,
            pixelBufferAdaptor: pixelBufferAdaptor,
            fps: 60,
            sysAudioInput: sysAudioInput,
            micAudioInput: micAudioInput,
            ffmpegEncoder: ffmpegEncoder
        )

        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: writer)
        let videoQueue = DispatchQueue(label: "capture.video.queue", qos: .userInteractive)
        let systemAudioQueue = DispatchQueue(label: "capture.systemaudio.queue", qos: .userInteractive)
        let micQueue = DispatchQueue(label: "capture.mic.queue", qos: .userInteractive)

        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: videoQueue)
        if config.captureSystemAudio {
            try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: systemAudioQueue)
        }
        if config.microphoneDeviceID != nil {
            try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: micQueue)
        }

        try await stream.startCapture()
        writer.startRequestingMediaData()

        print("録画中... q+Enterで終了。")
        while true {
            guard let line = readLine(), line.lowercased() != "q" else { break }
        }

        do {
            try await stream.stopCapture()
        } catch {
            print("ストリーム停止エラー: \(error)")
        }
        writer.finishSession()

        if let assetWriter {
            await assetWriter.finishWriting()
        }

        if config.ffmpeg {
            let audioPath = config.outputName + ".audio.m4a"
            if FileManager.default.fileExists(atPath: audioPath) {
                let outputURL = URL(fileURLWithPath: config.outputName)
                let audioURL = URL(fileURLWithPath: audioPath)
                let mergedURL = URL(fileURLWithPath: outputURL.path + ".merged.mp4")

                if FFmpegEncoder.mergeAudioVideo(videoURL: outputURL, audioURL: audioURL, outputURL: mergedURL) {
                    try FileManager.default.removeItem(at: outputURL)
                    try FileManager.default.moveItem(at: mergedURL, to: outputURL)
                }
                if let attrs = try? FileManager.default.attributesOfItem(atPath: audioPath),
                   let size = attrs[.size] as? Int {
                    print("[debug] .audio.m4a サイズ: \(size) bytes")
                }
                if !config.debug {
                    try FileManager.default.removeItem(at: audioURL)
                } else {
                    print("[debug] .audio.m4a を保持中: \(audioPath)")
                }
            }
        }

        print("保存しました: \(config.outputName)")
        writer.logStats()
    }

    private func buildStreamConfiguration(window: SCWindow, dims: Dimensions) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()

        let s = Double(dims.scale)
        config.sourceRect = CGRect(
            x: Double(self.config.cropLeft) / s,
            y: Double(self.config.cropTop) / s,
            width: Double(dims.videoWidth) / s,
            height: Double(dims.videoHeight) / s
        )

        config.width = dims.videoWidth
        config.height = dims.videoHeight
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 5

        if self.config.microphoneDeviceID != nil {
            config.captureMicrophone = true
            config.microphoneCaptureDeviceID = self.config.microphoneDeviceID
        }

        config.capturesAudio = self.config.captureSystemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)

        return config
    }

    private func buildAssetWriter(
        window: SCWindow, dims: Dimensions
    ) throws -> (
        writer: AVAssetWriter,
        adaptor: AVAssetWriterInputPixelBufferAdaptor?,
        sysAudioInput: AVAssetWriterInput?,
        micAudioInput: AVAssetWriterInput?
    ) {
        let videoWidth = dims.videoWidth
        let videoHeight = dims.videoHeight

        let outputURL = URL(fileURLWithPath: config.outputName)
        if FileManager.default.fileExists(atPath: config.outputName) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let fps = 60
        let pixelsPerSecond = Double(videoWidth) * Double(videoHeight) * Double(fps)
        let bitratePerPixel: Double
        switch config.codec {
        case .hevc: bitratePerPixel = 0.06
        default: bitratePerPixel = 0.08
        }
        let averageBitrate = Int(pixelsPerSecond * bitratePerPixel)

        var compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: averageBitrate,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 2
        ]
        if config.codec == .h264 {
            compressionProperties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        let videoInputSettings: [String: Any] = [
            AVVideoCodecKey: config.codec,
            AVVideoWidthKey: videoWidth,
            AVVideoHeightKey: videoHeight,
            AVVideoCompressionPropertiesKey: compressionProperties,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoInputSettings)
        videoInput.expectsMediaDataInRealTime = true

        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: videoWidth,
            kCVPixelBufferHeightKey as String: videoHeight
        ]
        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        assetWriter.add(videoInput)

        var sysAudioInput: AVAssetWriterInput? = nil
        var micAudioInput: AVAssetWriterInput? = nil
        if config.captureSystemAudio || config.microphoneDeviceID != nil {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256000
            ]
            if config.captureSystemAudio {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                input.expectsMediaDataInRealTime = true
                if assetWriter.canAdd(input) {
                    assetWriter.add(input)
                    sysAudioInput = input
                }
            }
            if config.microphoneDeviceID != nil {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                input.expectsMediaDataInRealTime = true
                if assetWriter.canAdd(input) {
                    assetWriter.add(input)
                    micAudioInput = input
                }
            }
        }

        return (assetWriter, pixelBufferAdaptor, sysAudioInput, micAudioInput)
    }
}
