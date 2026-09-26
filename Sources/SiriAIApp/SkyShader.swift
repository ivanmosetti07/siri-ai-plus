/// Shader Metal del cielo della Home, compilato a runtime (`MTLDevice.makeLibrary(source:)`).
/// Strati: gradiente del cielo → stelle e stelle cadenti → sole o luna → tre strati di nuvole con parallasse →
/// nebbia → pioggia su tre profondità → neve → lampi → gocce sul vetro.
enum SkyShader {
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct SkyUniforms {
        float4 frame;      // larghezza, altezza, tempo (s), messa a fuoco 0…1
        float4 weather;    // nuvole, pioggia, neve, nebbia
        float4 light;      // temporale, luce del giorno, crepuscolo, scorrimento
        float4 skyTop;
        float4 skyBottom;
        float4 body;       // sole o luna: posizione (0…1), sole visibile, luna visibile
        float4 cloud;      // colore delle nuvole
    };

    struct SkyVertex {
        float4 position [[position]];
        float2 uv;
    };

    vertex SkyVertex skyVertex(uint vid [[vertex_id]]) {
        const float2 corners[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        SkyVertex out;
        out.position = float4(corners[vid], 0.0, 1.0);
        out.uv = float2(corners[vid].x * 0.5 + 0.5, 0.5 - corners[vid].y * 0.5);
        return out;
    }

    // smoothstep che accetta anche i bordi invertiti.
    inline float ss(float a, float b, float x) {
        float t = clamp((x - a) / (b - a), 0.0, 1.0);
        return t * t * (3.0 - 2.0 * t);
    }

    inline float hash21(float2 p) {
        p = fract(p * float2(233.34, 851.73));
        p += dot(p, p + 23.45);
        return fract(p.x * p.y);
    }

    inline float noise(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        float a = hash21(i);
        float b = hash21(i + float2(1.0, 0.0));
        float c = hash21(i + float2(0.0, 1.0));
        float d = hash21(i + float2(1.0, 1.0));
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }

    inline float fbm(float2 p, int octaves) {
        float value = 0.0;
        float amplitude = 0.5;
        const float2x2 turn = float2x2(1.6, 1.2, -1.2, 1.6);
        for (int i = 0; i < octaves; i++) {
            value += amplitude * noise(p);
            p = turn * p + float2(3.1, 1.7);
            amplitude *= 0.5;
        }
        return value;
    }

    inline float cloudShape(float2 q, float coverage, int octaves, float softness) {
        float2 warp = float2(fbm(q * 0.5 + float2(1.7, 9.2), 2), fbm(q * 0.5 + float2(8.3, 2.8), 2));
        float n = fbm(q + (warp - 0.5) * 1.3, octaves);
        float low = mix(0.62, 0.27, coverage);
        float high = low + mix(0.17, 0.30, coverage) + softness;
        return ss(low, high, n);
    }

    inline float stars(float2 p, float time) {
        float2 st = p * 110.0;
        float2 id = floor(st);
        float h = hash21(id);
        if (h < 0.972) { return 0.0; }
        float2 f = fract(st) - 0.5;
        float2 offset = float2(hash21(id + 1.3), hash21(id + 4.7)) - 0.5;
        float d = length(f - offset * 0.6);
        float twinkle = 0.6 + 0.4 * sin(time * (0.7 + h * 3.0) + h * 91.0);
        float brightness = (h - 0.972) / 0.028;
        float size = mix(0.2, 0.42, brightness * brightness);
        float core = ss(size, 0.0, d);
        return core * core * twinkle * (0.55 + 0.9 * brightness);
    }

    inline float shootingStar(float2 p, float time, float aspect) {
        float period = 11.0;
        float cycle = floor(time / period);
        float h = hash21(float2(cycle, 4.2));
        float t = (time - cycle * period - h * 6.0) / 0.9;
        if (h < 0.45 || t < 0.0 || t > 1.0) { return 0.0; }
        float2 start = float2((0.35 + 0.55 * hash21(float2(cycle, 1.3))) * aspect, 0.04 + 0.22 * hash21(float2(cycle, 2.9)));
        float2 dir = normalize(float2(-0.85, 0.42));
        float2 head = start + dir * t * 0.5;
        float2 rel = p - head;
        float behind = dot(rel, -dir);
        float across = abs(dot(rel, float2(-dir.y, dir.x)));
        float trail = ss(0.2, 0.0, behind) * step(0.0, behind) * ss(0.003, 0.0, across);
        return trail * sin(t * 3.14159);
    }

    inline float rainLayer(float2 p, float time, float scale, float speed, float amount, float width) {
        float2 st = float2((p.x + p.y * 0.18) * scale, p.y * scale * 0.2);
        st.y -= time * speed * scale * 0.2;
        float2 id = floor(st);
        float2 f = fract(st);
        float h = hash21(id);
        if (h > amount) { return 0.0; }
        float x = 0.15 + 0.7 * hash21(id + 13.7);
        float head = hash21(id + 5.3);
        float len = 0.3 + 0.45 * hash21(id + 2.1);
        float along = fract(f.y - head + 1.0);
        float line = ss(width, 0.0, abs(f.x - x));
        return line * ss(0.0, 0.12, along) * ss(len, len * 0.5, along);
    }

    inline float snowLayer(float2 p, float time, float scale, float speed, float size) {
        float2 st = p * scale;
        st.y -= time * speed * scale;
        float column = floor(st.x);
        st.x += sin(st.y * 0.9 + hash21(float2(column, 1.0)) * 6.28 + time * 0.8) * 0.2;
        float2 id = floor(st);
        float2 f = fract(st) - 0.5;
        float h = hash21(id);
        if (h < 0.3) { return 0.0; }
        float2 offset = float2(hash21(id + 3.7), hash21(id + 9.1)) - 0.5;
        float d = length(f - offset * 0.4);
        float radius = size * scale * (0.6 + 0.8 * hash21(id + 1.9));
        return ss(radius, radius * 0.3, d);
    }

    inline float lightning(float time) {
        float period = 6.0;
        float cycle = floor(time / period);
        float h = hash21(float2(cycle, 7.3));
        float t = time - cycle * period - h * 4.5;
        if (h < 0.25 || t < 0.0 || t > 1.0) { return 0.0; }
        return exp(-t * 9.0) + 0.75 * exp(-abs(t - 0.22) * 26.0);
    }

    // Gocce ferme sul vetro: una lente un po' più chiara, un bordo scuro e un riflesso.
    inline float3 glassDrops(float2 p, float amount, float3 col) {
        float2 st = p * 9.0;
        float2 id = floor(st);
        float2 f = fract(st) - 0.5;
        float h = hash21(id + 31.0);
        if (h > amount * 0.35) { return col; }
        float2 center = (float2(hash21(id + 1.0), hash21(id + 2.0)) - 0.5) * 0.5;
        float r = 0.06 + 0.12 * hash21(id + 3.0);
        float2 rel = (f - center) * float2(1.0, 0.85);
        float d = length(rel);
        float inside = ss(r, r * 0.8, d);
        // La goccia fa da lente: in alto più chiara (riflette il cielo), in basso un'ombra sottile.
        float lens = inside * (0.5 - rel.y / r * 0.5);
        float shade = ss(r * 1.08, r * 0.92, d) * ss(-0.2 * r, r, rel.y);
        float spark = ss(r * 0.22, 0.0, length(rel - float2(-r * 0.3, -r * 0.42)));
        col = mix(col, col * 1.06 + 0.02, lens);
        col -= shade * 0.05;
        col += spark * 0.14;
        return col;
    }

    fragment float4 skyFragment(SkyVertex in [[stage_in]], constant SkyUniforms &u [[buffer(0)]]) {
        float2 res = max(u.frame.xy, float2(1.0));
        float time = u.frame.z;
        float focus = clamp(u.frame.w, 0.0, 1.0);
        float clouds = u.weather.x, rain = u.weather.y, snow = u.weather.z, fog = u.weather.w;
        float thunder = u.light.x, daylight = u.light.y, twilight = u.light.z, scroll = u.light.w;
        float aspect = res.x / res.y;

        // Apertura: il cielo parte più vicino, scuro e morbido, poi si mette a fuoco.
        float2 uv = (in.uv - 0.5) / mix(1.16, 1.0, focus) + 0.5;
        float2 p = float2(uv.x * aspect, uv.y);

        float3 col = mix(u.skyTop.rgb, u.skyBottom.rgb, ss(-0.05, 1.05, uv.y));
        col += float3(1.0, 0.52, 0.32) * twilight * 0.22 * ss(0.45, 1.1, uv.y) * (1.0 - clouds * 0.6);

        // Stelle
        float night = 1.0 - daylight;
        if (night > 0.01) {
            float mask = night * night * (1.0 - ss(0.35, 0.85, clouds)) * (1.0 - ss(0.5, 0.95, uv.y)) * focus;
            float2 sp = p + float2(0.0, scroll * 0.03);
            col += float3(0.9, 0.93, 1.0) * stars(sp, time) * mask;
            col += float3(1.0) * shootingStar(sp, time, aspect) * mask;
        }

        // Sole o luna
        float2 body = float2(u.body.x * aspect, u.body.y + scroll * 0.05);
        float dist = length(p - body);
        float sunVisible = u.body.z, moonVisible = u.body.w;
        if (sunVisible > 0.001) {
            float3 sunColor = mix(float3(1.0, 0.95, 0.83), float3(1.0, 0.63, 0.38), twilight);
            float glow = exp(-dist * 3.6) * 0.42 + exp(-dist * dist * 320.0) * 0.75;
            float disc = ss(0.034, 0.029, dist);
            float angle = atan2(p.y - body.y, p.x - body.x);
            float rays = (0.5 + 0.5 * sin(angle * 6.0 + time * 0.05)) * (0.5 + 0.5 * sin(angle * 9.0 - time * 0.035)) * exp(-dist * 3.2) * 0.1;
            col += sunColor * (glow + disc + rays) * sunVisible;
        }
        if (moonVisible > 0.001) {
            float disc = ss(0.036, 0.031, dist);
            float shadow = ss(0.034, 0.029, length(p - body - float2(0.015, -0.009)));
            float glow = exp(-dist * 7.0) * 0.22;
            col += (float3(0.93, 0.94, 1.0) * disc * (1.0 - shadow * 0.92) + float3(0.55, 0.65, 0.95) * glow) * moonVisible;
        }

        // Nuvole: tre strati, dai lontani ai vicini; si muovono a velocità diverse e seguono lo scorrimento.
        float cover = 0.0;
        if (clouds > 0.02) {
            int octaves = focus > 0.7 ? 5 : 3;
            float softness = (1.0 - focus) * 0.3;
            float2 toSun = normalize(body - float2(aspect * 0.5, 0.75));
            for (int layer = 0; layer < 3; layer++) {
                float fl = float(layer);
                float scale = 2.9 - fl * 0.75;
                float speed = 0.012 + fl * 0.01;
                float2 q = p * scale + float2(time * speed + fl * 11.3, (scroll * (0.12 + fl * 0.1) + fl * 5.1) * scale);
                float band = mix(ss(0.92 - fl * 0.1, 0.18, uv.y), 1.0, ss(0.72, 1.0, clouds));
                float density = cloudShape(q, clouds, octaves, softness) * band;
                float lit = cloudShape(q + toSun * 0.2, clouds, 3, softness) * band;
                // Cielo coperto: luce diffusa, meno contrasto tra lato illuminato e lato in ombra.
                float light = clamp(0.62 + (density - lit) * mix(1.8, 0.7, ss(0.6, 1.0, clouds)), 0.0, 1.0);
                float3 cloudColor = mix(u.cloud.rgb * 0.7, u.cloud.rgb * 1.07, light);
                cloudColor += float3(1.0, 0.9, 0.75) * sunVisible * exp(-dist * 3.0) * (1.0 - density) * 0.55;
                float alpha = density * mix(0.5, 0.94, fl * 0.5);
                col = mix(col, cloudColor, alpha);
                cover = max(cover, alpha);
            }
        }

        // Nebbia
        if (fog > 0.001) {
            float n = fbm(float2(p.x * 1.1 + time * 0.02, p.y * 2.6 - time * 0.006), 4);
            float bands = ss(0.35, 0.75, n) * ss(0.05, 0.85, uv.y);
            float3 fogColor = mix(float3(0.55, 0.59, 0.66), float3(0.86, 0.88, 0.9), daylight);
            col = mix(col, fogColor, clamp(fog * (0.22 + bands * 0.62), 0.0, 0.88));
        }

        // Pioggia
        if (rain > 0.001) {
            float r = 0.0;
            r += rainLayer(p, time, 24.0, 1.8, rain * 0.5, 0.055) * 0.6;
            r += rainLayer(p + float2(0.37, 0.0), time, 40.0, 1.3, rain * 0.55, 0.045) * 0.38;
            r += rainLayer(p + float2(0.71, 0.0), time, 64.0, 0.9, rain * 0.65, 0.04) * 0.22;
            col = mix(col, float3(0.82, 0.86, 0.92), clamp(r, 0.0, 1.0) * mix(0.5, 0.8, daylight));
            col *= 1.0 - rain * 0.06;
        }

        // Neve
        if (snow > 0.001) {
            float s = 0.0;
            s += snowLayer(p, time, 8.0, 0.09, 0.0065) * 0.95;
            s += snowLayer(p + 3.1, time, 14.0, 0.065, 0.0048) * 0.7;
            s += snowLayer(p + 7.7, time, 24.0, 0.045, 0.0032) * 0.45;
            col = mix(col, float3(0.97, 0.98, 1.0), clamp(s * snow, 0.0, 1.0));
        }

        // Lampi
        if (thunder > 0.001) {
            float flash = lightning(time) * thunder;
            col += float3(0.78, 0.82, 1.0) * flash * (0.2 + 0.8 * cover) * 0.85;
        }

        // Gocce sul vetro
        if (rain > 0.05) {
            col = glassDrops(float2(in.uv.x * aspect, in.uv.y), rain, col);
        }

        col *= mix(0.5, 1.0, focus);
        float2 v = in.uv - 0.5;
        col *= 1.0 - dot(v, v) * 0.2;
        col += (hash21(in.position.xy + fract(time)) - 0.5) / 255.0;
        return float4(clamp(col, 0.0, 1.0), 1.0);
    }
    """#
}
