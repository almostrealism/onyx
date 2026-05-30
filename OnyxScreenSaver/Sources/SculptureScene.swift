import AppKit
import SceneKit

/// Owns the SceneKit scene for the screensaver. Phase 1 is a placeholder —
/// one rotating cube against a dark backdrop — so we can verify the install
/// loop. The real per-host totems land in phase 2.
final class SculptureScene {

    let scene = SCNScene()
    let cameraNode = SCNNode()

    init(isPreview: Bool) {
        scene.background.contents = NSColor.black

        // Camera — pulled back enough to frame a couple of totems comfortably.
        let camera = SCNCamera()
        camera.zNear = 0.1
        camera.zFar = 200
        camera.fieldOfView = 50
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 30)
        scene.rootNode.addChildNode(cameraNode)

        // Soft ambient + a single warm directional light. Keeps the cubes
        // legible without flattening them.
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 300
        ambient.light?.color = NSColor(white: 1, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 800
        key.light?.color = NSColor(calibratedHue: 0.08, saturation: 0.2,
                                   brightness: 1.0, alpha: 1.0)
        key.eulerAngles = SCNVector3(-Float.pi / 4, Float.pi / 4, 0)
        scene.rootNode.addChildNode(key)

        // Phase 1 placeholder: one slowly spinning cube. Proves the saver is
        // loaded, the SceneKit pipeline is alive, and we have something to
        // look at while picking the saver in System Settings.
        let placeholder = makePlaceholderCube()
        scene.rootNode.addChildNode(placeholder)

        // Preview thumbnails in System Settings are tiny — slow the spin so
        // it looks intentional rather than frantic.
        let spinDuration: TimeInterval = isPreview ? 8 : 16
        let spin = CABasicAnimation(keyPath: "rotation")
        spin.fromValue = NSValue(scnVector4: SCNVector4(0, 1, 0, 0))
        spin.toValue = NSValue(scnVector4: SCNVector4(0, 1, 0, Float.pi * 2))
        spin.duration = spinDuration
        spin.repeatCount = .infinity
        placeholder.addAnimation(spin, forKey: "spin")
    }

    private func makePlaceholderCube() -> SCNNode {
        let size: CGFloat = 4
        let box = SCNBox(width: size, height: size, length: size,
                         chamferRadius: 0.15)
        let material = SCNMaterial()
        material.diffuse.contents = NSColor(calibratedHue: 0.08,
                                            saturation: 0.85,
                                            brightness: 1.0,
                                            alpha: 1.0)
        material.specular.contents = NSColor.white
        material.lightingModel = .blinn
        box.materials = [material]

        let node = SCNNode(geometry: box)
        return node
    }
}
