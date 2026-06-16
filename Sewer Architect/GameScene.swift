//
//  GameScene.swift
//  Sewer Architect
//
//  Renders the grid, buildings, pipes, toolbar, and HUD; routes mouse input
//  to either toolbar buttons or grid placement.
//

import SpriteKit

final class GameScene: SKScene {

    // MARK: Layout constants

    static let tileSize: CGFloat = 32
    static let gridWidth: Int = 20
    static let gridHeight: Int = 15
    static let hudHeight: CGFloat = 60

    static var sceneSize: CGSize {
        CGSize(
            width: CGFloat(gridWidth) * tileSize,
            height: CGFloat(gridHeight) * tileSize + hudHeight
        )
    }

    // MARK: Model

    private let world = World(width: gridWidth, height: gridHeight)
    private lazy var simulation = Simulation(world: world)

    // MARK: Render nodes

    private let boardNode = SKNode()
    private let uiNode = SKNode()
    private var tileNodes: [[SKSpriteNode]] = []
    private var pipeNodes: [GridCoord: SKSpriteNode] = [:]
    private var buildingNodes: [GridCoord: SKNode] = [:]

    // MARK: UI

    private var toolButtons: [(tool: BuildTool, node: SKShapeNode)] = []
    private var playButton: SKShapeNode!
    private var playButtonLabel: SKLabelNode!
    private let statusLabel = SKLabelNode()

    // MARK: State

    private var currentTool: BuildTool = .pipe
    private var isRunning: Bool = false
    private let tickInterval: TimeInterval = 0.5
    private var timeAccumulator: TimeInterval = 0
    private var lastUpdateTime: TimeInterval = 0

    // MARK: Lifecycle

    override func didMove(to view: SKView) {
        size = GameScene.sceneSize
        anchorPoint = .zero
        backgroundColor = SKColor(white: 0.12, alpha: 1.0)

        removeAllChildren()
        addChild(boardNode)
        addChild(uiNode)
        uiNode.position = CGPoint(
            x: 0,
            y: CGFloat(GameScene.gridHeight) * GameScene.tileSize
        )

        buildGridTiles()
        buildToolbar()
        refreshRender()
    }

    // MARK: Grid building

    private func buildGridTiles() {
        var rows: [[SKSpriteNode]] = []
        rows.reserveCapacity(GameScene.gridWidth)
        for x in 0..<GameScene.gridWidth {
            var column: [SKSpriteNode] = []
            column.reserveCapacity(GameScene.gridHeight)
            for y in 0..<GameScene.gridHeight {
                let isEven = (x + y) % 2 == 0
                let color: SKColor = isEven
                    ? SKColor(white: 0.22, alpha: 1)
                    : SKColor(white: 0.18, alpha: 1)
                let node = SKSpriteNode(
                    color: color,
                    size: CGSize(
                        width: GameScene.tileSize - 1,
                        height: GameScene.tileSize - 1
                    )
                )
                node.position = pointForCoord(GridCoord(x: x, y: y))
                boardNode.addChild(node)
                column.append(node)
            }
            rows.append(column)
        }
        tileNodes = rows
    }

    // MARK: Toolbar building

    private func buildToolbar() {
        let bg = SKSpriteNode(
            color: SKColor(white: 0.08, alpha: 1.0),
            size: CGSize(width: size.width, height: GameScene.hudHeight)
        )
        bg.anchorPoint = .zero
        bg.position = .zero
        uiNode.addChild(bg)

        let tools: [(BuildTool, String, SKColor)] = [
            (.house, "House", .systemBlue),
            (.plant, "Plant", .systemGreen),
            (.pipe,  "Pipe",  .systemGray),
            (.erase, "Erase", .systemRed)
        ]

        let buttonSize = CGSize(width: 78, height: 36)
        var cursorX: CGFloat = 8

        for (tool, title, color) in tools {
            let btn = SKShapeNode(rectOf: buttonSize, cornerRadius: 6)
            btn.position = CGPoint(
                x: cursorX + buttonSize.width / 2,
                y: GameScene.hudHeight / 2
            )
            btn.fillColor = color
            btn.strokeColor = .white
            btn.lineWidth = tool == currentTool ? 4 : 1
            btn.name = "tool:\(tool.rawValue)"
            uiNode.addChild(btn)

            let label = SKLabelNode(text: title)
            label.fontName = "Helvetica-Bold"
            label.fontSize = 14
            label.fontColor = .white
            label.verticalAlignmentMode = .center
            label.horizontalAlignmentMode = .center
            label.position = .zero
            btn.addChild(label)

            toolButtons.append((tool, btn))
            cursorX += buttonSize.width + 8
        }

        let pp = SKShapeNode(rectOf: buttonSize, cornerRadius: 6)
        pp.position = CGPoint(
            x: cursorX + buttonSize.width / 2,
            y: GameScene.hudHeight / 2
        )
        pp.fillColor = .systemPurple
        pp.strokeColor = .white
        pp.lineWidth = 2
        pp.name = "play"
        uiNode.addChild(pp)

        let ppLabel = SKLabelNode(text: "Play")
        ppLabel.fontName = "Helvetica-Bold"
        ppLabel.fontSize = 14
        ppLabel.fontColor = .white
        ppLabel.verticalAlignmentMode = .center
        ppLabel.horizontalAlignmentMode = .center
        ppLabel.position = .zero
        pp.addChild(ppLabel)

        playButton = pp
        playButtonLabel = ppLabel
        cursorX += buttonSize.width + 16

        statusLabel.fontName = "Menlo"
        statusLabel.fontSize = 12
        statusLabel.fontColor = .white
        statusLabel.horizontalAlignmentMode = .left
        statusLabel.verticalAlignmentMode = .center
        statusLabel.position = CGPoint(x: cursorX, y: GameScene.hudHeight / 2)
        uiNode.addChild(statusLabel)
    }

    private func refreshToolHighlight() {
        for (tool, node) in toolButtons {
            node.lineWidth = tool == currentTool ? 4 : 1
        }
    }

    // MARK: Coordinate conversion

    private func pointForCoord(_ c: GridCoord) -> CGPoint {
        CGPoint(
            x: (CGFloat(c.x) + 0.5) * GameScene.tileSize,
            y: (CGFloat(c.y) + 0.5) * GameScene.tileSize
        )
    }

    private func coordForBoardPoint(_ p: CGPoint) -> GridCoord? {
        guard p.x >= 0, p.y >= 0 else { return nil }
        let cx = Int(p.x / GameScene.tileSize)
        let cy = Int(p.y / GameScene.tileSize)
        let coord = GridCoord(x: cx, y: cy)
        return world.inBounds(coord) ? coord : nil
    }

    private var boardTopY: CGFloat {
        CGFloat(GameScene.gridHeight) * GameScene.tileSize
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        let scenePoint = event.location(in: self)
        if scenePoint.y >= boardTopY {
            handleToolbarClick(at: scenePoint)
        } else {
            handleBoardClick(at: scenePoint)
        }
    }

    private func handleToolbarClick(at scenePoint: CGPoint) {
        for node in nodes(at: scenePoint) {
            guard let name = node.name else { continue }
            if name == "play" {
                isRunning.toggle()
                playButtonLabel.text = isRunning ? "Pause" : "Play"
                return
            }
            if name.hasPrefix("tool:") {
                let raw = String(name.dropFirst("tool:".count))
                if let tool = BuildTool(rawValue: raw) {
                    currentTool = tool
                    refreshToolHighlight()
                    refreshRender()
                }
                return
            }
        }
    }

    private func handleBoardClick(at scenePoint: CGPoint) {
        let boardPoint = boardNode.convert(scenePoint, from: self)
        guard let coord = coordForBoardPoint(boardPoint) else { return }
        if world.place(currentTool, at: coord) {
            refreshRender()
        }
    }

    // MARK: Update loop

    override func update(_ currentTime: TimeInterval) {
        if lastUpdateTime == 0 {
            lastUpdateTime = currentTime
            return
        }
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
        }
    }

    // MARK: Render

    private func refreshRender() {
        for node in pipeNodes.values { node.removeFromParent() }
        pipeNodes.removeAll(keepingCapacity: true)
        for node in buildingNodes.values { node.removeFromParent() }
        buildingNodes.removeAll(keepingCapacity: true)

        for x in 0..<GameScene.gridWidth {
            for y in 0..<GameScene.gridHeight {
                let coord = GridCoord(x: x, y: y)
                switch world.tiles[x][y] {
                case .empty:
                    break
                case .pipe:
                    let node = SKSpriteNode(
                        color: pipeColor(at: coord),
                        size: CGSize(
                            width: GameScene.tileSize - 6,
                            height: GameScene.tileSize - 6
                        )
                    )
                    node.position = pointForCoord(coord)
                    boardNode.addChild(node)
                    pipeNodes[coord] = node
                case .house(let id):
                    let node = SKShapeNode(
                        rectOf: CGSize(
                            width: GameScene.tileSize - 4,
                            height: GameScene.tileSize - 4
                        ),
                        cornerRadius: 4
                    )
                    let backedUp = world.houses[id]?.isBackedUp ?? false
                    node.fillColor = backedUp ? .systemRed : .systemBlue
                    node.strokeColor = .white
                    node.lineWidth = 1
                    node.position = pointForCoord(coord)
                    boardNode.addChild(node)
                    buildingNodes[coord] = node
                case .plant:
                    let node = SKShapeNode(
                        rectOf: CGSize(
                            width: GameScene.tileSize - 2,
                            height: GameScene.tileSize - 2
                        ),
                        cornerRadius: 6
                    )
                    node.fillColor = .systemGreen
                    node.strokeColor = .white
                    node.lineWidth = 2
                    node.position = pointForCoord(coord)
                    boardNode.addChild(node)
                    buildingNodes[coord] = node
                }
            }
        }
        updateStatus()
    }

    private func pipeColor(at coord: GridCoord) -> SKColor {
        guard let pipe = world.pipes[coord] else {
            return SKColor(white: 0.5, alpha: 1)
        }
        let capacity = PipeState.capacityPerTick
        let frac = Double(pipe.flowThisTick) / Double(capacity)
        switch frac {
        case ..<0.01: return SKColor(white: 0.5, alpha: 1)
        case ..<0.34: return .systemTeal
        case ..<0.67: return .systemYellow
        case ..<1.0:  return .systemOrange
        default:      return .systemRed
        }
    }

    private func updateStatus() {
        let totalTreated = world.plants.values.reduce(0) { $0 + $1.lifetimeTreated }
        let backups = world.houses.values.filter { $0.isBackedUp }.count
        statusLabel.text = String(
            format: "tick %d  houses %d  plants %d  backups %d  treated %d  tool: %@",
            simulation.tick,
            world.houses.count,
            world.plants.count,
            backups,
            totalTreated,
            currentTool.rawValue
        )
    }
}
