// HLSL for the Direct3D 12 backend: the CPU reference's arithmetic
// (`Canvas`, `Blur`, `Canvas.drawBackdrop`, `Canvas.drawLayer`) in shaders.
// Field meanings per program are listed with `GPUProgram`.
#if os(Windows)

let hlslSource = """
cbuffer Constants : register(b0) {
    float2 targetOrigin;   // image pixel at the target's top-left
    float2 targetSize;     // texels
    float2 sourceOrigin;   // image pixel at the source's top-left
    uint instanceBase;
    uint unused;
};

struct Instance { float4 quad; float4 color; float4 p2; float4 p3; float4 p4; float4 p5; };
StructuredBuffer<Instance> instances : register(t1);
StructuredBuffer<float4> data : register(t2);
Texture2D<float4> source : register(t0);

struct VSOut { float4 pos : SV_Position; nointerpolation uint id : INSTANCE; };

VSOut vsQuad(uint v : SV_VertexID, uint i : SV_InstanceID) {
    VSOut o;
    o.id = instanceBase + i;
    Instance it = instances[o.id];
    float2 corner = float2(v & 1, v >> 1);
    float2 p = lerp(it.quad.xy, it.quad.zw, corner) - targetOrigin;
    o.pos = float4(p / targetSize * float2(2, -2) + float2(-1, 1), 0, 1);
    return o;
}

// Image coordinates of the pixel being shaded (its top-left corner).
float2 pixel(VSOut i) { return floor(i.pos.xy) + targetOrigin; }
float4 at(float2 imagePixel) { return source.Load(int3(int2(imagePixel - sourceOrigin), 0)); }

float4 psRect(VSOut i) : SV_Target {
    Instance it = instances[i.id];
    float2 p = pixel(i);
    float cx = min(p.x + 1, it.p2.z) - max(p.x, it.p2.x);
    float cy = min(p.y + 1, it.p2.w) - max(p.y, it.p2.y);
    return it.color * (saturate(cx) * saturate(cy));
}

float4 psMask(VSOut i) : SV_Target {
    Instance it = instances[i.id];
    float2 t = pixel(i) - it.quad.xy + it.p2.xy;
    return it.color * source.Load(int3(int2(t), 0)).r;
}

float4 psImage(VSOut i) : SV_Target {
    float4 c = at(pixel(i));
    return float4(c.rgb * c.a, c.a);
}

float4 psBlur(VSOut i) : SV_Target {
    Instance it = instances[i.id];
    int2 p = int2(pixel(i));
    int2 lo = int2(it.p2.xy), hi = int2(it.p2.zw) - 1;
    int n = int(it.p3.y), first = int(it.p3.z);
    bool vertical = it.p3.x > 0.5;
    float4 s = 0;
    for (int j = 0; j <= 2 * n; j++) {
        int2 q = p;
        if (vertical) q.y = clamp(p.y + j - n, lo.y, hi.y); else q.x = clamp(p.x + j - n, lo.x, hi.x);
        int w = first + j;
        s += at(float2(q)) * data[w >> 2][w & 3];
    }
    return s;
}

// Rounded rectangles: (x, y, width, height) and corner radius.
float rrDistance(float4 r, float k, float2 p) {
    float2 h = r.zw * 0.5;
    float2 q = abs(p - (r.xy + h)) - h + k;
    return length(max(q, 0)) + min(max(q.x, q.y), 0) - k;
}

float2 rrNormal(float4 r, float k, float2 p) {
    float2 c = r.xy + r.zw * 0.5;
    float2 s = float2(p.x < c.x ? -1 : 1, p.y < c.y ? -1 : 1);
    float2 q = abs(p - c) - r.zw * 0.5 + k;
    if (q.x > 0 && q.y > 0) return s * q / length(q);
    return q.x > q.y ? float2(s.x, 0) : float2(0, s.y);
}

// The outline's signed distance: one shape (smoothing < 0) or a smooth union.
float shapeDistance(uint first, uint count, float k, float2 p) {
    float d = 0;
    for (uint s = 0; s < count; s++) {
        float e = rrDistance(data[first + 2 * s], data[first + 2 * s + 1].x, p);
        if (s == 0 || k <= 0) { d = s == 0 ? e : min(d, e); continue; }
        float h = max(k - abs(d - e), 0) / k;
        d = min(d, e) - h * h * k / 4;
    }
    return d;
}

// Bilinear sample of the blurred pixels behind, at an image-space point (pixel centres at +0.5).
float4 sampleBehind(float2 pt, float4 src) {
    float fx = clamp(pt.x - 0.5 - src.x, 0, src.z - 1), fy = clamp(pt.y - 0.5 - src.y, 0, src.w - 1);
    int x0 = int(fx), y0 = int(fy);
    int x1 = min(x0 + 1, int(src.z) - 1), y1 = min(y0 + 1, int(src.w) - 1);
    float tx = fx - x0, ty = fy - y0;
    float4 a = source.Load(int3(x0, y0, 0)), b = source.Load(int3(x1, y0, 0));
    float4 c = source.Load(int3(x0, y1, 0)), d = source.Load(int3(x1, y1, 0));
    return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty;
}

struct Blended { float4 color : SV_Target0; float4 coverage : SV_Target1; };

Blended psBackdrop(VSOut i) {
    Instance it = instances[i.id];
    float2 c = pixel(i) + 0.5;
    uint first = uint(it.p2.y), count = uint(it.p2.z);
    float k = it.p2.w;
    float d = shapeDistance(first, count, k, c);
    float cov = saturate(0.5 - d);
    float4 col;
    float highlight = 0;
    if (it.p2.x < 0.5) {
        col = at(c - 0.5);
    } else {
        float depth = max(0, -d), bezel = it.p3.y;
        float u = min(depth / bezel, 1);
        float2 n; float strength = 1;
        if (k < 0) {
            n = rrNormal(data[first], data[first + 1].x, c);
        } else {
            float h = it.p4.w;
            float gx = shapeDistance(first, count, k, c + float2(h, 0)) - shapeDistance(first, count, k, c - float2(h, 0));
            float gy = shapeDistance(first, count, k, c + float2(0, h)) - shapeDistance(first, count, k, c - float2(0, h));
            float l = sqrt(gx * gx + gy * gy);
            if (l > 1e-12) { n = float2(gx, gy) / l; strength = min(l / (2 * h), 1); strength *= strength; }
            else { n = float2(0, -1); strength = 0; }
        }
        float m = it.p3.x * (1 - u) * (1 - u) * strength;
        float disp = it.p4.z;
        float4 g = sampleBehind(c + n * m, it.p5);
        col = float4(sampleBehind(c + n * (m * (1 + disp)), it.p5).r, g.g, sampleBehind(c + n * (m * (1 - disp)), it.p5).b, g.a);
        float facing = dot(n, it.p4.xy);
        float edge = max(0, 1 - depth / max(0.5, it.p3.w));
        float lit = max(0, facing) * max(0, facing) + 0.35 * max(0, -facing) * max(0, -facing);
        highlight = it.p3.z * lit * edge;
    }
    float4 tint = it.color;
    col = tint + col * (1 - tint.a);
    if (highlight > 0) { float h = min(highlight, 1); col = h + col * (1 - h); }
    Blended o;
    o.color = col * cov;
    o.coverage = float4(0, 0, 0, cov);
    return o;
}

float4 psDownsample(VSOut i) : SV_Target {
    Instance it = instances[i.id];
    int2 g = int2(pixel(i));
    int f = int(it.p3.x);
    int2 lo = int2(it.p2.xy), hi = int2(it.p2.zw) - 1;
    float4 s = 0;
    for (int j = 0; j < f; j++) {
        for (int k = 0; k < f; k++) s += at(float2(clamp(g * f + int2(k, j), lo, hi)));
    }
    return s * (1.0 / (f * f));
}

float4 psUpsample(VSOut i) : SV_Target {
    Instance it = instances[i.id];
    float f = it.p3.x;
    float2 size = it.p2.zw - it.p2.xy;
    float2 u = clamp((pixel(i) + 0.5) / f - 0.5 - it.p2.xy, 0, size - 1);
    int2 a = int2(u), b = min(a + 1, int2(size) - 1);
    float2 t = u - a;
    float4 p = source.Load(int3(a.x, a.y, 0)), q = source.Load(int3(b.x, a.y, 0));
    float4 r = source.Load(int3(a.x, b.y, 0)), s = source.Load(int3(b.x, b.y, 0));
    return (p * (1 - t.x) + q * t.x) * (1 - t.y) + (r * (1 - t.x) + s * t.x) * t.y;
}

// A target into a window's 8-bit image, over black (the window is opaque).
float4 psPresent(VSOut i) : SV_Target {
    return float4(at(pixel(i)).rgb, 1);
}

float4 psComposite(VSOut i) : SV_Target {
    Instance it = instances[i.id];
    float2 p = pixel(i);
    float k = it.color.x;
    if (it.color.y > 0.5) k *= saturate(0.5 - rrDistance(it.p2, it.p3.x, p + 0.5));
    return at(p) * k;
}
"""

#endif
