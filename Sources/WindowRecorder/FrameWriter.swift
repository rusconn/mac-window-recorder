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

import ScreenCaptureKit
import CoreMedia
import CoreVideo
import AVFoundation
import os

final class FrameWriter: NSObject, SCStreamOutput, SCStreamDelegate {
    let assetWriter: AVAssetWriter?
    let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    let sysAudioInput: AVAssetWriterInput?
    let micAudioInput: AVAssetWriterInput?
    let fps: Int
    let ffmpegEncoder: FFmpegEncoder?

    var frameCount = 0
    var receivedFrameCount = 0
    private(set) var hasStartedSession = false
    private(set) var sessionStartPTS: CMTime = .invalid
    private var lastVideoPresentationTime: CMTime = .invalid
    private var maxCallbackNanos: UInt64 = 0
    private var firstVideoPTS: CMTime = .invalid
    private var lastAudioPTS: CMTime = .invalid
    private var intervalSum: Double = 0
    private var intervalMin: Double = .greatestFiniteMagnitude
    private var intervalMax: Double = 0
    private var largeGapCount = 0
    private var intervalCount = 0
    private let lock = OSAllocatedUnfairLock()
    private let finishDrainTimeout: TimeInterval = 5.0

    // Pull-model video queue
    // CVPixelBufferは参照カウントベースのメモリ管理でスレッドセーフなため、@unchecked Sendableとして安全
    private struct PendingFrame: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let pts: CMTime
    }
    private let videoLock = OSAllocatedUnfairLock()
    private var pendingFrames: [PendingFrame] = []
    private let frameAvailable = DispatchSemaphore(value: 0)

    init(assetWriter: AVAssetWriter?,
         pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?, fps: Int,
         sysAudioInput: AVAssetWriterInput? = nil,
         micAudioInput: AVAssetWriterInput? = nil,
         ffmpegEncoder: FFmpegEncoder? = nil) {
        self.assetWriter = assetWriter
        self.pixelBufferAdaptor = pixelBufferAdaptor
        self.sysAudioInput = sysAudioInput
        self.micAudioInput = micAudioInput
        self.fps = fps
        self.ffmpegEncoder = ffmpegEncoder
        super.init()
    }

    func startRequestingMediaData() {
        guard let input = pixelBufferAdaptor?.assetWriterInput else { return }
        let writerQueue = DispatchQueue(label: "frame.writer.request.queue", qos: .userInteractive)
        input.requestMediaDataWhenReady(on: writerQueue) { [weak self] in
            self?.pullVideoFrames()
        }
    }

    private func pullVideoFrames() {
        guard let input = pixelBufferAdaptor?.assetWriterInput,
              let assetWriter,
              assetWriter.status == .writing else { return }

        while input.isReadyForMoreMediaData {
            let frame: PendingFrame? = videoLock.withLock {
                guard !pendingFrames.isEmpty else { return nil }
                return pendingFrames.removeFirst()
            }
            if let frame {
                appendVideoFrame(frame)
            } else {
                frameAvailable.wait()
            }
        }
    }

    private func drainPendingVideoFramesForFinish() {
        guard let input = pixelBufferAdaptor?.assetWriterInput,
              let assetWriter,
              assetWriter.status == .writing else { return }

        let deadline = Date().addingTimeInterval(finishDrainTimeout)
        while true {
            let hasPending = videoLock.withLock { !pendingFrames.isEmpty }
            guard hasPending else { return }

            if input.isReadyForMoreMediaData {
                let frame: PendingFrame? = videoLock.withLock {
                    guard !pendingFrames.isEmpty else { return nil }
                    return pendingFrames.removeFirst()
                }
                if let frame {
                    appendVideoFrame(frame)
                }
                continue
            }

            if Date() >= deadline {
                let dropped = videoLock.withLock {
                    let count = pendingFrames.count
                    pendingFrames.removeAll()
                    return count
                }
                receivedFrameCount += dropped
                print("警告: 終了時に動画入力がreadyにならず、\(dropped)フレームを破棄しました。")
                return
            }

            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    private func appendVideoFrame(_ frame: PendingFrame) {
        let hasAudio = sysAudioInput != nil || micAudioInput != nil
        if hasAudio && !hasStartedSession { return }

        if !firstVideoPTS.isValid {
            firstVideoPTS = frame.pts
        } else if lastVideoPresentationTime.isValid
                    && frame.pts <= lastVideoPresentationTime {
            receivedFrameCount += 1
            return
        }

        recordVideoInterval(pts: frame.pts)
        lastVideoPresentationTime = frame.pts
        receivedFrameCount += 1

        if pixelBufferAdaptor?.append(frame.pixelBuffer, withPresentationTime: frame.pts) == true {
            frameCount += 1
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        if type == .microphone || type == .audio {
            guard CMSampleBufferIsValid(sampleBuffer) else { return }

            // マイク音声はmicAudioInputにのみルーティング
            let target: AVAssetWriterInput?
            if type == .microphone {
                target = micAudioInput
            } else {
                target = sysAudioInput
            }
            guard target != nil else { return }

            var shouldAppend = false
            var appendSampleBuffer: CMSampleBuffer?

            lock.withLockUnchecked {
                guard assetWriter?.status == .writing else { return }
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

                // 音声のみの場合は従来通り
                let hasVideo = pixelBufferAdaptor != nil
                if !hasVideo {
                    if !sessionStartPTS.isValid {
                        sessionStartPTS = pts
                        assetWriter?.startSession(atSourceTime: pts)
                        hasStartedSession = true
                    }
                    lastAudioPTS = pts
                    shouldAppend = true
                    appendSampleBuffer = sampleBuffer
                    return
                }

                // 音声と映像の両方が有効な場合
                if !hasStartedSession {
                    sessionStartPTS = pts
                    assetWriter?.startSession(atSourceTime: pts)
                    hasStartedSession = true
                }

                // セッション開始済み
                lastAudioPTS = pts
                shouldAppend = true
                appendSampleBuffer = sampleBuffer
            }

            if shouldAppend, let appendSampleBuffer {
                target?.append(appendSampleBuffer)
            }
            return
        }

        guard type == .screen else { return }
        guard CMSampleBufferIsValid(sampleBuffer) else { return }

        let startNanos = mach_absolute_time()

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[String: Any]],
              let attachments = attachmentsArray.first,
              let statusRawValue = attachments[SCStreamFrameInfo.status.rawValue] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue)
        else {
            if hasStartedSession {
                receivedFrameCount += 1
            }
            return
        }

        guard status == .complete else {
            if hasStartedSession {
                receivedFrameCount += 1
            }
            return
        }

        if let ffmpegEncoder {
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                if hasStartedSession {
                    receivedFrameCount += 1
                }
                return
            }

            // 音声のみの場合は従来通り
            let hasAudio = sysAudioInput != nil || micAudioInput != nil
            if !hasAudio {
                let basePTS = startSessionIfNeeded(at: pts)
                receivedFrameCount += 1
                if !firstVideoPTS.isValid {
                    firstVideoPTS = pts
                } else if lastVideoPresentationTime.isValid
                            && pts <= lastVideoPresentationTime {
                    return
                }
                recordVideoInterval(pts: pts)
                lastVideoPresentationTime = pts
                let normalizedPts = CMTimeSubtract(pts, basePTS)
                CVBufferRemoveAttachment(imageBuffer, kCVImageBufferCGColorSpaceKey)
                ffmpegEncoder.writeFrame(imageBuffer, pts: normalizedPts)
                frameCount += 1
                let elapsed = mach_absolute_time() - startNanos
                if elapsed > maxCallbackNanos {
                    maxCallbackNanos = elapsed
                }
                return
            }

            // 音声と映像の両方が有効な場合
            if !hasStartedSession {
                return
            }

            // セッション開始済み
            receivedFrameCount += 1
            if !firstVideoPTS.isValid {
                firstVideoPTS = pts
            } else if lastVideoPresentationTime.isValid
                        && pts <= lastVideoPresentationTime {
                return
            }
            recordVideoInterval(pts: pts)
            lastVideoPresentationTime = pts
            let normalizedPts = CMTimeSubtract(pts, sessionStartPTS)
            CVBufferRemoveAttachment(imageBuffer, kCVImageBufferCGColorSpaceKey)
            ffmpegEncoder.writeFrame(imageBuffer, pts: normalizedPts)
            frameCount += 1
            let elapsed = mach_absolute_time() - startNanos
            if elapsed > maxCallbackNanos {
                maxCallbackNanos = elapsed
            }
            return
        }

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            if hasStartedSession {
                receivedFrameCount += 1
            }
            return
        }
        CVBufferRemoveAttachment(imageBuffer, kCVImageBufferCGColorSpaceKey)

        let frame = PendingFrame(pixelBuffer: imageBuffer, pts: pts)
        videoLock.withLock {
            pendingFrames.append(frame)
        }
        frameAvailable.signal()

        let elapsed = mach_absolute_time() - startNanos
        if elapsed > maxCallbackNanos {
            maxCallbackNanos = elapsed
        }
    }

    func finishSession() {
        ffmpegEncoder?.finish()

        lock.withLockUnchecked {
            for input in [sysAudioInput, micAudioInput] {
                if let input, assetWriter?.status == .writing {
                    input.markAsFinished()
                }
            }
        }

        drainPendingVideoFramesForFinish()

        if let input = pixelBufferAdaptor?.assetWriterInput {
            input.markAsFinished()
        }

        lock.withLockUnchecked {
            if hasStartedSession, let assetWriter {
                let finalEnd = latestValidTime(
                    lastVideoPresentationTime,
                    lastAudioPTS
                )
                assetWriter.endSession(atSourceTime: finalEnd)
                hasStartedSession = false
            }
        }
    }

    func logStats() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let maxMs = Double(maxCallbackNanos) * Double(info.numer) / Double(info.denom) / 1_000_000
        print("  受信フレーム数: \(receivedFrameCount), 書き込み: \(frameCount), ドロップ: \(receivedFrameCount - frameCount), max callback: \(String(format: "%.3f", maxMs))ms")

        if firstVideoPTS.isValid, lastVideoPresentationTime.isValid {
            let duration = CMTimeGetSeconds(CMTimeSubtract(lastVideoPresentationTime, firstVideoPTS))
            print("  動画時間: \(String(format: "%.1f", duration))秒")

            if intervalCount > 0 {
                let avgInterval = intervalSum / Double(intervalCount)
                print("  フレーム間隔: 平均 \(String(format: "%.1f", avgInterval))ms, 最小 \(String(format: "%.1f", intervalMin))ms, 最大 \(String(format: "%.1f", intervalMax))ms")
                print("  大きな間隔(>20ms): \(largeGapCount) 回")
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("ストリームが停止しました: \(error)")
    }

    // MARK: - Helpers

    @discardableResult
    private func startSessionIfNeeded(at pts: CMTime) -> CMTime {
        lock.withLockUnchecked {
            if !sessionStartPTS.isValid {
                sessionStartPTS = pts
                if let assetWriter {
                    assetWriter.startSession(atSourceTime: pts)
                }
                hasStartedSession = true
            }
            return sessionStartPTS
        }
    }

    private func recordVideoInterval(pts: CMTime) {
        guard lastVideoPresentationTime.isValid else { return }

        let intervalMs = CMTimeGetSeconds(CMTimeSubtract(pts, lastVideoPresentationTime)) * 1000.0
        intervalSum += intervalMs
        if intervalMs < intervalMin { intervalMin = intervalMs }
        if intervalMs > intervalMax { intervalMax = intervalMs }
        if intervalMs > 20.0 { largeGapCount += 1 }
        intervalCount += 1
    }

    private func latestValidTime(_ times: CMTime...) -> CMTime {
        times.reduce(CMTime.invalid) { latest, time in
            guard time.isValid else { return latest }
            guard latest.isValid else { return time }
            return CMTimeCompare(time, latest) > 0 ? time : latest
        }
    }
}
