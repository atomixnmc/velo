// Ripple: a gentle heat-haze wobble over the whole screen, used as PostProcess.shader (the last pass).
// PARAMS.x = strength in pixels, PARAMS.y = speed.
vec4 effect(vec4 color, vec2 uv) {
    vec2 px = 1.0 / TEXTURE_SIZE;
    float w = sin(uv.y * 40.0 + TIME * PARAMS.y) + sin(uv.x * 23.0 - TIME * PARAMS.y * 0.7);
    return texel(uv + vec2(w, -w) * px * PARAMS.x * 0.5) * color;
}
