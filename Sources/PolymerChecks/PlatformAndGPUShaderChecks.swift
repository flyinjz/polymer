// Headless deterministic checks for PolymerPlatform windowing/clipboard/audio-output
// and PolymerGPU shaders + SoftwareGPURasterizer parity against CPU Canvas.
import PolymerBase
import PolymerPlatform
import PolymerText
import PolymerRender
import PolymerGPU

@MainActor public let platformAndGPUShaderChecks: [Check] = [
    Check("platform.window-headless") { c in
        @MainActor
        final class SessionRecorder {
            var events: [WindowEvent] = []
            var renderCount: Int = 0
            var remainingTicks: Int = 3
            var currentSize = Size(width: 320, height: 200)
        }

        let scripted: [WindowEvent] = [
            .resized(size: Size(width: 640, height: 480), scale: 2.0),
            .pointerMoved(Point(x: 120, y: 80)),
            .pointerDown(Point(x: 120, y: 80), .left),
            .pointerUp(Point(x: 120, y: 80), .left),
            .scroll(at: Point(x: 120, y: 80), dx: 0, dy: -24),
            .key(WindowKeyEvent(key: "k", characters: "k", command: true, isDown: true)),
            .key(WindowKeyEvent(key: "return", characters: "\r", isDown: true)),
            .pointerExited,
        ]

        let runner = HeadlessWindowRunner(events: scripted, renderOnEveryEvent: false, maxAnimationTicks: 6, tickInterval: 1.0 / 60.0)
        let recorder = SessionRecorder()
        let options = WindowOptions(title: "Polymer Headless Check", width: 640, height: 480, resizable: true, darkGlass: true)

        try runner.runWindow(
            options: options,
            onEvent: { event in
                recorder.events.append(event)
                switch event {
                case .resized(let size, _):
                    recorder.currentSize = size
                case .tick:
                    recorder.remainingTicks -= 1
                default:
                    break
                }
            },
            renderFrame: {
                recorder.renderCount += 1
                let w = max(1, Int(recorder.currentSize.width))
                let h = max(1, Int(recorder.currentSize.height))
                let byte = UInt8(recorder.renderCount & 0xFF)
                return FrameBuffer(width: w, height: h, pixels: [UInt8](repeating: byte, count: w * h * 4))
            },
            needsAnimation: {
                recorder.remainingTicks > 0
            }
        )

        c.expectEqual(runner.lastOptions, options, "window options recorded")
        c.expectEqual(runner.animationTickCount, 3, "animation loop stops as soon as needsAnimation returns false")
        c.expectEqual(recorder.events.first, scripted.first, "first event is resized")
        c.expectEqual(recorder.events.last, .closed, "window closes cleanly at end of scripted run")
        c.expectEqual(recorder.events.count, scripted.count + 3 + 1, "all scripted events + 3 ticks + closed delivered")
        c.expectEqual(runner.dispatchedEvents, recorder.events, "runner event log matches handler log")
        c.expect(runner.renderedFrames.count >= 4, "rendered frames captured (\(runner.renderedFrames.count))")
        c.expect(runner.renderedFrames.allSatisfy { !$0.isEmpty && $0.width == 640 && $0.height == 480 }, "all presented framebuffers are valid 640x480")

        let shortcut = WindowKeyEvent(key: "tab", characters: "\t", shift: true)
        c.expectEqual(shortcut.keyPressText, "shift+tab", "WindowKeyEvent.keyPressText formats shift+tab")
        let cmdK = WindowKeyEvent(key: "k", characters: "k", command: true)
        c.expectEqual(cmdK.keyPressText, "cmd+k", "WindowKeyEvent.keyPressText formats cmd+k")

        let clip = InMemoryClipboard()
        c.expectEqual(clip.getString(), nil, "clipboard starts empty")
        clip.setString("Polymer 64-bit Audio")
        c.expectEqual(clip.getString(), "Polymer 64-bit Audio", "clipboard stores and retrieves string")
        clip.setString("Updated Copy")
        c.expectEqual(clip.getString(), "Updated Copy", "clipboard overwrites cleanly")

        let audioBackend = HeadlessAudioOutputBackend()
        let devices = audioBackend.listDevices()
        c.expect(!devices.isEmpty, "headless audio backend reports at least one device")
        c.expectEqual(audioBackend.defaultDevice()?.id, "headless-default", "default headless audio device matches")
        c.expect(audioBackend.defaultDevice()?.sampleRates.contains(192_000) == true, "supports 192 kHz")
        c.expectEqual(AudioOutputMode.exclusive.rawValue, "exclusive", "AudioOutputMode rawValue")

        Platform.installDesktop(windowRunner: runner, clipboard: clip, audioOutput: audioBackend)
        c.expect(Platform.windowRunner != nil, "Platform.windowRunner installed")
        c.expectEqual(Platform.clipboard.getString(), "Updated Copy", "Platform.clipboard points to installed clipboard")
        c.expectEqual(Platform.audioOutput.defaultDevice()?.id, "headless-default", "Platform.audioOutput installed")

        c.note("events=\(recorder.events.count), frames=\(runner.renderedFrames.count), ticks=\(runner.animationTickCount)")
    },

    Check("gpu.shader-rasterizer") { c in
        c.expect(GPUShaderSources.validateLayouts(), "GPUShaderUniforms & GPUQuadInstance layouts and shader entry points validate")
        c.expectEqual(MemoryLayout<GPUShaderUniforms>.stride, 16, "GPUShaderUniforms stride is 16 bytes")
        c.expectEqual(MemoryLayout<GPUQuadInstance>.stride, 76, "GPUQuadInstance stride is 76 bytes")
        c.expect(GPUShaderSources.metalMSL.contains("quadVertex"), "MSL contains quadVertex")
        c.expect(GPUShaderSources.metalMSL.contains("glyphFragment"), "MSL contains glyphFragment")
        c.expect(GPUShaderSources.d3d12HLSL.contains("VSMain"), "HLSL contains VSMain")
        c.expect(GPUShaderSources.d3d12HLSL.contains("PSMain"), "HLSL contains PSMain")

        let inter = try TextReference.font(root: c.root, "Inter-Regular.otf")
        let bg = Color(hex: 0x101012)
        var list = DisplayList(width: 240, height: 140, scale: 2)

        list.fill(Rect(x: 6, y: 6, width: 108, height: 58), Color(hex: 0x20222A))
        list.fill(Rect(x: 10, y: 10, width: 44, height: 22), Color(hex: 0x3A82F6))
        list.fill(Rect(x: 30, y: 16, width: 44, height: 22), Color(hex: 0xE25555, opacity: 0.5))

        var imgBmp = Bitmap(width: 4, height: 4)
        for y in 0..<4 {
            for x in 0..<4 {
                let o = (y * 4 + x) * 4
                imgBmp.pixels[o] = UInt8(60 + x * 55)
                imgBmp.pixels[o + 1] = UInt8(80 + y * 45)
                imgBmp.pixels[o + 2] = 210
                imgBmp.pixels[o + 3] = 255
            }
        }
        let img = RenderImage(imgBmp)
        list.drawImage(img, in: Rect(x: 82, y: 10, width: 24, height: 24), opacity: 0.9, filter: .bilinear)

        list.fill(Path(roundedRect: Rect(x: 82, y: 38, width: 26, height: 18), cornerRadius: 4), Color(hex: 0x55B87A))

        list.clipped(to: Rect(x: 10, y: 38, width: 66, height: 22)) { l in
            l.fill(Rect(x: 0, y: 34, width: 120, height: 34), Color(hex: 0x18181E))
            let glyphs = TextLayout.line("Polymer", font: inter, pixelSize: 12)
            l.drawGlyphs(glyphs, font: inter, size: 12, at: Point(x: 14, y: 54), color: .white)
        }

        let compiler = DisplayListCompiler()
        let device = RecordingGPUDevice(name: "ShaderParityGPU")
        let compiled = compiler.compile(list, device: device)

        let gpuBitmap = SoftwareGPURasterizer.rasterize(
            frame: compiled,
            glyphAtlas: compiler.glyphAtlas,
            pathAtlas: compiler.pathAtlas,
            device: device,
            background: bg
        )

        var cpuCanvas = Canvas(width: list.width, height: list.height, scale: list.scale, background: bg)
        cpuCanvas.draw(list)
        let cpuBitmap = cpuCanvas.bitmap

        c.expectEqual(gpuBitmap.width, cpuBitmap.width, "bitmap width matches")
        c.expectEqual(gpuBitmap.height, cpuBitmap.height, "bitmap height matches")

        for (px, py, label) in [(28, 28, "opaque blue rect"), (76, 48, "alpha-blended overlap"), (2, 2, "outside background")] {
            let gPx = gpuBitmap[px, py]
            let cPx = cpuBitmap[px, py]
            c.expectEqual(gPx.r, cPx.r, "\(label) R matches")
            c.expectEqual(gPx.g, cPx.g, "\(label) G matches")
            c.expectEqual(gPx.b, cPx.b, "\(label) B matches")
            c.expectEqual(gPx.a, cPx.a, "\(label) A matches")
        }

        let outside = gpuBitmap[40, 130]
        let expectedBg = cpuBitmap[40, 130]
        c.expectEqual(outside.r, expectedBg.r, "clip boundary prevents R leak")
        c.expectEqual(outside.g, expectedBg.g, "clip boundary prevents G leak")
        c.expectEqual(outside.b, expectedBg.b, "clip boundary prevents B leak")

        var sumErr = 0.0
        let totalChannels = gpuBitmap.pixels.count
        for i in 0..<totalChannels {
            sumErr += abs(Double(gpuBitmap.pixels[i]) - Double(cpuBitmap.pixels[i]))
        }
        let meanAbsErr = sumErr / Double(max(1, totalChannels))
        c.expect(meanAbsErr < 1.5, "full-frame SoftwareGPURasterizer mean channel error (\(meanAbsErr)) < 1.5/255")

        var cpuInk = 0.0
        var gpuInk = 0.0
        let panelBase = Double(0x18)
        for y in 76..<120 {
            for x in 20..<152 {
                let cp = cpuBitmap[x, y]
                let gp = gpuBitmap[x, y]
                cpuInk += max(0, Double(cp.r) - panelBase)
                gpuInk += max(0, Double(gp.r) - panelBase)
            }
        }
        let inkRatio = cpuInk > 0 ? gpuInk / cpuInk : 0
        c.expect(cpuInk > 1000, "glyph region contains substantial ink (\(cpuInk))")
        c.expectClose(inkRatio, 1.0, tolerance: 0.08, "glyph ink ratio matches CPU Canvas")

        c.note("meanAbsErr=\(meanAbsErr)/255, glyphInkRatio=\(inkRatio), batches=\(compiled.drawCallCount)")
    },
]
