#ifndef PLAYER_BRIDGING_HEADER_H
#define PLAYER_BRIDGING_HEADER_H

#include <libavcodec/avcodec.h>
#include <libavcodec/codec_par.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/mathematics.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/hdr_dynamic_metadata.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#if __has_include(<ass/ass.h>)
#include <ass/ass.h>
#else
#include "../../../libass/libass/ass.h"
#endif

#import "FFmpegBridge.h"

#endif
