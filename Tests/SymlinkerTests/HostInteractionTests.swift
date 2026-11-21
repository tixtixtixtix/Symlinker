import AppKit
import SwiftUI
import Testing
import DroppyKit
import DroppyKitHarness
@testable import Symlinker

@MainActor
struct HostInteractionTests {
    private func session(for model: SymlinkerDroplet) throws -> HarnessSession {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(DropletManifest.self, from: Data(contentsOf: root.appendingPathComponent("droplet.json")))
        let session = HarnessSession(droplet: model, manifest: manifest, manifestProblem: nil)
        session.activate()
        #expect(session.activationError == nil)
        return session
    }

    @Test func navigationDoesNotDuplicatePresentationsOrClearTheSession() throws {
        let model = SymlinkerDroplet()
        let session = try session(for: model)
        defer { session.deactivate() }
        #expect(!session.recorder.isShelfHeldOpen)
        let source = URL(fileURLWithPath: "/selected/source.txt")
        model.source = source
        model.open()
        let first = try #require(session.host.notchSurface.expandedState.current)
        model.open()
        #expect(session.recorder.effects.filter { $0.service == "notchSurface" && $0.detail.hasPrefix("present") }.count == 1)
        session.host.notchSurface.dismissExpandedSurface("symlinker")
        #expect(model.source == source)
        model.open()
        let second = try #require(session.host.notchSurface.expandedState.current)
        #expect(first.id != second.id)
        model.expandedSurfaceDidDismiss("symlinker", presentation: first, reason: .dropletRequested)
        #expect(session.host.notchSurface.expandedState.current?.id == second.id)
        #expect(model.source == source && !session.recorder.isShelfHeldOpen)
    }

    @Test func revealAndClipboardUseHostServicesAndRespectGrants() throws {
        let model = SymlinkerDroplet()
        let session = try session(for: model)
        defer { session.deactivate() }
        let result = URL(fileURLWithPath: "/destination/result.txt")
        model.createdLink = result
        model.reveal()
        #expect(session.recorder.effects.contains { $0.service == "workspace" && $0.detail == "reveal \(result.path)" })
        #expect(model.canCopyPaths && model.copyText("selected path"))
        #expect(session.recorder.effects.contains { $0.service == "workspace" && $0.detail == "copy \"selected path\"" })
        session.setCapability(.clipboardWrite, granted: false)
        let count = session.recorder.effects.count
        #expect(!model.canCopyPaths && !model.copyText("not allowed"))
        #expect(session.recorder.effects.count == count)
    }

    @Test func holdsAreScopedToWorkRatherThanActivation() async throws {
        let model = SymlinkerDroplet()
        let session = try session(for: model)
        defer { session.deactivate() }
        #expect(!session.recorder.isShelfHeldOpen)
        let request = try #require(model.beginSelection(.source))
        #expect(session.recorder.isShelfHeldOpen)
        model.cancelSelection(request)
        #expect(!session.recorder.isShelfHeldOpen)
        #expect(session.recorder.effects.contains { $0.detail == "hold open" })
        #expect(session.recorder.effects.contains { $0.detail == "release hold" })
        #expect(!session.recorder.effects.contains { $0.wasRefused })
    }

    @Test func onlyExpandedEditorSuppressesAutomaticCollapse() throws {
        let model = SymlinkerDroplet()
        let session = try session(for: model)
        defer { session.deactivate() }
        let descriptor = try #require(model.expandedSurfaces.first { $0.id == "symlinker" })
        #expect(descriptor.suppresses == [.shelfWidgets, .autoCollapse])
        #expect(!session.recorder.isShelfHeldOpen)
        model.open()
        #expect(session.host.notchSurface.expandedState.current?.surfaceID == descriptor.id)
        // The presentation owns the suppression; no global shelf hold leaks into Widgets.
        #expect(!session.recorder.isShelfHeldOpen)
        session.host.notchSurface.dismissExpandedSurface("symlinker")
        #expect(session.host.notchSurface.expandedState.current == nil)
        #expect(!session.recorder.isShelfHeldOpen)
    }

    @Test func fullEditorHoldEndsOnNavigationAndDeactivation() throws {
        let model = SymlinkerDroplet()
        let session = try session(for: model)
        let compact = UUID(), first = UUID(), second = UUID()
        model.editorVisibility(compact, visible: true)
        #expect(!session.recorder.isShelfHeldOpen)
        model.editorVisibility(first, visible: true, keepsShelfOpen: true)
        model.editorVisibility(second, visible: true, keepsShelfOpen: true)
        #expect(session.recorder.isShelfHeldOpen)
        let request = try #require(model.beginSelection(.source))
        model.cancelSelection(request)
        #expect(session.recorder.isShelfHeldOpen)
        model.reset()
        #expect(session.recorder.isShelfHeldOpen)
        model.editorVisibility(first, visible: false)
        #expect(session.recorder.isShelfHeldOpen)
        model.editorVisibility(second, visible: false)
        #expect(!session.recorder.isShelfHeldOpen)
        model.editorVisibility(first, visible: true, keepsShelfOpen: true)
        session.deactivate()
        #expect(!model.wantsShelfOpen && !session.recorder.isShelfHeldOpen)
    }

    @Test(arguments: [false, true])
    func widgetMountKeepsOnlyFullEditorOpen(isPaired: Bool) async throws {
        let model = SymlinkerDroplet()
        let session = try session(for: model)
        defer { session.deactivate() }
        let context = ShelfWidgetContext(availableSize: CGSize(width: isPaired ? 210 : SymlinkerMetrics.soloWidth, height: 164), isPaired: isPaired)
        let view = NSHostingView(rootView: model.makeWidgetView("symlinker", context: context))
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: context.availableSize.width, height: 164), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.recorder.isShelfHeldOpen == !isPaired)
        // Mounting a screenshot must never acquire a hold.
        window.contentView = NSHostingView(rootView: model.makeWidgetView("symlinker", context: .init(availableSize: context.availableSize, isPreview: true)))
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!session.recorder.isShelfHeldOpen)
    }

    @Test func refusedExpandedSurfaceHasRecoverableFeedback() throws {
        let model = SymlinkerDroplet()
        let session = try session(for: model)
        defer { session.deactivate() }
        session.setCapability(.expandedSurface, granted: false)
        model.open()
        #expect(model.message != nil && session.host.notchSurface.expandedState.current == nil)
        #expect(session.recorder.effects.contains { $0.wasRefused && $0.service == "notchSurface" })
    }
}
