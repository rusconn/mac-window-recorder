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
        if config.chromaSubsampling == .yuv420 {
            if videoWidth % 2 != 0 { videoWidth -= 1 }
            if videoHeight % 2 != 0 { videoHeight -= 1 }
        }
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

        if config.codec == .h264 && config.chromaSubsampling == .yuv444 {
            print("エラー: H.264はYUV444非対応です。HEVCをお使いください。")
            exit(1)
        }

        guard let window = config.window else {
            print("エラー: ウィンドウが選択されていません。")
            exit(1)
        }

        let dims = computeDimensions(window: window)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let streamConfig = buildStreamConfiguration(window: window, dims: dims)

        var videoEncoder: VideoEncoder?
        var assetWriterSession: AssetWriterSession?
        let ffmpegAudioURL = config.ffmpegPreset != nil
            && (config.captureSystemAudio || config.microphoneDeviceID != nil)
            ? URL(fileURLWithPath: config.outputName + ".audio.m4a")
            : nil

        if let preset = config.ffmpegPreset {
            let outputURL = URL(fileURLWithPath: config.outputName)
            if FileManager.default.fileExists(atPath: config.outputName) {
                try FileManager.default.removeItem(at: outputURL)
            }
            let codecName = config.codec == .hevc ? "libx265" : "libx264"
            let crf = config.codec == .hevc ? 18 : 16
            videoEncoder = FFmpegEncoder(
                width: dims.videoWidth,
                height: dims.videoHeight,
                codec: codecName,
                crf: crf,
                preset: preset,
                outputURL: outputURL,
                audioURL: ffmpegAudioURL,
                chromaSubsampling: config.chromaSubsampling,
                debug: config.debug
            )
            guard videoEncoder != nil else {
                print("FFmpegEncoder初期化失敗")
                return
            }

            if let ffmpegAudioURL {
                let session = try AssetWriterSession(
                    outputURL: ffmpegAudioURL,
                    fileType: .m4a,
                    captureSystemAudio: config.captureSystemAudio,
                    captureMicrophone: config.microphoneDeviceID != nil
                )
                session.startWriting()
                assetWriterSession = session
            }
        } else {
            let session = try AssetWriterSession(
                outputURL: URL(fileURLWithPath: config.outputName),
                fileType: .mp4,
                captureSystemAudio: config.captureSystemAudio,
                captureMicrophone: config.microphoneDeviceID != nil
            )
            let encoder = VideoToolboxEncoder(
                width: dims.videoWidth,
                height: dims.videoHeight,
                codec: config.codec,
                chromaSubsampling: config.chromaSubsampling,
                assetWriterSession: session
            )
            videoEncoder = encoder
            assetWriterSession = session
        }

        let writer = FrameWriter(
            fps: 60,
            assetWriterSession: assetWriterSession,
            videoEncoder: videoEncoder
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

        if let assetWriterSession {
            await assetWriterSession.finishWriting()
        }
        try videoEncoder?.finalizeRecording()

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

}
