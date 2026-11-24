// GPU shader contracts (Metal Shading Language and Direct3D 12 HLSL),
// uniform/instance layout verification, and a pure-Swift SoftwareGPURasterizer
// that executes CompiledFrame batches directly into a PolymerRender.Bitmap
// for deterministic headless pixel-parity checks.
import PolymerBase
import PolymerText
import PolymerRender

/// Per-frame shader uniform block shared by Metal (`buffer(1)`) and D3D12 (`cbuffer b0`).
/// 16 bytes (4 floats), matching 16-byte GPU constant buffer alignment rules.
public struct GPUShaderUniforms: Equatable, Hashable, Sendable {
    public var viewportWidth: Float
    public var viewportHeight: Float
    public var scale: Float
    public var time: Float

    public init(viewportWidth: Float, viewportHeight: Float, scale: Float = 1.0, time: Float = 0.0) {
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.scale = scale
        self.time = time
    }
}

/// Authoritative MSL and HLSL shader sources matching `GPUQuadInstance` and `GPUShaderUniforms`.
public enum GPUShaderSources {
    /// Complete Metal Shading Language vertex and fragment shaders for Polymer's instanced quad pipeline.
    public static let metalMSL: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct GPUShaderUniforms {
        float viewportWidth;
        float viewportHeight;
        float scale;
        float time;
    };

    struct GPUQuadInstance {
        uint kind;
        float x;
        float y;
        float width;
        float height;
        float u0;
        float v0;
        float u1;
        float v1;
        float r;
        float g;
        float b;
        float a;
        float clipX;
        float clipY;
        float clipW;
        float clipH;
        float cornerRadius;
        float blurRadius;
    };

    struct QuadVertexOut {
        float4 position [[position]];
        float2 pixelPos;
        float2 uv;
        float4 color;
        float4 clipRect;
        float4 quadBounds;
        float cornerRadius;
        uint kind;
    };

    constant float2 kQuadCorners[6] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 0.0),
        float2(1.0, 1.0),
        float2(0.0, 1.0)
    };

    static inline bool polymerOutsideClip(float2 p, float4 clipRect) {
        return p.x < clipRect.x || p.y < clipRect.y ||
               p.x >= (clipRect.x + clipRect.z) || p.y >= (clipRect.y + clipRect.w);
    }

    static inline float polymerRoundedRectCoverage(float2 p, float4 rect, float radius) {
        if (radius <= 0.0) { return 1.0; }
        float2 halfSize = rect.zw * 0.5;
        float r = min(radius, min(halfSize.x, halfSize.y));
        float2 center = rect.xy + halfSize;
        float2 q = abs(p - center) - (halfSize - float2(r));
        float dist = length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - r;
        return clamp(0.5 - dist, 0.0, 1.0);
    }

    vertex QuadVertexOut quadVertex(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        device const GPUQuadInstance* instances [[buffer(0)]],
        constant GPUShaderUniforms& uniforms [[buffer(1)]]
    ) {
        GPUQuadInstance inst = instances[instanceID];
        float2 corner = kQuadCorners[vertexID % 6];
        float2 px = float2(inst.x, inst.y) + corner * float2(inst.width, inst.height);

        float ndcX = (px.x / max(uniforms.viewportWidth, 1.0)) * 2.0 - 1.0;
        float ndcY = 1.0 - (px.y / max(uniforms.viewportHeight, 1.0)) * 2.0;

        QuadVertexOut out;
        out.position = float4(ndcX, ndcY, 0.0, 1.0);
        out.pixelPos = px;
        out.uv = mix(float2(inst.u0, inst.v0), float2(inst.u1, inst.v1), corner);
        out.color = float4(inst.r, inst.g, inst.b, inst.a);
        out.clipRect = float4(inst.clipX, inst.clipY, inst.clipW, inst.clipH);
        out.quadBounds = float4(inst.x, inst.y, inst.width, inst.height);
        out.cornerRadius = inst.cornerRadius;
        out.kind = inst.kind;
        return out;
    }

    fragment float4 solidRectFragment(QuadVertexOut in [[stage_in]]) {
        if (polymerOutsideClip(in.pixelPos, in.clipRect)) { discard_fragment(); }
        float cov = polymerRoundedRectCoverage(in.pixelPos, in.quadBounds, in.cornerRadius);
        return in.color * cov;
    }

    fragment float4 glyphFragment(
        QuadVertexOut in [[stage_in]],
        texture2d<float> glyphAtlas [[texture(0)]],
        sampler linearSampler [[sampler(0)]]
    ) {
        if (polymerOutsideClip(in.pixelPos, in.clipRect)) { discard_fragment(); }
        float cov = glyphAtlas.sample(linearSampler, in.uv).r;
        return in.color * cov;
    }

    fragment float4 imageFragment(
        QuadVertexOut in [[stage_in]],
        texture2d<float> imageTex [[texture(0)]],
        sampler linearSampler [[sampler(0)]]
    ) {
        if (polymerOutsideClip(in.pixelPos, in.clipRect)) { discard_fragment(); }
        float4 texel = imageTex.sample(linearSampler, in.uv);
        float4 premul = float4(texel.rgb * texel.a, texel.a);
        float cov = polymerRoundedRectCoverage(in.pixelPos, in.quadBounds, in.cornerRadius);
        return premul * (in.color.a * cov);
    }

    fragment float4 pathCoverageFragment(
        QuadVertexOut in [[stage_in]],
        texture2d<float> pathAtlas [[texture(0)]],
        sampler linearSampler [[sampler(0)]]
    ) {
        if (polymerOutsideClip(in.pixelPos, in.clipRect)) { discard_fragment(); }
        float cov = pathAtlas.sample(linearSampler, in.uv).r;
        return in.color * cov;
    }

    fragment float4 backdropBlurFragment(
        QuadVertexOut in [[stage_in]],
        texture2d<float> backdropTex [[texture(0)]],
        sampler linearSampler [[sampler(0)]]
    ) {
        if (polymerOutsideClip(in.pixelPos, in.clipRect)) { discard_fragment(); }
        float4 sampleVal = backdropTex.sample(linearSampler, in.uv);
        return sampleVal * in.color.a;
    }

    fragment float4 quadFragment(
        QuadVertexOut in [[stage_in]],
        texture2d<float> boundTex [[texture(0)]],
        sampler linearSampler [[sampler(0)]]
    ) {
        if (polymerOutsideClip(in.pixelPos, in.clipRect)) { discard_fragment(); }
        if (in.kind == 0u) {
            float cov = polymerRoundedRectCoverage(in.pixelPos, in.quadBounds, in.cornerRadius);
            return in.color * cov;
        } else if (in.kind == 1u || in.kind == 3u) {
            float cov = boundTex.sample(linearSampler, in.uv).r;
            return in.color * cov;
        } else if (in.kind == 2u) {
            float4 texel = boundTex.sample(linearSampler, in.uv);
            float4 premul = float4(texel.rgb * texel.a, texel.a);
            float cov = polymerRoundedRectCoverage(in.pixelPos, in.quadBounds, in.cornerRadius);
            return premul * (in.color.a * cov);
        } else {
            return boundTex.sample(linearSampler, in.uv) * in.color.a;
        }
    }
    """

    /// Complete HLSL Shader Model 6.0 vertex and pixel shaders for Direct3D 12 matching `GPUQuadInstance`.
    public static let d3d12HLSL: String = """
    cbuffer GPUShaderUniforms : register(b0) {
        float viewportWidth;
        float viewportHeight;
        float scale;
        float time;
    };

    struct GPUQuadInstance {
        uint kind;
        float x;
        float y;
        float width;
        float height;
        float u0;
        float v0;
        float u1;
        float v1;
        float r;
        float g;
        float b;
        float a;
        float clipX;
        float clipY;
        float clipW;
        float clipH;
        float cornerRadius;
        float blurRadius;
    };

    StructuredBuffer<GPUQuadInstance> gInstances : register(t0);
    Texture2D gTexture : register(t1);
    SamplerState gSampler : register(s0);

    struct PSInput {
        float4 position : SV_Position;
        float2 pixelPos : TEXCOORD0;
        float2 uv : TEXCOORD1;
        float4 color : COLOR0;
        float4 clipRect : TEXCOORD2;
        float4 quadBounds : TEXCOORD3;
        float cornerRadius : TEXCOORD4;
        nointerpolation uint kind : TEXCOORD5;
    };

    static const float2 kQuadCorners[6] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 0.0),
        float2(1.0, 1.0),
        float2(0.0, 1.0)
    };

    bool PolymerOutsideClip(float2 p, float4 clipRect) {
        return p.x < clipRect.x || p.y < clipRect.y ||
               p.x >= (clipRect.x + clipRect.z) || p.y >= (clipRect.y + clipRect.w);
    }

    float PolymerRoundedRectCoverage(float2 p, float4 rect, float radius) {
        if (radius <= 0.0) { return 1.0; }
        float2 halfSize = rect.zw * 0.5;
        float r = min(radius, min(halfSize.x, halfSize.y));
        float2 center = rect.xy + halfSize;
        float2 q = abs(p - center) - (halfSize - float2(r, r));
        float dist = length(max(q, float2(0.0, 0.0))) + min(max(q.x, q.y), 0.0) - r;
        return saturate(0.5 - dist);
    }

    PSInput VSMain(uint vertexID : SV_VertexID, uint instanceID : SV_InstanceID) {
        GPUQuadInstance inst = gInstances[instanceID];
        float2 corner = kQuadCorners[vertexID % 6];
        float2 px = float2(inst.x, inst.y) + corner * float2(inst.width, inst.height);

        float ndcX = (px.x / max(viewportWidth, 1.0)) * 2.0 - 1.0;
        float ndcY = 1.0 - (px.y / max(viewportHeight, 1.0)) * 2.0;

        PSInput output;
        output.position = float4(ndcX, ndcY, 0.0, 1.0);
        output.pixelPos = px;
        output.uv = lerp(float2(inst.u0, inst.v0), float2(inst.u1, inst.v1), corner);
        output.color = float4(inst.r, inst.g, inst.b, inst.a);
        output.clipRect = float4(inst.clipX, inst.clipY, inst.clipW, inst.clipH);
        output.quadBounds = float4(inst.x, inst.y, inst.width, inst.height);
        output.cornerRadius = inst.cornerRadius;
        output.kind = inst.kind;
        return output;
    }

    float4 PSMain(PSInput input) : SV_Target {
        if (PolymerOutsideClip(input.pixelPos, input.clipRect)) {
            discard;
        }
        if (input.kind == 0u) {
            float cov = PolymerRoundedRectCoverage(input.pixelPos, input.quadBounds, input.cornerRadius);
            return input.color * cov;
        }
        if (input.kind == 1u || input.kind == 3u) {
            float cov = gTexture.Sample(gSampler, input.uv).r;
            return input.color * cov;
        }
        if (input.kind == 2u) {
            float4 texel = gTexture.Sample(gSampler, input.uv);
            float4 premul = float4(texel.rgb * texel.a, texel.a);
            float cov = PolymerRoundedRectCoverage(input.pixelPos, input.quadBounds, input.cornerRadius);
            return premul * (input.color.a * cov);
        }
        return gTexture.Sample(gSampler, input.uv) * input.color.a;
    }
    """

    /// Validates that Swift `GPUShaderUniforms` and `GPUQuadInstance` memory layouts
    /// match the tightly-packed 4-byte-aligned structs declared in MSL and HLSL.
    public static func validateLayouts() -> Bool {
        guard MemoryLayout<GPUShaderUniforms>.size == 16,
              MemoryLayout<GPUShaderUniforms>.stride == 16,
              MemoryLayout<GPUShaderUniforms>.stride % 16 == 0,
              MemoryLayout<GPUShaderUniforms>.offset(of: \.viewportWidth) == 0,
              MemoryLayout<GPUShaderUniforms>.offset(of: \.viewportHeight) == 4,
              MemoryLayout<GPUShaderUniforms>.offset(of: \.scale) == 8,
              MemoryLayout<GPUShaderUniforms>.offset(of: \.time) == 12 else {
            return false
        }

        guard MemoryLayout<GPUQuadInstance>.size == 76,
              MemoryLayout<GPUQuadInstance>.stride == 76,
              MemoryLayout<GPUQuadInstance>.alignment == 4,
              MemoryLayout<GPUQuadInstance>.offset(of: \.kind) == 0,
              MemoryLayout<GPUQuadInstance>.offset(of: \.x) == 4,
              MemoryLayout<GPUQuadInstance>.offset(of: \.y) == 8,
              MemoryLayout<GPUQuadInstance>.offset(of: \.width) == 12,
              MemoryLayout<GPUQuadInstance>.offset(of: \.height) == 16,
              MemoryLayout<GPUQuadInstance>.offset(of: \.u0) == 20,
              MemoryLayout<GPUQuadInstance>.offset(of: \.v0) == 24,
              MemoryLayout<GPUQuadInstance>.offset(of: \.u1) == 28,
              MemoryLayout<GPUQuadInstance>.offset(of: \.v1) == 32,
              MemoryLayout<GPUQuadInstance>.offset(of: \.r) == 36,
              MemoryLayout<GPUQuadInstance>.offset(of: \.g) == 40,
              MemoryLayout<GPUQuadInstance>.offset(of: \.b) == 44,
              MemoryLayout<GPUQuadInstance>.offset(of: \.a) == 48,
              MemoryLayout<GPUQuadInstance>.offset(of: \.clipX) == 52,
              MemoryLayout<GPUQuadInstance>.offset(of: \.clipY) == 56,
              MemoryLayout<GPUQuadInstance>.offset(of: \.clipW) == 60,
              MemoryLayout<GPUQuadInstance>.offset(of: \.clipH) == 64,
              MemoryLayout<GPUQuadInstance>.offset(of: \.cornerRadius) == 68,
              MemoryLayout<GPUQuadInstance>.offset(of: \.blurRadius) == 72 else {
            return false
        }

        let requiredMSL = [
            "#include <metal_stdlib>",
            "struct GPUShaderUniforms",
            "struct GPUQuadInstance",
            "quadVertex",
            "solidRectFragment",
            "glyphFragment",
            "imageFragment",
            "pathCoverageFragment",
            "backdropBlurFragment",
        ]
        for token in requiredMSL where !metalMSL.contains(token) {
            return false
        }

        let requiredHLSL = [
            "cbuffer GPUShaderUniforms",
            "struct GPUQuadInstance",
            "VSMain",
            "PSMain",
            "SV_VertexID",
            "SV_InstanceID",
        ]
        for token in requiredHLSL where !d3d12HLSL.contains(token) {
            return false
        }

        return true
    }
}

// MARK: - Software GPU Rasterizer

/// Reference software implementation of Polymer's instanced GPU quad pipeline.
/// Executes a `CompiledFrame` directly against `GlyphAtlas`, optional `pathAtlas`,
/// and bound RGBA image textures into a `PolymerRender.Bitmap` for deterministic
/// pixel-parity verification against CPU `PolymerRender.Canvas`.
public enum SoftwareGPURasterizer {
    private struct MaskSource {
        var width: Int
        var height: Int
        var pixels: [UInt8]
    }

    private struct RGBASource {
        var width: Int
        var height: Int
        var pixels: [UInt8]
    }

    public static func rasterize(
        frame: CompiledFrame,
        glyphAtlas: GlyphAtlas,
        pathAtlas: GlyphAtlasPage? = nil,
        images: [UInt64: Bitmap] = [:],
        device: RecordingGPUDevice? = nil,
        background: Color = .clear
    ) -> Bitmap {
        let w = frame.width
        let h = frame.height
        guard w > 0 && h > 0 else { return Bitmap(width: 0, height: 0) }

        let bgA = Float(background.opacity)
        let bgR = Float(background.red) * bgA
        let bgG = Float(background.green) * bgA
        let bgB = Float(background.blue) * bgA

        var fb = [Float](repeating: 0, count: w * h * 4)
        if bgA > 0 {
            for i in stride(from: 0, to: fb.count, by: 4) {
                fb[i] = bgR
                fb[i + 1] = bgG
                fb[i + 2] = bgB
                fb[i + 3] = bgA
            }
        }

        @inline(__always)
        func blendPremultiplied(_ idx: Int, _ r: Float, _ g: Float, _ b: Float, _ a: Float) {
            guard a > 0 else { return }
            let k = 1.0 - a
            fb[idx] = r + fb[idx] * k
            fb[idx + 1] = g + fb[idx + 1] * k
            fb[idx + 2] = b + fb[idx + 2] * k
            fb[idx + 3] = a + fb[idx + 3] * k
        }

        func resolveMask(textureID: UInt64, isPath: Bool) -> MaskSource? {
            if let devTex = device?.textures[textureID], devTex.format == .r8Unorm {
                return MaskSource(width: devTex.width, height: devTex.height, pixels: devTex.pixels)
            }
            if isPath, let pathAtlas {
                if pathAtlas.texture?.id == textureID || textureID == 9_000 {
                    return MaskSource(width: pathAtlas.width, height: pathAtlas.height, pixels: pathAtlas.pixels)
                }
            }
            for page in glyphAtlas.pages {
                if page.texture?.id == textureID {
                    return MaskSource(width: page.width, height: page.height, pixels: page.pixels)
                }
            }
            if textureID >= 1_000 {
                let pageIdx = Int(textureID - 1_000)
                if pageIdx >= 0 && pageIdx < glyphAtlas.pages.count {
                    let p = glyphAtlas.pages[pageIdx]
                    return MaskSource(width: p.width, height: p.height, pixels: p.pixels)
                }
            }
            if let pathAtlas, textureID == 9_000 {
                return MaskSource(width: pathAtlas.width, height: pathAtlas.height, pixels: pathAtlas.pixels)
            }
            return nil
        }

        func resolveRGBA(textureID: UInt64) -> RGBASource? {
            if let bmp = images[textureID] {
                return RGBASource(width: bmp.width, height: bmp.height, pixels: bmp.pixels)
            }
            if let devTex = device?.textures[textureID], devTex.format == .rgba8Unorm {
                return RGBASource(width: devTex.width, height: devTex.height, pixels: devTex.pixels)
            }
            return nil
        }

        for batch in frame.batches {
            let sx0 = max(0, batch.scissor.x)
            let sy0 = max(0, batch.scissor.y)
            let sx1 = min(w, batch.scissor.x + batch.scissor.width)
            let sy1 = min(h, batch.scissor.y + batch.scissor.height)
            guard sx0 < sx1 && sy0 < sy1 else { continue }

            let batchMask: MaskSource?
            let batchImage: RGBASource?
            switch batch.kind {
            case .glyph:
                batchMask = resolveMask(textureID: batch.textureID, isPath: false)
                batchImage = nil
            case .pathCoverage:
                batchMask = resolveMask(textureID: batch.textureID, isPath: true)
                batchImage = nil
            case .image:
                batchMask = nil
                batchImage = resolveRGBA(textureID: batch.textureID)
            case .solidRect, .backdropBlur:
                batchMask = nil
                batchImage = nil
            }

            for inst in batch.instances {
                let icx0 = max(sx0, Int(Double(inst.clipX).rounded(.down)))
                let icy0 = max(sy0, Int(Double(inst.clipY).rounded(.down)))
                let icx1 = min(sx1, Int(Double(inst.clipX + inst.clipW).rounded(.up)))
                let icy1 = min(sy1, Int(Double(inst.clipY + inst.clipH).rounded(.up)))
                guard icx0 < icx1 && icy0 < icy1 else { continue }

                let x0 = Double(inst.x)
                let y0 = Double(inst.y)
                let x1 = x0 + Double(inst.width)
                let y1 = y0 + Double(inst.height)
                let dw = x1 - x0
                let dh = y1 - y0
                guard dw > 0 && dh > 0 else { continue }

                let ix0 = max(icx0, Int(x0.rounded(.down)))
                let iy0 = max(icy0, Int(y0.rounded(.down)))
                let ix1 = min(icx1, Int(x1.rounded(.up)))
                let iy1 = min(icy1, Int(y1.rounded(.up)))
                guard ix0 < ix1 && iy0 < iy1 else { continue }

                switch inst.kind {
                case .solidRect:
                    let cr = Double(inst.cornerRadius)
                    for py in iy0..<iy1 {
                        let cy = min(Double(py + 1), y1) - max(Double(py), y0)
                        for px in ix0..<ix1 {
                            let cx = min(Double(px + 1), x1) - max(Double(px), x0)
                            var cov = Float(cx * cy)
                            if cr > 0 {
                                cov *= roundedRectCoverage(px: Double(px) + 0.5, py: Double(py) + 0.5, x0: x0, y0: y0, w: dw, h: dh, r: cr)
                            }
                            if cov > 0 {
                                blendPremultiplied((py * w + px) * 4, inst.r * cov, inst.g * cov, inst.b * cov, inst.a * cov)
                            }
                        }
                    }

                case .glyph, .pathCoverage:
                    guard let mask = batchMask else { continue }
                    let uMin = Double(inst.u0) * Double(mask.width)
                    let vMin = Double(inst.v0) * Double(mask.height)
                    let uSpan = Double(inst.u1 - inst.u0) * Double(mask.width)
                    let vSpan = Double(inst.v1 - inst.v0) * Double(mask.height)
                    let rectMinX = Int(uMin.rounded())
                    let rectMinY = Int(vMin.rounded())
                    let rectMaxX = max(rectMinX, Int((uMin + uSpan).rounded()) - 1)
                    let rectMaxY = max(rectMinY, Int((vMin + vSpan).rounded()) - 1)
                    let inv255: Float = 1.0 / 255.0

                    @inline(__always)
                    func sampleMaskTexel(_ tx: Int, _ ty: Int) -> Float {
                        guard tx >= rectMinX && tx <= rectMaxX && ty >= rectMinY && ty <= rectMaxY,
                              tx >= 0 && tx < mask.width && ty >= 0 && ty < mask.height else {
                            return 0.0
                        }
                        return Float(mask.pixels[ty * mask.width + tx]) * inv255
                    }

                    for py in iy0..<iy1 {
                        let ay = vMin + ((Double(py) + 0.5 - y0) / dh) * vSpan
                        let fy = ay - 0.5
                        let yA = Int(fy.rounded(.down))
                        let ty = Float(fy - Double(yA))
                        for px in ix0..<ix1 {
                            let ax = uMin + ((Double(px) + 0.5 - x0) / dw) * uSpan
                            let fx = ax - 0.5
                            let xA = Int(fx.rounded(.down))
                            let tx = Float(fx - Double(xA))
                            let c00 = sampleMaskTexel(xA, yA)
                            let c10 = sampleMaskTexel(xA + 1, yA)
                            let c01 = sampleMaskTexel(xA, yA + 1)
                            let c11 = sampleMaskTexel(xA + 1, yA + 1)
                            let cov = c00 * (1 - tx) * (1 - ty)
                                + c10 * tx * (1 - ty)
                                + c01 * (1 - tx) * ty
                                + c11 * tx * ty
                            if cov > 0 {
                                blendPremultiplied((py * w + px) * 4, inst.r * cov, inst.g * cov, inst.b * cov, inst.a * cov)
                            }
                        }
                    }

                case .image:
                    guard let img = batchImage, img.width > 0, img.height > 0 else { continue }
                    let sw = img.width
                    let sh = img.height
                    let uMin = Double(inst.u0) * Double(sw)
                    let vMin = Double(inst.v0) * Double(sh)
                    let uSpan = Double(inst.u1 - inst.u0) * Double(sw)
                    let vSpan = Double(inst.v1 - inst.v0) * Double(sh)
                    let inv255: Float = 1.0 / 255.0
                    let op = inst.a

                    @inline(__always)
                    func samplePremul(_ sx: Int, _ sy: Int) -> (Float, Float, Float, Float) {
                        let cx = min(max(sx, 0), sw - 1)
                        let cy = min(max(sy, 0), sh - 1)
                        let o = (cy * sw + cx) * 4
                        let a = Float(img.pixels[o + 3]) * inv255
                        return (
                            Float(img.pixels[o]) * inv255 * a,
                            Float(img.pixels[o + 1]) * inv255 * a,
                            Float(img.pixels[o + 2]) * inv255 * a,
                            a
                        )
                    }

                    for py in iy0..<iy1 {
                        let cy = min(Double(py + 1), y1) - max(Double(py), y0)
                        let v = vMin + ((Double(py) + 0.5 - y0) / dh) * vSpan
                        let fy = v - 0.5
                        let yA = Int(fy.rounded(.down))
                        let ty = Float(fy - Double(yA))
                        for px in ix0..<ix1 {
                            let cx = min(Double(px + 1), x1) - max(Double(px), x0)
                            let cov = Float(cx * cy) * op
                            guard cov > 0 else { continue }
                            let u = uMin + ((Double(px) + 0.5 - x0) / dw) * uSpan
                            let fx = u - 0.5
                            let xA = Int(fx.rounded(.down))
                            let tx = Float(fx - Double(xA))
                            let p00 = samplePremul(xA, yA)
                            let p10 = samplePremul(xA + 1, yA)
                            let p01 = samplePremul(xA, yA + 1)
                            let p11 = samplePremul(xA + 1, yA + 1)
                            let w00 = (1 - tx) * (1 - ty)
                            let w10 = tx * (1 - ty)
                            let w01 = (1 - tx) * ty
                            let w11 = tx * ty
                            let r = p00.0 * w00 + p10.0 * w10 + p01.0 * w01 + p11.0 * w11
                            let g = p00.1 * w00 + p10.1 * w10 + p01.1 * w01 + p11.1 * w11
                            let b = p00.2 * w00 + p10.2 * w10 + p01.2 * w01 + p11.2 * w11
                            let a = p00.3 * w00 + p10.3 * w10 + p01.3 * w01 + p11.3 * w11
                            blendPremultiplied((py * w + px) * 4, r * cov, g * cov, b * cov, a * cov)
                        }
                    }

                case .backdropBlur:
                    let sigma = Double(inst.blurRadius)
                    guard sigma > 0 else { continue }
                    applyBackdropBlur(fb: &fb, width: w, box: PixelRect(x: ix0, y: iy0, width: ix1 - ix0, height: iy1 - iy0), sigma: sigma)
                }
            }
        }

        // Convert premultiplied sRGB float buffer to straight-alpha 8-bit Bitmap (identical to Canvas.bitmap).
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: fb.count, by: 4) {
            let a = fb[i + 3]
            let inv: Float = a > 0 ? 1.0 / a : 0.0
            for c in 0..<3 {
                out[i + c] = UInt8(min(max(fb[i + c] * inv * 255.0 + 0.5, 0.0), 255.0))
            }
            out[i + 3] = UInt8(min(max(a * 255.0 + 0.5, 0.0), 255.0))
        }
        return Bitmap(width: w, height: h, pixels: out)
    }

    private static func roundedRectCoverage(px: Double, py: Double, x0: Double, y0: Double, w: Double, h: Double, r: Double) -> Float {
        let halfW = w * 0.5
        let halfH = h * 0.5
        let rad = min(r, min(halfW, halfH))
        let cx = x0 + halfW
        let cy = y0 + halfH
        let qx = abs(px - cx) - (halfW - rad)
        let qy = abs(py - cy) - (halfH - rad)
        let ox = max(qx, 0.0)
        let oy = max(qy, 0.0)
        let dist = (ox * ox + oy * oy).squareRoot() + min(max(qx, qy), 0.0) - rad
        return Float(min(max(0.5 - dist, 0.0), 1.0))
    }

    private static func applyBackdropBlur(fb: inout [Float], width: Int, box: PixelRect, sigma: Double) {
        guard !box.isEmpty, sigma > 0 else { return }
        let wIdeal = ((12.0 * sigma * sigma / 3.0) + 1.0).squareRoot()
        var wl = Int(wIdeal.rounded(.down))
        if wl % 2 == 0 { wl = max(1, wl - 1) }
        let wu = wl + 2
        let mIdeal = (12.0 * sigma * sigma - 3.0 * Double(wl * wl) - 12.0 * Double(wl) - 9.0) / (-4.0 * Double(wl) - 4.0)
        let m = Int(mIdeal.rounded())
        let rl = max(0, (wl - 1) / 2)
        let ru = max(0, (wu - 1) / 2)
        let radii = [0 < m ? rl : ru, 1 < m ? rl : ru, 2 < m ? rl : ru]

        let bw = box.width
        let bh = box.height
        var bufA = [Float](repeating: 0, count: bw * bh * 4)
        var bufB = [Float](repeating: 0, count: bw * bh * 4)
        for y in 0..<bh {
            let srcRow = ((box.y + y) * width + box.x) * 4
            let dstRow = y * bw * 4
            for i in 0..<(bw * 4) { bufA[dstRow + i] = fb[srcRow + i] }
        }
        for r in radii where r > 0 {
            let inv = Float(1.0) / Float(2 * r + 1)
            for y in 0..<bh {
                let row = y * bw * 4
                for x in 0..<bw {
                    var a0: Float = 0, a1: Float = 0, a2: Float = 0, a3: Float = 0
                    for d in -r...r {
                        let sx = min(max(x + d, 0), bw - 1)
                        let o = row + sx * 4
                        a0 += bufA[o]; a1 += bufA[o + 1]; a2 += bufA[o + 2]; a3 += bufA[o + 3]
                    }
                    let o = row + x * 4
                    bufB[o] = a0 * inv; bufB[o + 1] = a1 * inv; bufB[o + 2] = a2 * inv; bufB[o + 3] = a3 * inv
                }
            }
            for x in 0..<bw {
                for y in 0..<bh {
                    var a0: Float = 0, a1: Float = 0, a2: Float = 0, a3: Float = 0
                    for d in -r...r {
                        let sy = min(max(y + d, 0), bh - 1)
                        let o = (sy * bw + x) * 4
                        a0 += bufB[o]; a1 += bufB[o + 1]; a2 += bufB[o + 2]; a3 += bufB[o + 3]
                    }
                    let o = (y * bw + x) * 4
                    bufA[o] = a0 * inv; bufA[o + 1] = a1 * inv; bufA[o + 2] = a2 * inv; bufA[o + 3] = a3 * inv
                }
            }
        }
        for y in 0..<bh {
            let dstRow = ((box.y + y) * width + box.x) * 4
            let srcRow = y * bw * 4
            for i in 0..<(bw * 4) { fb[dstRow + i] = bufA[srcRow + i] }
        }
    }
}
