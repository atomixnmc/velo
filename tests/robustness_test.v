import os
import time
import velo.core
import velo.audio
import velo.webp

// Save data safety, node lifecycle, input focus loss, damaged files.

fn tmp_dir(name string) string {
	d := os.join_path(os.temp_dir(), 'velo_robust_${name}_${time.now().unix_micro()}')
	os.mkdir_all(d) or { panic(err) }
	return d
}

fn test_save_keeps_a_backup_and_replaces_in_one_step() {
	dir := tmp_dir('save')
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'save.txt')
	mut s := core.Store.open(path)
	s.set_int('coins', 10)
	s.save()!
	s.set_int('coins', 20)
	s.save()! // replaces an existing file (os.mv could not on Windows)
	assert core.Store.open(path).get_int('coins', 0) == 20
	assert os.is_file(path + '.bak') && !os.exists(path + '.tmp')
	assert core.Store.open(path + '.bak').get_int('coins', 0) == 10
}

fn test_crash_during_save_recovers_from_tmp() {
	dir := tmp_dir('tmp')
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'save.txt')
	// the new save was written to .tmp, then the game died before the replace (and the main file is gone)
	os.write_file(path + '.tmp', 'coins = 77\n')!
	s := core.Store.open(path)
	assert s.get_int('coins', 0) == 77 && s.dirty // written back as the main file on the next save
}

fn test_damaged_save_keeps_good_lines_and_a_copy() {
	dir := tmp_dir('bad')
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'save.txt')
	os.write_file(path, 'coins = 5\ngarbage here\nname = "Kael"\n')!
	s := core.Store.open(path)
	assert s.get_int('coins', 0) == 5 && s.get_string('name', '') == 'Kael'
	copies := os.ls(dir)!.filter(it.starts_with('save.txt.corrupt-'))
	assert copies.len == 1 // the damaged file is kept before anything can overwrite it
	// a file that is entirely unreadable falls back to the previous save
	os.write_file(path, 'not a save file')!
	os.write_file(path + '.bak', 'coins = 4\n')!
	s2 := core.Store.open(path)
	assert s2.get_int('coins', 0) == 4
}

@[heap]
struct Log {
mut:
	lines []string
}

struct Life {
	core.Component
mut:
	log &Log
}

pub fn (mut l Life) on_destroy() {
	mut lg := l.log
	lg.lines << '${l.node.name}:${l.node.scene != unsafe { nil }}'
}

fn test_parent_and_child_destroyed_together_run_on_destroy_once() {
	mut s := core.Scene.new('T')
	mut log := &Log{}
	mut p := core.Node.new('P')
	p.add_component(&Life{
		log: log
	})
	mut c := core.Node.new('C')
	c.add_component(&Life{
		log: log
	})
	p.add_child(mut c)
	s.add(mut p)
	p.destroy()
	c.destroy()
	s.flush_destroyed()
	assert log.lines.len == 2
	assert 'C:true' in log.lines && 'P:true' in log.lines // once each, with the scene still set
}

@[heap]
struct Runs {
mut:
	n int
}

struct SelfRemover {
	core.Component
mut:
	runs &Runs
}

pub fn (mut r SelfRemover) update(dt f32) {
	mut c := r.runs
	c.n++
	mut n := r.node
	n.remove_component(0) // itself
	n.remove_component(1) // and its sibling, mid-loop
}

struct Counter {
	core.Component
mut:
	runs &Runs
}

pub fn (mut c Counter) update(dt f32) {
	mut r := c.runs
	r.n++
}

fn test_removing_components_during_update_is_safe() {
	mut s := core.Scene.new('T')
	mut runs := &Runs{}
	mut other := &Runs{}
	mut n := core.Node.new('N')
	n.add_component(&SelfRemover{
		runs: runs
	})
	n.add_component(&Counter{
		runs: other
	})
	n.add_component(&Counter{
		runs: other
	})
	s.add(mut n)
	s.update(0.016) // used to index past the end
	assert runs.n == 1
	assert n.components.len == 1 // two removed after the loop
	assert other.n == 1 // the removed sibling did not run; the third did
	s.update(0.016)
	assert other.n == 2
}

fn test_focus_loss_releases_held_keys() {
	mut i := core.Input{}
	i.key_down(int(core.Key.d))
	i.mouse_press()
	i.end_frame()
	assert i.is_down(.d) && i.mouse_down
	i.release_all()
	assert !i.is_down(.d) && i.was_released(.d)
	assert !i.mouse_down && i.mouse_released
}

fn riff(kind string, chunk_id string, size u32, body []u8) []u8 {
	mut b := 'RIFF'.bytes()
	b << [u8(0), 0, 0, 0]
	b << kind.bytes()
	b << chunk_id.bytes()
	b << [u8(size), u8(size >> 8), u8(size >> 16), u8(size >> 24)]
	b << body
	return b
}

fn test_damaged_chunk_sizes_fail_cleanly() {
	// sizes that used to go negative (infinite loop / negative slice)
	for size in [u32(0xFFFFFFF8), 0x80000000, 0xFFFFFFFF] {
		if _ := audio.decode_wav(riff('WAVE', 'junk', size, []u8{len: 16})) {
			assert false
		}
		if _ := webp.decode(riff('WEBP', 'ABCD', size, []u8{len: 16})) {
			assert false
		}
		if _, _ := webp.info(riff('WEBP', 'VP8L', size, []u8{len: 4})) {
			assert false
		}
	}
}
