struct CompressionSourceCoverage {
    private let roundStart: UInt64
    private let roundEnd: UInt64
    private var preparedEnd: UInt64
    private var longestCompletedGap: UInt64 = 0
    private(set) var preparedFrames = 0

    init(sourceBegin: UInt64, sourceEnd: UInt64) {
        precondition(sourceEnd >= sourceBegin)
        roundStart = sourceBegin
        roundEnd = sourceEnd
        preparedEnd = sourceBegin
    }

    var longestMissingSourceFrames: Int {
        Int(max(longestCompletedGap, roundEnd - preparedEnd))
    }

    // The playout pump supplies intervals in source order; past overlap cannot add coverage.
    mutating func recordPrepared(sourceBegin: UInt64, sourceEnd: UInt64) {
        let begin = max(max(sourceBegin, roundStart), preparedEnd)
        let end = min(sourceEnd, roundEnd)
        guard end > begin else { return }
        longestCompletedGap = max(longestCompletedGap, begin - preparedEnd)
        preparedFrames += Int(end - begin)
        preparedEnd = end
    }
}
