module physics

import math
import velo.core
import velo.render

// TileMapCollider — static collision for the TileMap on the same node: solid cells become Box2D shapes on one
// static body (walls, floors, platforms), so a map needs no hand-placed colliders.
//
//   TileMap { ... }
//   TileMapCollider { solid_tiles = [0, 1, 2, 8]  friction = 0.8 }    # [] = every non-empty cell is solid
//
// Orthogonal maps merge solid cells into as few rectangles as possible (rows first, then equal runs stacked);
// isometric, staggered and hex maps get one convex shape per cell (its diamond / hexagon). Contacts arrive in
// `began` / `touching` / `ended` like any collider (the node is the map's node).
// Painting tiles at runtime: the shapes follow automatically (checked a few times per second), or call rebuild().
@[heap]
pub struct TileMapCollider {
	core.Component
	ColliderState
pub mut:
	solid_tiles []int // tileset frames that collide; [] = all non-empty cells
	friction    f32 = 0.6
	restitution f32
	sensor      bool
	shapes      int @[hide] // shapes created by the last build
	built_sum   u64 @[hide] // checksum of the tiles the shapes were built from
	check_timer f32 @[hide]
}

@[typedef]
struct C.b2Hull {
mut:
	points [8]C.b2Vec2
	count  int
}

fn C.b2ComputeHull(points &C.b2Vec2, count int) C.b2Hull
fn C.b2MakePolygon(hull &C.b2Hull, radius f32) C.b2Polygon

pub fn (mut t TileMapCollider) on_load() {
	t.build()
}

pub fn (mut t TileMapCollider) on_destroy() {
	t.detach()
}

pub fn (mut t TileMapCollider) update(dt f32) {
	t.check_timer -= dt
	if t.check_timer > 0 {
		return
	}
	t.check_timer = 0.25
	tm := t.node.get_component[render.TileMap]() or { return }
	if tiles_sum(tm) != t.built_sum {
		t.rebuild()
	}
}

// rebuild recreates the shapes from the current tiles.
pub fn (mut t TileMapCollider) rebuild() {
	t.detach()
	t.build()
}

// is_solid: the cell collides.
pub fn (t &TileMapCollider) is_solid(tm &render.TileMap, col int, row int) bool {
	f := render.tile_frame(tm.get(col, row))
	if f < 0 {
		return false
	}
	return t.solid_tiles.len == 0 || f in t.solid_tiles
}

fn tiles_sum(tm &render.TileMap) u64 {
	mut h := u64(1469598103934665603)
	for v in tm.tiles {
		h = (h ^ u64(u32(v))) * 1099511628211
	}
	return h ^ u64(tm.columns) << 32 ^ u64(tm.rows) << 48
}

fn (mut t TileMapCollider) build() {
	if t.has_shape || t.node == unsafe { nil } || t.node.scene == unsafe { nil } {
		return
	}
	tm := t.node.get_component[render.TileMap]() or { return }
	mut w := world_of(t.node) or {
		eprintln('[TileMapCollider] ${t.node.path()}: no PhysicsWorld on this node or its ancestors')
		return
	}
	t.built_sum = tiles_sum(tm)
	pos, rot := world_transform(t.node)
	mut def := C.b2DefaultBodyDef()
	def.@type = body_static
	def.position = w.to_b2(pos)
	def.rotation = b2rot(rot)
	body := C.b2CreateBody(w.id, &def)
	t.own_body = body
	t.owns_body = true
	t.synced_pos, t.synced_rot = pos, rot
	t.owner = t.node
	t.world = w
	sc := t.node.world_matrix().scale()
	scale := core.vec2(f32(math.abs(sc.x)), f32(math.abs(sc.y)))
	ppm := w.ppm()
	sdef := shape_def(&t.ColliderState, 1, t.friction, t.restitution, t.sensor)
	t.shapes = 0
	mut last := C.b2ShapeId{}
	if tm.tile_layout() == .orthogonal {
		for r in t.solid_rects(tm) {
			// r: col, row, cols, rows -> a box in node space
			x, y, _, _ := tm.cell_local_rect(r[0], r[1])
			cs := tm.cell_size()
			w2, h2 := f32(r[2]) * cs.x / 2, f32(r[3]) * cs.y / 2
			center := core.vec2((x + w2) * scale.x, (y + h2) * scale.y).mul(1 / ppm)
			poly := C.b2MakeOffsetBox(w2 * scale.x / ppm, h2 * scale.y / ppm, b2vec(center), b2rot(0))
			last = C.b2CreatePolygonShape(body, &sdef, &poly)
			t.shapes++
		}
	} else {
		for row in 0 .. tm.rows {
			for col in 0 .. tm.columns {
				if !t.is_solid(tm, col, row) {
					continue
				}
				pts := tm.cell_polygon(col, row)
				if pts.len < 3 || pts.len > 8 {
					continue
				}
				mut b := [8]C.b2Vec2{}
				for i, p in pts {
					b[i] = b2vec(core.vec2(p.x * scale.x, p.y * scale.y).mul(1 / ppm))
				}
				hull := C.b2ComputeHull(&b[0], pts.len)
				if hull.count < 3 {
					continue
				}
				poly := C.b2MakePolygon(&hull, 0)
				last = C.b2CreatePolygonShape(body, &sdef, &poly)
				t.shapes++
			}
		}
	}
	t.shape_id = last
	t.has_shape = true // the body owns every shape; detach destroys the body and with it all of them
	w.colliders << &t.ColliderState
}

// solid_rects: orthogonal maps, solid cells merged into rectangles [col, row, cols, rows]: horizontal runs per
// row, then runs with the same span on consecutive rows stacked into one.
pub fn (t &TileMapCollider) solid_rects(tm &render.TileMap) [][]int {
	mut open := map[string][]int{} // "col,len" -> rect still growing downward
	mut out := [][]int{}
	for row in 0 .. tm.rows {
		mut runs := map[string]bool{}
		mut col := 0
		for col < tm.columns {
			if !t.is_solid(tm, col, row) {
				col++
				continue
			}
			start := col
			for col < tm.columns && t.is_solid(tm, col, row) {
				col++
			}
			key := '${start},${col - start}'
			runs[key] = true
			if mut r := open[key] {
				r[3]++
				open[key] = r
			} else {
				open[key] = [start, row, col - start, 1]
			}
		}
		for key in open.keys() {
			if key !in runs {
				out << open[key]
				open.delete(key)
			}
		}
	}
	for _, r in open {
		out << r
	}
	return out
}

pub fn (t &TileMapCollider) debug_outline() []core.Vec2 {
	tm := t.node.get_component[render.TileMap]() or { return []core.Vec2{} }
	return tm.debug_outline()
}

pub fn (t &TileMapCollider) debug_color() core.Color {
	return outline_color(t.sensor)
}
