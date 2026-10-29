import AVFoundation
import Foundation
import TranscriberCore

// 命令列測試工具：跑和 App 完全相同的流程，用來驗證核心邏輯與量測速度。
// 用法：transcriber-cli <音檔> [--mode fast|accurate] [--lang zhTW|yue|en|ja|ko|auto]
//       [--speakers auto|N|off] [--polish] [--out 資料夾]
//       transcriber-cli <音檔> --live [--speed 倍速] [--lang …]   模擬即時字幕：照時間一段一段送進辨識器

struct Options {
    var input: URL
    var engine: EngineKind = .fast
    var language: TranscriptionLanguage = .zhTW
    var speakerDetection = true
    var speakerCount: Int?
    var polish = false
    var output = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/逐字稿")
    var live = false
    var speed = 1.0
}

func usage() -> Never {
    FileHandle.standardError.write(Data("用法：transcriber-cli <音檔> [--mode fast|accurate] [--lang zhTW|yue|en|ja|ko|auto] [--speakers auto|N|off] [--polish] [--out 資料夾]\n       transcriber-cli <音檔> --live [--speed 倍速] [--lang zhTW|yue|en|ja|ko]\n".utf8))
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
            guard let engine = EngineKind(rawValue: value()) else { usage() }
            options.engine = engine
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
        case "--live":
            options.live = true
        case "--speed":
            guard let speed = Double(value()), speed > 0 else { usage() }
            options.speed = speed
        default:
            usage()
        }
    }
    return options
}

let options = parse()

/// 模擬即時字幕：每 0.1 秒的聲音照時間送一次，印出暫定與定案文字，量從送出到出字的延遲。
func runLive() async throws {
    let file = try AVAudioFile(forReading: options.input)
    let format = file.processingFormat
    let chunk = AVAudioFrameCount(format.sampleRate * 0.1)
    let started = Date()
    @Sendable func stamp() -> String { String(format: "%6.2fs", Date().timeIntervalSince(started)) }
    let fed = Atomic(0.0)

    let live = try await LiveTranscriber.start(
        language: options.language,
        onStatus: { print("\(stamp()) [狀態] \($0)") },
        onEvent: { event in
            switch event {
            case .volatile(let text):
                if !text.isEmpty { print("\(stamp()) 暫定（已送 \(String(format: "%.1f", fed.value)) 秒）：\(text)") }
            case .finalized(let segment):
                print("\(stamp()) 定案 [\(Exporter.clock(segment.start))-\(Exporter.clock(segment.end))]（已送 \(String(format: "%.1f", fed.value)) 秒）：\(segment.text)")
            }
        }
    )
    while file.framePosition < file.length {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
        try file.read(into: buffer, frameCount: chunk)
        live.append(buffer)
        fed.value += Double(buffer.frameLength) / format.sampleRate
        try await Task.sleep(for: .seconds(Double(buffer.frameLength) / format.sampleRate / options.speed))
    }
    let segments = await live.finish()
    print("\(stamp()) 結束，共 \(segments.count) 句")
}

/// 給回呼讀寫的簡單計數器（只在這個測試工具用）。
final class Atomic<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

if options.live {
    do {
        try await runLive()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("失敗：\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
let settings = JobSettings(
    engine: options.engine,
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
        case .stage(let track, let text):
            print("\(elapsed()) [\(track == .speakers ? "講者" : options.engine.displayName)] \(text)")
        case .progress:
            break
        case .liveSegments(let segments):
            for segment in segments {
                print("\(elapsed())   即時 \(Exporter.clock(segment.start)) \(segment.text)")
            }
        case .transcriptReady(let transcript):
            print("\(elapsed()) [\(transcript.engine.displayName)] 完成，處理 \(String(format: "%.1f", transcript.processingSeconds)) 秒，音檔 \(String(format: "%.1f", transcript.audioDuration)) 秒")
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
