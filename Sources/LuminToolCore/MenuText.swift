public enum MenuText {
    public static func wrap(_ text: String, width: Int = 30) -> String {
        let words = text.split(separator: " ").map(String.init)
        guard text.count > width, words.count > 1 else { return text }
        let n = words.count
        let infinity = Int.max / 4
        // best[k][i]: least cost of putting the first i words on k lines; fewest lines wins, cost only picks among them
        var best = [[Int]](repeating: [Int](repeating: infinity, count: n + 1), count: n + 1)
        var from = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: n + 1)
        best[0][0] = 0
        for lines in 1...n {
            for end in 1...n {
                var length = -1
                for start in stride(from: end - 1, through: 0, by: -1) {
                    length += words[start].count + 1
                    if length > width && start < end - 1 { break }
                    guard best[lines - 1][start] < infinity else { continue }
                    let cost = best[lines - 1][start] + length * length + (end < n ? breakCost(after: words[end - 1], width: width) : 0)
                    if cost < best[lines][end] {
                        best[lines][end] = cost
                        from[lines][end] = start
                    }
                }
            }
            if best[lines][n] < infinity {
                var result: [String] = []
                var end = n
                for line in stride(from: lines, through: 1, by: -1) {
                    let start = from[line][end]
                    result.insert(words[start..<end].joined(separator: " "), at: 0)
                    end = start
                }
                return result.joined(separator: "\n")
            }
        }
        return text
    }

    public static func title(_ text: String, width: Int = 30) -> String {
        wrap(text, width: width).split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.hasSuffix(".") && !line.hasSuffix("..") ? String(line.dropLast()) : String(line)
        }.joined(separator: "\n")
    }

    // Squared lengths keep lines even; a sentence end is a good place to break, a dangling preposition is not
    private static func breakCost(after word: String, width: Int) -> Int {
        if let last = word.last, ".;:,!?".contains(last) { return -width * width / 4 }
        return word.count <= 2 ? width * width : 0
    }
}
