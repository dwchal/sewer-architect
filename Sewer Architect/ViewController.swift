//
//  ViewController.swift
//  Sewer Architect
//
//  Created by Doug Challener on 6/15/26.
//

import Cocoa
import SpriteKit
import GameplayKit

class ViewController: NSViewController {

    @IBOutlet var skView: SKView!
    
    override func viewDidLoad() {
        super.viewDidLoad()

        if let view = self.skView {
            let scene = GameScene(size: GameScene.sceneSize)
            scene.scaleMode = .aspectFit
            view.presentScene(scene)

            view.ignoresSiblingOrder = true
            view.showsFPS = true
            view.showsNodeCount = true
        }
    }
}

