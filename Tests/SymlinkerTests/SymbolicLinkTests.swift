import Foundation
import Testing
@testable import Symlinker

struct SymbolicLinkTests {
    func fixture(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = root.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, destination)
    }
    @Test func originalRemainsAndLinkResolves() throws {
        try fixture { root, destination in
            let source = root.appendingPathComponent("A file with spaces.txt")
            try Data("original".utf8).write(to: source)
            let link = try SymbolicLink.create(source: source, destination: destination)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == source.path)
            #expect(try String(contentsOf: link, encoding: .utf8) == "original")
            #expect(try String(contentsOf: source, encoding: .utf8) == "original")
        }
    }
    @Test func directoryLink() throws {
        try fixture { root, destination in
            let source = root.appendingPathComponent("Original folder")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let link = try SymbolicLink.create(source: source, destination: destination)
            #expect(link.resolvingSymlinksInPath() == source.resolvingSymlinksInPath())
        }
    }
    @Test func existingFileIsNeverOverwritten() throws {
        try fixture { root, destination in
            let source = root.appendingPathComponent("notes.txt")
            try Data("source".utf8).write(to: source)
            let existing = destination.appendingPathComponent(source.lastPathComponent)
            try Data("preserve me".utf8).write(to: existing)
            #expect(throws: LinkError.self) { try SymbolicLink.create(source: source, destination: destination) }
            #expect(try String(contentsOf: existing, encoding: .utf8) == "preserve me")
        }
    }
    @Test func brokenLinkIsNeverOverwritten() throws {
        try fixture { root, destination in
            let source = root.appendingPathComponent("notes.txt")
            try Data().write(to: source)
            let existing = destination.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.createSymbolicLink(atPath: existing.path, withDestinationPath: "/missing/linkdrop-test")
            #expect(throws: LinkError.self) { try SymbolicLink.create(source: source, destination: destination) }
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: existing.path) == "/missing/linkdrop-test")
        }
    }
    @Test func invalidDestinationAndMissingSource() throws {
        try fixture { root, destination in
            let source = root.appendingPathComponent("file.txt")
            #expect(throws: LinkError.self) { try SymbolicLink.create(source: source, destination: destination) }
            try Data().write(to: source)
            #expect(throws: LinkError.self) { try SymbolicLink.create(source: source, destination: source) }
        }
    }
}

@MainActor
struct SymlinkerFlowTests {
    @Test(arguments: [false, true])
    func confirmationThenFinderAndResetPreservesLink(reducedMotion: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = root.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Original.txt")
        try Data("original".utf8).write(to: source)
        let model = SymlinkerDroplet()
        #expect(model.panelHeight == 112)
        model.select(source, destination: false)
        #expect(model.panelHeight == 112)
        model.select(destination, destination: true)
        #expect(model.panelHeight == 156)
        model.create(reducedMotion: reducedMotion)
        model.create(reducedMotion: reducedMotion) // Repeat presses cannot create a second operation.
        for _ in 0..<100 where !model.buttonConfirmed { try await Task.sleep(for: .milliseconds(30)) }
        #expect(model.buttonConfirmed)
        #expect(!model.buttonReady)
        for _ in 0..<100 where model.isCreating { try await Task.sleep(for: .milliseconds(30)) }
        #expect(model.buttonReady)
        #expect(model.message == nil)
        let link = try #require(model.createdLink)
        model.reset()
        #expect(model.source == nil && model.destination == nil && !model.buttonReady)
        #expect(model.panelHeight == 112)
        #expect(try String(contentsOf: link, encoding: .utf8) == "original")
    }
}

@MainActor
struct AnimationPlaygroundTests {
    private func springOvershootBound(_ settings: AnimationTuning) -> CGFloat {
        let decay = CGFloat(settings.damping) * 0.85
        let frequency = 7.5 + CGFloat(settings.rebound) * 0.8
        return exp(-decay * .pi / frequency)
    }

    private func reboundBound(_ settings: AnimationTuning) -> CGFloat {
        let decay = CGFloat(settings.damping) * 0.25
        let peak = atan(2 * .pi / decay) / .pi
        return CGFloat(settings.rebound) * 0.07 * pow(sin(.pi * peak), 2) * exp(-decay * peak)
    }

    @Test func demoReplayAndScrubbingNeverCreateLinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Original.txt")
        try Data("untouched".utf8).write(to: source)
        let demo = SymlinkerDroplet()
        demo.configureDemo()
        demo.source = source; demo.destination = destination
        var settings = AnimationTuning.defaults
        settings.stretchDuration = 0.05; settings.splitDuration = 0.05
        settings.recoilDuration = 0.05; settings.settleDuration = 0.05
        settings.confirmationDuration = 0.05; settings.finderDuration = 0.05
        demo.tuning = settings
        demo.create(reducedMotion: false)
        #expect(!demo.isCreating)
        demo.replay()
        for _ in 0..<20 where demo.activeTuning == nil { try await Task.sleep(for: .milliseconds(2)) }
        #expect(demo.renderingTuning == settings)
        var nextReplay = settings; nextReplay.stretchDuration = 2
        demo.tuning = nextReplay
        #expect(demo.renderingTuning == settings) // Editing cannot retime a running replay.
        for _ in 0..<100 where demo.isCreating { try await Task.sleep(for: .milliseconds(10)) }
        #expect(demo.buttonReady && !demo.isCreating)
        demo.scrub(0.3)
        #expect(demo.isScrubbing)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        #expect(try String(contentsOf: source, encoding: .utf8) == "untouched")
    }
    @Test func liveReplayKeepsRecoilAndSettleClockDuringButtonChanges() async throws {
        let demo = SymlinkerDroplet()
        demo.configureDemo()
        var settings = AnimationTuning.defaults
        settings.stretchDuration = 0.05; settings.splitDuration = 0.05
        settings.recoilDuration = 1; settings.settleDuration = 1
        settings.confirmationDuration = 0.05; settings.finderDuration = 0.05
        demo.tuning = settings
        demo.replay()
        for _ in 0..<100 where !demo.snapped { try await Task.sleep(for: .milliseconds(10)) }
        #expect(demo.snapped && demo.buttonConfirmed)
        #expect(demo.progress < 0.15) // The published value is elapsed time, not the final target.
        try await Task.sleep(for: .milliseconds(350))
        let recoilClock = settings.visualClock(demo.progress)
        #expect(recoilClock > 0.38 && recoilClock < 0.70)
        #expect(settings.returnAmount(at: recoilClock) > 0)
        #expect(settings.returnAmount(at: recoilClock) <= 1 + springOvershootBound(settings))
        #expect(!demo.buttonReady)
        for _ in 0..<150 where !demo.buttonReady { try await Task.sleep(for: .milliseconds(10)) }
        #expect(demo.buttonReady && demo.isCreating)
        #expect(demo.progress > 0.5 && demo.progress < 0.7)
        try await Task.sleep(for: .milliseconds(350))
        #expect(demo.isCreating && demo.progress < 0.9)
        #expect(abs(settings.reboundAmount(at: settings.visualClock(demo.progress))) <= reboundBound(settings))
        for _ in 0..<150 where demo.isCreating { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!demo.isCreating && demo.progress == 1)
    }

    @Test func sourceStretchesFullyBeforeCopiesAppear() {
        let settings = AnimationTuning.defaults
        #expect(settings.isValid)
        #expect(settings.confirmationDuration == 0.5 && settings.finderDuration == 0.5)
        #expect(settings.stretchDuration == 0.34 && settings.splitDuration == 0.22)
        #expect(settings.recoilDuration == 0.22 && settings.settleDuration == 0.32)
        #expect(abs(settings.totalDuration - 1.10) < 0.000001)
        #expect(settings.blur == 5 && settings.rebound == 2.2 && settings.damping == 5.74)
        #expect(settings.squash == 0.20 && settings.splitSoftness == 0.03 && settings.trails == 0)
        for step in 0...100 {
            let elapsed = settings.stretchDuration * Double(step) / 100
            let clock = settings.visualClock(CGFloat(elapsed / settings.totalDuration))
            #expect(settings.splitAmount(at: clock) < 0.00001)
        }
        let stretchEnd = settings.visualClock(CGFloat(settings.stretchDuration / settings.totalDuration))
        #expect(abs(settings.stretchAmount(at: stretchEnd) - 1) < 0.00001)
        #expect(abs(settings.splitAmount(at: 0.38) - 1) < 0.00001)
        #expect(abs(settings.splitAmount(at: 0.33) - 0.5) < 0.00001)
        #expect(settings.splitAmount(at: 0.31) < 0.4)
        #expect(settings.splitAmount(at: 0.36) < 0.95)
    }

    @Test func recoilAndSettleOccupyTheirOwnDurations() {
        var settings = AnimationTuning.defaults
        settings.recoilDuration = 3; settings.settleDuration = 4
        #expect(settings.isValid)
        let start = settings.stretchDuration + settings.splitDuration
        let end = start + settings.recoilDuration
        func clock(_ seconds: Double) -> CGFloat { settings.visualClock(CGFloat(seconds / settings.totalDuration)) }
        #expect(abs(settings.returnAmount(at: clock(start))) < 0.00001)
        let halfway = settings.returnAmount(at: clock(start + settings.recoilDuration / 2))
        #expect(halfway > 0.2 && halfway <= 1 + springOvershootBound(settings))
        #expect(abs(settings.returnAmount(at: clock(end)) - 1) <= springOvershootBound(settings))
        #expect(abs(settings.reboundAmount(at: clock(end))) <= reboundBound(settings))
        let before = settings.returnAmount(at: clock(end - 0.0001))
        let after = settings.returnAmount(at: clock(end + 0.0001))
        #expect(abs(after - before) < 0.0001)
        #expect(abs(settings.reboundAmount(at: clock(settings.totalDuration))) < 0.00001)
        #expect(abs(settings.returnAmount(at: clock(settings.totalDuration)) - 1) < 0.00001)
    }
    @Test func independentPhaseClockStaysContinuousAndMonotone() {
        var settings = AnimationTuning.defaults
        settings.stretchDuration = 0.05; settings.splitDuration = 2
        settings.recoilDuration = 0.11; settings.settleDuration = 1.37
        #expect(settings.isValid)
        #expect(settings.visualClock(0) == 0)
        #expect(abs(settings.visualClock(1) - 1) < 0.000001)
        var previous: CGFloat = 0
        for i in 1...1000 {
            let value = settings.visualClock(CGFloat(i) / 1000)
            #expect(value >= previous && value <= 1.000001)
            previous = value
        }
        #expect(settings.summary.contains("Split: 2.00 s"))
    }

    @Test func springStartsAtRestAndSettlesWithoutAnEndpointSnap() {
        let settings = AnimationTuning.defaults
        let step: CGFloat = 0.00001
        #expect(settings.returnAmount(at: 0.38) == 0)
        #expect(settings.returnAmount(at: 1) == 1)
        #expect(abs(settings.returnAmount(at: 0.38 + step) / step) < 0.01)
        #expect(abs((1 - settings.returnAmount(at: 1 - step)) / step) < 0.01)
        for i in 0...1000 {
            let clock = CGFloat(i) / 1000
            let response = settings.returnAmount(at: clock)
            #expect(response.isFinite && response >= 0 && response <= 1 + springOvershootBound(settings))
            #expect(abs(settings.reboundAmount(at: clock)) <= reboundBound(settings))
        }
    }

    @Test func scrubUsesPlaybackMilestonesAndClampsInvalidInput() {
        let demo = SymlinkerDroplet()
        demo.configureDemo()
        var settings = AnimationTuning.defaults
        settings.stretchDuration = 0.1; settings.splitDuration = 0.1
        settings.recoilDuration = 0.05; settings.settleDuration = 0.05
        settings.confirmationDuration = 1
        demo.tuning = settings
        demo.scrub(1)
        #expect(demo.buttonConfirmed && !demo.buttonReady)
        demo.scrub(.infinity)
        #expect(demo.progress == 0 && !demo.buttonConfirmed)
        demo.scrub(-1)
        #expect(demo.progress == 0)
        demo.scrub(2)
        #expect(demo.progress == 1)
        demo.scrub(0.5, reducedMotion: true)
        #expect(!demo.continuousMotion && !demo.buttonConfirmed)
    }
}
