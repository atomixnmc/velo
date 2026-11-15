module main

import os
import velo.app
import velo.core
import velo.render

// Gothic UI kit (tools/gen_gothic_ui.py) with the engine's UI features: sliced panels in three tiers whose
// borders and ornaments never stretch, buttons with hover / pressed / disabled images, glow and press scale,
// icon + text groups centred by a Layout (Label.auto_size), optically centred text, a ScrollView with a scroll
// bar, and a Mask.
//   python examples/ui_gothic/make_scene.py   regenerate the kit and the scene (--palette royal|emerald|bone)
//   v -cc gcc run examples/ui_gothic             kit, panels, buttons, scroll view, mask
//   v -cc gcc run examples/ui_gothic --widgets   sliders, radio group, drag and drop, form, health bar
fn main() {
	mut game := app.new(
		title:         'Velo Engine — gothic UI'
		assets_dir:    os.join_path(os.dir(@FILE), 'assets')
		scene:         if '--widgets' in os.args {
			'scenes/widgets.scene'
		} else {
			'scenes/ui.scene'
		}
		width:         1280
		height:        720
		window_width:  1280
		window_height: 720
	) or {
		eprintln(err)
		exit(1)
	}
	game.register[UiDemo]()
	game.register[WidgetsDemo]()
	game.run()
}

// UiDemo prints button clicks; VELO_UI_SCROLL=1 scrolls the list by itself (for captures).
pub struct UiDemo {
	core.Component
pub mut:
	t f32 @[hide]
}

pub fn (mut d UiDemo) start() {
	for name in ['Buttons/Play', 'Buttons/Continue', 'Buttons/Options', 'Buttons/Locked'] {
		n := d.node.find(name) or { continue }
		if mut b := n.get_component[render.Button]() {
			b.on_click(fn (mut b render.Button) {
				println('[ui] clicked ${b.node.name}')
			})
		}
	}
}

pub fn (mut d UiDemo) update(dt f32) {
	d.t += dt
	if os.getenv('VELO_UI_SCROLL') == '1' && d.t > 1 {
		mut c := d.node.find('Panel_medium/List/Content') or { return }
		c.position.y -= 40 * dt
	}
}

// WidgetsDemo wires the widgets scene: Space damages the health bar, "Lock settings" disables and dims the
// settings panel (UIGroup), the form prints its values on submit and shows its first error otherwise,
// dropped runes are logged.
pub struct WidgetsDemo {
	core.Component
}

pub fn (mut d WidgetsDemo) start() {
	if lock_node := d.node.find('Lock') {
		if mut b := lock_node.get_component[render.Button]() {
			b.on_click(fn (mut b render.Button) {
				settings := b.node.parent.find('Settings') or { return }
				if mut g := settings.get_component[render.UIGroup]() {
					g.interactable = !g.interactable
					g.alpha = if g.interactable { f32(1) } else { f32(0.55) }
				}
				if t := b.node.find('T') {
					if mut l := t.get_component[render.Label]() {
						l.text = if l.text == 'Lock settings' {
							'Unlock settings'
						} else {
							'Lock settings'
						}
					}
				}
			})
		}
	}
	if form_node := d.node.find('Signup') {
		if mut f := form_node.get_component[render.Form]() {
			f.on_submit(fn (mut f render.Form) {
				println('[form] submitted ${f.values()}')
			})
		}
	}
	for i in 0 .. 3 {
		if slot := d.node.find('Board/Slot${i}') {
			if mut z := slot.get_component[render.DropZone]() {
				z.on_drop(fn (mut z render.DropZone, mut d render.Draggable) {
					println('[drop] ${d.data} -> ${z.node.name}')
				})
			}
		}
	}
}

pub fn (mut d WidgetsDemo) update(dt f32) {
	inp := d.input()
	if inp.was_pressed(.space) {
		if mut n := d.node.find('Health') {
			if mut p := n.get_component[render.ProgressBar]() {
				p.progress = if p.progress <= 0.15 { f32(1) } else { p.progress - 0.2 }
			}
		}
	}
	if form_node := d.node.find('Signup') {
		f := form_node.get_component[render.Form]() or { return }
		if mut e := d.node.find('Signup/Error') {
			if mut l := e.get_component[render.Label]() {
				mut msg := ''
				for name, err in f.errors {
					msg = '${name}: ${err}'
					break
				}
				l.text = msg
			}
		}
	}
}
