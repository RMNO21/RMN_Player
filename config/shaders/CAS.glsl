// LICENSE
// =======
// Copyright (c) 2017-2019 Advanced Micro Devices, Inc. All rights reserved.
// -------
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
// -------
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
// Software.
// -------
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
// WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
// ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE

// FidelityFX Contrast Adaptive Sharpening (CAS) v1.0.2 for mpv

//!HOOK OUTPUT
//!BIND HOOKED
//!DESC CAS Relinearization Pass

vec3 srgb_to_linear(vec3 col) {
	return mix(col * 1.0 / 12.92,  pow((col + 0.055) / 1.055, vec3(2.4)), ivec3(lessThan(vec3(0.04045), col)));
}

vec4 hook()
{
	vec4 col = HOOKED_tex(HOOKED_pos);
	return vec4(srgb_to_linear(col.rgb), col.a);
}

//!HOOK OUTPUT
//!BIND HOOKED
//!DESC CAS Sharpening + Delinearization Pass

// User variables
#define SHARPENING 0.65 // Sharpening intensity: 0.0 to 1.0. (0.65 is crisp and natural)
#define CONTRAST 0.0   // Adjusts the range the shader adapts to high contrast. 0.0 to 1.0.

vec3 linear_to_srgb(vec3 col) {
	return mix(col * 12.92, 1.055 * pow(col, vec3(1.0 / 2.4)) - 0.055, ivec3(lessThanEqual(vec3(0.0031308), col)));
}

vec4 hook()
{
	// fetch a 3x3 neighborhood around the pixel 'e',
	//  a b c
	//  d(e)f
	//  g h i
	vec4 e = HOOKED_tex(HOOKED_pos);

	// If the current fragment is transparent, skip further processing
	if (e.a == 0.0)
		return vec4(linear_to_srgb(e.rgb), e.a);

	vec3 a = HOOKED_texOff(vec2(-1.0, -1.0)).rgb;
	vec3 b = HOOKED_texOff(vec2( 0.0, -1.0)).rgb;
	vec3 c = HOOKED_texOff(vec2( 1.0, -1.0)).rgb;
	vec3 f = HOOKED_texOff(vec2( 1.0,  0.0)).rgb;
	vec3 g = HOOKED_texOff(vec2(-1.0,  1.0)).rgb;
	vec3 h = HOOKED_texOff(vec2( 0.0,  1.0)).rgb;
	vec3 d = HOOKED_texOff(vec2(-1.0,  0.0)).rgb;
	vec3 i = HOOKED_texOff(vec2( 1.0,  1.0)).rgb;

	// Soft min and max.
	//  a b c			b
	//  d e f * 0.5	+ d e f * 0.5
	//  g h i			h
	// These are 2.0x bigger (factored out the extra multiply).
	vec3 mnRGB = min(min(min(d, e.rgb), min(f, b)), h);
	vec3 mnRGB2 = min(mnRGB, min(min(a, c), min(g, i)));
	mnRGB += mnRGB2;

	vec3 mxRGB = max(max(max(d, e.rgb), max(f, b)), h);
	vec3 mxRGB2 = max(mxRGB, max(max(a, c), max(g, i)));
	mxRGB += mxRGB2;

	// Smooth minimum distance to signal limit divided by smooth max.
	vec3 rcpMRGB = 1.0 / mxRGB;
	vec3 ampRGB = clamp(min(mnRGB, 2.0 - mxRGB) * rcpMRGB, 0.0, 1.0);

	// Shaping amount of sharpening.
	ampRGB = inversesqrt(ampRGB);

	float peak = -3.0 * clamp(CONTRAST, 0.0, 1.0) + 8.0;
	vec3 wRGB = -(1.0 / (ampRGB * peak));

	vec3 rcpWeightRGB = 1.0 / (4.0 * wRGB + 1.0);

	//						0 w 0
	//  Filter shape:		w 1 w
	//						0 w 0
	vec3 window = (b + d) + (f + h);
	vec3 outColor = clamp((window * wRGB + e.rgb) * rcpWeightRGB, 0.0, 1.0);

	// Delinearize
	return vec4(linear_to_srgb(mix(e.rgb, outColor, SHARPENING)), e.a);
}
