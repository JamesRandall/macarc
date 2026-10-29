// Draws the Archimedes' picture with OpenGL (or OpenGL ES), as the Mac app's
// Metal renderer does: sharp pixels, smooth, or a CRT.

#pragma once

#include <stdbool.h>
#include <stdint.h>

typedef struct ArchGL ArchGL;

/// The styles, as `DisplayStyle`.
enum {
    ARCH_GL_SHARP = 0,
    ARCH_GL_SMOOTH = 1,
    ARCH_GL_CRT = 2,
};

/// The part of the frame shown (the border can be cropped), in frame pixels.
typedef struct {
    int x, y, width, height;
} ArchGLCrop;

/// With the GL context current. NULL if the shaders don't build (the
/// message, if `error` isn't NULL, is to be freed).
ArchGL *arch_gl_create(char **error);
/// With the GL context current.
void arch_gl_destroy(ArchGL *gl);
/// A frame of 0xAARRGGBB pixels, `width` x `height` (VIDC's frame size
/// changes with the screen mode; the texture follows it).
void arch_gl_upload(ArchGL *gl, const uint32_t *pixels, int width, int height);
/// Draws `crop` of the last frame into the framebuffer that's bound,
/// letterboxed to `aspect` (the shown part's width over its height, as the
/// monitor shows it).
void arch_gl_draw(ArchGL *gl, int framebuffer_width, int framebuffer_height, int style, ArchGLCrop crop, double aspect);
/// Renders offscreen, as `arch_gl_draw` would at that size, into `pixels`
/// (0xAARRGGBB, top row first).
bool arch_gl_render_image(ArchGL *gl, int width, int height, int style, ArchGLCrop crop, double aspect, uint32_t *pixels);
