module render

// Fullscreen post-processing shaders (see postfx.v). Each pass is a fragment body written once in the GLSL
// subset that shader.v already supports on every backend, wrapped here per shading language:
//
//   vec4 post_main(vec2 uv)   uv: 0..1 across the source image, (0,0) = bottom-left on GL, top-left on Metal
//   tex0(uv) tex1(uv) tex2(uv)  the pass inputs (scene / bloom / LUT, depending on the pass)
//   U[i]                      the pass uniforms, an array of vec4 (post_uniform_count of them)
//
// The vertex stage draws one fullscreen triangle from gl_VertexID / [[vertex_id]], so no vertex buffer is used.

const post_uniform_count = 12

// bloom prefilter: 4 bilinear taps (a 4x4 box) of the full-size scene into the half-size target, keeping only
// what is brighter than the threshold (soft knee). U[0] = (source texel w, h, threshold, knee).
const post_bright_fs = 'vec3 velo_prefilter(vec3 c) {
	float br = max(c.r, max(c.g, c.b));
	float th = U[0].z;
	float knee = max(U[0].w, 0.0001);
	float rq = clamp(br - th + knee, 0.0, 2.0 * knee);
	rq = rq * rq / (4.0 * knee);
	float w = max(rq, br - th) / max(br, 0.0001);
	return c * w;
}
vec4 post_main(vec2 uv) {
	vec2 t = U[0].xy;
	vec3 c = tex0(uv + vec2(-t.x, -t.y)).rgb + tex0(uv + vec2(t.x, -t.y)).rgb
		+ tex0(uv + vec2(-t.x, t.y)).rgb + tex0(uv + vec2(t.x, t.y)).rgb;
	return vec4(velo_prefilter(c * 0.25), 1.0);
}
'

// separable 9-tap gaussian with linear sampling (5 fetches). U[0].xy = step (texel * direction * radius).
const post_blur_fs = 'vec4 post_main(vec2 uv) {
	vec2 d = U[0].xy;
	vec3 c = tex0(uv).rgb * 0.2270270270;
	c += tex0(uv + d * 1.3846153846).rgb * 0.3162162162;
	c += tex0(uv - d * 1.3846153846).rgb * 0.3162162162;
	c += tex0(uv + d * 3.2307692308).rgb * 0.0702702703;
	c += tex0(uv - d * 3.2307692308).rgb * 0.0702702703;
	return vec4(c, 1.0);
}
'

// composite: chromatic aberration -> grade (exposure, lift/gamma/gain, contrast, saturation, LUT) -> + bloom
// (added after the grade, so magic keeps its colour in a desaturated scene) -> vignette -> grain -> flash.
// Uniform layout: see PostSettings.uniforms.
const post_composite_fs = 'float velo_hash(vec2 p) {
	vec3 p3 = fract(vec3(p.x, p.y, p.x) * 0.1031);
	p3 += dot(p3, vec3(p3.y, p3.z, p3.x) + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}
vec3 velo_lut(vec3 c) {
	float n = U[9].z;
	float b = clamp(c.b, 0.0, 1.0) * (n - 1.0);
	float s0 = floor(b);
	float s1 = min(s0 + 1.0, n - 1.0);
	float x = (clamp(c.r, 0.0, 1.0) * (n - 1.0) + 0.5) / (n * n);
	float y = (clamp(c.g, 0.0, 1.0) * (n - 1.0) + 0.5) / n;
	vec3 a = tex2(vec2(x + s0 / n, y)).rgb;
	vec3 d = tex2(vec2(x + s1 / n, y)).rgb;
	return mix(a, d, b - s0);
}
vec4 post_main(vec2 uv) {
	vec2 cen = uv - vec2(0.5, 0.5);
	vec2 ca = cen * U[6].w * U[9].xy * 2.0;
	vec3 c = vec3(tex0(uv + ca).r, tex0(uv).g, tex0(uv - ca).b);
	c *= U[3].w;
	c = c * U[3].xyz + U[1].xyz * (vec3(1.0, 1.0, 1.0) - c);
	c = pow(max(c, vec3(0.0, 0.0, 0.0)), vec3(U[2].x, U[2].y, U[2].z));
	c = (c - vec3(0.5, 0.5, 0.5)) * U[2].w + vec3(0.5, 0.5, 0.5);
	float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
	c = mix(vec3(l, l, l), c, U[1].w);
	c = clamp(c, vec3(0.0, 0.0, 0.0), vec3(1.0, 1.0, 1.0));
	if (U[4].w > 0.0) {
		c = mix(c, velo_lut(c), U[4].w);
	}
	c *= U[4].xyz;
	if (U[0].w > 0.0) {
		vec3 bl = tex1(uv - ca * 0.5).rgb;
		float bll = dot(bl, vec3(0.2126, 0.7152, 0.0722));
		bl = mix(vec3(bll, bll, bll), bl, U[0].y);
		c += bl * U[0].z;
	}
	if (U[5].x > 0.0) {
		vec2 v = cen * vec2(U[5].w, 1.0);
		float dist = length(v) * 1.41421356;
		float vig = smoothstep(U[5].y, U[5].y + U[5].z, dist) * U[5].x;
		c = mix(c, U[6].xyz, vig);
	}
	if (U[7].x > 0.0) {
		vec2 gp = floor(uv / (U[9].xy * max(U[7].y, 1.0)));
		float g = velo_hash(gp + vec2(floor(U[0].x * 24.0) * 17.0, 0.0)) - 0.5;
		float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
		c += g * U[7].x * (1.0 - lum * 0.6);
	}
	c = mix(c, U[8].xyz, U[8].w);
	return vec4(clamp(c, vec3(0.0, 0.0, 0.0), vec3(1.0, 1.0, 1.0)), 1.0);
}
'

const post_gles_header = '#version 300 es\nprecision highp float;\nprecision highp int;\n'

// post_sources: the vertex + fragment source of one fullscreen pass that reads `ntex` textures.
pub fn post_sources(body string, ntex int, lang ShaderLang) (string, string) {
	return match lang {
		.glsl410 { post_glsl_vs('#version 410\n'), post_glsl_fs('#version 410\n', body, ntex) }
		.glsl300es { post_glsl_vs(post_gles_header), post_glsl_fs(post_gles_header, body, ntex) }
		.msl { post_msl_vs, post_msl_fs(body, ntex) }
	}
}

fn post_glsl_vs(header string) string {
	return header +
		'out vec2 velo_uv;
void main() {
	vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
	velo_uv = p;
	gl_Position = vec4(p * 2.0 -
		1.0, 0.0, 1.0);
}
'
}

fn post_glsl_fs(header string, body string, ntex int) string {
	mut s := header + 'uniform vec4 fs_u[${post_uniform_count}];\n'
	for i in 0 .. ntex {
		s += 'uniform sampler2D tex${i}_smp;\nvec4 tex${i}(vec2 uv) { return texture(tex${i}_smp, uv); }\n'
	}
	return s +
		'#define U fs_u
in vec2 velo_uv;
layout(location = 0) out vec4 velo_frag_color;
#line 1
' +
		body + '\nvoid main() { velo_frag_color = post_main(velo_uv); }\n'
}

const post_msl_vs = '#include <metal_stdlib>
using namespace metal;
struct velo_post_out {
	float4 pos [[position]];
	float2 uv [[user(locn0)]];
};
vertex velo_post_out main0(uint vid [[vertex_id]]) {
	velo_post_out out = {};
	float2 p = float2(float((vid << 1) & 2), float(vid & 2));
	out.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
	out.uv = float2(p.x, 1.0 - p.y);
	return out;
}
'

// post_msl_fs: as in shader.v, the body becomes a struct whose members are the inputs, so its functions see them.
fn post_msl_fs(body string, ntex int) string {
	mut members := ''
	mut params := ''
	mut assign := ''
	for i in 0 .. ntex {
		members += '\ttexture2d<float> t${i};\n\tsampler s${i};\n\tvec4 tex${i}(vec2 uv) const { return t${i}.sample(s${i}, uv); }\n'
		params += ', texture2d<float> t${i} [[texture(${i})]], sampler s${i} [[sampler(${i})]]'
		assign += '\te.t${i} = t${i};\n\te.s${i} = s${i};\n'
	}
	return
		'#include <metal_stdlib>
using namespace metal;
typedef float2 vec2;
typedef float3 vec3;
typedef float4 vec4;
typedef float2x2 mat2;
typedef float3x3 mat3;
typedef float4x4 mat4;
template <typename T, typename U> inline T mod(T x, U y) { return x -
		y * floor(x / y); }
#define inversesqrt rsqrt
struct velo_post_in { float2 uv [[user(locn0)]]; };
struct velo_post {
	constant float4* U;
' +
		members + '#line 1\n' + body +
		'
};
fragment float4 main0(velo_post_in in [[stage_in]], constant float4* u [[buffer(0)]]' +
		params + ') {
	velo_post e;
	e.U = u;
' + assign + '	return e.post_main(in.uv);
}
'
}
