/* Runs translated shader programs on OpenGL through a surfaceless EGL
   context, one invocation per pixel, for the GPU/CPU parity check. */
#include <epoxy/egl.h>
#include <epoxy/gl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static EGLDisplay display = EGL_NO_DISPLAY;
static EGLContext context = EGL_NO_CONTEXT;

int zsg_init(char *log, size_t log_len) {
    if (context != EGL_NO_CONTEXT) return 0;
    PFNEGLGETPLATFORMDISPLAYEXTPROC get_display = (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
    if (get_display) display = get_display(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
    if (display == EGL_NO_DISPLAY) display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    EGLint major, minor;
    if (display == EGL_NO_DISPLAY || !eglInitialize(display, &major, &minor)) {
        snprintf(log, log_len, "no EGL display");
        return 1;
    }
    if (!eglBindAPI(EGL_OPENGL_API)) {
        snprintf(log, log_len, "no desktop OpenGL API");
        return 1;
    }
    const EGLint config_attributes[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT, EGL_NONE};
    EGLConfig config;
    EGLint count = 0;
    if (!eglChooseConfig(display, config_attributes, &config, 1, &count) || count == 0) config = NULL;
    const EGLint attributes[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 3, EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT, EGL_NONE};
    context = eglCreateContext(display, config, EGL_NO_CONTEXT, attributes);
    if (context == EGL_NO_CONTEXT || !eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, context)) {
        snprintf(log, log_len, "no OpenGL 3.3 context (EGL error 0x%x)", eglGetError());
        context = EGL_NO_CONTEXT;
        return 1;
    }
    return 0;
}

static GLuint compile(GLenum kind, const char *source, char *log, size_t log_len) {
    GLuint shader = glCreateShader(kind);
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    GLint ok = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        glGetShaderInfoLog(shader, (GLsizei)log_len, NULL, log);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

/* Draw width x height pixels with the fragment shader `source`, which
   writes result and status; the words fill its ZsWords block. */
int zsg_run(const char *source, const uint32_t *words, uint32_t word_count, uint32_t width, uint32_t height, float *result, float *status, char *log, size_t log_len) {
    static const char *vertex =
        "#version 330 core\n"
        "void main() { vec2 p = vec2(gl_VertexID == 1 ? 3.0 : -1.0, gl_VertexID == 2 ? 3.0 : -1.0); gl_Position = vec4(p, 0.0, 1.0); }\n";
    GLuint vs = compile(GL_VERTEX_SHADER, vertex, log, log_len);
    if (!vs) return 2;
    GLuint fs = compile(GL_FRAGMENT_SHADER, source, log, log_len);
    if (!fs) {
        glDeleteShader(vs);
        return 3;
    }
    GLuint program = glCreateProgram();
    glAttachShader(program, vs);
    glAttachShader(program, fs);
    glBindFragDataLocation(program, 0, "zs_result");
    glBindFragDataLocation(program, 1, "zs_status");
    glLinkProgram(program);
    glDeleteShader(vs);
    glDeleteShader(fs);
    GLint linked = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (!linked) {
        glGetProgramInfoLog(program, (GLsizei)log_len, NULL, log);
        glDeleteProgram(program);
        return 4;
    }
    GLuint textures[2], framebuffer, buffer, array;
    glGenTextures(2, textures);
    for (int i = 0; i < 2; i++) {
        glBindTexture(GL_TEXTURE_2D, textures[i]);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA32F, (GLsizei)width, (GLsizei)height, 0, GL_RGBA, GL_FLOAT, NULL);
    }
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, textures[0], 0);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, GL_TEXTURE_2D, textures[1], 0);
    const GLenum targets[2] = {GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1};
    glDrawBuffers(2, targets);
    int code = 0;
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        snprintf(log, log_len, "incomplete framebuffer");
        code = 5;
    } else {
        size_t vectors = (word_count + 3) / 4;
        if (vectors == 0) vectors = 1;
        uint32_t *padded = calloc(vectors * 4, sizeof(uint32_t));
        memcpy(padded, words, word_count * sizeof(uint32_t));
        glGenBuffers(1, &buffer);
        glBindBuffer(GL_UNIFORM_BUFFER, buffer);
        glBufferData(GL_UNIFORM_BUFFER, (GLsizeiptr)(vectors * 16), padded, GL_STATIC_DRAW);
        free(padded);
        GLuint block = glGetUniformBlockIndex(program, "ZsWords");
        if (block != GL_INVALID_INDEX) {
            glUniformBlockBinding(program, block, 0);
            glBindBufferBase(GL_UNIFORM_BUFFER, 0, buffer);
        }
        glGenVertexArrays(1, &array);
        glBindVertexArray(array);
        glViewport(0, 0, (GLsizei)width, (GLsizei)height);
        glUseProgram(program);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        glReadBuffer(GL_COLOR_ATTACHMENT0);
        glReadPixels(0, 0, (GLsizei)width, (GLsizei)height, GL_RGBA, GL_FLOAT, result);
        glReadBuffer(GL_COLOR_ATTACHMENT1);
        glReadPixels(0, 0, (GLsizei)width, (GLsizei)height, GL_RGBA, GL_FLOAT, status);
        GLenum error = glGetError();
        if (error != GL_NO_ERROR) {
            snprintf(log, log_len, "OpenGL error 0x%x", error);
            code = 6;
        }
        glDeleteVertexArrays(1, &array);
        glDeleteBuffers(1, &buffer);
    }
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glDeleteFramebuffers(1, &framebuffer);
    glDeleteTextures(2, textures);
    glDeleteProgram(program);
    return code;
}
