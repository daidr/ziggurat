/* Shader effects on OpenGL for the Linux renderer. A surfaceless EGL
   context, independent of the window system, runs translated programs as
   fragment shaders: the content (a capture plane or the target beneath a
   backdrop shader) is uploaded as a texture, the shader draws into a
   framebuffer and the result is read back into the software plane. Zig
   decides when to use it; programs are linked outside paint. */
#include <epoxy/egl.h>
#include <epoxy/gl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ZGL_SLOTS 16
#define ZGL_WORDS 4096

typedef struct ZglParams {float a[4],b[4],shape[4],clip[4],c[4],d[4];uint32_t plane[4];} ZglParams;
_Static_assert(sizeof(ZglParams) == 112, "effect parameter packing");

typedef struct ZglEffects {
    EGLDisplay display, saved_display;
    EGLContext context, saved_context;
    EGLSurface saved_draw, saved_read;
    GLuint programs[ZGL_SLOTS];
    GLuint vertex, vertex_array, buffers[2], textures[2], framebuffer;
    GLint max_size;
    uint32_t sizes[2][2];
    uint64_t passes;
    int software;
    char renderer[128];
} ZglEffects;

static void report(char *log, size_t log_len, const char *message) {
    if (log_len) snprintf(log, log_len, "%s", message);
}

/* The toolkit may keep its own EGL context current on this thread and
   assume it stays so: it is restored after every use. */
static int current(ZglEffects *gl) {
    gl->saved_display = eglGetCurrentDisplay();
    gl->saved_context = eglGetCurrentContext();
    gl->saved_draw = eglGetCurrentSurface(EGL_DRAW);
    gl->saved_read = eglGetCurrentSurface(EGL_READ);
    return eglMakeCurrent(gl->display, EGL_NO_SURFACE, EGL_NO_SURFACE, gl->context) ? 0 : 1;
}
static void release(ZglEffects *gl) {
    if (gl->saved_context != EGL_NO_CONTEXT && gl->saved_display != EGL_NO_DISPLAY) eglMakeCurrent(gl->saved_display, gl->saved_draw, gl->saved_read, gl->saved_context);
    else eglMakeCurrent(gl->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
}

static GLuint compile(GLenum kind, const char *const *sources, GLsizei count, char *log, size_t log_len) {
    GLuint shader = glCreateShader(kind);
    glShaderSource(shader, count, sources, NULL);
    glCompileShader(shader);
    GLint ok = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        if (log_len) glGetShaderInfoLog(shader, (GLsizei)log_len, NULL, log);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

void zgl_effects_destroy(ZglEffects *gl) {
    if (!gl) return;
    if (gl->context != EGL_NO_CONTEXT && current(gl) == 0) {
        for (int i = 0; i < ZGL_SLOTS; i++)
            if (gl->programs[i]) glDeleteProgram(gl->programs[i]);
        if (gl->vertex) glDeleteShader(gl->vertex);
        if (gl->vertex_array) glDeleteVertexArrays(1, &gl->vertex_array);
        glDeleteBuffers(2, gl->buffers);
        glDeleteTextures(2, gl->textures);
        if (gl->framebuffer) glDeleteFramebuffers(1, &gl->framebuffer);
        release(gl);
    }
    if (gl->context != EGL_NO_CONTEXT) eglDestroyContext(gl->display, gl->context);
    free(gl);
}

/* An OpenGL 3.3 context for effects, or NULL. Without `force` a software
   rasterizer (llvmpipe, softpipe) is not used. */
ZglEffects *zgl_effects_create(int force, char *log, size_t log_len) {
    if (!epoxy_has_egl()) {
        report(log, log_len, "no EGL library");
        return NULL;
    }
    ZglEffects *gl = calloc(1, sizeof(ZglEffects));
    if (!gl) {
        report(log, log_len, "out of memory");
        return NULL;
    }
    gl->display = EGL_NO_DISPLAY;
    gl->context = EGL_NO_CONTEXT;
    PFNEGLGETPLATFORMDISPLAYEXTPROC get_display = (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
    if (get_display) gl->display = get_display(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
    if (gl->display == EGL_NO_DISPLAY) gl->display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    EGLint major, minor;
    if (gl->display == EGL_NO_DISPLAY || !eglInitialize(gl->display, &major, &minor) || !eglBindAPI(EGL_OPENGL_API)) {
        report(log, log_len, "no EGL display with desktop OpenGL");
        free(gl);
        return NULL;
    }
    const EGLint config_attributes[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT, EGL_NONE};
    EGLConfig config;
    EGLint count = 0;
    if (!eglChooseConfig(gl->display, config_attributes, &config, 1, &count) || count == 0) config = NULL;
    const EGLint attributes[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 3, EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT, EGL_NONE};
    gl->context = eglCreateContext(gl->display, config, EGL_NO_CONTEXT, attributes);
    if (gl->context == EGL_NO_CONTEXT || current(gl) != 0) {
        report(log, log_len, "no OpenGL 3.3 context");
        zgl_effects_destroy(gl);
        return NULL;
    }
    const char *name = (const char *)glGetString(GL_RENDERER);
    snprintf(gl->renderer, sizeof(gl->renderer), "%s", name ? name : "");
    gl->software = strstr(gl->renderer, "llvmpipe") || strstr(gl->renderer, "softpipe") || strstr(gl->renderer, "SWR") || strstr(gl->renderer, "Software");
    if (gl->software && !force) {
        report(log, log_len, "software rasterizer");
        release(gl);
        zgl_effects_destroy(gl);
        return NULL;
    }
    static const char *vertex = "#version 330 core\nvoid main() { vec2 p = vec2(gl_VertexID == 1 ? 3.0 : -1.0, gl_VertexID == 2 ? 3.0 : -1.0); gl_Position = vec4(p, 0.0, 1.0); }\n";
    gl->vertex = compile(GL_VERTEX_SHADER, &vertex, 1, log, log_len);
    glGetIntegerv(GL_MAX_TEXTURE_SIZE, &gl->max_size);
    glGenVertexArrays(1, &gl->vertex_array);
    glGenBuffers(2, gl->buffers);
    glBindBuffer(GL_UNIFORM_BUFFER, gl->buffers[0]);
    glBufferData(GL_UNIFORM_BUFFER, ZGL_WORDS * 4, NULL, GL_STREAM_DRAW);
    glBindBuffer(GL_UNIFORM_BUFFER, gl->buffers[1]);
    glBufferData(GL_UNIFORM_BUFFER, sizeof(ZglParams), NULL, GL_STREAM_DRAW);
    glBindBuffer(GL_UNIFORM_BUFFER, 0);
    glGenTextures(2, gl->textures);
    for (int i = 0; i < 2; i++) {
        glBindTexture(GL_TEXTURE_2D, gl->textures[i]);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    }
    glBindTexture(GL_TEXTURE_2D, 0);
    glGenFramebuffers(1, &gl->framebuffer);
    const int failed = !gl->vertex || glGetError() != GL_NO_ERROR;
    release(gl);
    if (failed) {
        if (log_len && !log[0]) report(log, log_len, "OpenGL setup failed");
        zgl_effects_destroy(gl);
        return NULL;
    }
    return gl;
}

const char *zgl_effects_renderer(ZglEffects *gl) { return gl->renderer; }
int zgl_effects_software(ZglEffects *gl) { return gl->software; }
uint64_t zgl_effects_passes(ZglEffects *gl) { return gl->passes; }

/* Link the fragment shader `source` (without #version) into `slot`.
   Returns 0, 1 when the context is lost, 2 on a compile or link error. */
int zgl_effects_install(ZglEffects *gl, uint32_t slot, const char *source, char *log, size_t log_len) {
    if (log_len) log[0] = 0;
    if (slot >= ZGL_SLOTS || current(gl) != 0) return 1;
    const char *sources[2] = {"#version 330 core\n", source};
    GLuint fragment = compile(GL_FRAGMENT_SHADER, sources, 2, log, log_len);
    int code = 2;
    if (fragment) {
        GLuint program = glCreateProgram();
        glAttachShader(program, gl->vertex);
        glAttachShader(program, fragment);
        glBindFragDataLocation(program, 0, "zs_out");
        glLinkProgram(program);
        glDeleteShader(fragment);
        GLint linked = 0;
        glGetProgramiv(program, GL_LINK_STATUS, &linked);
        if (linked) {
            GLuint block = glGetUniformBlockIndex(program, "ZsWords");
            if (block != GL_INVALID_INDEX) glUniformBlockBinding(program, block, 0);
            block = glGetUniformBlockIndex(program, "ZsParams");
            if (block != GL_INVALID_INDEX) glUniformBlockBinding(program, block, 1);
            glUseProgram(program);
            glUniform1i(glGetUniformLocation(program, "zs_content"), 0);
            glUseProgram(0);
            if (gl->programs[slot]) glDeleteProgram(gl->programs[slot]);
            gl->programs[slot] = program;
            code = 0;
        } else {
            if (log_len) glGetProgramInfoLog(program, (GLsizei)log_len, NULL, log);
            glDeleteProgram(program);
        }
    }
    release(gl);
    return code;
}

static int texture_size(ZglEffects *gl, int index, uint32_t width, uint32_t height) {
    if ((GLint)width > gl->max_size || (GLint)height > gl->max_size) return 1;
    if (gl->sizes[index][0] >= width && gl->sizes[index][1] >= height) return 0;
    if (width < gl->sizes[index][0]) width = gl->sizes[index][0];
    if (height < gl->sizes[index][1]) height = gl->sizes[index][1];
    glBindTexture(GL_TEXTURE_2D, gl->textures[index]);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, (GLsizei)width, (GLsizei)height, 0, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, NULL);
    gl->sizes[index][0] = width;
    gl->sizes[index][1] = height;
    return 0;
}

/* Run the program in `slot` over output pixels (0..out_width, 0..out_height)
   reading `content` (premultiplied ARGB32, strides in pixels) and write
   them to `out`. Returns 0, or nonzero when OpenGL failed; `out` may then
   hold partial results. */
int zgl_effects_run(ZglEffects *gl, uint32_t slot, const uint32_t *words, uint32_t word_count, const ZglParams *params, const uint32_t *content, uint32_t content_width, uint32_t content_height, size_t content_stride, uint32_t *out, uint32_t out_width, uint32_t out_height, size_t out_stride) {
    if (slot >= ZGL_SLOTS || !gl->programs[slot] || word_count > ZGL_WORDS || !content_width || !content_height || !out_width || !out_height) return 1;
    if (current(gl) != 0) return 2;
    int code = 0;
    if (texture_size(gl, 0, content_width, content_height) || texture_size(gl, 1, out_width, out_height)) code = 3;
    if (!code) {
        glBindBuffer(GL_UNIFORM_BUFFER, gl->buffers[0]);
        if (word_count) glBufferSubData(GL_UNIFORM_BUFFER, 0, (GLsizeiptr)word_count * 4, words);
        glBindBuffer(GL_UNIFORM_BUFFER, gl->buffers[1]);
        glBufferSubData(GL_UNIFORM_BUFFER, 0, sizeof(ZglParams), params);
        glBindBuffer(GL_UNIFORM_BUFFER, 0);
        glBindBufferBase(GL_UNIFORM_BUFFER, 0, gl->buffers[0]);
        glBindBufferBase(GL_UNIFORM_BUFFER, 1, gl->buffers[1]);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, gl->textures[0]);
        glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
        glPixelStorei(GL_UNPACK_ROW_LENGTH, (GLint)content_stride);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, (GLsizei)content_width, (GLsizei)content_height, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, content);
        glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
        glBindFramebuffer(GL_FRAMEBUFFER, gl->framebuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, gl->textures[1], 0);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) code = 4;
    }
    if (!code) {
        glViewport(0, 0, (GLsizei)out_width, (GLsizei)out_height);
        glDisable(GL_BLEND);
        glDisable(GL_SCISSOR_TEST);
        glUseProgram(gl->programs[slot]);
        glBindVertexArray(gl->vertex_array);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        glBindVertexArray(0);
        glUseProgram(0);
        glPixelStorei(GL_PACK_ALIGNMENT, 4);
        glPixelStorei(GL_PACK_ROW_LENGTH, (GLint)out_stride);
        glReadPixels(0, 0, (GLsizei)out_width, (GLsizei)out_height, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, out);
        glPixelStorei(GL_PACK_ROW_LENGTH, 0);
        if (glGetError() != GL_NO_ERROR) code = 5;
        else gl->passes++;
    }
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glBindTexture(GL_TEXTURE_2D, 0);
    release(gl);
    return code;
}
