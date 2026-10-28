import Testing
@testable import MediaSlimCore

@Suite("Quality search")
struct QualitySearchTests {
    /// A fake encoder: size grows linearly with quality, score rises smoothly.
    static func fakeEncoder(_ q: Double) -> QualitySearch.Trial {
        QualitySearch.Trial(quality: q, byteSize: Int64(1_000 + q * 9_000), score: 0.90 + q * 0.1)
    }

    @Test("Finds the lowest quality that passes")
    func findsBoundary() async throws {
        let search = QualitySearch(range: 0.0...1.0, tolerance: 0.01, maxTrials: 20)
        // Passes when 0.90 + q*0.1 >= 0.98, i.e. q >= 0.8.
        let outcome = try await search.run(threshold: 0.98) { Self.fakeEncoder($0) }
        let best = try #require(outcome.best)
        #expect(best.score >= 0.98)
        #expect(best.quality >= 0.8 && best.quality < 0.82)
    }

    @Test("Returns nil when even the top quality fails")
    func nothingPasses() async throws {
        let search = QualitySearch()
        let outcome = try await search.run(threshold: 0.9999) { Self.fakeEncoder($0) }
        #expect(outcome.best == nil)
        #expect(outcome.trials.count == 1)
    }

    @Test("Respects the trial budget")
    func trialBudget() async throws {
        let search = QualitySearch(range: 0.0...1.0, tolerance: 0.0001, maxTrials: 4)
        let outcome = try await search.run(threshold: 0.95) { Self.fakeEncoder($0) }
        #expect(outcome.trials.count == 4)
    }

    @Test("Picks the smallest passing trial even if scores are not monotonic")
    func nonMonotonic() async throws {
        let search = QualitySearch(range: 0.0...1.0, tolerance: 0.05, maxTrials: 10)
        let outcome = try await search.run(threshold: 0.95) { q in
            // A dip around 0.5 that fails, surrounded by passes.
            let score = (0.45...0.55).contains(q) ? 0.90 : 0.97
            return QualitySearch.Trial(quality: q, byteSize: Int64(q * 1_000), score: score)
        }
        let best = try #require(outcome.best)
        #expect(best.score >= 0.95)
        let passing = outcome.trials.filter { $0.score >= 0.95 }
        #expect(best.byteSize == passing.map(\.byteSize).min())
    }
}
