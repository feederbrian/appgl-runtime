#include "GLObjectStore.h"

#include <utility>

namespace appgl {

GLObjectStore::GLObjectStore(GLsizei maxVertexAttribs)
    : maxVertexAttribs_(maxVertexAttribs) {
}

ObjectTable<GLBufferObject>& GLObjectStore::buffers() {
    return buffers_;
}

ObjectTable<GLTextureObject>& GLObjectStore::textures() {
    return textures_;
}

ObjectTable<GLSamplerObject>& GLObjectStore::samplers() {
    return samplers_;
}

ObjectTable<GLRenderbufferObject>& GLObjectStore::renderbuffers() {
    return renderbuffers_;
}

ObjectTable<GLFramebufferObject>& GLObjectStore::framebuffers() {
    return framebuffers_;
}

ObjectTable<GLVertexArrayObject>& GLObjectStore::vertexArrays() {
    return vertexArrays_;
}

ObjectTable<GLShaderObject>& GLObjectStore::shaders() {
    return shaders_;
}

ObjectTable<GLProgramObject>& GLObjectStore::programs() {
    return programs_;
}

ObjectTable<GLQueryObject>& GLObjectStore::queries() {
    return queries_;
}

ObjectTable<GLSyncObject>& GLObjectStore::syncs() {
    return syncs_;
}

ObjectTable<GLTransformFeedbackObject>& GLObjectStore::transformFeedbacks() {
    return transformFeedbacks_;
}

ObjectTable<GLProgramPipelineObject>& GLObjectStore::programPipelines() {
    return programPipelines_;
}

GLsizei GLObjectStore::maxVertexAttribs() const {
    return maxVertexAttribs_;
}

void GLObjectStore::initializeVertexArray(GLVertexArrayObject& vertexArray) const {
    vertexArray.attributes.resize(static_cast<std::size_t>(maxVertexAttribs_));
}

void GLObjectStore::deferDelete(std::string label) {
    deferredDeletes_.push_back(std::move(label));
}

void GLObjectStore::drainDeferredDeletes() {
    deferredDeletes_.clear();
}

}  // namespace appgl
