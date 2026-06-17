//
//  Career.swift
//  Sewer Architect
//
//  Career mode: a chain of cities with escalating complexity — a small town,
//  a growing suburb, then a big aging city with a legacy combined system to
//  retrofit. Each level unlocks more tech and raises the stakes.
//

import Foundation

struct CareerLevel {
    let name: String
    let blurb: String
    let seed: UInt64
    let startingCash: Int
    let availableMaterials: [PipeMaterial]
    let availablePlantTiers: [PlantTier]
    let stormFrequency: Double
    let growthRate: Double
    let legacy: Bool
    let scenario: Scenario
}

enum Career {
    static let levels: [CareerLevel] = [
        CareerLevel(
            name: "Mudville",
            blurb: "A sleepy town. Get everyone connected and keep the creek clean.",
            seed: 0xA11CE,
            startingCash: 6_500,
            availableMaterials: [.clay, .pvc],
            availablePlantTiers: [.primary, .secondary],
            stormFrequency: 0.7,
            growthRate: 0.8,
            legacy: false,
            scenario: Scenario(name: "Mudville",
                               targetPopulation: 160,
                               maxOverflowsPerQuarter: 6,
                               requirePositiveCash: true,
                               deadlineQuarters: 16)
        ),
        CareerLevel(
            name: "Sprawlburg",
            blurb: "Booming suburb. Factories and strip malls are moving in fast.",
            seed: 0x5B2A77,
            startingCash: 5_500,
            availableMaterials: [.clay, .pvc, .concrete],
            availablePlantTiers: [.primary, .secondary],
            stormFrequency: 1.0,
            growthRate: 1.3,
            legacy: false,
            scenario: Scenario(name: "Sprawlburg",
                               targetPopulation: 360,
                               maxOverflowsPerQuarter: 5,
                               requirePositiveCash: true,
                               deadlineQuarters: 20)
        ),
        CareerLevel(
            name: "Old Town",
            blurb: "A century-old city on a single clay combined trunk. Retrofit it before storm season.",
            seed: 0x0FDC17,
            startingCash: 4_500,
            availableMaterials: PipeMaterial.allCases,
            availablePlantTiers: PlantTier.allCases,
            stormFrequency: 1.5,
            growthRate: 1.0,
            legacy: true,
            scenario: Scenario(name: "Old Town",
                               targetPopulation: 600,
                               maxOverflowsPerQuarter: 4,
                               requirePositiveCash: true,
                               deadlineQuarters: 28)
        )
    ]
}
