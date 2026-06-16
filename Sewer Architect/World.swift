//
//  World.swift
//  Sewer Architect
//
//  Holds the grid of tiles and the entity dictionaries for the v0 prototype.
//

import Foundation

final class World {
    let width: Int
    let height: Int

    var tiles: [[TileContent]]
    var houses: [Int: House] = [:]
    var plants: [Int: Plant] = [:]
    var pipes: [GridCoord: PipeState] = [:]

    private var nextHouseId: Int = 0
    private var nextPlantId: Int = 0

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.tiles = Array(
            repeating: Array(repeating: .empty, count: height),
            count: width
        )
    }

    func inBounds(_ c: GridCoord) -> Bool {
        c.x >= 0 && c.x < width && c.y >= 0 && c.y < height
    }

    func tile(at c: GridCoord) -> TileContent? {
        guard inBounds(c) else { return nil }
        return tiles[c.x][c.y]
    }

    @discardableResult
    func place(_ tool: BuildTool, at c: GridCoord) -> Bool {
        guard inBounds(c) else { return false }
        switch tool {
        case .none:
            return false
        case .erase:
            return erase(at: c)
        case .pipe:
            guard tiles[c.x][c.y] == .empty else { return false }
            tiles[c.x][c.y] = .pipe
            pipes[c] = PipeState()
            return true
        case .house:
            guard tiles[c.x][c.y] == .empty else { return false }
            let id = nextHouseId
            nextHouseId += 1
            tiles[c.x][c.y] = .house(id: id)
            houses[id] = House(id: id, coord: c)
            return true
        case .plant:
            guard tiles[c.x][c.y] == .empty else { return false }
            let id = nextPlantId
            nextPlantId += 1
            tiles[c.x][c.y] = .plant(id: id)
            plants[id] = Plant(id: id, coord: c)
            return true
        }
    }

    @discardableResult
    func erase(at c: GridCoord) -> Bool {
        guard inBounds(c) else { return false }
        switch tiles[c.x][c.y] {
        case .empty:
            return false
        case .pipe:
            pipes.removeValue(forKey: c)
        case .house(let id):
            houses.removeValue(forKey: id)
        case .plant(let id):
            plants.removeValue(forKey: id)
        }
        tiles[c.x][c.y] = .empty
        return true
    }
}
