import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

// MARK: - Preset

enum SpacePreset: String, CaseIterable, Identifiable {
    case identical = "Looks identical"
    case great     = "Great"
    case small     = "Small"

    var id: String { rawValue }

    var quality: Float {
        switch self {
        case .identical: return 0.90
        case .great:     return 0.75
        case .small:     return 0.60
        }
    }

    var detail: String {
        switch self {
        case .identical: return "Highest quality HEVC. Very hard to tell from the original. Saves roughly 50–65%."
        case .great:     return "High quality HEVC. Looks great on any screen. Saves roughly 60–75%."
        case .small:     return "Good quality, smaller file. Great for archiving clips you watch rarely. Saves roughly 70–80%."
        }
    }

    var estimatedSavings: Double {
        switch self {
        case .identical: return 0.57
        case .great:     return 0.67
        case .small:     return 0.75
        }
    }
}

// MARK: - Errors

enum SpaceError: LocalizedError {
    case noVideoTrack
    case readerFailed(Error?)
    case writerFailed(Error?)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:            return "The clip has no video track."
        case .readerFailed(let e):     return "Could not read the clip: \(e?.localizedDescription ?? "unknown error")"
        case .writerFailed(let e):     return "Could not write the output: \(e?.localizedDescription ?? "unknown error")"
        case .verificationFailed(let m): return "Verification failed: \(m)"
        }
    }
}

// MARK: - Encoder

enum SpaceSaver {

    static func outputURL(for clip: ClipRow) -> URL {
        let u = URL(fileURLWithPath: clip.path)
        let dir = u.deletingLastPathComponent()
        let stem = u.deletingPathExtension().lastPathComponent
        var n = 1
        func name(_ n: Int) -> String { n == 1 ? "\(stem)_hevc.mp4" : "\(stem)_hevc_\(n).mp4" }
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name(n)).path) { n += 1 }
        return dir.appendingPathComponent(name(n))
    }

    static func sampleOutputURL(for clip: ClipRow) -> URL {
        let u = URL(fileURLWithPath: clip.path)
        let dir = u.deletingLastPathComponent()
        let stem = u.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent(".\(stem)_hevc_sample.mp4")
    }

    /// Encodes the clip (or a leading sample of `sampleDuration` seconds) to HEVC at the given preset.
    static func encode(
        clip: ClipRow,
        preset: SpacePreset,
        shrinkTo1080p: Bool,
        outputURL: URL,
        sampleDuration: Double? = nil,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: outputURL)

        let asset = AVURLAsset(url: clip.url)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { throw SpaceError.noVideoTrack }

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else { throw SpaceError.noVideoTrack }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        let (naturalSize, preferredTransform, fps) = try await videoTrack.load(
            .naturalSize, .preferredTransform, .nominalFrameRate
        )

        // Display dimensions (rotation-corrected)
        let rotated = abs(preferredTransform.b) > 0.5
        var origW = Int(rotated ? naturalSize.height : naturalSize.width)
        var origH = Int(rotated ? naturalSize.width : naturalSize.height)

        var w = origW, h = origH
        if shrinkTo1080p && max(origW, origH) > 1920 {
            let scale = 1920.0 / Double(max(origW, origH))
            w = max(2, (Int(Double(origW) * scale) / 2) * 2)
            h = max(2, (Int(Double(origH) * scale) / 2) * 2)
        }

        let encodeDuration = sampleDuration.map { min($0, duration) } ?? duration

        // Build video composition that applies rotation + optional scale
        let comp = AVMutableVideoComposition()
        comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(fps.rounded(), 1)))
        comp.renderSize = CGSize(width: w, height: h)

        let instr = AVMutableVideoCompositionInstruction()
        instr.timeRange = CMTimeRange(start: .zero, end: CMTime(seconds: duration + 10, preferredTimescale: 600))
        let li = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        var xform = preferredTransform
        if origW != w || origH != h {
            let sx = CGFloat(w) / CGFloat(origW), sy = CGFloat(h) / CGFloat(origH)
            xform = xform.concatenating(CGAffineTransform(scaleX: sx, y: sy))
        }
        li.setTransform(xform, at: .zero)
        instr.layerInstructions = [li]
        comp.instructions = [instr]

        // Reader
        let reader = try AVAssetReader(asset: asset)
        if let sd = sampleDuration {
            reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: min(sd, duration), preferredTimescale: 600))
        }

        let videoOut = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        videoOut.videoComposition = comp
        reader.add(videoOut)

        var audioOut: AVAssetReaderAudioMixOutput? = nil
        if !audioTracks.isEmpty {
            let ao = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: NSNumber(value: kAudioFormatLinearPCM)
            ])
            reader.add(ao)
            audioOut = ao
        }

        // Writer
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let compressionProps: [String: Any] = [
            AVVideoQualityKey: NSNumber(value: preset.quality),
            AVVideoMaxKeyFrameIntervalDurationKey: NSNumber(value: 2.0)
        ]
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: NSNumber(value: w),
            AVVideoHeightKey: NSNumber(value: h),
            AVVideoCompressionPropertiesKey: compressionProps
        ])
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)

        var audioIn: AVAssetWriterInput? = nil
        if audioOut != nil {
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: NSNumber(value: kAudioFormatMPEG4AAC),
                AVSampleRateKey: NSNumber(value: 48000.0),
                AVNumberOfChannelsKey: NSNumber(value: 2),
                AVEncoderBitRateKey: NSNumber(value: 192000)
            ])
            ai.expectsMediaDataInRealTime = false
            writer.add(ai)
            audioIn = ai
        }

        guard reader.startReading() else { throw SpaceError.readerFailed(reader.error) }
        guard writer.startWriting() else { throw SpaceError.writerFailed(writer.error) }
        writer.startSession(atSourceTime: .zero)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await pumpTrack(input: videoIn, output: videoOut) { pts in
                    onProgress(min(pts / max(encodeDuration, 0.001), 0.99))
                }
            }
            if let ai = audioIn, let ao = audioOut {
                group.addTask { try await pumpTrack(input: ai, output: ao, onProgress: nil) }
            }
            try await group.waitForAll()
        }

        await writer.finishWriting()
        guard writer.status != .failed else { throw SpaceError.writerFailed(writer.error) }

        if let creationDate = (try? FileManager.default.attributesOfItem(atPath: clip.path))?[.creationDate] as? Date {
            try? FileManager.default.setAttributes([.creationDate: creationDate], ofItemAtPath: outputURL.path)
        }

        onProgress(1.0)
    }

    private static func pumpTrack(
        input: AVAssetWriterInput,
        output: AVAssetReaderOutput,
        onProgress: ((Double) -> Void)?
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "spacesaver.\(input.mediaType.rawValue)", qos: .userInitiated)) {
                while input.isReadyForMoreMediaData {
                    guard let buf = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        cont.resume()
                        return
                    }
                    let pts = CMSampleBufferGetPresentationTimeStamp(buf).seconds
                    if pts.isFinite { onProgress?(pts) }
                    input.append(buf)
                }
            }
        }
    }

    // MARK: - Verification

    struct VerifyResult {
        var ok: Bool
        var checks: [String]
        var outputSize: Int64
    }

    static func verify(original: ClipRow, outputURL: URL) async -> VerifyResult {
        var checks: [String] = []
        var ok = true

        let origAsset = AVURLAsset(url: URL(fileURLWithPath: original.path))
        let outAsset  = AVURLAsset(url: outputURL)

        // Duration
        guard let origDur = try? await origAsset.load(.duration).seconds,
              let outDur  = try? await outAsset.load(.duration).seconds else {
            checks.append("FAIL Could not load durations")
            return VerifyResult(ok: false, checks: checks, outputSize: 0)
        }
        let durDiff = abs(origDur - outDur)
        if durDiff > 0.5 {
            checks.append("FAIL Duration: original \(String(format: "%.2f", origDur))s, output \(String(format: "%.2f", outDur))s")
            ok = false
        } else {
            checks.append("OK   Duration: \(String(format: "%.2f", outDur))s (diff \(String(format: "%.3f", durDiff))s)")
        }

        // Tracks
        let origTracks = try? await origAsset.load(.tracks)
        let outTracks  = try? await outAsset.load(.tracks)
        let outVideoCount = outTracks?.filter { $0.mediaType == .video }.count ?? 0
        let origAudioCount = origTracks?.filter { $0.mediaType == .audio }.count ?? 0
        let outAudioCount  = outTracks?.filter  { $0.mediaType == .audio }.count ?? 0
        if outVideoCount != 1 {
            checks.append("FAIL Video tracks: expected 1, got \(outVideoCount)"); ok = false
        } else {
            checks.append("OK   Video tracks: 1")
        }
        if origAudioCount > 0 && outAudioCount == 0 {
            checks.append("FAIL Audio tracks: original had \(origAudioCount), output has 0"); ok = false
        } else if origAudioCount > 0 {
            checks.append("OK   Audio tracks: \(outAudioCount)")
        }

        // Size sanity (must be at least 5% of original)
        let outSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path))?[.size] as? Int64 ?? 0
        if outSize < original.size / 20 {
            checks.append("FAIL Output is suspiciously small: \(formatSize(outSize))"); ok = false
        } else {
            let pct = Int((1.0 - Double(outSize) / Double(original.size)) * 100)
            checks.append("OK   Size: \(formatSize(outSize)) (\(pct)% smaller than original)")
        }

        // Frame decode
        let gen = AVAssetImageGenerator(asset: outAsset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 320, height: 320)
        if let _ = try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image {
            checks.append("OK   First frame decoded")
        } else {
            checks.append("FAIL Could not decode first frame"); ok = false
        }
        if outDur > 2, let _ = try? await gen.image(at: CMTime(seconds: outDur - 0.5, preferredTimescale: 600)).image {
            checks.append("OK   Last frame decoded")
        } else if outDur > 2 {
            checks.append("FAIL Could not decode last frame"); ok = false
        }

        checks.append(ok ? "ALL CHECKS PASSED" : "SOME CHECKS FAILED")
        return VerifyResult(ok: ok, checks: checks, outputSize: outSize)
    }
}
