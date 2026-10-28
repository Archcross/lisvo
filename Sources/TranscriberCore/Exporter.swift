import Foundation

/// 把逐字稿寫成各種檔案。格式對齊 aTrain 的輸出，另外加上 VTT 與潤飾版。
public enum Exporter {
    public static func write(_ transcript: Transcript, baseName name: String, to folder: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var outputs: [(String, String)] = [
            ("\(name).txt", plainText(transcript)),
            ("\(name)_時間軸.txt", timestampedText(transcript)),
            ("\(name)_maxqda.txt", maxqdaText(transcript)),
            ("\(name).srt", srt(transcript)),
            ("\(name).vtt", vtt(transcript)),
        ]
        if transcript.polished != nil {
            outputs.append(("\(name)_潤飾.txt", polishedText(transcript)))
        }

        var urls: [URL] = []
        for (fileName, content) in outputs {
            let url = folder.appendingPathComponent(fileName)
            try content.write(to: url, atomically: true, encoding: .utf8)
            urls.append(url)
        }

        let jsonURL = folder.appendingPathComponent("\(name).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(transcript).write(to: jsonURL, options: .atomic)
        urls.append(jsonURL)
        return urls
    }

    // MARK: - 格式

    /// 依講者分段的純文字，沒有時間。
    static func plainText(_ transcript: Transcript) -> String {
        paragraphs(transcript.segments).map { paragraph in
            let body = paragraph.texts.joined(separator: separator(for: transcript))
            if let speaker = paragraph.speaker, transcript.speakerDetection {
                return "\(speaker)：\(body)"
            }
            return body
        }.joined(separator: "\n\n") + "\n"
    }

    /// 每句一行，前面標開始時間與講者。
    static func timestampedText(_ transcript: Transcript) -> String {
        transcript.segments.map { segment in
            let time = "[\(clock(segment.start))]"
            if transcript.speakerDetection {
                return "\(time) \(segment.speaker ?? "未知講者")：\(segment.text)"
            }
            return "\(time) \(segment.text)"
        }.joined(separator: "\n") + "\n"
    }

    /// 與 aTrain 的 transcription_maxqda.txt 相同排法：講者名稱獨立一行，句子前加 [hh:mm:ss] 時間戳，
    /// MAXQDA 匯入後點時間戳可以跳到對應音訊。
    static func maxqdaText(_ transcript: Transcript) -> String {
        var output = ""
        var currentSpeaker: String?
        for segment in transcript.segments {
            if transcript.speakerDetection {
                let speaker = segment.speaker ?? "未知講者"
                if speaker != currentSpeaker {
                    output += (output.isEmpty ? "" : "\n\n") + speaker + "\n"
                    currentSpeaker = speaker
                }
            }
            output += "[\(clock(segment.start))] - \(segment.text) "
        }
        return output.trimmingCharacters(in: .whitespaces) + "\n"
    }

    static func srt(_ transcript: Transcript) -> String {
        transcript.segments.enumerated().map { index, segment in
            let label = transcript.speakerDetection ? "\(segment.speaker ?? "未知講者")：" : ""
            return "\(index + 1)\n\(clock(segment.start, millisecondSeparator: ",")) --> \(clock(segment.end, millisecondSeparator: ","))\n\(label)\(segment.text)\n"
        }.joined(separator: "\n")
    }

    static func vtt(_ transcript: Transcript) -> String {
        let cues = transcript.segments.map { segment in
            let voice = transcript.speakerDetection ? "<v \(segment.speaker ?? "未知講者")>" : ""
            return "\(clock(segment.start, millisecondSeparator: ".")) --> \(clock(segment.end, millisecondSeparator: "."))\n\(voice)\(segment.text)\n"
        }
        return "WEBVTT\n\n" + cues.joined(separator: "\n")
    }

    static func polishedText(_ transcript: Transcript) -> String {
        guard let polished = transcript.polished else { return "" }
        return polished.map { paragraph in
            let time = "[\(clock(paragraph.start))]"
            if let speaker = paragraph.speaker, transcript.speakerDetection {
                return "\(time) \(speaker)：\(paragraph.polished)"
            }
            return "\(time) \(paragraph.polished)"
        }.joined(separator: "\n\n") + "\n"
    }

    // MARK: - 工具

    struct Paragraph {
        var speaker: String?
        var start: Double
        var end: Double
        var texts: [String]
    }

    /// 同一位講者連續的句子合成一段。
    static func paragraphs(_ segments: [TranscriptSegment]) -> [Paragraph] {
        var result: [Paragraph] = []
        for segment in segments {
            if let last = result.indices.last, result[last].speaker == segment.speaker {
                result[last].texts.append(segment.text)
                result[last].end = segment.end
            } else {
                result.append(Paragraph(speaker: segment.speaker, start: segment.start, end: segment.end, texts: [segment.text]))
            }
        }
        return result
    }

    /// 中日文句子直接相接，其他語言用空白隔開。
    static func separator(for transcript: Transcript) -> String {
        let language = transcript.detectedLanguage ?? transcript.language.whisperCode ?? ""
        let cjk = ["zh", "yue", "ja"].contains { language.hasPrefix($0) }
        return cjk ? "" : " "
    }

    /// 秒數轉成 hh:mm:ss；給了毫秒分隔符號時輸出 hh:mm:ss,mmm（SRT）或 hh:mm:ss.mmm（VTT）。
    public static func clock(_ seconds: Double, millisecondSeparator: String? = nil) -> String {
        let safe = max(0, seconds.isFinite ? seconds : 0)
        let totalMilliseconds = Int((safe * 1000).rounded())
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds / 60_000) % 60
        let secs = (totalMilliseconds / 1000) % 60
        let millis = totalMilliseconds % 1000
        let base = String(format: "%02d:%02d:%02d", hours, minutes, secs)
        guard let millisecondSeparator else { return base }
        return base + millisecondSeparator + String(format: "%03d", millis)
    }
}
