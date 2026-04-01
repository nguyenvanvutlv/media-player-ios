import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

private let ffThreadFrame: Int32 = 1  // FF_THREAD_FRAME

enum CoreVideoDecoderError: Error {
    case noCodec
    case openFailed(code: Int32)
    case allocateFrameFailed
    case pixelBufferFailed
    case formatDescriptionFailed
    case sampleBufferFailed
}

/// FFmpeg video decode → `CMSampleBuffer` with 10‑bit biplanar YUV for HDR when possible (no RGB).
final class CoreVideoDecoder {
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var sws: UnsafeMutableRawPointer?
    private var pixelBufferPool: CVPixelBufferPool?
    private var pixelBufferPoolKey: (w: Int32, h: Int32, format: OSType)?

    private var dstPixFmt: AVPixelFormat = AV_PIX_FMT_NONE
    private var lastWidth: Int32 = 0
    private var lastHeight: Int32 = 0
    private var lastSrcFmt: AVPixelFormat = AV_PIX_FMT_NONE

    private var cachedVideoFormatDesc: CMVideoFormatDescription?
    private var cachedVideoFormatKey: (w: Int, h: Int, pf: OSType)?
    private var loggedFirstFrameSummary = false
    private var logged4kSoftwareWarning = false
    private var isUsingVideoToolbox: Bool = false
    private var openedWidth: Int = 0
    private var openedHeight: Int = 0

    /// First frame’s media time (seconds); following frames are relative so PTS starts near 0 for `CMTimebase`.
    private var timelineOriginSeconds: Double?
    /// Same value as the first-assigned `timelineOriginSeconds`, exposed for subtitle ↔ display clock alignment (playback thread writes; main reads via lock).
    private let timelineOriginLock = NSLock()
    private var syncedFirstFrameMediaSeconds: Double?
    private var syntheticFrameIndex: Int64 = 0
    private var nominalFrameDuration: Double = 1.0 / 30.0

    /// Extra delay applied to every video PTS (e.g. align with audio stream `start_time`).
    private var presentationShiftSeconds: Double = 0
    /// Enforces strictly increasing presentation times for `AVSampleBufferDisplayLayer` (avoids Fig -12083).
    private var lastPresentationSeconds: Double?

    // MARK: - Seek target frame-skipping

    /// When set, frames with PTS before this value are decoded (for reference chain) but NOT
    /// wrapped into CMSampleBuffer, avoiding expensive pixel-buffer creation and FIFO pollution.
    /// Cleared automatically when the first on-target frame is produced.
    private var seekTargetPtsSeconds: Double?
    /// Count of frames skipped during post-seek catch-up (for diagnostics).
    private var seekSkippedFrameCount: Int = 0

    init() {}

    func isHardwareDecoding() -> Bool { isUsingVideoToolbox }
    func openedDimensions() -> (w: Int, h: Int) { (openedWidth, openedHeight) }

    func setPresentationShiftSeconds(_ seconds: Double) {
        presentationShiftSeconds = max(0, seconds)
    }

    /// Called by `FFmpegPlaybackEngine.performSeek` before demuxer seek.
    /// Enables post-seek frame skipping + `AVDISCARD_NONREF` for faster catch-up.
    func setSeekTarget(_ seconds: Double) {
        seekTargetPtsSeconds = seconds
        seekSkippedFrameCount = 0
        // Align post-seek timeline so the first on-target frame lands near t=0
        // relative to the seek target (the engine sets `mediaTimelineAnchor = seconds`).
        timelineOriginSeconds = seconds
        timelineOriginLock.lock()
        syncedFirstFrameMediaSeconds = seconds
        timelineOriginLock.unlock()
        // Tell FFmpeg to skip non-reference B-frames during catch-up (cheaper decode).
        if let ctx = codecContext {
            ctx.pointee.skip_frame = AVDISCARD_NONREF
        }
    }

    /// Clear seek target — restores normal decoding mode.
    private func clearSeekTarget() {
        seekTargetPtsSeconds = nil
        if let ctx = codecContext {
            ctx.pointee.skip_frame = AVDISCARD_DEFAULT
        }
    }

    func open(codecpar: UnsafePointer<AVCodecParameters>, forceSoftwareDecode: Bool = false) throws
    {
        close()
        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            throw CoreVideoDecoderError.noCodec
        }
        #if os(iOS) || os(tvOS)
            if !forceSoftwareDecode {
                do {
                    try openCodecContext(codecpar: codecpar, codec: codec, useVideoToolboxHw: true)
                    return
                } catch {
                    PlaybackLog.video(
                        "[Video][WARN] VideoToolbox hwaccel unavailable or open failed — software fallback (\(String(describing: error)))"
                    )
                    close()
                }
            } else {
                PlaybackLog.video(
                    "[Video] software decode requested — VideoToolbox hwaccel skipped")
            }
        #endif
        try openCodecContext(codecpar: codecpar, codec: codec, useVideoToolboxHw: false)
    }

    /// `hevc_videotoolbox` / `h264_videotoolbox` in FFmpeg are **hwaccels** used with the normal `hevc` / `h264` decoders via `av_hwdevice_ctx_create` + `get_format`, not separate `avcodec_find_decoder_by_name` entries.
    private func openCodecContext(
        codecpar: UnsafePointer<AVCodecParameters>,
        codec: UnsafePointer<AVCodec>,
        useVideoToolboxHw: Bool
    ) throws {
        var ctxPtr: UnsafeMutablePointer<AVCodecContext>? = avcodec_alloc_context3(codec)
        guard let ctx = ctxPtr else {
            throw CoreVideoDecoderError.openFailed(code: ff_err_enomem())
        }
        var err = avcodec_parameters_to_context(ctx, codecpar)
        if err < 0 {
            avcodec_free_context(&ctxPtr)
            throw CoreVideoDecoderError.openFailed(code: err)
        }

        let codecName = String(cString: codec.pointee.name)
        var usesVtHw = false
        #if os(iOS) || os(tvOS)
            if useVideoToolboxHw {
                let st = ff_videotoolbox_setup_decoder(ctx, codec)
                if st == 0 {
                    usesVtHw = true
                    ctx.pointee.thread_count = 0
                    ctx.pointee.thread_type = 0
                    ctx.pointee.extra_hw_frames = 16
                } else {
                    avcodec_free_context(&ctxPtr)
                    throw CoreVideoDecoderError.openFailed(code: st)
                }
            }
        #endif
        if !usesVtHw {
            let n = ProcessInfo.processInfo.processorCount
            ctx.pointee.thread_count = Int32(min(8, max(2, n)))
            ctx.pointee.thread_type = ffThreadFrame
            if codecpar.pointee.codec_id == AV_CODEC_ID_HEVC {
                ctx.pointee.flags2 |= AV_CODEC_FLAG2_FAST
            }
        }

        err = avcodec_open2(ctx, codec, nil)
        if err < 0 {
            avcodec_free_context(&ctxPtr)
            throw CoreVideoDecoderError.openFailed(code: err)
        }
        codecContext = ctx
        let w = Int(ctx.pointee.width)
        let h = Int(ctx.pointee.height)
        openedWidth = w
        openedHeight = h
        isUsingVideoToolbox = usesVtHw
        let hwLabel = usesVtHw ? "videotoolbox" : "sw"
        PlaybackLog.video(
            "[Video] decoder=\(codecName) codec_id=\(codecpar.pointee.codec_id) hwaccel=\(hwLabel) size=\(w)x\(h)"
        )
        PlaybackLog.video(usesVtHw ? "[Video] decoder: hardware" : "[Video] decoder: software")
        if usesVtHw {
            PlaybackLog.video(
                "[Video] using hardware decode (VideoToolbox hwaccel + \(codecName) decoder)")
        }
        if !usesVtHw,
            codecpar.pointee.codec_id == AV_CODEC_ID_HEVC
                || codecpar.pointee.codec_id == AV_CODEC_ID_H264,
            w >= 3840 || h >= 2160
        {
            PlaybackLog.video(
                "[Video][WARN] 4K software decode detected at \(w)x\(h) — expected VideoToolbox; playback may stutter"
            )
        }
        frame = av_frame_alloc()
        if frame == nil {
            avcodec_free_context(&ctxPtr)
            throw CoreVideoDecoderError.allocateFrameFailed
        }

        let fr = ctx.pointee.framerate
        if fr.num > 0, fr.den > 0 {
            nominalFrameDuration = Double(fr.den) / Double(fr.num)
        }
    }

    /// Absolute media seconds of the first displayed frame after open/seek (matches FFmpeg PTS × time_base before relative conversion). `nil` until the first frame.
    func mediaTimelineOriginSeconds() -> Double? {
        timelineOriginLock.lock()
        defer { timelineOriginLock.unlock() }
        return syncedFirstFrameMediaSeconds
    }

    /// After demuxer seek: flush codec state and reset presentation timeline so the next frame re-anchors PTS.
    func prepareForSeek() {
        if let ctx = codecContext {
            avcodec_flush_buffers(ctx)
        }
        loggedFirstFrameSummary = false
        timelineOriginSeconds = nil
        timelineOriginLock.lock()
        syncedFirstFrameMediaSeconds = nil
        timelineOriginLock.unlock()
        syntheticFrameIndex = 0
        lastPresentationSeconds = nil
        // Note: seekTargetPtsSeconds is NOT cleared here — it persists across
        // flush so frame-skipping continues until the first on-target frame.
    }

    func close() {
        if let s = sws {
            ff_sws_free(s)
            sws = nil
        }
        pixelBufferPool = nil
        pixelBufferPoolKey = nil
        if frame != nil {
            av_frame_free(&frame)
        }
        if codecContext != nil {
            avcodec_free_context(&codecContext)
        }
        dstPixFmt = AV_PIX_FMT_NONE
        lastWidth = 0
        lastHeight = 0
        lastSrcFmt = AV_PIX_FMT_NONE
        cachedVideoFormatDesc = nil
        cachedVideoFormatKey = nil
        loggedFirstFrameSummary = false
        isUsingVideoToolbox = false
        openedWidth = 0
        openedHeight = 0
        timelineOriginSeconds = nil
        timelineOriginLock.lock()
        syncedFirstFrameMediaSeconds = nil
        timelineOriginLock.unlock()
        syntheticFrameIndex = 0
        presentationShiftSeconds = 0
        lastPresentationSeconds = nil
    }

    deinit { close() }

    func sendPacket(_ packet: UnsafeMutablePointer<AVPacket>) throws {
        guard let ctx = codecContext else { return }
        let ret = avcodec_send_packet(ctx, packet)
        let again = ff_err_eagain()
        let eof = ff_err_eof()
        if ret < 0, ret != again, ret != eof {
            throw CoreVideoDecoderError.openFailed(code: ret)
        }
    }

    func receiveSampleBuffer(timeBase: AVRational) throws -> CMSampleBuffer? {
        guard let ctx = codecContext, let frm = frame else { return nil }

        // When a seek target is active, loop internally to drain all pre-target frames
        // from the decoder's output buffer. This avoids returning nil prematurely — the
        // caller treats nil as "no more frames", which would break its receive loop even
        // though the decoder may still have buffered frames ready.
        while true {
            let ret = avcodec_receive_frame(ctx, frm)
            if ret == ff_err_eagain() || ret == ff_err_eof() { return nil }
            if ret < 0 { throw CoreVideoDecoderError.openFailed(code: ret) }

            // --- Post-seek frame skipping ---
            if let target = seekTargetPtsSeconds {
                let tb = timeBase
                let pts = frm.pointee.best_effort_timestamp
                if pts != av_nopts_value(), tb.den > 0 {
                    let frameSec = Double(pts) * Double(tb.num) / Double(tb.den)
                    let tolerance = nominalFrameDuration * 0.5
                    if frameSec < (target - tolerance) {
                        seekSkippedFrameCount += 1
                        av_frame_unref(frm)
                        continue  // drain next buffered frame immediately
                    }
                }
                // Reached (or passed) the target → stop skipping, restore normal decode.
                if seekSkippedFrameCount > 0 {
                    PlaybackLog.seek(
                        "[Seek] skipped \(seekSkippedFrameCount) pre-target frames during catch-up")
                }
                clearSeekTarget()
            }

            // Hardware frames must stay on the VideoToolbox path — never feed VIDEOTOOLBOX into swscale.
            if Int32(frm.pointee.format) == AV_PIX_FMT_VIDEOTOOLBOX.rawValue {
                let sb = try makeSampleBufferFromVideoToolbox(frame: frm, timeBase: timeBase)
                logFirstFrameSummaryIfNeeded(frame: frm, path: "videotoolbox")
                return sb
            }

            let sb = try makeSampleBufferViaSwscale(frame: frm, timeBase: timeBase)
            if sb != nil {
                logFirstFrameSummaryIfNeeded(frame: frm, path: "swscale")
            }
            return sb
        }
    }

    private func logFirstFrameSummaryIfNeeded(frame: UnsafeMutablePointer<AVFrame>, path: String) {
        guard !loggedFirstFrameSummary else { return }
        loggedFirstFrameSummary = true
        let w = Int(frame.pointee.width)
        let h = Int(frame.pointee.height)
        let fmt = Int32(frame.pointee.format)
        PlaybackLog.video("[Video] first frame path=\(path) pix_fmt=\(fmt) size=\(w)x\(h)")
        if !isUsingVideoToolbox, !logged4kSoftwareWarning, w >= 3840 || h >= 2160 {
            logged4kSoftwareWarning = true
            PlaybackLog.video("[Video][WARN] SW decode detected for 4K (pix_fmt=\(fmt))")
        }
    }

    private func makeSampleBufferFromVideoToolbox(
        frame: UnsafeMutablePointer<AVFrame>, timeBase: AVRational
    ) throws -> CMSampleBuffer {
        guard let raw = frame.pointee.data.3 else {
            throw CoreVideoDecoderError.openFailed(code: -3)
        }
        let cvBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(UnsafeRawPointer(raw))
            .takeUnretainedValue()
        attachHDRMetadata(to: cvBuffer, frame: frame)
        return try wrapPixelBuffer(cvBuffer, frame: frame, timeBase: timeBase)
    }

    private func makeSampleBufferViaSwscale(
        frame: UnsafeMutablePointer<AVFrame>, timeBase: AVRational
    ) throws -> CMSampleBuffer? {
        let streamLooksHDR = isHDRish(frame: frame)
        #if targetEnvironment(simulator)
            return try makeSampleBufferViaSwscale(
                frame: frame, timeBase: timeBase, hdrOutput: false)
        #else
            if streamLooksHDR {
                do {
                    return try makeSampleBufferViaSwscale(
                        frame: frame, timeBase: timeBase, hdrOutput: true)
                } catch CoreVideoDecoderError.pixelBufferFailed {
                    return try makeSampleBufferViaSwscale(
                        frame: frame, timeBase: timeBase, hdrOutput: false)
                }
            }
            return try makeSampleBufferViaSwscale(
                frame: frame, timeBase: timeBase, hdrOutput: false)
        #endif
    }

    private func makeSampleBufferViaSwscale(
        frame: UnsafeMutablePointer<AVFrame>, timeBase: AVRational, hdrOutput: Bool
    ) throws -> CMSampleBuffer? {
        let w = frame.pointee.width
        let h = frame.pointee.height
        let srcFmt = AVPixelFormat(frame.pointee.format)

        let dst: AVPixelFormat = hdrOutput ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12
        let cvFormat: OSType =
            hdrOutput
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        if sws == nil || w != lastWidth || h != lastHeight || srcFmt != lastSrcFmt
            || dst != dstPixFmt
        {
            if let s = sws {
                ff_sws_free(s)
                sws = nil
            }
            // SWS_FAST_BILINEAR (1) is noticeably cheaper than SWS_BILINEAR (2) for large frames on CPU.
            // Prefer it even for HDR output to reduce stutter on software decode paths.
            let swsFlags: Int32 = 1
            sws = ff_sws_get_context(
                Int32(w), Int32(h), srcFmt.rawValue,
                Int32(w), Int32(h), dst.rawValue,
                swsFlags
            )
            lastWidth = w
            lastHeight = h
            lastSrcFmt = srcFmt
            dstPixFmt = dst
        }
        guard let swsCtx = sws else { throw CoreVideoDecoderError.openFailed(code: -1) }
        let pb = try obtainPixelBufferFromPool(width: w, height: h, format: cvFormat)
        let scaleRet = try swsScaleIntoPixelBuffer(
            swsCtx: swsCtx,
            srcFrame: frame,
            dstPixelBuffer: pb,
            dstIs10Bit: hdrOutput
        )
        if scaleRet < 0 { throw CoreVideoDecoderError.openFailed(code: Int32(scaleRet)) }
        attachHDRMetadata(to: pb, frame: frame)
        return try wrapPixelBuffer(pb, frame: frame, timeBase: timeBase)
    }

    private func obtainPixelBufferFromPool(width: Int32, height: Int32, format: OSType) throws
        -> CVPixelBuffer
    {
        if pixelBufferPool == nil
            || pixelBufferPoolKey?.w != width
            || pixelBufferPoolKey?.h != height
            || pixelBufferPoolKey?.format != format
        {
            let pbAttrs: [CFString: Any] = [
                kCVPixelBufferWidthKey: Int(width),
                kCVPixelBufferHeightKey: Int(height),
                kCVPixelBufferPixelFormatTypeKey: Int(format),
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            var pool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(
                kCFAllocatorDefault, nil, pbAttrs as CFDictionary, &pool)
            guard status == kCVReturnSuccess, let created = pool else {
                throw CoreVideoDecoderError.pixelBufferFailed
            }
            pixelBufferPool = created
            pixelBufferPoolKey = (w: width, h: height, format: format)
        }
        guard let pool = pixelBufferPool else { throw CoreVideoDecoderError.pixelBufferFailed }
        var pb: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        guard status == kCVReturnSuccess, let out = pb else {
            throw CoreVideoDecoderError.pixelBufferFailed
        }
        return out
    }

    private func swsScaleIntoPixelBuffer(
        swsCtx: UnsafeMutableRawPointer,
        srcFrame: UnsafeMutablePointer<AVFrame>,
        dstPixelBuffer: CVPixelBuffer,
        dstIs10Bit: Bool
    ) throws -> Int {
        let lockStatus = CVPixelBufferLockBaseAddress(dstPixelBuffer, [])
        guard lockStatus == kCVReturnSuccess else { throw CoreVideoDecoderError.pixelBufferFailed }
        defer { CVPixelBufferUnlockBaseAddress(dstPixelBuffer, []) }

        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(dstPixelBuffer, 0),
            let uvBase = CVPixelBufferGetBaseAddressOfPlane(dstPixelBuffer, 1)
        else {
            throw CoreVideoDecoderError.pixelBufferFailed
        }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(dstPixelBuffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(dstPixelBuffer, 1)

        var dstPlanes: [UnsafeMutablePointer<UInt8>?] = [
            yBase.assumingMemoryBound(to: UInt8.self),
            uvBase.assumingMemoryBound(to: UInt8.self),
            nil,
            nil,
        ]
        var dstStrides: [Int32] = [Int32(yStride), Int32(uvStride), 0, 0]

        var srcPlanes: [UnsafePointer<UInt8>?] = [
            UnsafePointer(srcFrame.pointee.data.0),
            UnsafePointer(srcFrame.pointee.data.1),
            UnsafePointer(srcFrame.pointee.data.2),
            UnsafePointer(srcFrame.pointee.data.3),
        ]
        var srcStrides: [Int32] = [
            srcFrame.pointee.linesize.0,
            srcFrame.pointee.linesize.1,
            srcFrame.pointee.linesize.2,
            srcFrame.pointee.linesize.3,
        ]

        _ = dstIs10Bit

        return Int(
            ff_sws_scale_planes(
                swsCtx,
                &srcPlanes,
                &srcStrides,
                0,
                Int32(srcFrame.pointee.height),
                &dstPlanes,
                &dstStrides
            )
        )
    }

    private func isHDRish(frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        let trc = frame.pointee.color_trc
        if trc == AVCOL_TRC_SMPTE2084 || trc == AVCOL_TRC_ARIB_STD_B67 { return true }
        if frame.pointee.color_primaries == AVCOL_PRI_BT2020 { return true }
        let f = frame.pointee.format
        if f == AV_PIX_FMT_YUV420P10LE.rawValue || f == AV_PIX_FMT_YUV420P12LE.rawValue
            || f == AV_PIX_FMT_P010LE.rawValue
        {
            return true
        }
        return false
    }

    private func createCVPixelBuffer(
        from frame: UnsafeMutablePointer<AVFrame>, format: OSType, is10Bit: Bool
    ) throws -> CVPixelBuffer {
        let w = max(1, Int(frame.pointee.width))
        let h = max(1, Int(frame.pointee.height))

        let attrsWithMetal: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let attrsBasic: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
        ]

        var pb: CVPixelBuffer?
        var status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            w,
            h,
            format,
            attrsWithMetal as CFDictionary,
            &pb
        )
        if status != kCVReturnSuccess {
            status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                w,
                h,
                format,
                attrsBasic as CFDictionary,
                &pb
            )
        }
        if status != kCVReturnSuccess { throw CoreVideoDecoderError.pixelBufferFailed }
        guard let pixelBuffer = pb else { throw CoreVideoDecoderError.pixelBufferFailed }

        status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard status == kCVReturnSuccess else { throw CoreVideoDecoderError.pixelBufferFailed }

        copyNV12Like(from: frame, to: pixelBuffer, is10Bit: is10Bit)
        return pixelBuffer
    }

    private func copyNV12Like(
        from frame: UnsafeMutablePointer<AVFrame>, to pb: CVPixelBuffer, is10Bit: Bool
    ) {
        let w = Int(frame.pointee.width)
        let h = Int(frame.pointee.height)
        guard let yDest = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let srcY = frame.pointee.data.0!
        let srcYStride = frame.pointee.linesize.0

        // NOTE: This copy sits on the hot video path in software decode mode.
        // Use `memcpy` per-row (not per-pixel loops) to reduce CPU overhead for large frames.
        let yRowBytes = is10Bit ? (w * 2) : w
        for row in 0..<h {
            memcpy(
                yDest.advanced(by: row * yStride),
                srcY.advanced(by: row * Int(srcYStride)),
                min(yStride, yRowBytes)
            )
        }

        guard let uvDest = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return }
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let srcUV = frame.pointee.data.1!
        let srcUVStride = frame.pointee.linesize.1
        let uvRows = h / 2
        let uvRowBytes = is10Bit ? (w * 2) : w
        for row in 0..<uvRows {
            memcpy(
                uvDest.advanced(by: row * uvStride),
                srcUV.advanced(by: row * Int(srcUVStride)),
                min(uvStride, uvRowBytes)
            )
        }
    }

    private func attachHDRMetadata(to pb: CVPixelBuffer, frame: UnsafeMutablePointer<AVFrame>) {
        if let prim = mapColorPrimaries(frame.pointee.color_primaries) {
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, prim, .shouldPropagate)
        }
        if let transfer = mapTransfer(frame.pointee.color_trc) {
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
        }
        if let matrix = mapMatrix(
            frame.pointee.colorspace, primaries: frame.pointee.color_primaries)
        {
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        }

        let n = Int(frame.pointee.nb_side_data)
        guard let sdHead = frame.pointee.side_data else { return }
        for i in 0..<n {
            guard let sdi = sdHead[i] else { continue }
            let t = sdi.pointee.type
            if t == AV_FRAME_DATA_MASTERING_DISPLAY_METADATA, let data = sdi.pointee.data {
                applyMastering(pb, data: data, size: Int(sdi.pointee.size))
            } else if t == AV_FRAME_DATA_CONTENT_LIGHT_LEVEL, let data = sdi.pointee.data {
                applyContentLight(pb, data: data, size: Int(sdi.pointee.size))
            }
        }
    }

    private func mapColorPrimaries(_ p: AVColorPrimaries) -> CFString? {
        switch p {
        case AVCOL_PRI_BT2020: return kCVImageBufferColorPrimaries_ITU_R_2020
        case AVCOL_PRI_BT709: return kCVImageBufferColorPrimaries_ITU_R_709_2
        case AVCOL_PRI_SMPTE432: return kCVImageBufferColorPrimaries_P3_D65
        default: return kCVImageBufferColorPrimaries_ITU_R_709_2
        }
    }

    private func mapTransfer(_ t: AVColorTransferCharacteristic) -> CFString? {
        switch t {
        case AVCOL_TRC_SMPTE2084: return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case AVCOL_TRC_ARIB_STD_B67: return kCVImageBufferTransferFunction_ITU_R_2100_HLG
        case AVCOL_TRC_BT709: return kCVImageBufferTransferFunction_ITU_R_709_2
        default: return kCVImageBufferTransferFunction_ITU_R_709_2
        }
    }

    private func mapMatrix(_ sp: AVColorSpace, primaries: AVColorPrimaries) -> CFString? {
        if primaries == AVCOL_PRI_BT2020 || sp == AVCOL_SPC_BT2020_NCL || sp == AVCOL_SPC_BT2020_CL
        {
            return kCVImageBufferYCbCrMatrix_ITU_R_2020
        }
        return kCVImageBufferYCbCrMatrix_ITU_R_709_2
    }

    private func applyMastering(_ pb: CVPixelBuffer, data: UnsafePointer<UInt8>, size: Int) {
        guard size >= MemoryLayout<AVMasteringDisplayMetadata>.size else { return }
        let m = UnsafeRawPointer(data).assumingMemoryBound(to: AVMasteringDisplayMetadata.self)
            .pointee
        guard m.has_primaries != 0, m.has_luminance != 0 else { return }

        let dp = m.display_primaries
        let primaries: [[String: Double]] = [
            ["X": av_q2d(dp.0.0), "Y": av_q2d(dp.0.1)],
            ["X": av_q2d(dp.1.0), "Y": av_q2d(dp.1.1)],
            ["X": av_q2d(dp.2.0), "Y": av_q2d(dp.2.1)],
        ]
        let dict: [String: Any] = [
            "DisplayPrimaries": primaries,
            "WhitePoint": ["X": av_q2d(m.white_point.0), "Y": av_q2d(m.white_point.1)],
            "MinLuminance": av_q2d(m.min_luminance),
            "MaxLuminance": av_q2d(m.max_luminance),
        ]
        CVBufferSetAttachment(
            pb, kCVImageBufferMasteringDisplayColorVolumeKey, dict as CFDictionary, .shouldPropagate
        )
    }

    private func applyContentLight(_ pb: CVPixelBuffer, data: UnsafePointer<UInt8>, size: Int) {
        guard size >= MemoryLayout<AVContentLightMetadata>.size else { return }
        let c = UnsafeRawPointer(data).assumingMemoryBound(to: AVContentLightMetadata.self).pointee
        let dict: [String: Any] = [
            "MaxContentLightLevel": Double(c.MaxCLL),
            "MaxPicAverageLightLevel": Double(c.MaxFALL),
        ]
        CVBufferSetAttachment(
            pb, kCVImageBufferContentLightLevelInfoKey, dict as CFDictionary, .shouldPropagate)
    }

    /// Media timeline aligned to 0 s; `AVSampleBufferDisplayLayer` shows frames when `controlTimebase` catches up to these PTS values.
    private func presentationTimes(for frame: UnsafeMutablePointer<AVFrame>, timeBase: AVRational)
        -> (CMTime, CMTime)
    {
        let tb = timeBase
        let pts = frame.pointee.best_effort_timestamp
        let duration = frame.pointee.duration
        let scale: CMTimeScale = 60_000
        let minPresentationStep = 1.0 / 120_000.0
        let minDurationSeconds = 1.0 / 60_000.0

        let ptsSeconds: Double
        if pts == av_nopts_value() {
            ptsSeconds = Double(syntheticFrameIndex) * nominalFrameDuration
            syntheticFrameIndex += 1
        } else {
            ptsSeconds = Double(pts) * Double(tb.num) / Double(tb.den)
        }

        if timelineOriginSeconds == nil {
            timelineOriginSeconds = ptsSeconds
            timelineOriginLock.lock()
            syncedFirstFrameMediaSeconds = ptsSeconds
            timelineOriginLock.unlock()
        }
        var relSeconds =
            max(0, ptsSeconds - (timelineOriginSeconds ?? 0)) + presentationShiftSeconds

        if let last = lastPresentationSeconds, relSeconds <= last {
            relSeconds = last + minPresentationStep
        }
        lastPresentationSeconds = relSeconds

        let durSeconds: Double
        if duration > 0 {
            durSeconds = Double(duration) * Double(tb.num) / Double(tb.den)
        } else {
            durSeconds = nominalFrameDuration
        }
        let durClamped = max(durSeconds, minDurationSeconds)

        return (
            CMTime(seconds: relSeconds, preferredTimescale: scale),
            CMTime(seconds: durClamped, preferredTimescale: scale)
        )
    }

    private func wrapPixelBuffer(
        _ pb: CVPixelBuffer, frame: UnsafeMutablePointer<AVFrame>, timeBase: AVRational
    ) throws -> CMSampleBuffer {
        let cw = CVPixelBufferGetWidth(pb)
        let ch = CVPixelBufferGetHeight(pb)
        let cpf = CVPixelBufferGetPixelFormatType(pb)

        let formatDescription: CMVideoFormatDescription
        if let key = cachedVideoFormatKey, key.w == cw, key.h == ch, key.pf == cpf,
            let cached = cachedVideoFormatDesc
        {
            formatDescription = cached
        } else {
            var fmt: CMVideoFormatDescription?
            let cStatus = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &fmt)
            if cStatus != noErr { throw CoreVideoDecoderError.formatDescriptionFailed }
            guard let fd = fmt else { throw CoreVideoDecoderError.formatDescriptionFailed }
            cachedVideoFormatDesc = fd
            cachedVideoFormatKey = (cw, ch, cpf)
            formatDescription = fd
        }

        let (presentation, durationTime) = presentationTimes(for: frame, timeBase: timeBase)
        var timing = CMSampleTimingInfo(
            duration: durationTime,
            presentationTimeStamp: presentation,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        var status: OSStatus
        if #available(iOS 15.0, tvOS 15.0, *) {
            status = CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pb,
                formatDescription: formatDescription,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            )
        } else {
            status = CMSampleBufferCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pb,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: formatDescription,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            )
        }
        if status != noErr || sampleBuffer == nil { throw CoreVideoDecoderError.sampleBufferFailed }
        return sampleBuffer!
    }

    private func av_nopts_value() -> Int64 {
        Int64(bitPattern: UInt64(0x8000_0000_0000_0000))
    }
}
