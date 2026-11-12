import AreteMedia
import AVFoundation
import CoreImage
import os
import QuartzCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The camera for court mode: keeps the last seconds of frames (small copies) so they can be shown a
/// few seconds late, and saved as a clip.
@MainActor @Observable
final class CourtCamera {
    enum State: Equatable {
        case starting
        case running
        case unavailable(String)
    }

    private(set) var state: State = .starting
    /// How many seconds late the picture is shown (0 is live).
    var delay: Double = 5 {
        didSet { sink.keep = Self.keep(for: delay) }
    }

    /// Frames are kept this wide (16:9 at 854 × 480 is about 0.6 MB each).
    nonisolated static let frameWidth: CGFloat = 854
    /// Seconds that can be saved on top of the delay.
    static let saveSpan = 6.0

    private let session = AVCaptureSession()
    private let sink = CaptureSink(keep: CourtCamera.keep(for: 5))
    private let queue = DispatchQueue(label: "mimesis.court.camera")

    private static func keep(for delay: Double) -> Double { delay + saveSpan + 1 }

    /// 60 frames a second when the camera can at 720p, for smoother slow motion of what's saved.
    private static func preferSixty(_ device: AVCaptureDevice) {
        let candidates = device.formats.filter { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return size.width == 1280 && size.height == 720
                && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 60 }
        }
        guard let format = candidates.first, (try? device.lockForConfiguration()) != nil else { return }
        device.activeFormat = format
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 60)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 60)
        device.unlockForConfiguration()
    }

    func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            state = .unavailable("Mimesis needs the camera for Live replay: allow it in Settings › Privacy › Camera.")
            return
        }
        #if os(iOS)
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        #else
        let device = AVCaptureDevice.default(for: .video)
        #endif
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else {
            state = .unavailable("No camera found.")
            return
        }
        Self.preferSixty(device)
        session.beginConfiguration()
        // With a 60 fps format chosen, the session keeps it (inputPriority); otherwise 720p.
        if device.activeVideoMinFrameDuration == CMTime(value: 1, timescale: 60) {
            #if os(iOS)
            session.sessionPreset = .inputPriority
            #endif
            // On the Mac, leaving the preset alone keeps the device's format.
        } else {
            session.sessionPreset = .hd1280x720
        }
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(sink, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        #if os(iOS)
        // Upright as the device is held when court mode opens.
        if let connection = output.connection(with: .video) {
            let angle: CGFloat = switch UIDevice.current.orientation {
            case .landscapeLeft: 0
            case .landscapeRight: 180
            case .portraitUpsideDown: 270
            default: 90
            }
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }
        #endif
        session.commitConfiguration()
        // Started and stopped on the camera's own queue, as Apple recommends (it blocks while starting).
        nonisolated(unsafe) let session = session
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                session.startRunning()
                done.resume()
            }
        }
        state = .running
    }

    func stop() {
        nonisolated(unsafe) let session = session
        queue.async { session.stopRunning() }
        sink.clear()
    }

    /// The picture to show now: `delay` seconds late.
    func frame() -> CIImage? {
        sink.frame(delayed: delay, now: CACurrentMediaTime()).map { CIImage(cvPixelBuffer: $0) }
    }

    /// How far back the buffer reaches yet, so the screen can say "filling…" at first.
    func reach() -> Double { sink.reach(now: CACurrentMediaTime()) }

    /// Saves the last `seconds` that were shown (ending `delay` seconds ago) as a clip.
    func saveLast(_ seconds: Double = CourtCamera.saveSpan) async throws -> URL {
        let frames = Frames(entries: sink.span(seconds, endingAt: CACurrentMediaTime() - delay))
        return try await Task.detached { try await Self.write(frames.entries) }.value
    }

    // MARK: - Writing a clip

    /// Writes frames (with their capture times) as an H.264 video in Application Support/Mimesis/Clips.
    nonisolated static func write(_ entries: [DelayBuffer<CVPixelBuffer>.Entry]) async throws -> URL {
        guard let first = entries.first else { throw CocoaError(.fileNoSuchFile) }
        let width = CVPixelBufferGetWidth(first.frame), height = CVPixelBufferGetHeight(first.frame)
        let folder = ComparisonStore.supportFolder.appendingPathComponent("Clips", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: ".")
        let file = folder.appendingPathComponent("Replay \(stamp).mov")
        try? FileManager.default.removeItem(at: file)

        let writer = try AVAssetWriter(outputURL: file, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for entry in entries {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            adaptor.append(entry.frame, withPresentationTime: CMTime(seconds: entry.time - first.time, preferredTimescale: 600))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return file
    }
}

/// Frames handed to the task that writes them; nothing else touches them meanwhile.
private struct Frames: @unchecked Sendable {
    let entries: [DelayBuffer<CVPixelBuffer>.Entry]
}

/// Receives camera frames off the main thread and keeps small copies in a delay buffer.
private final class CaptureSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var buffer: DelayBuffer<CVPixelBuffer>
    private let context = CIContext()
    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero

    init(keep: Double) {
        buffer = DelayBuffer(keep: keep)
    }

    var keep: Double {
        get { lock.withLock { buffer.keep } }
        set { lock.withLock { buffer.keep = newValue } }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let source = CMSampleBufferGetImageBuffer(sample), let copy = shrunk(source) else { return }
        let time = CACurrentMediaTime()
        lock.withLockUnchecked { buffer.append(copy, at: time) }
    }

    func frame(delayed delay: Double, now: Double) -> CVPixelBuffer? {
        lock.withLockUnchecked { buffer.frame(delayed: delay, now: now) }
    }

    func span(_ seconds: Double, endingAt end: Double) -> [DelayBuffer<CVPixelBuffer>.Entry] {
        lock.withLockUnchecked { buffer.span(seconds, endingAt: end) }
    }

    func reach(now: Double) -> Double {
        lock.withLock { buffer.reach(now: now) }
    }

    func clear() {
        lock.withLock { buffer.removeAll() }
    }

    /// A copy `frameWidth` wide in our own pool (the camera's buffers must go back to it quickly).
    private func shrunk(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let image = CIImage(cvPixelBuffer: source)
        let scale = CourtCamera.frameWidth / image.extent.width
        let size = CGSize(width: (image.extent.width * scale / 2).rounded() * 2,
                          height: (image.extent.height * scale / 2).rounded() * 2)
        if pool == nil || poolSize != size {
            var made: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ] as CFDictionary, &made)
            pool = made
            poolSize = size
        }
        guard let pool else { return nil }
        var copy: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &copy)
        guard let copy else { return nil }
        context.render(image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)), to: copy)
        return copy
    }
}
