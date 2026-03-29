# FFmpeg static build (LGPL) — `libffmpeg.xcframework`

This document accompanies the artifacts produced by `scripts/build-ffmpeg-xcframework.sh` (default output directory: `output/`).

## What was built

- **Source**: local `./FFmpeg` tree only (no prebuilt third-party binaries).
- **License mode**: `--disable-gpl --disable-nonfree` so **no GPL-only or non-free FFmpeg components** are enabled. Do **not** add `--enable-gpl` or link GPL libraries (for example x264/x265) if you need to stay LGPL-compatible.
- **Libraries merged for linking**: `libavutil`, `libavcodec`, `libavformat`, `libavfilter`, `libswscale`, `libswresample` are combined into a **single** `libffmpeg.a` per platform slice (required for `xcodebuild -create-xcframework -library`).
- **Per-library `.a` copies**: Each slice in the xcframework also receives the individual static archives (same architecture / lipo’d for simulator) so you can comply with LGPL “replacement” workflows (see below).
- **Encoders / muxers**: `--disable-encoders` and `--disable-muxers` (decode / demux focused; remuxing to files is not enabled).
- **Deployment targets**: defaults `MIN_IOS=13.0`, `MIN_TVOS=13.0` (override when invoking the script).
- **Apple APIs**: VideoToolbox and AudioToolbox support are enabled for hardware-accelerated decode paths where FFmpeg exposes them.
- **Bitcode**: not enabled (Apple deprecated bitcode; the build script does not pass embed-bitcode flags).

### Codec / format notes

| Area | Notes |
|------|--------|
| **H.264 / HEVC** | Software decoders plus **VideoToolbox** hwaccels when available. |
| **HEVC Main 10 (HDR)** | Software `hevc` decoder supports 10-bit; **HDR presentation** still depends on your renderer (Metal/CoreVideo), color tags, and display pipeline. |
| **VP9 / AV1** | Native FFmpeg decoders (`vp9`, `av1`) are enabled. Optional faster AV1 via **libdav1d** is *not* included here (would require building dav1d from source and extra configure flags). |
| **AAC / AC-3 / E-AC-3 / DTS** | `aac`, `ac3`, `eac3`, `dca` decoders enabled. Some AAC variants may use **AudioToolbox** helpers when selected at runtime. |
| **Subtitles** | `ass`, `subrip`, `srt`, `webvtt` enabled (see FFmpeg docs for exact codec IDs vs. container tracks). |
| **Dolby Vision** | FFmpeg may parse **RPU side data** in bitstreams; **full Dolby Vision playback** (proprietary tone-mapping / proprietary profiles) is **not** guaranteed and often requires Apple/SoC-specific paths outside FFmpeg. |

## LGPL compliance (static linking)

LGPL requires that users of your app can **replace** FFmpeg with a modified version. With **static** linking, that usually means:

1. **Providing** this README, the **LICENSE** files under `output/LICENSE/`, and access to the **corresponding FFmpeg source** (same version as built).
2. **Allowing relinking**: ship **object files** (`.o`) or **individual static libraries** (`.a`) for your app *excluding* FFmpeg, **or** provide a documented way to rebuild your binary against a replaced FFmpeg. The per-slice `libav*.a` files are included to support toolchain-level replacement workflows.
3. **No extra restrictions** in your license terms that block exercising these rights.

This is **not** legal advice; have counsel review distribution for your product.

## Rebuilding / replacing FFmpeg

1. Check out the **same FFmpeg revision** you shipped (or document the Git SHA).
2. Run from the repo root:

   ```bash
   ./scripts/build-ffmpeg-xcframework.sh
   ```

3. Optional environment variables:

   | Variable | Meaning |
   |----------|---------|
   | `FFMPEG_SRC` | Path to FFmpeg sources (default `./FFmpeg`). |
   | `MIN_IOS` / `MIN_TVOS` | Deployment targets (default `15.0`). |
   | `SKIP_SIM_X86=1` | Skip Intel simulator slices (arm64 simulator only). |
   | `FFMPEG_EXTRA_CONFIGURE` | Extra `./configure` arguments (advanced). |
   | `JOBS` | Parallel `make` jobs. |

4. Replace `output/libffmpeg.xcframework` in your Xcode project and **clean build**.

## Xcode integration

1. Drag `output/libffmpeg.xcframework` into the project (or add via **General → Frameworks**).
2. For **static** xcframeworks: set **Embed** to **Do Not Embed**.
3. Add **Header Search Paths** to the xcframework headers if needed (Xcode often resolves this automatically when linking the xcframework).
4. For Swift, add a **bridging header** that includes `libffmpeg-umbrella.h` from the xcframework’s Headers directory (or include only the FFmpeg headers you need).
5. Merge **Other Linker Flags** from `output/xcode-link-flags.xcconfig` (zlib, bz2, iconv, AudioToolbox, CoreMedia, CoreVideo, VideoToolbox, QuartzCore, `-ObjC`).

### Alignment with `CoreVideoDecoder` / `CoreAudioDecoder`

Use **VideoToolbox** / **AudioToolbox** / **AVAudioEngine** for system-optimized paths where appropriate; use **FFmpeg** (`libavcodec` / `libavformat`) for demuxing, software decode, or formats not covered by Apple APIs. A typical split: FFmpeg parses packets and decodes to raw frames/PCM when needed; Core Video / Metal presents video frames; AVAudioEngine or AudioUnit plays PCM.

## Folder layout (after a successful run)

```
output/
  libffmpeg.xcframework/    # iOS device, iOS sim, tvOS device, tvOS sim slices
  ffmpeg-headers/         # Staged copy + libffmpeg-umbrella.h (reference)
  LICENSE/                  # COPYING.LGPLv2.1, COPYING.LGPLv3, LICENSE.md
  README_LGPL.md            # This file (copied here by the script)
  xcode-link-flags.xcconfig
  build/                    # Intermediate installs (large; safe to delete after success)
```

## Limitations

- **No GPL components** by design — features that require `--enable-gpl` are absent.
- **No bundled libdav1d / libvpx / etc.** — optional external decoders were not linked; only what this `./configure` enables is present.
- **Patents / licensing for codecs** (e.g. MPEG-LA, Dolby, DTS) are **separate** from LGPL and may require royalties or agreements for your use case.
- **Simulator x86_64** builds may require a suitable Xcode toolchain; on some Apple Silicon setups, skipping them with `SKIP_SIM_X86=1` is acceptable if you only test on arm64 simulators.
