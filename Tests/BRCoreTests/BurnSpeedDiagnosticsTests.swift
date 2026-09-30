import Testing

@testable import BRCore

struct BurnSpeedDiagnosticsTests {
    private func writing(speed: Double? = 8992, track: Int = 1) -> BurnSnapshot {
        var snapshot = BurnSnapshot()
        snapshot.phase = .writing
        snapshot.progress = 0.25
        snapshot.speedKB = speed
        snapshot.speedX = speed.map { $0 / 4496 }
        snapshot.track = track
        snapshot.currentSpeedRaw = "8992"
        snapshot.rawState = "DRStatusStateTrackWrite"
        return snapshot
    }

    @Test func throttlesCallbacksButKeepsBriefSlowdownsInTheRange() throws {
        var recorder = BurnSpeedDiagnostics()
        let first = try #require(recorder.record(writing(), at: 0).first)
        #expect(first.contains("8992.000 KB/s（8.992 MB/s）"))
        #expect(first.contains("2.000×"))
        #expect(first.contains("DRStatusCurrentSpeedKey(raw)=8992"))
        #expect(recorder.record(writing(speed: 4400), at: 1).isEmpty)
        #expect(recorder.record(writing(), at: 2).isEmpty)
        let summary = try #require(recorder.record(writing(), at: 15).first)
        #expect(summary.contains("本段最低–最高=4400.000–8992.000 KB/s"))
        #expect(summary.contains("回调数=3"))
        #expect(recorder.record(writing(speed: 0), at: 16).isEmpty)
        let stalled = try #require(recorder.record(writing(), at: 30).first)
        #expect(stalled.contains("本段最低–最高=0.000–8992.000 KB/s"))
    }

    @Test func missingReadingsStayUnknownAndTrackChangesHaveSeparateRanges() throws {
        var recorder = BurnSpeedDiagnostics()
        let absent = try #require(recorder.record(writing(speed: nil), at: 0).first)
        #expect(absent.contains("DRStatusProgressCurrentKPS=未提供"))
        #expect(absent.contains("本段最低–最高=未提供"))
        #expect(recorder.record(writing(speed: 4400), at: 1).isEmpty)
        let changed = recorder.record(writing(speed: 17984, track: 2), at: 2)
        #expect(changed.count == 2)
        #expect(changed[0].contains("轨道=1"))
        #expect(changed[0].contains("本段最低–最高=4400.000–4400.000 KB/s"))
        #expect(changed[1].contains("轨道=2"))
        #expect(changed[1].contains("本段最低–最高=17984.000–17984.000 KB/s"))
    }

    @Test func phaseExitFlushesLastWriteReadingWithoutCallingItVerificationSpeed() throws {
        for phase in [BurnPhase.verifying, .finishing, .failed, .cancelled, .completed] {
            var recorder = BurnSpeedDiagnostics()
            _ = recorder.record(writing(), at: 0)
            #expect(recorder.record(writing(speed: 4400), at: 3).isEmpty)
            var next = BurnSnapshot()
            next.phase = phase
            let final = try #require(recorder.record(next, at: 4).first)
            #expect(final.contains("采样点已用 00:00:03"))
            #expect(final.contains("状态=DRStatusStateTrackWrite"))
            #expect(final.contains("4400.000 KB/s"))
            #expect(recorder.record(next, at: 5).isEmpty)
            #expect(recorder.record(writing(), at: 6).count == 1)
        }
    }
}
