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
import CoreVideo
import Foundation
import os

final class VideoToolboxEncoder: VideoEncoder {
    private let assetWriterSession: AssetWriterSession
    private let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private let videoInput: AVAssetWriterInput
    private let videoLock = OSAllocatedUnfairLock()
    private let frameAvailable = DispatchSemaphore(value: 0)
    private let finishDrainTimeout: TimeInterval = 5.0
    private var pendingFrames: [PendingFrame] = []

    private struct PendingFrame: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let pts: CMTime
    }

    init(
        width: Int,
        height: Int,
        codec: AVVideoCodecType,
        assetWriterSession: AssetWriterSession
    ) {
        self.assetWriterSession = assetWriterSession
        let fps = 60
        let pixelsPerSecond = Double(width) * Double(height) * Double(fps)
        let bitratePerPixel = codec == .hevc ? 0.06 : 0.08
        let averageBitrate = Int(pixelsPerSecond * bitratePerPixel)

        var compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: averageBitrate,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 2
        ]
        if codec == .h264 {
            compressionProperties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProperties,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        assetWriterSession.add(videoInput)
        assetWriterSession.startWriting()
    }

    func startSession(at pts: CMTime) {
        // AssetWriterSession owns the AVAssetWriter session for both encoders.
    }

    func startRequestingMediaData() {
        let writerQueue = DispatchQueue(label: "videotoolbox.encode.queue", qos: .userInteractive)
        videoInput.requestMediaDataWhenReady(on: writerQueue) { [weak self] in
            self?.pullVideoFrames()
        }
    }

    func writeFrame(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        let frame = PendingFrame(pixelBuffer: pixelBuffer, pts: pts)
        videoLock.withLock {
            pendingFrames.append(frame)
        }
        frameAvailable.signal()
    }

    func finish() -> Int {
        let dropped = drainPendingVideoFrames()
        videoInput.markAsFinished()
        return dropped
    }

    private func pullVideoFrames() {
        guard assetWriterSession.isWriting else { return }

        while videoInput.isReadyForMoreMediaData {
            let frame: PendingFrame? = videoLock.withLock {
                guard !pendingFrames.isEmpty else { return nil }
                return pendingFrames.removeFirst()
            }
            if let frame {
                pixelBufferAdaptor.append(frame.pixelBuffer, withPresentationTime: frame.pts)
            } else {
                frameAvailable.wait()
            }
        }
    }

    private func drainPendingVideoFrames() -> Int {
        guard assetWriterSession.isWriting else { return 0 }

        let deadline = Date().addingTimeInterval(finishDrainTimeout)
        while true {
            let hasPending = videoLock.withLock { !pendingFrames.isEmpty }
            guard hasPending else { return 0 }

            if videoInput.isReadyForMoreMediaData {
                let frame: PendingFrame? = videoLock.withLock {
                    guard !pendingFrames.isEmpty else { return nil }
                    return pendingFrames.removeFirst()
                }
                if let frame {
                    pixelBufferAdaptor.append(frame.pixelBuffer, withPresentationTime: frame.pts)
                }
                continue
            }

            if Date() >= deadline {
                let dropped = videoLock.withLock {
                    let count = pendingFrames.count
                    pendingFrames.removeAll()
                    return count
                }
                print("警告: 終了時に動画入力がreadyにならず、\(dropped)フレームを破棄しました。")
                return dropped
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }
}
