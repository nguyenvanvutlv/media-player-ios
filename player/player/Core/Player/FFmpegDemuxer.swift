import Foundation

enum FFmpegDemuxerError: Error {
    case openFailed(code: Int32)
    case streamInfoFailed(code: Int32)
    case noStreams
    case seekFailed(code: Int32)
}

/// Stream metadata for UI track lists (language, codec id name).
struct FFmpegStreamInfo {
    let streamIndex: Int
    let mediaType: AVMediaType
    let language: String?
    let codecName: String
}

/// Demux-only: `avformat_open_input`, `find_stream_info`, `av_read_frame`.
final class FFmpegDemuxer {
    private(set) var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var interruptState: UnsafeMutablePointer<FFmpegInterruptState>?
    private var readTimeoutSeconds: Double = 8.0

    private(set) var videoStreamIndex: Int = -1
    /// Active audio stream; may be switched to any entry in `audioStreamIndices`.
    private(set) var audioStreamIndex: Int = -1
    /// All audio stream indices in file order.
    private(set) var audioStreamIndices: [Int] = []
    /// All subtitle stream indices in file order.
    private(set) var subtitleStreamIndices: [Int] = []
    /// Duration in seconds (`AVFormatContext.duration`), or estimated from streams.
    private(set) var durationSeconds: Double = 0

    private var streamInfos: [Int: FFmpegStreamInfo] = [:]

    /// Call before first `readPacket`.
    func open(url: URL) throws {
        close()
        streamInfos = [:]
        audioStreamIndices = []
        subtitleStreamIndices = []
        durationSeconds = 0

        // Allocate format context so we can install `interrupt_callback` BEFORE open.
        var fmt: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        if fmt == nil { throw FFmpegDemuxerError.openFailed(code: ff_err_enomem()) }

        interruptState = UnsafeMutablePointer<FFmpegInterruptState>.allocate(capacity: 1)
        interruptState?.initialize(to: FFmpegInterruptState(cancel: 0, deadline_us: 0))
        if let st = interruptState, let f = fmt {
            ff_format_set_interrupt_callback(f, st)
        }

        let cstr = url.absoluteString.cString(using: .utf8)!
        var ret = avformat_open_input(&fmt, cstr, nil, nil)
        if ret < 0 { throw FFmpegDemuxerError.openFailed(code: ret) }
        formatContext = fmt
        ret = avformat_find_stream_info(fmt, nil)
        if ret < 0 { throw FFmpegDemuxerError.streamInfoFailed(code: ret) }

        guard let fc = fmt else { throw FFmpegDemuxerError.noStreams }
        let nb = Int(fc.pointee.nb_streams)
        guard let streams = fc.pointee.streams else { throw FFmpegDemuxerError.noStreams }

        for i in 0..<nb {
            guard let st = streams[i] else { continue }
            let type = st.pointee.codecpar.pointee.codec_type
            if type == AVMEDIA_TYPE_AUDIO {
                audioStreamIndices.append(i)
            } else if type == AVMEDIA_TYPE_SUBTITLE {
                subtitleStreamIndices.append(i)
            }
            streamInfos[i] = Self.makeStreamInfo(stream: st, streamIndex: i, mediaType: type)
        }

        videoStreamIndex = Int(av_find_best_stream(fc, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0))
        audioStreamIndex = Int(av_find_best_stream(fc, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0))
        if audioStreamIndex < 0, let first = audioStreamIndices.first {
            audioStreamIndex = first
        }
        if videoStreamIndex < 0 && audioStreamIndex < 0 {
            throw FFmpegDemuxerError.noStreams
        }

        durationSeconds = Self.computeDurationSeconds(formatContext: fc)
        packet = av_packet_alloc()
    }

    /// Select active audio stream by **index into `audioStreamIndices`** (not FFmpeg stream index).
    func setActiveAudioTrackIndex(_ trackIndex: Int) {
        guard trackIndex >= 0, trackIndex < audioStreamIndices.count else { return }
        audioStreamIndex = audioStreamIndices[trackIndex]
    }

    func activeAudioTrackListIndex() -> Int {
        audioStreamIndices.firstIndex(of: audioStreamIndex) ?? 0
    }

    func streamInfo(streamIndex: Int) -> FFmpegStreamInfo? {
        streamInfos[streamIndex]
    }

    func formatTitleOrURL() -> String? {
        guard let fmt = formatContext else { return nil }
        if let dict = fmt.pointee.metadata {
            if let t = av_dict_get(dict, "title", nil, 0), let c = t.pointee.value {
                return String(cString: c)
            }
        }
        if let url = fmt.pointee.url {
            return String(cString: url)
        }
        return nil
    }

    /// Seek: prefer **video stream** `time_base` + `start_time` so the target matches decoded PTS; then `avformat_flush`.
    /// When `flags == 0`, uses `AVSEEK_FLAG_BACKWARD` so the demuxer lands on a keyframe at or before the target (required for correct decode after flush).
    func seek(toSeconds seconds: Double, flags: Int32 = 0) throws {
        guard let fmt = formatContext else {
            throw FFmpegDemuxerError.seekFailed(code: -5)
        }
        let clamped = max(0, seconds)
        let avTimeBase: Int64 = 1_000_000 // AV_TIME_BASE
        let avTimeBaseQ = AVRational(num: 1, den: Int32(avTimeBase))
        let effectiveFlags: Int32 = flags != 0 ? flags : AVSEEK_FLAG_BACKWARD

        let ret: Int32
        if videoStreamIndex >= 0,
           let streams = fmt.pointee.streams,
           let st = streams[videoStreamIndex] {
            let tb = st.pointee.time_base
            if tb.den > 0 {
                let us = Int64(clamped * Double(avTimeBase))
                var targetTicks = av_rescale_q(us, avTimeBaseQ, tb)
                let start = st.pointee.start_time
                if start != Self.noptsInt64() {
                    targetTicks += start
                }
                PlaybackLog.ffmpeg(
                    "avformat_seek_file stream=\(videoStreamIndex) targetTicks=\(targetTicks) tb=\(tb.num)/\(tb.den) flags=\(effectiveFlags)"
                )
                ret = avformat_seek_file(fmt, Int32(videoStreamIndex), Int64.min, targetTicks, Int64.max, effectiveFlags)
            } else {
                let us = Int64(clamped * Double(avTimeBase))
                PlaybackLog.ffmpeg("avformat_seek_file fallback stream=-1 us=\(us) (video tb invalid)")
                ret = avformat_seek_file(fmt, -1, Int64.min, us, Int64.max, effectiveFlags)
            }
        } else {
            let us = Int64(clamped * Double(avTimeBase))
            PlaybackLog.ffmpeg("avformat_seek_file stream=-1 us=\(us) (no video stream)")
            ret = avformat_seek_file(fmt, -1, Int64.min, us, Int64.max, effectiveFlags)
        }

        if ret < 0 { throw FFmpegDemuxerError.seekFailed(code: ret) }
        avformat_flush(fmt)
        PlaybackLog.ffmpeg("seek OK ret=\(ret) clamped=\(String(format: "%.3f", clamped))s")
    }

    private static func computeDurationSeconds(formatContext: UnsafeMutablePointer<AVFormatContext>) -> Double {
        let d = formatContext.pointee.duration
        if d != Self.noptsInt64() && d > 0 {
            return Double(d) / 1_000_000.0
        }
        var maxEnd: Double = 0
        let nb = Int(formatContext.pointee.nb_streams)
        guard let streams = formatContext.pointee.streams else { return 0 }
        for i in 0..<nb {
            guard let st = streams[i] else { continue }
            let dur = st.pointee.duration
            let tb = st.pointee.time_base
            if dur > 0, tb.den > 0 {
                let sec = Double(dur) * Double(tb.num) / Double(tb.den)
                maxEnd = max(maxEnd, sec)
            }
        }
        return maxEnd
    }

    private static func makeStreamInfo(stream: UnsafeMutablePointer<AVStream>, streamIndex: Int, mediaType: AVMediaType) -> FFmpegStreamInfo {
        guard let par = stream.pointee.codecpar else {
            return FFmpegStreamInfo(streamIndex: streamIndex, mediaType: mediaType, language: nil, codecName: "unknown")
        }
        let cid = par.pointee.codec_id
        let codecNamePtr = avcodec_get_name(cid)
        let codecName = codecNamePtr != nil ? String(cString: codecNamePtr!) : "unknown"

        var lang: String?
        if let meta = stream.pointee.metadata {
            if let e = av_dict_get(meta, "language", nil, 0), let v = e.pointee.value {
                lang = String(cString: v)
            }
        }
        if lang == nil, let meta = stream.pointee.metadata, let e = av_dict_get(meta, "lang", nil, 0), let v = e.pointee.value {
            lang = String(cString: v)
        }

        return FFmpegStreamInfo(streamIndex: streamIndex, mediaType: mediaType, language: lang, codecName: codecName)
    }

    func codecParameters(streamIndex: Int) -> UnsafePointer<AVCodecParameters>? {
        guard let fmt = formatContext,
              streamIndex >= 0,
              streamIndex < Int(fmt.pointee.nb_streams),
              let streams = fmt.pointee.streams,
              let st = streams[streamIndex],
              let par = st.pointee.codecpar else { return nil }
        return UnsafePointer(par)
    }

    func timeBase(streamIndex: Int) -> AVRational {
        guard let fmt = formatContext,
              streamIndex >= 0,
              streamIndex < Int(fmt.pointee.nb_streams),
              let streams = fmt.pointee.streams,
              let st = streams[streamIndex] else {
            return AVRational(num: 0, den: 1)
        }
        return st.pointee.time_base
    }

    func close() {
        if packet != nil {
            av_packet_free(&packet)
            packet = nil
        }
        if formatContext != nil {
            avformat_close_input(&formatContext)
            formatContext = nil
        }
        if let st = interruptState {
            st.deinitialize(count: 1)
            st.deallocate()
            interruptState = nil
        }
        videoStreamIndex = -1
        audioStreamIndex = -1
        audioStreamIndices = []
        subtitleStreamIndices = []
        streamInfos = [:]
        durationSeconds = 0
    }

    private static func noptsInt64() -> Int64 {
        Int64(bitPattern: UInt64(0x8000_0000_0000_0000))
    }

    deinit { close() }

    /// Returns `true` if a packet was read; `false` on EOF. Packet is valid until next read.
    func readPacket() throws -> Bool {
        guard let fmt = formatContext, let pkt = packet else { return false }
        // Deadline-based interrupt: prevents indefinite blocking on network reads.
        if let st = interruptState, readTimeoutSeconds > 0 {
            let now = ff_time_us()
            let deadline = now + Int64(readTimeoutSeconds * 1_000_000.0)
            ff_interrupt_state_set_deadline_us(st, deadline)
        }
        let ret = av_read_frame(fmt, pkt)
        if ret < 0 {
            if ffmpeg_is_eof(Int32(ret)) != 0 {
                return false
            }
            throw FFmpegDemuxerError.openFailed(code: ret)
        }
        return true
    }

    /// Set read timeout (seconds) used by the interrupt callback. Set <= 0 to disable deadlines.
    func setReadTimeoutSeconds(_ seconds: Double) {
        readTimeoutSeconds = seconds
    }

    /// Interrupt a blocking demux read ASAP (used when seek/stop is requested).
    func interruptBlockingIO() {
        if let st = interruptState {
            ff_interrupt_state_cancel(st)
        }
    }

    /// Clear cancel/deadline after an interrupt-triggered unwind.
    func clearInterrupt() {
        if let st = interruptState {
            ff_interrupt_state_reset(st)
        }
    }

    var currentPacket: UnsafeMutablePointer<AVPacket>? { packet }

    func videoCodecParameters() -> UnsafePointer<AVCodecParameters>? {
        guard let fmt = formatContext, videoStreamIndex >= 0 else { return nil }
        guard let par = fmt.pointee.streams[videoStreamIndex]!.pointee.codecpar else { return nil }
        return UnsafePointer(par)
    }

    func audioCodecParameters() -> UnsafePointer<AVCodecParameters>? {
        guard let fmt = formatContext, audioStreamIndex >= 0 else { return nil }
        guard let par = fmt.pointee.streams[audioStreamIndex]!.pointee.codecpar else { return nil }
        return UnsafePointer(par)
    }

    func videoTimeBase() -> AVRational {
        guard let fmt = formatContext, videoStreamIndex >= 0 else { return AVRational(num: 0, den: 1) }
        return fmt.pointee.streams[videoStreamIndex]!.pointee.time_base
    }

    func audioTimeBase() -> AVRational {
        guard let fmt = formatContext, audioStreamIndex >= 0 else { return AVRational(num: 0, den: 1) }
        return fmt.pointee.streams[audioStreamIndex]!.pointee.time_base
    }

    /// Stream `start_time` converted to seconds (media offset of the first packet). `nil` if unknown.
    func streamMediaStartSeconds(streamIndex: Int) -> Double? {
        guard let fmt = formatContext,
              streamIndex >= 0,
              let streams = fmt.pointee.streams,
              let stPtr = streams[streamIndex] else { return nil }
        let st = stPtr.pointee
        let start = st.start_time
        if start == av_nopts_value_int64() { return nil }
        let tb = st.time_base
        guard tb.den > 0 else { return nil }
        return Double(start) * Double(tb.num) / Double(tb.den)
    }

    private func av_nopts_value_int64() -> Int64 {
        Int64(bitPattern: UInt64(0x8000_0000_0000_0000))
    }
}
