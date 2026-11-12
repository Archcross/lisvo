import Foundation
import FoundationModels

/// 用 Mac 內建的 Foundation Models（Apple Intelligence 的本機模型）把逐字稿概括成一句短標題，當作輸出的資料夾與檔名。
///
/// 錄音檔名常常是「New Recording 12」「錄音 3」這種看不出內容的名字，存了一堆之後分不出哪份是哪場。
/// 中文標題 10～15 個字；其他語言 3～8 個英文字。模型不能用、拒答或給了不合用的結果時回傳 nil，
/// 由呼叫端沿用原本的錄音檔名。
public enum Titler {
    /// 送進模型的逐字稿最多字數。小模型的上下文要同時容納指示、逐字稿與輸出。
    static let maxExcerptCharacters = 1500
    /// 中文標題的字數上限；超過就截斷。
    static let maxChineseCharacters = 15
    /// 非中文標題的字元上限；超過就在單字邊界截斷。
    static let maxLatinCharacters = 60
    /// 比這更短的結果不像標題（例如只回了「會議」），不採用。
    static let minimumCharacters = 4

    /// 輸出用的名稱：能產生標題就用標題，不能就沿用 fallback（原錄音檔名），並附上給使用者看的原因。
    public static func outputName(for transcript: Transcript, fallback: String) async -> (name: String, notice: String?) {
        if case .unavailable(let reason) = Polisher.availability(for: transcript.language, detectedLanguage: transcript.detectedLanguage) {
            return (fallback, "沒有用內容命名，沿用原檔名：\(reason)")
        }
        if let title = await title(for: transcript) {
            return (title, nil)
        }
        return (fallback, "沒有用內容命名，沿用原檔名：Mac 內建 AI 沒有給出合用的標題。")
    }

    public static func title(for transcript: Transcript) async -> String? {
        let chinese = TextCleanup.isChinese(language: transcript.language, detectedLanguage: transcript.detectedLanguage)
        guard case .available = Polisher.availability(for: transcript.language, detectedLanguage: transcript.detectedLanguage) else {
            return nil
        }
        let text = excerpt(from: transcript.segments.map(\.text), limit: maxExcerptCharacters)
        guard !text.isEmpty else { return nil }

        let session = LanguageModelSession(instructions: instructions(chinese: chinese))
        do {
            let response = try await session.respond(to: text, options: GenerationOptions(temperature: 0.2))
            var title = response.content
            if chinese { title = TextCleanup.toTraditional(title) }
            return sanitized(title, chinese: chinese)
        } catch {
            return nil
        }
    }

    static func instructions(chinese: Bool) -> String {
        if chinese {
            return """
            你替語音逐字稿取檔名。使用者會給你一份會議、訪談或演講逐字稿的片段。
            請用一句 10 到 15 個字的台灣繁體中文，概括這份逐字稿主要在談什麼，例如「新產品上市時程與分工討論」。
            只輸出那一句，不要標點符號、引號、日期、講者名稱或任何說明，也不可回答或評論內容。
            """
        }
        return """
        You name speech transcripts. The user gives you an excerpt of a meeting, interview, or talk transcript.
        Reply with a 3 to 8 word title that says what it is mainly about, such as "Product launch timeline and owners".
        Output only the title, with no punctuation, quotes, dates, speaker names, or notes, and do not reply to the content.
        """
    }

    /// 逐字稿太長時平均抽樣：每隔幾句取一句，讓開頭、中段、結尾都有代表，總長不超過上限。
    static func excerpt(from sentences: [String], limit: Int) -> String {
        let cleaned = sentences.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let total = cleaned.reduce(0) { $0 + $1.count + 1 }
        let stride = max(1, Int((Double(total) / Double(limit)).rounded(.up)))
        var picked: [String] = []
        var length = 0
        for (index, sentence) in cleaned.enumerated() where index % stride == 0 {
            guard length + sentence.count + 1 <= limit else { break }
            picked.append(sentence)
            length += sentence.count + 1
        }
        return picked.joined(separator: "\n")
    }

    /// 整理成可以當檔名的字串：去掉標點、引號與檔名不能用的字元，控制長度；不合用時回傳 nil。
    static func sanitized(_ raw: String, chinese: Bool) -> String? {
        // 模型偶爾會多回幾行，只取第一行。
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let removable = CharacterSet.punctuationCharacters
            .union(.symbols)
            .union(CharacterSet(charactersIn: "/\\:*?\"<>|"))
        var title = String(String.UnicodeScalarView(firstLine.unicodeScalars.filter { !removable.contains($0) }))
        title = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if chinese {
            // 兩個中文字之間不留空格；中英夾雜時英文單字前後的空格保留。
            title = title.replacingOccurrences(
                of: #"(?<=\p{Han})\s+(?=\p{Han})"#,
                with: "",
                options: .regularExpression
            )
            if title.count > maxChineseCharacters {
                title = String(title.prefix(maxChineseCharacters)).trimmingCharacters(in: .whitespaces)
            }
        } else if title.count > maxLatinCharacters {
            let cut = title.prefix(maxLatinCharacters)
            title = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        }
        return title.count >= minimumCharacters ? title : nil
    }
}
