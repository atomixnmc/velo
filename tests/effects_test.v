import velo.core
import velo.render

fn test_every_builtin_effect_has_source() {
	for name in render.sprite_effects {
		if name == 'none' {
			assert render.effect_source(name) == none
			continue
		}
		src := render.effect_source(name) or { panic('no source for ${name}') }
		assert src.contains('vec4 effect(vec4 color, vec2 uv)')
		assert name in render.effect_docs
	}
}

fn test_one_uber_shader_holds_every_effect() {
	src := render.uber_effect_source()
	for i, name in render.sprite_effects {
		if name == 'none' {
			continue
		}
		assert src.contains('vec4 fx_${name}(vec4 color, vec2 uv)')
		assert src.contains('if (id == ${i}) { return fx_${name}(color, uv); }')
	}
	assert src.count('vec4 effect(vec4 color, vec2 uv)') == 1
	a := render.builtin_effect('outline') or { panic('none') }
	b := render.builtin_effect('dissolve') or { panic('none') }
	assert a.id == 'velo:fx' && a == b // one shader, so one pipeline for all effects
	assert render.builtin_effect('nope') == none
	// it compiles as every backend's wrapper (text level)
	for lang in [render.ShaderLang.glsl410, .glsl300es, .msl] {
		_, fs := render.shader_sources(src, lang)!
		assert fs.contains('fx_hologram')
	}
}

fn test_effect_index_matches_the_list() {
	assert render.effect_index('none') == 0
	assert render.effect_index('outline') == render.sprite_effects.index('outline')
	assert render.effect_index('unknown') == 0
}

fn test_flash_returns_to_the_previous_effect() {
	mut fx := render.SpriteFx{
		effect: 'outline'
		amount: 2
		color:  core.rgba(255, 220, 0, 255)
	}
	fx.flash(core.rgba(255, 255, 255, 255), 0.2)
	assert fx.effect == 'flash' && fx.amount == 1
	fx.update(0.1)
	assert fx.amount > 0.4 && fx.amount < 0.6
	fx.update(0.2)
	assert fx.effect == 'outline' && fx.amount == 2 && fx.color == core.rgba(255, 220, 0, 255)
}

fn test_play_animates_amount_and_padding() {
	mut fx := render.SpriteFx{
		effect: 'none'
	}
	if _ := fx.shader() {
		assert false
	}
	fx.play('dissolve', 0, 1, 1)
	fx.update(0.5)
	assert fx.effect == 'dissolve' && fx.amount == 0.5
	fx.update(1)
	assert fx.amount == 1
	o := render.SpriteFx{
		effect: 'outline'
		amount: 2.5
	}
	assert o.padding() == 4
	assert render.SpriteFx{
		effect: 'greyscale'
	}.padding() == 0
	fx.clear()
	assert fx.effect == 'none'
}

fn test_particle_mid_colour_and_frames() {
	ps := render.ParticleSystem{
		start_color:   core.rgba(0, 0, 0, 0)
		mid_color:     core.rgba(255, 255, 255, 255)
		end_color:     core.rgba(0, 0, 0, 0)
		use_mid_color: true
		mid_time:      0.25
	}
	assert ps.color_at(0) == core.rgba(0, 0, 0, 0)
	assert ps.color_at(0.25) == core.rgba(255, 255, 255, 255)
	assert ps.color_at(1) == core.rgba(0, 0, 0, 0)
	assert ps.color_at(0.625).a > 120 && ps.color_at(0.625).a < 135
}
