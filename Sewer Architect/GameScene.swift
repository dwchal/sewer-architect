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

    static let tileWidth: CGFloat = 34
    static let tileHeight: CGFloat = 20
    static let gridWidth: Int = 24
    static let gridHeight: Int = 16
    static let panelHeight: CGFloat = 168
    static let boardMargin: CGFloat = 20

    /// Screen pixels of vertical rise per elevation level — this is what turns
    /// the flat diamond grid into a chunky, RollerCoaster-Tycoon-style landscape.
    static let elevationUnit: CGFloat = 3
    /// How far the terrain "slab" extends below ground so the land reads as
    /// solid earth with thickness rather than a paper-thin sheet.
    static let baseThickness: CGFloat = 8
    /// Extra room above the flat plane so tall hills don't collide with the panel.
    static let elevationHeadroom: CGFloat = 120

    static var tileSize: CGFloat { tileWidth }
    static var boardWidth: CGFloat {
        (CGFloat(gridWidth) + CGFloat(gridHeight)) * tileWidth / 2 + boardMargin * 2
    }
    static var boardHeight: CGFloat {
        (CGFloat(gridWidth) + CGFloat(gridHeight)) * tileHeight / 2
            + boardMargin * 2 + elevationHeadroom
    }
    static var sceneSize: CGSize {
        CGSize(width: boardWidth,
               height: boardHeight + panelHeight)
    }

    // MARK: Model

    private var world: World!
    private var simulation: Simulation!
    private var maxElevation: Int = 1

    // MARK: Render nodes

    private let boardNode = SKNode()
    private let uiNode = SKNode()
    private var tileNodes: [[SKShapeNode]] = []
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
        boardNode.zPosition = LayerRange.board
        uiNode.zPosition = LayerRange.ui
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

    /// Each terrain tile is extruded into an isometric block: a lit top diamond
    /// raised by its elevation, plus two shaded side walls dropping down to a
    /// common base. Front tiles draw over back ones, so the whole grid reads as
    /// a single chunky landmass with visible hills and earthen cliffs.
    private func buildTerrainTiles() {
        var rows: [[SKShapeNode]] = []
        let tw = GameScene.tileWidth
        let th = GameScene.tileHeight
        let base = GameScene.baseThickness
        for x in 0..<GameScene.gridWidth {
            var column: [SKShapeNode] = []
            for y in 0..<GameScene.gridHeight {
                let coord = GridCoord(x: x, y: y)
                let h = CGFloat(world.groundLevel(at: coord)) * GameScene.elevationUnit
                let top = terrainColor(at: coord)

                let container = SKNode()
                container.position = pointForCoord(coord)
                container.zPosition = zPosition(for: coord, layerOffset: BoardLayer.terrainSide)
                boardNode.addChild(container)

                // Left (south-west) wall — shaded darkest.
                let leftPath = CGMutablePath()
                leftPath.move(to: CGPoint(x: -tw / 2, y: h))
                leftPath.addLine(to: CGPoint(x: 0, y: h - th / 2))
                leftPath.addLine(to: CGPoint(x: 0, y: -th / 2 - base))
                leftPath.addLine(to: CGPoint(x: -tw / 2, y: -base))
                leftPath.closeSubpath()
                let leftWall = SKShapeNode(path: leftPath)
                leftWall.fillColor = shade(top, 0.55)
                leftWall.strokeColor = shade(top, 0.45)
                leftWall.lineWidth = 0.5
                leftWall.zPosition = 0
                container.addChild(leftWall)

                // Right (south-east) wall — shaded medium.
                let rightPath = CGMutablePath()
                rightPath.move(to: CGPoint(x: tw / 2, y: h))
                rightPath.addLine(to: CGPoint(x: 0, y: h - th / 2))
                rightPath.addLine(to: CGPoint(x: 0, y: -th / 2 - base))
                rightPath.addLine(to: CGPoint(x: tw / 2, y: -base))
                rightPath.closeSubpath()
                let rightWall = SKShapeNode(path: rightPath)
                rightWall.fillColor = shade(top, 0.74)
                rightWall.strokeColor = shade(top, 0.6)
                rightWall.lineWidth = 0.5
                rightWall.zPosition = 0.1
                container.addChild(rightWall)

                // Lit top face.
                let topPath = CGMutablePath()
                topPath.move(to: CGPoint(x: 0, y: h + th / 2))
                topPath.addLine(to: CGPoint(x: tw / 2, y: h))
                topPath.addLine(to: CGPoint(x: 0, y: h - th / 2))
                topPath.addLine(to: CGPoint(x: -tw / 2, y: h))
                topPath.closeSubpath()
                let topNode = SKShapeNode(path: topPath)
                topNode.fillColor = top
                topNode.strokeColor = shade(top, 0.8)
                topNode.lineWidth = 0.5
                topNode.zPosition = 0.2
                container.addChild(topNode)

                column.append(topNode)
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

    // MARK: Coordinates / depth sorting

    private enum LayerRange {
        static let board: CGFloat = 0
        static let ui: CGFloat = 10_000
        static let modal: CGFloat = 20_000
    }

    private enum BoardLayer {
        static let terrainSide: CGFloat = 0
        static let terrainTop: CGFloat = 1
        static let pipe: CGFloat = 2
        static let building: CGFloat = 3
        static let utility: CGFloat = 4
        static let marker: CGFloat = 6
        static let label: CGFloat = 7
        static let animation: CGFloat = 8
    }

    /// Painter's-algorithm depth: tiles nearer the viewer (smaller x+y, toward
    /// the outfall corner at the bottom of the screen) get a *higher* zPosition
    /// so they draw on top of — and correctly occlude — the taller terrain and
    /// buildings behind them.
    private func zPosition(for coord: GridCoord, layerOffset: CGFloat = 0) -> CGFloat {
        let diagonal = CGFloat(coord.x + coord.y)
        let span = CGFloat(GameScene.gridWidth + GameScene.gridHeight)
        return (span - diagonal) * 100 + layerOffset
    }

    private var boardCenterOffset: CGFloat {
        CGFloat(GameScene.gridHeight) * GameScene.tileWidth / 2 + GameScene.boardMargin
    }

    private var elevationOffset: CGFloat { GameScene.boardMargin }

    private func pointForCoord(_ c: GridCoord) -> CGPoint {
        let x = CGFloat(c.x) + 0.5
        let y = CGFloat(c.y) + 0.5
        return CGPoint(
            x: (x - y) * GameScene.tileWidth / 2 + boardCenterOffset,
            y: (x + y) * GameScene.tileHeight / 2 + elevationOffset
        )
    }

    /// The top-center of a tile's terrain block — where buildings sit and
    /// geysers erupt. This is the flat plane point lifted by the tile elevation.
    private func surfacePoint(_ c: GridCoord) -> CGPoint {
        let p = pointForCoord(c)
        return CGPoint(x: p.x,
                       y: p.y + CGFloat(world.groundLevel(at: c)) * GameScene.elevationUnit)
    }

    private func coordForBoardPoint(_ p: CGPoint) -> GridCoord? {
        let xMinusY = (p.x - boardCenterOffset) / (GameScene.tileWidth / 2)
        let xPlusY = (p.y - elevationOffset) / (GameScene.tileHeight / 2)
        let gridX = (xPlusY + xMinusY) / 2
        let gridY = (xPlusY - xMinusY) / 2
        let coord = GridCoord(x: Int(floor(gridX)), y: Int(floor(gridY)))
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
        switch currentTool {
        case .pipe, .erase, .residential, .commercial, .industrial:
            handleBoardClick(at: p)
        default:
            return
        }
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
        container.position = surfacePoint(coord)
        container.zPosition = zPosition(for: coord, layerOffset: BoardLayer.animation)
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
                    tileNodes[x][y].fillColor = stained
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
        // Pipes sit in the street as a shallow, slightly recessed channel.
        let anchor = addIsoBox(at: coord, inset: 5, height: 2,
                               topColor: pipeColor(pipe),
                               strokeColor: SKColor(white: 0.1, alpha: 0.5),
                               lineWidth: 0.75,
                               layer: BoardLayer.pipe)

        if pipe?.blocked == true {
            let x = SKLabelNode(text: "✕")
            x.fontName = "Helvetica-Bold"; x.fontSize = 14; x.fontColor = .red
            x.verticalAlignmentMode = .center; x.horizontalAlignmentMode = .center
            x.zPosition = BoardLayer.marker
            anchor.addChild(x)
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
        let brightness = 0.55 + 0.15 * CGFloat(house.level)
        // Taller, denser parcels grow upward — a quick read on development level.
        let height = 9 + CGFloat(house.level) * 5
        let stroke: SKColor = house.isBackedUp ? .red
            : (house.isConnected ? .white : .systemYellow)
        let anchor = addIsoBox(at: coord, inset: 4, height: height,
                               topColor: zoneColor(house.zone, brightness: brightness),
                               strokeColor: stroke,
                               lineWidth: house.isBackedUp ? 3 : 1,
                               layer: BoardLayer.building)

        let letter = SKLabelNode(text: String(house.zone.shortName.prefix(1)))
        letter.fontName = "Helvetica-Bold"; letter.fontSize = 11; letter.fontColor = .black
        letter.verticalAlignmentMode = .center; letter.horizontalAlignmentMode = .center
        letter.zPosition = BoardLayer.label
        anchor.addChild(letter)
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
        let tierBrightness: CGFloat = plant.tier == .primary ? 0.5
            : (plant.tier == .secondary ? 0.75 : 1.0)
        // Higher tiers are taller, more substantial works.
        let height: CGFloat = plant.tier == .primary ? 12
            : (plant.tier == .secondary ? 16 : 20)
        let anchor = addIsoBox(at: coord, inset: 1, height: height,
                               topColor: SKColor(red: 0.15, green: 0.7 * tierBrightness,
                                                 blue: 0.25, alpha: 1),
                               strokeColor: plant.condition < 30 ? .red : .white,
                               lineWidth: 2,
                               layer: BoardLayer.utility)

        let label = SKLabelNode(text: "P\(plant.tier == .primary ? "1" : plant.tier == .secondary ? "2" : "3")")
        label.fontName = "Helvetica-Bold"; label.fontSize = 11; label.fontColor = .white
        label.verticalAlignmentMode = .center; label.horizontalAlignmentMode = .center
        label.zPosition = BoardLayer.label
        anchor.addChild(label)
    }

    private func addPumpNode(_ coord: GridCoord, id: Int) {
        guard let pump = world.pumps[id] else { return }
        let top = pump.online ? SKColor.systemOrange
            : SKColor(red: 0.4, green: 0.1, blue: 0.1, alpha: 1)
        let anchor = addIsoBox(at: coord, inset: 5, height: 13,
                               topColor: top,
                               strokeColor: pump.hasBackupPump ? .systemGreen : .white,
                               lineWidth: 2,
                               layer: BoardLayer.utility)

        let arrow = SKLabelNode(text: pump.online ? "↑" : "×")
        arrow.fontName = "Helvetica-Bold"; arrow.fontSize = 13; arrow.fontColor = .black
        arrow.verticalAlignmentMode = .center; arrow.horizontalAlignmentMode = .center
        arrow.zPosition = BoardLayer.label
        anchor.addChild(arrow)
    }

    private func addDrainNode(_ coord: GridCoord) {
        // A storm inlet: a shallow grate set into the street surface.
        let anchor = addIsoBox(at: coord, inset: 7, height: 2,
                               topColor: .systemTeal,
                               strokeColor: .white,
                               lineWidth: 1,
                               layer: BoardLayer.utility)
        let g = SKLabelNode(text: "≈")
        g.fontName = "Helvetica-Bold"; g.fontSize = 12; g.fontColor = .black
        g.verticalAlignmentMode = .center; g.horizontalAlignmentMode = .center
        g.zPosition = BoardLayer.label
        anchor.addChild(g)
    }

    private func addBasinNode(_ coord: GridCoord, id: Int) {
        guard let basin = world.basins[id] else { return }
        let fill = CGFloat(basin.stored) / CGFloat(RetentionBasin.capacity)
        // A sunken basin whose water level rises as it fills.
        addIsoBox(at: coord, inset: 3, height: 3 + 5 * fill,
                  topColor: SKColor(red: 0.2, green: 0.3 + 0.4 * fill, blue: 0.7, alpha: 1),
                  strokeColor: .white,
                  lineWidth: 1,
                  layer: BoardLayer.utility)
    }

    /// Multiply a color's brightness — used to fake directional lighting on the
    /// side faces of isometric blocks (top stays lit, walls go darker).
    private func shade(_ c: SKColor, _ factor: CGFloat) -> SKColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.usingColorSpace(.deviceRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SKColor(red: r * factor, green: g * factor, blue: b * factor, alpha: a)
    }

    /// Build a 3D isometric box standing on a tile: a lit top diamond raised by
    /// `height`, plus two shaded side walls down to the tile surface. Returns an
    /// anchor node sitting at the center of the *top* face so callers can attach
    /// labels there. Nodes are added to `boardNode` and tracked in `dynamicNodes`.
    @discardableResult
    private func addIsoBox(at coord: GridCoord,
                           inset: CGFloat,
                           height: CGFloat,
                           topColor: SKColor,
                           strokeColor: SKColor,
                           lineWidth: CGFloat,
                           layer: CGFloat) -> SKNode {
        let tw = GameScene.tileWidth - inset * 2
        let th = GameScene.tileHeight - inset * 2

        let container = SKNode()
        container.position = surfacePoint(coord)
        container.zPosition = zPosition(for: coord, layerOffset: layer)
        boardNode.addChild(container)
        dynamicNodes.append(container)

        // Left wall.
        let leftPath = CGMutablePath()
        leftPath.move(to: CGPoint(x: -tw / 2, y: height))
        leftPath.addLine(to: CGPoint(x: 0, y: height - th / 2))
        leftPath.addLine(to: CGPoint(x: 0, y: -th / 2))
        leftPath.addLine(to: CGPoint(x: -tw / 2, y: 0))
        leftPath.closeSubpath()
        let leftWall = SKShapeNode(path: leftPath)
        leftWall.fillColor = shade(topColor, 0.58)
        leftWall.strokeColor = strokeColor
        leftWall.lineWidth = lineWidth * 0.5
        leftWall.zPosition = 0
        container.addChild(leftWall)

        // Right wall.
        let rightPath = CGMutablePath()
        rightPath.move(to: CGPoint(x: tw / 2, y: height))
        rightPath.addLine(to: CGPoint(x: 0, y: height - th / 2))
        rightPath.addLine(to: CGPoint(x: 0, y: -th / 2))
        rightPath.addLine(to: CGPoint(x: tw / 2, y: 0))
        rightPath.closeSubpath()
        let rightWall = SKShapeNode(path: rightPath)
        rightWall.fillColor = shade(topColor, 0.78)
        rightWall.strokeColor = strokeColor
        rightWall.lineWidth = lineWidth * 0.5
        rightWall.zPosition = 0.1
        container.addChild(rightWall)

        // Lit top face.
        let topPath = CGMutablePath()
        topPath.move(to: CGPoint(x: 0, y: height + th / 2))
        topPath.addLine(to: CGPoint(x: tw / 2, y: height))
        topPath.addLine(to: CGPoint(x: 0, y: height - th / 2))
        topPath.addLine(to: CGPoint(x: -tw / 2, y: height))
        topPath.closeSubpath()
        let topNode = SKShapeNode(path: topPath)
        topNode.fillColor = topColor
        topNode.strokeColor = strokeColor
        topNode.lineWidth = lineWidth
        topNode.zPosition = 0.2
        container.addChild(topNode)

        let anchor = SKNode()
        anchor.position = CGPoint(x: 0, y: height)
        anchor.zPosition = 0.3
        container.addChild(anchor)
        return anchor
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
        overlay.zPosition = LayerRange.modal
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
