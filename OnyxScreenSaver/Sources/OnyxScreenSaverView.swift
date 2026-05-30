import AppKit
import SceneKit
import ScreenSaver

/// Root view for the Onyx screensaver bundle.
///
/// macOS loads the screensaver as a plugin and instantiates this class once
/// per screen. The view owns a SceneKit scene that hosts one "cube totem" per
/// connected Onyx host. Phase 1 just renders a placeholder rotating cube so
/// we can verify the install loop end-to-end before wiring real data.
@objc(OnyxScreenSaverView)
public final class OnyxScreenSaverView: ScreenSaverView {

    private let sceneView = SCNView()
    private var sculpture: SculptureScene?

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        configure()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        // ScreenSaver framework calls animateOneFrame on a timer; SceneKit
        // drives its own render loop, so we just need to keep the host view
        // sized and let SceneKit do the work.
        animationTimeInterval = 1.0 / 30.0
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        sceneView.autoresizingMask = [.width, .height]
        sceneView.frame = bounds
        sceneView.backgroundColor = .black
        sceneView.antialiasingMode = .multisampling4X
        sceneView.preferredFramesPerSecond = 30
        sceneView.isPlaying = true
        addSubview(sceneView)

        let scene = SculptureScene(isPreview: isPreview)
        sceneView.scene = scene.scene
        sceneView.pointOfView = scene.cameraNode
        // SCNView holds the delegate weakly — we keep a strong ref via
        // `sculpture` so its motion-update callback keeps firing.
        sceneView.delegate = scene
        sculpture = scene
    }

    public override func startAnimation() {
        super.startAnimation()
        sceneView.isPlaying = true
    }

    public override func stopAnimation() {
        super.stopAnimation()
        sceneView.isPlaying = false
    }

    public override func animateOneFrame() {
        // SceneKit drives its own loop; this is just to keep the
        // ScreenSaver framework happy with a non-empty implementation.
        super.animateOneFrame()
    }
}
