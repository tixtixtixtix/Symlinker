import DroppyKit
import SwiftUI
import UniformTypeIdentifiers

/// A separate paired composition, not a scaled-down copy of the editor.
struct SymlinkerCompactWidget: View {
    @ObservedObject var model: SymlinkerDroplet
    let context: ShelfWidgetContext
    @State private var surfaceID = UUID()
    @State private var sourceTargeted = false
    @State private var destinationTargeted = false
    @Environment(\.accessibilityReduceMotion) private var systemReducedMotion
    private var reducedMotion: Bool { systemReducedMotion || model.reducesPreviewMotion }
    private var disabled: Bool { context.isPreview || context.isShelfTransitioning || !model.canInteract }

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.xsm) {
                Image(systemName: model.hasTimedConflict && !model.conflictNoticeVisible ? "folder" : model.sessionState == .needsAttention ? "exclamationmark.circle" : "link")
                    .font(.system(size: 12))
                Text(model.statusTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if model.isCreating || model.isPicking || !model.loadingRoles.isEmpty || model.preflight == .checking {
                    ProgressView().controlSize(.mini)
                }
            }
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            .frame(height: 16)

            VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
                selection(.source, url: model.source, targeted: $sourceTargeted)
                selection(.destination, url: model.destination, targeted: $destinationTargeted)
            }
            Spacer(minLength: 0)
            HStack(spacing: DroppySpacing.sm) {
                Button(model.hasSelectionPair || model.source != nil ? "Continue" : "Open Symlinker") { model.open() }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
                    .disabled(context.isPreview || context.isShelfTransitioning || model.isDemo)
                    .help("Open the source and destination editor without clearing your selections")
                Spacer(minLength: 0)
                if model.createdLink != nil || model.existingLink != nil {
                    Button { model.reveal() } label: { Image(systemName: "folder") }
                        .buttonStyle(DroppyCircleButtonStyle(size: 24))
                        .disabled(disabled || model.isCreating)
                        .accessibilityLabel("Show symbolic link in Finder")
                }
            }
            .frame(height: SymlinkerMetrics.actionHeight)
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(!context.isShelfTransitioning)
        .onAppear { if !context.isPreview { model.editorVisibility(surfaceID, visible: true) } }
        .onDisappear {
            sourceTargeted = false; destinationTargeted = false
            if !context.isPreview { model.editorVisibility(surfaceID, visible: false) }
        }
        .animation(reducedMotion ? nil : DroppyAnimation.state, value: model.sessionState)
    }

    private func selection(_ role: SelectionRole, url: URL?, targeted: Binding<Bool>) -> some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: role == .source ? "doc" : "folder").accessibilityHidden(true)
            Text(url?.lastPathComponent ?? (role == .source ? "Drop a file or folder" : "Drop a destination folder"))
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 10))
        .foregroundStyle(targeted.wrappedValue && !disabled ? Color.mint : AdaptiveColors.notchSurfaceSecondaryText)
        .frame(height: 12)
        .contentShape(Rectangle())
        .help(url.map { "\(role.title): \($0.path)" } ?? "Drop \(role == .source ? "one file or folder" : "one folder") here")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(role.title)
        .accessibilityValue(url?.path ?? "Not selected")
        .onDrop(of: [UTType.fileURL], isTargeted: targeted) { providers in
            targeted.wrappedValue = false
            guard !disabled else { return false }
            return model.acceptDrop(providers, role: role)
        }
    }
}
