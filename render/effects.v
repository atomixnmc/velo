module render

import math
import velo.core
import velo.assets

// Built-in sprite / skeleton effects: shader effects (see shader.v) that ship with the engine, so a game needs
// no .glsl asset. Put a SpriteFx next to a Sprite, a velo.kine2d skeleton (Spine / Kine2D) or any other mesh
// component on the same node:
//
//   SpriteFx { effect = "outline"  amount = 2  color = [255, 220, 120, 255] }
//   SpriteFx { effect = "dissolve"  amount = 0.4  width = 0.08  color = [255, 120, 30, 255] }
//
// and drive it from code: fx.flash(colour, seconds) (hit flash), fx.play('dissolve', 0, 1, 0.8) (animate
// `amount` from 0 to 1 over 0.8 s, e.g. a death), fx.clear().
//
// The set covers what 2D shader packs for Unity commonly offer per sprite (hit flash, outline / glow,
// dissolve, hologram, shine, greyscale, hue shift, wave, pixelate, frozen / petrify, Spine's "tint black"),
// written from scratch in the effect language every Velo backend shares. Every effect reads:
//   amount  PARAMS.x   the main strength (its meaning is listed per effect below)
//   width   PARAMS.y   the second parameter
//   color   PARAM_COLOR
//
// Notes: on skeletons the effect runs per attachment (an outline traces each part, as spine-unity's
// per-attachment outline does); additive slots are drawn without it. Outline / glow on a simple Sprite get
// extra room around the frame (`pad`) so they are not cut at the frame's edge.

pub const sprite_effects = ['none', 'flash', 'outline', 'glow', 'dissolve', 'hologram', 'shine', 'greyscale',
	'hue_shift', 'wave', 'pixelate', 'frozen', 'petrify', 'tint_black', 'negative', 'ghost']

// effect_doc: what `amount` / `width` / `color` mean for each built-in effect.
pub const effect_docs = {
	'flash':      'amount 0..1 mix toward color'
	'outline':    'amount = thickness in texels, color = outline colour, width > 0 = soft edge'
	'glow':       'amount = radius in texels, color = glow colour (alpha = strength), width = pulse speed'
	'dissolve':   'amount 0..1 how much is gone, width = burning edge size (0..0.3), color = edge colour'
	'hologram':   'amount = scanline count over the frame, width = flicker speed, color = tint'
	'shine':      'amount = seconds between sweeps, width = band width (0..1), color = band colour'
	'greyscale':  'amount 0..1'
	'hue_shift':  'amount = turns (0..1 = 0..360 degrees), width = saturation multiplier (0 = keep)'
	'wave':       'amount = amplitude in texels, width = waves across the frame, color unused'
	'pixelate':   'amount = block size in texels'
	'frozen':     'amount 0..1, color = ice tint'
	'petrify':    'amount 0..1, color = stone tint'
	'tint_black': 'color = the dark colour (Spine two-colour tint: shadows -> color, lights -> tint)'
	'negative':   'amount 0..1'
	'ghost':      'amount = minimum alpha (0..1), width = pulse speed, color = tint'
}

// Shared helpers, prepended to every built-in effect.
const fx_common = '
vec2 fx_local(vec2 uv) { return (uv - FRAME_RECT.xy) / max(FRAME_RECT.zw - FRAME_RECT.xy, vec2(0.000001, 0.000001)); }
vec2 fx_texel() { return 1.0 / max(TEXTURE_SIZE, vec2(1.0, 1.0)); }
// the texture, transparent outside the current frame (sprite sheets) so effects do not bleed neighbours in
vec4 fx_tex(vec2 uv) {
	vec2 lo = min(FRAME_RECT.xy, FRAME_RECT.zw);
	vec2 hi = max(FRAME_RECT.xy, FRAME_RECT.zw);
	if (uv.x < lo.x || uv.y < lo.y || uv.x > hi.x || uv.y > hi.y) { return vec4(0.0, 0.0, 0.0, 0.0); }
	return texel(uv);
}
float fx_hash(vec2 p) {
	vec3 p3 = fract(vec3(p.x, p.y, p.x) * 0.1031);
	p3 += dot(p3, vec3(p3.y, p3.z, p3.x) + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}
float fx_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = fx_hash(i);
	float b = fx_hash(i + vec2(1.0, 0.0));
	float c = fx_hash(i + vec2(0.0, 1.0));
	float d = fx_hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
float fx_luma(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }
// alpha of the 8 neighbours at distance r (texels): the silhouette grown by r
float fx_ring(vec2 uv, float r) {
	vec2 t = fx_texel() * r;
	float a = 0.0;
	a = max(a, fx_tex(uv + vec2(t.x, 0.0)).a);
	a = max(a, fx_tex(uv - vec2(t.x, 0.0)).a);
	a = max(a, fx_tex(uv + vec2(0.0, t.y)).a);
	a = max(a, fx_tex(uv - vec2(0.0, t.y)).a);
	a = max(a, fx_tex(uv + t * 0.7071).a);
	a = max(a, fx_tex(uv - t * 0.7071).a);
	a = max(a, fx_tex(uv + vec2(t.x, -t.y) * 0.7071).a);
	a = max(a, fx_tex(uv + vec2(-t.x, t.y) * 0.7071).a);
	return a;
}
'

const fx_bodies = {
	'flash':      'vec4 effect(vec4 color, vec2 uv) {
	vec4 c = fx_tex(uv) * color;
	return vec4(mix(c.rgb, PARAM_COLOR.rgb, clamp(PARAMS.x, 0.0, 1.0) * PARAM_COLOR.a), c.a);
}'
	'outline':    'vec4 effect(vec4 color, vec2 uv) {
	vec4 c = fx_tex(uv) * color;
	float r = max(PARAMS.x, 0.0);
	float o = fx_ring(uv, r);
	if (PARAMS.y > 0.0) { o = max(o * 0.5, fx_ring(uv, r * 0.5)); }
	float edge = clamp(o - c.a, 0.0, 1.0) * PARAM_COLOR.a * color.a;
	return vec4(mix(PARAM_COLOR.rgb, c.rgb, c.a), max(c.a, edge));
}'
	'glow':       'vec4 effect(vec4 color, vec2 uv) {
	vec4 c = fx_tex(uv) * color;
	float r = max(PARAMS.x, 1.0);
	float g = fx_ring(uv, r) * 0.25 + fx_ring(uv, r * 0.66) * 0.35 + fx_ring(uv, r * 0.33) * 0.4;
	float pulse = PARAMS.y > 0.0 ? 0.75 + 0.25 * sin(TIME * PARAMS.y * 6.2831) : 1.0;
	float a = clamp(g - c.a, 0.0, 1.0) * PARAM_COLOR.a * pulse * color.a;
	vec3 rgb = c.rgb + PARAM_COLOR.rgb * PARAM_COLOR.a * 0.25 * pulse * c.a;
	return vec4(mix(PARAM_COLOR.rgb, rgb, c.a), max(c.a, a));
}'
	'dissolve':   'vec4 effect(vec4 color, vec2 uv) {
	vec4 c = fx_tex(uv) * color;
	vec2 p = fx_local(uv) * 6.0;
	float n = fx_noise(p) * 0.65 + fx_noise(p * 2.7) * 0.35;
	float cut = PARAMS.x * (1.0 + PARAMS.y) - PARAMS.y;
	if (n < cut) { return vec4(0.0, 0.0, 0.0, 0.0); }
	float e = PARAMS.y > 0.0 ? 1.0 - smoothstep(0.0, PARAMS.y, n - cut) : 0.0;
	if (PARAMS.x <= 0.0) { e = 0.0; }
	return vec4(mix(c.rgb, PARAM_COLOR.rgb, e * PARAM_COLOR.a), c.a);
}'
	'hologram':   'vec4 effect(vec4 color, vec2 uv) {
	vec2 l = fx_local(uv);
	float lines = max(PARAMS.x, 1.0);
	float speed = PARAMS.y;
	float jitter = (fx_hash(vec2(floor(TIME * 20.0 * max(speed, 0.0001)), floor(l.y * 40.0))) - 0.5) * 0.01 * step(0.0001, speed);
	vec4 c = fx_tex(uv + vec2(jitter * (FRAME_RECT.z - FRAME_RECT.x), 0.0)) * color;
	float scan = 0.65 + 0.35 * sin((l.y * lines - TIME * speed * 2.0) * 6.2831);
	float flick = 0.85 + 0.15 * sin(TIME * speed * 37.0);
	vec3 tint = mix(vec3(fx_luma(c.rgb), fx_luma(c.rgb), fx_luma(c.rgb)), PARAM_COLOR.rgb, 0.6) * 1.3;
	return vec4(tint, c.a * scan * flick * 0.85);
}'
	'shine':      'vec4 effect(vec4 color, vec2 uv) {
	vec4 c = fx_tex(uv) * color;
	vec2 l = fx_local(uv);
	float period = max(PARAMS.x, 0.1);
	float t = mod(TIME, period) / period * 3.0 - 1.0;
	float d = abs(l.x + l.y * 0.5 - t);
	float band = 1.0 - smoothstep(0.0, max(PARAMS.y, 0.01), d);
	return vec4(mix(c.rgb, PARAM_COLOR.rgb, band * PARAM_COLOR.a), c.a);
}'
	'greyscale':  'vec4 effect(vec4 color, vec2 uv) {
	vec4 c = fx_tex(uv) * color;
	float g = fx_luma(c.rgb);
	return vec4(mix(c.rgb, vec3(g, g, g), clamp(PARAMS.x, 0.0, 1.0)), c.a);
}'
	'hue_shift':  'vec3 fx_hue(vec3 c, float turns, float sat) {
	// rotate around the grey axis (YIQ)
	float y = dot(c, vec3(0.299, 0.587, 0.114));
	float i = dot(c, vec3(0.596, -0.274, -0.322));
	float q = dot(c, vec3(0.211, -0.523, 0.312));
	float h = turns * 6.2831853;
	float cs = cos(h);
	float sn = sin(h);
	float i2 = (i * cs - q * sn) * sat;
	float q2 = (i * sn + q * cs) * sat;
	return vec3(y + 0.956 * i2 + 0.621 * q2, y - 0.272 * i2 - 0.647 * q2, y - 1.106 * i2 + 1.703 * q2);
}
vec4 effect(vec4 color, vec2 uv) {
	vec4 c = fx_tex(uv) * color;
	float sat = PARAMS.y > 0.0 ? PARAMS.y : 1.0;
	return vec4(clamp(fx_hue(c.rgb, PARAMS.x, sat), vec3(0.0, 0.0, 0.0), vec3(1.0, 1.0, 1.0)), c.a);
}'
	'wave':       'vec4 effect(vec4 color, vec2 uv) {
	vec2 l = fx_local(uv);
	float waves = PARAMS.y > 0.0 ? PARAMS.y : 2.0;
	float off = sin((l.y * waves + TIME) * 6.2831) * PARAMS.x * fx_texel().x;
	return fx_tex(uv + vec2(off, 0.0)) * color;
}'
	'pixelate':   'vec4 effect(vec4 color, vec2 uv) {
	vec2 b = fx_texel() * max(PARAMS.x, 1.0);
	vec2 q = (floor((uv - FRAME_RECT.xy) / b) + 0.5) * b + FRAME_RECT.xy;
	return fx_tex(q) * color;
}'
	'frozen':     'vec4 effect(vec4 color, vec2 uv) {
	vec4 c = fx_tex(uv) * color;
	float g = fx_luma(c.rgb);
	vec2 l = fx_local(uv);
	float crack = smoothstep(0.82, 0.95, fx_noise(l * 14.0)) * 0.6;
	vec3 ice = PARAM_COLOR.rgb * (0.55 + g * 0.9) + crack;
	return vec4(mix(c.rgb, ice, clamp(PARAMS.x, 0.0, 1.0)), c.a);
}'
	'petrify':    'vec4 effect(vec4 color, vec2 uv) {
	vec4 c = fx_tex(uv) * color;
	float g = fx_luma(c.rgb);
	float grain = fx_noise(fx_local(uv) * 40.0) * 0.18 - 0.09;
	vec3 stone = PARAM_COLOR.rgb * (0.35 + g * 0.8) + grain;
	return vec4(mix(c.rgb, stone, clamp(PARAMS.x, 0.0, 1.0)), c.a);
}'
	'tint_black': 'vec4 effect(vec4 color, vec2 uv) {
	vec4 t = fx_tex(uv);
	vec3 rgb = (vec3(1.0, 1.0, 1.0) - t.rgb) * PARAM_COLOR.rgb * t.a + t.rgb * color.rgb;
	return vec4(rgb, t.a * color.a);
}'
	'negative':   'vec4 effect(vec4 color, vec2 uv) {
	vec4 c = fx_tex(uv) * color;
	return vec4(mix(c.rgb, vec3(1.0, 1.0, 1.0) - c.rgb, clamp(PARAMS.x, 0.0, 1.0)), c.a);
}'
	'ghost':      'vec4 effect(vec4 color, vec2 uv) {
	vec4 c = fx_tex(uv) * color;
	float speed = PARAMS.y > 0.0 ? PARAMS.y : 1.0;
	float a = mix(clamp(PARAMS.x, 0.0, 1.0), 1.0, 0.5 + 0.5 * sin(TIME * speed * 6.2831));
	return vec4(mix(c.rgb, PARAM_COLOR.rgb, 0.35 * PARAM_COLOR.a), c.a * a);
}'
}

// effect_source: the standalone source of one built-in effect (for a .glsl file of your own to start from).
pub fn effect_source(name string) ?string {
	body := fx_bodies[name] or { return none }
	return fx_common + body + '
'
}

// effect_index: the built-in effect's number in sprite_effects (0 = none / unknown).
pub fn effect_index(name string) int {
	i := sprite_effects.index(name)
	return if i < 0 { 0 } else { i }
}

// uber_effect_source: every built-in effect in one shader, picked by the effect number the uniforms carry
// (column 0, w). One shader means one pipeline for all of them: each sokol_gl pipeline costs 5 sokol_gfx
// pipelines and the pool holds 64, so one pipeline per effect would run out.
pub fn uber_effect_source() string {
	mut s := fx_common
	mut dispatch := 'vec4 effect(vec4 color, vec2 uv) {
	int id = int(velo_p0.w + 0.5);
'
	for i, name in sprite_effects {
		body := fx_bodies[name] or { continue }
		s += body.replace('vec4 effect(vec4 color, vec2 uv)', 'vec4 fx_${name}(vec4 color, vec2 uv)') + '
'
		dispatch += '	if (id == ${i}) { return fx_${name}(color, uv); }
'
	}
	return s + dispatch + '	return fx_tex(uv) * color;
}
'
}

// builtin_effects caches the in-memory uber shader (the renderer compiles it once).
@[heap]
struct BuiltinEffects {
mut:
	uber &assets.Shader = unsafe { nil }
}

const builtin_effects = &BuiltinEffects{}

// builtin_effect: the in-memory shader holding every built-in effect (id 'velo:fx'), none for unknown names.
pub fn builtin_effect(name string) ?&assets.Shader {
	if name !in fx_bodies {
		return none
	}
	mut cache := unsafe { builtin_effects }
	if cache.uber == unsafe { nil } {
		cache.uber = &assets.Shader{
			id:      'velo:fx'
			path:    'velo:fx'
			source:  uber_effect_source()
			version: 1
		}
	}
	return cache.uber
}

// fx_uniforms: the shader built-ins for a SpriteFx (shader_uniforms plus the effect number in column 0, w).
fn fx_uniforms(fx &SpriteFx, tex_w f32, tex_h f32, frame [4]f32) []f32 {
	mut u := shader_uniforms(shader_time(fx.node), tex_w, tex_h, core.vec2(fx.amount, fx.width), fx.color,
		frame)
	u[3] = f32(effect_index(fx.effect))
	return u
}

// SpriteFx — a built-in effect on the node's Sprite, skeleton or mesh component (see the top of this file).
pub struct SpriteFx {
	core.Component
pub mut:
	effect string     = 'outline' @[choices: 'none|flash|outline|glow|dissolve|hologram|shine|greyscale|hue_shift|wave|pixelate|frozen|petrify|tint_black|negative|ghost']
	amount f32        = 1
	width  f32
	color  core.Color = core.white
	// extra texels drawn around a simple Sprite's frame (outline / glow need room); -1 = automatic
	pad f32 = -1
	// runtime: a timed flash or an animation of `amount` (see flash / play)
	anim_from     f32    @[hide]
	anim_to       f32    @[hide]
	anim_time     f32    @[hide]
	anim_length   f32    @[hide]
	anim_restore  string @[hide] // effect to go back to when a flash ends
	anim_restore_amount f32    @[hide]
	anim_restore_color  core.Color @[hide]
}

pub fn (mut fx SpriteFx) update(dt f32) {
	if fx.anim_length <= 0 {
		return
	}
	fx.anim_time += dt
	k := if fx.anim_time >= fx.anim_length { f32(1) } else { fx.anim_time / fx.anim_length }
	fx.amount = fx.anim_from + (fx.anim_to - fx.anim_from) * k
	if k >= 1 {
		fx.anim_length = 0
		if fx.anim_restore != '' {
			fx.effect = fx.anim_restore
			fx.amount = fx.anim_restore_amount
			fx.color = fx.anim_restore_color
			fx.anim_restore = ''
		}
	}
}

// flash: a hit flash toward `c` that fades out over `seconds`, then the previous effect comes back.
pub fn (mut fx SpriteFx) flash(c core.Color, seconds f32) {
	if fx.anim_restore == '' {
		fx.anim_restore = if fx.effect == 'flash' { 'none' } else { fx.effect }
		fx.anim_restore_amount = fx.amount
		fx.anim_restore_color = fx.color
	}
	fx.effect = 'flash'
	fx.color = c
	fx.play('flash', 1, 0, seconds)
}

// play switches to `effect` and animates `amount` from `from` to `to` over `seconds` (e.g. a dissolve death).
pub fn (mut fx SpriteFx) play(effect string, from f32, to f32, seconds f32) {
	fx.effect = effect
	fx.anim_from = from
	fx.anim_to = to
	fx.anim_time = 0
	fx.anim_length = if seconds > 0 { seconds } else { f32(0.0001) }
	fx.amount = from
}

// clear removes the effect.
pub fn (mut fx SpriteFx) clear() {
	fx.effect = 'none'
	fx.anim_length = 0
	fx.anim_restore = ''
}

// shader: the effect's shader, none when off.
pub fn (fx &SpriteFx) shader() ?&assets.Shader {
	if !fx.enabled || fx.effect == '' || fx.effect == 'none' {
		return none
	}
	return builtin_effect(fx.effect)
}

// padding: texels of room the effect needs around a simple sprite's frame.
pub fn (fx &SpriteFx) padding() f32 {
	if fx.pad >= 0 {
		return fx.pad
	}
	return match fx.effect {
		'outline' { f32(math.ceil(fx.amount)) + 1 }
		'glow' { f32(math.ceil(fx.amount)) + 1 }
		'wave' { f32(math.ceil(math.abs(fx.amount))) }
		else { 0 }
	}
}

// node_fx: the node's active SpriteFx with a shader, if any.
fn node_fx(n &core.Node) ?&SpriteFx {
	fx := n.get_component[SpriteFx]() or { return none }
	if _ := fx.shader() {
		return fx
	}
	return none
}
