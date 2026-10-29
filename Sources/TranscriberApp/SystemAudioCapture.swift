import AVFoundation
import Foundation
import ScreenCaptureKit

enum SystemAudioCaptureError: LocalizedError {
    case noDisplay
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            "找不到可以擷取聲音的螢幕。"
        case .permissionDenied:
            "沒有擷取系統聲音的權限。請到「系統設定 → 隱私權與安全性 → 螢幕與系統錄音」允許 Lisvo，然後重新打開 Lisvo。"
        }
    }
}

/// 擷取 Mac 正在播放的聲音（網頁、會議、任何 App），不含 Lisvo 自己的播放聲音。
/// 用 ScreenCaptureKit：macOS 要求「螢幕與系統錄音」權限。畫面只要求最小尺寸、每秒 1 張，收到後直接丟掉。
///
/// 執行緒：聲音在 `queue` 上依序送出，`onBuffer` 會在那條佇列被呼叫；`stream` 只在主執行緒的 start／stop 碰。
final class SystemAudioCapture: NSObject, LiveAudioCapture, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.archcross.lisvo.system-audio")
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private let onStop: @Sendable (Error) -> Void
    private var stream: SCStream?

    /// - Parameters:
    ///   - onBuffer: 每段聲音（擷取佇列上呼叫）。
    ///   - onStop: 系統中途停止擷取時（例如使用者在選單列關掉錄製）。
    init(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void, onStop: @escaping @Sendable (Error) -> Void) {
        self.onBuffer = onBuffer
        self.onStop = onStop
    }

    func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            // 沒有權限時，系統會跳出詢問並讓這裡失敗；使用者允許後要重開 App 才生效。
            throw SystemAudioCaptureError.permissionDenied
        }
        guard let display = content.displays.first else { throw SystemAudioCaptureError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        // 沒登記畫面輸出時，系統會一直記錄「丟棄畫面」的訊息；登記後直接忽略畫面。
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        onBuffer(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error)
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        do {
            try sampleBuffer.copyPCMData(fromRange: 0..<Int(frames), into: buffer.mutableAudioBufferList)
        } catch {
            return nil
        }
        return buffer
    }
}
