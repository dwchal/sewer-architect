//
//  Weather.swift
//  Sewer Architect
//
//  Weather drives stormwater. Storms spike flow (and overwhelm combined
//  sewers → overflows); droughts reduce flow (and invite blockages / odor).
//

import Foundation

enum WeatherKind: String {
    case clear
    case rain
    case storm
    case drought

    var displayName: String {
        switch self {
        case .clear:   return "Clear"
        case .rain:    return "Rain"
        case .storm:   return "Storm"
        case .drought: return "Drought"
        }
    }

    /// Multiplier applied to stormwater runoff.
    var rainIntensity: Double {
        switch self {
        case .clear:   return 0.0
        case .rain:    return 1.0
        case .storm:   return 3.0
        case .drought: return 0.0
        }
    }

    /// Multiplier on blockage chance (drought concentrates waste → clogs).
    var blockageFactor: Double {
        switch self {
        case .drought: return 2.5
        default:       return 1.0
        }
    }
}

struct Weather {
    private(set) var current: WeatherKind = .clear
    private(set) var ticksRemaining: Int = 0
    private var rng: SplitMix64

    /// Difficulty knob: scales how often severe weather strikes.
    var stormFrequency: Double = 1.0

    init(seed: UInt64) {
        rng = SplitMix64(seed: seed &* 0x2545F4914F6CDD1D)
    }

    mutating func advance(season: Int) {
        if ticksRemaining > 0 {
            ticksRemaining -= 1
            return
        }
        // Pick the next spell of weather. Storm season (every 4th season)
        // weights toward heavy rain.
        let stormSeason = (season % 4 == 3)
        let roll = Double(rng.next() % 1000) / 1000.0
        let stormChance = (stormSeason ? 0.28 : 0.10) * stormFrequency
        let rainChance = (stormSeason ? 0.40 : 0.28)
        let droughtChance = 0.08

        if roll < stormChance {
            current = .storm
            ticksRemaining = 3 + Int(rng.next() % 4)
        } else if roll < stormChance + rainChance {
            current = .rain
            ticksRemaining = 4 + Int(rng.next() % 6)
        } else if roll < stormChance + rainChance + droughtChance {
            current = .drought
            ticksRemaining = 8 + Int(rng.next() % 8)
        } else {
            current = .clear
            ticksRemaining = 6 + Int(rng.next() % 10)
        }
    }
}
