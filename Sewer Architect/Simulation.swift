//
//  Simulation.swift
//  Sewer Architect
//
//  Per-tick routing and capacity accounting. v0 uses BFS over the pipe graph
//  from each house to the nearest plant; no elevation/gravity yet.
//

import Foundation

final class Simulation {
    let world: World
    private(set) var tick: Int = 0

    init(world: World) {
        self.world = world
    }

    func step() {
        tick += 1
        resetPerTickState()

        // Process houses in id order so behavior is deterministic between runs.
        for houseId in world.houses.keys.sorted() {
            guard let house = world.houses[houseId] else { continue }
            let produced = House.productionPerTick

            guard let route = findRoute(from: house.coord) else {
                world.houses[houseId]?.isBackedUp = true
                continue
            }

            let minPipeRoom = route.path.map { coord -> Int in
                let used = world.pipes[coord]?.flowThisTick ?? 0
                return PipeState.capacityPerTick - used
            }.min() ?? 0

            let plantUsed = world.plants[route.plantId]?.receivedThisTick ?? 0
            let plantRoom = Plant.throughputPerTick - plantUsed

            let amount = max(0, min(produced, minPipeRoom, plantRoom))

            if amount < produced {
                world.houses[houseId]?.isBackedUp = true
            }

            if amount > 0 {
                for coord in route.path {
                    world.pipes[coord]?.flowThisTick += amount
                }
                world.plants[route.plantId]?.receivedThisTick += amount
                world.plants[route.plantId]?.lifetimeTreated += amount
            }
        }
    }

    private func resetPerTickState() {
        for coord in world.pipes.keys {
            world.pipes[coord]?.flowThisTick = 0
        }
        for id in world.plants.keys {
            world.plants[id]?.receivedThisTick = 0
            world.plants[id]?.overflowedThisTick = 0
        }
        for id in world.houses.keys {
            world.houses[id]?.isBackedUp = false
        }
    }

    private struct Route {
        let path: [GridCoord]
        let plantId: Int
    }

    /// BFS from the pipe tiles adjacent to a house, ending at the first pipe
    /// tile that touches any plant. Returns the pipe path and that plant's id.
    private func findRoute(from houseCoord: GridCoord) -> Route? {
        var visited: Set<GridCoord> = []
        var parents: [GridCoord: GridCoord] = [:]
        var queue: [GridCoord] = []

        for neighbor in houseCoord.orthogonalNeighbors {
            guard case .pipe = world.tile(at: neighbor) else { continue }
            if visited.insert(neighbor).inserted {
                queue.append(neighbor)
            }
        }

        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1

            // Done if any orthogonal neighbor is a plant.
            for neighbor in current.orthogonalNeighbors {
                if case .plant(let plantId) = world.tile(at: neighbor) {
                    return Route(path: reconstructPath(to: current, parents: parents),
                                 plantId: plantId)
                }
            }

            // Otherwise enqueue unvisited pipe neighbors.
            for neighbor in current.orthogonalNeighbors {
                guard case .pipe = world.tile(at: neighbor) else { continue }
                if visited.insert(neighbor).inserted {
                    parents[neighbor] = current
                    queue.append(neighbor)
                }
            }
        }
        return nil
    }

    private func reconstructPath(to end: GridCoord,
                                 parents: [GridCoord: GridCoord]) -> [GridCoord] {
        var path: [GridCoord] = [end]
        var current = end
        while let parent = parents[current] {
            path.append(parent)
            current = parent
        }
        return path.reversed()
    }
}
