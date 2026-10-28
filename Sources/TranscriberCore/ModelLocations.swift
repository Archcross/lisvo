import Foundation

/// App 自己下載的模型都放在 `~/Library/Application Support/Lisvo/Models` 底下，
/// 不散落到各套件的預設位置（例如 FluidAudio 預設會放在 `FluidAudio/Models`）。
/// 快速模式的語言包與 AI 潤飾的模型由 macOS 管理，不在這裡。
public enum ModelLocations {
    public static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lisvo/Models", isDirectory: true)
    }

    /// 精準模式的 Whisper 模型。
    public static var whisper: URL {
        root.appendingPathComponent("Whisper", isDirectory: true)
    }

    /// 分講者模型。FluidAudio 會在底下再建一層 `speaker-diarization`。
    public static var diarization: URL {
        root.appendingPathComponent("Diarization", isDirectory: true)
    }
}
