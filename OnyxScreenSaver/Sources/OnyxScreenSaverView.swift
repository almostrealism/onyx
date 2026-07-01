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
        animationTimeInterval = 1.0 / 24.0
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        sceneView.autoresizingMask = [.width, .height]
        sceneView.frame = bounds
        sceneView.backgroundColor = .black
        // Anti-alias was 4× — meaningful perf hit on base-M1 hardware at
        // screensaver resolutions. 2× is barely distinguishable visually
        // and ~half the fragment cost on the cubes.
        sceneView.antialiasingMode = .multisampling2X
        // 24 fps is the perf floor: enough to look smooth on slow drift
        // and orbit motion, low enough that we stay inside the per-frame
        // budget on integrated GPUs and avoid visible stuttering.
        sceneView.preferredFramesPerSecond = 24
        // Do NOT start rendering here. macOS instantiates this view for the
        // System Settings preview and for thumbnail generation, and in those
        // cases it may NEVER call startAnimation(). If we start the SceneKit
        // render loop (and the scene's data-driver timers) in init, they run
        // forever off-screen — that's the `legacyScreenSaver` idle-CPU bug.
        // Rendering + data drivers are gated on startAnimation()/stopAnimation().
        sceneView.isPlaying = false
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
        sceneView.isPlaying = true      // resume the SceneKit render loop
        sculpture?.start()              // resume live/mock data drivers
    }

    public override func stopAnimation() {
        super.stopAnimation()
        sceneView.isPlaying = false     // pause rendering (halts per-frame physics)
        sculpture?.stop()               // stop the reader + mock timers
    }

    public override func animateOneFrame() {
        // SceneKit drives its own loop; this is just to keep the
        // ScreenSaver framework happy with a non-empty implementation.
        super.animateOneFrame()
    }
}
