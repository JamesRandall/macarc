// The picture, drawn with OpenGL 3.2 core or OpenGL ES 3, whichever GTK's
// GL area gives. The fragment shader is the Mac app's Metal one
// (Apps/MacArch/Rendering/Renderer.swift) in GLSL.

#include "ArchGL.h"

#include <epoxy/gl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct ArchGL {
    GLuint program;
    GLuint vertexArray;
    GLuint texture;
    /// The texture's size (the last frame's).
    int width, height;
    GLint styleUniform, viewportHeightUniform, linesUniform, topUniform, originUniform, sizeUniform, textureSizeUniform;
};

static const char *vertexSource =
    "out vec2 uv;\n"
    "void main() {\n"
    "    vec2 corners[4] = vec2[4](vec2(-1.0, -1.0), vec2(1.0, -1.0), vec2(-1.0, 1.0), vec2(1.0, 1.0));\n"
    "    vec2 corner = corners[gl_VertexID];\n"
    "    gl_Position = vec4(corner, 0.0, 1.0);\n"
    "    uv = vec2((corner.x + 1.0) * 0.5, (1.0 - corner.y) * 0.5);\n"
    "}\n";

// The texture holds the frame's bytes as they are in memory (B, G, R, A),
// so colours are .bgr.
static const char *fragmentSource =
    "in vec2 uv;\n"
    "out vec4 fragColour;\n"
    "uniform sampler2D frame;\n"
    "uniform int style;\n"
    "uniform float viewportHeight;\n"
    "// The shown part of the frame: its raster lines, its top line, and\n"
    "// where it is in the texture.\n"
    "uniform float lines;\n"
    "uniform float top;\n"
    "uniform vec2 origin;\n"
    "uniform vec2 size;\n"
    "uniform vec2 textureSize;\n"
    "\n"
    "vec3 texel(vec2 p) { return texture(frame, p).bgr; }\n"
    "\n"
    "// A raster line's colour at x in linear light, with a little horizontal\n"
    "// spread like a real spot.\n"
    "vec3 rasterLine(float x, float line) {\n"
    "    float y = (top + clamp(line, 0.0, lines - 1.0) + 0.5) / textureSize.y;\n"
    "    float dx = 0.6 / textureSize.x;\n"
    "    vec3 c = texel(vec2(x, y)) * 0.5 + texel(vec2(x - dx, y)) * 0.25 + texel(vec2(x + dx, y)) * 0.25;\n"
    "    return pow(c, vec3(2.2));\n"
    "}\n"
    "\n"
    "// Gaussian beam profile across the line; bright lines are wider.\n"
    "vec3 spot(vec3 c, float d) {\n"
    "    vec3 w = mix(vec3(0.22), vec3(0.34), sqrt(c));\n"
    "    return c * exp(-0.5 * d * d / (w * w));\n"
    "}\n"
    "\n"
    "void main() {\n"
    "    vec2 p = origin + uv * size;\n"
    "    if (style == 0 || style == 1) {\n"
    "        fragColour = vec4(texel(p), 1.0);\n"
    "        return;\n"
    "    }\n"
    "    // Scanlines fade out where there are too few pixels per line to show them.\n"
    "    float perLine = viewportHeight / lines;\n"
    "    float strength = clamp((perLine - 1.5) / 1.5, 0.0, 1.0);\n"
    "    float y = uv.y * lines;\n"
    "    float line = floor(y);\n"
    "    float off = y - line - 0.5;\n"
    "    float other = off < 0.0 ? line - 1.0 : line + 1.0;\n"
    "    vec3 a = rasterLine(p.x, line);\n"
    "    vec3 b = rasterLine(p.x, other);\n"
    "    vec3 scanned = (spot(a, off) + spot(b, 1.0 - abs(off))) * 1.2;\n"
    "    vec3 c = mix(mix(a, b, abs(off) * 0.5), scanned, strength);\n"
    "    // An aperture grille, when there's room for it.\n"
    "    if (perLine >= 3.0) {\n"
    "        int stripe = int(gl_FragCoord.x) % 3;\n"
    "        c *= vec3(stripe == 0 ? 1.0 : 0.9, stripe == 1 ? 1.0 : 0.9, stripe == 2 ? 1.0 : 0.9) * 1.06;\n"
    "    }\n"
    "    // A little vignetting.\n"
    "    vec2 d = uv - 0.5;\n"
    "    c *= 1.0 - dot(d, d) * 0.25;\n"
    "    fragColour = vec4(pow(clamp(c, 0.0, 1.0), vec3(1.0 / 2.2)), 1.0);\n"
    "}\n";

static char *shaderLog(GLuint object, bool program) {
    GLint length = 0;
    if (program) {
        glGetProgramiv(object, GL_INFO_LOG_LENGTH, &length);
    } else {
        glGetShaderiv(object, GL_INFO_LOG_LENGTH, &length);
    }
    char *log = calloc((size_t)length + 1, 1);
    if (program) {
        glGetProgramInfoLog(object, length, NULL, log);
    } else {
        glGetShaderInfoLog(object, length, NULL, log);
    }
    return log;
}

static GLuint compile(GLenum type, const char *body, char **error) {
    const char *header = epoxy_is_desktop_gl()
        ? "#version 150\n"
        : "#version 300 es\nprecision highp float;\nprecision highp int;\n";
    const char *sources[2] = { header, body };
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 2, sources, NULL);
    glCompileShader(shader);
    GLint ok = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        if (error) *error = shaderLog(shader, false);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

/// (Re)allocates the texture for `width` x `height`, black.
static void allocate(ArchGL *gl, int width, int height) {
    gl->width = width;
    gl->height = height;
    glBindTexture(GL_TEXTURE_2D, gl->texture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    uint32_t *black = calloc((size_t)width * (size_t)height, 4);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, black);
    free(black);
}

ArchGL *arch_gl_create(char **error) {
    GLuint vertex = compile(GL_VERTEX_SHADER, vertexSource, error);
    if (!vertex) return NULL;
    GLuint fragment = compile(GL_FRAGMENT_SHADER, fragmentSource, error);
    if (!fragment) {
        glDeleteShader(vertex);
        return NULL;
    }
    GLuint program = glCreateProgram();
    glAttachShader(program, vertex);
    glAttachShader(program, fragment);
    glLinkProgram(program);
    glDeleteShader(vertex);
    glDeleteShader(fragment);
    GLint ok = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &ok);
    if (!ok) {
        if (error) *error = shaderLog(program, true);
        glDeleteProgram(program);
        return NULL;
    }

    ArchGL *gl = calloc(1, sizeof(ArchGL));
    gl->program = program;
    gl->styleUniform = glGetUniformLocation(program, "style");
    gl->viewportHeightUniform = glGetUniformLocation(program, "viewportHeight");
    gl->linesUniform = glGetUniformLocation(program, "lines");
    gl->topUniform = glGetUniformLocation(program, "top");
    gl->originUniform = glGetUniformLocation(program, "origin");
    gl->sizeUniform = glGetUniformLocation(program, "size");
    gl->textureSizeUniform = glGetUniformLocation(program, "textureSize");
    glGenVertexArrays(1, &gl->vertexArray);

    glGenTextures(1, &gl->texture);
    glBindTexture(GL_TEXTURE_2D, gl->texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    // Black until the first frame.
    allocate(gl, 640, 256);
    return gl;
}

void arch_gl_destroy(ArchGL *gl) {
    if (!gl) return;
    glDeleteTextures(1, &gl->texture);
    glDeleteVertexArrays(1, &gl->vertexArray);
    glDeleteProgram(gl->program);
    free(gl);
}

void arch_gl_upload(ArchGL *gl, const uint32_t *pixels, int width, int height) {
    if (width <= 0 || height <= 0) return;
    if (width != gl->width || height != gl->height) {
        allocate(gl, width, height);
    }
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    glBindTexture(GL_TEXTURE_2D, gl->texture);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
}

void arch_gl_draw(ArchGL *gl, int framebuffer_width, int framebuffer_height, int style, ArchGLCrop crop, double aspect) {
    glDisable(GL_BLEND);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_SCISSOR_TEST);
    glViewport(0, 0, framebuffer_width, framebuffer_height);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);

    // Letterboxed to the monitor's shape.
    double width = framebuffer_width, height = framebuffer_width / aspect;
    if (height > framebuffer_height) {
        height = framebuffer_height;
        width = height * aspect;
    }
    glViewport((GLint)((framebuffer_width - width) / 2), (GLint)((framebuffer_height - height) / 2),
               (GLsizei)width, (GLsizei)height);

    // A crop that's outside the texture (a frame of another size, before the
    // next one's uploaded) shows the whole of it.
    if (crop.width <= 0 || crop.height <= 0 || crop.x < 0 || crop.y < 0
        || crop.x + crop.width > gl->width || crop.y + crop.height > gl->height) {
        crop = (ArchGLCrop){ 0, 0, gl->width, gl->height };
    }
    float tw = (float)gl->width, th = (float)gl->height;

    glUseProgram(gl->program);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, gl->texture);
    GLint filter = style == ARCH_GL_SHARP ? GL_NEAREST : GL_LINEAR;
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, filter);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, filter);
    glUniform1i(glGetUniformLocation(gl->program, "frame"), 0);
    glUniform1i(gl->styleUniform, style);
    glUniform1f(gl->viewportHeightUniform, (GLfloat)height);
    glUniform1f(gl->linesUniform, (GLfloat)crop.height);
    glUniform1f(gl->topUniform, (GLfloat)crop.y);
    glUniform2f(gl->originUniform, crop.x / tw, crop.y / th);
    glUniform2f(gl->sizeUniform, crop.width / tw, crop.height / th);
    glUniform2f(gl->textureSizeUniform, tw, th);
    glBindVertexArray(gl->vertexArray);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindVertexArray(0);
    glUseProgram(0);
}

bool arch_gl_render_image(ArchGL *gl, int width, int height, int style, ArchGLCrop crop, double aspect, uint32_t *pixels) {
    GLint previous = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &previous);
    GLuint framebuffer = 0, target = 0;
    glGenFramebuffers(1, &framebuffer);
    glGenTextures(1, &target);
    glBindTexture(GL_TEXTURE_2D, target);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, target, 0);
    bool ok = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
    if (ok) {
        arch_gl_draw(gl, width, height, style, crop, aspect);
        uint8_t *rgba = malloc((size_t)width * (size_t)height * 4);
        glPixelStorei(GL_PACK_ALIGNMENT, 4);
        glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
        // GL's rows go bottom up.
        for (int y = 0; y < height; y++) {
            const uint8_t *row = rgba + (size_t)(height - 1 - y) * (size_t)width * 4;
            for (int x = 0; x < width; x++) {
                const uint8_t *p = row + x * 4;
                pixels[(size_t)y * (size_t)width + (size_t)x] =
                    0xFF000000u | (uint32_t)p[0] << 16 | (uint32_t)p[1] << 8 | p[2];
            }
        }
        free(rgba);
    }
    glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)previous);
    glDeleteFramebuffers(1, &framebuffer);
    glDeleteTextures(1, &target);
    return ok;
}
