import Foundation

/// 英文辨識器定案的一句，帶每個字的時間和平均信心。中英夾雜時用來換掉中文辨識器聽不懂的整句英文。
public struct EnglishSentence: Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    /// 每個字信心分數（0～1）的平均。
    public var confidence: Double
    public var words: [TimedWord]

    /// 頭尾信心太低的字先去掉：多半是旁邊的中文被硬聽成英文（實測「Took a project」的 Took 只有 0.03）。
    static let edgeConfidence = 0.4

    /// 去掉頭尾信心低的字後沒有英文字母（例如整句只有「, , ,」）就回傳 nil。
    public init?(words scored: [(word: TimedWord, confidence: Double)]) {
        var kept = scored[...]
        while let first = kept.first, first.confidence < Self.edgeConfidence { kept = kept.dropFirst() }
        while let last = kept.last, last.confidence < Self.edgeConfidence { kept = kept.dropLast() }
        let text = kept.map(\.word.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = kept.first, let last = kept.last, text.contains(where: BilingualMerge.isLatinLetter) else { return nil }
        self.text = text
        start = first.word.start
        end = last.word.end
        confidence = kept.map(\.confidence).reduce(0, +) / Double(kept.count)
        words = kept.map(\.word)
    }
}

/// 中英夾雜的即時字幕：同一段聲音同時交給中文和英文兩個辨識器，再合成一份。
///
/// 實測兩個辨識器各有盲點：
/// - 中文辨識器聽中文準，句子裡夾的英文單字也大多聽得出來（「這個 project 的 deadline」），
///   但整句英文會變亂碼（「I think we should focus…」→「I thinke shoudanist bcauseh…」）。
/// - 英文辨識器聽英文準，但會把中文硬聽成拼音（「Shi Shali Bai Wu」），這些字的信心只有 0.0～0.5，
///   真的英文句子約 0.9。
///
/// 所以以中文辨識結果為主，只把裡面「沒有中文字的段落」換成英文辨識器同一段、信心夠高的句子。
/// 中文句子裡夾的英文單字，英文辨識器那邊是一整句拼音亂碼、信心低，不會被拿來換。
public enum BilingualMerge {
    /// 英文句子的平均信心至少多少才拿來換。
    public static let minimumConfidence = 0.7
    /// 定案的句子用時間對：英文句子至少一半的時間落在這段沒有中文字的段落裡。
    static let minimumTimeOverlap = 0.5
    /// 暫定文字沒有逐字時間（實測每個字的時間都是整段的開頭），改用字母順序比對：
    /// 這段的英文字母至少六成依序出現在英文句子裡，而且涵蓋英文句子至少三成的字母。
    /// 第二個條件擋掉短的英文單字（「Marketing team」）湊巧對上一整句英文。
    static let minimumMatch = 0.6
    static let minimumCoverage = 0.3
    /// 暫定文字裡少於這麼多字母的段落不比對，太短容易湊巧對上。
    static let minimumLetters = 6
    /// 一段亂碼最多對到幾句連續的英文（中文辨識器有時把兩句英文黏成一段）。
    static let maximumSentencesPerStretch = 3

    /// 定案的一句：用逐字時間找出沒有中文字的段落，換成時間對得上的英文句子。字詞時間一起換。
    /// 傳入的是還沒整理標點的辨識結果；字詞拼不回原文時（有字沒帶時間）不動，避免弄丟字。
    public static func merge(_ segment: TranscriptSegment, english: [EnglishSentence]) -> TranscriptSegment {
        let candidates = english.filter { $0.confidence >= minimumConfidence }
        let source = segment.words
        guard !candidates.isEmpty, !source.isEmpty,
              source.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) == segment.text
        else { return segment }

        var used = Set<Int>()
        var words: [TimedWord] = []
        var pieces: [String] = []
        var replaced = false
        var index = 0
        for stretch in latinStretches(in: source) {
            for word in source[index..<stretch.lowerBound] {
                words.append(word)
                pieces.append(word.text)
            }
            let start = source[stretch.lowerBound].start
            let end = source[stretch.upperBound - 1].end
            let matched = candidates.indices.filter {
                !used.contains($0) && overlapRatio(of: candidates[$0], start: start, end: end) >= minimumTimeOverlap
            }
            if matched.isEmpty {
                for word in source[stretch] {
                    words.append(word)
                    pieces.append(word.text)
                }
            } else {
                used.formUnion(matched)
                let sentences = matched.map { candidates[$0] }
                words += sentences.flatMap(\.words)
                pieces.append(" " + sentences.map(\.text).joined(separator: " ") + " ")
                replaced = true
            }
            index = stretch.upperBound
        }
        guard replaced else { return segment }
        for word in source[index...] {
            words.append(word)
            pieces.append(word.text)
        }
        var merged = segment
        merged.text = collapseSpaces(pieces.joined())
        merged.words = words
        return merged
    }

    /// 暫定文字：依序把沒有中文字的段落和英文句子比對字母順序，夠像的才換。
    /// `english` 只放這段暫定文字同一時段的句子，比對才不會對到很久以前說的話。
    public static func merge(volatile text: String, english: [EnglishSentence]) -> String {
        let candidates = english.filter { $0.confidence >= minimumConfidence }
        guard !candidates.isEmpty else { return text }

        var replacements: [(range: Range<String.Index>, text: String)] = []
        var next = 0
        for stretch in latinStretches(in: text) {
            let letters = latinLetters(of: text[stretch])
            guard letters.count >= minimumLetters else { continue }
            var best: (sentences: ClosedRange<Int>, common: Int)?
            for first in next..<candidates.count {
                var combined: [Character] = []
                var previous = 0
                for last in first..<min(first + maximumSentencesPerStretch, candidates.count) {
                    let added = latinLetters(of: candidates[last].text)
                    combined += added
                    let common = commonSubsequenceLength(letters, combined)
                    // 多接一句時，這句本身也要有足夠的字母對上，否則是下一段亂碼的句子，不能搶過來。
                    if last > first, Double(common - previous) < minimumCoverage * Double(added.count) { break }
                    previous = common
                    guard Double(common) >= minimumMatch * Double(letters.count),
                          Double(common) >= minimumCoverage * Double(combined.count)
                    else { continue }
                    if common > (best?.common ?? 0) { best = (first...last, common) }
                }
            }
            guard let best else { continue }
            replacements.append((stretch, candidates[best.sentences].map(\.text).joined(separator: " ")))
            next = best.sentences.upperBound + 1
        }
        guard !replacements.isEmpty else { return text }
        var result = text
        for replacement in replacements.reversed() {
            result.replaceSubrange(replacement.range, with: " " + replacement.text + " ")
        }
        return collapseSpaces(result)
    }

    // MARK: - 找出沒有中文字的段落

    /// 中文字或全形標點。沒有它們的連續文字才可能是英文。
    static func isChineseCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar.properties.isIdeographic
                || (0x3000...0x303F).contains(scalar.value)   // 「。、」等中日文標點
                || (0xFF00...0xFFEF).contains(scalar.value)   // 「，！？：」等全形標點
        }
    }

    static func isLatinLetter(_ character: Character) -> Bool {
        character.isASCII && character.isLetter
    }

    /// 字詞層級：連續沒有中文字、而且至少有一個英文字的字詞。頭尾只有空白或標點的字詞不算進去。
    static func latinStretches(in words: [TimedWord]) -> [Range<Int>] {
        var stretches: [Range<Int>] = []
        var index = 0
        while index < words.count {
            guard !words[index].text.contains(where: isChineseCharacter) else {
                index += 1
                continue
            }
            var end = index
            while end < words.count, !words[end].text.contains(where: isChineseCharacter) { end += 1 }
            let group = index..<end
            if let first = group.first(where: { words[$0].text.contains(where: isLatinLetter) }),
               let last = group.last(where: { words[$0].text.contains(where: isLatinLetter) }) {
                stretches.append(first..<(last + 1))
            }
            index = end
        }
        return stretches
    }

    /// 文字層級：連續沒有中文字的部分，從第一個英文字母到最後一個英文字母，再帶上緊接的半形句尾標點。
    static func latinStretches(in text: String) -> [Range<String.Index>] {
        var stretches: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard !isChineseCharacter(text[index]) else {
                index = text.index(after: index)
                continue
            }
            var end = index
            while end < text.endIndex, !isChineseCharacter(text[end]) { end = text.index(after: end) }
            let group = text[index..<end]
            if let first = group.firstIndex(where: isLatinLetter), let last = group.lastIndex(where: isLatinLetter) {
                var upper = text.index(after: last)
                while upper < end, ".!?,;:".contains(text[upper]) { upper = text.index(after: upper) }
                stretches.append(first..<upper)
            }
            index = end
        }
        return stretches
    }

    // MARK: - 比對

    /// 英文句子有多少比例的時間落在 start～end 之間。
    static func overlapRatio(of sentence: EnglishSentence, start: Double, end: Double) -> Double {
        let overlap = min(sentence.end, end) - max(sentence.start, start)
        return max(0, overlap) / max(sentence.end - sentence.start, 0.1)
    }

    static func latinLetters<S: StringProtocol>(of text: S) -> [Character] {
        String(text.filter(isLatinLetter)).lowercased().map { $0 }
    }

    /// 最長共同子序列的長度：中文辨識器的亂碼通常是英文原句掉了一些字母（「bcauseh」對「because」），
    /// 字母的先後順序大致還在。
    static func commonSubsequenceLength(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = previous
        for x in a {
            for (j, y) in b.enumerated() {
                current[j + 1] = x == y ? previous[j] + 1 : max(previous[j + 1], current[j])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    static func collapseSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 判斷一段文字是中文還是英文，決定中英互譯的翻譯方向。
/// 不用系統的語言偵測（NLLanguageRecognizer）：實測它把「這個 project 的 deadline 是下禮拜五」判成英文。
public enum BilingualText {
    /// 至少兩個漢字就算中文。中文句子夾英文單字仍算中文；英文句子裡偶爾冒出一個字不算。
    public static func isChinese(_ text: String) -> Bool {
        var count = 0
        for character in text where character.unicodeScalars.contains(where: \.properties.isIdeographic) {
            count += 1
            if count >= 2 { return true }
        }
        return false
    }
}

/// 中英同時辨識時，把兩個辨識器的結果合成一條字幕事件，順序和只用一個辨識器時一樣：暫定文字不斷更新，講完一段送出定案。
///
/// 中文那段定案時，英文辨識器常常還沒定案同一段的英文。先把它當暫定文字顯示（字幕不會空一下），
/// 等英文辨識器定案到這段結尾、或最多等 `finalHold`，再合併送出。
actor BilingualLiveMerger {
    static let finalHold: Duration = .milliseconds(1500)
    /// 英文辨識器定案到中文那段結尾前多少秒內，就算跟上了。
    static let caughtUpTolerance = 0.3
    /// 暫定文字比對時，只看開始時間之前這麼多秒以後才結束的英文句子。
    static let volatileWindowSlack = 0.5
    /// 英文句子保留多久（以還在處理的最早那段為準）。更早的已經不會再用到。
    static let englishRetention = 30.0

    private let onEvent: @Sendable (LiveEvent) -> Void
    /// 整理標點、去掉開頭標點。和只用一個辨識器時的整理方式相同。
    private let tidy: @Sendable (String) -> String
    private var english: [EnglishSentence] = []
    private var englishFinalUntil = 0.0
    private var volatileText = ""
    private var volatileStart = 0.0
    /// 中文已定案、還在等英文辨識器的段落（未整理標點）。
    private var pending: [TranscriptSegment] = []
    private var holdGeneration = 0
    private var emitted: [TranscriptSegment] = []

    init(onEvent: @escaping @Sendable (LiveEvent) -> Void, tidy: @escaping @Sendable (String) -> String) {
        self.onEvent = onEvent
        self.tidy = tidy
    }

    func chineseVolatile(_ text: String, start: Double) {
        volatileText = text
        volatileStart = start
        publishVolatile()
    }

    func chineseFinal(_ segment: TranscriptSegment) {
        pending.append(segment)
        // 剛才的暫定文字就是這段，之後的暫定文字屬於下一段。
        volatileText = ""
        if englishCaughtUp {
            release()
        } else {
            publishVolatile()
            scheduleRelease()
        }
    }

    /// 英文辨識器定案一段。`sentence` 是 nil 代表那段沒有可用的英文（例如只有標點），但時間照樣往前推。
    func englishFinal(_ sentence: EnglishSentence?, end: Double?) {
        if let end { englishFinalUntil = max(englishFinalUntil, end) }
        if let sentence { english.append(sentence) }
        if !pending.isEmpty, englishCaughtUp {
            release()
        } else if sentence != nil {
            publishVolatile()
        }
    }

    /// 兩個辨識器都結束後呼叫：送出還在等的段落，回傳這次所有定案的句子（和送出過的完全相同）。
    func finish() -> [TranscriptSegment] {
        release()
        return emitted
    }

    private var englishCaughtUp: Bool {
        guard let last = pending.last else { return true }
        return englishFinalUntil >= last.end - Self.caughtUpTolerance
    }

    private func scheduleRelease() {
        holdGeneration += 1
        let generation = holdGeneration
        Task { [weak self] in
            try? await Task.sleep(for: Self.finalHold)
            await self?.releaseIfStillHolding(generation)
        }
    }

    private func releaseIfStillHolding(_ generation: Int) {
        guard generation == holdGeneration else { return }
        release()
    }

    private func release() {
        guard !pending.isEmpty else { return }
        for segment in pending {
            var merged = BilingualMerge.merge(segment, english: english)
            merged.text = tidy(merged.text)
            guard !merged.text.isEmpty else { continue }
            emitted.append(merged)
            onEvent(.finalized(merged))
        }
        pending = []
        let horizon = min(volatileText.isEmpty ? .infinity : volatileStart, englishFinalUntil) - Self.englishRetention
        english.removeAll { $0.end < horizon }
        publishVolatile()
    }

    /// 暫定文字：還在等英文的定案段落，接上中文辨識器目前的暫定文字。
    private func publishVolatile() {
        var parts = pending.map { BilingualMerge.merge($0, english: english).text }
        if !volatileText.isEmpty {
            let window = english.filter { $0.end > volatileStart - Self.volatileWindowSlack }
            parts.append(BilingualMerge.merge(volatile: volatileText, english: window))
        }
        onEvent(.volatile(tidy(parts.joined(separator: " "))))
    }
}
