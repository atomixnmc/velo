module main

import os
import velo.app
import velo.assets
import velo.kine2d
import velo.core
import velo.render

// Built-in sprite effects showcase: every SpriteFx effect on a sprite (render/effects.v).
//   v -cc gcc run examples/effects               the effects
//   v -cc gcc run examples/effects --imported    particle effects converted from Unity / Godot by
//                                                tools/import_assets.py (from tests/fixtures/import)
//   VELO_FX_SPINE=<folder with name.json + name.atlas + pages>   also shows a Spine 4.2 rig with six effects
fn main() {
	mut game := app.new(
		title:         'Velo Engine — sprite effects'
		assets_dir:    os.join_path(os.dir(@FILE), 'assets')
		scene:         if '--imported' in os.args { 'scenes/imported.scene' } else { 'scenes/effects.scene' }
		window_width:  1280
		window_height: 720
	) or {
		eprintln(err)
		exit(1)
	}
	game.register[FxDemo]()
	game.register[BurstReplay]()
	game.register[SpineFxDemo]()
	game.run()
}

// FxDemo replays its node's effect: dissolve out and back in, or a hit flash every second.
pub struct FxDemo {
	core.Component
pub mut:
	timer f32 @[hide]
}

pub fn (mut d FxDemo) update(dt f32) {
	d.timer -= dt
	if d.timer > 0 {
		return
	}
	mut fx := d.node.get_component[render.SpriteFx]() or { return }
	if fx.effect == 'dissolve' {
		back := fx.amount > 0.5
		fx.play('dissolve', if back { f32(1) } else { f32(0) }, if back { f32(0) } else { f32(1) }, 1.2)
		d.timer = 1.6
	} else {
		fx.flash(core.rgba(255, 255, 255, 255), 0.35)
		d.timer = 1.0
	}
}

// BurstReplay restarts the one-shot emitters of the scene every 1.5 s (the converted Godot burst).
pub struct BurstReplay {
	core.Component
pub mut:
	timer f32 @[hide]
}

pub fn (mut b BurstReplay) update(dt f32) {
	b.timer -= dt
	if b.timer > 0 {
		return
	}
	b.timer = 1.5
	mut root := b.node.scene.root
	replay(mut root)
}

fn replay(mut n core.Node) {
	for mut ps in n.get_components[render.ParticleSystem]() {
		if !ps.looping {
			ps.play()
		}
	}
	for mut ch in n.children {
		replay(mut ch)
	}
}

// SpineFxDemo: with VELO_FX_SPINE set, mounts that Spine 4.2 pack and shows it with several SpriteFx effects
// (the effect runs per attachment, see render/effects.v).
pub struct SpineFxDemo {
	core.Component
}

pub fn (mut d SpineFxDemo) start() {
	dir := os.getenv('VELO_FX_SPINE')
	if dir == '' {
		return
	}
	name := os.file_name(dir).all_before('__')
	mut db := d.node.scene.assets
	db.mount('spinefx', dir) or {
		eprintln('[effects] ${err}')
		return
	}
	looks := [['outline', '3', '0', '255,220,90'], ['dissolve', '0.5', '0.12', '255,120,30'],
		['hologram', '40', '1', '80,220,255'], ['frozen', '0.8', '0', '150,210,255'],
		['tint_black', '1', '0', '90,0,140'], ['flash', '0.7', '0', '255,255,255']]
	for i, l in looks {
		mut n := core.Node.new('Spine_${l[0]}')
		n.position = core.vec2(120 + f32(i) * 145, 520)
		n.scale = core.vec2(0.35, 0.35)
		n.add_component(&kine2d.Kine2D{
			data:  assets.ref[assets.TextAsset]('spinefx/${name}.json')
			atlas: assets.ref[assets.TextAsset]('spinefx/${name}.atlas')
		})
		c := l[3].split(',').map(u8(it.int()))
		n.add_component(&render.SpriteFx{
			effect: l[0]
			amount: l[1].f32()
			width:  l[2].f32()
			color:  core.rgba(c[0], c[1], c[2], 255)
		})
		if l[0] in ['dissolve', 'flash'] {
			n.add_component(&FxDemo{})
		}
		d.node.add_child(mut n)
	}
}
