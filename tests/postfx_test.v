import os
import velo.core
import velo.assets
import velo.serialize
import velo.render

fn test_post_sources_for_every_backend() {
	for lang in [render.ShaderLang.glsl410, .glsl300es, .msl] {
		vs, fs :=
			render.post_sources('vec4 post_main(vec2 uv) { return tex0(uv) * U[0]; }', 3, lang)
		assert vs.contains('vertex') || vs.contains('gl_VertexID')
		assert fs.contains('post_main')
		assert fs.contains('tex2')
	}
	_, gl := render.post_sources('vec4 post_main(vec2 uv) { return tex0(uv); }', 1, .glsl410)
	assert gl.contains('uniform sampler2D tex0_smp;') && !gl.contains('tex1_smp')
	assert gl.contains('uniform vec4 fs_u[12];')
	_, msl := render.post_sources('vec4 post_main(vec2 uv) { return tex0(uv); }', 2, .msl)
	assert msl.contains('texture2d<float> t1 [[texture(1)]]')
		&& msl.contains('return e.post_main(in.uv);')
}

fn test_every_preset_resolves() {
	for name in render.post_presets {
		s := render.post_preset(name)
		assert s.exposure > 0 && s.gamma > 0
	}
	assert render.post_preset('none').bloom == 0
	assert render.post_preset('gothic_night').bloom > 0
	assert render.post_preset('nope') == render.post_preset('none')
}

fn test_overrides_replace_the_preset() {
	mut p := render.PostProcess{
		preset:   'gothic_night'
		bloom:    2.5
		vignette: 0
		gain:     core.rgba(255, 128, 0, 255)
	}
	s := p.settings()
	base := render.post_preset('gothic_night')
	assert s.bloom == 2.5
	assert s.vignette == 0
	assert s.contrast == base.contrast // not overridden
	assert s.gain[0] == 1 && s.gain[2] == 0
	u := s.uniforms(1, 1920, 1080, 0, false, core.rgba(255, 0, 0, 255), 0.5)
	assert u.len == 48
	assert u[2] == 2.5 && u[3] == 1 // bloom intensity, on
	assert u[35] == 0.5 // flash amount
}

fn test_flash_fades_out() {
	mut p := render.PostProcess{}
	p.flash(core.rgba(255, 255, 255, 255), 1)
	assert p.flash_amount(0) == 1
	assert p.flash_amount(0.5) > 0 && p.flash_amount(0.5) < 1
	assert p.flash_amount(1.5) == 0
}

fn test_example_scene_loads_with_a_post_process() {
	dir := os.join_path(@VMODROOT, 'examples', 'postfx', 'assets')
	mut db := assets.open(dir) or { panic(err) }
	mut reg := serialize.new_registry()
	render.register_builtins(mut reg)
	reg.register[PostFxShowcase]()
	mut loader := serialize.new_loader(reg, db)
	mut s := loader.load_scene('scenes/postfx.scene') or { panic(err) }
	pp := render.find_post(s.root) or { panic('no PostProcess') }
	assert pp.preset == 'gothic_night'
	assert pp.settings().bloom > 0
}

// stands in for the example's PostFxShowcase component
pub struct PostFxShowcase {
	core.Component
}

fn test_colour_overrides_default_to_the_preset() {
	p := render.PostProcess{
		preset: 'gothic_night'
	}
	assert p.settings() == render.post_preset('gothic_night')
}
