//
//  GameScene.swift
//  Sewer Architect
//
//  Renders terrain, the pipe network, buildings, a control panel, a live HUD,
//  a news ticker, and the quarterly report-card overlay. Routes mouse + keyboard
//  input to building actions and game controls.
//

import SpriteKit

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

    private let world = World(width: gridWidth, height: gridHeight)
    private lazy var simulation = Simulation(world: world)
    private var maxElevation: Int = 1

    // MARK: Render nodes

    private let boardNode = SKNode()
    private let uiNode = SKNode()
    private var tileNodes: [[SKSpriteNode]] = []
    private var dynamicNodes: [SKNode] = []   // pipes + buildings, rebuilt per refresh
    private var reportOverlay: SKNode?

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

        maxElevation = max(1, world.elevation.flatMap { $0 }.max() ?? 1)
        world.seedStartingCity()

        removeAllChildren()
        addChild(boardNode)
        addChild(uiNode)
        uiNode.position = CGPoint(x: 0, y: GameScene.boardHeight)

        buildTerrainTiles()
        buildPanel()
        refreshRender()
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

    private func coordForBoardPoint(_ p: CGPoint) -> GridCoord? {
        guard p.x >= 0, p.y >= 0 else { return nil }
        let coord = GridCoord(x: Int(p.x / GameScene.tileSize),
                              y: Int(p.y / GameScene.tileSize))
        return world.inBounds(coord) ? coord : nil
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        let p = event.location(in: self)
        if reportOverlay != nil { dismissReport(); return }
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
            simulation.mode = simulation.mode == .sandbox ? .scenario : .sandbox
            controlLabel("ctl:mode")?.text = simulation.mode.displayName
        case "ctl:report":
            toggleReport()
        default:
            break
        }
        refreshRender()
    }

    private func cycleMaterial() {
        let all = PipeMaterial.allCases
        let i = all.firstIndex(of: world.selectedMaterial) ?? 0
        world.selectedMaterial = all[(i + 1) % all.count]
        controlLabel("ctl:material")?.text = "Pipe:" + String(world.selectedMaterial.displayName.prefix(4))
    }

    private func cyclePlantTier() {
        let all = PlantTier.allCases
        let i = all.firstIndex(of: world.selectedPlantTier) ?? 0
        world.selectedPlantTier = all[(i + 1) % all.count]
        controlLabel("ctl:tier")?.text = "Plant:" + String(world.selectedPlantTier.displayName.prefix(3))
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
        if ticked { refreshRender() }
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
        updateStatus()
        if reportOverlay != nil { rebuildReportOverlay() }
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
        let node = SKShapeNode(rectOf: CGSize(width: GameScene.tileSize - 4,
                                              height: GameScene.tileSize - 4),
                               cornerRadius: 4)
        let brightness = 0.55 + 0.15 * CGFloat(house.level)
        node.fillColor = zoneColor(house.zone, brightness: brightness)
        node.strokeColor = house.isBackedUp ? .red : (house.isConnected ? .white : .systemYellow)
        node.lineWidth = house.isBackedUp ? 3 : 1
        node.position = pointForCoord(coord)
        boardNode.addChild(node)
        dynamicNodes.append(node)

        let letter = SKLabelNode(text: String(house.zone.shortName.prefix(1)))
        letter.fontName = "Helvetica-Bold"; letter.fontSize = 12; letter.fontColor = .black
        letter.verticalAlignmentMode = .center; letter.horizontalAlignmentMode = .center
        node.addChild(letter)
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
        let node = SKShapeNode(rectOf: CGSize(width: GameScene.tileSize - 2,
                                              height: GameScene.tileSize - 2),
                               cornerRadius: 6)
        let tierBrightness: CGFloat = plant.tier == .primary ? 0.5
            : (plant.tier == .secondary ? 0.75 : 1.0)
        node.fillColor = SKColor(red: 0.15, green: 0.7 * tierBrightness, blue: 0.25, alpha: 1)
        node.strokeColor = plant.condition < 30 ? .red : .white
        node.lineWidth = 2
        node.position = pointForCoord(coord)
        boardNode.addChild(node)
        dynamicNodes.append(node)

        let label = SKLabelNode(text: "P\(plant.tier == .primary ? "1" : plant.tier == .secondary ? "2" : "3")")
        label.fontName = "Helvetica-Bold"; label.fontSize = 11; label.fontColor = .white
        label.verticalAlignmentMode = .center; label.horizontalAlignmentMode = .center
        node.addChild(label)
    }

    private func addPumpNode(_ coord: GridCoord, id: Int) {
        guard let pump = world.pumps[id] else { return }
        let node = SKShapeNode(rectOf: CGSize(width: GameScene.tileSize - 6,
                                              height: GameScene.tileSize - 6),
                               cornerRadius: 3)
        node.fillColor = pump.online ? .systemOrange : SKColor(red: 0.4, green: 0.1, blue: 0.1, alpha: 1)
        node.strokeColor = pump.hasBackupPump ? .systemGreen : .white
        node.lineWidth = 2
        node.zRotation = .pi / 4
        node.position = pointForCoord(coord)
        boardNode.addChild(node)
        dynamicNodes.append(node)

        let arrow = SKLabelNode(text: pump.online ? "↑" : "×")
        arrow.fontName = "Helvetica-Bold"; arrow.fontSize = 13; arrow.fontColor = .black
        arrow.verticalAlignmentMode = .center; arrow.horizontalAlignmentMode = .center
        arrow.zRotation = -.pi / 4
        node.addChild(arrow)
    }

    private func addDrainNode(_ coord: GridCoord) {
        let node = SKShapeNode(rectOf: CGSize(width: GameScene.tileSize - 8,
                                              height: GameScene.tileSize - 8),
                               cornerRadius: 2)
        node.fillColor = .systemTeal
        node.strokeColor = .white
        node.lineWidth = 1
        node.position = pointForCoord(coord)
        boardNode.addChild(node)
        dynamicNodes.append(node)
        let g = SKLabelNode(text: "≈")
        g.fontName = "Helvetica-Bold"; g.fontSize = 12; g.fontColor = .black
        g.verticalAlignmentMode = .center; g.horizontalAlignmentMode = .center
        node.addChild(g)
    }

    private func addBasinNode(_ coord: GridCoord, id: Int) {
        guard let basin = world.basins[id] else { return }
        let node = SKShapeNode(rectOf: CGSize(width: GameScene.tileSize - 4,
                                              height: GameScene.tileSize - 4),
                               cornerRadius: 8)
        let fill = CGFloat(basin.stored) / CGFloat(RetentionBasin.capacity)
        node.fillColor = SKColor(red: 0.2, green: 0.3 + 0.4 * fill, blue: 0.7, alpha: 1)
        node.strokeColor = .white
        node.lineWidth = 1
        node.position = pointForCoord(coord)
        boardNode.addChild(node)
        dynamicNodes.append(node)
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
        case .ongoing:     outcomeStr = simulation.mode == .scenario ? "Scenario: in progress" : "Sandbox"
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

    // MARK: Report card overlay

    private func toggleReport() {
        if reportOverlay != nil { dismissReport() } else { presentReport() }
    }

    private func presentReport() {
        let overlay = SKNode()
        overlay.zPosition = 1000
        addChild(overlay)
        reportOverlay = overlay
        rebuildReportOverlay()
    }

    private func dismissReport() {
        reportOverlay?.removeFromParent()
        reportOverlay = nil
    }

    private func rebuildReportOverlay() {
        guard let overlay = reportOverlay else { return }
        overlay.removeAllChildren()

        let panel = SKSpriteNode(color: SKColor(white: 0.05, alpha: 0.95),
                                 size: CGSize(width: size.width * 0.8, height: size.height * 0.7))
        panel.position = CGPoint(x: size.width / 2, y: size.height / 2)
        overlay.addChild(panel)

        let lines: [String]
        if let c = simulation.lastReportCard {
            lines = [
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
        } else {
            lines = [
                "DEPARTMENT OF SANITATION — QUARTERLY REPORT",
                "",
                "No report yet — press Play and run a full quarter",
                "(\(Simulation.ticksPerQuarter) ticks) to receive your first review.",
                "",
                "(click anywhere or press R to close)"
            ]
        }

        let startY = panel.position.y + panel.size.height / 2 - 34
        for (i, line) in lines.enumerated() {
            let label = SKLabelNode(text: line)
            label.fontName = i == 0 ? "Menlo-Bold" : "Menlo"
            label.fontSize = i == 0 ? 14 : 12
            label.fontColor = .white
            label.horizontalAlignmentMode = .center
            label.verticalAlignmentMode = .center
            label.position = CGPoint(x: panel.position.x, y: startY - CGFloat(i) * 22)
            overlay.addChild(label)
        }
    }
}
