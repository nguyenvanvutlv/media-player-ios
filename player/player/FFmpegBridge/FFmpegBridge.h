// Basic integer types used by the bridge.
#include <stdint.h>

struct AVFrame;
struct AVCodecContext;
struct AVCodec;
struct AVFormatContext;

/// Configures `AVCodecContext` for FFmpeg's VideoToolbox **hwaccel** (not a separate decoder). Call after `avcodec_parameters_to_context`, before `avcodec_open2`. Returns 0 on success.
int ff_videotoolbox_setup_decoder(struct AVCodecContext *ctx, const struct AVCodec *codec);
int ffmpeg_is_eof(int err);
int ff_err_eagain(void);
int ff_err_enomem(void);
int ff_err_eof(void);
int ff_sws_scale(void *c, struct AVFrame *src, struct AVFrame *dst);
/// Direct swscale into pre-allocated destination planes (avoids intermediate AVFrame allocations/copies).
int ff_sws_scale_planes(
    void *c,
    const uint8_t *const srcSlice[],
    const int srcStride[],
    int srcSliceY,
    int srcSliceH,
    uint8_t *const dst[],
    const int dstStride[]
);
int ff_swr_convert_interleaved_flt(void *swr, float *out, int out_samples_per_channel, struct AVFrame *frame);
int ff_swr_convert_planar_flt(void *swr, void *out_planes, int out_samples_per_channel, struct AVFrame *frame);
void *ff_sws_get_context(int srcW, int srcH, int srcFmt, int dstW, int dstH, int dstFmt, int flags);
void ff_sws_free(void *sws);

/// Monotonic time in microseconds (uses `av_gettime_relative`).
int64_t ff_time_us(void);

/// Interrupt/cancel support for blocking network reads (used by `AVFormatContext.interrupt_callback`).
/// `deadline_us`:
/// - 0: no deadline
/// - >0: interrupt after `ff_time_us() >= deadline_us`
typedef struct FFmpegInterruptState {
    volatile int cancel;
    int64_t deadline_us;
} FFmpegInterruptState;

void ff_interrupt_state_reset(FFmpegInterruptState *st);
void ff_interrupt_state_cancel(FFmpegInterruptState *st);
void ff_interrupt_state_set_deadline_us(FFmpegInterruptState *st, int64_t deadline_us);
void ff_format_set_interrupt_callback(struct AVFormatContext *fmt, FFmpegInterruptState *st);
