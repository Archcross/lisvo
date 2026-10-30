import Foundation
import Testing
@testable import TranscriberCore

@Suite struct SpeakerAssignerTests {
    let turns = [
        SpeakerTurn(speaker: "講者 1", start: 0, end: 5),
        SpeakerTurn(speaker: "講者 2", start: 5.2, end: 10),
    ]

    @Test func assignsSpeakerWithLargestOverlap() {
        let segment = TranscriptSegment(start: 3, end: 9, text: "沒有字詞時間")
        let result = SpeakerAssigner.assign(turns: turns, to: [segment])
        #expect(result.count == 1)
        #expect(result[0].speaker == "講者 2")
    }

    @Test func splitsSentenceWhenSpeakerChangesMidway() {
        let words = [
            TimedWord(text: "我先", start: 3.0, end: 3.6),
            TimedWord(text: "說完。", start: 3.6, end: 4.8),
            TimedWord(text: "好的", start: 5.3, end: 5.9),
            TimedWord(text: "我接著講。", start: 5.9, end: 7.0),
        ]
        let segment = TranscriptSegment(start: 3, end: 7, text: "我先說完。好的我接著講。", words: words)
        let result = SpeakerAssigner.assign(turns: turns, to: [segment])
        #expect(result.map(\.speaker) == ["講者 1", "講者 2"])
        #expect(result.map(\.text) == ["我先說完。", "好的我接著講。"])
        #expect(result[1].start == 5.3)
    }

    @Test func mergesTooShortRunsIntoNeighbour() {
        // 中間 0.3 秒被判成講者 2，是邊界誤差，應併回講者 1。
        let shortTurns = [
            SpeakerTurn(speaker: "講者 1", start: 0, end: 2),
            SpeakerTurn(speaker: "講者 2", start: 2, end: 2.3),
            SpeakerTurn(speaker: "講者 1", start: 2.3, end: 5),
        ]
        let words = [
            TimedWord(text: "今天", start: 0.5, end: 1.5),
            TimedWord(text: "的", start: 2.0, end: 2.3),
            TimedWord(text: "會議", start: 2.4, end: 3.5),
        ]
        let segment = TranscriptSegment(start: 0.5, end: 3.5, text: "今天的會議", words: words)
        let result = SpeakerAssigner.assign(turns: shortTurns, to: [segment])
        #expect(result.count == 1)
        #expect(result[0].speaker == "講者 1")
        #expect(result[0].text == "今天的會議")
    }

    @Test func fallsBackToNearestSpeakerWithinTolerance() {
        let segment = TranscriptSegment(start: 10.5, end: 11, text: "尾巴")
        #expect(SpeakerAssigner.assign(turns: turns, to: [segment])[0].speaker == "講者 2")

        let farAway = TranscriptSegment(start: 30, end: 31, text: "很遠")
        #expect(SpeakerAssigner.assign(turns: turns, to: [farAway])[0].speaker == nil)
    }

    @Test func leavesSegmentsUntouchedWithoutTurns() {
        let segment = TranscriptSegment(start: 0, end: 1, text: "一句")
        #expect(SpeakerAssigner.assign(turns: [], to: [segment]) == [segment])
    }
}

@Suite struct ExporterTests {
    func transcript(speakers: Bool) -> Transcript {
        Transcript(
            sourceFileName: "會議.m4a",
            engine: .fast,
            language: .zhTW,
            detectedLanguage: "zh-TW",
            audioDuration: 10,
            processingSeconds: 1,
            speakerDetection: speakers,
            segments: [
                TranscriptSegment(start: 0, end: 1.5, text: "大家好。", speaker: "講者 1"),
                TranscriptSegment(start: 1.5, end: 3.25, text: "開始吧。", speaker: "講者 1"),
                TranscriptSegment(start: 3725.5, end: 3727.004, text: "好的。", speaker: "講者 2"),
            ]
        )
    }

    @Test func formatsClock() {
        #expect(Exporter.clock(0) == "00:00:00")
        #expect(Exporter.clock(3725.5) == "01:02:05")
        #expect(Exporter.clock(3727.004, millisecondSeparator: ",") == "01:02:07,004")
        #expect(Exporter.clock(59.9996, millisecondSeparator: ".") == "00:01:00.000")
        #expect(Exporter.clock(-3) == "00:00:00")
        #expect(Exporter.clock(.nan) == "00:00:00")
    }

    @Test func plainTextGroupsBySpeakerWithoutSpacesForChinese() {
        #expect(Exporter.plainText(transcript(speakers: true)) == "講者 1：大家好。開始吧。\n\n講者 2：好的。\n")
        #expect(Exporter.plainText(transcript(speakers: false)) == "大家好。開始吧。\n\n好的。\n")
    }

    @Test func srtHasSpeakerAndMilliseconds() {
        let srt = Exporter.srt(transcript(speakers: true))
        #expect(srt.hasPrefix("1\n00:00:00,000 --> 00:00:01,500\n講者 1：大家好。\n"))
        #expect(srt.contains("3\n01:02:05,500 --> 01:02:07,004\n講者 2：好的。\n"))
    }

    @Test func vttUsesVoiceTags() {
        let vtt = Exporter.vtt(transcript(speakers: true))
        #expect(vtt.hasPrefix("WEBVTT\n\n00:00:00.000 --> 00:00:01.500\n<v 講者 1>大家好。\n"))
    }

    @Test func maxqdaPutsSpeakerOnOwnLine() {
        let text = Exporter.maxqdaText(transcript(speakers: true))
        #expect(text == "講者 1\n[00:00:00] - 大家好。 [00:00:01] - 開始吧。 \n\n講者 2\n[01:02:05] - 好的。\n")
    }

    @Test func writesAllFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try Exporter.write(transcript(speakers: true), baseName: "會議", to: folder)
        #expect(Set(files.map(\.lastPathComponent)) == [
            "會議.txt", "會議_時間軸.txt", "會議_maxqda.txt",
            "會議.srt", "會議.vtt", "會議.json",
        ])
        let decoded = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: folder.appendingPathComponent("會議.json")))
        #expect(decoded.segments.count == 3)
    }
}

@Suite struct PolisherTests {
    @Test func chunksJoinSameSpeakerAndRespectLimit() {
        let long = String(repeating: "字", count: Polisher.maxCharactersPerChunk - 5)
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: "第一句。", speaker: "講者 1"),
            TranscriptSegment(start: 1, end: 2, text: "第二句。", speaker: "講者 1"),
            TranscriptSegment(start: 2, end: 3, text: long, speaker: "講者 1"),
            TranscriptSegment(start: 3, end: 4, text: "換人。", speaker: "講者 2"),
        ]
        let chunks = Polisher.chunks(from: segments, separator: "")
        #expect(chunks.map(\.text) == ["第一句。第二句。", long, "換人。"])
        #expect(chunks[0].end == 2)
    }
}

@Suite struct TextCleanupTests {
    @Test func tidyRemovesSpacesAroundChinesePunctuationOnly() {
        #expect(TextCleanup.tidy(" 大家好 ，今天 開會 。 ", chinese: true) == "大家好，今天開會。")
        #expect(TextCleanup.tidy("還是 landing page 的問題 ？", chinese: true) == "還是 landing page 的問題？")
        #expect(TextCleanup.tidy("Hello world, again.", chinese: false) == "Hello world, again.")
    }

    @Test func convertsHalfWidthPunctuationNextToChinese() {
        #expect(TextCleanup.tidy("大家好,今天的會議?轉換率是3.2%,比預期低.", chinese: true) == "大家好，今天的會議？轉換率是3.2%，比預期低。")
        #expect(TextCleanup.tidy("Hello, world. 版本 1.5", chinese: true) == "Hello, world. 版本 1.5")
    }

    @Test func convertsSimplifiedToTraditional() {
        #expect(TextCleanup.toTraditional("我们讨论后台的发展") == "我們討論後台的發展")
    }

    @Test func removesPlaceholderForUndecodableBytes() {
        // 實測樣本：模型輸出「，」只吐出 EF BC 兩個位元組就接「我」，解碼後在「稿」與「我」之間多一個 U+FFFD。
        let bytes: [UInt8] = [0xE7, 0xA8, 0xBF, 0xEF, 0xBC, 0xE6, 0x88, 0x91]
        let decoded = String(decoding: bytes, as: UTF8.self)
        #expect(decoded == "稿\u{FFFD}我")
        #expect(TextCleanup.removingUndecodableBytes(decoded) == "稿我")
        #expect(TextCleanup.removingUndecodableBytes("設計稿週三可以給。") == "設計稿週三可以給。")
    }
}

@Suite struct WhisperRegionTests {
    @Test func mergesSameSpeakerAndPadsIntoSilenceOnly() {
        let turns = [
            SpeakerTurn(speaker: "講者 1", start: 1.0, end: 3.0),
            SpeakerTurn(speaker: "講者 1", start: 3.5, end: 5.0),  // 間隔 0.5 秒，併入上一段
            SpeakerTurn(speaker: "講者 2", start: 5.1, end: 8.0),  // 和前一段只隔 0.1 秒
            SpeakerTurn(speaker: "講者 1", start: 8.0, end: 8.2),  // 0.2 秒且和下一段隔 1.3 秒：不送
            SpeakerTurn(speaker: "講者 1", start: 9.5, end: 9.95),
        ]
        let regions = WhisperEngine.regions(from: turns, duration: 10)
        let expected = [
            AudioRegion(start: 0.8, end: 5.1, speaker: "講者 1"),
            AudioRegion(start: 5.0, end: 8.2, speaker: "講者 2"),
            AudioRegion(start: 9.3, end: 10, speaker: "講者 1"),
        ]
        #expect(regions.count == expected.count)
        for (actual, wanted) in zip(regions, expected) {
            #expect(actual.speaker == wanted.speaker)
            #expect(abs(actual.start - wanted.start) < 1e-9)
            #expect(abs(actual.end - wanted.end) < 1e-9)
        }
    }

    @Test func sameSpeakerTurnsCloseTogetherAreMergedBeforeDroppingShortOnes() {
        let turns = [
            SpeakerTurn(speaker: "講者 1", start: 8.0, end: 8.2),
            SpeakerTurn(speaker: "講者 1", start: 9.0, end: 9.95),
        ]
        let regions = WhisperEngine.regions(from: turns, duration: 10)
        #expect(regions.count == 1)
        #expect(abs(regions[0].start - 7.8) < 1e-9)
        #expect(regions[0].end == 10)
    }

    @Test func slicesWithinBounds() {
        let samples = [Float](repeating: 0, count: 16_000)
        #expect(WhisperEngine.slice(samples, region: AudioRegion(start: 0.5, end: 2, speaker: nil)).count == 8_000)
        #expect(WhisperEngine.slice(samples, region: AudioRegion(start: 2, end: 3, speaker: nil)).isEmpty)
    }
}

@Suite struct PipelineTests {
    @Test func uniqueFolderAddsCounterWhenTaken() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let first = TranscriptionPipeline.uniqueFolder(in: base, baseName: "會議")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        let second = TranscriptionPipeline.uniqueFolder(in: base, baseName: "會議")
        #expect(second.lastPathComponent == first.lastPathComponent + " (2)")
    }
}

@Suite struct ModelLocationTests {
    @Test func allModelsLiveUnderLisvoFolder() {
        #expect(ModelLocations.whisper.path.hasSuffix("Application Support/Lisvo/Models/Whisper"))
        #expect(ModelLocations.diarization.path.hasSuffix("Application Support/Lisvo/Models/Diarization"))
        #expect(WhisperModelStore.modelsDirectory == ModelLocations.whisper)
    }

    @Test func whisperMarkerStoresPathRelativeToModelsFolder() {
        let inside = WhisperModelStore.modelsDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930")
        #expect(WhisperModelStore.relativePath(of: inside) == "models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930")
        // 不在模型資料夾裡時保留完整路徑，讀回來時才找得到。
        #expect(WhisperModelStore.relativePath(of: URL(fileURLWithPath: "/tmp/whisper")) == "/tmp/whisper")
    }
}

@Suite struct InboxTests {
    private func makeFolders() throws -> InboxFolders {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-\(UUID().uuidString)")
        let folders = InboxFolders(root: root)
        try folders.createIfNeeded()
        return folders
    }

    @Test func folderLayout() {
        let folders = InboxFolders(root: URL(fileURLWithPath: "/x/Lisvo"))
        #expect(folders.inbox.path == "/x/Lisvo/收件")
        #expect(folders.processed.path == "/x/Lisvo/已處理")
        #expect(folders.transcripts.path == "/x/Lisvo/逐字稿")
    }

    @Test func fileIsReadyOnlyAfterSizeStaysTheSame() throws {
        let folders = try makeFolders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let file = folders.inbox.appendingPathComponent("會議.m4a")
        try Data(repeating: 1, count: 100).write(to: file)

        var scanner = InboxScanner()
        #expect(scanner.readyFiles(in: folders.inbox).isEmpty) // 第一次只記下大小
        // 還在寫入：大小變了，不能處理。
        try Data(repeating: 1, count: 200).write(to: file)
        #expect(scanner.readyFiles(in: folders.inbox).isEmpty)
        // 大小穩定：可以處理。
        #expect(scanner.readyFiles(in: folders.inbox).map(\.lastPathComponent) == ["會議.m4a"])
    }

    @Test func ignoresHiddenEmptyAndNonMediaFiles() throws {
        let folders = try makeFolders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        try Data([1]).write(to: folders.inbox.appendingPathComponent(".DS_Store"))
        try Data([1]).write(to: folders.inbox.appendingPathComponent("筆記.txt"))
        try Data().write(to: folders.inbox.appendingPathComponent("空的.m4a"))
        try Data([1]).write(to: folders.inbox.appendingPathComponent("錄音.m4a"))

        var scanner = InboxScanner()
        _ = scanner.readyFiles(in: folders.inbox)
        #expect(scanner.readyFiles(in: folders.inbox).map(\.lastPathComponent) == ["錄音.m4a"])
    }

    @Test func placeholderNames() {
        #expect(InboxScanner.placeholderTarget(of: ".會議.m4a.icloud") == "會議.m4a")
        #expect(InboxScanner.placeholderTarget(of: "會議.m4a") == nil)
        #expect(InboxScanner.placeholderTarget(of: ".DS_Store") == nil)
        #expect(InboxScanner.placeholderTarget(of: "..icloud") == nil)
    }

    @Test func markProcessedNeverOverwrites() throws {
        let folders = try makeFolders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        for _ in 0..<2 {
            try Data([1]).write(to: folders.inbox.appendingPathComponent("新錄音.m4a"))
            try folders.markProcessed(folders.inbox.appendingPathComponent("新錄音.m4a"))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: folders.processed.path).sorted()
        #expect(names == ["新錄音 (2).m4a", "新錄音.m4a"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folders.inbox.path).isEmpty)
    }

    @Test func supportedMedia() {
        #expect(SupportedMedia.isSupported(URL(fileURLWithPath: "/a/b.m4a")))
        #expect(SupportedMedia.isSupported(URL(fileURLWithPath: "/a/b.mov")))
        #expect(!SupportedMedia.isSupported(URL(fileURLWithPath: "/a/b.txt")))
    }
}

@Suite struct LiveTranscriberTests {
    @Test func dropsPunctuationCarriedOverFromPreviousSentence() {
        #expect(LiveTranscriber.dropLeadingPunctuation("。嗯，那你覺得") == "嗯，那你覺得")
        #expect(LiveTranscriber.dropLeadingPunctuation("， 好的。") == "好的。")
        #expect(LiveTranscriber.dropLeadingPunctuation("。") == "")
        #expect(LiveTranscriber.dropLeadingPunctuation("大家好。") == "大家好。")
    }
}

@Suite struct LiveTranslationTests {
    @Test func splitsChineseSentencesAndKeepsUnfinishedPart() {
        let result = SentenceSplitter.split("大家好，今天討論預算。你覺得呢？我認為主要是")
        #expect(result.complete == ["大家好，今天討論預算。", "你覺得呢？"])
        #expect(result.remainder == "我認為主要是")
    }

    @Test func englishPeriodRules() {
        let result = SentenceSplitter.split("Revenue grew 3.2 percent. The U.S. team agrees. Next")
        #expect(result.complete == ["Revenue grew 3.2 percent.", "The U.S. team agrees."])
        #expect(result.remainder == "Next")
    }

    @Test func closingQuoteStaysWithSentence() {
        let result = SentenceSplitter.split("他說：「好的。」然後")
        #expect(result.complete == ["他說：「好的。」"])
        #expect(result.remainder == "然後")
    }

    @Test func punctuationOnlyIsNotASentence() {
        #expect(SentenceSplitter.split("。！").complete.isEmpty)
        #expect(SentenceSplitter.allSentences("好。還沒講完") == ["好。", "還沒講完"])
    }

    @Test func exportJoinsSentenceTranslationsPerSegment() {
        let segments = [
            TranscriptSegment(start: 3, end: 10, text: "大家好。今天開會", speaker: nil),
            TranscriptSegment(start: 12, end: 20, text: "沒問題。", speaker: nil),
        ]
        let cache = ["大家好。": "Hello everyone.", "今天開會": "We meet today", "沒問題。": ""]
        let text = LiveTranslationExport.text(segments: segments, cache: cache, target: .en)
        #expect(text == "[00:00:03] Hello everyone. We meet today\n[00:00:12] （翻譯失敗）\n")
        // 還有句子沒翻好時標示未翻譯，不默默漏掉。
        let missing = LiveTranslationExport.text(segments: segments, cache: [:], target: .en)
        #expect(missing.hasPrefix("[00:00:03] （未翻譯）"))
    }

    @Test func clauseModeBreaksAtCommasAndColons() {
        let result = SentenceSplitter.split("大家好，今天的會議主要是：預算、時程。還有", at: .clause)
        #expect(result.complete == ["大家好，", "今天的會議主要是：", "預算、時程。"])
        #expect(result.remainder == "還有")
        // 預設的整句模式不受影響。
        #expect(SentenceSplitter.split("大家好，今天開會。").complete == ["大家好，今天開會。"])
    }

    @Test func clauseModeKeepsNumbersAndTimesTogether() {
        let result = SentenceSplitter.split("Well, we spent 1,000 dollars at 10:30, and then", at: .clause)
        #expect(result.complete == ["Well,", "we spent 1,000 dollars at 10:30,"])
        #expect(result.remainder == "and then")
    }

    @Test func unfinishedTextNeedsEnoughLength() {
        #expect(!UnfinishedTranslationPolicy.isLongEnough("請工程團隊先做效能", language: .zhTW))
        #expect(UnfinishedTranslationPolicy.isLongEnough("請工程團隊先做效能優化預算的部分", language: .zhTW))
        #expect(!UnfinishedTranslationPolicy.isLongEnough("we need the engineering team", language: .en))
        #expect(UnfinishedTranslationPolicy.isLongEnough("we need the engineering team to fix it before", language: .en))
    }

    @Test func sameLanguageIsSkipped() {
        #expect(TranscriptionLanguage.zhTW.isSameLanguage(as: .zhHant))
        #expect(TranscriptionLanguage.yue.isSameLanguage(as: .zhHant))
        #expect(!TranscriptionLanguage.en.isSameLanguage(as: .zhHant))
        #expect(!TranscriptionLanguage.auto.isSameLanguage(as: .en))
    }
}

@Suite struct BilingualMergeTests {
    /// 英文辨識器的一句：每個字的文字、開始時間、信心。字的結束時間取下一個字的開始。
    func sentence(_ words: [(String, Double, Double)], end: Double) -> EnglishSentence? {
        let scored = words.enumerated().map { index, word in
            let wordEnd = index + 1 < words.count ? words[index + 1].1 : end
            return (word: TimedWord(text: word.0, start: word.1, end: wordEnd), confidence: word.2)
        }
        return EnglishSentence(words: scored)
    }

    @Test func finalSegmentSwapsGarbledEnglishByTime() throws {
        // 中文辨識器把整句英文聽成亂碼（實測資料簡化）。
        let words = [
            TimedWord(text: "預算", start: 2.9, end: 3.2),
            TimedWord(text: "。 ", start: 3.3, end: 3.5),
            TimedWord(text: "I ", start: 3.6, end: 3.7),
            TimedWord(text: "thinke ", start: 3.7, end: 4.3),
            TimedWord(text: "shoudanist ", start: 4.3, end: 6.6),
            TimedWord(text: "month.", start: 6.6, end: 8.5),
            TimedWord(text: "好", start: 8.6, end: 8.8),
            TimedWord(text: "那", start: 8.8, end: 9.0),
        ]
        let segment = TranscriptSegment(start: 2.9, end: 9.0, text: "預算。 I thinke shoudanist month.好那", words: words)
        let english = try #require(sentence([(" I", 3.7, 0.92), (" think", 4.0, 0.96), (" we", 4.1, 0.98), (" should", 4.3, 0.99), (" focus.", 4.4, 0.9)], end: 8.4))

        let merged = BilingualMerge.merge(segment, english: [english])
        #expect(merged.text == "預算。 I think we should focus. 好那")
        #expect(TextCleanup.tidy(merged.text, chinese: true) == "預算。I think we should focus. 好那")
        #expect(merged.words.map(\.text) == ["預算", "。 ", " I", " think", " we", " should", " focus.", "好", "那"])
        #expect(merged.id == segment.id)
    }

    @Test func lowConfidenceEnglishKeepsChineseResult() throws {
        // 實測「這個 project 的 deadline 是下禮拜五…」交給英文辨識器的結果：中文被聽成拼音，信心很低。
        let english = try #require(sentence([
            ("Took", 0.0, 0.03), (" a", 0.4, 0.31), (" project,", 0.5, 0.74), (" the", 1.3, 0.91), (" deadline,", 1.3, 0.75),
            (" Shi", 2.2, 0.48), (" Shali", 2.5, 0.24), (" Bai", 2.7, 0.54), (" Wu,", 3.2, 0.20), (" Women", 3.7, 0.23),
            (" Yao", 4.1, 0.37), (" Xiang,", 4.3, 0.30), (" client", 5.0, 0.91), (" confirm", 5.3, 0.93), (" budget,", 6.0, 0.72),
            (" Yang", 7.0, 0.58), (" Ho", 7.3, 0.14), (" marketing", 7.5, 0.93), (" team,", 8.2, 0.50), (" Hui", 8.8, 0.50),
            (" Jiang,", 9.1, 0.03), (" big", 9.4, 0.22), (" proposal,", 9.7, 0.72), (" Tang", 10.7, 0.05), (" Jang,", 11.0, 0.08),
            (" okay,", 11.6, 0.02), (" Ma.", 11.8, 0.36),
        ], end: 12.0))
        #expect(english.confidence < BilingualMerge.minimumConfidence)
        // 頭尾信心低的字去掉了。
        #expect(english.text.hasPrefix("project,"))
        #expect(english.text.hasSuffix("proposal,"))

        let words = [
            TimedWord(text: "這", start: 0.0, end: 0.2), TimedWord(text: "個 ", start: 0.2, end: 0.3),
            TimedWord(text: "project", start: 0.3, end: 1.1), TimedWord(text: "的 ", start: 1.1, end: 1.3),
            TimedWord(text: "Client ", start: 4.6, end: 5.4), TimedWord(text: "conformbroget", start: 5.4, end: 6.8),
            TimedWord(text: "然", start: 6.8, end: 7.1),
        ]
        let segment = TranscriptSegment(start: 0, end: 7.1, text: "這個 project的 Client conformbroget然", words: words)
        #expect(BilingualMerge.merge(segment, english: [english]) == segment)
        #expect(BilingualMerge.merge(volatile: "我們要先跟 Client conformbroget然後", english: [english]) == "我們要先跟 Client conformbroget然後")
    }

    @Test func punctuationOnlyEnglishIsDropped() {
        // 實測英文辨識器聽一段純中文，有時只吐出一串信心幾乎是 0 的逗號。
        #expect(sentence([(" ,", 8.0, 0.01), (" ,", 8.8, 0.01), (" ,", 9.1, 0.01)], end: 9.3) == nil)
    }

    @Test func volatileTextSwapsEachGarbledStretchInOrder() throws {
        // 暫定文字沒有逐字時間，靠字母順序比對；兩段亂碼各自對到自己那句，不會被前一段搶走。
        let first = try #require(sentence([("I think we should focus on the marketing plan 1st because the launch is next month.", 3.7, 0.9)], end: 8.8))
        let second = try #require(sentence([("Sure, I will send the draft to everyone by Friday.", 12.4, 0.93)], end: 14.9))
        let text = "今天的會議我們先討論下一季的預算。I thinkedanirst bcauseh lanchs next month好那行銷的部分請你下週提出來。Sureliveyoneriday"
        let merged = TextCleanup.tidy(BilingualMerge.merge(volatile: text, english: [first, second]), chinese: true)
        #expect(merged == "今天的會議我們先討論下一季的預算。I think we should focus on the marketing plan 1st because the launch is next month. 好那行銷的部分請你下週提出來。Sure, I will send the draft to everyone by Friday.")
    }

    @Test func volatileTextKeepsShortEnglishWordsInChinese() throws {
        // 同一時段有一句真的英文，但中文句子裡的「Marketing team」不能被它換掉。
        let english = try #require(sentence([("Sure, I will send the draft to everyone by Friday.", 12.4, 0.93)], end: 14.9))
        let text = "然後 Marketing team會準備 preposal大家 OK嗎？"
        #expect(BilingualMerge.merge(volatile: text, english: [english]) == text)
    }

    @Test func directionFollowsChineseCharacterCount() {
        #expect(BilingualText.isChinese("這個 project 的 deadline"))
        #expect(!BilingualText.isChinese("I think we should focus."))
        #expect(!BilingualText.isChinese("OK 好"))
        #expect(TranslationTarget.bilingual.resolved(for: "大家好，") == .en)
        #expect(TranslationTarget.bilingual.resolved(for: "Thank you.") == .zhHant)
        #expect(TranslationTarget.ja.resolved(for: "Thank you.") == .ja)
    }

    @Test func bilingualOptionOnlyWhenListeningToChinese() {
        #expect(TranslationTarget.bilingual.isAvailable(listening: .zhTW))
        #expect(!TranslationTarget.bilingual.isAvailable(listening: .en))
        #expect(!TranslationTarget.bilingual.isAvailable(listening: .ja))
        #expect(TranslationTarget.bilingual.directions(listening: .zhTW).count == 2)
        #expect(TranslationTarget.bilingual.directions(listening: .en).isEmpty)
        #expect(!TranslationTarget.zhHant.isAvailable(listening: .zhTW))
        #expect(TranslationTarget.en.directions(listening: .zhTW) == [.en: Locale.Language(identifier: "zh-Hant")])
    }

    @Test func bilingualJoinSpacesOnlyAroundLatinText() {
        #expect(TranslationTarget.bilingual.join(["Hello.", "你好。", "謝謝。", "", "Thanks."]) == "Hello. 你好。謝謝。 Thanks.")
        #expect(TranslationTarget.zhHant.join(["你好。", "謝謝。"]) == "你好。謝謝。")
        #expect(TranslationTarget.en.join(["Hello.", "", "Thanks."]) == "Hello. Thanks.")
    }
}

@Suite struct BilingualLiveMergerTests {
    final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [LiveEvent] = []
        func append(_ event: LiveEvent) { lock.withLock { stored.append(event) } }
        var finalized: [String] {
            lock.withLock {
                stored.compactMap { if case .finalized(let segment) = $0 { segment.text } else { nil } }
            }
        }
        var lastVolatile: String? {
            lock.withLock {
                stored.compactMap { if case .volatile(let text) = $0 { text } else { nil } }.last
            }
        }
    }

    let garbled = TranscriptSegment(
        start: 0, end: 5,
        text: "好。 I thinke so",
        words: [
            TimedWord(text: "好", start: 0, end: 0.5), TimedWord(text: "。 ", start: 0.5, end: 1),
            TimedWord(text: "I ", start: 1, end: 1.5), TimedWord(text: "thinke ", start: 1.5, end: 3), TimedWord(text: "so", start: 3, end: 5),
        ]
    )

    func english() -> EnglishSentence? {
        EnglishSentence(words: [
            (TimedWord(text: " I", start: 1.1, end: 1.5), 0.95),
            (TimedWord(text: " think", start: 1.5, end: 3), 0.95),
            (TimedWord(text: " so.", start: 3, end: 4.9), 0.9),
        ])
    }

    @Test func holdsChineseFinalUntilEnglishCatchesUp() async throws {
        let log = EventLog()
        let merger = BilingualLiveMerger(onEvent: log.append, tidy: { TextCleanup.tidy($0, chinese: true) })
        await merger.chineseFinal(garbled)
        // 英文還沒定案到這段結尾：先當暫定文字顯示，不送定案。
        #expect(log.finalized.isEmpty)
        #expect(log.lastVolatile == "好。I thinke so")

        await merger.englishFinal(try #require(english()), end: 4.9)
        #expect(log.finalized == ["好。I think so."])
        #expect(log.lastVolatile == "")
        #expect(await merger.finish().map(\.text) == ["好。I think so."])
    }

    @Test func releasesAfterWaitingWhenEnglishNeverCatchesUp() async throws {
        let log = EventLog()
        let merger = BilingualLiveMerger(onEvent: log.append, tidy: { TextCleanup.tidy($0, chinese: true) })
        await merger.chineseFinal(garbled)
        try await Task.sleep(for: BilingualLiveMerger.finalHold + .milliseconds(300))
        // 等太久就照中文辨識的結果送出，不卡住字幕。
        #expect(log.finalized == ["好。I thinke so"])
        #expect(await merger.finish().map(\.text) == ["好。I thinke so"])
    }
}
