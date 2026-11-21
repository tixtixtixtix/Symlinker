import AppKit
import DroppyKit
import SwiftUI
import UniformTypeIdentifiers

enum SymlinkerMetrics {
    static let soloWidth: CGFloat = 364
    static let tileWidth: CGFloat = 128
    static let tileHeight: CGFloat = 96
    // Larger solo flat-wash pill and circle control height.
    static let actionHeight: CGFloat = 40
    // Two equal-width 146pt wash pills (114pt label + 16pt horizontal padding per side)
    // plus the 40pt back circle and two 8pt gaps fit inside the 348pt notch canvas.
    static let actionLabelWidth: CGFloat = 114
    // Conflict warning sits alone in the footer, so it can hold its full 13pt label comfortably.
    static let actionConflictLabelWidth: CGFloat = 156
    static let inset: CGFloat = DroppySpacing.sm
    static func panelHeight(hasFooter: Bool) -> CGFloat {
        tileHeight + 2 * inset
            + (hasFooter ? DroppySpacing.md + actionHeight : 0)
    }
    static let trackInset: CGFloat = 12
    static let trackHeight: CGFloat = 4
    static let trackOpacity: Double = 0.20
}

struct SymlinkerPanel: View {
    @ObservedObject var model: SymlinkerDroplet
    var isPreview = false
    var previewReducedMotion = false
    var keepsShelfOpen = false
    var usesAdaptiveForegrounds = false
    @State private var surfaceID = UUID()
    @Environment(\.accessibilityReduceMotion) private var systemReducedMotion
    private var reducedMotion: Bool { systemReducedMotion || previewReducedMotion || model.reducesPreviewMotion }
    private var showFooter: Bool { model.hasFooter }
    private var interactionDisabled: Bool { !model.canInteract || isPreview }
    private var showsConflictWarning: Bool { model.hasTimedConflict && model.conflictNoticeVisible }

    var body: some View {
        VStack(spacing: DroppySpacing.md) {
            GeometryReader { geometry in
                let width = min(SymlinkerMetrics.tileWidth, max(80, (geometry.size.width - 40) / 2))
                let gap = max(24, geometry.size.width - 2 * width)
                let showsMitosis = (model.workState == .animating || model.isScrubbing) && !reducedMotion
                ZStack(alignment: .topLeading) {
                    ConnectionTrack(progress: model.progress, fills: reducedMotion && (model.isCreating || model.isScrubbing) || model.createdLink != nil)
                        .frame(width: max(0, gap - 2 * SymlinkerMetrics.trackInset),
                               height: SymlinkerMetrics.trackHeight)
                        .offset(x: width + SymlinkerMetrics.trackInset,
                                y: (SymlinkerMetrics.tileHeight - SymlinkerMetrics.trackHeight) / 2)
                        .opacity(showsMitosis ? 0 : 1)
                    HStack(alignment: .top, spacing: gap) {
                        FileTile(url: model.source, title: "Choose source", caption: "Source", linked: false,
                                 disabled: interactionDisabled, loading: model.loadingRoles.contains(.source),
                                 select: { model.choose(destination: false) },
                                 drop: { model.acceptDrop($0, role: .source) },
                                 clear: { model.clearSelection(.source) },
                                 reveal: { if let url = model.source { model.reveal(url) } },
                                 copy: { if let url = model.source { model.copyPath(url) } }, canCopy: model.canCopyPaths)
                            .frame(width: width)
                        FileTile(url: model.createdLink ?? model.destination,
                                 title: "Choose destination", caption: model.createdLink == nil ? "Destination" : "Symbolic link",
                                 linked: model.createdLink != nil,
                                  disabled: interactionDisabled, loading: model.loadingRoles.contains(.destination),
                                 select: { if model.createdLink != nil { model.reveal() } else { model.choose(destination: true) } },
                                  drop: { model.acceptDrop($0, role: .destination) },
                                  clear: { model.clearSelection(.destination) },
                                  reveal: { if let url = model.createdLink ?? model.destination { model.reveal(url) } },
                                  copy: { if let url = model.createdLink ?? model.destination { model.copyPath(url) } },
                                  canCopy: model.canCopyPaths,
                                  change: { model.choose(destination: true) })
                            .frame(width: width)
                    }
                    .opacity(showsMitosis ? 0 : 1)
                    if showsMitosis, let source = model.source {
                        MitosisSurface(url: source, destination: model.destination, progress: model.progress, recoil: model.recoil, rebound: model.rebound,
                                       snapped: model.snapped, continuousMotion: model.continuousMotion, tuning: model.renderingTuning, tileWidth: width, tileGap: gap, totalWidth: geometry.size.width)
                            .allowsHitTesting(false).accessibilityHidden(true)
                            .transaction { transaction in
                                transaction.animation = nil
                                transaction.disablesAnimations = true
                            }
                    }
                }
            }.frame(height: SymlinkerMetrics.tileHeight)
            if showFooter { footer.transition(reducedMotion ? .identity : DroppyTransition.element) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(reducedMotion ? nil : DroppyAnimation.state, value: showFooter)
        .animation(reducedMotion ? nil : DroppyAnimation.state, value: model.buttonReady)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Symlinker")
        .contextMenu {
            if !model.isDemo { Button("Animation playground…") { model.openPlayground() }.disabled(isPreview) }
        }
        .onAppear { if !isPreview && !model.isDemo { model.editorVisibility(surfaceID, visible: true, keepsShelfOpen: keepsShelfOpen) } }
        .onDisappear { if !isPreview && !model.isDemo { model.editorVisibility(surfaceID, visible: false) } }
    }

    private var errorMessage: String? {
        if let message = model.message { return message }
        if case .invalid(let message, _) = model.preflight { return message }
        return nil
    }

    private var primaryTone: DroppyWashTone {
        if showsConflictWarning { return .accent(.orange) }
        if model.buttonConfirmed { return .accent(.green) }
        return .accent(AdaptiveColors.notchSurfacePrimaryText)
    }

    @ViewBuilder private var footer: some View {
            HStack(spacing: 0) {
                if model.createdLink != nil && model.buttonReady {
                    HStack(spacing: DroppySpacing.sm) {
                        Button { model.reset(keepingSelections: true, reducedMotion: reducedMotion) } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(DroppyWashCircleButtonStyle(
                            diameter: SymlinkerMetrics.actionHeight,
                            tone: .neutral,
                            usesAdaptiveForegrounds: usesAdaptiveForegrounds
                        ))
                        .disabled(interactionDisabled)
                        .accessibilityLabel("Back to source and destination")
                        .help("Return to the selected source and destination; the symbolic link stays on disk")

                        Button { model.reset(reducedMotion: reducedMotion) } label: {
                            HStack(spacing: DroppySpacing.xsm) {
                                Image(systemName: "plus")
                                Text("New symlink")
                            }
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.95)
                            .frame(width: SymlinkerMetrics.actionLabelWidth, height: 22)
                        }
                        .buttonStyle(DroppyWashPillButtonStyle(
                            height: SymlinkerMetrics.actionHeight,
                            tone: .neutral,
                            usesAdaptiveForegrounds: usesAdaptiveForegrounds
                        ))
                        .disabled(interactionDisabled)
                        .help("Clear both selections; the symbolic link stays on disk")
                    }
                    .transition(reducedMotion ? .identity : DroppyTransition.element)
                } else if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .lineLimit(2).help(errorMessage)
                        .accessibilityLabel(errorMessage)
                }
                Spacer(minLength: DroppySpacing.sm)
                Button {
                    guard !interactionDisabled, !showsConflictWarning else { return }
                    if model.buttonReady { model.reveal() } else { model.create(reducedMotion: reducedMotion) }
                } label: {
                    ZStack {
                        SymlinkActionContent(reducedMotion: reducedMotion, phase: model.buttonReady ? 2 : model.buttonConfirmed ? 1 : 0)
                            .animation(.smooth(duration: model.renderingTuning.confirmationDuration), value: model.buttonConfirmed)
                            .animation(.smooth(duration: model.renderingTuning.finderDuration), value: model.buttonReady)
                            .opacity(showsConflictWarning || model.workState == .creating ? 0 : 1)
                            .accessibilityHidden(showsConflictWarning || model.workState == .creating)
                        if model.workState == .creating {
                            HStack(spacing: DroppySpacing.xsm) {
                                ProgressView().controlSize(.mini)
                                Text("Creating…")
                            }
                        }
                        HStack(spacing: DroppySpacing.xsm) {
                            Image(systemName: "exclamationmark.circle")
                            Text("Name already exists")
                        }
                        .opacity(showsConflictWarning ? 1 : 0).accessibilityHidden(!showsConflictWarning)
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.95)
                    .frame(width: showsConflictWarning ? SymlinkerMetrics.actionConflictLabelWidth : SymlinkerMetrics.actionLabelWidth, height: 22)
                    .animation(DroppyAnimation.state, value: showsConflictWarning)
                }
                .buttonStyle(DroppyWashPillButtonStyle(
                    height: SymlinkerMetrics.actionHeight,
                    tone: primaryTone,
                    usesAdaptiveForegrounds: usesAdaptiveForegrounds
                ))
                // The filesystem and animation phases both reject repeat activation.
                .disabled(interactionDisabled || (!model.canAttemptCreation && !model.buttonReady && !model.isCreating))
                .allowsHitTesting(!interactionDisabled && !showsConflictWarning)
                .accessibilityRespondsToUserInteraction(!interactionDisabled && !showsConflictWarning)
                .help(model.buttonReady ? "Reveal the created symbolic link in Finder" : showsConflictWarning ? "Change the source or destination. Existing items are never replaced." : "Create a symbolic link without replacing existing items")
                .keyboardShortcut(model.isDemo || isPreview ? nil : KeyboardShortcut(.return, modifiers: []))
                .animation(reducedMotion ? nil : DroppyAnimation.stateEmphasis, value: model.buttonConfirmed)
                .animation(DroppyAnimation.state, value: showsConflictWarning)
            }.frame(height: SymlinkerMetrics.actionHeight)
    }
}

private struct ConnectionTrack: View, Animatable {
    nonisolated var progress: CGFloat
    var fills: Bool
    nonisolated var animatableData: CGFloat { get { progress } set { progress = newValue } }
    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(.white.opacity(SymlinkerMetrics.trackOpacity))
                .overlay(alignment: .leading) {
                    if fills {
                        Capsule().fill(.white.opacity(0.9))
                            .frame(width: geometry.size.width * min(max(progress, 0), 1))
                    }
                }
        }
        .accessibilityLabel("Link animation progress")
        .accessibilityValue("\(Int(min(max(progress, 0), 1) * 100)) percent")
    }
}

private struct FileTile: View {
    let url: URL?
    let title: String
    let caption: String
    let linked: Bool
    let disabled: Bool
    var loading = false
    let select: () -> Void
    let drop: ([NSItemProvider]) -> Bool
    let clear: () -> Void
    let reveal: () -> Void
    let copy: () -> Void
    var canCopy = false
    var change: (() -> Void)? = nil
    @State private var hover = false
    @State private var targeted = false
    @State private var arrived = true
    @Environment(\.accessibilityReduceMotion) private var reducedMotion

    var body: some View {
        VStack(spacing: DroppySpacing.sm) {
            Button(action: select) {
                VStack(spacing: DroppySpacing.xsm) {
                    if loading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 40, height: 40)
                            .accessibilityLabel("Loading \(caption.lowercased())")
                        Text(url?.lastPathComponent ?? title)
                            .font(.system(size: 11, weight: url == nil ? .regular : .medium))
                            .foregroundStyle(url == nil ? AdaptiveColors.notchSurfaceSecondaryText : AdaptiveColors.notchSurfacePrimaryText)
                            .lineLimit(1).truncationMode(.middle)
                    } else if let url {
                        FileGlyph(url: url, linked: linked).frame(height: 40)
                        Text(url.lastPathComponent).font(.system(size: 11, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                    } else {
                        Image(systemName: caption == "Source" ? "doc.badge.plus" : "folder.badge.plus")
                            .font(.system(size: 28, weight: .ultraLight))
                            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                        Text(title).font(.system(size: 11))
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    }
                }
                .padding(.horizontal, DroppySpacing.sm)
                .frame(maxWidth: .infinity).frame(height: SymlinkerMetrics.tileHeight)
                .background {
                    RoundedRectangle(cornerRadius: DroppyRadius.large, style: .continuous)
                        .fill(AdaptiveColors.notchSurfaceCardFill)
                        .overlay {
                            RoundedRectangle(cornerRadius: DroppyRadius.large, style: .continuous)
                                .fill(targeted && !disabled ? Color.mint.opacity(0.15) : Color.white.opacity(hover && !disabled ? 0.045 : 0))
                        }
                        .shadow(color: .black.opacity(0.14), radius: 6, y: 3)
                }
                .contentShape(RoundedRectangle(cornerRadius: DroppyRadius.large, style: .continuous))
            }
            .buttonStyle(SymlinkerTileStyle()).disabled(disabled)
            .scaleEffect(x: reducedMotion ? 1 : arrived ? 1 : 0.96,
                         y: reducedMotion ? 1 : arrived ? 1 : 1.02)
            .scaleEffect(targeted && !disabled && !reducedMotion ? 1.025 : 1)
            .onHover { hover = $0 }
            .help(url.map { "\(caption): \($0.path)" } ?? title)
            .accessibilityLabel("\(caption): \(url?.lastPathComponent ?? title)")
            .accessibilityHint(linked ? "Reveal the symbolic link in Finder" : "Click to choose, or drop a \(caption == "Source" ? "file or folder" : "folder")")
            .accessibilityValue(url?.path ?? "Not selected")
            .contextMenu {
                if !disabled {
                    Button("Change \(caption == "Source" ? "source" : "destination")…", action: change ?? select)
                    if url != nil {
                        Button("Clear selection", action: clear)
                        Divider()
                        Button("Show in Finder", action: reveal)
                        Button("Copy path", action: copy)
                            .disabled(!canCopy)
                            .help(canCopy ? "Copy the full path" : "Allow clipboard access for Symlinker to copy paths")
                    }
                }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: DroppyRadius.large, style: .continuous))
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            guard !disabled else { return false }
            targeted = false
            return drop(providers)
        }
        .task(id: url) {
            // The mitosis already animates this copy into place.
            guard !linked, !reducedMotion else { arrived = true; return }
            arrived = false
            do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(DroppyAnimation.stateEmphasis) { arrived = true }
        }
        .onChange(of: disabled) { _, disabled in
            if disabled { targeted = false }
        }
        .onDisappear { targeted = false }
        .animation(reducedMotion ? nil : DroppyAnimation.hover, value: hover)
        .animation(reducedMotion ? nil : DroppyAnimation.stateEmphasis, value: targeted)
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
    }

}

@MainActor
private final class FileArtwork: ObservableObject {
    @Published private(set) var image: NSImage
    private var loadedURL: URL?
    private var requestID = UUID()
    private struct Artwork: @unchecked Sendable { let image: NSImage }
    init(url: URL) {
        image = NSImage(systemSymbolName: url.hasDirectoryPath ? "folder" : "doc", accessibilityDescription: nil) ?? NSImage()
    }
    func refresh(_ url: URL) async {
        guard loadedURL != url else { return }
        let id = UUID(); requestID = id
        let artwork = try? await FileIO.run {
            Artwork(image: url.hasDirectoryPath ? NSWorkspace.shared.icon(for: .folder) : NSWorkspace.shared.icon(forFile: url.path))
        }
        guard !Task.isCancelled, requestID == id, let artwork else { return }
        loadedURL = url; image = artwork.image
    }
}

struct FileGlyph: View {
    let url: URL
    var linked = false
    var size: CGFloat = 40
    @StateObject private var artwork: FileArtwork
    init(url: URL, linked: Bool = false, size: CGFloat = 40) {
        self.url = url
        self.linked = linked
        self.size = size
        _artwork = StateObject(wrappedValue: FileArtwork(url: url))
    }
    var body: some View {
        let badgeGlyphSize = max(7, (size * 0.225).rounded())
        let badgePadding = size >= 32 ? 4.0 : 2.5
        let badgeOffsetX = size >= 32 ? 5.0 : 3.0
        let badgeOffsetY = size >= 32 ? 3.0 : 2.0
        Image(nsImage: artwork.image)
            .resizable().interpolation(.high).scaledToFit().frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if linked {
                    Image(systemName: "link").font(.system(size: badgeGlyphSize, weight: .bold))
                        .foregroundStyle(Color.mint)
                        .padding(badgePadding).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .offset(x: badgeOffsetX, y: badgeOffsetY).transition(.scale.combined(with: .opacity))
                }
            }
            .task(id: url) { await artwork.refresh(url) }
    }
}

// All motion is sampled from one clock, including the neck and spring tail.
private struct MitosisSurface: View {
    let url: URL
    let destination: URL?
    nonisolated var progress: CGFloat
    nonisolated var recoil: CGFloat
    nonisolated var rebound: CGFloat
    let snapped: Bool
    let continuousMotion: Bool
    let tuning: AnimationTuning
    let tileWidth: CGFloat
    let tileGap: CGFloat
    let totalWidth: CGFloat
    private func ease(_ value: CGFloat) -> CGFloat {
        let t = min(1, max(0, value))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }
    var body: some View {
        let clock = continuousMotion ? tuning.visualClock(progress) : min(1, max(0, progress))
        let separation = continuousMotion ? tuning.splitAmount(at: clock) : (snapped ? 1.0 : 0.0)
        let stretch = continuousMotion ? tuning.stretchAmount(at: clock) : ease(clock / 0.60)
        let leftReturn = continuousMotion ? tuning.returnAmount(at: clock) : recoil
        let rightReturn = continuousMotion ? tuning.returnAmount(at: clock, delay: 0.008) : recoil
        let leftBounce = continuousMotion ? tuning.reboundAmount(at: clock) : rebound * 0.07
        let rightBounce = continuousMotion ? tuning.reboundAmount(at: clock, delay: 0.008) : rebound * 0.07
        let joinedWidth = tileWidth + (totalWidth - tileWidth) * stretch
        let opening = tileGap * 0.5 * separation
        let lobeWidth = (joinedWidth - opening) / 2
        let leftWidth = (lobeWidth + (tileWidth - lobeWidth) * leftReturn) * (1 - leftBounce)
        let rightWidth = (lobeWidth + (tileWidth - lobeWidth) * rightReturn) * (1 - rightBounce)
        let baseHeight = SymlinkerMetrics.tileHeight * (1 - CGFloat(tuning.squash) * stretch)
        let leftHeight = (baseHeight + (SymlinkerMetrics.tileHeight - baseHeight) * leftReturn) * (1 + leftBounce)
        let rightHeight = (baseHeight + (SymlinkerMetrics.tileHeight - baseHeight) * rightReturn) * (1 + rightBounce)
        let leftRect = CGRect(x: 0, y: (SymlinkerMetrics.tileHeight - leftHeight) / 2, width: leftWidth, height: leftHeight)
        let rightRect = CGRect(x: joinedWidth - rightWidth, y: (SymlinkerMetrics.tileHeight - rightHeight) / 2,
                               width: rightWidth, height: rightHeight)
        let contentTravel = ease(separation / 0.72)
        let duplicate = ease((contentTravel - 0.12) / 0.75)
        let duplicateLabel = ease((contentTravel - 0.55) / 0.45)
        let leftX = joinedWidth / 2 + (leftRect.midX - joinedWidth / 2) * contentTravel
        let rightX = joinedWidth / 2 + (rightRect.midX - joinedWidth / 2) * contentTravel
        let speed = sin(.pi * ease(clock)) * (1 - ease((clock - 0.65) / 0.35))
        let blur = max(0, speed) * CGFloat(tuning.blur)
        let arrival = continuousMotion ? ease((clock - 0.70) / 0.30) : (snapped ? recoil : 0)
        let departure = continuousMotion ? 1 - ease(clock / 0.19) : 0
        let badge = continuousMotion ? ease((clock - 0.55) / 0.27) : (snapped ? 1.0 : 0.0)
        let glyphStretch = 0.045 * stretch * (1 - separation)
        let y = SymlinkerMetrics.tileHeight / 2
        ZStack(alignment: .topLeading) {
            ConnectionTrack(progress: arrival, fills: true)
                .frame(width: max(0, tileGap - 2 * SymlinkerMetrics.trackInset),
                       height: SymlinkerMetrics.trackHeight)
                .opacity(max(departure, arrival))
                .offset(x: tileWidth + SymlinkerMetrics.trackInset,
                        y: y - SymlinkerMetrics.trackHeight / 2)
            if let destination {
                RoundedRectangle(cornerRadius: DroppyRadius.large, style: .continuous)
                    .fill(AdaptiveColors.notchSurfaceCardFill)
                    .frame(width: tileWidth, height: SymlinkerMetrics.tileHeight)
                    .shadow(color: .black.opacity(0.14), radius: 6, y: 3)
                    .overlay { glyph(destination, badge: 0) }
                    .scaleEffect(0.98 + 0.02 * departure)
                    .opacity(departure)
                    .blur(radius: (1 - departure) * 3)
                    .position(x: totalWidth - tileWidth / 2, y: y)
            }
            MitosisSilhouette(left: leftRect, right: rightRect, neck: 1 - separation)
                .fill(AdaptiveColors.notchSurfaceCardFill)
                .blur(radius: blur * 0.35)
                .shadow(color: .black.opacity(0.14), radius: 6, y: 3)
                .frame(width: totalWidth, height: SymlinkerMetrics.tileHeight)
            if tuning.trails > 0 {
                glyph(url, badge: 0)
                    .opacity(Double(speed) * tuning.trails)
                    .blur(radius: 3)
                    .offset(x: blur * 1.5)
                    .position(x: leftX, y: y)
                glyph(url, badge: badge, labelOpacity: duplicateLabel)
                    .opacity(Double(speed * duplicate) * tuning.trails)
                    .blur(radius: 3)
                    .offset(x: -blur * 1.5)
                    .position(x: rightX, y: y)
            }
            glyph(url, badge: 0)
                .scaleEffect(x: 1 + glyphStretch - leftBounce * 0.25,
                             y: 1 - CGFloat(tuning.squash) * stretch * (1 - leftReturn) * 0.25 + leftBounce * 0.25)
                .blur(radius: blur * 0.25)
                .position(x: leftX, y: y)
            glyph(url, badge: badge, labelOpacity: duplicateLabel)
                .scaleEffect(x: 1 + glyphStretch - rightBounce * 0.25,
                             y: 1 - CGFloat(tuning.squash) * stretch * (1 - rightReturn) * 0.25 + rightBounce * 0.25)
                .blur(radius: blur * 0.25)
                .opacity(duplicate)
                .position(x: rightX, y: y)
        }.frame(width: totalWidth, height: SymlinkerMetrics.tileHeight)
    }
    private func glyph(_ file: URL, badge: CGFloat, labelOpacity: CGFloat = 1) -> some View {
        VStack(spacing: DroppySpacing.sm) {
            FileGlyph(url: file)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "link").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.mint)
                        .padding(4).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .scaleEffect(0.65 + 0.35 * badge)
                        .opacity(badge).blur(radius: (1 - badge) * 2)
                        .offset(x: 5, y: 3)
                }
                .frame(height: 40)
            Text(file.lastPathComponent).font(.system(size: 11, weight: .medium))
                .lineLimit(1).truncationMode(.middle).frame(width: tileWidth - 16)
                .opacity(labelOpacity)
        }
        .frame(width: tileWidth, height: SymlinkerMetrics.tileHeight)
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
    }
}

private struct MitosisSilhouette: Shape {
    var left: CGRect
    var right: CGRect
    var neck: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tile = RoundedRectangle(cornerRadius: DroppyRadius.large, style: .continuous)
        guard neck > 0 else {
            path.addPath(tile.path(in: left))
            path.addPath(tile.path(in: right))
            return path
        }
        let innerRadius = DroppyRadius.large * (1 - neck)
        let innerTile = RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
        let leftOuter = tile.path(in: left).cgPath
        let rightOuter = tile.path(in: right).cgPath
        let leftInner = innerTile.path(in: left).cgPath
        let rightInner = innerTile.path(in: right).cgPath
        let midX = (left.midX + right.midX) / 2
        let midY = (left.midY + right.midY) / 2
        let waist = min(left.height, right.height) / 2 * neck * neck
        let top = CGPoint(x: midX, y: midY - waist)
        let bottom = CGPoint(x: midX, y: midY + waist)
        let leftAttach = max(left.minY + min(left.height / 2, innerRadius * 1.6),
                             left.midY - waist - left.height * 0.35 * neck * (1 - neck))
        let rightAttach = max(right.minY + min(right.height / 2, innerRadius * 1.6),
                              right.midY - waist - right.height * 0.35 * neck * (1 - neck))
        let leftGap = max(0, midX - left.maxX)
        let rightGap = max(0, right.minX - midX)
        // The neck meets each side tangentially. Native corners survive the
        // deformation, including the exact single-card and separated endpoints.
        path.move(to: top)
        path.addCurve(to: CGPoint(x: right.minX, y: rightAttach),
                      control1: CGPoint(x: midX + rightGap * 0.55, y: top.y),
                      control2: CGPoint(x: right.minX, y: rightAttach + (top.y - rightAttach) * 0.55))
        appendCorner(.topLeft, of: rightInner, in: right, to: &path)
        appendCorner(.topRight, of: rightOuter, in: right, to: &path)
        appendCorner(.bottomRight, of: rightOuter, in: right, to: &path)
        appendCorner(.bottomLeft, of: rightInner, in: right, to: &path)
        let rightBottom = 2 * right.midY - rightAttach
        path.addLine(to: CGPoint(x: right.minX, y: rightBottom))
        path.addCurve(to: bottom,
                      control1: CGPoint(x: right.minX, y: rightBottom - (rightBottom - bottom.y) * 0.55),
                      control2: CGPoint(x: midX + rightGap * 0.55, y: bottom.y))
        let leftBottom = 2 * left.midY - leftAttach
        path.addCurve(to: CGPoint(x: left.maxX, y: leftBottom),
                      control1: CGPoint(x: midX - leftGap * 0.55, y: bottom.y),
                      control2: CGPoint(x: left.maxX, y: leftBottom - (leftBottom - bottom.y) * 0.55))
        appendCorner(.bottomRight, of: leftInner, in: left, to: &path)
        appendCorner(.bottomLeft, of: leftOuter, in: left, to: &path)
        appendCorner(.topLeft, of: leftOuter, in: left, to: &path)
        appendCorner(.topRight, of: leftInner, in: left, to: &path)
        path.addLine(to: CGPoint(x: left.maxX, y: leftAttach))
        path.addCurve(to: top,
                      control1: CGPoint(x: left.maxX, y: leftAttach + (top.y - leftAttach) * 0.55),
                      control2: CGPoint(x: midX - leftGap * 0.55, y: top.y))
        path.closeSubpath()
        return path
    }

    private enum Corner { case topLeft, topRight, bottomLeft, bottomRight }
    private func appendCorner(_ corner: Corner, of outline: CGPath, in bounds: CGRect, to path: inout Path) {
        var previous = CGPoint.zero
        var began = false
        outline.applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint:
                previous = points[0]
            case .addCurveToPoint:
                let end = points[2]
                let onLeft = max(previous.x, end.x) <= bounds.midX
                let onRight = min(previous.x, end.x) >= bounds.midX
                let onTop = max(previous.y, end.y) <= bounds.midY
                let onBottom = min(previous.y, end.y) >= bounds.midY
                let matches: Bool
                switch corner {
                case .topLeft: matches = onLeft && onTop
                case .topRight: matches = onRight && onTop
                case .bottomLeft: matches = onLeft && onBottom
                case .bottomRight: matches = onRight && onBottom
                }
                if matches {
                    if !began { path.addLine(to: previous); began = true }
                    path.addCurve(to: end, control1: points[0], control2: points[1])
                }
                previous = end
            default: break
            }
        }
        if !began {
            switch corner {
            case .topLeft: path.addLine(to: CGPoint(x: bounds.minX, y: bounds.minY))
            case .topRight: path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.minY))
            case .bottomLeft: path.addLine(to: CGPoint(x: bounds.minX, y: bounds.maxY))
            case .bottomRight: path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY))
            }
        }
    }
}

struct SymlinkActionContent: View, Animatable {
    let reducedMotion: Bool
    nonisolated var phase: CGFloat
    nonisolated var animatableData: CGFloat { get { phase } set { phase = newValue } }
    var body: some View {
        ZStack {
            label("Create symlink", symbol: "link", at: 0)
            label("Created", symbol: "checkmark", at: 1)
            label("Show in Finder", symbol: "folder", at: 2)
        }
    }
    private func label(_ text: String, symbol: String, at index: CGFloat) -> some View {
        let weight = max(0, 1 - abs(phase - index))
        return HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: symbol)
            Text(text)
        }
        .opacity(weight).blur(radius: reducedMotion ? 0 : (1 - weight) * 4)
        .offset(y: reducedMotion ? 0 : (index - phase) * 5)
        .scaleEffect(reducedMotion ? 1 : 0.96 + 0.04 * weight)
        .accessibilityHidden(weight < 0.5)
    }
}

/// Drop targets retain their content's contrast during creation: disabling
/// interaction must not make the original appear to disappear.
struct SymlinkerTileStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reducedMotion ? 0.98 : 1)
            .animation(DroppyAnimation.press, value: configuration.isPressed)
    }
}
