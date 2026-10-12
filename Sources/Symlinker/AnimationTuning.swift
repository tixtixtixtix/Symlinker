import Foundation

struct AnimationTuning: Codable, Equatable, Sendable {
    var stretchDuration = 0.34
    var splitDuration = 0.22
    var recoilDuration = 0.22
    var settleDuration = 0.32
    var confirmationDuration = 0.50
    var finderDuration = 0.50
    var blur = 5.0
    var rebound = 2.2
    var damping = 5.74
    var squash = 0.20
    var splitSoftness = 0.03
    var trails = 0.0
    var totalDuration: Double { stretchDuration + splitDuration + recoilDuration + settleDuration }
    static let defaults = AnimationTuning()
    static let storageKey = "app.getdroppy.symlinker.animationTuning.v3"
    private static let legacyDefaults: Self = {
        var value = Self()
        value.stretchDuration = 0.28; value.splitDuration = 0.15
        value.recoilDuration = 0.15; value.settleDuration = 0.30
        value.blur = 5; value.rebound = 2.2; value.damping = 10.98
        value.squash = 0.18; value.splitSoftness = 0.03; value.trails = 0.25
        return value
    }()
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid else { return defaults }
        // Adopt the new factory motion without replacing a user's tuned preset.
        return value == legacyDefaults ? defaults : value
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
        let t = min(1, max(0, (clock - 0.38 - delay) / (0.62 - delay)))
        let decay = CGFloat(damping) * 0.85
        let frequency = 7.5 + CGFloat(rebound) * 0.8
        let residual = exp(-decay * t) * (cos(frequency * t) + decay / frequency * sin(frequency * t))
        // Recoil and settling share one spring; the tail reaches rest with zero velocity.
        return 1 - residual * (1 - ease((t - 0.65) / 0.35))
    }
    func reboundAmount(at clock: CGFloat, delay: CGFloat = 0) -> CGFloat {
        let t = min(1, max(0, (clock - 0.38 - delay) / (0.62 - delay)))
        let envelope = pow(sin(.pi * t), 2) * exp(-CGFloat(damping) * 0.25 * t)
        return CGFloat(rebound) * 0.07 * envelope * cos(2 * .pi * t)
    }
    // Scalar Hermite segments avoid allocating collections on every display frame.
    func visualClock(_ progress: CGFloat) -> CGFloat {
        let total = totalDuration
        let a = stretchDuration / total
        let b = (stretchDuration + splitDuration) / total
        let c = (stretchDuration + splitDuration + recoilDuration) / total
        let s0 = 0.28 / a
        let s1 = 0.10 / (b - a)
        let s2 = 0.32 / (c - b)
        let s3 = 0.30 / (1 - c)
        let m1 = 2 * s0 * s1 / (s0 + s1)
        let m2 = 2 * s1 * s2 / (s1 + s2)
        let m3 = 2 * s2 * s3 / (s2 + s3)
        let x = min(1, max(0, Double(progress)))
        if x <= a { return segment(x, start: 0, end: a, from: 0, to: 0.28, incoming: 0, outgoing: m1) }
        if x <= b { return segment(x, start: a, end: b, from: 0.28, to: 0.38, incoming: m1, outgoing: m2) }
        if x <= c { return segment(x, start: b, end: c, from: 0.38, to: 0.70, incoming: m2, outgoing: m3) }
        return segment(x, start: c, end: 1, from: 0.70, to: 1, incoming: m3, outgoing: 0)
    }
    private func segment(_ x: Double, start: Double, end: Double, from: Double, to: Double,
                         incoming: Double, outgoing: Double) -> CGFloat {
        let width = end - start
        let t = (x - start) / width
        let t2 = t * t, t3 = t2 * t
        return CGFloat((2*t3 - 3*t2 + 1) * from + (t3 - 2*t2 + t) * width * incoming
                       + (-2*t3 + 3*t2) * to + (t3 - t2) * width * outgoing)
    }
}
