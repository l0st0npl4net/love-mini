// mini2d - small 2D software renderer for the Miyoo Mini / Mini Plus, the drawing
// half of love-mini's love.graphics.
//
// Based on mini2d from panelattack-miyoo by snyderman3000 (MIT License, see the
// notice in THIRD_PARTY_NOTICES.md); love-mini adds the rest of LOVE's blend modes,
// affine (rotated, sheared) blits, polygon fills and a stencil buffer.
//
// All drawing is done by the CPU into ARGB8888 premultiplied-alpha surfaces.
// Only the back buffers live in physically contiguous (MMA) memory; present()
// uses the SigmaStar 2D engine (GE) to rotate them onto the framebuffer.
//
// Build with -DM2D_HOST for a desktop stub: back buffer in RAM, frames can be
// dumped as PPM, and key presses can be scripted from a file.

#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>

#ifndef M2D_HOST
#include <sys/ioctl.h>
#include <linux/fb.h>
#include <linux/input.h>
#include "mi_sys.h"
#include "mi_gfx.h"
#endif

typedef struct m2d_surf {
    uint32_t *px;      // ARGB8888 premultiplied
    uint64_t phy;      // physical address (back buffer only)
    int w, h, stride;  // stride in bytes
    // optional run-length table of non-transparent runs per row (static images):
    // spans[rowidx[y] .. rowidx[y+1]) are triplets {x0, x1, opaque}
    uint32_t *rowidx;
    uint16_t *spans;
    // the stencil buffer (w x h, made on first use)
    uint8_t *sten;
} m2d_surf;

static m2d_surf back;
#define MAX_VIEWS 16
static struct { m2d_surf *s; int x, y; } views[MAX_VIEWS];
static int fb_w = 640, fb_h = 480;
static int frame_no = 0;

// statistics (pixels touched per path), read + reset by m2d_stats()
static double st[8];
enum { ST_BLIT_CALLS, ST_PX_COPY, ST_PX_ALPHA, ST_PX_GENERIC, ST_PX_FILL, ST_PX_CLEAR, ST_FILL_CALLS, ST_PX_SCALED };
void m2d_stats(double *out) { for (int i = 0; i < 8; i++) { out[i] = st[i]; st[i] = 0; } }

// clip rectangle (applies to every draw op), in destination pixels
static int clip_on = 0, clip_x0, clip_y0, clip_x1, clip_y1;

#ifndef M2D_HOST
static int fb_fd = -1, in_fd = -1;
static struct fb_var_screeninfo vinfo;
static struct fb_fix_screeninfo finfo;
static uint64_t fb_phy;
#else
static FILE *script = NULL;
static int script_frame = -1, script_code, script_value;
#endif

// ---------------------------------------------------------------- surfaces
m2d_surf *m2d_surface_new(int w, int h)
{
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    m2d_surf *s = (m2d_surf *)calloc(1, sizeof(m2d_surf));
    if (!s) return NULL;
    s->w = w; s->h = h; s->stride = w * 4;
    s->px = (uint32_t *)calloc((size_t)w * h, 4);
    if (!s->px) { free(s); return NULL; }
    return s;
}

void m2d_surface_free(m2d_surf *s)
{
    if (!s || s == &back) return;
    free(s->px);
    free(s->rowidx);
    free(s->spans);
    free(s->sten);
    free(s);
}

// Build the run table: lets alpha blits skip transparent pixels and memcpy opaque runs.
void m2d_surface_build_spans(m2d_surf *s)
{
    free(s->rowidx); free(s->spans);
    s->rowidx = NULL; s->spans = NULL;
    size_t n = 0;
    for (int pass = 0; pass < 2; pass++) {
        size_t k = 0;
        for (int y = 0; y < s->h; y++) {
            if (pass) s->rowidx[y] = (uint32_t)k;
            const uint32_t *row = (const uint32_t *)((uint8_t *)s->px + y * s->stride);
            int x = 0;
            while (x < s->w) {
                uint32_t a = row[x] >> 24;
                if (a == 0) { x++; continue; }
                int op = (a == 255);
                int x0 = x;
                while (x < s->w) {
                    uint32_t b = row[x] >> 24;
                    if (b == 0 || (b == 255) != op) break;
                    x++;
                }
                if (pass) { s->spans[k * 3] = x0; s->spans[k * 3 + 1] = x; s->spans[k * 3 + 2] = op; }
                k++;
            }
        }
        if (!pass) {
            n = k;
            s->rowidx = (uint32_t *)malloc(sizeof(uint32_t) * (s->h + 1));
            s->spans = (uint16_t *)malloc(sizeof(uint16_t) * 3 * (n ? n : 1));
            if (!s->rowidx || !s->spans) { free(s->rowidx); free(s->spans); s->rowidx = NULL; s->spans = NULL; return; }
        } else {
            s->rowidx[s->h] = (uint32_t)k;
        }
    }
}

// a surface that aliases a rectangle of another surface (no copy, not freed)
m2d_surf *m2d_surface_view(m2d_surf *parent, int x, int y, int w, int h)
{
    m2d_surf *s = (m2d_surf *)calloc(1, sizeof(m2d_surf));
    if (!s) return NULL;
    s->w = w; s->h = h; s->stride = parent->stride;
    s->px = (uint32_t *)((uint8_t *)parent->px + y * parent->stride) + x;
    s->phy = 0;
    if (parent == &back) { // follow the back buffer when it flips
        for (int i = 0; i < MAX_VIEWS; i++)
            if (!views[i].s) { views[i].s = s; views[i].x = x; views[i].y = y; break; }
    }
    return s;
}

void m2d_surface_view_free(m2d_surf *s)
{
    for (int i = 0; i < MAX_VIEWS; i++) if (views[i].s == s) views[i].s = NULL;
    free(s->sten);
    free(s);
}

// composite over black: premultiplied colour stays, alpha becomes 255
void m2d_surface_flatten(m2d_surf *s)
{
    for (int y = 0; y < s->h; y++) {
        uint32_t *row = (uint32_t *)((uint8_t *)s->px + y * s->stride);
        for (int x = 0; x < s->w; x++) row[x] |= 0xff000000u;
    }
}

int m2d_surface_is_opaque(m2d_surf *s)
{
    for (int y = 0; y < s->h; y++) {
        const uint32_t *row = (const uint32_t *)((uint8_t *)s->px + y * s->stride);
        for (int x = 0; x < s->w; x++) if ((row[x] >> 24) != 255) return 0;
    }
    return 1;
}

// A copy of src (same size) with an effect, for shaders love-mini stands in for:
//   0 SOLID   white where src has alpha (a sprite's flash: drawn tinted to the colour)
//   1 GRAY    luminance
//   2 INVERT  the colour inverted (alpha kept)
//   3 NOBLACK pure black pixels made transparent (a shader that discards them)
void m2d_surface_effect(m2d_surf *d, m2d_surf *src, int mode)
{
    int w = src->w < d->w ? src->w : d->w, h = src->h < d->h ? src->h : d->h;
    for (int y = 0; y < h; y++) {
        const uint32_t *sp = (const uint32_t *)((uint8_t *)src->px + y * src->stride);
        uint32_t *dp = (uint32_t *)((uint8_t *)d->px + y * d->stride);
        for (int x = 0; x < w; x++) {
            uint32_t c = sp[x], a = c >> 24, r = (c >> 16) & 255, g = (c >> 8) & 255, b = c & 255;
            switch (mode) {
            case 0: dp[x] = a * 0x01010101u; break;
            case 1: { uint32_t l = (r * 77 + g * 150 + b * 29) >> 8; dp[x] = (a << 24) | (l << 16) | (l << 8) | l; break; }
            case 2: dp[x] = (a << 24) | ((a - r) << 16) | ((a - g) << 8) | (a - b); break;
            default: dp[x] = (r | g | b) ? c : 0; break;
            }
        }
    }
}

// resample src (premultiplied) into dst's size: box filter down, nearest up
void m2d_surface_resample(m2d_surf *d, m2d_surf *src)
{
    int sw = src->w, sh = src->h, dw = d->w, dh = d->h;
    for (int y = 0; y < dh; y++) {
        int y0 = (int)((int64_t)y * sh / dh), y1 = (int)((int64_t)(y + 1) * sh / dh);
        if (y1 <= y0) y1 = y0 + 1;
        if (y1 > sh) y1 = sh;
        uint32_t *drow = (uint32_t *)((uint8_t *)d->px + y * d->stride);
        for (int x = 0; x < dw; x++) {
            int x0 = (int)((int64_t)x * sw / dw), x1 = (int)((int64_t)(x + 1) * sw / dw);
            if (x1 <= x0) x1 = x0 + 1;
            if (x1 > sw) x1 = sw;
            uint32_t a = 0, r = 0, g = 0, b = 0, n = 0;
            for (int yy = y0; yy < y1; yy++) {
                const uint32_t *srow = (const uint32_t *)((uint8_t *)src->px + yy * src->stride);
                for (int xx = x0; xx < x1; xx++) {
                    uint32_t c = srow[xx];
                    a += c >> 24; r += (c >> 16) & 255; g += (c >> 8) & 255; b += c & 255; n++;
                }
            }
            drow[x] = (((a + n / 2) / n) << 24) | (((r + n / 2) / n) << 16) | (((g + n / 2) / n) << 8) | ((b + n / 2) / n);
        }
    }
}

size_t m2d_surface_bytes(m2d_surf *s) { return s ? (size_t)s->stride * s->h : 0; }

static inline uint32_t premul(const uint8_t *p)
{
    uint32_t a = p[3];
    if (a == 255) return 0xff000000u | ((uint32_t)p[0] << 16) | ((uint32_t)p[1] << 8) | p[2];
    if (a == 0) return 0;
    uint32_t r = (p[0] * a + 127) / 255;
    uint32_t g = (p[1] * a + 127) / 255;
    uint32_t b = (p[2] * a + 127) / 255;
    return (a << 24) | (r << 16) | (g << 8) | b;
}

// Upload straight-alpha RGBA8 (LOVE ImageData) of size sw x sh into the whole
// surface, resampling to the surface size (box filter when shrinking).
void m2d_surface_upload_rgba(m2d_surf *s, const uint8_t *rgba, int sw, int sh)
{
    free(s->rowidx); free(s->spans); s->rowidx = NULL; s->spans = NULL;
    int dw = s->w, dh = s->h;
    if (dw == sw && dh == sh) {
        for (int y = 0; y < sh; y++) {
            uint32_t *d = (uint32_t *)((uint8_t *)s->px + y * s->stride);
            const uint8_t *p = rgba + (size_t)y * sw * 4;
            for (int x = 0; x < sw; x++, p += 4) d[x] = premul(p);
        }
        return;
    }
    for (int y = 0; y < dh; y++) {
        int y0 = (int)((int64_t)y * sh / dh), y1 = (int)((int64_t)(y + 1) * sh / dh);
        if (y1 <= y0) y1 = y0 + 1;
        if (y1 > sh) y1 = sh;
        uint32_t *d = (uint32_t *)((uint8_t *)s->px + y * s->stride);
        for (int x = 0; x < dw; x++) {
            int x0 = (int)((int64_t)x * sw / dw), x1 = (int)((int64_t)(x + 1) * sw / dw);
            if (x1 <= x0) x1 = x0 + 1;
            if (x1 > sw) x1 = sw;
            uint32_t sa = 0, sr = 0, sg = 0, sb = 0, n = 0;
            for (int yy = y0; yy < y1; yy++) {
                const uint8_t *p = rgba + ((size_t)yy * sw + x0) * 4;
                for (int xx = x0; xx < x1; xx++, p += 4) {
                    uint32_t a = p[3];
                    sa += a;
                    sr += p[0] * a; sg += p[1] * a; sb += p[2] * a;
                    n++;
                }
            }
            if (sa == 0) { d[x] = 0; continue; }
            uint32_t A = (sa + n / 2) / n;
            uint32_t R = (sr / 255 + n / 2) / n, G = (sg / 255 + n / 2) / n, B = (sb / 255 + n / 2) / n;
            if (R > A) R = A;
            if (G > A) G = A;
            if (B > A) B = A;
            d[x] = (A << 24) | (R << 16) | (G << 8) | B;
        }
    }
}

// Upload a luminance+alpha glyph (w x h) at x0,y0 as premultiplied white.
void m2d_surface_upload_la8(m2d_surf *s, const uint8_t *la, int x0, int y0, int w, int h)
{
    for (int y = 0; y < h; y++) {
        if (y0 + y < 0 || y0 + y >= s->h) continue;
        uint32_t *d = (uint32_t *)((uint8_t *)s->px + (y0 + y) * s->stride);
        const uint8_t *p = la + (size_t)y * w * 2;
        for (int x = 0; x < w; x++, p += 2) {
            if (x0 + x < 0 || x0 + x >= s->w) continue;
            uint32_t a = p[1];
            uint32_t l = (p[0] * a + 127) / 255;
            d[x0 + x] = (a << 24) | (l << 16) | (l << 8) | l;
        }
    }
}

// Read back as straight-alpha RGBA8 (for canvas:newImageData)
void m2d_surface_download_rgba(m2d_surf *s, uint8_t *rgba)
{
    for (int y = 0; y < s->h; y++) {
        const uint32_t *row = (const uint32_t *)((uint8_t *)s->px + y * s->stride);
        for (int x = 0; x < s->w; x++, rgba += 4) {
            uint32_t c = row[x], a = c >> 24;
            if (a == 0) { rgba[0] = rgba[1] = rgba[2] = rgba[3] = 0; continue; }
            rgba[0] = (uint8_t)((((c >> 16) & 255) * 255 + a / 2) / a);
            rgba[1] = (uint8_t)((((c >> 8) & 255) * 255 + a / 2) / a);
            rgba[2] = (uint8_t)(((c & 255) * 255 + a / 2) / a);
            rgba[3] = (uint8_t)a;
        }
    }
}

void m2d_surface_copy(m2d_surf *dst, m2d_surf *src)
{
    if (dst->w != src->w || dst->h != src->h) return;
    for (int y = 0; y < src->h; y++)
        memcpy((uint8_t *)dst->px + y * dst->stride, (uint8_t *)src->px + y * src->stride, (size_t)src->w * 4);
}

m2d_surf *m2d_backbuffer(void) { return &back; }

// ---------------------------------------------------------------- clip
void m2d_set_clip(int x, int y, int w, int h)
{
    clip_on = 1;
    clip_x0 = x; clip_y0 = y; clip_x1 = x + w; clip_y1 = y + h;
}

void m2d_reset_clip(void) { clip_on = 0; }

// intersect [x0,x1)x[y0,y1) with surface and clip; returns 0 if empty
static inline int do_clip(m2d_surf *d, int *x0, int *y0, int *x1, int *y1)
{
    if (*x0 < 0) *x0 = 0;
    if (*y0 < 0) *y0 = 0;
    if (*x1 > d->w) *x1 = d->w;
    if (*y1 > d->h) *y1 = d->h;
    if (clip_on) {
        if (*x0 < clip_x0) *x0 = clip_x0;
        if (*y0 < clip_y0) *y0 = clip_y0;
        if (*x1 > clip_x1) *x1 = clip_x1;
        if (*y1 > clip_y1) *y1 = clip_y1;
    }
    return *x0 < *x1 && *y0 < *y1;
}

// ---------------------------------------------------------------- stencil
// Test: a pixel is drawn only where its stencil value passes the comparison (LOVE's
// setStencilTest). Write: draws change the stencil where their pixels are not
// transparent, and leave the colour alone (LOVE's stencil()).
enum { ST_ALWAYS = 0, ST_EQUAL, ST_NOTEQUAL, ST_LESS, ST_LEQUAL, ST_GREATER, ST_GEQUAL, ST_NEVER };
enum { SW_OFF = 0, SW_REPLACE, SW_INCREMENT, SW_DECREMENT, SW_INCWRAP, SW_DECWRAP, SW_INVERT };
static int sten_cmp = ST_ALWAYS, sten_val = 0, sten_write = SW_OFF, sten_wval = 0;

static inline int sten_slow(void) { return sten_cmp != ST_ALWAYS || sten_write != SW_OFF; }

uint8_t *m2d_surface_stencil(m2d_surf *s)
{
    if (!s->sten) s->sten = (uint8_t *)calloc((size_t)s->w * s->h, 1);
    return s->sten;
}

void m2d_stencil_clear(m2d_surf *s, int value)
{
    if (s->sten || value) memset(m2d_surface_stencil(s), value & 255, (size_t)s->w * s->h);
}

void m2d_stencil_test(int compare, int value) { sten_cmp = compare; sten_val = value & 255; }
void m2d_stencil_write(int action, int value) { sten_write = action; sten_wval = value & 255; }

// LOVE's compare modes: the pixel's stencil value against the given one
// (setStencilTest("greater", 0): drawn where the stencil is above 0).
static inline int sten_pass(int v)
{
    switch (sten_cmp) {
    case ST_EQUAL: return v == sten_val;
    case ST_NOTEQUAL: return v != sten_val;
    case ST_LESS: return v < sten_val;
    case ST_LEQUAL: return v <= sten_val;
    case ST_GREATER: return v > sten_val;
    case ST_GEQUAL: return v >= sten_val;
    case ST_NEVER: return 0;
    default: return 1;
    }
}

static inline int sten_apply(int v)
{
    switch (sten_write) {
    case SW_REPLACE: return sten_wval;
    case SW_INCREMENT: return v < 255 ? v + 1 : 255;
    case SW_DECREMENT: return v > 0 ? v - 1 : 0;
    case SW_INCWRAP: return (v + 1) & 255;
    case SW_DECWRAP: return (v - 1) & 255;
    case SW_INVERT: return (~v) & 255;
    default: return v;
    }
}

// ---------------------------------------------------------------- pixel ops
static inline uint32_t mul_px(uint32_t c, uint32_t f) // f: 0..256
{
    uint32_t rb = ((c & 0x00ff00ff) * f >> 8) & 0x00ff00ff;
    uint32_t ag = (((c >> 8) & 0x00ff00ff) * f) & 0xff00ff00;
    return rb | ag;
}

// ---------------------------------------------------------------- rows
// The inner loops of most draws, on 8 pixels at a time with NEON (the same results
// as the per-pixel code: d * (256 - a) >> 8 is d * (255 - a) + d, shifted).
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#define M2D_NEON 1
#endif

static inline uint32_t mul_px(uint32_t c, uint32_t f);

// d[i] = s[i] over d[i] (premultiplied)
static void blend_row(uint32_t *d, const uint32_t *s, int n)
{
    int i = 0;
#ifdef M2D_NEON
    for (; i + 8 <= n; i += 8) {
        uint8x8x4_t sv = vld4_u8((const uint8_t *)(s + i));
        uint64_t a64 = vget_lane_u64(vreinterpret_u64_u8(sv.val[3]), 0);
        if (a64 == 0) continue;
        if (a64 == ~(uint64_t)0) { vst4_u8((uint8_t *)(d + i), sv); continue; }
        uint8x8x4_t dv = vld4_u8((const uint8_t *)(d + i));
        uint8x8_t inv = vmvn_u8(sv.val[3]);
        for (int c = 0; c < 4; c++) {
            uint16x8_t t = vmlal_u8(vmovl_u8(dv.val[c]), dv.val[c], inv);
            dv.val[c] = vadd_u8(sv.val[c], vshrn_n_u16(t, 8));
        }
        vst4_u8((uint8_t *)(d + i), dv);
    }
#endif
    for (; i < n; i++) {
        uint32_t c = s[i], a = c >> 24;
        if (a == 255) d[i] = c;
        else if (a) d[i] = c + mul_px(d[i], 256 - a);
    }
}

// s[i] tinted (each channel * (t + 1) >> 8), into o
static void tint_row(uint32_t *o, const uint32_t *s, int n, uint32_t tint)
{
    int i = 0;
#ifdef M2D_NEON
    uint8x8_t t0 = vdup_n_u8(tint & 255), t1 = vdup_n_u8((tint >> 8) & 255);
    uint8x8_t t2 = vdup_n_u8((tint >> 16) & 255), t3 = vdup_n_u8(tint >> 24);
    for (; i + 8 <= n; i += 8) {
        uint8x8x4_t v = vld4_u8((const uint8_t *)(s + i));
        v.val[0] = vshrn_n_u16(vmlal_u8(vmovl_u8(v.val[0]), v.val[0], t0), 8);
        v.val[1] = vshrn_n_u16(vmlal_u8(vmovl_u8(v.val[1]), v.val[1], t1), 8);
        v.val[2] = vshrn_n_u16(vmlal_u8(vmovl_u8(v.val[2]), v.val[2], t2), 8);
        v.val[3] = vshrn_n_u16(vmlal_u8(vmovl_u8(v.val[3]), v.val[3], t3), 8);
        vst4_u8((uint8_t *)(o + i), v);
    }
#endif
    for (; i < n; i++) {
        uint32_t c = s[i];
        uint32_t a = ((c >> 24) * ((tint >> 24) + 1)) >> 8;
        uint32_t r = (((c >> 16) & 255) * (((tint >> 16) & 255) + 1)) >> 8;
        uint32_t g = (((c >> 8) & 255) * (((tint >> 8) & 255) + 1)) >> 8;
        uint32_t b = ((c & 255) * ((tint & 255) + 1)) >> 8;
        o[i] = (a << 24) | (r << 16) | (g << 8) | b;
    }
}

// d[i] = colour over d[i]
static void fill_row_alpha(uint32_t *d, int n, uint32_t argb)
{
    uint32_t inv = 256 - (argb >> 24);
    int i = 0;
#ifdef M2D_NEON
    uint8x8_t c0 = vdup_n_u8(argb & 255), c1 = vdup_n_u8((argb >> 8) & 255);
    uint8x8_t c2 = vdup_n_u8((argb >> 16) & 255), c3 = vdup_n_u8(argb >> 24);
    uint8x8_t iv = vdup_n_u8(255 - (argb >> 24));
    for (; i + 8 <= n; i += 8) {
        uint8x8x4_t dv = vld4_u8((const uint8_t *)(d + i));
        dv.val[0] = vadd_u8(c0, vshrn_n_u16(vmlal_u8(vmovl_u8(dv.val[0]), dv.val[0], iv), 8));
        dv.val[1] = vadd_u8(c1, vshrn_n_u16(vmlal_u8(vmovl_u8(dv.val[1]), dv.val[1], iv), 8));
        dv.val[2] = vadd_u8(c2, vshrn_n_u16(vmlal_u8(vmovl_u8(dv.val[2]), dv.val[2], iv), 8));
        dv.val[3] = vadd_u8(c3, vshrn_n_u16(vmlal_u8(vmovl_u8(dv.val[3]), dv.val[3], iv), 8));
        vst4_u8((uint8_t *)(d + i), dv);
    }
#endif
    for (; i < n; i++) d[i] = argb + mul_px(d[i], inv);
}

static inline uint32_t over(uint32_t s, uint32_t d)
{
    uint32_t a = s >> 24;
    if (a == 255) return s;
    if (a == 0) return d;
    return s + mul_px(d, 256 - a);
}

static inline uint32_t sat(int v) { return v < 0 ? 0 : v > 255 ? 255 : (uint32_t)v; }

static inline uint32_t add_px(uint32_t s, uint32_t d)
{
    uint32_t r = ((s >> 16) & 255) + ((d >> 16) & 255);
    uint32_t g = ((s >> 8) & 255) + ((d >> 8) & 255);
    uint32_t b = (s & 255) + (d & 255);
    uint32_t a = (s >> 24) + (d >> 24);
    if (r > 255) r = 255;
    if (g > 255) g = 255;
    if (b > 255) b = 255;
    if (a > 255) a = 255;
    return (a << 24) | (r << 16) | (g << 8) | b;
}

static inline uint32_t tint_px(uint32_t c, uint32_t tint)
{
    uint32_t a = ((c >> 24) * ((tint >> 24) + 1)) >> 8;
    uint32_t r = (((c >> 16) & 255) * (((tint >> 16) & 255) + 1)) >> 8;
    uint32_t g = (((c >> 8) & 255) * (((tint >> 8) & 255) + 1)) >> 8;
    uint32_t b = ((c & 255) * ((tint & 255) + 1)) >> 8;
    return (a << 24) | (r << 16) | (g << 8) | b;
}

// LOVE's blend modes, for premultiplied colours (s: source, d: destination).
enum { BLEND_REPLACE = 0, BLEND_ALPHA, BLEND_ADD, BLEND_SUBTRACT, BLEND_MULTIPLY, BLEND_SCREEN,
       BLEND_LIGHTEN, BLEND_DARKEN };

static inline uint32_t blend_px(uint32_t s, uint32_t d, int mode)
{
    switch (mode) {
    case BLEND_ALPHA: return over(s, d);
    case BLEND_ADD: return add_px(s, d);
    case BLEND_REPLACE: return s;
    default: break;
    }
    uint32_t sa = s >> 24, out = 0;
    for (int sh = 0; sh <= 24; sh += 8) {
        int sc = (s >> sh) & 255, dc = (d >> sh) & 255, v;
        switch (mode) {
        // subtract: d - s; the alpha stays the destination's
        case BLEND_SUBTRACT: v = sh == 24 ? dc : dc - sc; break;
        // multiply: s * d + d * (1 - sa)
        case BLEND_MULTIPLY: v = (sc * dc + 127) / 255 + (dc * (255 - (int)sa) + 127) / 255; break;
        // screen: s + d * (1 - s)
        case BLEND_SCREEN: v = sc + (dc * (255 - sc) + 127) / 255; break;
        case BLEND_LIGHTEN: v = sc > dc ? sc : dc; break;
        case BLEND_DARKEN: v = sh == 24 ? (sc > dc ? sc : dc) : (sc < dc ? sc : dc); break;
        default: v = sc;
        }
        out |= sat(v) << sh;
    }
    return out;
}

// One pixel through the stencil: tested, then either the stencil written or the
// colour blended.
static inline void put_slow(m2d_surf *d, int x, int y, uint32_t *dp, uint32_t c, int blend)
{
    uint8_t *sp = d->sten ? d->sten + (size_t)y * d->w + x : NULL;
    int v = sp ? *sp : 0;
    if (!sten_pass(v)) return;
    if (sten_write != SW_OFF) {
        if ((c >> 24) == 0) return;
        if (!sp) sp = m2d_surface_stencil(d) + (size_t)y * d->w + x;
        *sp = (uint8_t)sten_apply(v);
        return;
    }
    *dp = blend_px(c, *dp, blend);
}

// clear a whole surface (ignores clip unless use_clip)
void m2d_clear(m2d_surf *d, uint32_t argb, int use_clip)
{
    st[ST_PX_CLEAR] += (double)d->w * d->h;
    if (!use_clip || !clip_on) {
        if (argb == 0 && d->stride == d->w * 4) { memset(d->px, 0, (size_t)d->stride * d->h); return; }
        for (int y = 0; y < d->h; y++) {
            uint32_t *row = (uint32_t *)((uint8_t *)d->px + y * d->stride);
            for (int x = 0; x < d->w; x++) row[x] = argb;
        }
        return;
    }
    int x0 = 0, y0 = 0, x1 = d->w, y1 = d->h;
    if (!do_clip(d, &x0, &y0, &x1, &y1)) return;
    for (int y = y0; y < y1; y++) {
        uint32_t *row = (uint32_t *)((uint8_t *)d->px + y * d->stride);
        for (int x = x0; x < x1; x++) row[x] = argb;
    }
}

void m2d_fill(m2d_surf *d, int x, int y, int w, int h, uint32_t argb, int blend)
{
    int x0 = x, y0 = y, x1 = x + w, y1 = y + h;
    if (w <= 0 || h <= 0 || !do_clip(d, &x0, &y0, &x1, &y1)) return;
    uint32_t a = argb >> 24;
    int slow = sten_slow();
    if (!slow && blend == BLEND_ALPHA && a == 0) return;
    if (blend == BLEND_ALPHA && a == 255) blend = BLEND_REPLACE;
    st[ST_FILL_CALLS] += 1; st[ST_PX_FILL] += (double)(x1 - x0) * (y1 - y0);
    for (int yy = y0; yy < y1; yy++) {
        uint32_t *row = (uint32_t *)((uint8_t *)d->px + yy * d->stride);
        if (slow) for (int xx = x0; xx < x1; xx++) put_slow(d, xx, yy, row + xx, argb, blend);
        else if (blend == BLEND_REPLACE) for (int xx = x0; xx < x1; xx++) row[xx] = argb;
        else if (blend == BLEND_ALPHA) fill_row_alpha(row + x0, x1 - x0, argb);
        else for (int xx = x0; xx < x1; xx++) row[xx] = blend_px(argb, row[xx], blend);
    }
}

// Blit src rect (sx,sy,sw,sh) to dst rect (dx,dy,dw,dh) with nearest scaling.
// flip: bit0 = mirror x, bit1 = mirror y. tint: premultiplied ARGB (0xffffffff = none)
#ifdef M2D_HOST
static int nodraw = -1;
#endif
// a destination row's worth of source pixels (screens up to 2048 wide)
#define ROWBUF 2048
static uint32_t rowbuf[ROWBUF];

void m2d_blit(m2d_surf *s, int sx, int sy, int sw, int sh,
              m2d_surf *d, int dx, int dy, int dw, int dh,
              uint32_t tint, int blend, int flip)
{
#ifdef M2D_HOST
    if (nodraw < 0) nodraw = getenv("M2D_NODRAW") != NULL;
    if (nodraw) return;
#endif
    if (dw <= 0 || dh <= 0 || sw <= 0 || sh <= 0) return;
    // keep source rect inside the surface
    if (sx < 0) sx = 0;
    if (sy < 0) sy = 0;
    if (sx + sw > s->w) sw = s->w - sx;
    if (sy + sh > s->h) sh = s->h - sy;
    if (sw <= 0 || sh <= 0) return;

    int x0 = dx, y0 = dy, x1 = dx + dw, y1 = dy + dh;
    if (!do_clip(d, &x0, &y0, &x1, &y1)) return;

    uint32_t stepx = (uint32_t)(((uint64_t)sw << 16) / dw);
    uint32_t stepy = (uint32_t)(((uint64_t)sh << 16) / dh);
    uint32_t fx0 = (uint32_t)(x0 - dx) * stepx;
    uint32_t fy = (uint32_t)(y0 - dy) * stepy;
    int unscaled = (sw == dw && sh == dh);
    int notint = (tint == 0xffffffffu);
    int fx_flip = flip & 1, fy_flip = flip & 2;
    int slow = sten_slow();
    if (tint == 0 && blend != BLEND_REPLACE && !slow) return; // fully transparent
    // the fast paths know replace and alpha only
    int fast = !slow && (blend == BLEND_REPLACE || blend == BLEND_ALPHA);
    st[ST_BLIT_CALLS] += 1;
    {
        double px = (double)(x1 - x0) * (y1 - y0);
        if (fast && !fx_flip && unscaled && notint && blend == BLEND_REPLACE) st[ST_PX_COPY] += px;
        else if (fast && !fx_flip && unscaled && notint && blend == BLEND_ALPHA) st[ST_PX_ALPHA] += px;
        else st[ST_PX_GENERIC] += px;
        if (!unscaled) st[ST_PX_SCALED] += px;
    }

    int prev_srcy = -1;
    for (int y = y0; y < y1; y++, fy += stepy) {
        int srcy = (int)(fy >> 16);
        if (srcy >= sh) srcy = sh - 1;
        if (fy_flip) srcy = sh - 1 - srcy;
        const uint32_t *srow = (const uint32_t *)((uint8_t *)s->px + (sy + srcy) * s->stride) + sx;
        uint32_t *drow = (uint32_t *)((uint8_t *)d->px + y * d->stride);

        // scaled, nearest pixel, no tint: a canvas or picture enlarged to the screen
        if (fast && notint && !unscaled) {
            int same = (srcy == prev_srcy);
            prev_srcy = srcy;
            if (blend == BLEND_REPLACE && same) {
                // the row above came from the same source row: copy it
                memcpy(drow + x0, (uint8_t *)drow - d->stride + x0 * 4, (size_t)(x1 - x0) * 4);
                continue;
            }
            uint32_t fx = fx0;
            if (blend == BLEND_REPLACE) {
                if (!fx_flip) for (int x = x0; x < x1; x++, fx += stepx) drow[x] = srow[fx >> 16];
                else for (int x = x0; x < x1; x++, fx += stepx) drow[x] = srow[sw - 1 - (int)(fx >> 16)];
            } else if (x1 - x0 > ROWBUF) {
                for (int x = x0; x < x1; x++, fx += stepx) {
                    int srcx = (int)(fx >> 16);
                    uint32_t c = srow[fx_flip ? sw - 1 - srcx : srcx], a = c >> 24;
                    if (a == 255) drow[x] = c;
                    else if (a) drow[x] = c + mul_px(drow[x], 256 - a);
                }
            } else {
                // the source row picked out once, blended into each row it covers
                int n = x1 - x0;
                if (!same) {
                    for (int x = 0; x < n; x++, fx += stepx) {
                        int srcx = (int)(fx >> 16);
                        rowbuf[x] = srow[fx_flip ? sw - 1 - srcx : srcx];
                    }
                }
                blend_row(drow + x0, rowbuf, n);
            }
            continue;
        }

        if (fast && !fx_flip && unscaled && notint) {
            const uint32_t *sp = srow + (x0 - dx);
            if (blend == BLEND_REPLACE) { memcpy(drow + x0, sp, (x1 - x0) * 4); continue; }
            if (s->rowidx) {
                // walk only the non-transparent runs of this source row
                int off = sx - dx;                // src x = dst x + off
                int lo = x0 + off, hi = x1 + off; // visible src range
                int r = sy + srcy;
                for (uint32_t k = s->rowidx[r]; k < s->rowidx[r + 1]; k++) {
                    int a0 = s->spans[k * 3], a1 = s->spans[k * 3 + 1];
                    if (a1 <= lo) continue;
                    if (a0 >= hi) break;
                    if (a0 < lo) a0 = lo;
                    if (a1 > hi) a1 = hi;
                    const uint32_t *src = (const uint32_t *)((uint8_t *)s->px + r * s->stride) + a0;
                    uint32_t *dst = drow + (a0 - off);
                    if (s->spans[k * 3 + 2]) memcpy(dst, src, (a1 - a0) * 4);
                    else blend_row(dst, src, a1 - a0);
                }
                continue;
            }
            blend_row(drow + x0, sp, x1 - x0);
            continue;
        }
        if (fast && fx_flip && unscaled && notint && blend == BLEND_ALPHA) {
            const uint32_t *sp = srow + (sw - 1 - (x0 - dx));
            for (int x = x0; x < x1; x++, sp--) {
                uint32_t c = *sp, a = c >> 24;
                if (a == 255) drow[x] = c;
                else if (a) drow[x] = c + mul_px(drow[x], 256 - a);
            }
            continue;
        }
        uint32_t fx = fx0;
        if (fast && blend == BLEND_ALPHA && x1 - x0 <= ROWBUF) {
            // tinted (a coloured sprite, text): the row picked out, tinted, blended
            int n = x1 - x0;
            if (unscaled && !fx_flip) {
                tint_row(rowbuf, srow + (x0 - dx), n, tint);
            } else {
                for (int x = 0; x < n; x++, fx += stepx) {
                    int srcx = (int)(fx >> 16);
                    rowbuf[x] = srow[fx_flip ? sw - 1 - srcx : srcx];
                }
                tint_row(rowbuf, rowbuf, n, tint);
            }
            blend_row(drow + x0, rowbuf, n);
            continue;
        }
        for (int x = x0; x < x1; x++, fx += stepx) {
            int srcx = (int)(fx >> 16);
            if (srcx >= sw) srcx = sw - 1;
            if (fx_flip) srcx = sw - 1 - srcx;
            uint32_t c = srow[srcx];
            if (!notint) c = tint_px(c, tint);
            if (slow) put_slow(d, x, y, drow + x, c, blend);
            else drow[x] = blend_px(c, drow[x], blend);
        }
    }
}

// Blit the src rect (sx,sy,sw,sh) through an affine map: m (2x3, row-major) takes
// a point of the rect (u, v in source pixels from its top left) to destination
// pixels: x = m0*u + m1*v + m2, y = m3*u + m4*v + m5. Each destination pixel whose
// centre falls inside the mapped rect takes the nearest source pixel.
void m2d_blit_affine(m2d_surf *s, int sx, int sy, int sw, int sh, m2d_surf *d, const float *m,
                     uint32_t tint, int blend)
{
    if (sw <= 0 || sh <= 0) return;
    if (sx < 0) sx = 0;
    if (sy < 0) sy = 0;
    if (sx + sw > s->w) sw = s->w - sx;
    if (sy + sh > s->h) sh = s->h - sy;
    if (sw <= 0 || sh <= 0) return;
    double a = m[0], b = m[1], c = m[3], e = m[4];
    double det = a * e - b * c;
    if (fabs(det) < 1e-9) return;
    // the destination box of the four corners
    double cx[4] = { m[2], m[2] + a * sw, m[2] + b * sh, m[2] + a * sw + b * sh };
    double cy[4] = { m[5], m[5] + c * sw, m[5] + e * sh, m[5] + c * sw + e * sh };
    double minx = cx[0], maxx = cx[0], miny = cy[0], maxy = cy[0];
    for (int i = 1; i < 4; i++) {
        if (cx[i] < minx) minx = cx[i];
        if (cx[i] > maxx) maxx = cx[i];
        if (cy[i] < miny) miny = cy[i];
        if (cy[i] > maxy) maxy = cy[i];
    }
    int x0 = (int)floor(minx), y0 = (int)floor(miny), x1 = (int)ceil(maxx), y1 = (int)ceil(maxy);
    if (!do_clip(d, &x0, &y0, &x1, &y1)) return;
    // inverse: (u, v) = inv * (x - m2, y - m5), in 16.16
    double ia = e / det, ib = -b / det, ic = -c / det, ie = a / det;
    int32_t du_dx = (int32_t)(ia * 65536.0), dv_dx = (int32_t)(ic * 65536.0);
    int notint = (tint == 0xffffffffu);
    int slow = sten_slow();
    st[ST_BLIT_CALLS] += 1;
    st[ST_PX_GENERIC] += (double)(x1 - x0) * (y1 - y0);
    int64_t umax = (int64_t)sw << 16, vmax = (int64_t)sh << 16;
    for (int y = y0; y < y1; y++) {
        double py = y + 0.5 - m[5], px = x0 + 0.5 - m[2];
        int64_t u = (int64_t)((ia * px + ib * py) * 65536.0);
        int64_t v = (int64_t)((ic * px + ie * py) * 65536.0);
        uint32_t *drow = (uint32_t *)((uint8_t *)d->px + y * d->stride);
        for (int x = x0; x < x1; x++, u += du_dx, v += dv_dx) {
            if (u < 0 || v < 0 || u >= umax || v >= vmax) continue;
            uint32_t col = *((const uint32_t *)((uint8_t *)s->px + (sy + (int)(v >> 16)) * s->stride) + sx + (int)(u >> 16));
            if (!notint) col = tint_px(col, tint);
            if (slow) put_slow(d, x, y, drow + x, col, blend);
            else if ((col >> 24) || blend != BLEND_ALPHA) drow[x] = blend_px(col, drow[x], blend);
        }
    }
}

// Fill a polygon (n points, xy pairs in destination pixels; even-odd rule). Pixel
// centres inside are drawn.
void m2d_polygon(m2d_surf *d, const float *xy, int n, uint32_t argb, int blend)
{
    if (n < 3) return;
    float miny = xy[1], maxy = xy[1];
    for (int i = 1; i < n; i++) {
        if (xy[i * 2 + 1] < miny) miny = xy[i * 2 + 1];
        if (xy[i * 2 + 1] > maxy) maxy = xy[i * 2 + 1];
    }
    int y0 = (int)floorf(miny), y1 = (int)ceilf(maxy), x0 = 0, x1 = d->w;
    if (!do_clip(d, &x0, &y0, &x1, &y1)) return;
    int cap = 16;
    float stackxs[16], *xs = stackxs;
    if (n > cap) { xs = (float *)malloc(sizeof(float) * n); if (!xs) return; }
    for (int y = y0; y < y1; y++) {
        float py = y + 0.5f;
        int k = 0;
        for (int i = 0, j = n - 1; i < n; j = i++) {
            float yi = xy[i * 2 + 1], yj = xy[j * 2 + 1];
            if ((yi > py) != (yj > py)) {
                float xi = xy[i * 2], xj = xy[j * 2];
                xs[k++] = xi + (py - yi) * (xj - xi) / (yj - yi);
            }
        }
        // sort the crossings (few): insertion sort
        for (int i = 1; i < k; i++) {
            float t = xs[i];
            int j = i - 1;
            while (j >= 0 && xs[j] > t) { xs[j + 1] = xs[j]; j--; }
            xs[j + 1] = t;
        }
        for (int i = 0; i + 1 < k; i += 2) {
            int a = (int)ceilf(xs[i] - 0.5f), b = (int)ceilf(xs[i + 1] - 0.5f);
            if (b > a) m2d_fill(d, a, y, b - a, 1, argb, blend);
        }
    }
    if (xs != stackxs) free(xs);
}

// thick line from (x0,y0) to (x1,y1); width in pixels
void m2d_line(m2d_surf *d, int x0, int y0, int x1, int y1, int width, uint32_t argb, int blend)
{
    if (width < 1) width = 1;
    int half = width / 2;
    if (y0 == y1) {
        int a = x0 < x1 ? x0 : x1, b = x0 < x1 ? x1 : x0;
        m2d_fill(d, a, y0 - half, b - a + 1, width, argb, blend);
        return;
    }
    if (x0 == x1) {
        int a = y0 < y1 ? y0 : y1, b = y0 < y1 ? y1 : y0;
        m2d_fill(d, x0 - half, a, width, b - a + 1, argb, blend);
        return;
    }
    if (width > 1) {
        // a quad around the segment: no overdraw for blended colours
        float dx = (float)(x1 - x0), dy = (float)(y1 - y0), len = sqrtf(dx * dx + dy * dy);
        float nx = -dy / len * width / 2.0f, ny = dx / len * width / 2.0f;
        float q[8] = { x0 + 0.5f + nx, y0 + 0.5f + ny, x1 + 0.5f + nx, y1 + 0.5f + ny,
                       x1 + 0.5f - nx, y1 + 0.5f - ny, x0 + 0.5f - nx, y0 + 0.5f - ny };
        m2d_polygon(d, q, 4, argb, blend);
        return;
    }
    int dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1;
    int dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1;
    int err = dx + dy;
    for (;;) {
        m2d_fill(d, x0, y0, 1, 1, argb, blend);
        if (x0 == x1 && y0 == y1) break;
        int e2 = 2 * err;
        if (e2 >= dy) { err += dy; x0 += sx; }
        if (e2 <= dx) { err += dx; y0 += sy; }
    }
}

// filled circle, or ring of thickness lw when fill == 0
void m2d_circle(m2d_surf *d, int cx, int cy, int r, uint32_t argb, int blend, int fill, int lw)
{
    if (r <= 0) return;
    int r2 = r * r;
    int ri = fill ? -1 : r - (lw < 1 ? 1 : lw);
    int ri2 = ri > 0 ? ri * ri : -1;
    for (int y = -r; y <= r; y++) {
        int yy = y * y;
        int xo = 0;
        while ((xo + 1) * (xo + 1) + yy <= r2) xo++;
        if (fill || ri2 < 0 || yy > ri2) {
            m2d_fill(d, cx - xo, cy + y, 2 * xo + 1, 1, argb, blend);
        } else {
            int xi = 0;
            while ((xi + 1) * (xi + 1) + yy <= ri2) xi++;
            m2d_fill(d, cx - xo, cy + y, xo - xi, 1, argb, blend);
            m2d_fill(d, cx + xi + 1, cy + y, xo - xi, 1, argb, blend);
        }
    }
}

// ---------------------------------------------------------------- init / present / input
// Two back buffers: the CPU draws into one while the other is being shown.
// On the device, presenting (cache flush, GE blit, page flip, vsync wait) runs
// on its own thread, so a frame only has to *draw* within 16.7 ms to hit 60 fps.
static struct { uint32_t *px; uint64_t phy; } bufs[2];
static int cur = 0;

static void point_views(void)
{
    for (int i = 0; i < MAX_VIEWS; i++)
        if (views[i].s) views[i].s->px = (uint32_t *)((uint8_t *)back.px + views[i].y * back.stride) + views[i].x;
}

#ifndef M2D_HOST
#include <pthread.h>
static pthread_t pthr;
static pthread_mutex_t mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv = PTHREAD_COND_INITIALIZER;
static int job = -1, quitting = 0, threaded = 0;

static void show_buffer(int b)
{
    MI_SYS_FlushInvCache(bufs[b].px, back.stride * back.h);
    MI_GFX_Surface_t ss, ds; MI_GFX_Rect_t sr, dr; MI_GFX_Opt_t opt; MI_U16 fence = 0;
    ss.phyAddr = bufs[b].phy; ss.eColorFmt = E_MI_GFX_FMT_ARGB8888;
    ss.u32Width = back.w; ss.u32Height = back.h; ss.u32Stride = back.stride;
    ds.phyAddr = fb_phy + (uint64_t)fb_w * vinfo.yoffset * 4;
    ds.eColorFmt = E_MI_GFX_FMT_ARGB8888;
    ds.u32Width = fb_w; ds.u32Height = fb_h; ds.u32Stride = fb_w * 4;
    int sc = fb_w / back.w < fb_h / back.h ? fb_w / back.w : fb_h / back.h;
    if (sc < 1) sc = 1;
    sr.s32Xpos = 0; sr.s32Ypos = 0; sr.u32Width = back.w; sr.u32Height = back.h;
    dr.u32Width = back.w * sc; dr.u32Height = back.h * sc;
    dr.s32Xpos = (fb_w - (int)dr.u32Width) / 2; dr.s32Ypos = (fb_h - (int)dr.u32Height) / 2;
    memset(&opt, 0, sizeof(opt));
    opt.stClipRect.u32Width = fb_w; opt.stClipRect.u32Height = fb_h;
    opt.eSrcDfbBldOp = E_MI_GFX_DFB_BLD_ONE;
    opt.eRotate = E_MI_GFX_ROTATE_180;
    MI_GFX_BitBlit(&ss, &sr, &ds, &dr, &opt, &fence);
    MI_GFX_WaitAllDone(TRUE, fence);
    ioctl(fb_fd, FBIOPAN_DISPLAY, &vinfo); // waits for vblank
    vinfo.yoffset ^= fb_h;
}

static void *present_thread(void *arg)
{
    (void)arg;
    pthread_mutex_lock(&mtx);
    for (;;) {
        while (job < 0 && !quitting) pthread_cond_wait(&cv, &mtx);
        if (job < 0 && quitting) break;
        int b = job;
        pthread_mutex_unlock(&mtx);
        show_buffer(b);
        pthread_mutex_lock(&mtx);
        job = -1;
        pthread_cond_broadcast(&cv);
    }
    pthread_mutex_unlock(&mtx);
    return NULL;
}
#endif

void m2d_quit(void);

static int alloc_buffer(int i, size_t size)
{
#ifndef M2D_HOST
    MI_PHY phy = 0;
    void *vir = NULL;
    if (MI_SYS_MMA_Alloc(NULL, size, &phy) != 0) return -1;
    if (MI_SYS_Mmap(phy, size, &vir, TRUE) != 0) return -1;
    bufs[i].phy = phy;
    bufs[i].px = (uint32_t *)vir;
#else
    bufs[i].px = (uint32_t *)malloc(size);
    if (!bufs[i].px) return -1;
#endif
    memset(bufs[i].px, 0, size);
    return 0;
}

// The screen's size (the framebuffer's on the device; M2D_SIZE=WxH or 640x480 on
// the host), before m2d_init.
void m2d_screen_size(int *w, int *h)
{
#ifndef M2D_HOST
    int fd = open("/dev/fb0", O_RDWR);
    struct fb_var_screeninfo v;
    if (fd >= 0 && ioctl(fd, FBIOGET_VSCREENINFO, &v) == 0) { *w = v.xres; *h = v.yres; }
    else { *w = 640; *h = 480; }
    if (fd >= 0) close(fd);
#else
    const char *s = getenv("M2D_SIZE");
    if (!s || sscanf(s, "%dx%d", w, h) != 2) { *w = 640; *h = 480; }
#endif
}

int m2d_init(int w, int h)
{
    back.w = w; back.h = h; back.stride = w * 4;
    size_t size = (size_t)back.stride * h;
#ifndef M2D_HOST
    if (MI_SYS_Init() != 0) return -1;
    if (MI_GFX_Open() != 0) return -2;
    fb_fd = open("/dev/fb0", O_RDWR);
    if (fb_fd < 0) return -3;
    ioctl(fb_fd, FBIOGET_FSCREENINFO, &finfo);
    ioctl(fb_fd, FBIOGET_VSCREENINFO, &vinfo);
    fb_w = vinfo.xres; fb_h = vinfo.yres;
    vinfo.yoffset = 0;
    vinfo.yres_virtual = vinfo.yres * 2;
    ioctl(fb_fd, FBIOPUT_VSCREENINFO, &vinfo);
    fb_phy = finfo.smem_start;
    MI_SYS_MemsetPa(fb_phy, 0, fb_w * fb_h * 4 * 2);
    in_fd = open("/dev/input/event0", O_RDONLY | O_NONBLOCK);
#else
    fb_w = w; fb_h = h;
    const char *sp = getenv("M2D_INPUT");
    if (sp) script = fopen(sp, "r");
#endif
    if (alloc_buffer(0, size) != 0) return -4;
    if (alloc_buffer(1, size) != 0) return -5;
    cur = 0;
    back.px = bufs[0].px; back.phy = bufs[0].phy;
    atexit(m2d_quit); // the screen and MI_SYS are left as found, however the game ends
#ifndef M2D_HOST
    const char *t = getenv("M2D_SYNC_PRESENT");
    threaded = !(t && *t == '1');
    if (threaded && pthread_create(&pthr, NULL, present_thread, NULL) != 0) threaded = 0;
#endif
    return 0;
}

int m2d_fb_width(void) { return fb_w; }
int m2d_fb_height(void) { return fb_h; }
int m2d_frame_count(void) { return frame_no; }

// Hands the finished frame to the display and switches drawing to the other buffer.
// Blocks only while the previous frame is still waiting for its vblank.
void m2d_present(void)
{
    frame_no++;
#ifndef M2D_HOST
    if (threaded) {
        pthread_mutex_lock(&mtx);
        while (job >= 0) pthread_cond_wait(&cv, &mtx);
        job = cur;
        pthread_cond_broadcast(&cv);
        pthread_mutex_unlock(&mtx);
    } else {
        show_buffer(cur);
    }
#else
    const char *dir = getenv("M2D_DUMP");
    const char *ev = getenv("M2D_DUMP_EVERY");
    int every = ev ? atoi(ev) : 60;
    if (every < 1) every = 1;
    if (dir && frame_no % every == 0) {
        char path[512];
        snprintf(path, sizeof path, "%s/f%06d.ppm", dir, frame_no);
        FILE *f = fopen(path, "wb");
        if (f) {
            fprintf(f, "P6\n%d %d\n255\n", back.w, back.h);
            for (int i = 0; i < back.w * back.h; i++) {
                uint32_t c = back.px[i];
                unsigned char rgb[3] = { (c >> 16) & 255, (c >> 8) & 255, c & 255 };
                fwrite(rgb, 1, 3, f);
            }
            fclose(f);
        }
    }
#endif
    cur ^= 1;
    back.px = bufs[cur].px; back.phy = bufs[cur].phy;
    point_views();
}

// returns 1 and fills code/value when a key event is available
int m2d_poll_key(int *code, int *value)
{
#ifndef M2D_HOST
    struct input_event ev;
    while (in_fd >= 0 && read(in_fd, &ev, sizeof ev) == sizeof ev) {
        if (ev.type == EV_KEY) { *code = ev.code; *value = ev.value; return 1; }
    }
    return 0;
#else
    if (!script) return 0;
    if (script_frame < 0) {
        if (fscanf(script, "%d %d %d", &script_frame, &script_code, &script_value) != 3) {
            fclose(script); script = NULL; return 0;
        }
    }
    if (frame_no >= script_frame) {
        *code = script_code; *value = script_value;
        script_frame = -1;
        return 1;
    }
    return 0;
#endif
}

void m2d_quit(void)
{
    static int done = 0;
    if (done) return;
    done = 1;
#ifndef M2D_HOST
    if (threaded) {
        pthread_mutex_lock(&mtx);
        while (job >= 0) pthread_cond_wait(&cv, &mtx);
        quitting = 1;
        pthread_cond_broadcast(&cv);
        pthread_mutex_unlock(&mtx);
        pthread_join(pthr, NULL);
    }
    MI_SYS_MemsetPa(fb_phy, 0, fb_w * fb_h * 4 * 2);
    vinfo.yoffset = 0;
    ioctl(fb_fd, FBIOPAN_DISPLAY, &vinfo);
    for (int i = 0; i < 2; i++) {
        MI_SYS_Munmap(bufs[i].px, back.stride * back.h);
        MI_SYS_MMA_Free(bufs[i].phy);
    }
    if (in_fd >= 0) close(in_fd);
    close(fb_fd);
    MI_GFX_Close();
    MI_SYS_Exit();
#else
    free(bufs[0].px); free(bufs[1].px);
#endif
}
