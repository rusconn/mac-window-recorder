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
import CoreMedia
import CoreVideo
import os
import CFFmpeg

final class FFmpegEncoder {
    private let outputURL: URL
    private let width: Int32
    private let height: Int32
    private let lock = OSAllocatedUnfairLock()
    private let encodeQueue = DispatchQueue(label: "ffmpeg.encode.queue", qos: .userInteractive)
    private let semaphore = DispatchSemaphore(value: 5)

    private var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var stream: UnsafeMutablePointer<AVStream>?
    private var swsContext: UnsafeMutablePointer<SwsContext>?
    private var bgraFrame: UnsafeMutablePointer<AVFrame>?
    private var yuvFrame: UnsafeMutablePointer<AVFrame>?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private let debug: Bool
    private var headerWritten = false
    private var frameCount = 0

    static func mergeAudioVideo(videoURL: URL, audioURL: URL, outputURL: URL) -> Bool {
        var videoInCtx: UnsafeMutablePointer<AVFormatContext>?
        var audioInCtx: UnsafeMutablePointer<AVFormatContext>?
        var outCtx: UnsafeMutablePointer<AVFormatContext>?

        let openVideo = avformat_open_input(&videoInCtx, videoURL.path, nil, nil)
        guard openVideo >= 0 else {
            print("[merge] 動画入力を開けません: \(videoURL.path)")
            return false
        }
        avformat_find_stream_info(videoInCtx, nil)

        let openAudio = avformat_open_input(&audioInCtx, audioURL.path, nil, nil)
        guard openAudio >= 0 else {
            print("[merge] 音声入力を開けません: \(audioURL.path)")
            swift_avformat_close_input(&videoInCtx)
            return false
        }
        avformat_find_stream_info(audioInCtx, nil)

        let openOut = avformat_alloc_output_context2(&outCtx, nil, nil, outputURL.path)
        guard openOut >= 0 else {
            print("[merge] 出力コンテキスト作成失敗")
            swift_avformat_close_input(&videoInCtx)
            swift_avformat_close_input(&audioInCtx)
            return false
        }

        var videoInIdx: Int32 = -1
        for i in 0..<Int(videoInCtx!.pointee.nb_streams) {
            let st = videoInCtx!.pointee.streams[i]!
            if st.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                videoInIdx = Int32(i)
                break
            }
        }

        var audioInIndices: [Int32] = []
        for i in 0..<Int(audioInCtx!.pointee.nb_streams) {
            let st = audioInCtx!.pointee.streams[i]!
            if st.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
                audioInIndices.append(Int32(i))
            }
        }

        guard videoInIdx >= 0, !audioInIndices.isEmpty else {
            print("[merge] ストリームが見つかりません (video=\(videoInIdx), audio=\(audioInIndices))")
            swift_avformat_close_input(&videoInCtx)
            swift_avformat_close_input(&audioInCtx)
            avformat_free_context(outCtx)
            return false
        }

        let outVideoStream = avformat_new_stream(outCtx, nil)
        guard let outVideoStream else { return false }
        avcodec_parameters_copy(outVideoStream.pointee.codecpar, videoInCtx!.pointee.streams[Int(videoInIdx)]!.pointee.codecpar)
        outVideoStream.pointee.codecpar.pointee.codec_tag = 0

        var outAudioStreams: [UnsafeMutablePointer<AVStream>] = []
        var inAudioTSList: [AVRational] = []
        for audioInIdx in audioInIndices {
            let outStream = avformat_new_stream(outCtx, nil)
            guard let outStream else { return false }
            avcodec_parameters_copy(outStream.pointee.codecpar, audioInCtx!.pointee.streams[Int(audioInIdx)]!.pointee.codecpar)
            outStream.pointee.codecpar.pointee.codec_tag = 0
            outAudioStreams.append(outStream)
            inAudioTSList.append(audioInCtx!.pointee.streams[Int(audioInIdx)]!.pointee.time_base)
        }

        let openRet = avio_open(&outCtx!.pointee.pb, outputURL.path, AVIO_FLAG_WRITE)
        guard openRet >= 0 else {
            print("[merge] 出力ファイルを開けません: \(outputURL.path) ret=\(openRet)")
            swift_avformat_close_input(&videoInCtx)
            swift_avformat_close_input(&audioInCtx)
            avformat_free_context(outCtx)
            return false
        }

        guard avformat_write_header(outCtx, nil) >= 0 else {
            print("[merge] ヘッダー書き込み失敗")
            avio_closep(&outCtx!.pointee.pb)
            swift_avformat_close_input(&videoInCtx)
            swift_avformat_close_input(&audioInCtx)
            avformat_free_context(outCtx)
            return false
        }

        let outAudioTSList = outAudioStreams.map { $0.pointee.time_base }

        let inVideoTS = videoInCtx!.pointee.streams[Int(videoInIdx)]!.pointee.time_base
        let outVideoTS = outVideoStream.pointee.time_base

        let pkt = av_packet_alloc()
        guard let pkt else { return false }
        defer {
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            av_packet_free(&p)
        }

        while av_read_frame(videoInCtx, pkt) >= 0 {
            if pkt.pointee.stream_index == videoInIdx {
                pkt.pointee.stream_index = 0
                av_packet_rescale_ts(pkt, inVideoTS, outVideoTS)
                av_interleaved_write_frame(outCtx, pkt)
            }
            av_packet_unref(pkt)
        }

        while av_read_frame(audioInCtx, pkt) >= 0 {
            if let matchIndex = audioInIndices.firstIndex(of: pkt.pointee.stream_index) {
                let inTS = inAudioTSList[matchIndex]
                let outTS = outAudioTSList[matchIndex]

                pkt.pointee.stream_index = Int32(1 + matchIndex)
                av_packet_rescale_ts(pkt, inTS, outTS)
                
                av_interleaved_write_frame(outCtx, pkt)
            }
            av_packet_unref(pkt)
        }

        av_write_trailer(outCtx)
        avio_closep(&outCtx!.pointee.pb)
        avformat_free_context(outCtx)
        swift_avformat_close_input(&videoInCtx)
        swift_avformat_close_input(&audioInCtx)

        return true
    }

    init?(width: Int, height: Int, codec: String, crf: Int, outputURL: URL, debug: Bool = false) {
        self.width = Int32(width)
        self.height = Int32(height)
        self.outputURL = outputURL
        self.debug = debug

        let savedFd = debug ? -1 : swift_suppress_stderr()
        let ok = setupEncoder(codec: codec, crf: crf)
        if savedFd >= 0 { swift_restore_stderr(savedFd) }
        guard ok else { return nil }
    }

    private func setupEncoder(codec: String, crf: Int) -> Bool {
        let ret = avformat_alloc_output_context2(&formatContext, nil, nil, outputURL.path)
        guard ret >= 0, let formatContext else {
            print("[FFmpegEncoder] 出力コンテキスト作成失敗: ret=\(ret)")
            return false
        }

        guard let encoder = avcodec_find_encoder_by_name(codec) else {
            print("[FFmpegEncoder] エンコーダが見つかりません: \(codec)")
            return false
        }

        stream = avformat_new_stream(formatContext, nil)
        guard let stream else { return false }

        codecContext = avcodec_alloc_context3(encoder)
        guard let codecContext else { return false }

        codecContext.pointee.width = width
        codecContext.pointee.height = height
        codecContext.pointee.pix_fmt = AV_PIX_FMT_YUV420P
        codecContext.pointee.time_base = AVRational(num: 1, den: 1_000_000)
        codecContext.pointee.framerate = AVRational(num: 60, den: 1)
        codecContext.pointee.max_b_frames = 0

        codecContext.pointee.colorspace = AVCOL_SPC_BT709
        codecContext.pointee.color_primaries = AVCOL_PRI_BT709
        codecContext.pointee.color_trc = AVCOL_TRC_BT709
        codecContext.pointee.color_range = AVCOL_RANGE_MPEG

        av_opt_set(codecContext.pointee.priv_data, "preset", "veryfast", 0)
        av_opt_set(codecContext.pointee.priv_data, "crf", "\(crf)", 0)
        av_opt_set(codecContext.pointee.priv_data, "g", "120", 0)
        if codec == "libx264" && !debug {
            av_opt_set(codecContext.pointee.priv_data, "x264-params", "log=-1", 0)
        }
        if codec == "libx265" && !debug {
            av_opt_set(codecContext.pointee.priv_data, "tag", "hvc1", 0)
            av_opt_set(codecContext.pointee.priv_data, "x265-params", "log-level=none", 0)
        }
        if codec == "libx265" && debug {
            av_opt_set(codecContext.pointee.priv_data, "tag", "hvc1", 0)
        }

        if formatContext.pointee.oformat.pointee.flags & AVFMT_GLOBALHEADER != 0 {
            codecContext.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER
        }

        guard avcodec_open2(codecContext, encoder, nil) >= 0 else {
            print("[FFmpegEncoder] エンコーダを開けません")
            return false
        }

        avcodec_parameters_from_context(stream.pointee.codecpar, codecContext)
        stream.pointee.time_base = codecContext.pointee.time_base

        bgraFrame = av_frame_alloc()
        guard let bgraFrame else { return false }
        bgraFrame.pointee.format = AV_PIX_FMT_BGRA.rawValue
        bgraFrame.pointee.width = width
        bgraFrame.pointee.height = height

        yuvFrame = av_frame_alloc()
        guard let yuvFrame else { return false }
        yuvFrame.pointee.format = AV_PIX_FMT_YUV420P.rawValue
        yuvFrame.pointee.width = width
        yuvFrame.pointee.height = height
        guard av_frame_get_buffer(yuvFrame, 0) >= 0 else {
            print("[FFmpegEncoder] YUVフレームバッファ確保失敗")
            return false
        }

        swsContext = sws_getContext(
            width, height, AV_PIX_FMT_BGRA,
            width, height, AV_PIX_FMT_YUV420P,
            Int32(SWS_BILINEAR.rawValue), nil, nil, nil
        )
        guard let swsContext else {
            print("[FFmpegEncoder] sws_getContext失敗")
            return false
        }
        swift_sws_set_bt709(swsContext)

        packet = av_packet_alloc()
        guard packet != nil else { return false }

        guard avio_open(&formatContext.pointee.pb, outputURL.path, AVIO_FLAG_WRITE) >= 0 else {
            print("[FFmpegEncoder] 出力ファイルを開けません")
            return false
        }

        guard avformat_write_header(formatContext, nil) >= 0 else {
            print("[FFmpegEncoder] ヘッダー書き込み失敗")
            return false
        }
        headerWritten = true

        return true
    }

    func writeFrame(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        semaphore.wait()

        encodeQueue.async { [self] in
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            let srcBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer)!
            let copySize = srcBytesPerRow * Int(height)
            let ownedData = UnsafeMutableRawPointer.allocate(byteCount: copySize, alignment: 1)
            ownedData.copyMemory(from: srcBase, byteCount: copySize)
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            let ptsUs = Int64(CMTimeGetSeconds(pts) * 1_000_000)

            self.lock.withLockUnchecked {
                guard let codecContext,
                      let swsContext, let bgraFrame, let yuvFrame else {
                    ownedData.deallocate()
                    self.semaphore.signal()
                    return
                }

                yuvFrame.pointee.format = AV_PIX_FMT_YUV420P.rawValue
                yuvFrame.pointee.width = width
                yuvFrame.pointee.height = height
                let makeWritableRet = av_frame_make_writable(yuvFrame)
                guard makeWritableRet >= 0 else {
                    print("[FFmpegEncoder] av_frame_make_writable失敗: \(makeWritableRet)")
                    ownedData.deallocate()
                    self.semaphore.signal()
                    return
                }

                bgraFrame.pointee.data.0 = ownedData.assumingMemoryBound(to: UInt8.self)
                bgraFrame.pointee.linesize.0 = Int32(srcBytesPerRow)

                swift_sws_scale(
                    swsContext,
                    bgraFrame.pointee.data.0, bgraFrame.pointee.linesize.0,
                    0, height,
                    yuvFrame.pointee.data.0, yuvFrame.pointee.data.1, yuvFrame.pointee.data.2,
                    yuvFrame.pointee.linesize.0, yuvFrame.pointee.linesize.1, yuvFrame.pointee.linesize.2
                )

                ownedData.deallocate()

                yuvFrame.pointee.pts = ptsUs

                let ret = avcodec_send_frame(codecContext, yuvFrame)
                if ret < 0 {
                    print("[FFmpegEncoder] avcodec_send_frame失敗: \(ret)")
                    self.semaphore.signal()
                    return
                }

                self.drainPackets()
                self.frameCount += 1
            }
            self.semaphore.signal()
        }
    }

    func finish() {
        encodeQueue.sync {
            self.lock.withLockUnchecked {
                defer { self.freeResources() }

                guard let codecContext, let formatContext else { return }

                let savedFd = debug ? -1 : swift_suppress_stderr()
                avcodec_send_frame(codecContext, nil)
                self.drainPackets()
                if headerWritten {
                    av_write_trailer(formatContext)
                }
                if savedFd >= 0 { swift_restore_stderr(savedFd) }
                print("[FFmpegEncoder] 合計フレーム数: \(self.frameCount)")
            }
        }
    }

    private func drainPackets() {
        guard let codecContext, let formatContext, let packet,
              let stream else { return }

        while true {
            let ret = avcodec_receive_packet(codecContext, packet)
            if ret == swift_av_err_eagain() || ret == swift_av_err_eof() {
                break
            }
            guard ret >= 0 else { break }

            av_packet_rescale_ts(packet, codecContext.pointee.time_base, stream.pointee.time_base)
            packet.pointee.stream_index = stream.pointee.index
            av_interleaved_write_frame(formatContext, packet)
            av_packet_unref(packet)
        }
    }

    private func freeResources() {
        av_packet_free(&packet)
        if let swsContext { sws_freeContext(swsContext) }
        av_frame_free(&yuvFrame)
        av_frame_free(&bgraFrame)
        if let formatContext { avio_closep(&formatContext.pointee.pb) }
        avcodec_free_context(&codecContext)
        avformat_free_context(formatContext)
    }
}
