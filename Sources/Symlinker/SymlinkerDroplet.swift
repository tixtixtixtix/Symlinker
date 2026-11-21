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
    @Published var tuning = AnimationTuning.load() { didSet { if !isDemo && savesTuning { tuning.save() } } }
    private var savesTuning = true
    public override init() { super.init() }
    /// Tests use a deterministic preset without reading timing assumptions from, or writing to, user preferences.
    init(tuning: AnimationTuning) {
        super.init()
        savesTuning = false
        self.tuning = tuning
    }
    @Published var activeTuning: AnimationTuning?
    var renderingTuning: AnimationTuning { activeTuning ?? tuning }
    @Published var isScrubbing = false
    var isDemo = false
    private var playgroundWindow: NSWindow?
    private var playgroundDelegate: AnimationPlaygroundWindowDelegate?
    #if DEBUG
    var previewsPlayground = false
    private var isPreviewFixture = false
    private var previewsReducedMotion = false
    #endif
    var reducesPreviewMotion: Bool {
        #if DEBUG
        previewsReducedMotion
        #else
        false
        #endif
    }
    @Published var source: URL?
    @Published var destination: URL?
    @Published var createdLink: URL?
    @Published var message: String?
    enum WorkState: Equatable { case idle, picking(SelectionRole), creating, animating }
    @Published private(set) var workState: WorkState = .idle
    var isCreating: Bool {
        get { workState == .creating || workState == .animating }
        set { workState = newValue ? .animating : .idle }
    }
    @Published var progress: CGFloat = 0
    @Published var settled = false
    @Published var snapped = false
    @Published var recoil: CGFloat = 0
    @Published var rebound: CGFloat = 0
    @Published var continuousMotion = false
    @Published var buttonConfirmed = false
    @Published var buttonReady = false
    var hasSelectionPair: Bool { source != nil && destination != nil }
    var hasFooter: Bool { hasSelectionPair || message != nil }
    var panelHeight: CGFloat { SymlinkerMetrics.panelHeight(hasFooter: hasFooter) }
    var isPicking: Bool {
        get { if case .picking = workState { true } else { false } }
        set { workState = newValue ? .picking(.source) : .idle }
    }
    @Published private(set) var loadingRoles: Set<SelectionRole> = []
    @Published private(set) var preflight: PreflightState = .none
    @Published private(set) var conflictNoticeVisible = false
    var conflictNoticeDuration: Duration = .seconds(6)
    private var conflictNoticeTask: Task<Void, Never>?
    private var noticedConflict: URL?
    @Published private(set) var issueRole: SelectionRole?
    private var host: DropletHost?
    private var operation: Task<Void, Never>?
    private var picker: NSOpenPanel?
    private var expandedPresentation: ExpandedSurfacePresentation?
    private var leases: [SelectionRole: SecurityScopeLease] = [:]
    private var selectionRequests: [SelectionRole: SelectionRequest] = [:]
    private var selectionTasks: [SelectionRole: Task<Void, Never>] = [:]
    private var preflightTask: Task<Void, Never>?
    private var generation = UUID()
    private var operationID: UUID?
    private var acceptsInteractions = true
    private var visibleEditors: Set<UUID> = []
    private var visibleDropEditors: Set<UUID> = []
    private var holdsShelfOpen = false
    var wantsShelfOpen: Bool { acceptsInteractions && !isDemo && (!visibleDropEditors.isEmpty || isCreating || isPicking || !loadingRoles.isEmpty) }
    var retainedSelectionCount: Int { leases.count }
    var canCopyPaths: Bool { acceptsInteractions && !isDemo && host?.isGranted(.clipboardWrite) == true }
    private var lastDirectories: [SelectionRole: URL] = [:]
    // Injectable syscall for deterministic lifecycle tests; always runs on FileIO's queue.
    var createLink: @Sendable (URL, URL) throws -> URL = { try SymbolicLink.create(source: $0, destination: $1) }

    var canInteract: Bool { acceptsInteractions && !isDemo && !isCreating && !isPicking }
    var canAttemptCreation: Bool { canInteract && hasSelectionPair && loadingRoles.isEmpty && createdLink == nil && preflight != .checking }
    var canCreate: Bool { canAttemptCreation && preflight.canCreate }
    var outputURL: URL? { guard let source, let destination else { return nil }; return destination.appendingPathComponent(source.lastPathComponent) }
    var existingLink: URL? { if case .conflict(let url, true) = preflight { url } else { nil } }
    var hasTimedConflict: Bool { createdLink == nil && message == nil && preflight.conflictURL != nil }
    var sessionState: SessionState {
        if isCreating { return .creating }
        if isPicking || !loadingRoles.isEmpty || preflight == .checking { return .selecting }
        if message != nil { return .needsAttention }
        if createdLink != nil { return .completed }
        switch preflight {
        case .conflict, .invalid: return .needsAttention
        default: return hasSelectionPair ? .ready : .empty
        }
    }
    var statusTitle: String {
        switch sessionState {
        case .creating: return workState == .creating ? "Creating link…" : "Link created"
        case .completed: return "Symlink created"
        case .selecting: return isPicking ? "Choosing a location…" : "Checking selection…"
        case .needsAttention:
            if hasTimedConflict && !conflictNoticeVisible { return "Change destination" }
            return existingLink != nil ? "Link already exists" : "Selection needs attention"
        case .ready: return "Ready to create"
        case .empty: return source == nil ? "Choose a source" : "Choose a destination"
        }
    }

    public func activate(host: DropletHost) throws {
        self.host = host
        acceptsInteractions = true
        if let source { leases[.source] = SecurityScopeLease(url: source) }
        if let destination { leases[.destination] = SecurityScopeLease(url: destination) }
        updateShelfHold()
        refreshPreflight()
    }
    public func deactivate() {
        acceptsInteractions = false
        generation = UUID(); operationID = nil
        invalidateSelections()
        preflightTask?.cancel(); preflightTask = nil
        conflictNoticeTask?.cancel(); conflictNoticeTask = nil
        operation?.cancel(); operation = nil
        if createdLink != nil { finishConfirmation() }
        workState = .idle
        playgroundWindow?.close(); playgroundWindow = nil
        picker?.cancel(nil); picker = nil
        leases.removeAll()
        visibleEditors.removeAll()
        visibleDropEditors.removeAll()
        if holdsShelfOpen { host?.shelf.setHoldsOpen(false) }
        holdsShelfOpen = false
        if host?.notchSurface.expandedState.current?.dropletID == Self.id {
            host?.notchSurface.dismissExpandedSurface("symlinker")
        }
        expandedPresentation = nil
        host = nil
    }
    func open() {
        guard acceptsInteractions, !isDemo else { return }
        if let current = host?.notchSurface.expandedState.current,
           current.dropletID == Self.id, current.surfaceID == "symlinker" { return }
        expandedPresentation = host?.notchSurface.presentExpandedSurface(.init(surfaceID: "symlinker", opensShelf: true))
        if expandedPresentation == nil {
            message = "Symlinker could not open here. Try opening it from the Widgets page."
        }
    }
    func reveal() {
        if let url = createdLink ?? existingLink { reveal(url) }
    }
    func reveal(_ url: URL) {
        guard acceptsInteractions, !isDemo else { return }
        host?.workspace.revealInFinder(url)
    }
    func copyPath(_ url: URL) {
        _ = copyText(url.path)
    }
    @discardableResult func copyText(_ text: String) -> Bool {
        guard canCopyPaths else { return false }
        return host?.workspace.copyToPasteboard(text) ?? false
    }
    func editorVisibility(_ id: UUID, visible: Bool, keepsShelfOpen: Bool = false) {
        if visible {
            visibleEditors.insert(id)
            if keepsShelfOpen { visibleDropEditors.insert(id) }
            refreshPreflight()
        }
        else {
            visibleEditors.remove(id)
            visibleDropEditors.remove(id)
            if visibleEditors.isEmpty {
                invalidateSelections(); picker?.cancel(nil); picker = nil
                conflictNoticeTask?.cancel(); conflictNoticeTask = nil
                if isPicking { workState = .idle }
                if workState == .animating { operation?.cancel() }
            }
        }
        updateShelfHold()
    }
    private func updateShelfHold() {
        guard host != nil else { holdsShelfOpen = false; return }
        let hold = wantsShelfOpen
        guard hold != holdsShelfOpen else { return }
        holdsShelfOpen = hold
        host?.shelf.setHoldsOpen(hold)
    }
    func choose(destination choosingDestination: Bool) {
        let role: SelectionRole = choosingDestination ? .destination : .source
        guard canInteract, let request = beginSelection(role) else { return }
        let panel = NSOpenPanel()
        panel.title = choosingDestination ? "Choose destination folder" : "Choose source file or folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = !choosingDestination
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = choosingDestination ? destination ?? lastDirectories[role] : source?.deletingLastPathComponent() ?? lastDirectories[role]
        picker = panel; workState = .picking(role); updateShelfHold()
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self, self.isCurrent(request), self.picker === panel else { return }
                self.picker = nil; self.workState = .idle
                if response == .OK, let url = panel.url { self.receiveSelection(url, request: request) }
                else { self.cancelSelection(request) }
                self.updateShelfHold()
            }
        }
    }
    func select(_ url: URL, destination choosingDestination: Bool) {
        guard let request = beginSelection(choosingDestination ? .destination : .source) else { return }
        receiveSelection(url, request: request)
    }

    func beginSelection(_ role: SelectionRole) -> SelectionRequest? {
        guard canInteract else { return nil }
        selectionTasks[role]?.cancel()
        let request = SelectionRequest(generation: generation, role: role)
        selectionRequests[role] = request
        loadingRoles.insert(role)
        updateShelfHold()
        return request
    }
    func isCurrent(_ request: SelectionRequest) -> Bool {
        acceptsInteractions && !isCreating && request.generation == generation && selectionRequests[request.role] == request
    }
    func cancelSelection(_ request: SelectionRequest) {
        guard isCurrent(request) else { return }
        selectionRequests.removeValue(forKey: request.role)
        selectionTasks.removeValue(forKey: request.role)?.cancel()
        loadingRoles.remove(request.role)
        updateShelfHold()
    }
    func receiveSelection(_ url: URL, request: SelectionRequest) {
        guard isCurrent(request) else { return }
        let lease = SecurityScopeLease(url: url)
        selectionTasks[request.role] = Task { [weak self] in
            do {
                try await FileIO.run { try SymbolicLink.validateSelection(url, role: request.role); withExtendedLifetime(lease) {} }
                guard !Task.isCancelled, let self, self.isCurrent(request) else { return }
                self.leases[request.role] = lease
                self.lastDirectories[request.role] = request.role == .source ? url.deletingLastPathComponent() : url
                if request.role == .source { self.source = url } else { self.destination = url }
                self.clearPresentation()
                self.completeSelection(request)
                self.refreshPreflight()
            } catch {
                guard !Task.isCancelled, let self, self.isCurrent(request) else { return }
                self.reportSelectionIssue(error.localizedDescription, role: request.role)
                self.completeSelection(request)
            }
        }
    }
    private func completeSelection(_ request: SelectionRequest) {
        selectionRequests.removeValue(forKey: request.role)
        selectionTasks.removeValue(forKey: request.role)
        loadingRoles.remove(request.role)
        updateShelfHold()
        host?.shelf.invalidateLayout(for: "symlinker")
    }
    private func invalidateSelections() {
        selectionRequests.removeAll()
        selectionTasks.values.forEach { $0.cancel() }; selectionTasks.removeAll()
        loadingRoles.removeAll()
        updateShelfHold()
    }
    func acceptDrop(_ providers: [NSItemProvider], role: SelectionRole) -> Bool {
        guard canInteract else { return false }
        guard providers.count == 1, let provider = providers.first else {
            if let request = selectionRequests[role] { cancelSelection(request) }
            reportSelectionIssue(LinkError.multipleItems.localizedDescription, role: role); return false
        }
        guard provider.hasItemConformingToTypeIdentifier("public.file-url"), let request = beginSelection(role) else {
            if let request = selectionRequests[role] { cancelSelection(request) }
            reportSelectionIssue(LinkError.invalidDrop.localizedDescription, role: role); return false
        }
        selectionTasks[role] = Task { [weak self] in
            let url = await FileDrop.load(provider)
            guard !Task.isCancelled, let self, self.isCurrent(request) else { return }
            if let url { self.receiveSelection(url, request: request) }
            else { self.reportSelectionIssue(LinkError.invalidDrop.localizedDescription, role: role); self.completeSelection(request) }
        }
        return true
    }
    func reportSelectionIssue(_ text: String, role: SelectionRole) {
        guard acceptsInteractions, !isCreating, !isDemo else { return }
        message = text; issueRole = role
        host?.shelf.invalidateLayout(for: "symlinker")
    }
    func clearSelection(_ role: SelectionRole) {
        guard canInteract else { return }
        invalidateSelections()
        if role == .source { source = nil } else { destination = nil }
        leases.removeValue(forKey: role)
        clearPresentation(); refreshPreflight()
        host?.shelf.invalidateLayout(for: "symlinker")
    }
    private func clearPresentation() {
        conflictNoticeTask?.cancel(); conflictNoticeTask = nil
        noticedConflict = nil; conflictNoticeVisible = false
        activeTuning = nil; isScrubbing = false; continuousMotion = false
        createdLink = nil; message = nil; issueRole = nil; progress = 0; settled = false; snapped = false
        recoil = 0; rebound = 0; buttonConfirmed = false; buttonReady = false
    }
    func refreshPreflight() {
        #if DEBUG
        guard !isPreviewFixture else { return }
        #endif
        preflightTask?.cancel()
        guard acceptsInteractions, !isDemo, !isCreating, createdLink == nil,
              let source, let destination else { applyPreflight(.none); return }
        applyPreflight(.checking)
        let generation = generation
        let resources = Array(leases.values)
        preflightTask = Task { [weak self] in
            let result = try? await FileIO.run { withExtendedLifetime(resources) { SymbolicLink.preflight(source: source, destination: destination) } }
            guard !Task.isCancelled, let self, self.acceptsInteractions, self.generation == generation,
                  self.source == source, self.destination == destination, self.createdLink == nil, let result else { return }
            self.applyPreflight(result)
            self.host?.shelf.invalidateLayout(for: "symlinker")
        }
    }
    /// Also used by tests to await the same asynchronous pipeline as picker and drop input.
    func waitForSelections() async {
        while !selectionTasks.isEmpty { for task in Array(selectionTasks.values) { await task.value } }
        await preflightTask?.value
    }
    func waitForOperation() async { await operation?.value }
    func waitForConflictNotice() async { await conflictNoticeTask?.value }

    private func applyPreflight(_ result: PreflightState) {
        conflictNoticeTask?.cancel(); conflictNoticeTask = nil
        preflight = result
        if let url = result.conflictURL {
            if noticedConflict != url { noticedConflict = url; conflictNoticeVisible = true }
            startConflictNoticeTimer(for: url)
        } else if result != .checking {
            noticedConflict = nil; conflictNoticeVisible = false
        }
    }
    private func startConflictNoticeTimer(for url: URL) {
        #if DEBUG
        guard !isPreviewFixture else { return }
        #endif
        guard conflictNoticeVisible, !visibleEditors.isEmpty, acceptsInteractions else { return }
        let duration = conflictNoticeDuration
        conflictNoticeTask = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard !Task.isCancelled, let self, self.acceptsInteractions,
                  self.noticedConflict == url, self.preflight.conflictURL == url else { return }
            self.conflictNoticeVisible = false
            self.conflictNoticeTask = nil
        }
    }
    func reset(keepingSelections: Bool = false, reducedMotion: Bool = false) {
        guard canInteract else { return }
        guard !keepingSelections || (createdLink != nil && buttonReady) else { return }
        withAnimation(reducedMotion ? nil : DroppyAnimation.state) {
            invalidateSelections()
            if !keepingSelections { source = nil; destination = nil }
            clearPresentation()
        }
        if !keepingSelections {
            // Going back keeps access to the same source and destination for the next operation.
            leases.removeAll()
        }
        refreshPreflight()
        host?.shelf.invalidateLayout(for: "symlinker")
    }
    func create(reducedMotion: Bool) {
        guard canAttemptCreation, let source, let destination else { return }
        let settings = tuning
        invalidateSelections(); preflightTask?.cancel()
        conflictNoticeTask?.cancel(); conflictNoticeTask = nil
        noticedConflict = nil; conflictNoticeVisible = false
        let id = UUID(); operationID = id
        activeTuning = settings
        continuousMotion = !reducedMotion
        workState = .creating; message = nil; issueRole = nil; settled = false
        updateShelfHold()
        let resources = Array(leases.values)
        let createLink = createLink
        operation = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.operationID == id {
                    self.workState = .idle; self.operation = nil; self.operationID = nil
                    self.updateShelfHold()
                    if self.createdLink == nil { self.refreshPreflight() }
                }
            }
            do {
                // The filesystem succeeds before the visual confirmation begins.
                let link = try await FileIO.run { try withExtendedLifetime(resources) { try createLink(source, destination) } }
                guard self.acceptsInteractions, self.operationID == id else { return }
                self.createdLink = link
                self.workState = .animating
                guard !Task.isCancelled else { self.finishConfirmation(); return }
                try await self.animate(link: link, reducedMotion: reducedMotion, settings: settings)
            } catch is CancellationError {
                if self.operationID == id, self.createdLink != nil { self.finishConfirmation() }
            } catch {
                guard self.acceptsInteractions, self.operationID == id else { return }
                let duplicate = (error as? LinkError).map { if case .nameTaken = $0 { true } else { false } } == true
                    || (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == CocoaError.fileWriteFileExists.rawValue
                self.message = duplicate ? nil : "Could not create the link. \(error.localizedDescription)"
                if let linkError = error as? LinkError, case .missingSource = linkError { self.issueRole = .source }
                else { self.issueRole = .destination }
                self.progress = 0
            }
        }
    }
    private func finishConfirmation() {
        settled = true; progress = 1; recoil = 1; rebound = 0; snapped = true
        buttonConfirmed = true; buttonReady = true; continuousMotion = false
    }
    private func animate(link: URL, reducedMotion: Bool, settings: AnimationTuning) async throws {
        activeTuning = settings
        continuousMotion = !reducedMotion
        let timing = animationTiming(settings: settings, reducedMotion: reducedMotion)
        let screen = playgroundWindow?.screen ?? NSScreen.main
        let reportedRate = screen?.maximumFramesPerSecond ?? 60
        let framesPerSecond = Double(min(120, max(30, reportedRate > 0 ? reportedRate : 60)))
        let clock = ContinuousClock()
        let start = clock.now
        while true {
            try Task.checkCancellation()
            let components = start.duration(to: clock.now).components
            let elapsed = Double(components.seconds) + Double(components.attoseconds) / 1e18
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            let nextProgress = CGFloat(min(1, elapsed / timing.tile))
            if nextProgress != progress {
                withTransaction(transaction) { progress = nextProgress }
            }
            if elapsed >= timing.split && !snapped {
                snapped = true; createdLink = link; recoil = 1; settled = true
                buttonConfirmed = true
            }
            if elapsed >= timing.finder && !buttonReady { buttonReady = true }
            if elapsed >= timing.end { break }
            // Deadlines stay on the initial clock grid; a late frame skips missed slots.
            let nextFrame = floor(elapsed * framesPerSecond) + 1
            let nextTime = elapsed >= timing.tile
                ? (buttonReady ? timing.end : timing.finder)
                : nextFrame / framesPerSecond
            let deadline = start.advanced(by: .seconds(min(timing.end, nextTime)))
            try await clock.sleep(until: deadline, tolerance: .milliseconds(1))
        }
    }
    private func animationTiming(settings: AnimationTuning, reducedMotion: Bool)
        -> (tile: Double, split: Double, finder: Double, end: Double) {
        let tile = reducedMotion ? 0.35 : settings.totalDuration
        let split = reducedMotion ? 0.35 : settings.stretchDuration + settings.splitDuration
        let finder = split + max(reducedMotion ? 0.192 : settings.recoilDuration, settings.confirmationDuration)
        return (tile, split, finder, max(tile, finder + settings.finderDuration))
    }
    func configureDemo() {
        isDemo = true
        source = URL(fileURLWithPath: "/Symlinker preview/Project notes.txt")
        destination = URL(fileURLWithPath: "/Symlinker preview/Workspace", isDirectory: true)
    }
    func replay(reducedMotion: Bool = false) {
        guard isDemo, !isCreating else { return }
        let settings = tuning
        activeTuning = settings; continuousMotion = !reducedMotion
        isScrubbing = false; createdLink = nil; progress = 0; snapped = false; recoil = 0
        rebound = 0; buttonConfirmed = false; buttonReady = false; settled = false; message = nil
        isCreating = true
        let link = destination!.appendingPathComponent(source!.lastPathComponent)
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.isCreating = false; self.operation = nil }
            do { try await self.animate(link: link, reducedMotion: reducedMotion, settings: settings) }
            catch { /* Demo cancellation never examines or touches the filesystem. */ }
        }
    }
    func scrub(_ value: Double, reducedMotion: Bool = false) {
        guard isDemo, !isCreating else { return }
        applyScrub(value, reducedMotion: reducedMotion)
    }
    private func applyScrub(_ value: Double, reducedMotion: Bool) {
        let normalized = value.isFinite ? min(1, max(0, value)) : 0
        let timing = animationTiming(settings: tuning, reducedMotion: reducedMotion)
        let elapsed = normalized * timing.tile
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) {
            activeTuning = nil
            isScrubbing = true; continuousMotion = !reducedMotion
            progress = CGFloat(normalized)
            snapped = elapsed >= timing.split
            createdLink = snapped ? destination!.appendingPathComponent(source!.lastPathComponent) : nil
            settled = snapped; recoil = snapped ? 1 : 0; rebound = 0
            buttonConfirmed = snapped; buttonReady = elapsed >= timing.finder
        }
    }
    func openPlayground() {
        guard acceptsInteractions, !isDemo else { return }
        if let playgroundWindow { playgroundWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 832, height: 650),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Symlinker animation playground"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 772, height: 590)
        window.contentView = NSHostingView(rootView: AnimationPlaygroundView(owner: self))
        let delegate = AnimationPlaygroundWindowDelegate { [weak self] in
            self?.playgroundWindow = nil; self?.playgroundDelegate = nil
        }
        playgroundDelegate = delegate; window.delegate = delegate
        window.center(); playgroundWindow = window
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

}

extension SymlinkerDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [.init(id: "symlinker", title: "Symlinker", systemImage: "link", layoutTraits: .init(
            preferredSoloWidth: SymlinkerMetrics.soloWidth, preferredPairedWidth: 210, contentHeight: .fixed(panelHeight)),
            prewarmPolicy: .never,
            searchKeywords: ["symlink", "symbolic link", "files"])]
    }
    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        guard id == "symlinker" else { return AnyView(EmptyView()) }
        return AnyView(Group {
            if context.isCompact {
                SymlinkerCompactWidget(model: self, context: context)
            } else {
                SymlinkerPanel(
                    model: self,
                    isPreview: context.isPreview,
                    keepsShelfOpen: true,
                    usesAdaptiveForegrounds: context.usesAdaptiveForegrounds
                )
                    .padding(context.contentInsets)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(!context.isShelfTransitioning)
            }
        })
    }
    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? {
        guard id == "symlinker" else { return nil }
        return AnyView(VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            Text("Preview and tune the animation without creating links.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Button("Animation playground…") { self.openPlayground() }
                .buttonStyle(.bordered)
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
        guard id == "symlinker" else { return nil }
        #if DEBUG
        if previewsPlayground { return CGSize(width: 832, height: 650) }
        #endif
        let width = min(proposal.maximumSize.width, max(proposal.standardSize.width, SymlinkerMetrics.soloWidth))
        return CGSize(width: width, height: panelHeight)
    }
    public func expandedSurfaceDidDismiss(_ id: ExpandedSurfaceID, presentation: ExpandedSurfacePresentation, reason: ExpandedSurfaceDismissalReason) {
        guard id == "symlinker", expandedPresentation?.id == presentation.id else { return }
        expandedPresentation = nil
        // View disappearance cancels pending input. Never clear the session on host Home/close.
    }
}

#if DEBUG
public extension SymlinkerDroplet {
    func renderPlayground(to path: String) {
        let hosting = NSHostingView(rootView: AnimationPlaygroundView(owner: self).frame(width: 832, height: 650))
        hosting.frame = NSRect(x: 0, y: 0, width: 832, height: 650)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting; window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        RunLoop.main.run(until: Date().addingTimeInterval(0.9))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
    }
    /// Harness-only fixtures; never create files or links while rendering previews.
    func preparePreview(state: String, source: URL, destination: URL) {
        isPreviewFixture = true
        previewsReducedMotion = state.hasSuffix(":reduced")
        let state = previewsReducedMotion ? String(state.dropLast(8)) : state
        if state == "playground" { previewsPlayground = true; return }
        guard state != "idle" else { return }
        if state == "loading" {
            self.destination = destination
            loadingRoles = [.source]
            return
        }
        if state == "destination" { self.destination = destination; return }
        self.source = source
        if state != "source" { self.destination = destination; preflight = .ready(destination.appendingPathComponent(source.lastPathComponent)) }
        if state.hasPrefix("frame:"), let value = Double(state.dropFirst(6)), value.isFinite {
            applyScrub(value, reducedMotion: false)
            return
        }
        if state == "mitosis" { isCreating = true; continuousMotion = true; progress = 0.29 }
        if state == "creating" { workState = .creating }
        if state == "success" || state == "returned" {
            createdLink = destination.appendingPathComponent(source.lastPathComponent)
            progress = 1; settled = true; snapped = true; recoil = 1; buttonConfirmed = true; buttonReady = true
            if state == "returned" { reset(keepingSelections: true, reducedMotion: true) }
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
        if state == "error" { message = LinkError.nameTaken.localizedDescription; issueRole = .destination }
        if state == "conflict" || state == "conflict-faded" {
            applyPreflight(.conflict(destination.appendingPathComponent(source.lastPathComponent), isSameLink: true))
            if state == "conflict-faded" { conflictNoticeVisible = false }
        }
        if state == "checking" { preflight = .checking }
    }
}
#endif
