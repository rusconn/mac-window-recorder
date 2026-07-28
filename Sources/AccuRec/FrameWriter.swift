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
    let assetWriterSession: AssetWriterSession?
    let fps: Int
    let videoEncoder: VideoEncoder?

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
    init(fps: Int,
         assetWriterSession: AssetWriterSession? = nil,
         videoEncoder: VideoEncoder? = nil) {
        self.assetWriterSession = assetWriterSession
        self.fps = fps
        self.videoEncoder = videoEncoder
        super.init()
    }

    func startRequestingMediaData() {
        videoEncoder?.startRequestingMediaData()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        if type == .microphone || type == .audio {
            guard CMSampleBufferIsValid(sampleBuffer) else { return }

            guard assetWriterSession?.capturesAudio == true else { return }

            lock.withLockUnchecked {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

                // 音声のみの場合は従来通り
                let hasVideo = videoEncoder != nil
                if !hasVideo {
                    if !sessionStartPTS.isValid {
                        sessionStartPTS = pts
                        videoEncoder?.startSession(at: pts)
                        assetWriterSession?.startSession(at: pts)
                        hasStartedSession = true
                    }
                    lastAudioPTS = pts
                    return
                }

                // 音声と映像の両方が有効な場合
                if !hasStartedSession {
                    sessionStartPTS = pts
                    videoEncoder?.startSession(at: pts)
                    assetWriterSession?.startSession(at: pts)
                    hasStartedSession = true
                }

                // セッション開始済み
                lastAudioPTS = pts
            }

            assetWriterSession?.append(sampleBuffer, type: type)
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

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            if hasStartedSession {
                receivedFrameCount += 1
            }
            return
        }
        let hasAudio = assetWriterSession?.capturesAudio == true
        if hasAudio && !hasStartedSession { return }
        if !hasStartedSession { startSessionIfNeeded(at: pts) }

        receivedFrameCount += 1
        if !firstVideoPTS.isValid {
            firstVideoPTS = pts
        } else if lastVideoPresentationTime.isValid && pts <= lastVideoPresentationTime {
            return
        }
        recordVideoInterval(pts: pts)
        lastVideoPresentationTime = pts
        CVBufferRemoveAttachment(imageBuffer, kCVImageBufferCGColorSpaceKey)
        videoEncoder?.writeFrame(imageBuffer, pts: pts)
        frameCount += 1

        let elapsed = mach_absolute_time() - startNanos
        if elapsed > maxCallbackNanos {
            maxCallbackNanos = elapsed
        }
    }

    func finishSession() {
        receivedFrameCount += videoEncoder?.finish() ?? 0

        lock.withLockUnchecked {
            if hasStartedSession {
                let finalEnd = latestValidTime(
                    lastVideoPresentationTime,
                    lastAudioPTS
                )
                assetWriterSession?.finishSession(at: finalEnd)
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
                videoEncoder?.startSession(at: pts)
                assetWriterSession?.startSession(at: pts)
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
