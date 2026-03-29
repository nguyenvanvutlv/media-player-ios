#include <libavutil/error.h>
#include <errno.h>
#include <stdint.h>
#include <libavutil/frame.h>
#include <libavutil/hwcontext.h>
#include <libavcodec/avcodec.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>

static enum AVPixelFormat ff_get_format_videotoolbox(AVCodecContext *ctx, const enum AVPixelFormat *pix_fmts)
{
    enum AVPixelFormat want = (enum AVPixelFormat)(uintptr_t)ctx->opaque;
    const enum AVPixelFormat *p;
    for (p = pix_fmts; *p != AV_PIX_FMT_NONE; p++) {
        if (*p == want)
            return *p;
    }
    return AV_PIX_FMT_NONE;
}

int ff_videotoolbox_setup_decoder(AVCodecContext *ctx, const AVCodec *codec)
{
    AVBufferRef *device = NULL;
    int err;
    const AVCodecHWConfig *cfg = NULL;
    for (int i = 0;; i++) {
        cfg = avcodec_get_hw_config(codec, i);
        if (!cfg)
            return AVERROR(ENOENT);
        if ((cfg->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) &&
            cfg->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX) {
            err = av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0);
            if (err < 0) {
                av_buffer_unref(&device);
                return err;
            }
            ctx->hw_device_ctx = av_buffer_ref(device);
            av_buffer_unref(&device);
            ctx->opaque = (void *)(uintptr_t)cfg->pix_fmt;
            ctx->get_format = ff_get_format_videotoolbox;
            return 0;
        }
    }
}

int ffmpeg_is_eof(int err) {
    return err == AVERROR_EOF;
}

int ff_err_eagain(void) { return AVERROR(EAGAIN); }
int ff_err_enomem(void) { return AVERROR(ENOMEM); }
int ff_err_eof(void) { return AVERROR_EOF; }

int ff_sws_scale(void *c, AVFrame *src, AVFrame *dst) {
    return sws_scale((struct SwsContext *)c,
                     (const uint8_t *const *)src->data, src->linesize,
                     0, src->height,
                     (uint8_t *const *)dst->data, dst->linesize);
}

int ff_swr_convert_interleaved_flt(void *swr, float *out, int out_samples_per_channel, AVFrame *frame) {
    uint8_t *out_planes[1] = { (uint8_t *)out };
    const uint8_t **in = (const uint8_t **)(frame->extended_data ? frame->extended_data : frame->data);
    return swr_convert((struct SwrContext *)swr, out_planes, out_samples_per_channel, in, frame->nb_samples);
}

int ff_swr_convert_planar_flt(void *swr, void *out_planes, int out_samples_per_channel, AVFrame *frame) {
    const uint8_t **in = (const uint8_t **)(frame->extended_data ? frame->extended_data : frame->data);
    return swr_convert((struct SwrContext *)swr, (uint8_t **)out_planes, out_samples_per_channel, in, frame->nb_samples);
}

void *ff_sws_get_context(int srcW, int srcH, int srcFmt, int dstW, int dstH, int dstFmt, int flags) {
    return sws_getContext(
        srcW, srcH, (enum AVPixelFormat)srcFmt,
        dstW, dstH, (enum AVPixelFormat)dstFmt,
        flags, NULL, NULL, NULL);
}

void ff_sws_free(void *sws) {
    /* FFmpeg 6+ API: sws_freeContext(SwsContext *) — not SwsContext ** */
    if (!sws) return;
    sws_freeContext((struct SwsContext *)sws);
}

