import velo.core
import velo.physics
import velo.render

// Per-tile flips, animated tiles, autotiling and TileMapCollider (no GPU; Box2D runs headless).

fn grid(layout string, cols int, rows int, tiles []int) &render.TileMap {
	return &render.TileMap{
		columns:   cols
		rows:      rows
		tile_size: if layout == 'orthogonal' { core.vec2(16, 16) } else { core.vec2(64, 32) }
		layout:    layout
		tiles:     tiles
	}
}

fn test_flip_bits_keep_the_frame() {
	t := 5 | render.tile_flip_x | render.tile_transpose
	assert render.tile_frame(t) == 5
	assert render.tile_frame(-1) == -1
	assert render.rotated_tile(7, 1) == 7 | render.tile_transpose | render.tile_flip_x
	assert render.rotated_tile(7, 4) == 7
	assert render.rotated_tile(7, -1) == render.rotated_tile(7, 3)
}

fn test_flipped_uvs() {
	plain := render.tile_uvs(3, 0, 0, 1, 1)
	assert plain == [f32(0), 0, 1, 0, 1, 1, 0, 1]!
	fx := render.tile_uvs(3 | render.tile_flip_x, 0, 0, 1, 1)
	assert fx == [f32(1), 0, 0, 0, 0, 1, 1, 1]!
	// a quarter turn clockwise: the top-left corner shows the texture's bottom-left
	cw := render.tile_uvs(render.rotated_tile(3, 1), 0, 0, 1, 1)
	assert cw[0] == 0 && cw[1] == 1
	assert cw[2] == 0 && cw[3] == 0
}

fn test_animated_tiles() {
	mut tm := grid('orthogonal', 2, 1, [4, 9])
	tm.animations = [4, 3, 10] // frames 4, 5, 6 at 10 fps
	assert tm.animated_frame(4, 0) == 4
	assert tm.animated_frame(4, 0.15) == 5
	assert tm.animated_frame(4, 0.25) == 6
	assert tm.animated_frame(4, 0.31) == 4
	assert tm.animated_frame(9, 0.15) == 9 // not an animation start
}

fn test_autotile_edge_set() {
	mut tm := grid('orthogonal', 3, 3, []int{len: 9, init: -1})
	base := 16
	tm.paint_terrain(1, 1, base)
	assert tm.get(1, 1) == base // an island
	tm.paint_terrain(2, 1, base)
	assert tm.get(1, 1) == base + 2 // east neighbour
	assert tm.get(2, 1) == base + 8 // west neighbour
	tm.paint_terrain(1, 0, base)
	assert tm.get(1, 1) == base + 2 + 1
	assert tm.get(1, 0) == base + 4
	tm.paint_terrain(1, 0, -1)
	assert tm.get(1, 0) == -1
	assert tm.get(1, 1) == base + 2
	// fill from code, then fix every cell at once
	mut big := grid('orthogonal', 3, 3, []int{len: 9, init: 16})
	big.autotile_all(16)
	assert big.get(1, 1) == 16 + 15
	assert big.get(0, 0) == 16 + 2 + 4
	// isometric uses the same four edges, staggered its own
	mut iso := grid('isometric', 2, 2, [16, 16, -1, -1])
	iso.autotile_all(16)
	assert iso.get(0, 0) == 16 + 2 && iso.get(1, 0) == 16 + 8
	mut st := grid('staggered', 2, 2, [16, -1, 16, -1])
	assert st.edge_neighbors(0, 1).len == 4
	st.autotile_all(16)
	assert st.get(0, 1) != 16 // row 1 is shifted: (0, 1) touches (0, 0)
	assert grid('hex_flat', 2, 2, []).edge_neighbors(0, 0).len == 0
}

fn test_solid_cells_merge_into_rectangles() {
	// 4x3:   X X X X
	//        X . . X
	//        X . . X
	tm := grid('orthogonal', 4, 3, [1, 1, 1, 1, 1, -1, -1, 1, 1, -1, -1, 1])
	c := physics.TileMapCollider{}
	rects := c.solid_rects(tm)
	mut area := 0
	for r in rects {
		area += r[2] * r[3]
	}
	assert area == 8
	assert rects.len == 3 // the top row, and the two side columns below it
	only := physics.TileMapCollider{
		solid_tiles: [2]
	}
	assert only.solid_rects(tm).len == 0
}

fn test_body_lands_on_a_tile_floor() {
	mut scene := core.Scene.new('test')
	scene.root.add_component(&physics.PhysicsWorld{
		gravity: core.vec2(0, 980)
	})
	mut ground := core.Node.new('Ground')
	ground.position = core.vec2(-80, 200) // the map's top-left corner
	ground.add_component(grid('orthogonal', 10, 2, []int{len: 10, init: -1}))
	mut tm := ground.get_component[render.TileMap]() or { panic('no map') }
	tm.tiles << []int{len: 10, init: 3} // row 1 is the floor: y 216 .. 232
	col := ground.add_component(&physics.TileMapCollider{})
	scene.add(mut ground)
	assert col.shapes == 1 // one merged rectangle

	mut box := core.Node.new('Box')
	box.add_component(&physics.BoxCollider{
		size: core.vec2(10, 10)
	})
	box.add_component(&physics.RigidBody{})
	scene.add(mut box)
	for _ in 0 .. 180 {
		scene.update(1.0 / 60.0)
	}
	assert box.position.y > 205 && box.position.y < 215 // resting on y = 216
	assert col.is_touching(box)
}

fn test_isometric_cells_become_diamonds() {
	mut scene := core.Scene.new('test')
	scene.root.add_component(&physics.PhysicsWorld{})
	mut n := core.Node.new('Iso')
	n.add_component(grid('isometric', 3, 3, [1, -1, 1, -1, 1, -1, 1, -1, 1]))
	col := n.add_component(&physics.TileMapCollider{})
	scene.add(mut n)
	assert col.shapes == 5
}
