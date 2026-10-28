import Foundation

/// Finds the lowest encoder quality whose output still passes a similarity threshold.
///
/// The search is a bisection over a continuous quality parameter (0...1). It assumes the
/// score rises with quality, but it never trusts that blindly: the result is always the
/// smallest output among the trials that actually passed.
public struct QualitySearch: Sendable {
    public struct Trial: Sendable, Equatable {
        public let quality: Double
        public let byteSize: Int64
        public let score: Double

        public init(quality: Double, byteSize: Int64, score: Double) {
            self.quality = quality
            self.byteSize = byteSize
            self.score = score
        }
    }

    public let range: ClosedRange<Double>
    /// Stop when the remaining interval is narrower than this.
    public let tolerance: Double
    public let maxTrials: Int

    public init(range: ClosedRange<Double> = 0.30...0.95, tolerance: Double = 0.03, maxTrials: Int = 8) {
        precondition(range.lowerBound >= 0 && range.upperBound <= 1, "Quality range must be within 0...1")
        precondition(maxTrials >= 1, "At least one trial is needed")
        self.range = range
        self.tolerance = tolerance
        self.maxTrials = maxTrials
    }

    public struct Outcome: Sendable, Equatable {
        /// The smallest output that passed, or `nil` if none did.
        public let best: Trial?
        public let trials: [Trial]
    }

    /// - Parameters:
    ///   - threshold: minimum acceptable score.
    ///   - evaluate: encodes at a quality and returns the size and similarity of the result.
    public func run(
        threshold: Double,
        evaluate: (Double) async throws -> Trial
    ) async throws -> Outcome {
        var trials: [Trial] = []
        var lo = range.lowerBound
        var hi = range.upperBound

        // First check the top of the range: if even that fails, nothing below will pass.
        let top = try await evaluate(hi)
        trials.append(top)
        guard top.score >= threshold else { return Outcome(best: nil, trials: trials) }

        while trials.count < maxTrials, hi - lo > tolerance {
            try Task.checkCancellation()
            let mid = (lo + hi) / 2
            let trial = try await evaluate(mid)
            trials.append(trial)
            if trial.score >= threshold {
                hi = mid
            } else {
                lo = mid
            }
        }

        let best = trials.filter { $0.score >= threshold }.min { $0.byteSize < $1.byteSize }
        return Outcome(best: best, trials: trials)
    }
}
