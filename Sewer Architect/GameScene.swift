//
//  GameScene.swift
//  Sewer Architect
//
//  Renders terrain, the pipe network, buildings, a control panel, a live HUD,
//  a news ticker, and the quarterly report-card overlay. Routes mouse + keyboard
//  input to building actions and game controls.
//

import SpriteKit
import Foundation

final class GameScene: SKScene {

    // MARK: Layout

    static let tileSize: CGFloat = 30
    static let gridWidth: Int = 24
    static let gridHeight: Int = 16
    static let panelHeight: CGFloat = 168

    static var boardHeight: CGFloat { CGFloat(gridHeight) * tileSize }
    static var sceneSize: CGSize {
        CGSize(width: CGFloat(gridWidth) * tileSize,
               height: boardHeight + panelHeight)
    }

    // MARK: Model

    private var world: World!
    private var simulation: Simulation!
    private var maxElevation: Int = 1

    // MARK: Render nodes

    private let boardNode = SKNode()
    private let uiNode = SKNode()
    private var tileNodes: [[SKSpriteNode]] = []
    private var dynamicNodes: [SKNode] = []   // pipes + buildings, rebuilt per refresh

    // A click-to-dismiss modal (report card, win/loss, career transitions).
    private var modalOverlay: SKNode?
    private var modalAction: (() -> Void)?

    // MARK: Career

    private var careerIndex = 0
    private var outcomeShown = false

    // MARK: UI

    private var toolButtons: [(tool: BuildTool, node: SKShapeNode)] = []
    private var controlButtons: [(name: String, node: SKShapeNode, label: SKLabelNode)] = []
    private let statusLine1 = SKLabelNode()
    private let statusLine2 = SKLabelNode()
    private let statusLine3 = SKLabelNode()
    private let tickerLabel = SKLabelNode()

    // MARK: State

    private var currentTool: BuildTool = .pipe
    private var isRunning = false
    private let speeds: [TimeInterval] = [0.5, 0.25, 0.12]
    private var speedIndex = 0
    private var tickInterval: TimeInterval { speeds[speedIndex] }
    private var timeAccumulator: TimeInterval = 0
    private var lastUpdateTime: TimeInterval = 0
    private var lastPaintedCoord: GridCoord?

    // MARK: Lifecycle

    override func didMove(to view: SKView) {
        size = GameScene.sceneSize
        anchorPoint = .zero
        backgroundColor = SKColor(white: 0.10, alpha: 1)

        removeAllChildren()
        addChild(boardNode)
        addChild(uiNode)
        uiNode.position = CGPoint(x: 0, y: GameScene.boardHeight)

        buildPanel()
        loadGame(mode: .sandbox, level: nil)
    }

    // MARK: Game setup / level loading

    /// (Re)build the world + simulation for a sandbox game or a career level,
    /// then rebuild the board and HUD around it.
    private func loadGame(mode: GameMode, level: CareerLevel?) {
        isRunning = false
        controlLabel("ctl:play")?.text = "Play"
        outcomeShown = false
        dismissModal()

        let seed = level?.seed ?? 0xC0FFEE
        let w = World(width: GameScene.gridWidth, height: GameScene.gridHeight, seed: seed)
        w.finance = Finance(cash: level?.startingCash ?? 5_000)
        w.availableMaterials = level?.availableMaterials ?? PipeMaterial.allCases
        w.availablePlantTiers = level?.availablePlantTiers ?? PlantTier.allCases
        w.selectedMaterial = w.availableMaterials.first ?? .clay
        w.selectedPlantTier = w.availablePlantTiers.first ?? .primary
        if level?.legacy == true { w.seedLegacyCity() } else { w.seedStartingCity() }
        world = w

        let sim = Simulation(world: w, seed: seed)
        sim.mode = mode
        if let level { sim.scenario = level.scenario }
        sim.weather.stormFrequency = level?.stormFrequency ?? 1.0
        sim.growthRate = level?.growthRate ?? 1.0
        simulation = sim

        maxElevation = max(1, w.elevation.flatMap { $0 }.max() ?? 1)
        currentTool = .pipe
        rebuildBoard()
        syncControlLabels()
        refreshRender()

        if let level {
            sim.log.post("Career — \(level.name): \(level.blurb)", severity: .info, tick: 0)
        }
    }

    private func rebuildBoard() {
        boardNode.removeAllChildren()
        dynamicNodes.removeAll(keepingCapacity: true)
        tileNodes.removeAll(keepingCapacity: true)
        buildTerrainTiles()
    }

    /// Push current model state back onto the control button labels.
    private func syncControlLabels() {
        controlLabel("ctl:material")?.text = "Pipe:" + String(world.selectedMaterial.displayName.prefix(4))
        controlLabel("ctl:tier")?.text = "Plant:" + String(world.selectedPlantTier.displayName.prefix(3))
        controlLabel("ctl:combined")?.text = world.buildCombinedSewers ? "Combined" : "Separate"
        controlLabel("ctl:prev")?.text = "Maint:" + (simulation.preventiveMaintenance ? "On" : "Off")
        controlLabel("ctl:mode")?.text = modeLabel()
        controlLabel("ctl:speed")?.text = ["1x", "2x", "4x"][speedIndex]
        refreshToolHighlight()
    }

    private func modeLabel() -> String {
        simulation.mode == .career ? "Lv\(careerIndex + 1)" : simulation.mode.displayName
    }

    // MARK: Terrain

    private func buildTerrainTiles() {
        var rows: [[SKSpriteNode]] = []
        for x in 0..<GameScene.gridWidth {
            var column: [SKSpriteNode] = []
            for y in 0..<GameScene.gridHeight {
                let coord = GridCoord(x: x, y: y)
                let node = SKSpriteNode(color: terrainColor(at: coord),
                                        size: CGSize(width: GameScene.tileSize - 1,
                                                     height: GameScene.tileSize - 1))
                node.position = pointForCoord(coord)
                boardNode.addChild(node)
                column.append(node)
            }
            rows.append(column)
        }
        tileNodes = rows
    }

    /// Low ground (toward the outfall) reads blue-green; high ground reads
    /// brown. Helps the player see where gravity wants the flow to go.
    private func terrainColor(at c: GridCoord) -> SKColor {
        if c == world.outfall {
            return SKColor(red: 0.10, green: 0.25, blue: 0.45, alpha: 1) // river
        }
        let f = CGFloat(world.groundLevel(at: c)) / CGFloat(maxElevation)
        let low = (r: CGFloat(0.12), g: CGFloat(0.26), b: CGFloat(0.30))
        let high = (r: CGFloat(0.34), g: CGFloat(0.30), b: CGFloat(0.18))
        return SKColor(red: low.r + (high.r - low.r) * f,
                       green: low.g + (high.g - low.g) * f,
                       blue: low.b + (high.b - low.b) * f,
                       alpha: 1)
    }

    // MARK: Panel / controls

    private func buildPanel() {
        let bg = SKSpriteNode(color: SKColor(white: 0.07, alpha: 1),
                              size: CGSize(width: size.width, height: GameScene.panelHeight))
        bg.anchorPoint = .zero
        bg.position = .zero
        uiNode.addChild(bg)

        // Row 1: build tools.
        let tools: [(BuildTool, SKColor)] = [
            (.residential, .systemBlue), (.commercial, .systemYellow),
            (.industrial, .systemPurple), (.pipe, .systemGray),
            (.pump, .systemOrange), (.plant, .systemGreen),
            (.drain, .systemTeal), (.basin, .systemIndigo),
            (.upgrade, .brown), (.repair, .systemMint), (.erase, .systemRed)
        ]
        layoutButtonRow(y: 22, items: tools.map { ($0.0.displayName, "tool:\($0.0.rawValue)", $0.1) })
        for (tool, _) in tools {
            if let node = controlButtons.first(where: { $0.name == "tool:\(tool.rawValue)" })?.node {
                toolButtons.append((tool, node))
            }
        }

        // Row 2: game controls.
        let controls: [(String, String, SKColor)] = [
            ("Play", "ctl:play", .systemGreen),
            ("1x", "ctl:speed", .systemGray),
            ("Rate-", "ctl:rateDown", .systemTeal),
            ("Rate+", "ctl:rateUp", .systemTeal),
            ("Loan", "ctl:loan", .systemBrown),
            ("Pipe:Clay", "ctl:material", .systemGray),
            ("Plant:Pri", "ctl:tier", .systemGreen),
            ("Combined", "ctl:combined", .systemIndigo),
            ("Maint:On", "ctl:prev", .systemMint),
            ("Sandbox", "ctl:mode", .systemPurple),
            ("Report", "ctl:report", .systemOrange)
        ]
        layoutButtonRow(y: 58, items: controls)

        // Status lines.
        for (i, label) in [statusLine1, statusLine2, statusLine3].enumerated() {
            label.fontName = "Menlo"
            label.fontSize = 11
            label.fontColor = .white
            label.horizontalAlignmentMode = .left
            label.verticalAlignmentMode = .center
            label.position = CGPoint(x: 8, y: 92 + CGFloat(i) * 18)
            uiNode.addChild(label)
        }

        tickerLabel.fontName = "Menlo-Bold"
        tickerLabel.fontSize = 11
        tickerLabel.fontColor = .systemYellow
        tickerLabel.horizontalAlignmentMode = .left
        tickerLabel.verticalAlignmentMode = .center
        tickerLabel.position = CGPoint(x: 8, y: 150)
        uiNode.addChild(tickerLabel)

        refreshToolHighlight()
    }

    private func layoutButtonRow(y: CGFloat, items: [(String, String, SKColor)]) {
        let count = items.count
        let gap: CGFloat = 4
        let totalGap = gap * CGFloat(count + 1)
        let buttonWidth = (size.width - totalGap) / CGFloat(count)
        let buttonSize = CGSize(width: buttonWidth, height: 28)
        var cursorX = gap
        for (title, name, color) in items {
            let btn = SKShapeNode(rectOf: buttonSize, cornerRadius: 5)
            btn.position = CGPoint(x: cursorX + buttonWidth / 2, y: y)
            btn.fillColor = color
            btn.strokeColor = .white
            btn.lineWidth = 1
            btn.name = name
            uiNode.addChild(btn)

            let label = SKLabelNode(text: title)
            label.fontName = "Helvetica-Bold"
            label.fontSize = 10
            label.fontColor = .black
            label.verticalAlignmentMode = .center
            label.horizontalAlignmentMode = .center
            label.name = name
            btn.addChild(label)

            controlButtons.append((name, btn, label))
            cursorX += buttonWidth + gap
        }
    }

    private func refreshToolHighlight() {
        for (tool, node) in toolButtons {
            node.lineWidth = tool == currentTool ? 4 : 1
        }
    }

    private func controlLabel(_ name: String) -> SKLabelNode? {
        controlButtons.first(where: { $0.name == name })?.label
    }

    // MARK: Coordinates

    private func pointForCoord(_ c: GridCoord) -> CGPoint {
        CGPoint(x: (CGFloat(c.x) + 0.5) * GameScene.tileSize,
                y: (CGFloat(c.y) + 0.5) * GameScene.tileSize)
    }

    /// Isometric anchor for anything that rises off a tile.  Click handling keeps
    /// using the orthogonal grid above, but miniatures share this projection so
    /// they read as small city objects sitting on diamond tile centers.
    private func isometricTileCenter(for coord: GridCoord) -> CGPoint {
        let tile = GameScene.tileSize
        let halfWidth = tile * 0.5
        let halfHeight = tile * 0.25
        let originX = GameScene.sceneSize.width * 0.5
        let originY = tile * 2.4
        let x = originX + CGFloat(coord.x - coord.y) * halfWidth
        let y = originY + CGFloat(coord.x + coord.y) * halfHeight
            + CGFloat(world.groundLevel(at: coord)) * 2
        return CGPoint(x: x, y: y)
    }

    private func zPosition(for coord: GridCoord, verticalOffset: CGFloat = 0) -> CGFloat {
        CGFloat(coord.x + coord.y) * 10
            + CGFloat(world.groundLevel(at: coord)) * 2
            + verticalOffset
    }

    private func coordForBoardPoint(_ p: CGPoint) -> GridCoord? {
        guard p.x >= 0, p.y >= 0 else { return nil }
        let coord = GridCoord(x: Int(p.x / GameScene.tileSize),
                              y: Int(p.y / GameScene.tileSize))
        return world.inBounds(coord) ? coord : nil
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        let p = event.location(in: self)
        if modalOverlay != nil {
            let action = modalAction
            dismissModal()
            action?()
            return
        }
        if p.y >= GameScene.boardHeight {
            handlePanelClick(at: p)
        } else {
            lastPaintedCoord = nil
            handleBoardClick(at: p)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = event.location(in: self)
        guard p.y < GameScene.boardHeight else { return }
        // Click-drag to paint pipes / zones / erase quickly.
        guard currentTool == .pipe || currentTool == .erase
                || currentTool == .residential else { return }
        handleBoardClick(at: p)
    }

    private func handleBoardClick(at scenePoint: CGPoint) {
        let boardPoint = boardNode.convert(scenePoint, from: self)
        guard let coord = coordForBoardPoint(boardPoint) else { return }
        if coord == lastPaintedCoord { return }
        lastPaintedCoord = coord
        let result = world.place(currentTool, at: coord)
        if case .rejectedFunds(let needed) = result {
            simulation.log.post("Can't afford that — need $\(needed).",
                                severity: .warning, tick: simulation.tick)
        }
        refreshRender()
    }

    private func handlePanelClick(at scenePoint: CGPoint) {
        for node in nodes(at: scenePoint) {
            guard let name = node.name else { continue }
            if name.hasPrefix("tool:") {
                if let tool = BuildTool(rawValue: String(name.dropFirst(5))) {
                    currentTool = tool
                    refreshToolHighlight()
                    refreshRender()
                }
                return
            }
            if name.hasPrefix("ctl:") {
                handleControl(name)
                return
            }
        }
    }

    private func handleControl(_ name: String) {
        switch name {
        case "ctl:play":
            isRunning.toggle()
            controlLabel("ctl:play")?.text = isRunning ? "Pause" : "Play"
        case "ctl:speed":
            speedIndex = (speedIndex + 1) % speeds.count
            controlLabel("ctl:speed")?.text = ["1x", "2x", "4x"][speedIndex]
        case "ctl:rateUp":
            world.finance.sewerRate = min(Finance.maxRate, world.finance.sewerRate + 0.25)
        case "ctl:rateDown":
            world.finance.sewerRate = max(Finance.minRate, world.finance.sewerRate - 0.25)
        case "ctl:loan":
            world.finance.takeLoan(1_000)
            simulation.log.post("Took out a $1,000 bond. Interest is now your problem.",
                                severity: .info, tick: simulation.tick)
        case "ctl:material":
            cycleMaterial()
        case "ctl:tier":
            cyclePlantTier()
        case "ctl:combined":
            world.buildCombinedSewers.toggle()
            controlLabel("ctl:combined")?.text = world.buildCombinedSewers ? "Combined" : "Separate"
        case "ctl:prev":
            simulation.preventiveMaintenance.toggle()
            controlLabel("ctl:prev")?.text = "Maint:" + (simulation.preventiveMaintenance ? "On" : "Off")
        case "ctl:mode":
            cycleMode()
        case "ctl:report":
            toggleReport()
        default:
            break
        }
        refreshRender()
    }

    private func cycleMaterial() {
        let avail = world.availableMaterials
        guard !avail.isEmpty else { return }
        let i = avail.firstIndex(of: world.selectedMaterial) ?? -1
        world.selectedMaterial = avail[(i + 1) % avail.count]
        controlLabel("ctl:material")?.text = "Pipe:" + String(world.selectedMaterial.displayName.prefix(4))
    }

    private func cyclePlantTier() {
        let avail = world.availablePlantTiers
        guard !avail.isEmpty else { return }
        let i = avail.firstIndex(of: world.selectedPlantTier) ?? -1
        world.selectedPlantTier = avail[(i + 1) % avail.count]
        controlLabel("ctl:tier")?.text = "Plant:" + String(world.selectedPlantTier.displayName.prefix(3))
    }

    /// Cycle Sandbox → Scenario → Career. Career (re)starts from level 1 on a
    /// fresh map; the others keep the current map.
    private func cycleMode() {
        let order: [GameMode] = [.sandbox, .scenario, .career]
        let i = order.firstIndex(of: simulation.mode) ?? 0
        let next = order[(i + 1) % order.count]
        switch next {
        case .sandbox:
            simulation.mode = .sandbox
            simulation.resetOutcome()
            outcomeShown = false
            world.availableMaterials = PipeMaterial.allCases
            world.availablePlantTiers = PlantTier.allCases
            controlLabel("ctl:mode")?.text = modeLabel()
        case .scenario:
            simulation.mode = .scenario
            simulation.beginScenario(Scenario())
            outcomeShown = false
            controlLabel("ctl:mode")?.text = modeLabel()
        case .career:
            careerIndex = 0
            loadGame(mode: .career, level: Career.levels[0])
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers else { return }
        switch key {
        case " ":  handleControl("ctl:play")
        case "r":  toggleReport()
        case "]":  handleControl("ctl:speed")
        case "=", "+": handleControl("ctl:rateUp")
        case "-":  handleControl("ctl:rateDown")
        default:   break
        }
    }

    // MARK: Update loop

    override func update(_ currentTime: TimeInterval) {
        if lastUpdateTime == 0 { lastUpdateTime = currentTime; return }
        let dt = currentTime - lastUpdateTime
        lastUpdateTime = currentTime
        guard isRunning else { return }

        timeAccumulator += dt
        var ticked = false
        while timeAccumulator >= tickInterval {
            timeAccumulator -= tickInterval
            simulation.step()
            ticked = true
        }
        if ticked {
            refreshRender()
            spawnOverflowAnimations()
            handleOutcomeTransition()
        }
    }

    // MARK: Outcome / career transitions

    private func handleOutcomeTransition() {
        guard !outcomeShown else { return }
        switch simulation.outcome {
        case .ongoing:
            return
        case .won(let message):
            outcomeShown = true
            isRunning = false
            controlLabel("ctl:play")?.text = "Play"
            if simulation.mode == .career { presentCareerWin(message) }
            else { presentModal(["🎉  YOU WIN", "", message, "", "(click to close)"]) }
        case .lost(let message):
            outcomeShown = true
            isRunning = false
            controlLabel("ctl:play")?.text = "Play"
            if simulation.mode == .career { presentCareerLoss(message) }
            else { presentModal(["☠️  GAME OVER", "", message, "", "(click to close)"]) }
        }
    }

    private func presentCareerWin(_ message: String) {
        let isLast = careerIndex + 1 >= Career.levels.count
        if isLast {
            presentModal([
                "🏆  CAREER COMPLETE",
                "", message, "",
                "You've run sewers from Mudville to Old Town",
                "without (entirely) drowning the place. Legendary.",
                "", "(click to close)"
            ])
        } else {
            let next = Career.levels[careerIndex + 1]
            presentModal([
                "✅  LEVEL COMPLETE — \(Career.levels[careerIndex].name)",
                "", message, "",
                "Next posting: \(next.name)",
                next.blurb,
                "", "(click to begin the next city)"
            ], action: { [weak self] in
                guard let self else { return }
                self.careerIndex += 1
                self.loadGame(mode: .career, level: Career.levels[self.careerIndex])
            })
        }
    }

    private func presentCareerLoss(_ message: String) {
        presentModal([
            "☠️  LEVEL FAILED — \(Career.levels[careerIndex].name)",
            "", message, "",
            "(click to retry this city)"
        ], action: { [weak self] in
            guard let self else { return }
            self.loadGame(mode: .career, level: Career.levels[self.careerIndex])
        })
    }

    // MARK: Overflow animations

    private func spawnOverflowAnimations() {
        for ev in simulation.overflowEventsThisTick {
            spawnGeyser(at: ev.coord, isCSO: ev.isCSO, amount: ev.amount)
        }
    }

    /// A manhole geyser: a murky splash ring plus a spray of droplets that arc
    /// up and fall back down. CSOs spray sickly green; sewage backups spray brown.
    private func spawnGeyser(at coord: GridCoord, isCSO: Bool, amount: Int) {
        let color: SKColor = isCSO
            ? SKColor(red: 0.32, green: 0.5, blue: 0.18, alpha: 1)   // murky green
            : SKColor(red: 0.45, green: 0.30, blue: 0.14, alpha: 1)  // brown
        let container = SKNode()
        container.position = pointForCoord(coord)
        container.zPosition = 500
        boardNode.addChild(container)

        let ring = SKShapeNode(circleOfRadius: GameScene.tileSize * 0.22)
        ring.fillColor = color
        ring.strokeColor = .clear
        ring.alpha = 0.85
        container.addChild(ring)
        ring.run(.sequence([
            .group([.scale(to: 2.4, duration: 0.5), .fadeOut(withDuration: 0.5)]),
            .removeFromParent()
        ]))

        let count = min(7, 3 + amount / 3)
        for i in 0..<count {
            let drop = SKShapeNode(circleOfRadius: 2.5)
            drop.fillColor = color
            drop.strokeColor = .clear
            container.addChild(drop)

            let angle = Double(i) / Double(count) * 2 * Double.pi
            let dx = CGFloat(cos(angle)) * GameScene.tileSize * 0.6
            let up = GameScene.tileSize * (0.7 + 0.4 * CGFloat(i % 3))
            let rise = SKAction.moveBy(x: dx, y: up, duration: 0.32)
            rise.timingMode = .easeOut
            let fall = SKAction.moveBy(x: dx * 0.5, y: -up * 1.4, duration: 0.42)
            fall.timingMode = .easeIn
            drop.run(.sequence([
                rise,
                .group([fall, .fadeOut(withDuration: 0.42)]),
                .removeFromParent()
            ]))
        }
        container.run(.sequence([.wait(forDuration: 1.1), .removeFromParent()]))
    }

    /// Stain the river corner toward sickly green as pollution rises.
    private func updateRiver() {
        let frac = min(1.0, CGFloat(simulation.score.riverPollution) / 120.0)
        let clean = SKColor(red: 0.10, green: 0.25, blue: 0.45, alpha: 1)
        let sick = SKColor(red: 0.28, green: 0.5, blue: 0.16, alpha: 1)
        let stained = blend(clean, sick, t: frac)
        for x in 0..<min(tileNodes.count, GameScene.gridWidth) {
            for y in 0..<min(tileNodes[x].count, GameScene.gridHeight) {
                let c = GridCoord(x: x, y: y)
                if c == world.outfall || (c.x + c.y) <= 2 {
                    tileNodes[x][y].color = stained
                }
            }
        }
    }

    // MARK: Render

    private func refreshRender() {
        for node in dynamicNodes { node.removeFromParent() }
        dynamicNodes.removeAll(keepingCapacity: true)

        for x in 0..<GameScene.gridWidth {
            for y in 0..<GameScene.gridHeight {
                let coord = GridCoord(x: x, y: y)
                switch world.tiles[x][y] {
                case .empty:        break
                case .pipe:         addPipeNode(coord)
                case .house(let id):addHouseNode(coord, id: id)
                case .plant(let id):addPlantNode(coord, id: id)
                case .pump(let id): addPumpNode(coord, id: id)
                case .drain:        addDrainNode(coord)
                case .basin(let id):addBasinNode(coord, id: id)
                }
            }
        }
        updateRiver()
        updateStatus()
    }

    private func addPipeNode(_ coord: GridCoord) {
        let pipe = world.pipes[coord]
        let node = SKSpriteNode(color: pipeColor(pipe),
                                size: CGSize(width: GameScene.tileSize - 7,
                                             height: GameScene.tileSize - 7))
        node.position = pointForCoord(coord)
        boardNode.addChild(node)
        dynamicNodes.append(node)

        if pipe?.blocked == true {
            let x = SKLabelNode(text: "✕")
            x.fontName = "Helvetica-Bold"; x.fontSize = 14; x.fontColor = .red
            x.verticalAlignmentMode = .center; x.horizontalAlignmentMode = .center
            node.addChild(x)
        }
    }

    private func pipeColor(_ pipe: PipeState?) -> SKColor {
        guard let pipe = pipe else { return SKColor(white: 0.5, alpha: 1) }
        if pipe.blocked { return SKColor(white: 0.25, alpha: 1) }
        let base: SKColor
        switch pipe.fillFraction {
        case ..<0.01: base = SKColor(white: 0.55, alpha: 1)
        case ..<0.34: base = .systemTeal
        case ..<0.67: base = .systemYellow
        case ..<1.0:  base = .systemOrange
        default:      base = .systemRed
        }
        // Worn pipes get a brownish wash so degradation is visible.
        if pipe.condition < 40 {
            return blend(base, SKColor.brown, t: 0.45)
        }
        return base
    }

    private func addHouseNode(_ coord: GridCoord, id: Int) {
        guard let house = world.houses[id] else { return }
        let node = SKNode()
        let brightness = 0.55 + 0.15 * CGFloat(house.level)
        let wallColor = zoneColor(house.zone, brightness: brightness)
        let strokeColor: SKColor = house.isBackedUp ? .red : (house.isConnected ? .white : .systemYellow)

        switch house.zone {
        case .residential:
            addPolygon(to: node, points: [CGPoint(x: -10, y: -7), CGPoint(x: 10, y: -7),
                                          CGPoint(x: 10, y: 5), CGPoint(x: -10, y: 5)],
                       fill: blend(wallColor, .white, t: 0.12), stroke: strokeColor)
            addPolygon(to: node, points: [CGPoint(x: -12, y: 5), CGPoint(x: 0, y: 15),
                                          CGPoint(x: 12, y: 5)],
                       fill: blend(wallColor, .brown, t: 0.5), stroke: strokeColor)
            addPolygon(to: node, points: [CGPoint(x: 2, y: -7), CGPoint(x: 10, y: -7),
                                          CGPoint(x: 10, y: 5), CGPoint(x: 2, y: 5)],
                       fill: blend(wallColor, .black, t: 0.2), stroke: .clear)
        case .commercial:
            addPolygon(to: node, points: [CGPoint(x: -12, y: -8), CGPoint(x: 12, y: -8),
                                          CGPoint(x: 12, y: 10), CGPoint(x: -12, y: 10)],
                       fill: wallColor, stroke: strokeColor)
            addPolygon(to: node, points: [CGPoint(x: -13, y: 1), CGPoint(x: 13, y: 1),
                                          CGPoint(x: 10, y: 6), CGPoint(x: -10, y: 6)],
                       fill: .systemRed, stroke: .white)
            addPolygon(to: node, points: [CGPoint(x: -7, y: -8), CGPoint(x: 7, y: -8),
                                          CGPoint(x: 7, y: -1), CGPoint(x: -7, y: -1)],
                       fill: blend(.systemTeal, .white, t: 0.25), stroke: .clear)
        case .industrial:
            addPolygon(to: node, points: [CGPoint(x: -13, y: -8), CGPoint(x: 11, y: -8),
                                          CGPoint(x: 11, y: 6), CGPoint(x: -13, y: 6)],
                       fill: wallColor, stroke: strokeColor)
            addPolygon(to: node, points: [CGPoint(x: -14, y: 6), CGPoint(x: -5, y: 14),
                                          CGPoint(x: 4, y: 6), CGPoint(x: 12, y: 12),
                                          CGPoint(x: 13, y: 6)],
                       fill: blend(.darkGray, wallColor, t: 0.25), stroke: strokeColor)
            addPolygon(to: node, points: [CGPoint(x: 7, y: 6), CGPoint(x: 11, y: 6),
                                          CGPoint(x: 11, y: 17), CGPoint(x: 7, y: 17)],
                       fill: .darkGray, stroke: .black)
        }
        if house.isBackedUp {
            addStatusBadge("!", color: .red, to: node)
        }
        node.position = isometricTileCenter(for: coord)
        node.zPosition = zPosition(for: coord, verticalOffset: 4)
        boardNode.addChild(node)
        dynamicNodes.append(node)
    }

    private func zoneColor(_ zone: ZoneType, brightness: CGFloat) -> SKColor {
        let b = min(1, brightness)
        switch zone {
        case .residential: return SKColor(red: 0.25 * b, green: 0.5 * b, blue: 1.0 * b, alpha: 1)
        case .commercial:  return SKColor(red: 1.0 * b, green: 0.85 * b, blue: 0.2 * b, alpha: 1)
        case .industrial:  return SKColor(red: 0.7 * b, green: 0.35 * b, blue: 0.9 * b, alpha: 1)
        }
    }

    private func addPlantNode(_ coord: GridCoord, id: Int) {
        guard let plant = world.plants[id] else { return }
        let node = SKNode()
        let tierBrightness: CGFloat = plant.tier == .primary ? 0.5
            : (plant.tier == .secondary ? 0.75 : 1.0)
        let outline: SKColor = plant.condition < 30 ? .red : .white
        let water = SKColor(red: 0.18, green: 0.55 * tierBrightness, blue: 0.75, alpha: 1)
        addPolygon(to: node, points: [CGPoint(x: -13, y: -9), CGPoint(x: 1, y: -13),
                                      CGPoint(x: 14, y: -6), CGPoint(x: 0, y: -2)],
                   fill: blend(water, .black, t: 0.1), stroke: outline)
        addPolygon(to: node, points: [CGPoint(x: -12, y: -3), CGPoint(x: 2, y: -7),
                                      CGPoint(x: 13, y: -1), CGPoint(x: -1, y: 4)],
                   fill: water, stroke: outline)
        if plant.tier != .primary {
            addPolygon(to: node, points: [CGPoint(x: 2, y: 1), CGPoint(x: 13, y: 4),
                                          CGPoint(x: 8, y: 11), CGPoint(x: -4, y: 8)],
                       fill: blend(water, .white, t: 0.18), stroke: outline)
        }
        if plant.tier == .tertiary {
            addPolygon(to: node, points: [CGPoint(x: -14, y: 5), CGPoint(x: -8, y: 3),
                                          CGPoint(x: -3, y: 7), CGPoint(x: -10, y: 11)],
                       fill: .systemMint, stroke: outline)
        }
        addPolygon(to: node, points: [CGPoint(x: -11, y: 6), CGPoint(x: -1, y: 6),
                                      CGPoint(x: -1, y: 14), CGPoint(x: -11, y: 14)],
                   fill: SKColor(red: 0.15, green: 0.7 * tierBrightness, blue: 0.25, alpha: 1),
                   stroke: outline)
        node.position = isometricTileCenter(for: coord)
        node.zPosition = zPosition(for: coord, verticalOffset: 5)
        boardNode.addChild(node)
        dynamicNodes.append(node)
    }

    private func addPumpNode(_ coord: GridCoord, id: Int) {
        guard let pump = world.pumps[id] else { return }
        let node = SKNode()
        let fill = pump.online ? SKColor.systemOrange : SKColor(red: 0.4, green: 0.1, blue: 0.1, alpha: 1)
        addPolygon(to: node, points: [CGPoint(x: -10, y: -8), CGPoint(x: 8, y: -8),
                                      CGPoint(x: 10, y: 6), CGPoint(x: -8, y: 9)],
                   fill: fill, stroke: pump.hasBackupPump ? .systemGreen : .white)
        addPolygon(to: node, points: [CGPoint(x: -14, y: -2), CGPoint(x: -8, y: -4),
                                      CGPoint(x: 12, y: 4), CGPoint(x: 14, y: 8),
                                      CGPoint(x: 8, y: 9), CGPoint(x: -12, y: 1)],
                   fill: .darkGray, stroke: .white)
        addArrow(to: node, online: pump.online)
        node.position = isometricTileCenter(for: coord)
        node.zPosition = zPosition(for: coord, verticalOffset: 4)
        boardNode.addChild(node)
        dynamicNodes.append(node)
    }

    private func addDrainNode(_ coord: GridCoord) {
        let node = SKNode()
        addPolygon(to: node, points: [CGPoint(x: -12, y: -4), CGPoint(x: 0, y: -10),
                                      CGPoint(x: 12, y: -4), CGPoint(x: 0, y: 3)],
                   fill: .systemTeal, stroke: .white)
        for x in stride(from: -7, through: 7, by: 7) {
            addPolygon(to: node, points: [CGPoint(x: CGFloat(x) - 1, y: -6),
                                          CGPoint(x: CGFloat(x) + 1, y: -6),
                                          CGPoint(x: CGFloat(x) + 1, y: 0),
                                          CGPoint(x: CGFloat(x) - 1, y: 0)],
                       fill: .black, stroke: .clear)
        }
        node.position = isometricTileCenter(for: coord)
        node.zPosition = zPosition(for: coord, verticalOffset: 3)
        boardNode.addChild(node)
        dynamicNodes.append(node)
    }

    private func addBasinNode(_ coord: GridCoord, id: Int) {
        guard let basin = world.basins[id] else { return }
        let node = SKNode()
        let fill = CGFloat(basin.stored) / CGFloat(RetentionBasin.capacity)
        addPolygon(to: node, points: [CGPoint(x: -14, y: -4), CGPoint(x: 0, y: -12),
                                      CGPoint(x: 14, y: -4), CGPoint(x: 0, y: 6)],
                   fill: SKColor(red: 0.16, green: 0.18, blue: 0.22, alpha: 1), stroke: .white)
        addPolygon(to: node, points: [CGPoint(x: -10, y: -4), CGPoint(x: 0, y: -9),
                                      CGPoint(x: 10, y: -4), CGPoint(x: 0, y: 3)],
                   fill: SKColor(red: 0.2, green: 0.3 + 0.4 * fill, blue: 0.7, alpha: 1), stroke: .clear)
        addPolygon(to: node, points: [CGPoint(x: -8, y: 3), CGPoint(x: -2, y: 0),
                                      CGPoint(x: 8, y: 3), CGPoint(x: 2, y: 6)],
                   fill: SKColor(red: 0.25, green: 0.65, blue: 0.85, alpha: 0.8), stroke: .clear)
        node.position = isometricTileCenter(for: coord)
        node.zPosition = zPosition(for: coord, verticalOffset: 2)
        boardNode.addChild(node)
        dynamicNodes.append(node)
    }

    @discardableResult
    private func addPolygon(to parent: SKNode,
                            points: [CGPoint],
                            fill: SKColor,
                            stroke: SKColor,
                            lineWidth: CGFloat = 1) -> SKShapeNode {
        let path = CGMutablePath()
        if let first = points.first {
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            path.closeSubpath()
        }
        let shape = SKShapeNode(path: path)
        shape.fillColor = fill
        shape.strokeColor = stroke
        shape.lineWidth = lineWidth
        parent.addChild(shape)
        return shape
    }

    private func addStatusBadge(_ text: String, color: SKColor, to parent: SKNode) {
        let badge = SKShapeNode(circleOfRadius: 5)
        badge.fillColor = color
        badge.strokeColor = .white
        badge.position = CGPoint(x: 11, y: 12)
        parent.addChild(badge)

        let label = SKLabelNode(text: text)
        label.fontName = "Helvetica-Bold"
        label.fontSize = 8
        label.fontColor = .white
        label.verticalAlignmentMode = .center
        label.horizontalAlignmentMode = .center
        badge.addChild(label)
    }

    private func addArrow(to parent: SKNode, online: Bool) {
        let color: SKColor = online ? .white : .black
        addPolygon(to: parent,
                   points: [CGPoint(x: -5, y: -1), CGPoint(x: 4, y: -1),
                            CGPoint(x: 4, y: -4), CGPoint(x: 10, y: 2),
                            CGPoint(x: 4, y: 8), CGPoint(x: 4, y: 5),
                            CGPoint(x: -5, y: 5)],
                   fill: color,
                   stroke: .clear)
        if !online {
            let label = SKLabelNode(text: "×")
            label.fontName = "Helvetica-Bold"
            label.fontSize = 16
            label.fontColor = .white
            label.verticalAlignmentMode = .center
            label.horizontalAlignmentMode = .center
            parent.addChild(label)
        }
    }

    private func blend(_ a: SKColor, _ b: SKColor, t: CGFloat) -> SKColor {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.usingColorSpace(.deviceRGB)?.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.usingColorSpace(.deviceRGB)?.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return SKColor(red: ar + (br - ar) * t, green: ag + (bg - ag) * t,
                       blue: ab + (bb - ab) * t, alpha: 1)
    }

    // MARK: Status / ticker

    private func updateStatus() {
        let f = world.finance
        let qInYear = simulation.quarter % 4 + 1
        statusLine1.text = String(
            format: "Yr %d  Q%d  %@  $%d  Debt $%d  Rate $%.2f  Rev +%d/Exp -%d",
            simulation.year, qInYear, simulation.weather.current.displayName,
            f.cash, f.debt, f.sewerRate, f.lastRevenue, f.lastExpenses)

        statusLine2.text = String(
            format: "Pop %d/%d served  Coverage %.0f%%  Happy %.0f%%  Env %.0f%%  Overflows(Q) %d",
            simulation.servedPopulation, simulation.totalPopulation,
            simulation.serviceCoverage, simulation.citySatisfaction,
            simulation.score.environmentScore,
            simulation.score.overflowIncidentsThisQuarter)

        var outcomeStr = "Playing"
        switch simulation.outcome {
        case .ongoing:
            switch simulation.mode {
            case .sandbox:  outcomeStr = "Sandbox"
            case .scenario: outcomeStr = "Scenario: in progress"
            case .career:   outcomeStr = "Career: \(Career.levels[careerIndex].name)"
            }
        case .won(let m):  outcomeStr = "WON — \(m)"
        case .lost(let m): outcomeStr = "LOST — \(m)"
        }
        statusLine3.text = String(
            format: "Tool:%@  Pipe:%@  Plant:%@  %@  Maint:%@  %@",
            currentTool.displayName, world.selectedMaterial.displayName,
            world.selectedPlantTier.displayName,
            world.buildCombinedSewers ? "Combined" : "Separate",
            simulation.preventiveMaintenance ? "On" : "Off", outcomeStr)

        if let event = simulation.log.latest {
            tickerLabel.text = "📰 " + event.headline
            switch event.severity {
            case .info:    tickerLabel.fontColor = .systemGray
            case .warning: tickerLabel.fontColor = .systemYellow
            case .crisis:  tickerLabel.fontColor = .systemRed
            }
        } else {
            tickerLabel.text = "📰 Welcome to the Department of Sanitation. Try not to flood anything."
            tickerLabel.fontColor = .systemGray
        }
    }

    // MARK: Modal overlay (report card, win/loss, career transitions)

    private func toggleReport() {
        if modalOverlay != nil { dismissModal(); return }
        presentModal(reportCardLines())
    }

    private func reportCardLines() -> [String] {
        if let c = simulation.lastReportCard {
            return [
                "DEPARTMENT OF SANITATION — QUARTERLY REPORT",
                c.headline,
                "",
                "Grade:            \(c.grade)",
                "Quarter:          \(c.quarter)   Population: \(c.population)",
                String(format: "Service coverage: %.0f%%", c.serviceCoverage),
                "Overflow events:  \(c.overflowIncidents)",
                String(format: "Environment:      %.0f%%", c.environmentScore),
                String(format: "Financial health: %.0f%%", c.financialHealth),
                String(format: "Satisfaction:     %.0f%%", c.satisfaction),
                "Cash: $\(c.cash)   Debt: $\(c.debt)",
                "",
                "(click anywhere or press R to close)"
            ]
        }
        return [
            "DEPARTMENT OF SANITATION — QUARTERLY REPORT",
            "",
            "No report yet — press Play and run a full quarter",
            "(\(Simulation.ticksPerQuarter) ticks) to receive your first review.",
            "",
            "(click anywhere or press R to close)"
        ]
    }

    /// Show a centered modal panel of text. If `action` is non-nil it runs when
    /// the player clicks to dismiss (used to advance/retry career levels).
    private func presentModal(_ lines: [String], action: (() -> Void)? = nil) {
        dismissModal()
        let overlay = SKNode()
        overlay.zPosition = 1000
        addChild(overlay)

        let panel = SKSpriteNode(color: SKColor(white: 0.05, alpha: 0.95),
                                 size: CGSize(width: size.width * 0.84, height: size.height * 0.72))
        panel.position = CGPoint(x: size.width / 2, y: size.height / 2)
        overlay.addChild(panel)

        let startY = panel.position.y + panel.size.height / 2 - 34
        for (i, line) in lines.enumerated() {
            let label = SKLabelNode(text: line)
            label.fontName = i == 0 ? "Menlo-Bold" : "Menlo"
            label.fontSize = i == 0 ? 15 : 12
            label.fontColor = .white
            label.horizontalAlignmentMode = .center
            label.verticalAlignmentMode = .center
            label.position = CGPoint(x: panel.position.x, y: startY - CGFloat(i) * 22)
            overlay.addChild(label)
        }

        modalOverlay = overlay
        modalAction = action
    }

    private func dismissModal() {
        modalOverlay?.removeFromParent()
        modalOverlay = nil
        modalAction = nil
    }
}
