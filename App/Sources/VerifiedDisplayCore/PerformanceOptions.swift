import Foundation

public struct PerformanceOptions: Codable, Equatable, Sendable {
    public enum Scheduling: String, Codable, Sendable { case periodic, arrival }
    public enum Damage: String, Codable, Sendable { case cpu, metal }
    public enum Compression: String, Codable, Sendable { case delta, full }
    public var workers: Int
    public var scheduling: Scheduling
    public var damage: Damage
    public var compression: Compression
    public var queueDepth: Int

    public var reuseBuffers: Bool
    public var adaptiveWorkers: Bool
    public var overlapPreparation: Bool

    private enum CodingKeys: String, CodingKey {
        case workers, scheduling, damage, compression, queueDepth, reuseBuffers, adaptiveWorkers, overlapPreparation
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workers = try c.decode(Int.self, forKey: .workers)
        scheduling = try c.decode(Scheduling.self, forKey: .scheduling)
        damage = try c.decode(Damage.self, forKey: .damage)
        compression = try c.decode(Compression.self, forKey: .compression)
        queueDepth = try c.decode(Int.self, forKey: .queueDepth)
        reuseBuffers = try c.decodeIfPresent(Bool.self, forKey: .reuseBuffers) ?? false
        adaptiveWorkers = try c.decodeIfPresent(Bool.self, forKey: .adaptiveWorkers) ?? false
        overlapPreparation = try c.decodeIfPresent(Bool.self, forKey: .overlapPreparation) ?? false
    }
    public init(workers: Int = 4, scheduling: Scheduling = .periodic,
                damage: Damage = .cpu, compression: Compression = .delta, queueDepth: Int = 3,
                reuseBuffers: Bool = false, adaptiveWorkers: Bool = false, overlapPreparation: Bool = false) {
        self.workers=workers; self.scheduling=scheduling; self.damage=damage
        self.compression=compression; self.queueDepth=queueDepth
        self.reuseBuffers=reuseBuffers; self.adaptiveWorkers=adaptiveWorkers; self.overlapPreparation=overlapPreparation
    }
    public var isValid: Bool { [0,1,2,4,8].contains(workers) && [2,3,5].contains(queueDepth) }
    /// Avoid dispatch overhead on cursor-sized updates. The selected CPU budget
    /// is a ceiling, including when the parent apportions it across panels.
    public func workers(forChangedTiles count: Int) -> Int {
        guard adaptiveWorkers else { return workers }
        let desired = count < 512 ? 1 : count < 1024 ? 2 : count < 2048 ? 4 : 8
        return min(workers, desired)
    }
    /// Cursor-only USB writes are too short to justify speculative CPU work.
    public func shouldOverlap(changedTiles: Int) -> Bool {
        overlapPreparation && changedTiles >= 512
    }
    public var arguments: [String] {
        ["--encoder-workers",String(workers),"--scheduling",scheduling.rawValue,
         "--damage",damage.rawValue,"--compression",compression.rawValue,"--queue-depth",String(queueDepth),
         "--reuse-buffers",reuseBuffers ? "1" : "0", "--adaptive-workers",adaptiveWorkers ? "1" : "0",
         "--overlap-preparation",overlapPreparation ? "1" : "0"]
    }
}
