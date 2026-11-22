module render

import sokol.gfx

// Mipmaps: textures drawn smaller than their pixels (Spine rigs scaled down, zoomed-out cameras) shimmer and
// alias with a single level. decode_image builds the whole chain (on the preload worker when it runs there);
// the upload passes it to sokol, and the shared linear sampler filters between levels (trilinear).
// 'nearest' textures (pixel art) are uploaded without mips.

#include "@VMODROOT/render/mipmaps.h"

fn C.velo_mip_bytes(w int, h int) usize
fn C.velo_build_mips(base &u8, w int, h int, out &u8) int

// MipChain — the levels below the base image, stored one after another in one buffer.
pub struct MipChain {
pub:
	data   voidptr // malloc'd; freed with free_decoded / after the upload
	levels int
}

// build_mips makes the chain for w x h RGBA8 pixels (none for 1 x 1 or empty images).
pub fn build_mips(pixels voidptr, w int, h int) MipChain {
	if pixels == unsafe { nil } || w <= 0 || h <= 0 || (w == 1 && h == 1) {
		return MipChain{}
	}
	size := C.velo_mip_bytes(w, h)
	buf := unsafe { malloc(isize(size)) }
	if buf == unsafe { nil } {
		return MipChain{}
	}
	levels := C.velo_build_mips(&u8(pixels), w, h, &u8(buf))
	return MipChain{buf, levels}
}

// mip_size: the size of level `i` (0 = the base).
pub fn mip_size(w int, h int, i int) (int, int) {
	mut mw := w
	mut mh := h
	for _ in 0 .. i {
		mw = if mw > 1 { mw / 2 } else { 1 }
		mh = if mh > 1 { mh / 2 } else { 1 }
	}
	return mw, mh
}

// fill_mips puts the base and the chain's levels into an image description.
fn fill_mips(mut d gfx.ImageDesc, base voidptr, w int, h int, chain MipChain) {
	d.data.subimage[0][0] = gfx.Range{
		ptr:  base
		size: usize(w * h * 4)
	}
	mut levels := 1
	if chain.data != unsafe { nil } {
		mut p := &u8(chain.data)
		for i in 1 .. chain.levels + 1 {
			if i >= gfx.sg_max_mipmaps {
				break
			}
			mw, mh := mip_size(w, h, i)
			n := mw * mh * 4
			d.data.subimage[0][i] = gfx.Range{
				ptr:  p
				size: usize(n)
			}
			unsafe {
				p += n
			}
			levels++
		}
	}
	d.num_mipmaps = levels
}
