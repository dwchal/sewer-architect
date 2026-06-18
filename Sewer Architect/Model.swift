//
//  Model.swift
//  Sewer Architect
//
//  Core model types. Expanded from the v0 prototype to cover the design spec:
//  zones, pipe materials, gravity/elevation, pump (lift) stations, treatment
//  tiers, stormwater infrastructure, aging/condition, and build economy.
//

import Foundation

// MARK: - Geometry

struct GridCoord: Hashable, Comparable {
    let x: Int
    let y: Int

    func offset(dx: Int, dy: Int) -> GridCoord {
        GridCoord(x: x + dx, y: y + dy)
    }

    var orthogonalNeighbors: [GridCoord] {
        [
            offset(dx: 1, dy: 0),
            offset(dx: -1, dy: 0),
            offset(dx: 0, dy: 1),
            offset(dx: 0, dy: -1)
        ]
    }

    func manhattanDistance(to other: GridCoord) -> Int {
        abs(x - other.x) + abs(y - other.y)
    }

    /// Row-major ordering. Used so RNG-driven loops over the pipe network
    /// iterate in a deterministic order, since Swift's Dictionary keys view
    /// is unordered across runs (hash seed is randomized).
    static func < (lhs: GridCoord, rhs: GridCoord) -> Bool {
        lhs.x != rhs.x ? lhs.x < rhs.x : lhs.y < rhs.y
    }
}

// MARK: - Zones (city development)

/// The kind of parcel that develops on the map. Drives waste load, stormwater
/// runoff, and how unhappy residents get about smells, backups, and rate hikes.
enum ZoneType: String, CaseIterable {
    case residential
    case commercial
    case industrial

    /// Sanitary waste produced per population unit per tick.
    var loadPerPop: Int {
        switch self {
        case .residential: return 1
        case .commercial:  return 2
        case .industrial:  return 3
        }
    }

    /// How much stormwater this parcel sheds during rain (more pavement = more).
    var runoffFactor: Double {
        switch self {
        case .residential: return 1.0
        case .commercial:  return 1.6
        case .industrial:  return 1.4
        }
    }

    /// Only residents file complaints / vote; industry tolerates smell better.
    var smellSensitivity: Double {
        switch self {
        case .residential: return 1.0
        case .commercial:  return 0.5
        case .industrial:  return 0.1
        }
    }

    var displayName: String {
        switch self {
        case .residential: return "Residential"
        case .commercial:  return "Commercial"
        case .industrial:  return "Industrial"
        }
    }

    var shortName: String {
        switch self {
        case .residential: return "Res"
        case .commercial:  return "Com"
        case .industrial:  return "Ind"
        }
    }
}

// MARK: - Pipe materials (capacity / durability / cost tradeoffs)

enum PipeMaterial: String, CaseIterable {
    case clay
    case pvc
    case concrete
    case trenchless

    /// Flow units carried per tick at full condition.
    var baseCapacity: Int {
        switch self {
        case .clay:       return 4
        case .pvc:        return 8
        case .concrete:   return 16
        case .trenchless: return 24
        }
    }

    var buildCost: Int {
        switch self {
        case .clay:       return 20
        case .pvc:        return 55
        case .concrete:   return 130
        case .trenchless: return 320
        }
    }

    /// Condition points lost per tick from ageing/corrosion/root intrusion.
    var decayPerTick: Double {
        switch self {
        case .clay:       return 0.30
        case .pvc:        return 0.12
        case .concrete:   return 0.06
        case .trenchless: return 0.02
        }
    }

    var displayName: String {
        switch self {
        case .clay:       return "Clay"
        case .pvc:        return "PVC"
        case .concrete:   return "Concrete"
        case .trenchless: return "Trenchless"
        }
    }

    /// Next tier up for the "dig up the street and upsize" upgrade action.
    var upgraded: PipeMaterial? {
        switch self {
        case .clay:       return .pvc
        case .pvc:        return .concrete
        case .concrete:   return .trenchless
        case .trenchless: return nil
        }
    }
}

// MARK: - Treatment plant tiers

enum PlantTier: String, CaseIterable {
    case primary
    case secondary
    case tertiary

    /// Flow units treated per tick at full condition.
    var throughput: Int {
        switch self {
        case .primary:   return 24
        case .secondary: return 48
        case .tertiary:  return 96
        }
    }

    var buildCost: Int {
        switch self {
        case .primary:   return 600
        case .secondary: return 1800
        case .tertiary:  return 4500
        }
    }

    var maintenancePerTick: Int {
        switch self {
        case .primary:   return 6
        case .secondary: return 14
        case .tertiary:  return 32
        }
    }

    /// Fraction of pollution removed from treated flow before discharge.
    var effluentQuality: Double {
        switch self {
        case .primary:   return 0.40
        case .secondary: return 0.80
        case .tertiary:  return 0.97
        }
    }

    /// "Stink radius" in tiles. Better tech is enclosed and smells less.
    var smellRadius: Int {
        switch self {
        case .primary:   return 4
        case .secondary: return 3
        case .tertiary:  return 2
        }
    }

    var displayName: String {
        switch self {
        case .primary:   return "Primary"
        case .secondary: return "Secondary"
        case .tertiary:  return "Tertiary"
        }
    }

    var upgraded: PlantTier? {
        switch self {
        case .primary:   return .secondary
        case .secondary: return .tertiary
        case .tertiary:  return nil
        }
    }
}

// MARK: - Tile contents

enum TileContent: Equatable {
    case empty
    case pipe
    case house(id: Int)
    case plant(id: Int)
    case pump(id: Int)
    case drain(id: Int)
    case basin(id: Int)
    case lab(id: Int)

    var isConduit: Bool {
        switch self {
        case .pipe, .pump: return true
        default:           return false
        }
    }
}

// MARK: - Build tools

enum BuildTool: String, CaseIterable {
    case none
    case residential
    case commercial
    case industrial
    case pipe
    case pump
    case plant
    case drain
    case basin
    case lab       // wastewater pathogen-monitoring lab (public-health revenue)
    case upgrade   // dig up the street: upsize pipe / upgrade plant in place
    case repair    // dispatch a crew to restore condition / clear a blockage
    case erase

    var displayName: String {
        switch self {
        case .none:        return "—"
        case .residential: return "Res"
        case .commercial:  return "Com"
        case .industrial:  return "Ind"
        case .pipe:        return "Pipe"
        case .pump:        return "Pump"
        case .plant:       return "Plant"
        case .drain:       return "Drain"
        case .basin:       return "Basin"
        case .lab:         return "Lab"
        case .upgrade:     return "Upsize"
        case .repair:      return "Repair"
        case .erase:       return "Erase"
        }
    }
}

// MARK: - Entities

/// A developed parcel ("house" kept as the type name for continuity with v0,
/// but it now represents any zoned, populated parcel).
struct House {
    let id: Int
    let coord: GridCoord
    var zone: ZoneType
    var level: Int = 1            // grows over time as the city densifies
    var isConnected: Bool = false // had a working route to a plant this tick
    var isBackedUp: Bool = false  // produced more than the network could take
    var satisfaction: Double = 70 // 0...100, smoothed over time

    var population: Int { level * 4 }
    var load: Int { population * zone.loadPerPop }
}

struct Plant {
    let id: Int
    let coord: GridCoord
    var tier: PlantTier
    var condition: Double = 100
    var receivedThisTick: Int = 0
    var overflowedThisTick: Int = 0
    var lifetimeTreated: Int = 0

    var capacity: Int {
        Int(Double(tier.throughput) * max(0.30, condition / 100.0))
    }
}

/// Lift / pumping station: lets flow climb uphill, at the cost of money, power,
/// and the risk of failure. A backup pump keeps it online when the main fails.
struct PumpStation {
    static let baseCapacity: Int = 30
    static let buildCost: Int = 450
    static let backupCost: Int = 250
    static let maintenancePerTick: Int = 9

    let id: Int
    let coord: GridCoord
    var condition: Double = 100
    var hasBackupPump: Bool = false
    var online: Bool = true
    var throughThisTick: Int = 0

    var capacity: Int {
        guard online else { return 0 }
        return Int(Double(PumpStation.baseCapacity) * max(0.30, condition / 100.0))
    }
}

/// Stormwater inlet. Diverts rain runoff from nearby parcels away from the
/// sanitary network (into storm sewers / the outfall), easing combined-sewer
/// overflow pressure during storms.
struct StormDrain {
    static let buildCost: Int = 80
    static let intakePerTick: Int = 6

    let id: Int
    let coord: GridCoord
}

/// Retention basin. Buffers stormwater so it doesn't hit the network all at
/// once, then releases it slowly after the storm passes.
struct RetentionBasin {
    static let buildCost: Int = 220
    static let capacity: Int = 120
    static let releasePerTick: Int = 4

    let id: Int
    let coord: GridCoord
    var stored: Int = 0
}

/// Wastewater pathogen-monitoring lab. Samples the sewage from the connected
/// catchment around it (wastewater-based epidemiology) and earns ongoing
/// public-health surveillance-contract revenue, plus one-off grant windfalls
/// whenever it catches an outbreak signal early.
struct MonitoringLab {
    static let buildCost: Int = 350
    static let maintenancePerTick: Int = 5
    /// How far (in tiles) the lab can sample connected parcels.
    static let coverageRadius: Int = 5
    /// Surveillance fee paid per monitored person, per "month" (scaled per tick).
    static let feePerPopPerMonth: Double = 0.7

    let id: Int
    let coord: GridCoord
    var monitoredThisTick: Int = 0
    var lifetimeRevenue: Int = 0
    var outbreaksDetected: Int = 0
}

/// Per-tile pipe state: what it's made of, whether it carries stormwater, how
/// worn it is, and how much flowed through it this tick.
struct PipeState {
    var material: PipeMaterial
    var combined: Bool          // also carries stormwater runoff
    var condition: Double = 100 // 0...100; degrades with age, restored by crews
    var blocked: Bool = false   // grease / roots / "mystery item" — zero flow
    var flowThisTick: Int = 0

    /// Usable capacity this tick, reduced by wear and zeroed by a blockage.
    var capacity: Int {
        guard !blocked else { return 0 }
        let factor = max(0.25, condition / 100.0)
        return Int(Double(material.baseCapacity) * factor)
    }

    var fillFraction: Double {
        let cap = max(1, material.baseCapacity)
        return Double(flowThisTick) / Double(cap)
    }
}
