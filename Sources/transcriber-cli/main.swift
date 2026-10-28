import Foundation
import TranscriberCore

// 命令列測試工具：跑和 App 完全相同的流程，用來驗證核心邏輯與量測速度。
// 用法：transcriber-cli <音檔> [--mode fast|accurate|both] [--lang zhTW|yue|en|ja|ko|auto]
//       [--speakers auto|N|off] [--polish] [--out 資料夾]

struct Options {
    var input: URL
    var engines: [EngineKind] = [.fast]
    var language: TranscriptionLanguage = .zhTW
    var speakerDetection = true
    var speakerCount: Int?
    var polish = false
    var output = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/逐字稿")
}

func usage() -> Never {
    FileHandle.standardError.write(Data("用法：transcriber-cli <音檔> [--mode fast|accurate|both] [--lang zhTW|yue|en|ja|ko|auto] [--speakers auto|N|off] [--polish] [--out 資料夾]\n".utf8))
    exit(2)
}

func parse() -> Options {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard let first = arguments.first, !first.hasPrefix("--") else { usage() }
    arguments.removeFirst()
    var options = Options(input: URL(fileURLWithPath: first))

    while !arguments.isEmpty {
        let flag = arguments.removeFirst()
        func value() -> String {
            guard !arguments.isEmpty else { usage() }
            return arguments.removeFirst()
        }
        switch flag {
        case "--mode":
            switch value() {
            case "fast": options.engines = [.fast]
            case "accurate": options.engines = [.accurate]
            case "both": options.engines = [.fast, .accurate]
            default: usage()
            }
        case "--lang":
            guard let language = TranscriptionLanguage(rawValue: value()) else { usage() }
            options.language = language
        case "--speakers":
            let raw = value()
            switch raw {
            case "off": options.speakerDetection = false
            case "auto": options.speakerCount = nil
            default:
                guard let count = Int(raw), count > 0 else { usage() }
                options.speakerCount = count
            }
        case "--polish":
            options.polish = true
        case "--out":
            options.output = URL(fileURLWithPath: value(), isDirectory: true)
        default:
            usage()
        }
    }
    return options
}

let options = parse()
let settings = JobSettings(
    engines: options.engines,
    language: options.language,
    speakerDetection: options.speakerDetection,
    speakerCount: options.speakerCount,
    polish: options.polish,
    outputDirectory: options.output
)

let started = Date()
func elapsed() -> String { String(format: "%6.1fs", Date().timeIntervalSince(started)) }

do {
    let result = try await TranscriptionPipeline.run(input: options.input, settings: settings) { event in
        switch event {
        case .stage(let engine, let text):
            print("\(elapsed()) [\(engine?.displayName ?? "共用")] \(text)")
        case .progress:
            break
        case .liveSegments(let engine, let segments):
            for segment in segments {
                print("\(elapsed())   即時[\(engine.displayName)] \(Exporter.clock(segment.start)) \(segment.text)")
            }
        case .transcriptReady(let engine, let transcript):
            print("\(elapsed()) [\(engine.displayName)] 完成，處理 \(String(format: "%.1f", transcript.processingSeconds)) 秒，音檔 \(String(format: "%.1f", transcript.audioDuration)) 秒")
            for segment in transcript.segments {
                print(String(format: "  [%6.2f-%6.2f] ", segment.start, segment.end) + "\(segment.speaker ?? "-")：\(segment.text)")
            }
            for paragraph in transcript.polished ?? [] {
                print("  潤飾\(paragraph.didPolish ? "" : "（保留原文）")：\(paragraph.speaker ?? "-")：\(paragraph.polished)")
            }
        case .notice(let text):
            print("\(elapsed()) 注意：\(text)")
        }
    }
    print("輸出資料夾：\(result.outputFolder.path)")
    result.files.forEach { print("  \($0.lastPathComponent)") }
} catch {
    FileHandle.standardError.write(Data("失敗：\(error.localizedDescription)\n".utf8))
    exit(1)
}
