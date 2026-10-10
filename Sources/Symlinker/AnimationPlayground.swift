import AppKit
import DroppyKit
import SwiftUI

struct AnimationPlaygroundView: View {
    @ObservedObject var owner: SymlinkerDroplet
    @StateObject private var demo: SymlinkerDroplet
    @State private var loop = false
    @State private var reducedMotion = false
    @State private var copied = false
    @State private var playback: Task<Void, Never>?

    init(owner: SymlinkerDroplet) {
        self.owner = owner
        let preview = SymlinkerDroplet()
        preview.configureDemo(); preview.tuning = owner.tuning
        _demo = StateObject(wrappedValue: preview)
    }
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Animation preview").font(.title2.weight(.semibold))
                Text("Replay as often as you like. No files or symbolic links are created.")
                    .font(.callout).foregroundStyle(.secondary)
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 30, style: .continuous).fill(.black)
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(0.06)).frame(width: 150, height: 20)
                    SymlinkerPanel(model: demo, previewReducedMotion: reducedMotion)
                        .frame(width: 352, height: 156).padding(.top, 38)
                }.frame(width: 384, height: 220)
                HStack {
                    Button { play() } label: { Label("Replay animation", systemImage: "play.fill") }
                        .buttonStyle(DroppyAccentButtonStyle(color: .white, size: .small))
                        .disabled(demo.isCreating)
                    Spacer()
                    Toggle("Loop", isOn: $loop).toggleStyle(.checkbox)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Scrub preview").font(.callout)
                        Spacer()
                        Text(demo.isCreating ? "Playing…" : "\(Int(demo.progress * 100))%")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(get: { Double(demo.progress) }, set: { demo.scrub($0) }), in: 0...1)
                        .disabled(demo.isCreating || reducedMotion)
                }
                Toggle("Preview Reduce Motion", isOn: $reducedMotion).toggleStyle(.checkbox)
                    .disabled(demo.isCreating)
                HStack {
                    Text("Tile sequence").foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.2f seconds", owner.tuning.totalDuration)).monospacedDigit()
                }.font(.callout)
                Spacer(minLength: 0)
                HStack {
                    Button(copied ? "Copied" : "Copy settings") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(owner.tuning.summary, forType: .string)
                        copied = true
                    }.buttonStyle(DroppyQuietButtonStyle(size: .small))
                    Spacer()
                    Button("Reset defaults") { owner.tuning = .defaults }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small)).disabled(demo.isCreating)
                }
                Text("Changes apply on the next replay and are saved for real links. Copy settings to share your preferred values.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(width: 384)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    group("Duration per animation") {
                        parameter("Stretch", key: \.stretchDuration, range: 0.05...2, unit: "s")
                        parameter("Split", key: \.splitDuration, range: 0.05...2, unit: "s")
                        parameter("Recoil", key: \.recoilDuration, range: 0.05...5, unit: "s")
                        parameter("Settle", key: \.settleDuration, range: 0.05...5, unit: "s")
                        parameter("Checkmark transition", key: \.confirmationDuration, range: 0.05...1, unit: "s")
                        parameter("Finder transition", key: \.finderDuration, range: 0.05...1, unit: "s")
                    }
                    group("Blur and motion") {
                        parameter("Motion blur", key: \.blur, range: 0...12, unit: "pt")
                        parameter("Rebound strength", key: \.rebound, range: 0...2.2)
                        parameter("Spring damping", key: \.damping, range: 5...14)
                        parameter("Stretch squash", key: \.squash, range: 0...0.40)
                        parameter("Split softness", key: \.splitSoftness, range: 0.03...0.30)
                        parameter("Motion trails", key: \.trails, range: 0...0.25)
                    }
                }.padding(.trailing, 8)
            }
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .preferredColorScheme(.dark)
        .onChange(of: owner.tuning) { _, settings in
            demo.tuning = settings; copied = false
        }
        .onDisappear { playback?.cancel(); demo.deactivate() }
    }
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            content()
        }
    }
    private func parameter(_ title: String, key: WritableKeyPath<AnimationTuning, Double>,
                           range: ClosedRange<Double>, unit: String = "") -> some View {
        let binding = Binding<Double>(get: { owner.tuning[keyPath: key] }, set: { value in
            var settings = owner.tuning
            settings[keyPath: key] = min(range.upperBound, max(range.lowerBound, (value * 100).rounded() / 100))
            owner.tuning = settings
        })
        return AnimationParameterRow(title: title, value: binding, range: range, unit: unit)
    }
    private func play() {
        playback?.cancel()
        playback = Task { @MainActor in
            repeat {
                demo.tuning = owner.tuning
                demo.replay(reducedMotion: reducedMotion)
                do {
                    while demo.isCreating { try await Task.sleep(for: .milliseconds(30)) }
                    guard loop else { return }
                    try await Task.sleep(for: .milliseconds(200))
                } catch { return }
            } while !Task.isCancelled
        }
    }
}

extension SymlinkerDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        AnyView(AnimationSettingsView(owner: self))
    }
    public var settingsSearchEntries: [SettingsSearchEntry] {
        [.init(title: "Animation playground", keywords: ["test", "preview", "duration", "blur", "rebound"])]
    }
}

private struct AnimationSettingsView: View {
    @ObservedObject var owner: SymlinkerDroplet
    var body: some View {
        DropletSettingsPane {
            DropletSettingsCard {
                DropletControlRow(title: "Animation playground") {
                    Button("Open…") { owner.openPlayground() }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
                DropletControlRow(title: "Tile sequence duration") {
                    DropletValuePill(text: String(format: "%.2f s", owner.tuning.totalDuration))
                }
            }
        }
    }
}

@MainActor
final class AnimationPlaygroundWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) {
        // Removing the hosted view stops looping and cancels its demo task.
        (notification.object as? NSWindow)?.contentView = nil
        onClose()
    }
}

private struct AnimationParameterRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    @State private var draft = ""
    @FocusState private var isEditing: Bool
    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(title).font(.callout)
                Spacer(minLength: 8)
                TextField(title, text: $draft)
                    .textFieldStyle(.roundedBorder).frame(width: 64)
                    .multilineTextAlignment(.trailing).font(.caption.monospacedDigit())
                    .focused($isEditing).onSubmit { commit(); isEditing = false }
                    .help("Type a value, then press Return to apply")
                    .accessibilityLabel("\(title) value")
                if !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(.secondary).frame(width: 16) }
            }
            Slider(value: $value, in: range).accessibilityLabel(title)
        }
        .onAppear { refresh() }
        .onChange(of: value) { _, _ in if !isEditing { refresh() } }
        .onChange(of: isEditing) { _, editing in if !editing { commit() } }
    }
    private func refresh() { draft = String(format: "%.2f", value) }
    private func commit() {
        if let number = Double(draft.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")), number.isFinite {
            value = min(range.upperBound, max(range.lowerBound, number))
        }
        refresh()
    }
}
