//
//  World.swift
//  Sewer Architect
//
//  The grid: terrain elevation, tile contents, entity tables, and the build /
//  erase / upgrade / repair operations that spend money against the budget.
//

import Foundation

/// Result of attempting a build action, so the UI can explain failures.
enum BuildResult {
    case placed
    case rejectedOccupied
    case rejectedEmpty
    case rejectedFunds(needed: Int)
    case rejectedInvalid
    case repaired
    case upgraded
}

final class World {
    let width: Int
    let height: Int

    /// Elevation per tile (higher = uphill). Gravity moves flow to lower tiles;
    /// climbing uphill requires a pump station.
    var elevation: [[Int]]
    var tiles: [[TileContent]]

    var houses: [Int: House] = [:]
    var plants: [Int: Plant] = [:]
    var pumps: [Int: PumpStation] = [:]
    var drains: [Int: StormDrain] = [:]
    var basins: [Int: RetentionBasin] = [:]
    var pipes: [GridCoord: PipeState] = [:]

    /// Where the city discharges treated effluent (and, sadly, overflows). The
    /// low corner of the map. Used for environmental accounting / flavor.
    let outfall: GridCoord

    var finance = Finance()

    /// Player's current pipe material and plant tier selections for new builds.
    var selectedMaterial: PipeMaterial = .clay
    var selectedPlantTier: PlantTier = .primary
    /// Combined sewers carry stormwater too (cheap now, CSO risk later).
    var buildCombinedSewers: Bool = true

    private var nextId: Int = 0
    private func makeId() -> Int { defer { nextId += 1 }; return nextId }

    /// Create a developed parcel, sharing the same id space as manual builds so
    /// the city-growth system can never collide with the player's builds.
    @discardableResult
    func developParcel(_ zone: ZoneType, at c: GridCoord) -> Int? {
        guard inBounds(c), tiles[c.x][c.y] == .empty else { return nil }
        let id = makeId()
        tiles[c.x][c.y] = .house(id: id)
        houses[id] = House(id: id, coord: c, zone: zone)
        return id
    }

    /// Lay down a small starting town (a plant near the low corner, a few
    /// residential parcels, and gravity-fed pipes) free of charge, so a new
    /// game opens on something already flowing rather than a blank grid.
    func seedStartingCity() {
        func setPipe(_ c: GridCoord) {
            guard inBounds(c), tiles[c.x][c.y] == .empty else { return }
            tiles[c.x][c.y] = .pipe
            pipes[c] = PipeState(material: .clay, combined: true)
        }
        func setHouse(_ c: GridCoord, _ z: ZoneType) {
            guard inBounds(c), tiles[c.x][c.y] == .empty else { return }
            let id = makeId()
            tiles[c.x][c.y] = .house(id: id)
            houses[id] = House(id: id, coord: c, zone: z)
        }
        func setPlant(_ c: GridCoord) {
            guard inBounds(c), tiles[c.x][c.y] == .empty else { return }
            let id = makeId()
            tiles[c.x][c.y] = .plant(id: id)
            plants[id] = Plant(id: id, coord: c, tier: .primary)
        }

        setPlant(GridCoord(x: 2, y: 2))
        setPipe(GridCoord(x: 3, y: 2))
        setPipe(GridCoord(x: 4, y: 2))
        setPipe(GridCoord(x: 4, y: 3))
        setPipe(GridCoord(x: 3, y: 3))
        setHouse(GridCoord(x: 5, y: 2), .residential)
        setHouse(GridCoord(x: 5, y: 3), .residential)
        setHouse(GridCoord(x: 3, y: 4), .residential)
    }

    init(width: Int, height: Int, seed: UInt64 = 0xC0FFEE) {
        self.width = width
        self.height = height
        self.tiles = Array(
            repeating: Array(repeating: .empty, count: height),
            count: width
        )
        self.elevation = Array(
            repeating: Array(repeating: 0, count: height),
            count: width
        )
        self.outfall = GridCoord(x: 0, y: 0)
        generateTerrain(seed: seed)
    }

    // MARK: - Terrain

    /// A simple, deterministic terrain: a diagonal slope toward the outfall in
    /// the low corner, plus a couple of bumps so routing has character. Range
    /// is roughly 0...20.
    private func generateTerrain(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        // Two random "hills" to perturb the base slope.
        let hill1 = GridCoord(x: Int(rng.next() % UInt64(width)),
                              y: Int(rng.next() % UInt64(height)))
        let hill2 = GridCoord(x: Int(rng.next() % UInt64(width)),
                              y: Int(rng.next() % UInt64(height)))
        for x in 0..<width {
            for y in 0..<height {
                let slope = Double(x + y) / Double(width + height) * 14.0
                let c = GridCoord(x: x, y: y)
                let d1 = Double(c.manhattanDistance(to: hill1))
                let d2 = Double(c.manhattanDistance(to: hill2))
                let bump1 = max(0, 6.0 - d1) * 0.8
                let bump2 = max(0, 5.0 - d2) * 0.7
                elevation[x][y] = max(0, Int((slope + bump1 + bump2).rounded()))
            }
        }
    }

    func groundLevel(at c: GridCoord) -> Int {
        guard inBounds(c) else { return Int.max }
        return elevation[c.x][c.y]
    }

    // MARK: - Bounds / lookup

    func inBounds(_ c: GridCoord) -> Bool {
        c.x >= 0 && c.x < width && c.y >= 0 && c.y < height
    }

    func tile(at c: GridCoord) -> TileContent? {
        guard inBounds(c) else { return nil }
        return tiles[c.x][c.y]
    }

    // MARK: - Build catalog

    /// Money cost of using `tool` at `coord` with the current selections.
    func cost(of tool: BuildTool, at coord: GridCoord) -> Int {
        switch tool {
        case .none, .erase:        return 0
        case .residential,
             .commercial,
             .industrial:          return 60
        case .pipe:                return selectedMaterial.buildCost
        case .pump:                return PumpStation.buildCost
        case .plant:               return selectedPlantTier.buildCost
        case .drain:               return StormDrain.buildCost
        case .basin:               return RetentionBasin.buildCost
        case .upgrade:             return upgradeCost(at: coord)
        case .repair:              return repairCost(at: coord)
        }
    }

    private func upgradeCost(at c: GridCoord) -> Int {
        switch tile(at: c) {
        case .pipe:
            guard let next = pipes[c]?.material.upgraded else { return 0 }
            return next.buildCost + 40 // +disruption surcharge for digging
        case .plant(let id):
            guard let next = plants[id]?.tier.upgraded else { return 0 }
            return next.buildCost
        case .pump(let id):
            guard let pump = pumps[id], !pump.hasBackupPump else { return 0 }
            return PumpStation.backupCost
        default:
            return 0
        }
    }

    private func repairCost(at c: GridCoord) -> Int {
        switch tile(at: c) {
        case .pipe:        return 30
        case .pump:        return 60
        case .plant:       return 90
        default:           return 0
        }
    }

    // MARK: - Build / erase

    @discardableResult
    func place(_ tool: BuildTool, at c: GridCoord) -> BuildResult {
        guard inBounds(c) else { return .rejectedInvalid }
        switch tool {
        case .none:
            return .rejectedInvalid
        case .erase:
            return erase(at: c)
        case .upgrade:
            return upgrade(at: c)
        case .repair:
            return repair(at: c)
        case .residential, .commercial, .industrial,
             .pipe, .pump, .plant, .drain, .basin:
            return build(tool, at: c)
        }
    }

    private func build(_ tool: BuildTool, at c: GridCoord) -> BuildResult {
        guard tiles[c.x][c.y] == .empty else { return .rejectedOccupied }
        let price = cost(of: tool, at: c)
        guard finance.canAfford(price) else { return .rejectedFunds(needed: price) }

        switch tool {
        case .residential, .commercial, .industrial:
            let zone: ZoneType = tool == .residential ? .residential
                : (tool == .commercial ? .commercial : .industrial)
            let id = makeId()
            tiles[c.x][c.y] = .house(id: id)
            houses[id] = House(id: id, coord: c, zone: zone)
        case .pipe:
            tiles[c.x][c.y] = .pipe
            pipes[c] = PipeState(material: selectedMaterial,
                                 combined: buildCombinedSewers)
        case .pump:
            let id = makeId()
            tiles[c.x][c.y] = .pump(id: id)
            pumps[id] = PumpStation(id: id, coord: c)
        case .plant:
            let id = makeId()
            tiles[c.x][c.y] = .plant(id: id)
            plants[id] = Plant(id: id, coord: c, tier: selectedPlantTier)
        case .drain:
            let id = makeId()
            tiles[c.x][c.y] = .drain(id: id)
            drains[id] = StormDrain(id: id, coord: c)
        case .basin:
            let id = makeId()
            tiles[c.x][c.y] = .basin(id: id)
            basins[id] = RetentionBasin(id: id, coord: c)
        default:
            return .rejectedInvalid
        }
        finance.spend(price, reason: .construction)
        return .placed
    }

    @discardableResult
    func erase(at c: GridCoord) -> BuildResult {
        guard inBounds(c) else { return .rejectedInvalid }
        switch tiles[c.x][c.y] {
        case .empty:
            return .rejectedEmpty
        case .pipe:
            pipes.removeValue(forKey: c)
        case .house(let id):
            houses.removeValue(forKey: id)
        case .plant(let id):
            plants.removeValue(forKey: id)
        case .pump(let id):
            pumps.removeValue(forKey: id)
        case .drain(let id):
            drains.removeValue(forKey: id)
        case .basin(let id):
            basins.removeValue(forKey: id)
        }
        tiles[c.x][c.y] = .empty
        return .placed
    }

    private func upgrade(at c: GridCoord) -> BuildResult {
        let price = upgradeCost(at: c)
        switch tiles[c.x][c.y] {
        case .pipe:
            guard let next = pipes[c]?.material.upgraded else { return .rejectedInvalid }
            guard finance.canAfford(price) else { return .rejectedFunds(needed: price) }
            pipes[c]?.material = next
            pipes[c]?.condition = 100 // fresh pipe in the trench
            finance.spend(price, reason: .construction)
            return .upgraded
        case .plant(let id):
            guard let next = plants[id]?.tier.upgraded else { return .rejectedInvalid }
            guard finance.canAfford(price) else { return .rejectedFunds(needed: price) }
            plants[id]?.tier = next
            finance.spend(price, reason: .construction)
            return .upgraded
        case .pump(let id):
            guard let pump = pumps[id], !pump.hasBackupPump else { return .rejectedInvalid }
            guard finance.canAfford(price) else { return .rejectedFunds(needed: price) }
            pumps[id]?.hasBackupPump = true
            finance.spend(price, reason: .construction)
            return .upgraded
        default:
            return .rejectedInvalid
        }
    }

    private func repair(at c: GridCoord) -> BuildResult {
        let price = repairCost(at: c)
        switch tiles[c.x][c.y] {
        case .pipe:
            guard finance.canAfford(price) else { return .rejectedFunds(needed: price) }
            pipes[c]?.condition = 100
            pipes[c]?.blocked = false
            finance.spend(price, reason: .maintenance)
            return .repaired
        case .pump(let id):
            guard finance.canAfford(price) else { return .rejectedFunds(needed: price) }
            pumps[id]?.condition = 100
            pumps[id]?.online = true
            finance.spend(price, reason: .maintenance)
            return .repaired
        case .plant(let id):
            guard finance.canAfford(price) else { return .rejectedFunds(needed: price) }
            plants[id]?.condition = 100
            finance.spend(price, reason: .maintenance)
            return .repaired
        default:
            return .rejectedInvalid
        }
    }
}

// MARK: - Deterministic RNG

/// Small, fast, seedable PRNG so terrain and events are reproducible per seed.
nonisolated struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
