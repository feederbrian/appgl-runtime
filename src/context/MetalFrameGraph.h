#pragma once

#include <memory>

#include "../../include/AppGL/glcorearb.h"

#ifdef __OBJC__
@class CAMetalLayer;
@protocol MTLDevice;
@protocol MTLCommandQueue;
@protocol MTLTexture;
#endif

namespace appgl {

class GLObjectStore;
class GLStateTracker;

class MetalFrameGraph {
public:
    MetalFrameGraph(void* layer, void* device, void* commandQueue);
    ~MetalFrameGraph();

    MetalFrameGraph(const MetalFrameGraph&) = delete;
    MetalFrameGraph& operator=(const MetalFrameGraph&) = delete;

    void resizeDrawable(GLsizei width, GLsizei height);
    void enableOffscreenDrawable(GLsizei width, GLsizei height);
    void encodeDefaultFramebufferClear(
        GLbitfield mask,
        GLfloat clearRed,
        GLfloat clearGreen,
        GLfloat clearBlue,
        GLfloat clearAlpha,
        GLdouble clearDepth,
        GLint clearStencil
    );
    void beginRenderPassForCurrentFramebuffer(GLStateTracker& state, GLObjectStore& objects);
    void* currentRenderEncoder() const;
    void endRenderPass();
    void endFrame(GLObjectStore& objects);
    void present();
    bool copyRGBA8Pixels(GLint x, GLint y, GLsizei width, GLsizei height, void* outPixels);
    bool hasValidAttachments() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace appgl
