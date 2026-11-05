/* The OpenGL of src/ui/gl_renderer.c in a browser: each function the
   renderer calls is imported from the page (web/ziggurat.js), which runs
   it on the WebGL2 context of the window's canvas. WebGL2 is OpenGL ES 3.0:
   the page makes up for what ES lacks and the renderer uses (texture
   buffers as 2D float textures, BGRA uploads and reads, clamping to a
   transparent border, the shaders' #version), so the renderer's own code
   and shaders stay those of the desktops. Objects are named by integers,
   as in OpenGL, each the page's table index for the context current. */
#ifndef ZIGGURAT_GL_WEB_H
#define ZIGGURAT_GL_WEB_H
#include <stdint.h>
#include <stddef.h>

typedef unsigned int GLenum;
typedef unsigned int GLuint;
typedef int GLint;
typedef int GLsizei;
typedef unsigned int GLbitfield;
typedef float GLfloat;
typedef unsigned char GLboolean;
typedef unsigned char GLubyte;
typedef char GLchar;
typedef long GLsizeiptr;
typedef long GLintptr;

#define GL_NO_ERROR 0
#define GL_ONE 1
#define GL_TRIANGLES 0x0004
#define GL_TRIANGLE_STRIP 0x0005
#define GL_ONE_MINUS_SRC_ALPHA 0x0303
#define GL_CULL_FACE 0x0B44
#define GL_DEPTH_TEST 0x0B71
#define GL_DITHER 0x0BD0
#define GL_BLEND 0x0BE2
#define GL_SCISSOR_TEST 0x0C11
#define GL_UNPACK_ROW_LENGTH 0x0CF2
#define GL_UNPACK_ALIGNMENT 0x0CF5
#define GL_PACK_ROW_LENGTH 0x0D02
#define GL_PACK_ALIGNMENT 0x0D05
#define GL_MAX_TEXTURE_SIZE 0x0D33
#define GL_TEXTURE_2D 0x0DE1
#define GL_TEXTURE_BORDER_COLOR 0x1004
#define GL_UNSIGNED_BYTE 0x1401
#define GL_TEXTURE 0x1702
#define GL_RED 0x1903
#define GL_RGBA 0x1908
#define GL_RENDERER 0x1F01
#define GL_NEAREST 0x2600
#define GL_LINEAR 0x2601
#define GL_NEAREST_MIPMAP_NEAREST 0x2700
#define GL_LINEAR_MIPMAP_NEAREST 0x2701
#define GL_TEXTURE_MAG_FILTER 0x2800
#define GL_TEXTURE_MIN_FILTER 0x2801
#define GL_TEXTURE_WRAP_S 0x2802
#define GL_TEXTURE_WRAP_T 0x2803
#define GL_COLOR_BUFFER_BIT 0x00004000
#define GL_FUNC_ADD 0x8006
#define GL_RGBA8 0x8058
#define GL_BGRA 0x80E1
#define GL_CLAMP_TO_BORDER 0x812D
#define GL_CLAMP_TO_EDGE 0x812F
#define GL_TEXTURE_BASE_LEVEL 0x813C
#define GL_TEXTURE_MAX_LEVEL 0x813D
#define GL_R8 0x8229
#define GL_R32F 0x822E
#define GL_TEXTURE0 0x84C0
#define GL_TEXTURE1 0x84C1
#define GL_TEXTURE2 0x84C2
#define GL_TEXTURE3 0x84C3
#define GL_TEXTURE4 0x84C4
#define GL_TEXTURE5 0x84C5
#define GL_RGBA32F 0x8814
#define GL_STREAM_DRAW 0x88E0
#define GL_FRAGMENT_SHADER 0x8B30
#define GL_VERTEX_SHADER 0x8B31
#define GL_COMPILE_STATUS 0x8B81
#define GL_LINK_STATUS 0x8B82
#define GL_TEXTURE_BUFFER 0x8C2A
#define GL_MAX_TEXTURE_BUFFER_SIZE 0x8C2B
#define GL_READ_FRAMEBUFFER 0x8CA8
#define GL_DRAW_FRAMEBUFFER 0x8CA9
#define GL_FRAMEBUFFER_COMPLETE 0x8CD5
#define GL_COLOR_ATTACHMENT0 0x8CE0
#define GL_FRAMEBUFFER 0x8D40
#define GL_UNIFORM_BUFFER 0x8A11
#define GL_INVALID_INDEX 0xFFFFFFFFu

#define ZGL(name) __attribute__((import_module("ziggurat"),import_name(#name)))
ZGL(glActiveTexture) void glActiveTexture(GLenum texture);
ZGL(glAttachShader) void glAttachShader(GLuint program,GLuint shader);
ZGL(glBindBuffer) void glBindBuffer(GLenum target,GLuint buffer);
ZGL(glBindBufferBase) void glBindBufferBase(GLenum target,GLuint index,GLuint buffer);
ZGL(glBindFragDataLocation) void glBindFragDataLocation(GLuint program,GLuint color,const GLchar *name);
ZGL(glBindFramebuffer) void glBindFramebuffer(GLenum target,GLuint framebuffer);
ZGL(glBindSampler) void glBindSampler(GLuint unit,GLuint sampler);
ZGL(glBindTexture) void glBindTexture(GLenum target,GLuint texture);
ZGL(glBindVertexArray) void glBindVertexArray(GLuint array);
ZGL(glBlendEquation) void glBlendEquation(GLenum mode);
ZGL(glBlendFuncSeparate) void glBlendFuncSeparate(GLenum src_rgb,GLenum dst_rgb,GLenum src_alpha,GLenum dst_alpha);
ZGL(glBlitFramebuffer) void glBlitFramebuffer(GLint sx0,GLint sy0,GLint sx1,GLint sy1,GLint dx0,GLint dy0,GLint dx1,GLint dy1,GLbitfield mask,GLenum filter);
ZGL(glBufferData) void glBufferData(GLenum target,GLsizeiptr size,const void *data,GLenum usage);
ZGL(glBufferSubData) void glBufferSubData(GLenum target,GLintptr offset,GLsizeiptr size,const void *data);
ZGL(glCheckFramebufferStatus) GLenum glCheckFramebufferStatus(GLenum target);
ZGL(glClear) void glClear(GLbitfield mask);
ZGL(glClearColor) void glClearColor(GLfloat r,GLfloat g,GLfloat b,GLfloat a);
ZGL(glCompileShader) void glCompileShader(GLuint shader);
ZGL(glCopyTexSubImage2D) void glCopyTexSubImage2D(GLenum target,GLint level,GLint xoffset,GLint yoffset,GLint x,GLint y,GLsizei width,GLsizei height);
ZGL(glCreateProgram) GLuint glCreateProgram(void);
ZGL(glCreateShader) GLuint glCreateShader(GLenum kind);
ZGL(glDeleteBuffers) void glDeleteBuffers(GLsizei n,const GLuint *buffers);
ZGL(glDeleteFramebuffers) void glDeleteFramebuffers(GLsizei n,const GLuint *framebuffers);
ZGL(glDeleteProgram) void glDeleteProgram(GLuint program);
ZGL(glDeleteSamplers) void glDeleteSamplers(GLsizei n,const GLuint *samplers);
ZGL(glDeleteShader) void glDeleteShader(GLuint shader);
ZGL(glDeleteTextures) void glDeleteTextures(GLsizei n,const GLuint *textures);
ZGL(glDeleteVertexArrays) void glDeleteVertexArrays(GLsizei n,const GLuint *arrays);
ZGL(glDisable) void glDisable(GLenum cap);
ZGL(glDrawArrays) void glDrawArrays(GLenum mode,GLint first,GLsizei count);
ZGL(glDrawArraysInstanced) void glDrawArraysInstanced(GLenum mode,GLint first,GLsizei count,GLsizei instances);
ZGL(glEnable) void glEnable(GLenum cap);
ZGL(glFlush) void glFlush(void);
ZGL(glFramebufferTexture2D) void glFramebufferTexture2D(GLenum target,GLenum attachment,GLenum textarget,GLuint texture,GLint level);
ZGL(glGenBuffers) void glGenBuffers(GLsizei n,GLuint *buffers);
ZGL(glGenFramebuffers) void glGenFramebuffers(GLsizei n,GLuint *framebuffers);
ZGL(glGenSamplers) void glGenSamplers(GLsizei n,GLuint *samplers);
ZGL(glGenTextures) void glGenTextures(GLsizei n,GLuint *textures);
ZGL(glGenVertexArrays) void glGenVertexArrays(GLsizei n,GLuint *arrays);
ZGL(glGetError) GLenum glGetError(void);
ZGL(glGetIntegerv) void glGetIntegerv(GLenum name,GLint *out);
ZGL(glGetProgramInfoLog) void glGetProgramInfoLog(GLuint program,GLsizei capacity,GLsizei *length,GLchar *log);
ZGL(glGetProgramiv) void glGetProgramiv(GLuint program,GLenum name,GLint *out);
ZGL(glGetShaderInfoLog) void glGetShaderInfoLog(GLuint shader,GLsizei capacity,GLsizei *length,GLchar *log);
ZGL(glGetShaderiv) void glGetShaderiv(GLuint shader,GLenum name,GLint *out);
ZGL(glGetUniformBlockIndex) GLuint glGetUniformBlockIndex(GLuint program,const GLchar *name);
ZGL(glGetUniformLocation) GLint glGetUniformLocation(GLuint program,const GLchar *name);
ZGL(glLinkProgram) void glLinkProgram(GLuint program);
ZGL(glPixelStorei) void glPixelStorei(GLenum name,GLint value);
ZGL(glReadPixels) void glReadPixels(GLint x,GLint y,GLsizei width,GLsizei height,GLenum format,GLenum type,void *pixels);
ZGL(glSamplerParameterfv) void glSamplerParameterfv(GLuint sampler,GLenum name,const GLfloat *values);
ZGL(glSamplerParameteri) void glSamplerParameteri(GLuint sampler,GLenum name,GLint value);
ZGL(glScissor) void glScissor(GLint x,GLint y,GLsizei width,GLsizei height);
ZGL(glShaderSource) void glShaderSource(GLuint shader,GLsizei count,const GLchar *const *sources,const GLint *lengths);
ZGL(glTexBuffer) void glTexBuffer(GLenum target,GLenum format,GLuint buffer);
ZGL(glTexImage2D) void glTexImage2D(GLenum target,GLint level,GLint internal,GLsizei width,GLsizei height,GLint border,GLenum format,GLenum type,const void *pixels);
ZGL(glTexParameteri) void glTexParameteri(GLenum target,GLenum name,GLint value);
ZGL(glTexSubImage2D) void glTexSubImage2D(GLenum target,GLint level,GLint x,GLint y,GLsizei width,GLsizei height,GLenum format,GLenum type,const void *pixels);
ZGL(glUniform1f) void glUniform1f(GLint location,GLfloat v);
ZGL(glUniform1fv) void glUniform1fv(GLint location,GLsizei count,const GLfloat *values);
ZGL(glUniform1i) void glUniform1i(GLint location,GLint v);
ZGL(glUniform1uiv) void glUniform1uiv(GLint location,GLsizei count,const GLuint *values);
ZGL(glUniform2f) void glUniform2f(GLint location,GLfloat x,GLfloat y);
ZGL(glUniform3f) void glUniform3f(GLint location,GLfloat x,GLfloat y,GLfloat z);
ZGL(glUniform4f) void glUniform4f(GLint location,GLfloat x,GLfloat y,GLfloat z,GLfloat w);
ZGL(glUniform4fv) void glUniform4fv(GLint location,GLsizei count,const GLfloat *values);
ZGL(glUniform4ui) void glUniform4ui(GLint location,GLuint x,GLuint y,GLuint z,GLuint w);
ZGL(glUniform4uiv) void glUniform4uiv(GLint location,GLsizei count,const GLuint *values);
ZGL(glUniformBlockBinding) void glUniformBlockBinding(GLuint program,GLuint block,GLuint binding);
ZGL(glUseProgram) void glUseProgram(GLuint program);
ZGL(glViewport) void glViewport(GLint x,GLint y,GLsizei width,GLsizei height);

/* The page's side of a window's context. zgl_attach makes the WebGL2
   context of window id's canvas (1), or finds none (0), and the canvas
   then shows only what the context draws. zgl_current makes it the one
   the gl* calls go to: 0, or 1 when the context is lost; generation counts
   the times it was restored, after which every object is gone.
   zgl_renderer writes the name of what draws (WEBGL_debug_renderer_info,
   or "WebGL2") into out. */
ZGL(zgl_attach) int zgl_attach(uint32_t id);
ZGL(zgl_current) int zgl_current(uint32_t id,uint32_t *generation);
ZGL(zgl_renderer) uint32_t zgl_renderer(char *out,uint32_t capacity);
/* The page's text, as src/ui/web.c draws it (zw_text_draw, zw_text_copy). */
ZGL(zw_text_draw) int zw_text_draw(const char *text,uint32_t length,const char *font,uint32_t font_length,double size,double max_width,double offset,uint32_t rgb,double *out);
ZGL(zw_text_copy) void zw_text_copy(uint32_t *pixels);

/* What the desktops' renderer takes from GTK, cairo, Pango and EGL, made
   inert: a browser's renderer has no device domain and no offscreen
   context of its own. */
typedef struct ZglOpaque GdkGLContext;
typedef struct ZglOpaque GdkWindow;
typedef struct ZglOpaque GtkWidget;
typedef struct ZglOpaque PangoLayout;
typedef struct ZglOpaque PangoFontDescription;
typedef struct ZglOpaque cairo_surface_t;
typedef struct ZglOpaque cairo_t;
typedef unsigned long gulong;
typedef void *EGLContext;
typedef void *EGLDisplay;
#define EGL_NO_CONTEXT ((EGLContext)0)
#define EGL_NO_DISPLAY ((EGLDisplay)0)
#endif
