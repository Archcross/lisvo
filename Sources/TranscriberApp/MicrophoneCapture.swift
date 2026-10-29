import AVFoundation
import Foundation

enum MicrophoneCaptureError: LocalizedError {
    case permissionDenied
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "沒有使用麥克風的權限。請到「系統設定 → 隱私權與安全性 → 麥克風」允許 Lisvo。"
        case .noInputDevice:
            "找不到麥克風。請接上麥克風，或到「系統設定 → 聲音 → 輸入」選一個輸入裝置。"
        }
    }
}

/// 擷取麥克風的聲音，用「系統設定 → 聲音 → 輸入」目前選的裝置。
///
/// 執行緒：`engine` 只在 `control` 佇列上操作（開始、停止、換裝置後重接），彼此不會同時進行；
/// 聲音由 AVAudioEngine 的擷取執行緒依序送出，`onBuffer` 在那條執行緒被呼叫。所以標成 @unchecked Sendable。
final class MicrophoneCapture: LiveAudioCapture, @unchecked Sendable {
    private let control = DispatchQueue(label: "com.archcross.lisvo.microphone")
    private let engine = AVAudioEngine()
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private let onStop: @Sendable (Error) -> Void
    private var configurationObserver: NSObjectProtocol?
    private var isCapturing = false

    /// - Parameters:
    ///   - onBuffer: 每段聲音（擷取執行緒上呼叫）。
    ///   - onStop: 換了輸入裝置後接不回去時。
    init(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void, onStop: @escaping @Sendable (Error) -> Void) {
        self.onBuffer = onBuffer
        self.onStop = onStop
    }

    func start() async throws {
        try await Self.ensureAuthorized()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            control.async {
                do {
                    try self.startEngine()
                    self.observeConfigurationChanges()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            control.async {
                if let observer = self.configurationObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self.configurationObserver = nil
                }
                self.stopEngine()
                continuation.resume()
            }
        }
    }

    /// 第一次使用時跳出系統的麥克風授權詢問；使用者拒絕過就直接告訴他去哪裡打開。
    private static func ensureAuthorized() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw MicrophoneCaptureError.permissionDenied }
        default:
            throw MicrophoneCaptureError.permissionDenied
        }
    }

    /// 在 `control` 佇列上呼叫。
    private func startEngine() throws {
        let input = engine.inputNode
        // 沒有任何輸入裝置時，格式的取樣率和聲道數是 0。
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicrophoneCaptureError.noInputDevice }

        let onBuffer = self.onBuffer
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            // 系統沒有保證回呼結束後這塊緩衝區不會被重複使用，複製一份再交出去。
            guard let copy = Self.copy(buffer) else { return }
            onBuffer(copy)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isCapturing = true
    }

    /// 在 `control` 佇列上呼叫。
    private func stopEngine() {
        guard isCapturing else { return }
        isCapturing = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// 接上或拔掉耳機、換了輸入裝置時，系統會停掉 engine 並發出通知；用新裝置的格式重新接上。
    /// 重接的空檔（通常不到一秒）沒有聲音送出，之後的字幕時間會比實際早這麼一點。
    private func observeConfigurationChanges() {
        guard configurationObserver == nil else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.control.async { self.restartAfterConfigurationChange() }
        }
    }

    /// 在 `control` 佇列上呼叫。
    private func restartAfterConfigurationChange() {
        // 已經停止（使用者按了停止）就不重接。
        guard isCapturing else { return }
        stopEngine()
        do {
            try startEngine()
        } catch {
            onStop(error)
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for (from, to) in zip(source, destination) {
            guard let fromData = from.mData, let toData = to.mData else { return nil }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }
}
