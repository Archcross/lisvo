import Foundation

/// 把「誰在什麼時候說話」對到逐字稿的每一句。
///
/// 做法沿用 aTrain（來自 whisperX）：看時間重疊，重疊最多的講者就是這段話的講者。
/// 差別在於這裡用字詞時間逐字判斷，一句話中途換人時會切成兩句，aTrain 只會整句歸給一個人。
public enum SpeakerAssigner {
    /// 一句話裡換講者的片段短於這個秒數，視為分講者模型的邊界誤差，併回前後文。
    static let minimumRunDuration = 0.6
    /// 字詞完全沒和任何講者重疊時（常見於句尾），找這個距離內最近的講者。
    static let nearestSpeakerTolerance = 1.5

    public static func assign(turns: [SpeakerTurn], to segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard !turns.isEmpty else { return segments }
        let sortedTurns = turns.sorted { $0.start < $1.start }
        return segments.flatMap { split($0, turns: sortedTurns) }
    }

    static func speaker(start: Double, end: Double, turns: [SpeakerTurn]) -> String? {
        var overlapBySpeaker: [String: Double] = [:]
        for turn in turns {
            if turn.start >= end { break }
            let overlap = min(turn.end, end) - max(turn.start, start)
            if overlap > 0 {
                overlapBySpeaker[turn.speaker, default: 0] += overlap
            }
        }
        if let best = overlapBySpeaker.max(by: { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }) {
            return best.key
        }

        // 沒有重疊：找時間距離最近的講者段落。
        let mid = (start + end) / 2
        var nearest: (speaker: String, distance: Double)?
        for turn in turns {
            let distance = mid < turn.start ? turn.start - mid : max(0, mid - turn.end)
            if distance <= nearestSpeakerTolerance, distance < (nearest?.distance ?? .infinity) {
                nearest = (turn.speaker, distance)
            }
        }
        return nearest?.speaker
    }

    private struct Run {
        var speaker: String?
        var words: [TimedWord]
        var start: Double { words.first?.start ?? 0 }
        var end: Double { words.last?.end ?? 0 }
        var duration: Double { end - start }
    }

    static func split(_ segment: TranscriptSegment, turns: [SpeakerTurn]) -> [TranscriptSegment] {
        let timedWords = segment.words.filter { $0.end >= $0.start }
        guard timedWords.count > 1 else {
            var copy = segment
            copy.speaker = speaker(start: segment.start, end: segment.end, turns: turns)
            return [copy]
        }

        // 1. 每個字詞各自判斷講者，連續同一人的字詞合成一段。
        var runs: [Run] = []
        for word in timedWords {
            let who = speaker(start: word.start, end: word.end, turns: turns)
            if let last = runs.indices.last, runs[last].speaker == who {
                runs[last].words.append(word)
            } else {
                runs.append(Run(speaker: who, words: [word]))
            }
        }

        // 2. 太短的段落多半是邊界誤差，併進比較長的鄰居。
        var changed = true
        while changed, runs.count > 1 {
            changed = false
            guard let shortest = runs.indices.min(by: { runs[$0].duration < runs[$1].duration }),
                  runs[shortest].duration < minimumRunDuration
            else { break }
            let target: Int
            if shortest == 0 {
                target = 1
            } else if shortest == runs.count - 1 {
                target = shortest - 1
            } else {
                target = runs[shortest - 1].duration >= runs[shortest + 1].duration ? shortest - 1 : shortest + 1
            }
            if target < shortest {
                runs[target].words.append(contentsOf: runs[shortest].words)
            } else {
                runs[target].words.insert(contentsOf: runs[shortest].words, at: 0)
            }
            runs.remove(at: shortest)
            // 合併後相鄰兩段可能變成同一人，再接起來。
            var merged: [Run] = []
            for run in runs {
                if let last = merged.indices.last, merged[last].speaker == run.speaker {
                    merged[last].words.append(contentsOf: run.words)
                } else {
                    merged.append(run)
                }
            }
            runs = merged
            changed = true
        }

        if runs.count == 1 {
            var copy = segment
            copy.speaker = runs[0].speaker
            return [copy]
        }

        return runs.map { run in
            TranscriptSegment(
                start: run.start,
                end: run.end,
                text: run.words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines),
                speaker: run.speaker,
                words: run.words
            )
        }
    }
}
