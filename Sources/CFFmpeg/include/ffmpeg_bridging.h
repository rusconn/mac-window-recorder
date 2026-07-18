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

#ifndef ffmpeg_bridging_h
#define ffmpeg_bridging_h

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/pixfmt.h>
#include <libswscale/swscale.h>
#include <unistd.h>
#include <fcntl.h>

static inline int swift_av_err_eagain(void) { return AVERROR(EAGAIN); }
static inline int swift_av_err_eof(void) { return AVERROR_EOF; }

static inline int swift_sws_scale(
    SwsContext *ctx,
    const uint8_t *src, int srcStride,
    int srcSliceY, int srcSliceH,
    uint8_t *dst0, uint8_t *dst1, uint8_t *dst2,
    int dstStride0, int dstStride1, int dstStride2)
{
    const uint8_t *srcSlice[] = { src };
    int srcStrides[] = { srcStride };
    uint8_t *dstSlice[] = { dst0, dst1, dst2 };
    int dstStrides[] = { dstStride0, dstStride1, dstStride2 };
    return sws_scale(ctx, srcSlice, srcStrides, srcSliceY, srcSliceH, dstSlice, dstStrides);
}

static inline void swift_avformat_close_input(AVFormatContext **ctx) {
    avformat_close_input(ctx);
}

static inline void swift_sws_set_bt709(SwsContext *ctx) {
    const int *coeff = sws_getCoefficients(SWS_CS_ITU709);
    sws_setColorspaceDetails(ctx, coeff, 1, coeff, 0, 0, 1 << 16, 1 << 16);
}

static void swift_av_log_null(void *avcl, int level, const char *fmt, va_list vl) {
    (void)avcl; (void)level; (void)fmt; (void)vl;
}

// NOTE: libx264/libx265 は av_log を経由せず stderr に直接出力するため、
// av_log_set_callback / av_log_set_level では libx264 のログを抑制できない。
// swift_suppress_stderr / swift_restore_stderr を併用して stderr を直接黙らせる。
static inline void swift_av_log_set_quiet(void) {
    av_log_set_callback(swift_av_log_null);
}

static inline void swift_av_log_set_default(void) {
    av_log_set_callback(NULL);
}

static inline int swift_suppress_stderr(void) {
    // NOTE: libx264/libx265 は av_log を経由せず stderr に直接出力するため、
    // av_log_set_level(AV_LOG_QUIET) では抑制できない。stderr を一時的に破棄する。
    int fd = dup(STDERR_FILENO);
    int devnull = open("/dev/null", O_WRONLY);
    dup2(devnull, STDERR_FILENO);
    close(devnull);
    return fd;
}

static inline void swift_restore_stderr(int savedFd) {
    dup2(savedFd, STDERR_FILENO);
    close(savedFd);
}

#endif
