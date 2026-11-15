module main

import os
import velo.app
import velo.assets
import velo.core
import velo.render

// Post-processing showcase: the scene has a PostProcess component; this cycles its presets.
//   v -cc gcc run examples/postfx
//   VELO_POSTFX_AUTO=2 cycles the presets every 2 s (with a flash on `flash`), for captures and timing.
//   VELO_POSTFX=0 turns post-processing off (as a low-end device would), VELO_PROFILE=1 prints frame times.
fn main() {
	mut game := app.new(
		title:         'Velo Engine — post-processing'
		assets_dir:    os.join_path(os.dir(@FILE), 'assets')
		scene:         'scenes/postfx.scene'
		window_width:  1280
		window_height: 720
	) or {
		eprintln(err)
		exit(1)
	}
	game.register[PostFxShowcase]()
	game.run()
}

// the presets shown, in key order (1-9); 'flash' is the 'none' preset with a looping flash
const showcase = ['gothic_night', 'gothic_day', 'bloom', 'grade', 'vignette', 'chromatic', 'grain',
	'flash', 'cinematic']

pub struct PostFxShowcase {
	core.Component
pub mut:
	index       int
	timer       f32
	flash_timer f32
	auto        f32 = f32(os.getenv('VELO_POSTFX_AUTO').f64()) @[hide]
}

fn (mut s PostFxShowcase) post() ?&render.PostProcess {
	return s.node.scene.root.get_component[render.PostProcess]() // on the root in this scene
}

fn (mut s PostFxShowcase) select(i int) {
	s.index = (i + showcase.len) % showcase.len
	s.timer = 0
	name := showcase[s.index]
	if mut pp := s.post() {
		pp.preset = if name == 'flash' { 'none' } else { name }
		if name == 'flash' {
			pp.flash(core.rgba(255, 240, 200, 230), 0.6)
		}
	}
	if n := s.node.find('Name') {
		if mut l := n.get_component[render.Label]() {
			l.text = '${s.index + 1}  ${name}'
		}
	}
	println('[postfx] preset ${name}')
}

pub fn (mut s PostFxShowcase) start() {
	s.select(0)
}

pub fn (mut s PostFxShowcase) update(dt f32) {
	inp := s.input()
	for i in 0 .. showcase.len {
		if inp.was_pressed(unsafe { core.Key(int(core.Key._1) + i) }) {
			s.select(i)
		}
	}
	if inp.was_pressed(.space) {
		s.select(s.index + 1)
	}
	if inp.was_pressed(.p) {
		if mut pp := s.post() {
			pp.enabled = !pp.enabled // disabled: the scene draws straight to the window
			println('[postfx] post-processing ${if pp.enabled { 'on' } else { 'off' }}')
		}
	}
	s.timer += dt
	s.flash_timer += dt
	if mut pp := s.post() {
		if inp.was_pressed(.f) || (showcase[s.index] == 'flash' && s.flash_timer > 1.0) {
			pp.flash(core.rgba(255, 240, 200, 230), 0.6)
			s.flash_timer = 0
		}
		if inp.was_pressed(.s) {
			pp.set_shader(if pp.shader.is_set() {
				assets.AssetRef[assets.Shader]{}
			} else {
				assets.ref[assets.Shader]('6c0f7e11')
			})
			if pp.shader.is_set() {
				pp.shader_params = core.vec2(3, 2)
			}
		}
	}
	if s.auto > 0 && s.timer >= s.auto {
		s.select(s.index + 1)
	}
}
