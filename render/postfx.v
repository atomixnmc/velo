module render

import os
import time
import sokol.gfx
import sokol.sapp
import sokol.sgl
import velo.core
import velo.assets

// Fullscreen post-processing.
//
// Add a PostProcess component to any node of a scene (one per scene; the first active one found is used):
//
//   PostProcess { preset = "gothic_night" }
//   PostProcess { preset = "bloom"  bloom = 1.4  vignette = 0.5 }      # a preset with some values overridden
//   PostProcess { preset = "none"  lut = @asset("...")  lut_strength = 1 }
//
// With it, the app draws the world into an offscreen image, runs the passes below and only then presents;
// Canvas (UI) nodes are drawn afterwards, untouched, unless `include_ui` is set.
//
//   bloom      prefilter (soft threshold) to a half-size image -> separable gaussian -> added after the grade
//   grade      exposure, lift (shadow colour) / gamma / gain (highlight colour), contrast, saturation, LUT
//   vignette   darkens (or tints) toward the corners
//   chromatic  splits red / blue toward the edges (pixels at the corners, for a 1080 px tall screen)
//   grain      animated film grain
//   flash      PostProcess.flash(colour, seconds): a fullscreen flash fading out (hits, spells, lightning)
//   shader     optional last pass: a .glsl effect (see shader.v) run over the whole image; texel(uv) reads it
//
// Without a PostProcess component nothing changes: everything draws straight to the window as before.
// Renderer.postfx_enabled = false (or the environment variable VELO_POSTFX=0) turns it off for low-end devices.
// Backends without a velo shader language (D3D11, WebGPU) ignore it.

pub const post_presets = ['none', 'gothic_night', 'gothic_day', 'bloom', 'grade', 'vignette',
	'chromatic', 'grain', 'cinematic']

// PostSettings — the resolved values of every pass (a preset, then the component's overrides).
pub struct PostSettings {
pub mut:
	bloom             f32 // intensity; 0 = no bloom passes at all
	bloom_threshold   f32 = 0.7  // brightness (0..1, max of r/g/b) where the glow starts
	bloom_knee        f32 = 0.15 // softness of the threshold
	bloom_radius      f32 = 1.0  // blur spread (1 = 9 taps at half resolution; 2 = twice as wide)
	bloom_saturation  f32 = 1.0  // >1 makes the glow more colourful than the source
	exposure          f32 = 1.0
	contrast          f32 = 1.0
	saturation        f32 = 1.0
	gamma             f32 = 1.0
	lift              [3]f32 // added into the shadows (0 = none)
	gain              [3]f32 = [f32(1), 1, 1]! // multiplies the highlights
	lut_strength      f32 // 0..1, needs PostProcess.lut
	vignette          f32 // 0..1 how dark the corners get
	vignette_radius   f32 = 0.55 // where it starts (0 = centre, 1 = corner)
	vignette_softness f32 = 0.6
	vignette_color    [3]f32
	chromatic         f32 // pixels at the corners (1080 p)
	grain             f32 // 0..~0.2
	grain_size        f32 = 1.5 // pixels
}

// post_preset: the settings of a named preset (unknown names = 'none').
pub fn post_preset(name string) PostSettings {
	return match name {
		'gothic_night' {
			// dark, cold and desaturated, so coloured magic and fire glow out of it
			PostSettings{
				bloom:             1.1
				bloom_threshold:   0.62
				bloom_knee:        0.2
				bloom_radius:      1.6
				bloom_saturation:  1.35
				exposure:          0.92
				contrast:          1.12
				saturation:        0.78
				gamma:             1.05
				lift:              [f32(0.025), 0.01, 0.06]!
				gain:              [f32(0.94), 0.95, 1.04]!
				vignette:          0.62
				vignette_radius:   0.45
				vignette_softness: 0.7
				vignette_color:    [f32(0.03), 0.0, 0.06]!
				chromatic:         1.2
				grain:             0.045
			}
		}
		'gothic_day' {
			// restored kingdom: warm sunrise, gentle glow
			PostSettings{
				bloom:           0.55
				bloom_threshold: 0.78
				bloom_radius:    1.4
				exposure:        1.03
				contrast:        1.06
				saturation:      1.06
				lift:            [f32(0.01), 0.008, 0.02]!
				gain:            [f32(1.04), 1.0, 0.93]!
				vignette:        0.32
				vignette_radius: 0.55
				vignette_color:  [f32(0.08), 0.04, 0.0]!
				grain:           0.02
			}
		}
		'bloom' {
			PostSettings{
				bloom:            1.2
				bloom_threshold:  0.6
				bloom_radius:     1.5
				bloom_saturation: 1.2
			}
		}
		'grade' {
			PostSettings{
				contrast:   1.18
				saturation: 1.25
				lift:       [f32(0.0), 0.03, 0.06]!
				gain:       [f32(1.06), 0.98, 0.88]!
			}
		}
		'vignette' {
			PostSettings{
				vignette:        0.75
				vignette_radius: 0.35
			}
		}
		'chromatic' {
			PostSettings{
				chromatic: 6
			}
		}
		'grain' {
			PostSettings{
				grain:      0.12
				grain_size: 2
			}
		}
		'cinematic' {
			PostSettings{
				bloom:           0.7
				bloom_threshold: 0.72
				contrast:        1.15
				saturation:      0.9
				lift:            [f32(0.0), 0.03, 0.05]!
				gain:            [f32(1.05), 1.0, 0.9]!
				vignette:        0.45
				chromatic:       1.5
				grain:           0.05
			}
		}
		else {
			PostSettings{}
		}
	}
}

// PostProcess — scene-level fullscreen effects (see the top of this file). Every override left at -1 (or a
// colour with alpha 0) keeps the preset's value.
pub struct PostProcess {
	core.Component
pub mut:
	preset     string = 'gothic_night' @[choices: 'none|gothic_night|gothic_day|bloom|grade|vignette|chromatic|grain|cinematic']
	include_ui bool // true: Canvas nodes go through the effects too
	// overrides
	bloom             f32        = -1
	bloom_threshold   f32        = -1
	bloom_radius      f32        = -1
	bloom_saturation  f32        = -1
	exposure          f32        = -1
	contrast          f32        = -1
	saturation        f32        = -1
	gamma             f32        = -1
	lift              core.Color = unset_color // shadow colour: rgb, alpha = strength (255 = add up to 0.25)
	gain              core.Color = unset_color // highlight colour multiplier (255 = 1.0)
	vignette          f32        = -1
	vignette_radius   f32        = -1
	vignette_softness f32        = -1
	vignette_color    core.Color = unset_color
	chromatic         f32        = -1
	grain             f32        = -1
	grain_size        f32        = -1
	// colour lookup table: a strip of N slices of N x N (e.g. 256 x 16), red across a slice, green down,
	// blue across the slices. tools/make_lut.py writes the identity table to grade in an image editor.
	lut          assets.AssetRef[assets.Texture]
	lut_strength f32 = -1
	// an extra last pass (a .glsl effect, as for Sprite.shader); PARAMS / PARAM_COLOR are below
	shader        assets.AssetRef[assets.Shader]
	shader_params core.Vec2
	shader_color  core.Color = core.white
	// runtime
	lut_tex      &assets.Texture = unsafe { nil } @[hide]
	shader_data  &assets.Shader  = unsafe { nil }  @[hide]
	flash_color  core.Color      @[hide]
	flash_start  f64             @[hide]
	flash_length f32             @[hide]
}

pub fn (mut p PostProcess) on_load() {
	if p.lut.is_set() && p.lut_tex == unsafe { nil } && p.node != unsafe { nil }
		&& p.node.scene != unsafe { nil } && p.node.scene.assets != unsafe { nil } {
		mut db := p.node.scene.assets
		p.lut_tex = db.get(p.lut) or {
			eprintln('[PostProcess] ${p.node.path()}: ${err}')
			unsafe { nil }
		}
	}
	if p.shader_data == unsafe { nil } {
		p.shader_data = load_shader(p.node, p.shader)
	}
}

pub fn (mut p PostProcess) on_destroy() {
	if p.lut_tex != unsafe { nil } && p.node != unsafe { nil } && p.node.scene != unsafe { nil }
		&& p.node.scene.assets != unsafe { nil } {
		mut db := p.node.scene.assets
		db.release(p.lut_tex.id)
	}
	p.lut_tex = unsafe { nil }
	p.shader_data = release_shader_asset(p.node, p.shader_data)
}

// set_shader changes the extra last pass at runtime (an unset ref removes it).
pub fn (mut p PostProcess) set_shader(r assets.AssetRef[assets.Shader]) {
	p.shader_data = release_shader_asset(p.node, p.shader_data)
	p.shader = r
	p.shader_data = load_shader(p.node, r)
}

// flash starts a fullscreen flash of `c` (its alpha = the peak strength) that fades out over `seconds`.
pub fn (mut p PostProcess) flash(c core.Color, seconds f32) {
	p.flash_color = c
	p.flash_length = if seconds > 0 { seconds } else { f32(0.001) }
	p.flash_start = if p.node != unsafe { nil } && p.node.scene != unsafe { nil } {
		p.node.scene.real_time
	} else {
		0
	}
}

// flash_amount: the flash strength (0..1) at scene real time `now`.
pub fn (p &PostProcess) flash_amount(now f64) f32 {
	if p.flash_length <= 0 || p.flash_color.a == 0 {
		return 0
	}
	t := f32(now - p.flash_start) / p.flash_length
	if t < 0 || t >= 1 {
		return 0
	}
	return f32(p.flash_color.a) / 255 * (1 - t) * (1 - t)
}

// unset_color: a colour override left at alpha 0 keeps the preset's value
const unset_color = core.Color{0, 0, 0, 0}

fn ov(v f32, base f32) f32 {
	return if v >= 0 { v } else { base }
}

fn rgb3(c core.Color, k f32) [3]f32 {
	return [f32(c.r) / 255 * k, f32(c.g) / 255 * k, f32(c.b) / 255 * k]!
}

// settings: the preset with this component's overrides applied.
pub fn (p &PostProcess) settings() PostSettings {
	b := post_preset(p.preset)
	mut s := PostSettings{
		...b
		bloom:             ov(p.bloom, b.bloom)
		bloom_threshold:   ov(p.bloom_threshold, b.bloom_threshold)
		bloom_radius:      ov(p.bloom_radius, b.bloom_radius)
		bloom_saturation:  ov(p.bloom_saturation, b.bloom_saturation)
		exposure:          ov(p.exposure, b.exposure)
		contrast:          ov(p.contrast, b.contrast)
		saturation:        ov(p.saturation, b.saturation)
		gamma:             ov(p.gamma, b.gamma)
		vignette:          ov(p.vignette, b.vignette)
		vignette_radius:   ov(p.vignette_radius, b.vignette_radius)
		vignette_softness: ov(p.vignette_softness, b.vignette_softness)
		chromatic:         ov(p.chromatic, b.chromatic)
		grain:             ov(p.grain, b.grain)
		grain_size:        ov(p.grain_size, b.grain_size)
		lut_strength:      ov(p.lut_strength, if p.lut.is_set() { f32(1) } else { b.lut_strength })
	}
	if p.lift.a > 0 {
		s.lift = rgb3(p.lift, f32(p.lift.a) / 255 * 0.25)
	}
	if p.gain.a > 0 {
		s.gain = rgb3(p.gain, 1)
	}
	if p.vignette_color.a > 0 {
		s.vignette_color = rgb3(p.vignette_color, 1)
	}
	return s
}

// uniforms packs the composite pass's U[] (see post_composite_fs).
pub fn (s PostSettings) uniforms(seconds f32, w int, h int, lut_size int, has_lut bool, flash core.Color, flash_amount f32) []f32 {
	g := if s.gamma > 0 { 1 / s.gamma } else { f32(1) }
	bloom_on := if s.bloom > 0 { f32(1) } else { f32(0) }
	lut := if has_lut { s.lut_strength } else { f32(0) }
	ca := s.chromatic * f32(h) / 1080
	aspect := if h > 0 { f32(w) / f32(h) } else { f32(1) }
	return [
		seconds,
		s.bloom_saturation,
		s.bloom,
		bloom_on, // 0
		s.lift[0],
		s.lift[1],
		s.lift[2],
		s.saturation, // 1
		g,
		g,
		g,
		s.contrast, // 2
		s.gain[0],
		s.gain[1],
		s.gain[2],
		s.exposure, // 3
		1,
		1,
		1,
		lut, // 4
		s.vignette,
		s.vignette_radius,
		s.vignette_softness,
		aspect, // 5
		s.vignette_color[0],
		s.vignette_color[1],
		s.vignette_color[2],
		ca, // 6
		s.grain,
		s.grain_size,
		0,
		0, // 7
		f32(flash.r) / 255,
		f32(flash.g) / 255,
		f32(flash.b) / 255,
		flash_amount, // 8
		1 / f32(if w > 0 {
			w
		} else {
			1
		}),
		1 / f32(if h > 0 {
			h
		} else {
			1
		}),
		f32(lut_size),
		0, // 9
		0,
		0,
		0,
		0, // 10
		0,
		0,
		0,
		0, // 11
	]
}

// find_post: the first enabled PostProcess on an active node (tree order).
pub fn find_post(n &core.Node) ?&PostProcess {
	if !n.active || n.destroyed {
		return none
	}
	if pp := n.get_component[PostProcess]() {
		if pp.enabled {
			return pp
		}
	}
	for ch in n.children {
		if pp := find_post(ch) {
			return pp
		}
	}
	return none
}

// ---------- GPU side ----------

fn C.sgl_layer(layer_id int)
fn C.sgl_draw_layer(layer_id int)

// sokol_gl layers: the world goes to 0 (drawn into the offscreen image), the UI and overlays to 1 (drawn on the
// window after the effects), the optional shader pass to 2.
const layer_world = 0
const layer_ui = 1
const layer_shader = 2

struct PostTarget {
mut:
	img gfx.Image // what is sampled
	att gfx.Attachments
	w   int
	h   int
}

// PostFx — the GPU resources of the post-processing chain (created on first use, rebuilt on resize).
struct PostFx {
mut:
	tried       bool
	ok          bool
	w           int
	h           int
	samples     int
	scene_color gfx.Image // multisampled when the window is
	scene_depth gfx.Image
	scene       PostTarget // resolved scene colour
	half_a      PostTarget
	half_b      PostTarget
	full_b      PostTarget // composite output, when a shader pass follows
	smp         gfx.Sampler
	shd_bright  gfx.Shader
	shd_blur    gfx.Shader
	shd_comp    gfx.Shader
	pip_bright  gfx.Pipeline
	pip_blur    gfx.Pipeline
	pip_comp    gfx.Pipeline // to the window
	pip_comp_rt gfx.Pipeline // to full_b
	timing      PostTiming
}

const postfx_env_off = os.getenv('VELO_POSTFX') == '0'

fn os_env_on(name string) bool {
	return os.getenv(name) == '1'
}

fn os_env_set(name string) bool {
	return os.getenv(name) != ''
}

fn gfx_is_gl() bool {
	return gfx.query_backend() in [.glcore33, .gles3]
}

fn make_post_shader(body string, ntex int, lang ShaderLang, label string) !gfx.Shader {
	vs, fs := post_sources(body, ntex, lang)
	mut desc := gfx.ShaderDesc{}
	unsafe { vmemset(&desc, 0, int(sizeof(desc))) }
	desc.label = &char(label.str)
	desc.vs.source = &char(vs.str)
	desc.fs.source = &char(fs.str)
	if lang == .msl {
		desc.vs.entry = c'main0'
		desc.fs.entry = c'main0'
	}
	desc.fs.uniform_blocks[0].size = usize(post_uniform_count * 16)
	desc.fs.uniform_blocks[0].uniforms[0].name = c'fs_u'
	desc.fs.uniform_blocks[0].uniforms[0].@type = .float4
	desc.fs.uniform_blocks[0].uniforms[0].array_count = post_uniform_count
	names := [c'tex0_smp', c'tex1_smp', c'tex2_smp']
	for i in 0 .. ntex {
		desc.fs.images[i].used = true
		desc.fs.images[i].image_type = ._2d
		desc.fs.images[i].sample_type = .float
		desc.fs.samplers[i].used = true
		desc.fs.samplers[i].sampler_type = .filtering
		desc.fs.image_sampler_pairs[i].used = true
		desc.fs.image_sampler_pairs[i].image_slot = u8(i)
		desc.fs.image_sampler_pairs[i].sampler_slot = u8(i)
		desc.fs.image_sampler_pairs[i].glsl_name = names[i]
	}
	shd := gfx.make_shader(&desc)
	if gfx.query_shader_state(shd) != .valid {
		gfx.destroy_shader(shd)
		return error('${label} does not compile (see the graphics log above)')
	}
	return shd
}

// make_post_pipeline: offscreen = an RGBA8 target without depth; otherwise the window's formats.
fn make_post_pipeline(shd gfx.Shader, offscreen bool) gfx.Pipeline {
	mut pd := gfx.PipelineDesc{}
	unsafe { vmemset(&pd, 0, int(sizeof(pd))) }
	pd.label = c'velo-post'
	pd.shader = shd
	if offscreen {
		pd.colors[0].pixel_format = .rgba8
		pd.depth.pixel_format = .none
		pd.sample_count = 1
	}
	return gfx.make_pipeline(&pd)
}

fn (mut f PostFx) init_shaders() ! {
	lang := backend_lang() or {
		return error('not supported by the ${gfx.query_backend()} backend')
	}
	f.shd_bright = make_post_shader(post_bright_fs, 1, lang, 'velo-post-bright')!
	f.shd_blur = make_post_shader(post_blur_fs, 1, lang, 'velo-post-blur')!
	f.shd_comp = make_post_shader(post_composite_fs, 3, lang, 'velo-post-composite')!
	f.pip_bright = make_post_pipeline(f.shd_bright, true)
	f.pip_blur = make_post_pipeline(f.shd_blur, true)
	f.pip_comp = make_post_pipeline(f.shd_comp, false)
	f.pip_comp_rt = make_post_pipeline(f.shd_comp, true)
	mut sd := gfx.SamplerDesc{}
	unsafe { vmemset(&sd, 0, int(sizeof(sd))) }
	sd.min_filter = .linear
	sd.mag_filter = .linear
	sd.wrap_u = .clamp_to_edge
	sd.wrap_v = .clamp_to_edge
	sd.label = c'velo-post-sampler'
	f.smp = gfx.make_sampler(&sd)
	if f.smp.id == 0 {
		// without it every pass would fail validation each frame: switch post-processing off instead
		return error('no sampler (sokol sampler pool exhausted)')
	}
}

fn make_rt_image(w int, h int, format gfx.PixelFormat, samples int, label &char) gfx.Image {
	mut d := gfx.ImageDesc{}
	unsafe { vmemset(&d, 0, int(sizeof(d))) }
	d.render_target = true
	d.width = w
	d.height = h
	d.pixel_format = format
	d.sample_count = samples
	unsafe {
		d.label = label
	}
	return gfx.make_image(&d)
}

fn make_color_target(w int, h int, label &char) PostTarget {
	img := make_rt_image(w, h, .rgba8, 1, label)
	mut ad := gfx.AttachmentsDesc{}
	unsafe { vmemset(&ad, 0, int(sizeof(ad))) }
	ad.colors[0].image = img
	return PostTarget{
		img: img
		att: gfx.make_attachments(&ad)
		w:   w
		h:   h
	}
}

fn (mut f PostFx) destroy_targets() {
	if f.w == 0 {
		return
	}
	for t in [f.scene, f.half_a, f.half_b, f.full_b] {
		gfx.destroy_attachments(t.att)
		gfx.destroy_image(t.img)
	}
	if f.samples > 1 {
		gfx.destroy_image(f.scene_color)
	}
	gfx.destroy_image(f.scene_depth)
	f.w = 0
	f.h = 0
}

// ensure_targets (re)creates the images for a w x h framebuffer.
fn (mut f PostFx) ensure_targets(w int, h int) {
	if f.w == w && f.h == h {
		return
	}
	f.destroy_targets()
	// the window's formats as sokol_gfx numbers them (sapp.depth_format() uses sokol_app's own numbering)
	sw := gg_default_pass().swapchain
	f.samples = if sw.sample_count > 0 { sw.sample_count } else { 1 }
	color_fmt := sw.color_format
	depth_fmt := sw.depth_format
	resolved := make_rt_image(w, h, color_fmt, 1, c'velo-post-scene')
	f.scene_color = if f.samples > 1 {
		make_rt_image(w, h, color_fmt, f.samples, c'velo-post-scene-msaa')
	} else {
		resolved
	}
	f.scene_depth = make_rt_image(w, h, depth_fmt, f.samples, c'velo-post-depth')
	mut ad := gfx.AttachmentsDesc{}
	unsafe { vmemset(&ad, 0, int(sizeof(ad))) }
	ad.colors[0].image = f.scene_color
	if f.samples > 1 {
		ad.resolves[0].image = resolved
	}
	ad.depth_stencil.image = f.scene_depth
	f.scene = PostTarget{
		img: resolved
		att: gfx.make_attachments(&ad)
		w:   w
		h:   h
	}
	hw := if w / 2 > 0 { w / 2 } else { 1 }
	hh := if h / 2 > 0 { h / 2 } else { 1 }
	f.half_a = make_color_target(hw, hh, c'velo-post-half-a')
	f.half_b = make_color_target(hw, hh, c'velo-post-half-b')
	f.full_b = make_color_target(w, h, c'velo-post-full-b')
	f.w = w
	f.h = h
}

fn (f &PostFx) pass(t PostTarget, pip gfx.Pipeline, images []gfx.Image, u []f32) {
	mut action := gfx.PassAction{}
	action.colors[0].load_action = .dontcare
	mut p := gfx.Pass{}
	unsafe { vmemset(&p, 0, int(sizeof(p))) }
	p.action = action
	p.attachments = t.att
	gfx.begin_pass(&p)
	f.draw_fullscreen(pip, images, u)
	gfx.end_pass()
}

fn (f &PostFx) draw_fullscreen(pip gfx.Pipeline, images []gfx.Image, u []f32) {
	gfx.apply_pipeline(pip)
	mut b := gfx.Bindings{}
	unsafe { vmemset(&b, 0, int(sizeof(b))) }
	for i, img in images {
		b.fs.images[i] = img
		b.fs.samplers[i] = f.smp
	}
	gfx.apply_bindings(&b)
	mut data := []f32{len: post_uniform_count * 4}
	for i in 0 .. u.len {
		if i < data.len {
			data[i] = u[i]
		}
	}
	gfx.apply_uniforms(.fs, 0, &gfx.Range{
		ptr:  data.data
		size: usize(data.len * 4)
	})
	gfx.draw(0, 3, 1)
}

// post_armed: draw_scene found a PostProcess and the frame is drawn through the chain (see end_frame).
fn (mut r Renderer) arm_post(scene &core.Scene) {
	r.post_comp = unsafe { nil }
	if !r.postfx_enabled || postfx_env_off || scene == unsafe { nil }
		|| scene.root == unsafe { nil } {
		return
	}
	pp := find_post(scene.root) or { return }
	if !r.post.tried {
		r.post.tried = true
		r.post.init_shaders() or {
			eprintln('[render] post-processing off: ${err}')
			return
		}
		r.post.ok = true
	}
	if !r.post.ok {
		return
	}
	r.post_comp = pp
	r.post_time = f32(scene.real_time)
}

// end_frame finishes the frame: through the post-processing chain when the scene has a PostProcess, otherwise
// exactly as gg's ctx.end(). The app calls it instead of ctx.end().
pub fn (mut r Renderer) end_frame() {
	if r.post_comp == unsafe { nil } {
		r.ctx.end()
		return
	}
	pp := r.post_comp
	r.post_comp = unsafe { nil }
	w, h := sapp.width(), sapp.height()
	if w <= 0 || h <= 0 {
		r.ctx.end()
		return
	}
	mut f := &r.post
	f.ensure_targets(w, h)
	s := pp.settings()
	now := if pp.node != unsafe { nil } && pp.node.scene != unsafe { nil } {
		pp.node.scene.real_time
	} else {
		0
	}

	// optional shader pass: recorded as sokol_gl commands on its own layer, drawn on the window below
	mut shader_pip := ?sgl.Pipeline(none)
	if pp.shader_data != unsafe { nil } {
		if pip := r.pipeline_for(pp.shader_data) {
			shader_pip = pip
		}
	}
	if pip := shader_pip {
		r.record_shader_pass(pp, pip, w, h)
	}

	// 1. the world into the offscreen image
	bg := r.ctx.bg_color
	mut clear := gfx.PassAction{}
	clear.colors[0].load_action = .clear
	clear.colors[0].clear_value = gfx.Color{f32(bg.r) / 255, f32(bg.g) / 255, f32(bg.b) / 255, 1}
	mut scene_pass := gfx.Pass{}
	unsafe { vmemset(&scene_pass, 0, int(sizeof(scene_pass))) }
	scene_pass.action = clear
	scene_pass.attachments = f.scene.att
	gfx.begin_pass(&scene_pass)
	C.sgl_draw_layer(layer_world)
	gfx.end_pass()
	mut t0 := i64(0)
	if postfx_timing {
		f.timing.gpu_finish()
		t0 = time.sys_mono_now()
	}

	// 2. bloom at half resolution
	if s.bloom > 0 {
		f.pass(f.half_a, f.pip_bright, [f.scene.img], [1 / f32(w), 1 / f32(h), s.bloom_threshold,
			s.bloom_knee])
		tx, ty := s.bloom_radius / f32(f.half_a.w), s.bloom_radius / f32(f.half_a.h)
		f.pass(f.half_b, f.pip_blur, [f.half_a.img], [tx, 0])
		f.pass(f.half_a, f.pip_blur, [f.half_b.img], [f32(0), ty])
		if s.bloom_radius > 1.25 {
			// a second, wider round: a softer, larger glow
			f.pass(f.half_b, f.pip_blur, [f.half_a.img], [tx * 2, 0])
			f.pass(f.half_a, f.pip_blur, [f.half_b.img], [f32(0), ty * 2])
		}
	}

	// 3. composite (to the window, or to full_b when a shader pass follows)
	mut lut_img := f.half_b.img
	mut lut_size := 0
	if pp.lut_tex != unsafe { nil } && s.lut_strength > 0 {
		if img := r.image_for(pp.lut_tex) {
			if img.simg_ok && img.height > 1 && img.width == img.height * img.height {
				lut_img = img.simg
				lut_size = img.height
			}
		}
	}
	u := s.uniforms(r.post_time, w, h, lut_size, lut_size > 0, pp.flash_color, pp.flash_amount(now))
	inputs := [f.scene.img, f.half_a.img, lut_img]
	mut screen := gg_default_pass()
	if _ := shader_pip {
		f.pass(f.full_b, f.pip_comp_rt, inputs, u)
		gfx.begin_pass(&screen)
		C.sgl_draw_layer(layer_shader)
	} else {
		gfx.begin_pass(&screen)
		f.draw_fullscreen(f.pip_comp, inputs, u)
	}
	if postfx_timing {
		f.timing.gpu_finish()
		f.timing.add(time.sys_mono_now() - t0, w, h)
	}
	// 4. UI and overlays, untouched
	C.sgl_draw_layer(layer_ui)
	gfx.end_pass()
	gfx.commit()
}

fn gg_default_pass() gfx.Pass {
	mut action := gfx.PassAction{}
	action.colors[0].load_action = .dontcare
	return sapp.create_default_pass(action)
}

// record_shader_pass queues a fullscreen quad of full_b drawn with the PostProcess shader (sokol_gl layer 2).
fn (mut r Renderer) record_shader_pass(pp &PostProcess, pip sgl.Pipeline, w int, h int) {
	C.sgl_layer(layer_shader)
	sgl.matrix_mode_projection()
	sgl.push_matrix()
	sgl.load_identity()
	sgl.ortho(0, f32(w), f32(h), 0, -1, 1)
	sgl.matrix_mode_modelview()
	sgl.push_matrix()
	sgl.load_identity()
	sgl.scissor_rect(0, 0, w, h, true)
	sgl.load_pipeline(pip)
	sgl.matrix_mode_texture()
	sgl.push_matrix()
	sgl.load_matrix(shader_uniforms(r.post_time, f32(w), f32(h), pp.shader_params, pp.shader_color, [
		f32(0),
		0,
		1,
		1,
	]!))
	sgl.enable_texture()
	sgl.texture(r.post.full_b.img, r.post.smp)
	// GL images are stored bottom-up: the top of the screen is v = 1 there, v = 0 on Metal
	top, bottom := if gfx.query_backend() == .glcore33 || gfx.query_backend() == .gles3 {
		f32(1), f32(0)
	} else {
		f32(0), f32(1)
	}
	sgl.begin_quads()
	sgl.v2f_t2f_c4b(0, 0, 0, top, 255, 255, 255, 255)
	sgl.v2f_t2f_c4b(f32(w), 0, 1, top, 255, 255, 255, 255)
	sgl.v2f_t2f_c4b(f32(w), f32(h), 1, bottom, 255, 255, 255, 255)
	sgl.v2f_t2f_c4b(0, f32(h), 0, bottom, 255, 255, 255, 255)
	sgl.end()
	sgl.disable_texture()
	sgl.pop_matrix()
	sgl.matrix_mode_modelview()
	sgl.pop_matrix()
	sgl.matrix_mode_projection()
	sgl.pop_matrix()
	sgl.load_default_pipeline()
	C.sgl_layer(layer_ui)
}
