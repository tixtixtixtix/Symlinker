import DroppyKit
import SwiftUI
import UniformTypeIdentifiers

/// Compact paired shelf view: two vertical System-Settings-style file tiles,
/// animated confirmation feedback, and a bottom action row with a circular + new-symlink control.
struct SymlinkerCompactWidget: View {
    @ObservedObject var model: SymlinkerDroplet
    let context: ShelfWidgetContext
    @State private var surfaceID = UUID()
    @State private var sourceTargeted = false
    @State private var destinationTargeted = false
    @Environment(\.accessibilityReduceMotion) private var systemReducedMotion
    private var reducedMotion: Bool { systemReducedMotion || model.reducesPreviewMotion }
    private var disabled: Bool { context.isPreview || context.isShelfTransitioning || !model.canInteract }
    private var showsConflictWarning: Bool { model.hasTimedConflict && model.conflictNoticeVisible }
    private var errorMessage: String? {
        if let message = model.message { return message }
        if case .invalid(let message, _) = model.preflight { return message }
        return nil
    }
    private var hasAnythingToClear: Bool {
        model.source != nil || model.destination != nil || model.createdLink != nil || model.message != nil
    }
    private var highlightedRole: SelectionRole? {
        if sourceTargeted { return .source }
        if destinationTargeted { return .destination }
        if case .picking(let role) = model.workState { return role }
        if model.createdLink != nil && model.buttonConfirmed { return .destination }
        if model.source == nil { return .source }
        if model.destination == nil { return .destination }
        return nil
    }

    var body: some View {
        GeometryReader { geometry in
            let tight = geometry.size.height < 120
            let spacing: CGFloat = tight ? DroppySpacing.xs : DroppySpacing.sm
            let buttonHeight: CGFloat = tight ? 28 : 34
            let iconSize: CGFloat = tight ? 18 : 26
            let cornerRadius: CGFloat = tight ? DroppyRadius.small : DroppyRadius.medium
            let labelFontSize: CGFloat = tight ? 12 : 13

            VStack(spacing: spacing) {
                CompactSelectionTile(
                    role: .source,
                    url: model.source,
                    title: "Choose source",
                    caption: "Source",
                    linked: false,
                    highlighted: highlightedRole == .source,
                    disabled: disabled,
                    loading: model.loadingRoles.contains(.source),
                    targeted: $sourceTargeted,
                    iconSize: iconSize,
                    cornerRadius: cornerRadius,
                    fontSize: labelFontSize,
                    tight: tight,
                    reducedMotion: reducedMotion,
                    select: { model.choose(destination: false) },
                    drop: { model.acceptDrop($0, role: .source) },
                    clear: { model.clearSelection(.source) },
                    reveal: { if let url = model.source { model.reveal(url) } },
                    copy: { if let url = model.source { model.copyPath(url) } },
                    canCopy: model.canCopyPaths,
                    openEditor: { model.open() }
                )

                CompactSelectionTile(
                    role: .destination,
                    url: (model.buttonConfirmed ? model.createdLink : nil) ?? model.destination,
                    title: "Choose destination",
                    caption: model.createdLink != nil && model.buttonConfirmed ? "Symbolic link" : "Destination",
                    linked: model.createdLink != nil && model.buttonConfirmed,
                    highlighted: highlightedRole == .destination,
                    disabled: disabled,
                    loading: model.loadingRoles.contains(.destination),
                    targeted: $destinationTargeted,
                    iconSize: iconSize,
                    cornerRadius: cornerRadius,
                    fontSize: labelFontSize,
                    tight: tight,
                    reducedMotion: reducedMotion,
                    select: { if model.createdLink != nil { model.reveal() } else { model.choose(destination: true) } },
                    drop: { model.acceptDrop($0, role: .destination) },
                    clear: { model.clearSelection(.destination) },
                    reveal: { if let url = model.createdLink ?? model.destination { model.reveal(url) } },
                    copy: { if let url = model.createdLink ?? model.destination { model.copyPath(url) } },
                    canCopy: model.canCopyPaths,
                    change: { model.choose(destination: true) },
                    openEditor: { model.open() }
                )

                HStack(spacing: tight ? DroppySpacing.xsm : DroppySpacing.sm) {
                    bottomActionButton(height: buttonHeight, fontSize: labelFontSize)
                    if hasAnythingToClear {
                        Button { model.reset(reducedMotion: reducedMotion) } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(DroppyWashCircleButtonStyle(
                            diameter: buttonHeight,
                            tone: .neutral,
                            usesAdaptiveForegrounds: context.usesAdaptiveForegrounds
                        ))
                        .disabled(disabled)
                        .accessibilityLabel(model.createdLink != nil ? "New symlink" : "Clear selections")
                        .help(model.createdLink != nil ? "Start a new symlink; the created symbolic link stays on disk" : "Clear selections; files stay on disk")
                        .transition(reducedMotion ? .identity : DroppyTransition.element)
                    }
                }
                .frame(height: buttonHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(!context.isShelfTransitioning)
        .animation(reducedMotion ? nil : DroppyAnimation.state, value: highlightedRole)
        .animation(reducedMotion ? nil : DroppyAnimation.state, value: hasAnythingToClear)
        .animation(reducedMotion ? nil : DroppyAnimation.stateEmphasis, value: model.buttonConfirmed)
        .animation(reducedMotion ? nil : DroppyAnimation.state, value: model.buttonReady)
        .animation(reducedMotion ? nil : DroppyAnimation.state, value: showsConflictWarning)
        .onAppear { if !context.isPreview { model.editorVisibility(surfaceID, visible: true) } }
        .onDisappear {
            sourceTargeted = false; destinationTargeted = false
            if !context.isPreview { model.editorVisibility(surfaceID, visible: false) }
        }
    }

    private var bottomActionTone: DroppyWashTone {
        if showsConflictWarning || errorMessage != nil { return .accent(.orange) }
        if model.buttonConfirmed { return .accent(.green) }
        if model.workState == .creating || model.canAttemptCreation {
            return .accent(AdaptiveColors.notchSurfacePrimaryText)
        }
        return .neutral
    }

    private var bottomActionDisabled: Bool {
        if disabled { return true }
        if showsConflictWarning { return false }
        if model.buttonReady { return false }
        return !model.canAttemptCreation
    }

    private var bottomActionHelp: String {
        if model.buttonReady { return "Reveal the created symbolic link in Finder" }
        if showsConflictWarning { return "Change the source or destination. Existing items are never replaced." }
        if let errorMessage { return errorMessage }
        return "Create a symbolic link without replacing existing items"
    }

    @ViewBuilder
    private func bottomActionButton(height: CGFloat, fontSize: CGFloat) -> some View {
        let showsStatusOverlay = showsConflictWarning || model.workState == .creating || (errorMessage != nil && !model.buttonConfirmed)
        Button {
            guard !disabled, !showsConflictWarning else { return }
            if model.buttonReady {
                model.reveal()
            } else {
                model.create(reducedMotion: true)
            }
        } label: {
            ZStack {
                SymlinkActionContent(
                    reducedMotion: reducedMotion,
                    phase: model.buttonReady ? 2 : model.buttonConfirmed ? 1 : 0
                )
                .animation(
                    reducedMotion ? nil : .smooth(duration: model.renderingTuning.confirmationDuration),
                    value: model.buttonConfirmed
                )
                .animation(
                    reducedMotion ? nil : .smooth(duration: model.renderingTuning.finderDuration),
                    value: model.buttonReady
                )
                .opacity(showsStatusOverlay ? 0 : 1)
                .accessibilityHidden(showsStatusOverlay)

                if model.workState == .creating {
                    HStack(spacing: DroppySpacing.xsm) {
                        ProgressView().controlSize(.mini)
                        Text("Creating…")
                    }
                } else if showsConflictWarning {
                    HStack(spacing: DroppySpacing.xsm) {
                        Image(systemName: "exclamationmark.circle")
                        Text("Name already exists")
                    }
                } else if let errorMessage, !model.buttonConfirmed {
                    HStack(spacing: DroppySpacing.xsm) {
                        Image(systemName: "exclamationmark.circle")
                        Text(errorMessage)
                    }
                }
            }
            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(DroppyWashPillButtonStyle(
            height: height,
            tone: bottomActionTone,
            usesAdaptiveForegrounds: context.usesAdaptiveForegrounds
        ))
        .disabled(bottomActionDisabled)
        .allowsHitTesting(!disabled && !showsConflictWarning)
        .accessibilityRespondsToUserInteraction(!disabled && !showsConflictWarning)
        .help(bottomActionHelp)
    }
}

private struct CompactSelectionTile: View {
    let role: SelectionRole
    let url: URL?
    let title: String
    let caption: String
    let linked: Bool
    let highlighted: Bool
    let disabled: Bool
    let loading: Bool
    @Binding var targeted: Bool
    let iconSize: CGFloat
    let cornerRadius: CGFloat
    let fontSize: CGFloat
    let tight: Bool
    let reducedMotion: Bool
    let select: () -> Void
    let drop: ([NSItemProvider]) -> Bool
    let clear: () -> Void
    let reveal: () -> Void
    let copy: () -> Void
    let canCopy: Bool
    var change: (() -> Void)? = nil
    let openEditor: () -> Void
    @State private var hover = false

    private var iconForeground: Color {
        highlighted ? .white : AdaptiveColors.notchSurfaceTertiaryText
    }

    private var textForeground: Color {
        if highlighted { return .white }
        return url != nil ? AdaptiveColors.notchSurfacePrimaryText : AdaptiveColors.notchSurfaceSecondaryText
    }

    var body: some View {
        Button(action: select) {
            HStack(spacing: DroppySpacing.sm) {
                Group {
                    if loading {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Loading \(caption.lowercased())")
                    } else if let url {
                        FileGlyph(url: url, linked: linked, size: iconSize)
                    } else {
                        Image(systemName: role == .source ? "doc.badge.plus" : "folder.badge.plus")
                            .font(.system(size: tight ? 15 : 20, weight: .regular))
                            .foregroundStyle(iconForeground)
                    }
                }
                .frame(width: iconSize, height: iconSize)

                Text(url?.lastPathComponent ?? title)
                    .font(.system(size: fontSize, weight: highlighted || url != nil ? .semibold : .medium))
                    .foregroundStyle(textForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, tight ? DroppySpacing.sm : DroppySpacing.smd)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(highlighted ? Color.blue : AdaptiveColors.notchSurfaceCardFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color.white.opacity(hover && !disabled ? (highlighted ? 0.08 : 0.045) : 0))
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(SymlinkerTileStyle())
        .disabled(disabled)
        .scaleEffect(targeted && !disabled && !reducedMotion ? 1.02 : 1)
        .onHover { hover = $0 }
        .animation(reducedMotion ? nil : DroppyAnimation.hover, value: hover)
        .animation(reducedMotion ? nil : DroppyAnimation.stateEmphasis, value: targeted)
        .help(url.map { "\(caption): \($0.path)" } ?? title)
        .accessibilityLabel("\(caption): \(url?.lastPathComponent ?? title)")
        .accessibilityHint(linked ? "Reveal the symbolic link in Finder" : "Click to choose, or drop a \(role == .source ? "file or folder" : "folder")")
        .accessibilityValue(url?.path ?? "Not selected")
        .contextMenu {
            if !disabled {
                Button("Change \(role == .source ? "source" : "destination")…", action: change ?? select)
                if url != nil {
                    Button("Clear selection", action: clear)
                    Divider()
                    Button("Show in Finder", action: reveal)
                    Button("Copy path", action: copy)
                        .disabled(!canCopy)
                        .help(canCopy ? "Copy the full path" : "Allow clipboard access for Symlinker to copy paths")
                }
                Divider()
                Button("Open full editor…", action: openEditor)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            targeted = false
            guard !disabled else { return false }
            return drop(providers)
        }
        .onChange(of: disabled) { _, isDisabled in
            if isDisabled { targeted = false }
        }
        .onDisappear { targeted = false }
    }
}
