import AppKit
import DroppyKit
import SwiftUI
import UniformTypeIdentifiers

enum SymlinkerMetrics {
    static let tileHeight: CGFloat = 96
    static let tileGap: CGFloat = 80
    static let trackInset: CGFloat = 12
    static let trackHeight: CGFloat = 4
    static let trackOpacity: Double = 0.20
}

struct SymlinkerPanel: View {
    @ObservedObject var model: SymlinkerDroplet
    var isPreview = false
    var previewReducedMotion = false
    @Environment(\.accessibilityReduceMotion) private var systemReducedMotion
    private var reducedMotion: Bool { systemReducedMotion || previewReducedMotion }
    private var showFooter: Bool { model.hasSelectionPair || model.message != nil }

    var body: some View {
        VStack(spacing: DroppySpacing.md) {
            GeometryReader { geometry in
                let width = (geometry.size.width - SymlinkerMetrics.tileGap) / 2
                let showsMitosis = (model.isCreating || model.isScrubbing) && !reducedMotion
                ZStack(alignment: .topLeading) {
                    ConnectionTrack(progress: model.progress, fills: reducedMotion && model.isCreating || model.createdLink != nil)
                        .frame(width: SymlinkerMetrics.tileGap - 2 * SymlinkerMetrics.trackInset,
                               height: SymlinkerMetrics.trackHeight)
                        .offset(x: width + SymlinkerMetrics.trackInset,
                                y: (SymlinkerMetrics.tileHeight - SymlinkerMetrics.trackHeight) / 2)
                        .opacity(showsMitosis ? 0 : 1)
                    HStack(alignment: .top, spacing: SymlinkerMetrics.tileGap) {
                        FileTile(url: model.source, title: "Choose source", caption: "Source", linked: false,
                                 disabled: model.isDemo || model.isCreating || model.isPicking || isPreview,
                                 select: { model.choose(destination: false) }, drop: { model.select($0, destination: false) })
                            .frame(width: width)
                        FileTile(url: model.createdLink == nil ? model.destination : model.source,
                                 title: "Choose destination", caption: model.createdLink == nil ? "Destination" : "Symbolic link",
                                 linked: model.createdLink != nil,
                                 disabled: model.isDemo || model.isCreating || model.isPicking || isPreview,
                                 select: { if model.createdLink != nil { model.reveal() } else { model.choose(destination: true) } },
                                 drop: { model.select($0, destination: true) })
                            .frame(width: width)
                    }
                    .opacity(showsMitosis ? 0 : 1)
                    if showsMitosis, let source = model.source {
                        MitosisSurface(url: source, destination: model.destination, progress: model.progress, recoil: model.recoil, rebound: model.rebound,
                                       snapped: model.snapped, continuousMotion: model.continuousMotion, tuning: model.renderingTuning, tileWidth: width, totalWidth: geometry.size.width)
                            .allowsHitTesting(false).accessibilityHidden(true)
                            .transaction { transaction in
                                transaction.animation = nil
                                transaction.disablesAnimations = true
                            }
                    }
                }
            }.frame(height: SymlinkerMetrics.tileHeight)
            if showFooter { footer.transition(DroppyTransition.element) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(DroppyAnimation.state, value: showFooter)
        .animation(DroppyAnimation.state, value: model.buttonReady)
        .accessibilityLabel("Symlinker")
        .contextMenu {
            if !model.isDemo { Button("Animation playground…") { model.openPlayground() } }
        }
    }

    @ViewBuilder private var footer: some View {
        if let message = model.message {
            HStack(spacing: DroppySpacing.xsm) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text(message).lineLimit(2)
            }.font(.system(size: 11)).foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .accessibilityLabel("Unable to create link. \(message)")
        } else {
            HStack {
                if model.createdLink != nil && model.buttonReady {
                    Button("Create new symlink") { model.reset() }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                        .disabled(model.isDemo || model.isCreating || model.isPicking || isPreview)
                        .help("Clear this connection; the symbolic link stays on disk")
                        .transition(DroppyTransition.element)
                }
                Spacer(minLength: DroppySpacing.sm)
                Button {
                    guard !model.isDemo, !isPreview, !model.isCreating, !model.isPicking else { return }
                    if model.buttonReady { model.reveal() } else { model.create(reducedMotion: reducedMotion) }
                } label: {
                    SymlinkActionContent(reducedMotion: reducedMotion, phase: model.buttonReady ? 2 : model.buttonConfirmed ? 1 : 0)
                        .frame(width: 124, height: 20)
                        .animation(.smooth(duration: model.renderingTuning.confirmationDuration), value: model.buttonConfirmed)
                        .animation(.smooth(duration: model.renderingTuning.finderDuration), value: model.buttonReady)
                        .foregroundStyle(model.buttonConfirmed ? Color.green : AdaptiveColors.notchSurfacePrimaryText)
                }
                .buttonStyle(DroppyAccentButtonStyle(color: model.buttonConfirmed ? .green : .white, size: .small))
                // Keep the glass and its ink intact while ignoring repeat presses.
                .allowsHitTesting(!model.isDemo && !model.isCreating && !model.isPicking && !isPreview)
                .accessibilityRespondsToUserInteraction(!model.isCreating && !model.isPicking && !isPreview)
                .keyboardShortcut(model.isDemo ? nil : KeyboardShortcut(.return, modifiers: []))
                .animation(DroppyAnimation.stateEmphasis, value: model.buttonConfirmed)
            }.frame(height: 32)
        }
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
        .accessibilityLabel("Connection progress")
        .accessibilityValue("\(Int(min(max(progress, 0), 1) * 100)) percent")
    }
}

private struct FileTile: View {
    let url: URL?
    let title: String
    let caption: String
    let linked: Bool
    let disabled: Bool
    let select: () -> Void
    let drop: (URL) -> Void
    @State private var hover = false
    @State private var targeted = false
    @State private var arrived = true
    @State private var dropTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reducedMotion

    var body: some View {
        VStack(spacing: DroppySpacing.sm) {
            Button(action: select) {
                VStack(spacing: DroppySpacing.sm) {
                    if let url {
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
                                .fill(targeted ? Color.mint.opacity(0.15) : Color.white.opacity(hover && !disabled ? 0.045 : 0))
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
            .help(url?.path ?? title)
            .accessibilityLabel("\(caption): \(url?.lastPathComponent ?? title)")
            .accessibilityHint(linked ? "Reveal the symbolic link in Finder" : "Click to choose, or drop a \(caption == "Source" ? "file or folder" : "folder")")
            .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
                guard !disabled, providers.count == 1, let provider = providers.first else { return false }
                dropTask?.cancel()
                dropTask = Task { @MainActor in
                    let url: URL? = await withCheckedContinuation { continuation in
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                            let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                            continuation.resume(returning: url)
                        }
                    }
                    guard !Task.isCancelled, let url else { return }
                    drop(url)
                }
                return true
            }

        }
        .task(id: url) {
            // The mitosis already animates this copy into place.
            guard !linked else { arrived = true; return }
            arrived = false
            do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(DroppyAnimation.stateEmphasis) { arrived = true }
        }
        .onDisappear { dropTask?.cancel() }
        .animation(DroppyAnimation.hover, value: hover)
        .animation(DroppyAnimation.stateEmphasis, value: targeted)
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
    }
}

private struct FileGlyph: View {
    let url: URL
    var linked = false
    var body: some View {
        Image(nsImage: url.hasDirectoryPath ? NSWorkspace.shared.icon(for: .folder) : NSWorkspace.shared.icon(forFile: url.path))
            .resizable().interpolation(.high).scaledToFit().frame(width: 40, height: 40)
            .overlay(alignment: .bottomTrailing) {
                if linked {
                    Image(systemName: "link").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.mint)
                        .padding(4).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .offset(x: 5, y: 3).transition(.scale.combined(with: .opacity))
                }
            }
    }
}

// Rectangular tiles share an elapsed clock independent of button transitions.
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
    let totalWidth: CGFloat
    private func ease(_ value: CGFloat) -> CGFloat {
        let t = min(1, max(0, value))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }
    var body: some View {
        let clock = continuousMotion ? tuning.visualClock(progress) : min(1, max(0, progress))
        let p = continuousMotion ? min(1, clock / 0.38) : clock
        let separation = continuousMotion ? tuning.splitAmount(at: clock) : (snapped ? 1.0 : 0.0)
        let leftReturn = continuousMotion ? tuning.returnAmount(at: clock) : recoil
        let rightReturn = continuousMotion ? tuning.returnAmount(at: clock, delay: 0.012) : recoil
        let stretch = continuousMotion ? tuning.stretchAmount(at: clock) : ease(p / 0.60)
        let joinedWidth = tileWidth + (totalWidth - tileWidth) * stretch
        let splitWidth = totalWidth / 2
        let leftWidth = splitWidth + (tileWidth - splitWidth) * leftReturn
        let rightWidth = splitWidth + (tileWidth - splitWidth) * rightReturn
        let leftTarget = tileWidth / 2 + (splitWidth - tileWidth) / 2 * stretch * (1 - leftReturn)
        let rightTarget = tileWidth / 2 + (totalWidth - splitWidth / 2 - tileWidth / 2) * stretch
            + (splitWidth - tileWidth) / 2 * rightReturn
        let leftX = joinedWidth / 2 + (leftTarget - joinedWidth / 2) * separation
        let rightX = joinedWidth / 2 + (rightTarget - joinedWidth / 2) * separation
        let baseHeight = SymlinkerMetrics.tileHeight * (1 - CGFloat(tuning.squash) * stretch)
        let leftHeight = baseHeight + SymlinkerMetrics.tileHeight * CGFloat(tuning.squash) * leftReturn
        let rightHeight = baseHeight + SymlinkerMetrics.tileHeight * CGFloat(tuning.squash) * rightReturn
        let leftBounce = continuousMotion ? tuning.reboundAmount(at: clock) : rebound
        let rightBounce = continuousMotion ? tuning.reboundAmount(at: clock, delay: 0.012) : rebound
        let speedWash = continuousMotion ? sin(.pi * ease((clock - 0.20) / 0.55)) : sin(.pi * p)
        let blur = max(0, speedWash) * CGFloat(tuning.blur)
            + sin(.pi * separation) * CGFloat(tuning.blur) * 0.70
        let arrival = continuousMotion ? ease((clock - 0.70) / 0.30) : (snapped ? recoil : 0)
        let departure = continuousMotion ? 1 - ease(clock / 0.19) : 0
        let duplicate = separation
        let badge = continuousMotion ? ease((clock - 0.55) / 0.27) : (snapped ? 1.0 : 0.0)
        let leftGlyphScale = 1 + 0.13 * stretch * (1 - leftReturn) - 0.10 * leftBounce
        let rightGlyphScale = 1 + 0.13 * stretch * (1 - rightReturn) - 0.10 * rightBounce
        let joinedScale = joinedWidth / tileWidth
        let y = SymlinkerMetrics.tileHeight / 2
        ZStack(alignment: .topLeading) {
            ConnectionTrack(progress: arrival, fills: true)
                .frame(width: SymlinkerMetrics.tileGap - 2 * SymlinkerMetrics.trackInset,
                       height: SymlinkerMetrics.trackHeight)
                .opacity(max(departure, arrival))
                .blur(radius: (1 - max(departure, arrival)) * 2)
                .offset(x: tileWidth + SymlinkerMetrics.trackInset,
                        y: y - SymlinkerMetrics.trackHeight / 2)
            if let destination {
                RoundedRectangle(cornerRadius: DroppyRadius.large, style: .continuous)
                    .fill(AdaptiveColors.notchSurfaceCardFill)
                    .frame(width: tileWidth, height: SymlinkerMetrics.tileHeight)
                    .overlay { glyph(destination, badge: 0) }
                    .scaleEffect(0.94 + 0.06 * departure)
                    .opacity(departure)
                    .blur(radius: (1 - departure) * 6)
                    .position(x: totalWidth - tileWidth / 2, y: y)
            }
            RoundedRectangle(cornerRadius: DroppyRadius.large, style: .continuous)
                .fill(AdaptiveColors.notchSurfaceCardFill)
                .frame(width: joinedWidth, height: baseHeight)
                .opacity(1 - separation)
                .blur(radius: blur * 0.65)
                .offset(y: (SymlinkerMetrics.tileHeight - baseHeight) / 2)
            // One source remains intact while its entire content stretches with the card.
            // Only the split introduces the two independently positioned copies.
            glyph(url, badge: 0)
                .scaleEffect(x: joinedWidth / tileWidth, y: baseHeight / SymlinkerMetrics.tileHeight)
                .blur(radius: blur * 0.50)
                .opacity(1 - separation)
                .position(x: joinedWidth / 2, y: y)
            glyph(url, badge: 0)
                .scaleEffect(x: joinedWidth / tileWidth, y: baseHeight / SymlinkerMetrics.tileHeight)
                .blur(radius: 4 + blur * 0.5)
                .opacity(Double(speedWash * (1 - separation)) * tuning.trails)
                .offset(x: blur * 1.8)
                .position(x: joinedWidth / 2, y: y)
            tile(width: leftWidth, height: leftHeight,
                 pulse: leftBounce, blur: blur, visibility: separation)
                .position(x: leftX, y: y)
            tile(width: rightWidth, height: rightHeight,
                 pulse: rightBounce, blur: blur, visibility: separation)
                .position(x: rightX, y: y)
            // Short translucent trails disappear before the final sharp handoff.
            glyph(url, badge: 0)
                .opacity(Double(speedWash * separation) * tuning.trails)
                .blur(radius: 4)
                .offset(x: blur * 1.8)
                .position(x: leftX, y: y)
            glyph(url, badge: badge)
                .opacity(Double(speedWash * duplicate) * tuning.trails)
                .blur(radius: 4)
                .offset(x: -blur * 1.8)
                .position(x: rightX, y: y)
            glyph(url, badge: 0)
                .scaleEffect(x: joinedScale + (leftGlyphScale - joinedScale) * separation,
                             y: 1 - 0.10 * stretch * (1 - leftReturn) + 0.10 * leftBounce)
                .blur(radius: blur * 0.50)
                .opacity(separation)
                .position(x: leftX, y: y)
            glyph(url, badge: badge)
                .scaleEffect(x: joinedScale + (rightGlyphScale - joinedScale) * separation,
                             y: 1 - 0.10 * stretch * (1 - rightReturn) + 0.10 * rightBounce)
                .blur(radius: blur * 0.55)
                .opacity(duplicate)
                .position(x: rightX, y: y)
        }.frame(width: totalWidth, height: SymlinkerMetrics.tileHeight)
    }
    private func tile(width: CGFloat, height: CGFloat,
                      pulse: CGFloat, blur: CGFloat, visibility: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: DroppyRadius.large, style: .continuous)
            .fill(AdaptiveColors.notchSurfaceCardFill)
            .frame(width: max(1, width), height: max(1, height))
            .scaleEffect(x: 1 - 0.15 * pulse, y: 1 + 0.15 * pulse)
            .blur(radius: blur * 0.65)
            .shadow(color: .black.opacity(0.14), radius: 6, y: 3)
            .opacity(visibility)
    }
    private func glyph(_ file: URL, badge: CGFloat) -> some View {
        VStack(spacing: DroppySpacing.sm) {
            FileGlyph(url: file)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "link").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.mint)
                        .padding(4).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .scaleEffect(0.65 + 0.35 * badge)
                        .opacity(badge).blur(radius: (1 - badge) * 3)
                        .offset(x: 5, y: 3)
                }
                .frame(height: 40)
            Text(file.lastPathComponent).font(.system(size: 11, weight: .medium))
                .lineLimit(1).truncationMode(.middle).frame(width: tileWidth - 16)
        }.foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
    }
}

private struct SymlinkActionContent: View, Animatable {
    let reducedMotion: Bool
    nonisolated var phase: CGFloat
    nonisolated var animatableData: CGFloat { get { phase } set { phase = newValue } }
    var body: some View {
        ZStack {
            label("Create Symlink", symbol: "link", at: 0)
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
private struct SymlinkerTileStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reducedMotion ? 0.98 : 1)
            .animation(DroppyAnimation.press, value: configuration.isPressed)
    }
}
