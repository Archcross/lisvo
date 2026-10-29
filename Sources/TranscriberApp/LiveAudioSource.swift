import AVFoundation
import Foundation

/// 即時字幕的聲音來源：開始後把聲音一段一段交給 onBuffer，停止後不再送。
/// 同一個來源送出的聲音必須依序、不重疊（LiveTranscriber 的轉檔器假設同一時間只有一個呼叫）。
protocol LiveAudioCapture: AnyObject, Sendable {
    func start() async throws
    func stop() async
}

/// 即時字幕要聽哪裡的聲音。
enum LiveAudioSource: String, CaseIterable, Identifiable {
    /// Mac 正在播放的聲音（網頁、會議、任何 App）。
    case system
    /// 麥克風收到的聲音（現場演講、面對面談話）。
    case microphone

    var id: String { rawValue }

    /// 選單、主視窗與逐字稿裡的來源名稱。
    var label: String {
        switch self {
        case .system: "電腦聲音"
        case .microphone: "麥克風"
        }
    }

    var symbol: String {
        switch self {
        case .system: "speaker.wave.2"
        case .microphone: "mic"
        }
    }

    var help: String {
        switch self {
        case .system: "把 Mac 正在播放的聲音（網頁、會議、任何 App）即時轉成字幕，顯示在浮動視窗。不分講者、不潤飾。"
        case .microphone: "把麥克風收到的聲音（現場演講、面對面談話）即時轉成字幕，顯示在浮動視窗。用「系統設定 → 聲音 → 輸入」選的麥克風。"
        }
    }

    func makeCapture(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onStop: @escaping @Sendable (Error) -> Void
    ) -> any LiveAudioCapture {
        switch self {
        case .system: SystemAudioCapture(onBuffer: onBuffer, onStop: onStop)
        case .microphone: MicrophoneCapture(onBuffer: onBuffer, onStop: onStop)
        }
    }
}
