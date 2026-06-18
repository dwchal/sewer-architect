//
//  Simulation.swift
//  Sewer Architect
//
//  The tick engine. Each step advances time and weather, routes sanitary +
//  stormwater flow through the gravity/pumped pipe network to treatment plants,
//  ages infrastructure, rolls random events, grows the city, settles the
//  budget, updates citizen satisfaction, and tracks the score.
//

import Foundation

final class Simulation {
    let world: World
    private(set) var tick: Int = 0

    // Calendar
    static let ticksPerQuarter: Int = 24
    var quarter: Int { tick / Simulation.ticksPerQuarter }
    var year: Int { quarter / 4 }

    // Subsystems
    var weather: Weather
    let log = EventLog()
    var score = ScoreTracker()
    var mode: GameMode = .sandbox
    var scenario = Scenario()
    private(set) var outcome: GameOutcome = .ongoing

    // Tunables (difficulty / sandbox knobs)
    var growthRate: Double = 1.0
    var disastersEnabled: Bool = true
    var preventiveMaintenance: Bool = true
    static let crewActionsPerTick: Int = 3

    // Cached per-tick readouts for the HUD
    private(set) var citySatisfaction: Double = 70
    private(set) var serviceCoverage: Double = 0
    private(set) var servedPopulation: Int = 0
    private(set) var totalPopulation: Int = 0
    private(set) var lastReportCard: ReportCard?

    /// Overflow points generated during the most recent tick, so the renderer
    /// can pop geysers / river discoloration where they happened.
    struct OverflowEvent {
        let coord: GridCoord
        let isCSO: Bool
        let amount: Int
    }
    private(set) var overflowEventsThisTick: [OverflowEvent] = []

    private var rng: SplitMix64

    init(world: World, seed: UInt64 = 0xBEEF_F00D) {
        self.world = world
        self.weather = Weather(seed: seed)
        self.rng = SplitMix64(seed: seed &* 0x100000001B3)
    }

    // MARK: - Main tick

    func step() {
        guard isPlayable else { return }
        tick += 1

        weather.advance(season: quarter)
        resetPerTickState()

        let storm = computeStormwater()
        routeFlow(storm: storm)
        treatAndDischarge()

        ageInfrastructure()
        runMaintenanceCrews()
        if disastersEnabled { rollRandomEvents() }

        settleBudget()
        updateSatisfaction()

        growCity()

        score.decayPollution()

        if tick % Simulation.ticksPerQuarter == 0 {
            issueReportCard()
        }
        evaluateOutcome()
    }

    var isPlayable: Bool {
        if case .ongoing = outcome { return true }
        return mode == .sandbox
    }

    // MARK: - Reset

    private func resetPerTickState() {
        overflowEventsThisTick.removeAll(keepingCapacity: true)
        for coord in world.pipes.keys {
            world.pipes[coord]?.flowThisTick = 0
        }
        for id in world.plants.keys {
            world.plants[id]?.receivedThisTick = 0
            world.plants[id]?.overflowedThisTick = 0
        }
        for id in world.pumps.keys {
            world.pumps[id]?.throughThisTick = 0
        }
        for id in world.houses.keys {
            world.houses[id]?.isBackedUp = false
            world.houses[id]?.isConnected = false
        }
    }

    // MARK: - Stormwater

    /// Per-parcel stormwater that ends up entering the *sanitary* network
    /// (only happens through combined sewers; storm drains and basins divert
    /// the rest). Returns extra load keyed by house id.
    private func computeStormwater() -> [Int: Int] {
        let intensity = weather.current.rainIntensity
        guard intensity > 0 else {
            // Dry: let basins slowly release what they buffered.
            for id in world.basins.keys {
                let release = min(RetentionBasin.releasePerTick, world.basins[id]?.stored ?? 0)
                world.basins[id]?.stored -= release
            }
            return [:]
        }

        var drainRoom: [Int: Int] = world.drains.mapValues { _ in StormDrain.intakePerTick }
        var basinRoom: [Int: Int] = world.basins.mapValues {
            RetentionBasin.capacity - $0.stored
        }

        var stormToNetwork: [Int: Int] = [:]
        for hid in world.houses.keys.sorted() {
            guard let house = world.houses[hid] else { continue }
            var runoff = Int((intensity
                              * house.zone.runoffFactor
                              * Double(house.level)).rounded())
            guard runoff > 0 else { continue }

            // Divert to nearby storm drains first.
            for did in world.drains.keys.sorted() where runoff > 0 {
                guard let drain = world.drains[did],
                      drain.coord.manhattanDistance(to: house.coord) <= 2,
                      let room = drainRoom[did], room > 0 else { continue }
                let take = min(room, runoff)
                drainRoom[did] = room - take
                runoff -= take
            }
            // Then buffer in nearby retention basins.
            for bid in world.basins.keys.sorted() where runoff > 0 {
                guard let basin = world.basins[bid],
                      basin.coord.manhattanDistance(to: house.coord) <= 3,
                      let room = basinRoom[bid], room > 0 else { continue }
                let take = min(room, runoff)
                basinRoom[bid] = room - take
                world.basins[bid]?.stored += take
                runoff -= take
            }
            guard runoff > 0 else { continue }

            // Whatever's left: combined sewers push it into the sanitary network
            // (CSO risk); separate systems discharge it straight to the river.
            if isCombinedServed(house.coord) {
                stormToNetwork[hid] = runoff
            } else {
                // Legal-ish separate storm outfall: small direct river load.
                score.addPollution(Double(runoff) * 0.05)
            }
        }
        return stormToNetwork
    }

    private func isCombinedServed(_ coord: GridCoord) -> Bool {
        for n in coord.orthogonalNeighbors {
            if case .pipe = world.tile(at: n), world.pipes[n]?.combined == true {
                return true
            }
        }
        return false
    }

    // MARK: - Flow routing

    private func routeFlow(storm: [Int: Int]) {
        var served = 0

        for hid in world.houses.keys.sorted() {
            guard let house = world.houses[hid] else { continue }
            let sanitary = house.load
            let stormLoad = storm[hid] ?? 0
            let demand = sanitary + stormLoad
            guard demand > 0 else {
                world.houses[hid]?.isConnected = true
                continue
            }

            guard let route = findRoute(from: house.coord) else {
                world.houses[hid]?.isBackedUp = true
                // No outlet at all: sanitary backs up, storm overflows.
                handleOverflow(sanitary: sanitary, storm: stormLoad, at: house.coord)
                continue
            }

            world.houses[hid]?.isConnected = true

            let routeRoom = route.path.map { conduitRoom(at: $0) }.min() ?? 0
            let plantRoom = max(0, (world.plants[route.plantId]?.capacity ?? 0)
                                - (world.plants[route.plantId]?.receivedThisTick ?? 0))
            let delivered = max(0, min(demand, routeRoom, plantRoom))

            if delivered > 0 {
                for coord in route.path { addFlow(at: coord, amount: delivered) }
                world.plants[route.plantId]?.receivedThisTick += delivered
            }

            if delivered < demand {
                world.houses[hid]?.isBackedUp = true
                // Split the shortfall proportionally between waste and storm.
                let shortfall = demand - delivered
                let stormShare = stormLoad > 0
                    ? Int((Double(shortfall) * Double(stormLoad) / Double(demand)).rounded())
                    : 0
                let sanitaryShare = shortfall - stormShare
                handleOverflow(sanitary: sanitaryShare, storm: stormShare, at: house.coord)
            } else if sanitary > 0 {
                served += house.population
            }
        }

        servedPopulation = served
        totalPopulation = world.houses.values.reduce(0) { $0 + $1.population }
        let parcels = world.houses.count
        let okParcels = world.houses.values.filter { $0.isConnected && !$0.isBackedUp }.count
        serviceCoverage = parcels == 0 ? 100 : Double(okParcels) / Double(parcels) * 100
    }

    /// Charge an overflow: sanitary backups and combined-sewer overflows both
    /// pollute and count as incidents; CSOs are nastier and draw regulators.
    private func handleOverflow(sanitary: Int, storm: Int, at coord: GridCoord) {
        if storm > 0 {
            score.addPollution(Double(storm) * 0.5)
            score.recordOverflow()
            overflowEventsThisTick.append(.init(coord: coord, isCSO: true, amount: storm))
            if rng.chance(0.30) {
                log.post(EventFlavor.pick(EventFlavor.cso, rng: &rng),
                         severity: .crisis, tick: tick)
            }
            applyOverflowFine(units: storm)
        }
        if sanitary > 0 {
            score.addPollution(Double(sanitary) * 0.8)
            score.recordOverflow()
            overflowEventsThisTick.append(.init(coord: coord, isCSO: false, amount: sanitary))
            if rng.chance(0.18) {
                log.post(EventFlavor.pick(EventFlavor.backup, rng: &rng),
                         severity: .warning, tick: tick)
            }
        }
    }

    /// Regulations tighten over time: overflow fines kick in and grow.
    private func applyOverflowFine(units: Int) {
        guard quarter >= 2 else { return }
        let perUnit = 8 + quarter * 2
        let fine = units * perUnit
        world.finance.spend(fine, reason: .fine)
    }

    private func conduitRoom(at c: GridCoord) -> Int {
        switch world.tile(at: c) {
        case .pipe:
            let p = world.pipes[c]
            return max(0, (p?.capacity ?? 0) - (p?.flowThisTick ?? 0))
        case .pump(let id):
            let pump = world.pumps[id]
            return max(0, (pump?.capacity ?? 0) - (pump?.throughThisTick ?? 0))
        default:
            return 0
        }
    }

    private func addFlow(at c: GridCoord, amount: Int) {
        switch world.tile(at: c) {
        case .pipe:
            world.pipes[c]?.flowThisTick += amount
        case .pump(let id):
            world.pumps[id]?.throughThisTick += amount
        default:
            break
        }
    }

    private struct Route { let path: [GridCoord]; let plantId: Int }

    /// BFS over conduit tiles (pipe + pump). Gravity rule: you may step to a
    /// neighbor of equal-or-lower elevation freely; stepping uphill is only
    /// allowed when leaving a pump (lift) station.
    private func findRoute(from houseCoord: GridCoord) -> Route? {
        var visited: Set<GridCoord> = []
        var parents: [GridCoord: GridCoord] = [:]
        var queue: [GridCoord] = []

        for n in houseCoord.orthogonalNeighbors {
            guard world.tile(at: n)?.isConduit == true else { continue }
            guard conduitFlowable(at: n) else { continue }
            if visited.insert(n).inserted { queue.append(n) }
        }

        var head = 0
        while head < queue.count {
            let current = queue[head]; head += 1

            for n in current.orthogonalNeighbors {
                if case .plant(let plantId) = world.tile(at: n) {
                    return Route(path: reconstructPath(to: current, parents: parents),
                                 plantId: plantId)
                }
            }

            let currentIsPump: Bool = {
                if case .pump = world.tile(at: current) { return true }
                return false
            }()

            for n in current.orthogonalNeighbors {
                guard world.tile(at: n)?.isConduit == true else { continue }
                guard conduitFlowable(at: n) else { continue }
                let canStep = currentIsPump
                    || world.groundLevel(at: n) <= world.groundLevel(at: current)
                guard canStep else { continue }
                if visited.insert(n).inserted {
                    parents[n] = current
                    queue.append(n)
                }
            }
        }
        return nil
    }

    /// A conduit can carry flow unless it's a blocked pipe or an offline pump.
    private func conduitFlowable(at c: GridCoord) -> Bool {
        switch world.tile(at: c) {
        case .pipe:        return world.pipes[c]?.blocked == false
        case .pump(let id):return world.pumps[id]?.online == true
        default:           return false
        }
    }

    private func reconstructPath(to end: GridCoord,
                                 parents: [GridCoord: GridCoord]) -> [GridCoord] {
        var path = [end]
        var current = end
        while let parent = parents[current] {
            path.append(parent)
            current = parent
        }
        return path.reversed()
    }

    // MARK: - Treatment / discharge

    private func treatAndDischarge() {
        for id in world.plants.keys {
            guard let plant = world.plants[id] else { continue }
            world.plants[id]?.lifetimeTreated += plant.receivedThisTick
            // Even treated effluent has residual pollution by tier.
            let residual = Double(plant.receivedThisTick)
                * (1.0 - plant.tier.effluentQuality) * 0.05
            score.addPollution(residual)
        }
    }

    // MARK: - Ageing

    private func ageInfrastructure() {
        for c in world.pipes.keys {
            guard var pipe = world.pipes[c] else { continue }
            pipe.condition = max(0, pipe.condition - pipe.material.decayPerTick)
            world.pipes[c] = pipe
        }
        for id in world.pumps.keys {
            world.pumps[id]?.condition = max(0, (world.pumps[id]?.condition ?? 0) - 0.10)
        }
        for id in world.plants.keys {
            world.plants[id]?.condition = max(0, (world.plants[id]?.condition ?? 0) - 0.05)
        }
    }

    // MARK: - Workforce / maintenance crews

    /// Preventive maintenance: crews top up the worst-condition assets and clear
    /// blockages each tick, for a modest fee — the "fix it before it breaks"
    /// side of the inspection minigame.
    private func runMaintenanceCrews() {
        guard preventiveMaintenance else { return }
        var actions = Simulation.crewActionsPerTick

        // Priority 1: clear blockages.
        for c in world.pipes.keys.sorted() where actions > 0 {
            if world.pipes[c]?.blocked == true {
                guard world.finance.canAfford(20) else { break }
                world.pipes[c]?.blocked = false
                world.pipes[c]?.condition = max(world.pipes[c]?.condition ?? 0, 40)
                world.finance.spend(20, reason: .maintenance)
                actions -= 1
            }
        }
        // Priority 2: shore up the most worn conduits.
        let worn = world.pipes
            .filter { ($0.value.condition) < 50 }
            .sorted { $0.value.condition < $1.value.condition }
            .prefix(actions)
        for (c, _) in worn where actions > 0 {
            guard world.finance.canAfford(12) else { break }
            world.pipes[c]?.condition = min(100, (world.pipes[c]?.condition ?? 0) + 8)
            world.finance.spend(12, reason: .maintenance)
            actions -= 1
        }
    }

    // MARK: - Random events

    private func rollRandomEvents() {
        let weatherBlock = weather.current.blockageFactor

        for c in world.pipes.keys.sorted() {
            guard let pipe = world.pipes[c] else { continue }

            // Blockages: more likely when worn and during drought.
            if !pipe.blocked {
                let wear = 1.0 + (100 - pipe.condition) / 50.0
                let p = 0.0006 * wear * weatherBlock
                if rng.chance(p) {
                    world.pipes[c]?.blocked = true
                    log.post(EventFlavor.pick(EventFlavor.blockage, rng: &rng),
                             severity: .warning, tick: tick)
                }
            }

            // Bursts: only very worn pipes, and they need a crew to fix.
            if pipe.condition < 25 && rng.chance(0.004) {
                world.pipes[c]?.condition = 8
                world.pipes[c]?.blocked = true
                log.post(EventFlavor.pick(EventFlavor.burst, rng: &rng),
                         severity: .crisis, tick: tick)
            }
        }

        // Pump failures: worn pumps without a backup can trip offline.
        for id in world.pumps.keys.sorted() {
            guard let pump = world.pumps[id], pump.online else { continue }
            if pump.condition < 45 && !pump.hasBackupPump && rng.chance(0.01) {
                world.pumps[id]?.online = false
                log.post(EventFlavor.pick(EventFlavor.pumpFailure, rng: &rng),
                         severity: .crisis, tick: tick)
            }
        }

        // Odd grumpy-citizen complaint when satisfaction is low.
        if citySatisfaction < 50 && rng.chance(0.05) {
            log.post(EventFlavor.pick(EventFlavor.complaint, rng: &rng),
                     severity: .info, tick: tick)
        }
    }

    // MARK: - City growth

    private func growCity() {
        // The city grows faster when residents are happy; sandbox can dial it.
        let happiness = max(0.2, citySatisfaction / 100.0)
        let interval = max(2, Int(8.0 / (growthRate * happiness)))
        guard tick % interval == 0 else { return }

        // Densify an existing parcel (you find out the load went up afterward).
        if world.houses.count > 2, rng.chance(0.5),
           let hid = world.houses.keys.sorted().randomElement(using: &rng) {
            if (world.houses[hid]?.level ?? 3) < 3 {
                world.houses[hid]?.level += 1
                if rng.chance(0.4) {
                    log.post("Developers densify a block — your network finds out the hard way.",
                             severity: .info, tick: tick)
                }
                return
            }
        }

        // Otherwise spawn a brand-new parcel next to existing development.
        guard let spot = newDevelopmentSite() else { return }
        let zone = zoneForCurrentPhase()
        guard world.developParcel(zone, at: spot) != nil else { return }
        log.post("New \(zone.displayName.lowercased()) parcel opens on the edge of town — connect it!",
                 severity: .info, tick: tick)
    }

    private func zoneForCurrentPhase() -> ZoneType {
        if quarter >= 4 && rng.chance(0.3) { return .industrial }
        if quarter >= 2 && rng.chance(0.4) { return .commercial }
        return .residential
    }

    /// An empty tile adjacent to an existing parcel or pipe, biased to appear
    /// "next to the city." Falls back to any empty tile.
    private func newDevelopmentSite() -> GridCoord? {
        var candidates: [GridCoord] = []
        for (_, house) in world.houses {
            for n in house.coord.orthogonalNeighbors where world.tile(at: n) == .empty {
                candidates.append(n)
            }
        }
        if let pick = candidates.randomElement(using: &rng) { return pick }
        var anyEmpty: [GridCoord] = []
        for x in 0..<world.width {
            for y in 0..<world.height where world.tiles[x][y] == .empty {
                anyEmpty.append(GridCoord(x: x, y: y))
            }
        }
        return anyEmpty.randomElement(using: &rng)
    }

    // MARK: - Budget

    private func settleBudget() {
        // Revenue: a per-tick slice of the monthly sewer fee from served pop.
        let revenue = Int((Double(servedPopulation) * world.finance.sewerRate * 0.25).rounded())
        world.finance.earn(revenue)

        // Maintenance: pipes, pumps, and plants all cost money to keep running.
        var expenses = 0
        expenses += world.pipes.count // $1/pipe/tick baseline upkeep
        for pump in world.pumps.values { _ = pump; expenses += PumpStation.maintenancePerTick }
        for plant in world.plants.values { expenses += plant.tier.maintenancePerTick }
        world.finance.spend(expenses, reason: .maintenance)

        let interest = world.finance.accrueInterest()

        world.finance.lastRevenue = revenue
        world.finance.lastExpenses = expenses + interest
    }

    // MARK: - Satisfaction

    private func updateSatisfaction() {
        guard !world.houses.isEmpty else { citySatisfaction = 70; return }

        var weightedSum = 0.0
        var popSum = 0
        let rate = world.finance.sewerRate

        for hid in world.houses.keys {
            guard let house = world.houses[hid] else { continue }
            var target = 85.0

            // Smell from plants and pump stations within their stink radius.
            for plant in world.plants.values {
                let d = plant.coord.manhattanDistance(to: house.coord)
                if d <= plant.tier.smellRadius {
                    let prox = Double(plant.tier.smellRadius - d + 1)
                    target -= prox * 6.0 * house.zone.smellSensitivity
                }
            }
            for pump in world.pumps.values {
                let d = pump.coord.manhattanDistance(to: house.coord)
                if d <= 2 {
                    target -= Double(3 - d) * 4.0 * house.zone.smellSensitivity
                }
            }

            if !house.isConnected { target -= 40 }
            if house.isBackedUp { target -= 25 }

            // Rate above ~2.0 starts to bite; very high rates are hated.
            if rate > 2.0 { target -= (rate - 2.0) * 15.0 }

            target = max(0, min(100, target))
            let smoothed = (house.satisfaction * 0.85) + (target * 0.15)
            world.houses[hid]?.satisfaction = smoothed

            weightedSum += smoothed * Double(house.population)
            popSum += house.population
        }
        citySatisfaction = popSum == 0 ? 70 : weightedSum / Double(popSum)
    }

    // MARK: - Scoring / outcome

    private func issueReportCard() {
        let card = score.issueCard(
            quarter: quarter,
            population: totalPopulation,
            serviceCoverage: serviceCoverage,
            satisfaction: citySatisfaction,
            finance: world.finance
        )
        lastReportCard = card
        log.post("\(card.headline) — Grade: \(card.grade)",
                 severity: card.grade == "F" ? .crisis : .info, tick: tick)
    }

    /// Reset win/loss tracking (e.g. when switching to sandbox).
    func resetOutcome() { outcome = .ongoing }

    /// Start (or restart) a scenario from the current world state.
    func beginScenario(_ s: Scenario) {
        scenario = s
        outcome = .ongoing
    }

    private func evaluateOutcome() {
        guard mode == .scenario || mode == .career else { outcome = .ongoing; return }
        let result = scenario.evaluate(
            population: totalPopulation,
            quarter: quarter,
            lastCard: lastReportCard,
            finance: world.finance,
            environmentScore: score.environmentScore
        )
        if case .ongoing = result {
            outcome = .ongoing
        } else {
            if case .ongoing = outcome { // first transition only
                switch result {
                case .won(let m):  log.post("YOU WIN: \(m)", severity: .info, tick: tick)
                case .lost(let m): log.post("GAME OVER: \(m)", severity: .crisis, tick: tick)
                case .ongoing:     break
                }
            }
            outcome = result
        }
    }
}

// MARK: - RNG helpers

extension SplitMix64 {
    /// True with probability `p` (0...1).
    nonisolated mutating func chance(_ p: Double) -> Bool {
        guard p > 0 else { return false }
        guard p < 1 else { return true }
        return Double(next() % 1_000_000) / 1_000_000.0 < p
    }
}
