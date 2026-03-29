struct AVFrame;
struct AVCodecContext;
struct AVCodec;

/// Configures `AVCodecContext` for FFmpeg's VideoToolbox **hwaccel** (not a separate decoder). Call after `avcodec_parameters_to_context`, before `avcodec_open2`. Returns 0 on success.
int ff_videotoolbox_setup_decoder(struct AVCodecContext *ctx, const struct AVCodec *codec);
int ffmpeg_is_eof(int err);
int ff_err_eagain(void);
int ff_err_enomem(void);
int ff_err_eof(void);
int ff_sws_scale(void *c, struct AVFrame *src, struct AVFrame *dst);
int ff_swr_convert_interleaved_flt(void *swr, float *out, int out_samples_per_channel, struct AVFrame *frame);
int ff_swr_convert_planar_flt(void *swr, void *out_planes, int out_samples_per_channel, struct AVFrame *frame);
void *ff_sws_get_context(int srcW, int srcH, int srcFmt, int dstW, int dstH, int dstFmt, int flags);
void ff_sws_free(void *sws);
