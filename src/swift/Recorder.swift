import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

let outputPath: String
if CommandLine.arguments.count > 1 {
    outputPath = CommandLine.arguments[1]
} else {
    let fileName = "output_\(Int(Date().timeIntervalSince1970)).mov"
    outputPath = FileManager.default.currentDirectoryPath + "/" + fileName
}

struct Config: Codable {
    let fps: Int
    let showCursor: Bool
    let displayId: CGDirectDisplayID
}

func main() {

    let service = ScreenRecorderService()
    let defaultConfig = Config(fps: 30, showCursor: true, displayId: CGMainDisplayID())
    let jsonEncoder = JSONEncoder()
    let defaultConfigJSON: String
    do {
        defaultConfigJSON =
            String(data: try jsonEncoder.encode(defaultConfig), encoding: .utf8) ?? ""
    } catch {
        print("Failed to create default configuration: \(error)")
        return
    }
    service.startRecording(configJSON: defaultConfigJSON)
    print("Recording started. Type 'stop' and press Enter to stop recording.")
    while let input = readLine()?.lowercased() {
        if input == "stop" {
            service.stopRecording()
            break
        } else {
            print("Unknown command. Type 'stop' to end recording.")
        }
    }
    service.waitForCompletion()
}

main()

class ScreenRecorder: NSObject, SCStreamOutput {
    private let videoSampleBufferQueue = DispatchQueue(
        label: "ScreenRecorder.VideoSampleBufferQueue")
    private let audioSampleBufferQueue = DispatchQueue(
        label: "ScreenRecorder.AudioSampleBufferQueue")
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var stream: SCStream?

    private var sessionStarted = false
    private var sessionStartTime: CMTime = .zero
    private var firstVideoSampleTime: CMTime = .zero
    private var firstAudioSampleTime: CMTime = .zero
    private var lastVideoSampleBuffer: CMSampleBuffer?
    private var lastAudioSampleBuffer: CMSampleBuffer?
    private var videoTimeOffset: CMTime = .zero
    private var audioTimeOffset: CMTime = .zero

    private var config: Config?
    private var outputURL: URL?
    private var frameCount: Int = 0
    private var audioSampleCount: Int = 0
    private var isRecording = false
    private var recordingStartTime: Date?
    private var recordingEndTime: Date?

    func startCapture(configJSON: String) async throws {
        guard !isRecording else {
            print("Recording is already in progress")
            return
        }

        guard let jsonData = configJSON.data(using: .utf8) else {
            throw NSError(
                domain: "ScreenCapture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid JSON"])
        }

        config = try JSONDecoder().decode(Config.self, from: jsonData)

        let availableContent = try await SCShareableContent.current
        print(
            "Available displays: \(availableContent.displays.map { "\($0.displayID)" }.joined(separator: ", "))"
        )

        guard
            let display = availableContent.displays.first(where: {
                $0.displayID == config?.displayId ?? CGMainDisplayID()
            })
        else {
            throw NSError(
                domain: "ScreenCapture", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Display not found"])
        }

        // Get display size and scale factor
        let displayBounds = CGDisplayBounds(display.displayID)
        let displaySize = displayBounds.size
        let displayScaleFactor: Int
        if let mode = CGDisplayCopyDisplayMode(display.displayID) {
            displayScaleFactor = mode.pixelWidth / mode.width
        } else {
            displayScaleFactor = 1
        }

        // Calculate video size (downsized if necessary)
        let videoSize = ScreenRecorder.downsizedVideoSize(
            source: displaySize, scaleFactor: displayScaleFactor)

        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = videoSize.width
        streamConfiguration.height = videoSize.height
        streamConfiguration.minimumFrameInterval = CMTime(
            value: 1, timescale: CMTimeScale(config?.fps ?? 60))
        streamConfiguration.queueDepth = 6
        streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfiguration.showsCursor = config?.showCursor ?? false

        // Enhanced audio configuration
        streamConfiguration.capturesAudio = true
        streamConfiguration.sampleRate = 44100
        streamConfiguration.channelCount = 2

        print("Display dimensions: \(videoSize.width)x\(videoSize.height)")
        print("FPS: \(config?.fps ?? 60)")
        print("Show cursor: \(config?.showCursor ?? false)")
        print("Audio sample rate: 44100 Hz")
        print("Audio channels: 2 (stereo)")

        // Create content filter for system audio capture
        let filter = SCContentFilter(display: display, excludingWindows: [])
        print("System audio capture is enabled.")

        stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: nil)

        // Use the outputPath determined above
        outputURL = URL(fileURLWithPath: outputPath)
        print("Output URL: \(outputURL?.path ?? "Unknown")")

        // Create AVAssetWriter for a QuickTime movie file
        guard let outputURL = outputURL else {
            throw NSError(
                domain: "ScreenCapture", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Invalid output URL"])
        }
        assetWriter = try AVAssetWriter(url: outputURL, fileType: .mov)

        // Setup video encoding settings for QuickTime compatibility
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoSize.width,
            AVVideoHeightKey: videoSize.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoSize.width * videoSize.height * 8,  // 8 bits per pixel
                AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCAVLC,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]

        // Create AVAssetWriter input for video
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput?.expectsMediaDataInRealTime = true

        // Enhanced audio output settings
        let audioOutputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 44100.0,
            AVEncoderBitRateKey: 128000,
        ]
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutputSettings)
        audioInput?.expectsMediaDataInRealTime = true

        guard let assetWriter = assetWriter, let videoInput = videoInput,
            let audioInput = audioInput,
            assetWriter.canAdd(videoInput), assetWriter.canAdd(audioInput)
        else {
            throw NSError(
                domain: "ScreenCapture", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Can't add input to asset writer"])
        }
        assetWriter.add(videoInput)
        assetWriter.add(audioInput)

        try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoSampleBufferQueue)
        try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioSampleBufferQueue)
        try await stream?.startCapture()

        guard assetWriter.startWriting() else {
            throw NSError(
                domain: "ScreenCapture", code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't start writing to AVAssetWriter"])
        }

        // Don't start session immediately - wait for first sample
        isRecording = true
        frameCount = 0
        audioSampleCount = 0
        firstVideoSampleTime = .zero
        firstAudioSampleTime = .zero
        sessionStartTime = .zero
        videoTimeOffset = .zero
        audioTimeOffset = .zero
        recordingStartTime = Date()

        print("Capture started.")
    }

    func stopCapture() async throws -> String {
        guard isRecording else {
            print("No recording in progress")
            return ""
        }

        isRecording = false
        recordingEndTime = Date()

        try await stream?.stopCapture()
        stream = nil

        // Wait a bit to ensure all samples are processed
        try await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        // Calculate the final timestamp properly
        let finalTimestamp = CMTimeMaximum(videoTimeOffset, audioTimeOffset)

        print("Final video timestamp: \(videoTimeOffset.seconds)")
        print("Final audio timestamp: \(audioTimeOffset.seconds)")
        print("Final session timestamp: \(finalTimestamp.seconds)")

        // End session with the maximum timestamp to ensure proper duration
        if sessionStarted {
            assetWriter?.endSession(atSourceTime: finalTimestamp)
        }

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        // Wait for the writer to finish
        await assetWriter?.finishWriting()

        // Check if writing was successful
        if let writer = assetWriter {
            if writer.status == .failed {
                print(
                    "AssetWriter failed with error: \(writer.error?.localizedDescription ?? "Unknown error")"
                )
            } else {
                print("AssetWriter status: \(writer.status.rawValue)")
            }
        }

        let outputPath = outputURL?.path ?? "Unknown"
        let duration: Double = {
            if let start = recordingStartTime, let end = recordingEndTime {
                return end.timeIntervalSince(start)
            } else {
                return 0.0
            }
        }()

        let result: [String: Any] = [
            "outputPath": outputPath,
            "duration": duration,
            "videoFrames": frameCount,
            "audioSamples": audioSampleCount,
            "finalTimestamp": finalTimestamp.seconds,
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: result, options: []),
            let jsonString = String(data: jsonData, encoding: .utf8)
        {
            print(jsonString)
        }

        print("Recording saved to: \(outputPath)")
        print("Total video frames captured: \(frameCount)")
        print("Total audio samples captured: \(audioSampleCount)")
        print("Recording duration: \(String(format: "%.2f", duration)) seconds")
        print("Video duration should be: \(String(format: "%.2f", finalTimestamp.seconds)) seconds")

        // Reset for next recording
        assetWriter = nil
        videoInput = nil
        audioInput = nil
        sessionStarted = false

        return outputPath
    }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid, isRecording else { return }

        switch type {
        case .screen:
            handleVideoSample(sampleBuffer)
        case .audio:
            handleAudioSample(sampleBuffer)
        default:
            break
        }
    }

    private func handleVideoSample(_ sampleBuffer: CMSampleBuffer) {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let attachment = attachments.first,
            let statusRawValue = attachment[SCStreamFrameInfo.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRawValue),
            status == .complete
        else { return }

        guard let videoInput = videoInput, videoInput.isReadyForMoreMediaData else {
            print("Video input not ready, dropping frame")
            return
        }

        // Initialize session and timing on first sample
        if !sessionStarted {
            sessionStartTime = sampleBuffer.presentationTimeStamp
            firstVideoSampleTime = sampleBuffer.presentationTimeStamp
            assetWriter?.startSession(atSourceTime: .zero)  // Always start at zero
            sessionStarted = true
            videoTimeOffset = .zero
            print("Video session started")
        }

        // Calculate frame duration based on configured FPS
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(config?.fps ?? 30))

        // Use frame count to calculate consistent timestamps
        videoTimeOffset = CMTimeMultiply(frameDuration, multiplier: Int32(frameCount))
        lastVideoSampleBuffer = sampleBuffer

        // Create new sample buffer with sequential timing
        let timing = CMSampleTimingInfo(
            duration: frameDuration,
            presentationTimeStamp: videoTimeOffset,
            decodeTimeStamp: .invalid
        )

        if let retimedSampleBuffer = try? CMSampleBuffer(
            copying: sampleBuffer, withNewTiming: [timing])
        {
            videoInput.append(retimedSampleBuffer)
            frameCount += 1
            if frameCount % 60 == 0 {
                print("Video frames captured: \(frameCount), timestamp: \(videoTimeOffset.seconds)")
            }
        } else {
            print("Couldn't create retimed video sample buffer, dropping frame")
        }
    }

    private func handleAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard let audioInput = audioInput, audioInput.isReadyForMoreMediaData else {
            print("Audio input not ready, dropping sample")
            return
        }

        // Initialize audio timing based on session start
        if sessionStartTime == .zero {
            // If no video samples yet, use audio to start session
            sessionStartTime = sampleBuffer.presentationTimeStamp
            firstAudioSampleTime = sampleBuffer.presentationTimeStamp
            assetWriter?.startSession(atSourceTime: .zero)  // Always start at zero
            sessionStarted = true
            audioTimeOffset = .zero
            print("Audio session started")
        } else if firstAudioSampleTime == .zero {
            firstAudioSampleTime = sampleBuffer.presentationTimeStamp
        }

        // Calculate audio timestamp based on sample count and sample rate
        let sampleRate: Int32 = 44100
        let samplesPerBuffer = CMSampleBufferGetNumSamples(sampleBuffer)

        // Update audio time offset
        audioTimeOffset = CMTime(
            value: Int64(audioSampleCount * samplesPerBuffer), timescale: sampleRate)
        lastAudioSampleBuffer = sampleBuffer

        // Create new sample buffer with calculated timing
        let timing = CMSampleTimingInfo(
            duration: sampleBuffer.duration,
            presentationTimeStamp: audioTimeOffset,
            decodeTimeStamp: .invalid
        )

        if let retimedSampleBuffer = try? CMSampleBuffer(
            copying: sampleBuffer, withNewTiming: [timing])
        {
            audioInput.append(retimedSampleBuffer)
            audioSampleCount += 1
            if audioSampleCount % 1000 == 0 {
                print(
                    "Audio samples captured: \(audioSampleCount), timestamp: \(audioTimeOffset.seconds)"
                )
            }
        } else {
            print("Couldn't create retimed audio sample buffer, dropping sample")
        }
    }

    private static func downsizedVideoSize(source: CGSize, scaleFactor: Int) -> (
        width: Int, height: Int
    ) {
        let maxSize = CGSize(width: 4096, height: 2304)
        let w = source.width * Double(scaleFactor)
        let h = source.height * Double(scaleFactor)
        let r = max(w / maxSize.width, h / maxSize.height)
        return r > 1
            ? (width: Int(w / r), height: Int(h / r))
            : (width: Int(w), height: Int(h))
    }
}

class ScreenRecorderService {
    private let recorder = ScreenRecorder()
    private let commandQueue = DispatchQueue(label: "com.screenrecorder.commandQueue")
    private let completionGroup = DispatchGroup()

    func startRecording(configJSON: String) {
        completionGroup.enter()
        commandQueue.async {
            Task {
                do {
                    try await self.recorder.startCapture(configJSON: configJSON)
                } catch {
                    print("Error starting capture: \(error)")
                    self.completionGroup.leave()
                }
            }
        }
    }

    func stopRecording() {
        commandQueue.async {
            Task {
                do {
                    let outputPath = try await self.recorder.stopCapture()
                    print("Recording stopped. Output path: \(outputPath)")
                    self.completionGroup.leave()
                } catch {
                    print("Error stopping capture: \(error)")
                    self.completionGroup.leave()
                }
            }
        }
    }

    func waitForCompletion() {
        completionGroup.wait()
    }
}
