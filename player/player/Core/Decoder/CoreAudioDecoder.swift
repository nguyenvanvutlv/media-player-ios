import AVFoundation
import Foundation

enum CoreAudioDecoderError: Error {
    case noCodec
    case openFailed(code: Int32)
    case swrFailed
    case bufferFailed
}

/// FFmpeg decode + swresample → PCM matching the **`AVAudioPlayerNode` bus format** from `connect(..., format: nil)`.
/// iOS mixers typically expect **non‑interleaved Float32**; a hand‑rolled `AVAudioFormat(interleaved: true)` often fails with `-10868`.
final class CoreAudioDecoder {
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var swr: OpaquePointer?
    private var swrOutLayout = AVChannelLayout()
    private var swrOutLayoutInited = false

    private var timeBase: AVRational = AVRational(num: 1, den: 1)
    /// Cumulative timeline when FFmpeg PTS is missing (best-effort).
    private var syntheticPtsSeconds: Double = 0

    private(set) var outputFormat: AVAudioFormat?

    /// - Parameter engineFormat: Use `AVAudioPlayerNode.outputFormat(forBus: 0)` after `connect(..., format: nil)` + `prepare()`.
    /// - Parameter timeBase: Stream `time_base` from `AVStream` (used to turn `best_effort_timestamp` into seconds).
    func open(codecpar: UnsafePointer<AVCodecParameters>, engineFormat: AVAudioFormat, timeBase: AVRational) throws {
        close()
        self.timeBase = timeBase
        syntheticPtsSeconds = 0
        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            throw CoreAudioDecoderError.noCodec
        }
        var ctxPtr: UnsafeMutablePointer<AVCodecContext>? = avcodec_alloc_context3(codec)
        guard let ctx = ctxPtr else { throw CoreAudioDecoderError.openFailed(code: ff_err_enomem()) }
        var err = avcodec_parameters_to_context(ctx, codecpar)
        if err < 0 { avcodec_free_context(&ctxPtr); throw CoreAudioDecoderError.openFailed(code: err) }
        err = avcodec_open2(ctx, codec, nil)
        if err < 0 { avcodec_free_context(&ctxPtr); throw CoreAudioDecoderError.openFailed(code: err) }
        codecContext = ctx
        frame = av_frame_alloc()
        if frame == nil { avcodec_free_context(&ctxPtr); throw CoreAudioDecoderError.openFailed(code: ff_err_enomem()) }

        let outRate = Int32(engineFormat.sampleRate)
        let outCh = max(1, Int(engineFormat.channelCount))
        var outLayout = AVChannelLayout()
        av_channel_layout_default(&outLayout, Int32(outCh))
        swrOutLayout = outLayout
        swrOutLayoutInited = true

        let outAvFmt: AVSampleFormat = engineFormat.isInterleaved ? AV_SAMPLE_FMT_FLT : AV_SAMPLE_FMT_FLTP

        var swrPtr: OpaquePointer? = swr_alloc()
        guard swrPtr != nil else {
            av_channel_layout_uninit(&swrOutLayout)
            swrOutLayoutInited = false
            throw CoreAudioDecoderError.swrFailed
        }
        swr = swrPtr

        err = swr_alloc_set_opts2(
            &swrPtr,
            &swrOutLayout,
            outAvFmt,
            outRate,
            &ctx.pointee.ch_layout,
            ctx.pointee.sample_fmt,
            ctx.pointee.sample_rate,
            0,
            nil
        )
        swr = swrPtr
        if err < 0 {
            swr_free(&swrPtr)
            swr = nil
            av_channel_layout_uninit(&swrOutLayout)
            swrOutLayoutInited = false
            throw CoreAudioDecoderError.openFailed(code: err)
        }
        guard let s = swr else {
            av_channel_layout_uninit(&swrOutLayout)
            swrOutLayoutInited = false
            throw CoreAudioDecoderError.swrFailed
        }
        err = swr_init(s)
        if err < 0 {
            swr_free(&swr)
            swr = nil
            av_channel_layout_uninit(&swrOutLayout)
            swrOutLayoutInited = false
            throw CoreAudioDecoderError.openFailed(code: err)
        }

        outputFormat = engineFormat
    }

    func close() {
        syntheticPtsSeconds = 0
        if swr != nil { swr_free(&swr) }
        if swrOutLayoutInited {
            av_channel_layout_uninit(&swrOutLayout)
            swrOutLayoutInited = false
        }
        if frame != nil { av_frame_free(&frame) }
        if codecContext != nil { avcodec_free_context(&codecContext) }
        outputFormat = nil
    }

    deinit { close() }

    func prepareForSeek() {
        syntheticPtsSeconds = 0
        guard let ctx = codecContext, let frm = frame else { return }
        avcodec_flush_buffers(ctx)
        let again = ff_err_eagain()
        let eof = ff_err_eof()
        while true {
            let ret = avcodec_receive_frame(ctx, frm)
            if ret == again || ret == eof { break }
            if ret < 0 { break }
        }
    }

    func sendPacket(_ packet: UnsafeMutablePointer<AVPacket>) throws {
        guard let ctx = codecContext else { return }
        let ret = avcodec_send_packet(ctx, packet)
        let again = ff_err_eagain()
        let eof = ff_err_eof()
        if ret < 0, ret != again, ret != eof {
            throw CoreAudioDecoderError.openFailed(code: ret)
        }
    }

    /// Decoded PCM plus **start** presentation time in **seconds** (stream timeline, FFmpeg PTS × `time_base`).
    func receivePCM() throws -> (AVAudioPCMBuffer, Double)? {
        guard let ctx = codecContext, let frm = frame, let fmt = outputFormat, let swrCtx = swr else { return nil }
        let ret = avcodec_receive_frame(ctx, frm)
        let again = ff_err_eagain()
        let eof = ff_err_eof()
        if ret == again || ret == eof { return nil }
        if ret < 0 { throw CoreAudioDecoderError.openFailed(code: ret) }

        let ptsStartSec = presentationStartSeconds(for: frm, codecCtx: ctx)

        let channels = Int(fmt.channelCount)
        let outRate = Int32(fmt.sampleRate)
        let delay = swr_get_delay(swrCtx, Int64(ctx.pointee.sample_rate))
        let outCount = av_rescale_rnd(
            delay + Int64(frm.pointee.nb_samples),
            Int64(outRate),
            Int64(ctx.pointee.sample_rate),
            AV_ROUND_UP
        )
        let outSamples = Int(outCount)

        if fmt.isInterleaved {
            guard let buf = try receivePCMInterleaved(swrCtx: swrCtx, frm: frm, fmt: fmt, channels: channels, outSamples: outSamples) else { return nil }
            return (buf, ptsStartSec)
        }
        guard let buf = try receivePCMPlanar(swrCtx: swrCtx, frm: frm, fmt: fmt, channels: channels, outSamples: outSamples) else { return nil }
        return (buf, ptsStartSec)
    }

    private func presentationStartSeconds(for frm: UnsafeMutablePointer<AVFrame>, codecCtx: UnsafeMutablePointer<AVCodecContext>) -> Double {
        let pts = frm.pointee.best_effort_timestamp
        let tb = timeBase
        if pts == av_nopts_value() {
            let sec = syntheticPtsSeconds
            syntheticPtsSeconds += Double(frm.pointee.nb_samples) / Double(max(1, codecCtx.pointee.sample_rate))
            return sec
        }
        if tb.den <= 0 {
            let sec = syntheticPtsSeconds
            syntheticPtsSeconds += Double(frm.pointee.nb_samples) / Double(max(1, codecCtx.pointee.sample_rate))
            return sec
        }
        return Double(pts) * Double(tb.num) / Double(tb.den)
    }

    private func av_nopts_value() -> Int64 {
        Int64(bitPattern: UInt64(0x8000_0000_0000_0000))
    }

    private func receivePCMInterleaved(
        swrCtx: OpaquePointer,
        frm: UnsafeMutablePointer<AVFrame>,
        fmt: AVAudioFormat,
        channels: Int,
        outSamples: Int
    ) throws -> AVAudioPCMBuffer? {
        var outStorage = [Float](repeating: 0, count: outSamples * channels)
        let conv = outStorage.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            return ff_swr_convert_interleaved_flt(UnsafeMutableRawPointer(swrCtx), base, Int32(outSamples), frm)
        }
        if conv < 0 { throw CoreAudioDecoderError.openFailed(code: conv) }
        let producedPerChannel = Int(conv)
        guard producedPerChannel > 0, let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(producedPerChannel)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(producedPerChannel)
        let byteCount = producedPerChannel * channels * MemoryLayout<Float>.size
        memcpy(buffer.floatChannelData![0], outStorage, byteCount)
        return buffer
    }

    private func receivePCMPlanar(
        swrCtx: OpaquePointer,
        frm: UnsafeMutablePointer<AVFrame>,
        fmt: AVAudioFormat,
        channels: Int,
        outSamples: Int
    ) throws -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(outSamples)) else {
            throw CoreAudioDecoderError.bufferFailed
        }
        guard let out = buffer.floatChannelData else {
            throw CoreAudioDecoderError.bufferFailed
        }

        let pp = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: channels)
        defer { pp.deallocate() }
        for ch in 0..<channels {
            pp[ch] = out[ch]
        }

        let conv = ff_swr_convert_planar_flt(
            UnsafeMutableRawPointer(swrCtx),
            UnsafeMutableRawPointer(pp),
            Int32(outSamples),
            frm
        )
        if conv < 0 { throw CoreAudioDecoderError.openFailed(code: conv) }
        let producedPerChannel = Int(conv)
        if producedPerChannel <= 0 { return nil }
        buffer.frameLength = AVAudioFrameCount(producedPerChannel)
        return buffer
    }
}
