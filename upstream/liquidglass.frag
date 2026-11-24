#version 440
// Liquid Glass shader for gokko-custom (macOS Tahoe / iOS 26 style optics).
//
// Build:  qsb --qt6 -o liquidglass.frag.qsb liquidglass.frag

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 itemSize;      // whole shader item in px (glass + pad on every side)
    vec2 glassSize;     // the glass rectangle in px
    vec2 srcSize;       // backdrop texture size in px
    vec2 srcOffset;     // where the item's top-left sits inside the backdrop texture, px
    float pad;          // item padding around the glass (room for the drop shadow)
    float radius;       // corner radius, px
    float bezel;        // width of the refracting rim, px
    float thickness;    // how far the rim shifts the backdrop, px
    float dispersion;   // chromatic split (0 = none)
    float blurPx;       // interior backdrop blur radius, px
    float tintMix;      // 0..1 amount of tint (the "translucency" slider)
    float saturation;   // backdrop saturation boost
    float dark;         // 0 = light mode, 1 = dark mode
    float debug;        // 1 = show the raw backdrop texture (magenta = texture is empty)
    float rim;          // specular edge highlight strength
    float grain;        // fine noise amplitude over the whole glass
    float magnify;      // lens magnification of the glass slab
    float shadowAmt;    // drop-shadow strength (1 = default, 0 = none)
    float rimTint;      // 0 = crisp ice-white rim, 1 = tint rim toward local refracted glass
    float ringW;        // optional extra edge border width (px)
    float flatInner;    // kept for uniform layout compatibility
};

layout(binding = 1) uniform sampler2D src;

const int   TAPS   = 24;
const float GOLDEN = 2.39996323;

vec3 backdropLod(vec2 pItem, float lod)
{
    vec2 uv = (pItem + srcOffset) / srcSize;
    return textureLod(src, clamp(uv, vec2(0.001), vec2(0.999)), lod).rgb;
}

float ign(vec2 p)
{
    return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

vec3 blurredDisp(vec2 pItem, vec2 disp, float disperse, float rad)
{
    float R   = max(rad, 0.4) * 1.25;
    float gap = R * sqrt(3.14159265 / float(TAPS));
    float lod = clamp(log2(max(gap, 1.0)) + 0.15, 0.0, 3.5);
    float rot = ign(gl_FragCoord.xy) * 6.2831853;
    vec3  acc = vec3(0.0);
    float wsum = 0.0;
    for (int i = 0; i < TAPS; ++i) {
        float fi = float(i) + 0.5;
        float r  = sqrt(fi / float(TAPS));
        float a  = fi * GOLDEN + rot;
        float w  = exp(-2.4 * r * r);
        vec2  o  = vec2(cos(a), sin(a)) * r * R;
        vec3  c;
        if (disperse > 1e-4) {
            c.r = backdropLod(pItem + o + disp * (1.0 + disperse), lod).r;
            c.g = backdropLod(pItem + o + disp,                    lod).g;
            c.b = backdropLod(pItem + o + disp * (1.0 - disperse), lod).b;
        } else {
            c = backdropLod(pItem + o + disp, lod);
        }
        acc  += c * w;
        wsum += w;
    }
    return acc / wsum;
}

float hash12(vec2 p)
{
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float roundBox(vec2 q, vec2 hs, float r)
{
    vec2 d = abs(q) - (hs - r);
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}

void main()
{
    vec2 p  = qt_TexCoord0 * itemSize;
    vec2 hs = glassSize * 0.5;
    vec2 q  = p - vec2(pad) - hs;
    float r = min(radius, min(hs.x, hs.y));

    float sd  = roundBox(q, hs, r);               // < 0 inside the glass
    float cov = clamp(0.5 - sd, 0.0, 1.0);        // anti-aliased coverage

    if (debug > 0.5) {
        vec4 s = texture(src, clamp((p + srcOffset) / srcSize, vec2(0.001), vec2(0.999)));
        fragColor = (s.a < 0.01 ? vec4(1.0, 0.0, 1.0, 1.0) : vec4(s.rgb / max(s.a, 1e-3), 1.0)) * cov * qt_Opacity;
        return;
    }

    // Two-layer Tahoe drop shadow (tight contact + soft ambient)
    float sContact = roundBox(q - vec2(0.0, 1.5), hs, r);
    float sAmbient = roundBox(q - vec2(0.0, 5.0), hs, r);
    float shadow   = shadowAmt * (
        0.22 * exp(-max(sContact, 0.0) / 3.0)
      + 0.18 * (1.0 - smoothstep(-1.0, max(pad - 0.5, 9.0), sAmbient))
    );
    if (cov <= 0.0) {
        fragColor = vec4(0.0, 0.0, 0.0, shadow) * qt_Opacity;
        return;
    }

    // Distance to edge + outward unit normal
    float t  = max(-sd, 0.0);
    vec2  d2 = abs(q) - (hs - r);
    vec2  sg = vec2(q.x >= 0.0 ? 1.0 : -1.0, q.y >= 0.0 ? 1.0 : -1.0);
    vec2  m  = max(d2, 0.0);
    vec2  g  = (length(m) > 1e-4) ? normalize(m) * sg
                                  : ((d2.x > d2.y) ? vec2(sg.x, 0.0) : vec2(0.0, sg.y));

    // Curved peripheral bezel: steep convex glass lens hugging the outer rim
    float maxBz = max(5.0, min(hs.x, hs.y) * 0.78);
    float bz    = clamp(bezel * 1.15, 8.0, maxBz);
    float u     = clamp(t / bz, 0.0, 1.0);
    float om    = 1.0 - u;
    float edgeW = om * om;
    float slope = edgeW * (1.2 + 3.2 * om);
    vec3  n     = normalize(vec3(g * slope, 1.0));

    // Strong, clean Snell refraction on the bezel + mild center lens zoom
    vec3 rd   = refract(vec3(0.0, 0.0, -1.0), n, 1.0 / 1.52);
    vec2 disp = rd.xy / max(-rd.z, 0.24) * clamp(thickness * 0.95, 0.0, 34.0);

    float lens = clamp(magnify, 0.0, 0.25) * 0.35;
    vec2  ctr  = vec2(pad) + hs;
    vec2  ps   = ctr + (p - ctr) * (1.0 - lens);

    // Crucial for Liquid Glass: keep the curved rim ultra-clear (0.6 px) so refracted
    // lines & colors visibly bend along the edge, ramping smoothly to frosted blur inside.
    float rad      = mix(0.65, max(blurPx, 2.5), smoothstep(0.08, 0.95, u));
    float disperse = dispersion * 0.75 * (om * om * om);

    vec3 col = blurredDisp(ps, disp, disperse, rad);

    // Vibrant Apple Liquid Glass color grading + luminance-adaptive translucency
    float l   = dot(col, vec3(0.2126, 0.7152, 0.0722));
    float sat = mix(saturation, 1.44, 0.55);
    col = mix(vec3(l), col, sat);

    float lw    = smoothstep(0.26, 0.80, l);
    float adapt = mix(0.75, 1.25, mix(1.0 - lw, lw, dark));
    vec3  tintC = mix(vec3(0.98, 0.99, 1.0), vec3(0.075, 0.082, 0.105), dark);
    col = mix(col, tintC, clamp(tintMix * adapt, 0.0, 0.78));
    col += mix(0.055, 0.022, dark);

    // Subtle top glossy reflection cushion inside the glass
    float ty = clamp((q.y + hs.y) / max(glassSize.y, 1.0), 0.0, 1.0);
    col += pow(max(1.0 - ty, 0.0), 2.0) * mix(0.065, 0.045, dark);

    // Signature Apple Fresnel Specular Rim (top-left bright arc + opposite corner bounce)
    vec3 ice    = vec3(0.97, 0.985, 1.0);
    vec3 localL = clamp(col * 1.65 + 0.28, 0.0, 1.0);
    vec3 rimCol = mix(ice, localL, 0.25 + 0.45 * clamp(rimTint, 0.0, 1.0));

    vec2  L      = normalize(vec2(-0.62, -0.78));
    float facing = dot(g, L);
    float hiTL   = pow(max(facing, 0.0), 1.6);
    float hiBR   = 0.55 * pow(max(-facing, 0.0), 2.4);
    float diagHi = hiTL + hiBR;

    float crisp  = 1.0 - smoothstep(0.3, 1.6, t);       // razor-crisp rim line (~1.3 px)
    float bevelG = exp(-t / 4.8);                       // soft pooled liquid glow inside bezel
    float specK  = max(rim, 0.35) * mix(1.10, 1.28, dark);

    float edgeHi = (crisp * (0.28 + 0.92 * diagHi) + bevelG * (0.06 + 0.14 * diagHi)) * specK;
    col += edgeHi * rimCol;

    // Luminous inner meniscus caustic arc hugging the optical slope
    float mx  = (t - bz * 0.36) / (bz * 0.22 + 1.0);
    float men = exp(-mx * mx);
    col += men * 0.08 * (0.30 + diagHi) * specK * rimCol;

    // 1px outer contrast micro-border so bright glass never dissolves into white backdrops
    float outerSep = (1.0 - cov) * smoothstep(0.0, 0.65, lw) * 0.22 * max(shadowAmt, 0.35);
    col *= (1.0 - outerSep * 0.65);

    if (ringW > 0.0) {
        float ring = 1.0 - smoothstep(ringW * 0.45, ringW * 0.45 + 1.0, t);
        col = mix(col, rimCol, ring * (0.45 + 0.45 * diagHi));
    } else if (ringW < 0.0) {
        float rw   = -ringW;
        float ring = 1.0 - smoothstep(rw * 0.5, rw * 0.5 + 1.0, t);
        float glow = exp(-t / (rw * 2.2)) * 0.22;
        float fall = max(r * 3.0, 26.0);
        float wTR  = pow(clamp(1.0 - length(q - vec2( hs.x, -hs.y)) / fall, 0.0, 1.0), 1.2);
        float wBL  = pow(clamp(1.0 - length(q - vec2(-hs.x,  hs.y)) / fall, 0.0, 1.0), 1.2);
        float cw   = 1.0 - max(wTR, wBL);
        vec3  ringCol = clamp(col * 1.8 + 0.22, 0.0, 1.0);
        col = mix(col, ringCol, clamp((ring + glow) * cw, 0.0, 1.0) * 0.78);
    }

    float gn = hash12(gl_FragCoord.xy) + hash12(gl_FragCoord.xy * 1.7 + 17.0) - 1.0;
    col += gn * grain;

    col = clamp(col, 0.0, 1.0);

    float a = cov + shadow * (1.0 - cov);
    fragColor = vec4(col * cov, a) * qt_Opacity;
}
