// Mip chain for RGBA8 textures (see render/mipmaps.c.v). Header-only, included once by the render module.
#ifndef VELO_MIPMAPS_H
#define VELO_MIPMAPS_H
#include <stdint.h>
#include <stdlib.h>

// velo_mip_bytes: bytes needed for every level below the base (w x h) down to 1 x 1.
static size_t velo_mip_bytes(int w, int h) {
	size_t total = 0;
	while (w > 1 || h > 1) {
		w = w > 1 ? w / 2 : 1;
		h = h > 1 ? h / 2 : 1;
		total += (size_t)w * (size_t)h * 4;
	}
	return total;
}

// velo_mip_down halves src (sw x sh) into dst. Each output texel averages a 2x2 block (3 wide / tall at the
// odd edge, so no source column or row is lost). Colour is weighted by alpha: the colour of fully transparent
// texels (often black in atlases) does not bleed into visible edges as a dark fringe.
static void velo_mip_down(const uint8_t* src, int sw, int sh, uint8_t* dst, int dw, int dh) {
	for (int y = 0; y < dh; y++) {
		int y0 = y * 2, y1 = y0 + (sh > 1 ? 1 : 0);
		int y2 = (y == dh - 1 && (sh & 1) && sh > 1) ? sh - 1 : y1;
		for (int x = 0; x < dw; x++) {
			int x0 = x * 2, x1 = x0 + (sw > 1 ? 1 : 0);
			int x2 = (x == dw - 1 && (sw & 1) && sw > 1) ? sw - 1 : x1;
			uint32_t r = 0, g = 0, b = 0, a = 0, n = 0, cr = 0, cg = 0, cb = 0;
			int xs[3] = {x0, x1, x2}, ys[3] = {y0, y1, y2};
			int nx = (x2 != x1) ? 3 : (x1 != x0 ? 2 : 1);
			int ny = (y2 != y1) ? 3 : (y1 != y0 ? 2 : 1);
			for (int j = 0; j < ny; j++) {
				const uint8_t* row = src + (size_t)ys[j] * sw * 4;
				for (int i = 0; i < nx; i++) {
					const uint8_t* p = row + (size_t)xs[i] * 4;
					uint32_t pa = p[3];
					r += p[0] * pa; g += p[1] * pa; b += p[2] * pa; a += pa;
					cr += p[0]; cg += p[1]; cb += p[2];
					n++;
				}
			}
			uint8_t* o = dst + ((size_t)y * dw + x) * 4;
			if (a > 0) {
				o[0] = (uint8_t)((r + a / 2) / a);
				o[1] = (uint8_t)((g + a / 2) / a);
				o[2] = (uint8_t)((b + a / 2) / a);
			} else {
				o[0] = (uint8_t)(cr / n); o[1] = (uint8_t)(cg / n); o[2] = (uint8_t)(cb / n);
			}
			o[3] = (uint8_t)((a + n / 2) / n);
		}
	}
}

// velo_build_mips fills `out` (velo_mip_bytes(w, h) bytes) with every level below the base, largest first.
// Returns the number of levels written.
static int velo_build_mips(const uint8_t* base, int w, int h, uint8_t* out) {
	int levels = 0;
	const uint8_t* src = base;
	while (w > 1 || h > 1) {
		int dw = w > 1 ? w / 2 : 1, dh = h > 1 ? h / 2 : 1;
		velo_mip_down(src, w, h, out, dw, dh);
		src = out;
		out += (size_t)dw * dh * 4;
		w = dw;
		h = dh;
		levels++;
	}
	return levels;
}
#endif
