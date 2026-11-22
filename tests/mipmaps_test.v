import velo.render

fn px(m render.MipChain, offset int) []u8 {
	p := unsafe { &u8(m.data) + offset * 4 }
	return unsafe { [p[0], p[1], p[2], p[3]] }
}

fn test_chain_goes_down_to_one_texel() {
	mut img := []u8{len: 8 * 4 * 4, init: 255}
	m := render.build_mips(img.data, 8, 4)
	assert m.levels == 3 // 4x2, 2x1, 1x1
	w, h := render.mip_size(8, 4, 3)
	assert w == 1 && h == 1
	unsafe { free(m.data) }
}

fn test_transparent_texels_do_not_darken_edges() {
	// 2x2: one opaque red texel, three transparent black ones (a typical atlas edge)
	img := [u8(255), 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
	m := render.build_mips(img.data, 2, 2)
	assert m.levels == 1
	p := px(m, 0)
	assert p[0] == 255 && p[1] == 0 && p[2] == 0 // still red, not dark red
	assert p[3] == 64 // a quarter covered
	unsafe { free(m.data) }
}

fn test_odd_sizes_keep_the_last_column() {
	// 3x1: white, white, red -> 1x1 averages all three
	img := [u8(255), 255, 255, 255, 255, 255, 255, 255, 255, 0, 0, 255]
	m := render.build_mips(img.data, 3, 1)
	assert m.levels == 1 // 3x1 -> 1x1
	p := px(m, 0)
	assert p[0] == 255 && p[1] == 170 && p[2] == 170
	unsafe { free(m.data) }
}

fn test_one_texel_has_no_chain() {
	img := [u8(1), 2, 3, 4]
	m := render.build_mips(img.data, 1, 1)
	assert m.levels == 0 && m.data == unsafe { nil }
}
