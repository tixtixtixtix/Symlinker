import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Symlinker

struct FileDropTests {
    @Test func acceptsOnlyLocalAbsoluteFileURLs() throws {
        let path = "/Users/test/A file é.txt"
        let url = URL(fileURLWithPath: path)
        #expect(FileDrop.url(from: url as NSURL) == url)
        #expect(FileDrop.url(from: path as NSString) == url)
        #expect(FileDrop.url(from: url.absoluteString as NSString) == url)
        #expect(FileDrop.url(from: Data(url.absoluteString.utf8) as NSData) == url)
        #expect(FileDrop.url(from: "https://example.com/file.txt" as NSString) == nil)
        #expect(FileDrop.url(from: "file://remote.example/share/file.txt" as NSString) == nil)
        #expect(FileDrop.url(from: "relative/file.txt" as NSString) == nil)
        #expect(FileDrop.url(from: "file:///tmp/file%00.txt" as NSString) == nil)
        #expect(FileDrop.url(from: "file:///tmp/file.txt?other" as NSString) == nil)
        #expect(FileDrop.url(from: Data([0xff, 0xfe]) as NSData) == nil)
        #expect(FileDrop.url(from: nil) == nil)
    }

    @Test @MainActor func nativeProviderLoadsFileURL() async throws {
        let url = URL(fileURLWithPath: "/Users/test/a file.txt")
        let provider = NSItemProvider(object: url as NSURL)
        let result = await FileDrop.load(provider)
        #expect(result == url)
    }

    @Test func providerCompletionIsExactlyOnce() async {
        let load = ProviderLoad()
        let url = URL(fileURLWithPath: "/selected.txt")
        let result = await withCheckedContinuation { continuation in
            #expect(load.install(continuation))
            load.finish(url)
            load.finish(nil)
            load.finish(URL(fileURLWithPath: "/stale.txt"))
        }
        #expect(result == url)
    }

    @Test func cancellationBeforeProviderRegistrationResumes() async {
        let load = ProviderLoad()
        load.finish(nil)
        let result = await withCheckedContinuation { continuation in
            #expect(!load.install(continuation))
        }
        #expect(result == nil)
    }

    @Test func providerDeadlineResumesWithoutCallback() async {
        let load = ProviderLoad(timeout: 0.01)
        let result = await withCheckedContinuation { continuation in
            #expect(load.install(continuation))
        }
        #expect(result == nil)
    }
}

@MainActor
struct SelectionAndLifecycleTests {
    private func fixture() throws -> (root: URL, source: URL, destination: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = root.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Original é.txt")
        try Data("untouched".utf8).write(to: source)
        return (root, source, destination)
    }

    @Test func newestSelectionWinsAndCanceledInputIsIgnored() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let model = SymlinkerDroplet()
        let old = try #require(model.beginSelection(.source))
        let current = try #require(model.beginSelection(.source))
        model.receiveSelection(f.destination, request: old)
        model.receiveSelection(f.source, request: current)
        await model.waitForSelections()
        #expect(model.source == f.source && model.loadingRoles.isEmpty)
        #expect(model.retainedSelectionCount == 1)
        let canceled = try #require(model.beginSelection(.source))
        model.cancelSelection(canceled)
        model.receiveSelection(f.destination, request: canceled)
        await model.waitForSelections()
        #expect(model.source == f.source)
        #expect(!model.wantsShelfOpen)
    }

    @Test func invalidSelectionPreservesPreviousPairAndCanRecover() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let model = SymlinkerDroplet()
        model.select(f.source, destination: false)
        model.select(f.destination, destination: true)
        await model.waitForSelections()
        #expect(model.canCreate && model.sessionState == .ready)
        model.select(f.source, destination: true)
        await model.waitForSelections()
        #expect(model.destination == f.destination && model.source == f.source)
        #expect(model.message != nil && model.issueRole == .destination)
        #expect(model.retainedSelectionCount == 2)
        model.select(f.destination, destination: true)
        await model.waitForSelections()
        #expect(model.message == nil && model.canCreate)
        model.clearSelection(.source)
        #expect(model.source == nil && model.destination == f.destination)
        #expect(model.retainedSelectionCount == 1 && !model.canCreate)
        model.reset()
        #expect(model.retainedSelectionCount == 0)
    }

    @Test func dropsUseSameValidationAndRejectMultipleItems() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let model = SymlinkerDroplet()
        let source = NSItemProvider(object: f.source as NSURL)
        let folder = NSItemProvider(object: f.destination as NSURL)
        #expect(model.acceptDrop([source], role: .source))
        #expect(model.acceptDrop([folder], role: .destination))
        await model.waitForSelections()
        #expect(model.source?.path == f.source.path && model.destination?.path == f.destination.path)
        #expect(model.canCreate)
        #expect(!model.acceptDrop([source, folder], role: .source))
        #expect(model.source?.path == f.source.path && model.destination?.path == f.destination.path)
        #expect(model.message == LinkError.multipleItems.localizedDescription)
        #expect(!model.acceptDrop([NSItemProvider(object: "text" as NSString)], role: .source))
        #expect(model.source == f.source)
    }

    @Test func navigationCancelsPendingInputButKeepsSelections() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let model = SymlinkerDroplet()
        model.select(f.source, destination: false)
        await model.waitForSelections()
        let first = UUID(), second = UUID()
        model.editorVisibility(first, visible: true)
        model.editorVisibility(second, visible: true)
        let request = try #require(model.beginSelection(.destination))
        #expect(model.wantsShelfOpen)
        model.editorVisibility(first, visible: false)
        #expect(model.isCurrent(request)) // Another visible surface still owns this input.
        model.editorVisibility(second, visible: false)
        #expect(!model.isCurrent(request) && !model.wantsShelfOpen)
        model.receiveSelection(f.destination, request: request)
        #expect(model.source == f.source && model.destination == nil)
        model.editorVisibility(UUID(), visible: true)
        #expect(model.source == f.source)
    }

    @Test func deactivationInvalidatesPendingCallbacksAndReleasesSelections() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let model = SymlinkerDroplet()
        model.select(f.source, destination: false)
        await model.waitForSelections()
        let request = try #require(model.beginSelection(.destination))
        model.deactivate()
        model.receiveSelection(f.destination, request: request)
        await model.waitForSelections()
        #expect(model.destination == nil && model.source == f.source)
        #expect(model.retainedSelectionCount == 0 && model.loadingRoles.isEmpty)
        #expect(!model.canInteract && !model.wantsShelfOpen)
    }

    @Test func replacingSelectionsDoesNotAccumulateAccess() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let model = SymlinkerDroplet()
        for _ in 0..<20 {
            model.select(f.source, destination: false)
            await model.waitForSelections()
        }
        #expect(model.retainedSelectionCount == 1)
        model.reset()
        #expect(model.retainedSelectionCount == 0)
    }

    @Test func rejectedDropInvalidatesOlderPendingDrop() async throws {
        let model = SymlinkerDroplet()
        let request = try #require(model.beginSelection(.source))
        #expect(!model.acceptDrop([], role: .source))
        #expect(!model.isCurrent(request) && model.loadingRoles.isEmpty)
        #expect(!model.wantsShelfOpen)
    }

    @Test func allWorkPhasesHaveConsistentShelfHoldPolicy() {
        let model = SymlinkerDroplet()
        #expect(!model.wantsShelfOpen)
        model.isPicking = true
        #expect(model.wantsShelfOpen && model.sessionState == .selecting)
        model.isPicking = false
        model.isCreating = true
        #expect(model.wantsShelfOpen && model.sessionState == .creating)
        model.isCreating = false
        model.createdLink = URL(fileURLWithPath: "/result.txt")
        #expect(!model.wantsShelfOpen && model.sessionState == .completed)
        model.deactivate()
        #expect(!model.wantsShelfOpen)
    }

    @Test func directorySymlinkDestinationAndPackagesKeepTheirMeaning() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let folderLink = f.root.appendingPathComponent("Folder link")
        try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: f.destination)
        let link = try SymbolicLink.create(source: f.source, destination: folderLink)
        #expect(try String(contentsOf: link, encoding: .utf8) == "untouched")
        let package = f.root.appendingPathComponent("Example.app", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let packageLink = try SymbolicLink.create(source: package, destination: f.destination)
        #expect(packageLink.resolvingSymlinksInPath() == package.resolvingSymlinksInPath())
        let selectedLink = f.root.appendingPathComponent("Selected link.txt")
        try FileManager.default.createSymbolicLink(at: selectedLink, withDestinationURL: f.source)
        let result = try SymbolicLink.create(source: selectedLink, destination: f.destination)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: result.path) == selectedLink.path)
    }

    @Test func concurrentCreatesNeverReplaceAnExistingItem() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let successes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask { (try? await FileIO.run { try SymbolicLink.create(source: f.source, destination: f.destination) }) != nil }
            }
            var count = 0
            for await succeeded in group { if succeeded { count += 1 } }
            return count
        }
        #expect(successes == 1)
        #expect(try String(contentsOf: f.destination.appendingPathComponent(f.source.lastPathComponent), encoding: .utf8) == "untouched")
    }

    @Test func movedSourceIsRevalidatedBeforeCreation() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let model = SymlinkerDroplet(tuning: .defaults)
        model.select(f.source, destination: false)
        model.select(f.destination, destination: true)
        await model.waitForSelections()
        #expect(model.canCreate)
        try FileManager.default.moveItem(at: f.source, to: f.root.appendingPathComponent("Moved.txt"))
        model.create(reducedMotion: true)
        await model.waitForOperation()
        #expect(model.message != nil && !model.isCreating && model.createdLink == nil)
        #expect(!model.wantsShelfOpen)
    }

    @Test func leavingDuringAnimationKeepsSuccessfulResult() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let model = SymlinkerDroplet(tuning: .defaults)
        let surface = UUID()
        model.editorVisibility(surface, visible: true)
        model.select(f.source, destination: false)
        model.select(f.destination, destination: true)
        await model.waitForSelections()
        model.create(reducedMotion: false)
        for _ in 0..<100 where model.workState != .animating { try await Task.sleep(for: .milliseconds(5)) }
        try #require(model.workState == .animating)
        model.editorVisibility(surface, visible: false)
        await model.waitForOperation()
        let link = try #require(model.createdLink)
        #expect(model.buttonReady && model.buttonConfirmed && !model.isCreating)
        #expect(!model.wantsShelfOpen && model.sessionState == .completed)
        #expect(try String(contentsOf: link, encoding: .utf8) == "untouched")
        model.editorVisibility(UUID(), visible: true)
        #expect(model.createdLink == link && model.source == f.source && model.destination == f.destination)
    }

    @Test func preflightDoesNotOverwriteOrConfuseOtherLinks() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let link = f.destination.appendingPathComponent(f.source.lastPathComponent)
        #expect(SymbolicLink.preflight(source: f.source, destination: f.destination) == .ready(link))
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/missing.txt")
        #expect(SymbolicLink.preflight(source: f.source, destination: f.destination) == .conflict(link, isSameLink: false))
        #expect(throws: LinkError.self) { try SymbolicLink.create(source: f.source, destination: f.destination) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "/missing.txt")
    }

    @Test func duplicateNoticeFadesButRetryStillRevalidates() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let link = try SymbolicLink.create(source: f.source, destination: f.destination)
        let model = SymlinkerDroplet(tuning: .defaults)
        model.conflictNoticeDuration = .milliseconds(10)
        model.editorVisibility(UUID(), visible: true)
        model.select(f.source, destination: false)
        model.select(f.destination, destination: true)
        await model.waitForSelections()
        #expect(model.hasTimedConflict && model.conflictNoticeVisible)
        await model.waitForConflictNotice()
        #expect(!model.conflictNoticeVisible && model.hasTimedConflict)
        #expect(!model.canCreate && model.canAttemptCreation && model.existingLink == link)
        model.create(reducedMotion: true)
        await model.waitForOperation()
        await model.waitForSelections()
        #expect(model.createdLink == nil && model.existingLink == link)
        #expect(try String(contentsOf: link, encoding: .utf8) == "untouched")
        await model.waitForConflictNotice()
        // Simulate the user resolving the conflict in Finder; cached preflight must not block a safe retry.
        try FileManager.default.removeItem(at: link)
        model.create(reducedMotion: true)
        await model.waitForOperation()
        #expect(model.createdLink == link && model.buttonReady)
        model.deactivate()
    }

    @Test func navigationCancelsNoticeTimerWithoutClearingConflict() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try SymbolicLink.create(source: f.source, destination: f.destination)
        let model = SymlinkerDroplet(tuning: .defaults)
        model.conflictNoticeDuration = .seconds(20)
        let id = UUID()
        model.editorVisibility(id, visible: true)
        model.select(f.source, destination: false)
        model.select(f.destination, destination: true)
        await model.waitForSelections()
        #expect(model.conflictNoticeVisible)
        model.editorVisibility(id, visible: false)
        await model.waitForConflictNotice()
        #expect(model.hasTimedConflict && model.conflictNoticeVisible && model.existingLink != nil)
        model.reset()
        #expect(!model.conflictNoticeVisible)
    }

    @Test func backgroundCompletionCannotMutateDisabledDroplet() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = CreationGate()
        let model = SymlinkerDroplet(tuning: .defaults)
        model.createLink = { source, destination in
            gate.wait()
            return try SymbolicLink.create(source: source, destination: destination)
        }
        model.select(f.source, destination: false)
        model.select(f.destination, destination: true)
        await model.waitForSelections()
        model.create(reducedMotion: false)
        let completion = Task { await model.waitForOperation() }
        for await _ in gate.started { break }
        model.deactivate()
        gate.release()
        await completion.value
        #expect(model.createdLink == nil && model.message == nil && !model.isCreating)
        #expect(model.retainedSelectionCount == 0 && !model.wantsShelfOpen)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.destination.appendingPathComponent(f.source.lastPathComponent).path) == f.source.path)
    }
}

/// Blocks only the dedicated filesystem queue, never the main actor or a cooperative executor.
private final class CreationGate: @unchecked Sendable {
    let started: AsyncStream<Void>
    private let didStart: AsyncStream<Void>.Continuation
    private let condition = NSCondition()
    private var released = false
    init() { (started, didStart) = AsyncStream.makeStream(of: Void.self) }
    func wait() {
        didStart.yield(()); didStart.finish()
        condition.lock()
        while !released { condition.wait() }
        condition.unlock()
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}
