#include "GLObjectStore.h"

#include <utility>

// Phase 3f-11: full definition of appgl::interp::SpirvModule is needed
// here so the `std::unique_ptr<SpirvModule>` fields in GLProgramObject
// can be destroyed and moved from this TU without the caller seeing
// the complete type. The ctor/dtor/move ops below live here for the
// same reason — any other TU that instantiates `~GLProgramObject`
// would otherwise try to dereference an incomplete type.
#include "../shader/ShaderInterpreter.h"

namespace appgl {

// GLProgramObject special members. All default-bodies; the pointer
// cache fields destruct cleanly because SpirvModule is complete in
// this TU.
GLProgramObject::GLProgramObject() = default;
GLProgramObject::~GLProgramObject() = default;
GLProgramObject::GLProgramObject(GLProgramObject&&) noexcept = default;
GLProgramObject& GLProgramObject::operator=(GLProgramObject&&) noexcept = default;

// β [metal-tess-TF] — same pattern as GLProgramObject above:
// the `std::unique_ptr<GLProgramObject>` syntheticTessProgram field
// requires GLProgramObject to be complete at the point of destruction.
// Defining the special members here keeps any caller TU free of the
// SpirvModule include + the GLProgramObject destructor body.
GLProgramPipelineObject::GLProgramPipelineObject() = default;
GLProgramPipelineObject::~GLProgramPipelineObject() = default;
GLProgramPipelineObject::GLProgramPipelineObject(GLProgramPipelineObject&&) noexcept = default;
GLProgramPipelineObject& GLProgramPipelineObject::operator=(GLProgramPipelineObject&&) noexcept = default;

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
    const auto count = static_cast<std::size_t>(maxVertexAttribs_);
    vertexArray.attributes.resize(count);
    vertexArray.bindingPoints.resize(count);
    // GL 4.3 spec defaults:
    //   - attribute.bindingIndex = attribute index (equivalent to
    //     `glVertexAttribBinding(N, N)`)
    //   - bindingPoint.stride = 16 (GL 4.6 §10.3.8)
    //   - bindingPoint.offset = 0, .divisor = 0, .buffer = 0
    // CTS `vertex_attrib_binding.basic-state1` asserts default
    // GL_VERTEX_BINDING_STRIDE = 16 for every binding index.
    for (std::size_t i = 0; i < count; ++i) {
        vertexArray.attributes[i].bindingIndex = static_cast<GLuint>(i);
        vertexArray.bindingPoints[i].stride = 16;
    }
}

GLuint GLObjectStore::reserveSharedShaderProgramName() {
    // Scan from 1 upward until we find an ID free in BOTH tables,
    // then mark it reserved in whichever table the caller inserts
    // into via insertAt. Cheap because shader/program churn is
    // low in practice.
    GLuint id = 1;
    while (shaders_.contains(id) || programs_.contains(id)) {
        ++id;
    }
    // Bump both tables' nextId_ past this reservation so the next
    // reserveName() in either table doesn't hand out the same ID.
    shaders_.bumpNextIdBeyond(id);
    programs_.bumpNextIdBeyond(id);
    return id;
}

void GLObjectStore::deferDelete(std::string label) {
    deferredDeletes_.push_back(std::move(label));
}

void GLObjectStore::drainDeferredDeletes() {
    deferredDeletes_.clear();
}

}  // namespace appgl
