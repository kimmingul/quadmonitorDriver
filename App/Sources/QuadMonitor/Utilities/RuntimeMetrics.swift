import Foundation

actor RuntimeMetrics {
    private var frameDurationsMs: [Double] = []

    func recordFrameDuration(_ ms: Double) {
        frameDurationsMs.append(ms)
        if frameDurationsMs.count > 600 {
            frameDurationsMs.removeFirst(frameDurationsMs.count - 600)
        }
    }

    func summary() -> String {
        guard !frameDurationsMs.isEmpty else {
            return "frames=0"
        }

        let sorted = frameDurationsMs.sorted()
        let avg = frameDurationsMs.reduce(0, +) / Double(frameDurationsMs.count)
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let maxValue = sorted.last ?? 0

        return String(
            format: "frames=%d avg=%.2fms p95=%.2fms max=%.2fms",
            frameDurationsMs.count,
            avg,
            p95,
            maxValue
        )
    }
}
