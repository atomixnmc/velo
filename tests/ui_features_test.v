import os
import time
import velo.core
import velo.assets
import velo.serialize
import velo.render

// Button state images / glow / scale, ornament slicing, 'fit' sprites, label padding, scroll bars, Mask.

fn png_header(path string, w int, h int) {
	os.write_file_array(path, [u8(0x89), `P`, `N`, `G`, 13, 10, 26, 10, 0, 0, 0, 13, `I`, `H`,
		`D`, `R`, 0, 0, u8(w >> 8), u8(w), 0, 0, u8(h >> 8), u8(h)]) or { panic(err) }
}

fn load(scene_text string) (&core.Scene, string) {
	dir := os.join_path(os.temp_dir(), 'velo_ui_features_${time.now().unix_micro()}')
	os.mkdir_all(dir) or { panic(err) }
	for name in ['plate', 'plate_hover', 'plate_pressed'] {
		png_header(os.join_path(dir, '${name}.png'), 120, 40)
		os.write_file(os.join_path(dir, '${name}.png.meta'), 'id: ${name}\nkind: texture\n') or {
			panic(err)
		}
	}
	png_header(os.join_path(dir, 'wide.png'), 200, 100)
	os.write_file(os.join_path(dir, 'wide.png.meta'), 'id: wide\nkind: texture\n') or { panic(err) }
	os.write_file(os.join_path(dir, 'ui.scene'), scene_text) or { panic(err) }
	mut db := assets.open(dir) or { panic(err) }
	mut reg := serialize.new_registry()
	render.register_builtins(mut reg)
	mut loader := serialize.new_loader(reg, db)
	s := loader.load_scene('ui.scene') or { panic(err) }
	return s, dir
}

fn frames(mut s core.Scene, n int) {
	for _ in 0 .. n {
		s.update(0.016)
		s.input.end_frame()
	}
}

fn test_button_state_images_glow_and_scale() {
	mut s, dir := load('node Root {
  node Btn {
    position = [100, 100]
    UITransform { size = [120, 40] }
    Sprite { texture = @asset("plate") }
    Button { hover_sprite = @asset("plate_hover")  pressed_sprite = @asset("plate_pressed")  hover_scale = 1.1  pressed_scale = 0.9  hover_glow = [255, 200, 100, 80] }
  }
}')
	defer {
		os.rmdir_all(dir) or {}
	}
	btn := s.find('Btn') or { panic('no Btn') }
	sp := btn.get_component[render.Sprite]() or { panic('no sprite') }
	b := btn.get_component[render.Button]() or { panic('no button') }
	frames(mut s, 2)
	assert sp.texture.id == 'plate' && b.state == 'normal'
	// hover: its image, the glow, growing to 1.1
	s.input.mouse = core.vec2(100, 100)
	frames(mut s, 60)
	assert b.state == 'hover'
	assert sp.texture.id == 'plate_hover' && sp.tex != unsafe { nil }
	assert sp.glow.a == 80
	assert btn.scale.x > 1.09 && btn.scale.x <= 1.1
	// pressed
	s.input.mouse_press()
	frames(mut s, 60)
	assert sp.texture.id == 'plate_pressed'
	assert btn.scale.x < 0.91
	// release outside: back to normal, no glow, scale 1
	s.input.mouse = core.vec2(400, 400)
	s.input.mouse_release()
	frames(mut s, 60)
	assert b.state == 'normal'
	assert sp.texture.id == 'plate' && sp.glow.a == 0
	assert btn.scale.x > 0.999 && btn.scale.x < 1.001
	// disabled without a disabled image keeps the normal one
	mut bb := btn.get_component[render.Button]() or { panic('no button') }
	bb.interactable = false
	frames(mut s, 2)
	assert b.state == 'disabled' && sp.texture.id == 'plate'
}

fn test_ornament_keeps_its_size_and_fit_keeps_aspect() {
	mut s, dir := load('node Root {
  node Panel {
    Sprite { texture = @asset("wide")  draw_mode = "sliced"  size = [400, 100]  border_left = 20  border_right = 20  border_top = 10  border_bottom = 10  ornament_x = [80, 120] }
  }
  node Icon {
    Sprite { texture = @asset("wide")  draw_mode = "fit"  size = [100, 100] }
  }
}')
	defer {
		os.rmdir_all(dir) or {}
	}
	p := s.find('Panel') or { panic('no Panel') }
	sp := p.get_component[render.Sprite]() or { panic('no sprite') }
	quads := sp.quads()
	// the ornament column: texture x 80..120 shown 40 wide, centred in the 400 wide sprite
	mut found := false
	for q in quads {
		if q.u0 == 80 && q.u1 == 120 {
			found = true
			assert q.w == 40
			assert q.x + q.w / 2 == 0 // centred (anchor 0.5)
		}
	}
	assert found
	// 3 columns + ornament split = 5 columns x 3 rows
	assert quads.len == 15
	ic := s.find('Icon') or { panic('no Icon') }
	isp := ic.get_component[render.Sprite]() or { panic('no sprite') }
	fq := isp.quads()
	assert fq.len == 1
	assert fq[0].w == 100 && fq[0].h == 50 // 200 x 100 fitted into 100 x 100
	assert fq[0].y == -25
}

fn test_label_padding_and_offset() {
	mut n := core.Node.new('L').with(&render.UITransform{
		size: core.vec2(200, 60)
	})
	l := n.add_component(&render.Label{
		text:    'x'
		align:   'left'
		valign:  'top'
		padding: core.vec2(10, 6)
		offset:  core.vec2(0, 3)
	})
	assert l.text_point() == core.vec2(-90, -21)
}

fn test_scroll_bars_and_mask() {
	mut s, dir := load('node Root {
  node List {
    UITransform { size = [100, 100] }
    ScrollView { }
    Mask { }
    node Content { UITransform { size = [100, 400]  anchor = [0.5, 0] }  position = [0, -50] }
  }
}')
	defer {
		os.rmdir_all(dir) or {}
	}
	list := s.find('List') or { panic('no List') }
	mut sv := list.get_component[render.ScrollView]() or { panic('no scroll view') }
	track, thumb := sv.scrollbar_rects(1) or { panic('no vertical bar') }
	assert track.h == 96
	assert thumb.h == 25 // the view is 100 / 400 of the content: a quarter of the view (at least 24)
	assert thumb.y == track.y // at the top
	if _, _ := sv.scrollbar_rects(0) {
		assert false // not horizontal
	}
	assert sv.scrollbar_alpha() == 1
	frames(mut s, 120) // idle for 2 s: auto-hidden
	assert sv.scrollbar_alpha() == 0
	assert list.get_component[render.Mask]() != none
}
