import AppKit
import Combine
import DroppyKit
import SwiftUI

@objc(SymlinkerPrincipal)
public final class SymlinkerPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }
    @MainActor public func makeDroplet() -> AnyObject { SymlinkerDroplet() }
}

@MainActor
public final class SymlinkerDroplet: NSObject, ObservableObject, Droplet {
    public nonisolated static let id: DropletID = "symlinker"
    @Published var tuning = AnimationTuning.load() { didSet { if !isDemo { tuning.save() } } }
    @Published var activeTuning: AnimationTuning?
    var renderingTuning: AnimationTuning { isCreating ? activeTuning ?? tuning : tuning }
    @Published var isScrubbing = false
    var isDemo = false
    private var playgroundWindow: NSWindow?
    private var playgroundDelegate: AnimationPlaygroundWindowDelegate?
    #if DEBUG
    var previewsPlayground = false
    #endif
    @Published var source: URL?
    @Published var destination: URL?
    @Published var createdLink: URL?
    @Published var message: String?
    @Published var isCreating = false
    @Published var progress: CGFloat = 0
    @Published var settled = false
    @Published var snapped = false
    @Published var recoil: CGFloat = 0
    @Published var rebound: CGFloat = 0
    @Published var continuousMotion = false
    @Published var buttonConfirmed = false
    @Published var buttonReady = false
    var hasSelectionPair: Bool { source != nil && destination != nil }
    var panelHeight: CGFloat { hasSelectionPair || message != nil ? 156 : 112 }
    @Published var isPicking = false
    private var host: DropletHost?
    private var operation: Task<Void, Never>?
    private var picker: NSOpenPanel?
    private var scopedURLs: [URL] = []
    var canCreate: Bool { source != nil && destination != nil && !isCreating && !isPicking && createdLink == nil }

    public func activate(host: DropletHost) throws { self.host = host }
    public func deactivate() {
        operation?.cancel(); operation = nil
        playgroundWindow?.close(); playgroundWindow = nil
        picker?.cancel(nil); picker = nil
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }; scopedURLs.removeAll()
        host?.shelf.setHoldsOpen(false)
        host = nil
    }
    func open() {
        _ = host?.notchSurface.presentExpandedSurface(.init(surfaceID: "symlinker", opensShelf: true))
    }
    func reveal() {
        if !isDemo, let createdLink { NSWorkspace.shared.activateFileViewerSelecting([createdLink]) }
    }
    func hold(_ value: Bool) { host?.shelf.setHoldsOpen(value) }
    func choose(destination choosingDestination: Bool) {
        guard !isDemo, !isCreating, !isPicking else { return }
        let panel = NSOpenPanel()
        panel.title = choosingDestination ? "Choose destination folder" : "Choose source file or folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = !choosingDestination
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        picker = panel; isPicking = true; hold(true)
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                if response == .OK, let url = panel.url { self.select(url, destination: choosingDestination) }
                self.picker = nil; self.isPicking = false; self.hold(false)
            }
        }
    }
    func select(_ url: URL, destination choosingDestination: Bool) {
        guard !isDemo, !isCreating, url.isFileURL else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            if choosingDestination && values.isDirectory != true {
                throw LinkError.destinationMustBeFolder
            }
            if scoped { scopedURLs.append(url) }
            withAnimation(DroppyAnimation.stateEmphasis) {
                if choosingDestination { destination = url } else { source = url }
                createdLink = nil; message = nil; progress = 0; settled = false; snapped = false; recoil = 0; rebound = 0; buttonConfirmed = false; buttonReady = false
            }
            host?.shelf.invalidateLayout(for: "symlinker")
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            message = error.localizedDescription
            host?.shelf.invalidateLayout(for: "symlinker")
        }
    }
    func reset() {
        guard !isCreating, !isPicking else { return }
        withAnimation(DroppyAnimation.state) {
            source = nil; destination = nil; createdLink = nil; message = nil; progress = 0; settled = false; snapped = false; recoil = 0; rebound = 0; buttonConfirmed = false; buttonReady = false
        }
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }; scopedURLs.removeAll()
        host?.shelf.invalidateLayout(for: "symlinker")
    }
    func create(reducedMotion: Bool) {
        guard !isDemo, canCreate, let source, let destination else { return }
        isCreating = true; message = nil; settled = false; hold(true)
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.isCreating = false; self.hold(false); self.operation = nil }
            do {
                // The filesystem succeeds before the visual confirmation begins.
                let link = try await Task.detached(priority: .userInitiated) {
                    try SymbolicLink.create(source: source, destination: destination)
                }.value
                guard !Task.isCancelled else { self.createdLink = link; self.buttonReady = true; self.buttonConfirmed = true; return }
                try await self.animate(link: link, reducedMotion: reducedMotion, settings: self.tuning)
            } catch is CancellationError {
                // Creation is atomic and must still be reflected after a cancelled animation.
                let link = destination.appendingPathComponent(source.lastPathComponent)
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil {
                    self.createdLink = link; self.settled = true; self.progress = 1; self.recoil = 1; self.rebound = 0; self.snapped = true; self.buttonConfirmed = true; self.buttonReady = true
                }
            } catch { self.message = error.localizedDescription; self.progress = 0 }
        }
    }
    private func animate(link: URL, reducedMotion: Bool, settings: AnimationTuning) async throws {
        activeTuning = settings
        continuousMotion = !reducedMotion
        try await Task.sleep(for: .milliseconds(16))
        // Publish actual elapsed progress rather than an implicit animation target.
        // Button and host transactions must never retime the tile sequence.
        let tileDuration = reducedMotion ? 0.35 : settings.totalDuration
        let splitTime = reducedMotion ? 0.35 : settings.stretchDuration + settings.splitDuration
        let finderTime = splitTime + max(reducedMotion ? 0.192 : settings.recoilDuration, settings.confirmationDuration)
        let endTime = max(tileDuration, finderTime + settings.finderDuration)
        let clock = ContinuousClock()
        let start = clock.now
        while true {
            try Task.checkCancellation()
            let components = start.duration(to: clock.now).components
            let elapsed = Double(components.seconds) + Double(components.attoseconds) / 1e18
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { progress = CGFloat(min(1, elapsed / tileDuration)) }
            if elapsed >= splitTime && !snapped {
                snapped = true; createdLink = link; recoil = 1; settled = true
                buttonConfirmed = true
            }
            if elapsed >= finderTime && !buttonReady { buttonReady = true }
            if elapsed >= endTime { break }
            try await Task.sleep(for: .milliseconds(8))
        }
    }
    func configureDemo() {
        isDemo = true
        source = URL(fileURLWithPath: "/Symlinker preview/Project notes.txt")
        destination = URL(fileURLWithPath: "/Symlinker preview/Workspace", isDirectory: true)
    }
    func replay(reducedMotion: Bool = false) {
        guard isDemo, !isCreating else { return }
        isScrubbing = false; createdLink = nil; progress = 0; snapped = false; recoil = 0
        rebound = 0; buttonConfirmed = false; buttonReady = false; settled = false; message = nil
        isCreating = true
        let settings = tuning
        let link = destination!.appendingPathComponent(source!.lastPathComponent)
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.isCreating = false; self.operation = nil }
            do { try await self.animate(link: link, reducedMotion: reducedMotion, settings: settings) }
            catch { /* Demo cancellation never examines or touches the filesystem. */ }
        }
    }
    func scrub(_ value: Double) {
        guard isDemo, !isCreating else { return }
        isScrubbing = true; continuousMotion = true
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) {
            progress = CGFloat(value)
            let clock = tuning.visualClock(progress)
            snapped = clock >= 0.38
            createdLink = snapped ? destination!.appendingPathComponent(source!.lastPathComponent) : nil
            buttonConfirmed = snapped; buttonReady = clock >= 0.70
        }
    }
    func openPlayground() {
        if let playgroundWindow { playgroundWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 650),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Symlinker animation playground"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 760, height: 590)
        window.contentView = NSHostingView(rootView: AnimationPlaygroundView(owner: self))
        let delegate = AnimationPlaygroundWindowDelegate { [weak self] in
            self?.playgroundWindow = nil; self?.playgroundDelegate = nil
        }
        playgroundDelegate = delegate; window.delegate = delegate
        window.center(); playgroundWindow = window
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

}

enum LinkError: LocalizedError {
    case destinationMustBeFolder, nameTaken, missingSource
    var errorDescription: String? {
        switch self {
        case .destinationMustBeFolder: "Choose a folder for the destination."
        case .nameTaken: "An item with this name already exists. Choose another folder."
        case .missingSource: "The source is unavailable. Choose it again."
        }
    }
}

enum SymbolicLink {
    static func create(source: URL, destination: URL) throws -> URL {
        let fm = FileManager.default
        guard source.isFileURL, fm.fileExists(atPath: source.path) else { throw LinkError.missingSource }
        var directory: ObjCBool = false
        guard destination.isFileURL, fm.fileExists(atPath: destination.path, isDirectory: &directory), directory.boolValue else {
            throw LinkError.destinationMustBeFolder
        }
        let link = destination.appendingPathComponent(source.lastPathComponent)
        // Detect broken symlinks as well as existing files. Never overwrite anything.
        if fm.fileExists(atPath: link.path) || (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil {
            throw LinkError.nameTaken
        }
        try fm.createSymbolicLink(at: link, withDestinationURL: source.standardizedFileURL)
        return link
    }
}

extension SymlinkerDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [.init(id: "symlinker", title: "Symlinker", systemImage: "link", layoutTraits: .init(
            preferredSoloWidth: 352, preferredPairedWidth: 210, contentHeight: .fixed(panelHeight)),
            searchKeywords: ["symlink", "symbolic link", "files"])]
    }
    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(Group {
            if context.isCompact {
                VStack(alignment: .leading, spacing: DroppySpacing.md) {
                    Image(systemName: "link").font(.system(size: 24, weight: .light))
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    Button("Open Symlinker") { self.open() }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
                .padding(context.contentInsets)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                SymlinkerPanel(model: self, isPreview: context.isPreview)
                    .padding(context.contentInsets)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        })
    }
    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? {
        AnyView(VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            Text("Preview and tune the animation without creating links.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Button("Animation playground…") { self.openPlayground() }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
        }.padding().frame(width: 260))
    }
}

extension SymlinkerDroplet: ExpandedSurfaceHosting, ExpandedSurfaceProviding {
    public var expandedSurfaceProvider: (any ExpandedSurfaceProviding)? { self }
    public var expandedSurfaces: [ExpandedSurfaceDescriptor] {
        [.init(id: "symlinker", title: "Symlinker", systemImage: "link", suppresses: [.shelfWidgets, .autoCollapse])]
    }
    public func makeExpandedSurfaceView(_ id: ExpandedSurfaceID, context: ExpandedSurfaceContext) -> AnyView {
        guard id == "symlinker" else { return AnyView(EmptyView()) }
        #if DEBUG
        if previewsPlayground { return AnyView(AnimationPlaygroundView(owner: self)) }
        #endif
        return AnyView(SymlinkerPanel(model: self, isPreview: context.isPreview)
            .padding(DroppySpacing.sm).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
    }
    public func expandedSurfaceSize(_ id: ExpandedSurfaceID, fitting proposal: ExpandedSurfaceSizeProposal) -> CGSize? {
        #if DEBUG
        if previewsPlayground { return CGSize(width: 820, height: 650) }
        #endif
        return CGSize(width: proposal.standardSize.width, height: panelHeight)
    }
}

#if DEBUG
public extension SymlinkerDroplet {
    func renderPlayground(to path: String) {
        let hosting = NSHostingView(rootView: AnimationPlaygroundView(owner: self).frame(width: 820, height: 650))
        hosting.frame = NSRect(x: 0, y: 0, width: 820, height: 650)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting; window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        RunLoop.main.run(until: Date().addingTimeInterval(0.9))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
    }
    /// Harness-only fixtures; never create files or links while rendering previews.
    func preparePreview(state: String, source: URL, destination: URL) {
        if state == "playground" { previewsPlayground = true; return }
        guard state != "idle" else { return }
        self.source = source
        if state != "source" { self.destination = destination }
        if state == "mitosis" { isCreating = true; continuousMotion = true; progress = 0.29 }
        if state == "success" {
            createdLink = destination.appendingPathComponent(source.lastPathComponent)
            progress = 1; settled = true; snapped = true; recoil = 1; buttonConfirmed = true; buttonReady = true
        }
        if state == "confirmed" {
            createdLink = destination.appendingPathComponent(source.lastPathComponent)
            progress = 1; snapped = true; recoil = 1; buttonConfirmed = true
        }
        if state == "rebound" {
            isCreating = true; continuousMotion = true; progress = 0.65; snapped = true; recoil = 1; rebound = 1
            createdLink = destination.appendingPathComponent(source.lastPathComponent)
            buttonConfirmed = true
        }
        if state == "flow" {
            isCreating = true; continuousMotion = true; progress = 0.65
            createdLink = destination.appendingPathComponent(source.lastPathComponent)
            buttonConfirmed = true
        }
        if state == "snapped" { isCreating = true; continuousMotion = true; progress = 0.41; snapped = true; recoil = 0.45 }
        if state == "error" { message = LinkError.nameTaken.localizedDescription }
    }
}
#endif
