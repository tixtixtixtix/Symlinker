import Foundation

struct AnimationTuning: Codable, Equatable, Sendable {
    var stretchDuration = 0.28
    var splitDuration = 0.15
    var recoilDuration = 0.15
    var settleDuration = 0.30
    var confirmationDuration = 0.50
    var finderDuration = 0.50
    var blur = 5.0
    var rebound = 2.2
    var damping = 10.98
    var squash = 0.18
    var splitSoftness = 0.03
    var trails = 0.25
    var totalDuration: Double { stretchDuration + splitDuration + recoilDuration + settleDuration }
    static let defaults = AnimationTuning()
    static let storageKey = "app.getdroppy.symlinker.animationTuning.v3"
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid else { return defaults }
        return value
    }
    var isValid: Bool {
        [stretchDuration, splitDuration].allSatisfy { $0.isFinite && (0.05...2).contains($0) }
        && [recoilDuration, settleDuration].allSatisfy { $0.isFinite && (0.05...5).contains($0) }
        && [confirmationDuration, finderDuration].allSatisfy { $0.isFinite && (0.05...1).contains($0) }
        && blur.isFinite && (0...12).contains(blur)
        && rebound.isFinite && (0...2.2).contains(rebound)
        && damping.isFinite && (5...14).contains(damping)
        && squash.isFinite && (0...0.40).contains(squash)
        && splitSoftness.isFinite && (0.03...0.30).contains(splitSoftness)
        && trails.isFinite && (0...0.25).contains(trails)
    }
    func save() {
        if isValid, let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.storageKey) }
    }
    var summary: String {
        """
        Symlinker animation settings
        Stretch: \(format(stretchDuration)) s
        Split: \(format(splitDuration)) s
        Recoil: \(format(recoilDuration)) s
        Settle: \(format(settleDuration)) s
        Total: \(format(totalDuration)) s
        Checkmark transition: \(format(confirmationDuration)) s
        Finder transition: \(format(finderDuration)) s
        Blur: \(format(blur)) pt
        Rebound: \(format(rebound))
        Damping: \(format(damping))
        Squash: \(format(squash * 100)) %
        Split softness: \(format(splitSoftness))
        Trails: \(format(trails))
        """
    }
    private func format(_ value: Double) -> String { String(format: "%.2f", value) }
    private func ease(_ value: CGFloat) -> CGFloat {
        let t = min(1, max(0, value))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }
    func stretchAmount(at clock: CGFloat) -> CGFloat { ease(clock / 0.28) }
    func splitAmount(at clock: CGFloat) -> CGFloat {
        // Softness shapes the easing; it must not shorten the selected split duration.
        let t = min(1, max(0, (clock - 0.28) / 0.10))
        let cubic = t * t * (3 - 2 * t)
        let softness = CGFloat(splitSoftness / 0.30)
        return cubic + (ease(t) - cubic) * softness
    }
    func returnAmount(at clock: CGFloat, delay: CGFloat = 0) -> CGFloat {
        let recoil = ease((clock - 0.38 - delay) / (0.32 - delay))
        guard clock > 0.70 else { return recoil }
        let settle = ease((clock - 0.70) / 0.30)
        return 1 + 0.028 * sin(2 * .pi * settle) * exp(-CGFloat(damping) * 0.35 * settle) * (1 - settle)
    }
    func reboundAmount(at clock: CGFloat, delay: CGFloat = 0) -> CGFloat {
        let peak = CGFloat(rebound) * 0.42
        guard clock > 0.70 else { return peak * ease((clock - 0.38 - delay) / (0.32 - delay)) }
        let rawSettle = (clock - 0.70) / 0.30
        let settle = ease(rawSettle)
        // Spend the entire settle duration relaxing the tall/skinny peak and its overshoot.
        return peak * cos(1.6 * .pi * settle) * exp(-CGFloat(damping) * 0.35 * settle)
            * (1 - ease((rawSettle - 0.70) / 0.30))
    }
    // A monotone cubic clock map preserves velocity across independently timed phases.
    func visualClock(_ progress: CGFloat) -> CGFloat {
        let total = totalDuration
        let knots: [Double] = [0, stretchDuration / total, (stretchDuration + splitDuration) / total,
                               (stretchDuration + splitDuration + recoilDuration) / total, 1]
        let values: [Double] = [0, 0.28, 0.38, 0.70, 1]
        let slopes = (0..<4).map { (values[$0 + 1] - values[$0]) / (knots[$0 + 1] - knots[$0]) }
        var tangents = [Double](repeating: 0, count: 5)
        for i in 1..<4 { tangents[i] = 2 * slopes[i - 1] * slopes[i] / (slopes[i - 1] + slopes[i]) }
        let x = min(1, max(0, Double(progress)))
        let i = (0..<4).first { x <= knots[$0 + 1] } ?? 3
        let width = knots[i + 1] - knots[i]
        let t = (x - knots[i]) / width
        let t2 = t * t, t3 = t2 * t
        return CGFloat((2*t3 - 3*t2 + 1) * values[i] + (t3 - 2*t2 + t) * width * tangents[i]
                       + (-2*t3 + 3*t2) * values[i + 1] + (t3 - t2) * width * tangents[i + 1])
    }
}
