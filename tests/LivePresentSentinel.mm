#include "LivePresentSentinel.h"

#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>

#include <array>
#include <algorithm>
#include <cstdint>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include "../include/AppGL/glcorearb.h"
#include "../src/context/GLContext.h"
#include "../src/runtime/AppGLRuntime.h"

namespace appgl::tests {
namespace {

constexpr GLsizei kTileSize = 8;
constexpr GLsizei kColumns = 16;
constexpr GLsizei kRows = 8;
constexpr GLsizei kDraws = kColumns * kRows;
constexpr GLsizei kCanvasWidth = kColumns * kTileSize;
constexpr GLsizei kCanvasHeight = kRows * kTileSize;
constexpr GLsizei kVerticesPerDraw = 6;
constexpr GLsizei kFloatsPerVertex = 5;
constexpr GLsizei kStrideBytes = kFloatsPerVertex * sizeof(float);

struct IndirectCommand {
    GLuint count;
    GLuint instanceCount;
    GLuint first;
    GLuint baseInstance;
};

const char* kVS =
    "#version 430 core\n"
    "layout(location = 0) in vec2 aPos;\n"
    "layout(location = 1) in vec3 aColor;\n"
    "out vec3 vColor;\n"
    "void main() {\n"
    "    vColor = aColor;\n"
    "    gl_Position = vec4(aPos, 0.0, 1.0);\n"
    "}\n";

const char* kFS =
    "#version 430 core\n"
    "in vec3 vColor;\n"
    "layout(location = 0) out vec4 fragColor;\n"
    "void main() {\n"
    "    fragColor = vec4(vColor, 1.0);\n"
    "}\n";

void pumpRunLoopOnce() {
    [[NSRunLoop mainRunLoop]
        runMode:NSDefaultRunLoopMode
     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
}

std::string shaderInfoLog(GLDispatchTable& gl, GLuint shader) {
    GLint length = 0;
    gl.glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &length);
    if (length <= 1) {
        return {};
    }
    std::string log(static_cast<std::size_t>(length), '\0');
    GLsizei written = 0;
    gl.glGetShaderInfoLog(shader, length, &written, log.data());
    log.resize(static_cast<std::size_t>(std::max<GLsizei>(written, 0)));
    return log;
}

std::string programInfoLog(GLDispatchTable& gl, GLuint program) {
    GLint length = 0;
    gl.glGetProgramiv(program, GL_INFO_LOG_LENGTH, &length);
    if (length <= 1) {
        return {};
    }
    std::string log(static_cast<std::size_t>(length), '\0');
    GLsizei written = 0;
    gl.glGetProgramInfoLog(program, length, &written, log.data());
    log.resize(static_cast<std::size_t>(std::max<GLsizei>(written, 0)));
    return log;
}

GLuint compileShader(GLDispatchTable& gl,
                     GLenum stage,
                     const char* source,
                     std::string& message) {
    const GLuint shader = gl.glCreateShader(stage);
    gl.glShaderSource(shader, 1, &source, nullptr);
    gl.glCompileShader(shader);
    GLint compiled = GL_FALSE;
    gl.glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (compiled != GL_TRUE) {
        message = shaderInfoLog(gl, shader);
        gl.glDeleteShader(shader);
        return 0;
    }
    return shader;
}

GLuint buildProgram(GLDispatchTable& gl, std::string& message) {
    const GLuint vs = compileShader(gl, GL_VERTEX_SHADER, kVS, message);
    if (vs == 0) {
        message = "live-present MDI vertex shader failed: " + message;
        return 0;
    }
    const GLuint fs = compileShader(gl, GL_FRAGMENT_SHADER, kFS, message);
    if (fs == 0) {
        gl.glDeleteShader(vs);
        message = "live-present MDI fragment shader failed: " + message;
        return 0;
    }

    const GLuint program = gl.glCreateProgram();
    gl.glAttachShader(program, vs);
    gl.glAttachShader(program, fs);
    gl.glLinkProgram(program);
    gl.glDeleteShader(vs);
    gl.glDeleteShader(fs);

    GLint linked = GL_FALSE;
    gl.glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (linked != GL_TRUE) {
        message = "live-present MDI program link failed: " +
            programInfoLog(gl, program);
        gl.glDeleteProgram(program);
        return 0;
    }
    return program;
}

void pushVertex(std::vector<float>& vertices,
                float x,
                float y,
                float r,
                float g,
                float b) {
    vertices.push_back(x);
    vertices.push_back(y);
    vertices.push_back(r);
    vertices.push_back(g);
    vertices.push_back(b);
}

void buildWall(std::vector<float>& vertices,
               std::vector<IndirectCommand>& commands) {
    vertices.clear();
    commands.clear();
    vertices.reserve(static_cast<std::size_t>(kDraws * kVerticesPerDraw * kFloatsPerVertex));
    commands.reserve(static_cast<std::size_t>(kDraws));

    for (GLsizei row = 0; row < kRows; ++row) {
        for (GLsizei col = 0; col < kColumns; ++col) {
            const GLsizei draw = row * kColumns + col;
            const float x0 = -1.0f + 2.0f * static_cast<float>(col) /
                static_cast<float>(kColumns);
            const float x1 = -1.0f + 2.0f * static_cast<float>(col + 1) /
                static_cast<float>(kColumns);
            const float y0 = -1.0f + 2.0f * static_cast<float>(row) /
                static_cast<float>(kRows);
            const float y1 = -1.0f + 2.0f * static_cast<float>(row + 1) /
                static_cast<float>(kRows);
            const float r = 0.45f + 0.45f * static_cast<float>((col % 4) + 1) / 4.0f;
            const float g = 0.35f + 0.55f * static_cast<float>((row % 4) + 1) / 4.0f;
            const float b = 0.30f + 0.50f * static_cast<float>(((draw / 3) % 4) + 1) / 4.0f;

            pushVertex(vertices, x0, y0, r, g, b);
            pushVertex(vertices, x1, y0, r, g, b);
            pushVertex(vertices, x1, y1, r, g, b);
            pushVertex(vertices, x0, y0, r, g, b);
            pushVertex(vertices, x1, y1, r, g, b);
            pushVertex(vertices, x0, y1, r, g, b);

            commands.push_back({
                static_cast<GLuint>(kVerticesPerDraw),
                1u,
                static_cast<GLuint>(draw * kVerticesPerDraw),
                0u,
            });
        }
    }
}

bool pixelIsCovered(const std::array<std::uint8_t, 4>& pixel) {
    return pixel[0] > 24 || pixel[1] > 24 || pixel[2] > 24;
}

int countCoveredTiles(GLDispatchTable& gl) {
    int covered = 0;
    gl.glReadBuffer(GL_BACK);
    for (GLsizei row = 0; row < kRows; ++row) {
        for (GLsizei col = 0; col < kColumns; ++col) {
            std::array<std::uint8_t, 4> pixel = {};
            gl.glReadPixels(col * kTileSize + kTileSize / 2,
                            row * kTileSize + kTileSize / 2,
                            1, 1, GL_RGBA, GL_UNSIGNED_BYTE,
                            pixel.data());
            if (pixelIsCovered(pixel)) {
                ++covered;
            }
        }
    }
    return covered;
}

bool expectNoError(GLDispatchTable& gl,
                   const char* label,
                   std::string& message) {
    const GLenum error = gl.glGetError();
    if (error == GL_NO_ERROR) {
        return true;
    }
    std::ostringstream stream;
    stream << label << " GL error 0x" << std::hex << error;
    message = stream.str();
    return false;
}

bool renderMDIFrame(GLDispatchTable& gl,
                    GLuint program,
                    GLuint vao,
                    GLuint indirectBuffer,
                    std::string& message) {
    gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
    gl.glViewport(0, 0, kCanvasWidth, kCanvasHeight);
    gl.glDisable(GL_BLEND);
    gl.glDisable(GL_CULL_FACE);
    gl.glDisable(GL_DEPTH_TEST);
    gl.glDisable(GL_SCISSOR_TEST);
    gl.glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    gl.glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    gl.glUseProgram(program);
    gl.glBindVertexArray(vao);
    gl.glBindBuffer(GL_DRAW_INDIRECT_BUFFER, indirectBuffer);
    gl.glMultiDrawArraysIndirect(GL_TRIANGLES, nullptr, kDraws, 0);
    gl.glBindBuffer(GL_DRAW_INDIRECT_BUFFER, 0);
    gl.glBindVertexArray(0);
    gl.glUseProgram(0);
    return expectNoError(gl, "live-present MDI draw", message);
}

}  // namespace

bool runS22LivePresentMDISentinel(std::string& message) {
    if (![NSThread isMainThread]) {
        message = "live-present MDI sentinel requires the main thread";
        return false;
    }

    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];

        const NSRect rect = NSMakeRect(0, 0, kCanvasWidth, kCanvasHeight);
        NSWindow* window =
            [[NSWindow alloc] initWithContentRect:rect
                                        styleMask:NSWindowStyleMaskBorderless
                                          backing:NSBackingStoreBuffered
                                            defer:NO];
        NSView* view = [[NSView alloc] initWithFrame:rect];
        CAMetalLayer* layer = [CAMetalLayer layer];
        layer.frame = rect;
        layer.bounds = rect;
        layer.drawableSize = CGSizeMake(kCanvasWidth, kCanvasHeight);
        layer.framebufferOnly = NO;
        layer.displaySyncEnabled = NO;
        view.wantsLayer = YES;
        view.layer = layer;
        window.contentView = view;
        [window orderFrontRegardless];
        pumpRunLoopOnce();

        auto context = std::make_unique<GLContext>((__bridge void*)layer);
        Runtime::shared().makeCurrent(context.get());
        Runtime::shared().noteRenderer(context->rendererString());
        auto& gl = Runtime::shared().dispatch();

        const GLuint program = buildProgram(gl, message);
        if (program == 0) {
            Runtime::shared().makeCurrent(nullptr);
            context.reset();
            [window close];
#if !__has_feature(objc_arc)
            [view release];
            [window release];
#endif
            return false;
        }

        std::vector<float> vertices;
        std::vector<IndirectCommand> commands;
        buildWall(vertices, commands);

        GLuint vao = 0;
        GLuint vbo = 0;
        GLuint indirectBuffer = 0;
        gl.glGenVertexArrays(1, &vao);
        gl.glGenBuffers(1, &vbo);
        gl.glGenBuffers(1, &indirectBuffer);

        gl.glBindVertexArray(vao);
        gl.glBindBuffer(GL_ARRAY_BUFFER, vbo);
        gl.glBufferData(GL_ARRAY_BUFFER,
                        static_cast<GLsizeiptr>(vertices.size() * sizeof(float)),
                        vertices.data(),
                        GL_STATIC_DRAW);
        gl.glEnableVertexAttribArray(0);
        gl.glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE,
                                 kStrideBytes,
                                 reinterpret_cast<void*>(0));
        gl.glEnableVertexAttribArray(1);
        gl.glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE,
                                 kStrideBytes,
                                 reinterpret_cast<void*>(2 * sizeof(float)));
        gl.glBindVertexArray(0);
        gl.glBindBuffer(GL_ARRAY_BUFFER, 0);

        gl.glBindBuffer(GL_DRAW_INDIRECT_BUFFER, indirectBuffer);
        gl.glBufferData(GL_DRAW_INDIRECT_BUFFER,
                        static_cast<GLsizeiptr>(commands.size() * sizeof(IndirectCommand)),
                        commands.data(),
                        GL_STATIC_DRAW);
        gl.glBindBuffer(GL_DRAW_INDIRECT_BUFFER, 0);

        bool ok = expectNoError(gl, "live-present MDI setup", message);
        if (ok) {
            ok = renderMDIFrame(gl, program, vao, indirectBuffer, message);
        }
        if (ok) {
            context->swapBuffers();
            pumpRunLoopOnce();
            ok = renderMDIFrame(gl, program, vao, indirectBuffer, message);
        }
        int coveredTiles = 0;
        if (ok) {
            coveredTiles = countCoveredTiles(gl);
            ok = expectNoError(gl, "live-present MDI readback", message);
        }
        if (ok && coveredTiles != kDraws) {
            std::ostringstream stream;
            stream << "live-present MDI covered " << coveredTiles
                   << " tiles, expected " << kDraws;
            message = stream.str();
            ok = false;
        }
        if (ok) {
            context->swapBuffers();
            message = "layer-backed present MDI rendered all 128 viewport tiles";
        }

        gl.glBindBuffer(GL_DRAW_INDIRECT_BUFFER, 0);
        gl.glBindBuffer(GL_ARRAY_BUFFER, 0);
        gl.glBindVertexArray(0);
        gl.glUseProgram(0);
        gl.glDeleteBuffers(1, &indirectBuffer);
        gl.glDeleteBuffers(1, &vbo);
        gl.glDeleteVertexArrays(1, &vao);
        gl.glDeleteProgram(program);
        Runtime::shared().makeCurrent(nullptr);
        context.reset();
        [window close];
#if !__has_feature(objc_arc)
        [view release];
        [window release];
#endif
        return ok;
    }
}

}  // namespace appgl::tests
