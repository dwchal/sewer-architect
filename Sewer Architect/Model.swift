//
//  Model.swift
//  Sewer Architect
//
//  Core model types for the v0 prototype.
//

import Foundation

struct GridCoord: Hashable {
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
}

enum TileContent: Equatable {
    case empty
    case pipe
    case house(id: Int)
    case plant(id: Int)
}

enum BuildTool: String, CaseIterable {
    case none
    case house
    case plant
    case pipe
    case erase
}

struct House {
    static let productionPerTick: Int = 1

    let id: Int
    let coord: GridCoord
    var isBackedUp: Bool = false
}

struct Plant {
    static let throughputPerTick: Int = 10

    let id: Int
    let coord: GridCoord
    var receivedThisTick: Int = 0
    var overflowedThisTick: Int = 0
    var lifetimeTreated: Int = 0
}

struct PipeState {
    static let capacityPerTick: Int = 3

    var flowThisTick: Int = 0
}
