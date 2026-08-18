#!/usr/bin/env python3

from __future__ import annotations

import json
import re
import shutil
import sys
import xml.etree.ElementTree as ET
from collections import OrderedDict
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VENDOR_DIR = ROOT / "tools" / "gen_from_registry" / "khronos"
XML_PATH = VENDOR_DIR / "gl.xml"
SOURCE_HEADER = VENDOR_DIR / "glcorearb.h"
VENDOR_KHR = VENDOR_DIR / "khrplatform.h"

PUBLIC_INCLUDE_DIR = ROOT / "include" / "AppGL"
GENERATED_DIR = ROOT / "src" / "generated"

PUBLIC_HEADER = PUBLIC_INCLUDE_DIR / "glcorearb.h"
PUBLIC_KHR = PUBLIC_INCLUDE_DIR / "khrplatform.h"
DISPATCH_HEADER = GENERATED_DIR / "gl_dispatch.gen.h"
ENTRYPOINTS_CPP = GENERATED_DIR / "gl_entrypoints.gen.cpp"
PROC_ADDRESS_CPP = GENERATED_DIR / "gl_procaddress.gen.cpp"
ALIASES_CPP = GENERATED_DIR / "gl_aliases.gen.cpp"
FIXED_FUNCTION_CPP = GENERATED_DIR / "gl_fixed_function.gen.cpp"
MANIFEST_JSON = GENERATED_DIR / "gl_manifest.gen.json"
ENUMS_HEADER = GENERATED_DIR / "gl_enums.gen.h"
FUNCTION_IDS_HEADER = GENERATED_DIR / "gl_function_ids.gen.h"

SUPPORTED_FEATURES = [
    f"GL_VERSION_{major}_{minor}"
    for major, minor in (
        (1, 0), (1, 1), (1, 2), (1, 3), (1, 4), (1, 5),
        (2, 0), (2, 1),
        (3, 0), (3, 1), (3, 2), (3, 3),
        (4, 0), (4, 1), (4, 2), (4, 3), (4, 4), (4, 5), (4, 6),
    )
]

# Extension blocks whose compile-time API surface is exported from AppGL's
# generated public header even while runtime advertisement remains separately
# gated by GLCapabilities. Commands that need their own dispatch slots still
# belong in EXTRA_EXTENSION_COMMANDS below; aliases can remain generator-owned
# forwarders while sharing these registry-derived prototypes and tokens.
PUBLIC_EXTENSION_FEATURES = [
    "GL_ARB_geometry_shader4",
]

# Registry omissions: aliases the Khronos gl.xml does not declare with an
# explicit <alias> child element, but which the EXT/ARB extension specs
# document as behaviorally identical to a core target. As of the vendored
# gl.xml snapshot, every other FBO/RB EXT command HAS the alias
# declaration — these two are isolated registry holes, not a missing
# extension family. Without these overrides, hosts that load the legacy
# EXT_framebuffer_object names through appglGetProcAddress (e.g. glad's
# default loader) get NULL function pointers and crash at first bind.
#
# Any entry added here must reference a `target` that resolves into the
# core profile command set (so the forwarder has a real implementation
# to delegate into). Use this list sparingly — it exists to paper over
# Khronos registry bugs, not to invent new aliases.
EXTRA_ALIASES = [
    ("glBindFramebufferEXT", "glBindFramebuffer"),
    ("glBindRenderbufferEXT", "glBindRenderbuffer"),
    ("glCheckNamedFramebufferStatusEXT", "glCheckNamedFramebufferStatus"),
    ("glFramebufferDrawBufferEXT", "glNamedFramebufferDrawBuffer"),
    ("glFramebufferDrawBuffersEXT", "glNamedFramebufferDrawBuffers"),
    ("glFramebufferReadBufferEXT", "glNamedFramebufferReadBuffer"),
    ("glGetFramebufferParameterivEXT", "glGetNamedFramebufferParameteriv"),
    ("glGetNamedFramebufferAttachmentParameterivEXT", "glGetNamedFramebufferAttachmentParameteriv"),
    ("glGetNamedFramebufferParameterivEXT", "glGetNamedFramebufferParameteriv"),
    ("glGetNamedRenderbufferParameterivEXT", "glGetNamedRenderbufferParameteriv"),
    ("glNamedFramebufferParameteriEXT", "glNamedFramebufferParameteri"),
    ("glNamedFramebufferRenderbufferEXT", "glNamedFramebufferRenderbuffer"),
    ("glNamedFramebufferTextureEXT", "glNamedFramebufferTexture"),
    ("glNamedFramebufferTextureLayerEXT", "glNamedFramebufferTextureLayer"),
    ("glNamedRenderbufferStorageEXT", "glNamedRenderbufferStorage"),
    ("glNamedRenderbufferStorageMultisampleEXT", "glNamedRenderbufferStorageMultisample"),
    # EXT_direct_state_access named-buffer family. gl.xml declares no
    # <alias> for these because EXT DSA nominally accepts names that were
    # only reserved by glGenBuffers, while core DSA is specified against
    # glCreateBuffers. In this runtime ObjectTable::reserveName() already
    # try_emplace()s the object (GLObjectStore.h:2127), so a gen-only name
    # is present in the table and the core entry points accept it — which
    # makes the forwarders behaviourally exact here. Signatures are
    # identical parameter-for-parameter.
    ("glMapNamedBufferEXT", "glMapNamedBuffer"),
    ("glMapNamedBufferRangeEXT", "glMapNamedBufferRange"),
    ("glUnmapNamedBufferEXT", "glUnmapNamedBuffer"),
    ("glFlushMappedNamedBufferRangeEXT", "glFlushMappedNamedBufferRange"),
    ("glGetNamedBufferParameterivEXT", "glGetNamedBufferParameteriv"),
    ("glGetNamedBufferPointervEXT", "glGetNamedBufferPointerv"),
    ("glGetNamedBufferSubDataEXT", "glGetNamedBufferSubData"),
    ("glNamedCopyBufferSubDataEXT", "glCopyNamedBufferSubData"),
]

# Extension commands whose names aren't reachable through the core-
# feature walk (because the ARB/KHR extension lacks a core target and
# the registry doesn't expose the extension in our SUPPORTED_FEATURES
# list) but which we implement by hand. The generator emits a forward
# declaration + proc-table entry for each; the real definition lives
# somewhere under src/runtime or src/context and matches the signature
# below.
#
# Each entry is (name, return_type, args_decl). Kept in sync with the
# matching `extern "C"` definition in the hand-written source file.
MANUAL_EXTENSION_COMMANDS = [
    # GL_ARB_parallel_shader_compile / GL_KHR_parallel_shader_compile —
    # hand-written in src/runtime/AppGLGroup8.cpp. Our compile path
    # is synchronous, so the count argument is stored for query
    # round-trips but has no threading effect.
    ("glMaxShaderCompilerThreadsARB", "void", "GLuint count"),
    ("glMaxShaderCompilerThreadsKHR", "void", "GLuint count"),
    # GL_EXT_direct_state_access named-buffer creation. NOT a plain alias:
    # EXT DSA says an unknown or since-deleted buffer name is created on
    # first use ("the GL first creates a new state vector"), while core
    # glNamedBufferData raises INVALID_OPERATION for the same name. The
    # hand-written definition in src/runtime/AppGLGroup8.cpp materialises
    # the name and then forwards to the core entry point.
    ("glNamedBufferDataEXT", "void",
     "GLuint buffer, GLsizeiptr size, const void *data, GLenum usage"),
]

# Extension commands that are intentionally promoted into the generated
# public header, dispatch table, entry-point wrappers, function IDs, and
# proc-address table even though the generator's core-feature walk would not
# discover them. The real implementation lives in hand-written runtime code
# and is installed into GLDispatchTable like any core command.
#
# This is scaffold-only: adding a command here does not advertise the
# corresponding extension at runtime. The extension string remains owned by
# GLCapabilities::initializeExtensions() and kAppGLExtensionList.
EXTRA_EXTENSION_COMMANDS = [
    (
        "glBindBufferOffsetEXT",
        "void",
        "GLenum target, GLuint index, GLuint buffer, GLintptr offset",
        "GL_EXT_transform_feedback",
    ),
    (
        "glBufferPageCommitmentARB",
        "void",
        "GLenum target, GLintptr offset, GLsizeiptr size, GLboolean commit",
        "ARB_sparse_buffer",
    ),
    (
        "glNamedBufferPageCommitmentARB",
        "void",
        "GLuint buffer, GLintptr offset, GLsizeiptr size, GLboolean commit",
        "ARB_sparse_buffer",
    ),
    (
        "glNamedBufferPageCommitmentEXT",
        "void",
        "GLuint buffer, GLintptr offset, GLsizeiptr size, GLboolean commit",
        "ARB_sparse_buffer",
    ),
    (
        "glTexPageCommitmentARB",
        "void",
        "GLenum target, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLsizei width, GLsizei height, GLsizei depth, GLboolean commit",
        "ARB_sparse_texture",
    ),
    (
        "glTexturePageCommitmentEXT",
        "void",
        "GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLsizei width, GLsizei height, GLsizei depth, GLboolean commit",
        "ARB_sparse_texture",
    ),
    (
        "glGetFragmentShadingRatesEXT",
        "void",
        "GLsizei samples, GLsizei maxCount, GLsizei *count, GLenum *shadingRates",
        "GL_EXT_fragment_shading_rate",
    ),
    (
        "glShadingRateEXT",
        "void",
        "GLenum rate",
        "GL_EXT_fragment_shading_rate",
    ),
    (
        "glShadingRateCombinerOpsEXT",
        "void",
        "GLenum combinerOp0, GLenum combinerOp1",
        "GL_EXT_fragment_shading_rate",
    ),
    (
        "glFramebufferShadingRateEXT",
        "void",
        "GLenum target, GLenum attachment, GLuint texture, GLint baseLayer, GLsizei numLayers, GLsizei texelWidth, GLsizei texelHeight",
        "GL_EXT_fragment_shading_rate",
    ),
    (
        "glBlendBarrier",
        "void",
        "void",
        "GL_KHR_blend_equation_advanced",
    ),
    (
        "glBlendBarrierKHR",
        "void",
        "void",
        "GL_KHR_blend_equation_advanced",
    ),
    (
        "glFramebufferTextureMultiviewOVR",
        "void",
        "GLenum target, GLenum attachment, GLuint texture, GLint level, GLint baseViewIndex, GLsizei numViews",
        "GL_OVR_multiview",
    ),
    (
        "glNamedFramebufferTextureMultiviewOVR",
        "void",
        "GLuint framebuffer, GLenum attachment, GLuint texture, GLint level, GLint baseViewIndex, GLsizei numViews",
        "GL_OVR_multiview",
    ),
    (
        "glVertexArrayVertexAttribDivisorEXT",
        "void",
        "GLuint vaobj, GLuint index, GLuint divisor",
        "GL_EXT_direct_state_access",
    ),
    (
        "glGenerateTextureMipmapEXT",
        "void",
        "GLuint texture, GLenum target",
        "GL_EXT_direct_state_access",
    ),
    (
        "glNamedFramebufferTexture1DEXT",
        "void",
        "GLuint framebuffer, GLenum attachment, GLenum textarget, GLuint texture, GLint level",
        "GL_EXT_direct_state_access",
    ),
    (
        "glNamedFramebufferTexture2DEXT",
        "void",
        "GLuint framebuffer, GLenum attachment, GLenum textarget, GLuint texture, GLint level",
        "GL_EXT_direct_state_access",
    ),
    (
        "glNamedFramebufferTexture3DEXT",
        "void",
        "GLuint framebuffer, GLenum attachment, GLenum textarget, GLuint texture, GLint level, GLint zoffset",
        "GL_EXT_direct_state_access",
    ),
    (
        "glNamedFramebufferTextureFaceEXT",
        "void",
        "GLuint framebuffer, GLenum attachment, GLuint texture, GLint level, GLenum face",
        "GL_EXT_direct_state_access",
    ),
    (
        "glNamedRenderbufferStorageMultisampleCoverageEXT",
        "void",
        "GLuint renderbuffer, GLsizei coverageSamples, GLsizei colorSamples, GLenum internalformat, GLsizei width, GLsizei height",
        "GL_EXT_direct_state_access",
    ),
    (
        "glFramebufferTextureLayerARB",
        "void",
        "GLenum target, GLenum attachment, GLuint texture, GLint level, GLint layer",
        "GL_ARB_geometry_shader4",
    ),
    (
        "glFramebufferTextureFaceARB",
        "void",
        "GLenum target, GLenum attachment, GLuint texture, GLint level, GLenum face",
        "GL_ARB_geometry_shader4",
    ),
]

EXTRA_EXTENSION_ENUMS = [
    ("GL_SPARSE_STORAGE_BIT_ARB", "0x0400"),
    ("GL_SPARSE_BUFFER_PAGE_SIZE_ARB", "0x82F8"),
    ("GL_VIRTUAL_PAGE_SIZE_X_ARB", "0x9195"),
    ("GL_VIRTUAL_PAGE_SIZE_Y_ARB", "0x9196"),
    ("GL_VIRTUAL_PAGE_SIZE_Z_ARB", "0x9197"),
    ("GL_MAX_SPARSE_TEXTURE_SIZE_ARB", "0x9198"),
    ("GL_MAX_SPARSE_3D_TEXTURE_SIZE_ARB", "0x9199"),
    ("GL_MAX_SPARSE_ARRAY_TEXTURE_LAYERS_ARB", "0x919A"),
    ("GL_TEXTURE_SPARSE_ARB", "0x91A6"),
    ("GL_VIRTUAL_PAGE_SIZE_INDEX_ARB", "0x91A7"),
    ("GL_NUM_VIRTUAL_PAGE_SIZES_ARB", "0x91A8"),
    ("GL_SPARSE_TEXTURE_FULL_ARRAY_CUBE_MIPMAPS_ARB", "0x91A9"),
    ("GL_NUM_SPARSE_LEVELS_ARB", "0x91AA"),
    ("GL_TEXTURE_REDUCTION_MODE_ARB", "0x9366"),
    ("GL_WEIGHTED_AVERAGE_ARB", "0x9367"),
    ("GL_TEXTURE_CUBE_MAP_ARRAY_ARB", "0x9009"),
    ("GL_TEXTURE_BINDING_CUBE_MAP_ARRAY_ARB", "0x900A"),
    ("GL_PROXY_TEXTURE_CUBE_MAP_ARRAY_ARB", "0x900B"),
    ("GL_SAMPLER_CUBE_MAP_ARRAY_ARB", "0x900C"),
    ("GL_SAMPLER_CUBE_MAP_ARRAY_SHADOW_ARB", "0x900D"),
    ("GL_INT_SAMPLER_CUBE_MAP_ARRAY_ARB", "0x900E"),
    ("GL_UNSIGNED_INT_SAMPLER_CUBE_MAP_ARRAY_ARB", "0x900F"),
    ("GL_MAX_PROGRAM_TEXTURE_GATHER_COMPONENTS_ARB", "0x8F9F"),
    ("GL_TEXTURE_SWIZZLE_R_EXT", "0x8E42"),
    ("GL_TEXTURE_SWIZZLE_G_EXT", "0x8E43"),
    ("GL_TEXTURE_SWIZZLE_B_EXT", "0x8E44"),
    ("GL_TEXTURE_SWIZZLE_A_EXT", "0x8E45"),
    ("GL_TEXTURE_SWIZZLE_RGBA_EXT", "0x8E46"),
    ("GL_SHADING_RATE_1X1_PIXELS_EXT", "0x96A6"),
    ("GL_SHADING_RATE_1X2_PIXELS_EXT", "0x96A7"),
    ("GL_SHADING_RATE_2X1_PIXELS_EXT", "0x96A8"),
    ("GL_SHADING_RATE_2X2_PIXELS_EXT", "0x96A9"),
    ("GL_SHADING_RATE_1X4_PIXELS_EXT", "0x96AA"),
    ("GL_SHADING_RATE_4X1_PIXELS_EXT", "0x96AB"),
    ("GL_SHADING_RATE_4X2_PIXELS_EXT", "0x96AC"),
    ("GL_SHADING_RATE_2X4_PIXELS_EXT", "0x96AD"),
    ("GL_SHADING_RATE_4X4_PIXELS_EXT", "0x96AE"),
    ("GL_SHADING_RATE_EXT", "0x96D0"),
    ("GL_SHADING_RATE_ATTACHMENT_EXT", "0x96D1"),
    ("GL_FRAGMENT_SHADING_RATE_COMBINER_OP_KEEP_EXT", "0x96D2"),
    ("GL_FRAGMENT_SHADING_RATE_COMBINER_OP_REPLACE_EXT", "0x96D3"),
    ("GL_FRAGMENT_SHADING_RATE_COMBINER_OP_MIN_EXT", "0x96D4"),
    ("GL_FRAGMENT_SHADING_RATE_COMBINER_OP_MAX_EXT", "0x96D5"),
    ("GL_FRAGMENT_SHADING_RATE_COMBINER_OP_MUL_EXT", "0x96D6"),
    ("GL_MIN_FRAGMENT_SHADING_RATE_ATTACHMENT_TEXEL_WIDTH_EXT", "0x96D7"),
    ("GL_MAX_FRAGMENT_SHADING_RATE_ATTACHMENT_TEXEL_WIDTH_EXT", "0x96D8"),
    ("GL_MIN_FRAGMENT_SHADING_RATE_ATTACHMENT_TEXEL_HEIGHT_EXT", "0x96D9"),
    ("GL_MAX_FRAGMENT_SHADING_RATE_ATTACHMENT_TEXEL_HEIGHT_EXT", "0x96DA"),
    ("GL_MAX_FRAGMENT_SHADING_RATE_ATTACHMENT_TEXEL_ASPECT_RATIO_EXT", "0x96DB"),
    ("GL_MAX_FRAGMENT_SHADING_RATE_ATTACHMENT_LAYERS_EXT", "0x96DC"),
    ("GL_FRAGMENT_SHADING_RATE_WITH_SHADER_DEPTH_STENCIL_WRITES_SUPPORTED_EXT", "0x96DD"),
    ("GL_FRAGMENT_SHADING_RATE_WITH_SAMPLE_MASK_SUPPORTED_EXT", "0x96DE"),
    ("GL_FRAGMENT_SHADING_RATE_ATTACHMENT_WITH_DEFAULT_FRAMEBUFFER_SUPPORTED_EXT", "0x96DF"),
    ("GL_FRAGMENT_SHADING_RATE_NON_TRIVIAL_COMBINERS_SUPPORTED_EXT", "0x8F6F"),
    ("GL_FRAGMENT_SHADING_RATE_PRIMITIVE_RATE_WITH_MULTI_VIEWPORT_SUPPORTED_EXT", "0x9780"),
    ("GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_NUM_VIEWS_OVR", "0x9630"),
    ("GL_MAX_VIEWS_OVR", "0x9631"),
    ("GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_BASE_VIEW_INDEX_OVR", "0x9632"),
    ("GL_FRAMEBUFFER_INCOMPLETE_VIEW_TARGETS_OVR", "0x9633"),
    ("GL_COMPRESSED_ALPHA", "0x84E9"),
    ("GL_COMPRESSED_LUMINANCE", "0x84EA"),
    ("GL_COMPRESSED_LUMINANCE_ALPHA", "0x84EB"),
    ("GL_COMPRESSED_INTENSITY", "0x84EC"),
    ("GL_COMPRESSED_RGB_S3TC_DXT1_EXT", "0x83F0"),
    ("GL_COMPRESSED_RGBA_S3TC_DXT1_EXT", "0x83F1"),
    ("GL_COMPRESSED_RGBA_S3TC_DXT3_EXT", "0x83F2"),
    ("GL_COMPRESSED_RGBA_S3TC_DXT5_EXT", "0x83F3"),
    ("GL_COMPRESSED_RGBA_ASTC_4x4_KHR", "0x93B0"),
    ("GL_COMPRESSED_RGBA_ASTC_5x4_KHR", "0x93B1"),
    ("GL_COMPRESSED_RGBA_ASTC_5x5_KHR", "0x93B2"),
    ("GL_COMPRESSED_RGBA_ASTC_6x5_KHR", "0x93B3"),
    ("GL_COMPRESSED_RGBA_ASTC_6x6_KHR", "0x93B4"),
    ("GL_COMPRESSED_RGBA_ASTC_8x5_KHR", "0x93B5"),
    ("GL_COMPRESSED_RGBA_ASTC_8x6_KHR", "0x93B6"),
    ("GL_COMPRESSED_RGBA_ASTC_8x8_KHR", "0x93B7"),
    ("GL_COMPRESSED_RGBA_ASTC_10x5_KHR", "0x93B8"),
    ("GL_COMPRESSED_RGBA_ASTC_10x6_KHR", "0x93B9"),
    ("GL_COMPRESSED_RGBA_ASTC_10x8_KHR", "0x93BA"),
    ("GL_COMPRESSED_RGBA_ASTC_10x10_KHR", "0x93BB"),
    ("GL_COMPRESSED_RGBA_ASTC_12x10_KHR", "0x93BC"),
    ("GL_COMPRESSED_RGBA_ASTC_12x12_KHR", "0x93BD"),
    ("GL_COMPRESSED_SRGB8_ALPHA8_ASTC_4x4_KHR", "0x93D0"),
    ("GL_COMPRESSED_SRGB8_ALPHA8_ASTC_5x4_KHR", "0x93D1"),
    ("GL_COMPRESSED_SRGB8_ALPHA8_ASTC_5x5_KHR", "0x93D2"),
    ("GL_COMPRESSED_SRGB8_ALPHA8_ASTC_6x5_KHR", "0x93D3"),
    ("GL_COMPRESSED_SRGB8_ALPHA8_ASTC_6x6_KHR", "0x93D4"),
    ("GL_COMPRESSED_SRGB8_ALPHA8_ASTC_8x5_KHR", "0x93D5"),
    ("GL_COMPRESSED_SRGB8_ALPHA8_ASTC_8x6_KHR", "0x93D6"),
    ("GL_COMPRESSED_SRGB8_ALPHA8_ASTC_8x8_KHR", "0x93D7"),
    ("GL_COMPRESSED_SRGB8_ALPHA8_ASTC_10x5_KHR", "0x93D8"),
    ("GL_COMPRESSED_SRGB8_ALPHA8_ASTC_10x6_KHR", "0x93D9"),
    ("GL_COMPRESSED_SRGB8_ALPHA8_ASTC_10x8_KHR", "0x93DA"),
    ("GL_COMPRESSED_SRGB8_ALPHA8_ASTC_10x10_KHR", "0x93DB"),
    ("GL_COMPRESSED_SRGB8_ALPHA8_ASTC_12x10_KHR", "0x93DC"),
    ("GL_COMPRESSED_SRGB8_ALPHA8_ASTC_12x12_KHR", "0x93DD"),
    ("GL_BLEND_ADVANCED_COHERENT_KHR", "0x9285"),
    ("GL_MULTIPLY_KHR", "0x9294"),
    ("GL_SCREEN_KHR", "0x9295"),
    ("GL_OVERLAY_KHR", "0x9296"),
    ("GL_DARKEN_KHR", "0x9297"),
    ("GL_LIGHTEN_KHR", "0x9298"),
    ("GL_COLORDODGE_KHR", "0x9299"),
    ("GL_COLORBURN_KHR", "0x929A"),
    ("GL_HARDLIGHT_KHR", "0x929B"),
    ("GL_SOFTLIGHT_KHR", "0x929C"),
    ("GL_DIFFERENCE_KHR", "0x929E"),
    ("GL_EXCLUSION_KHR", "0x92A0"),
    ("GL_HSL_HUE_KHR", "0x92AD"),
    ("GL_HSL_SATURATION_KHR", "0x92AE"),
    ("GL_HSL_COLOR_KHR", "0x92AF"),
    ("GL_HSL_LUMINOSITY_KHR", "0x92B0"),
]

# Fixed-function entry points whose silent-stub bodies in
# gl_fixed_function.gen.cpp must be SUPPRESSED so a hand-written file
# elsewhere in the runtime can provide the real `extern "C" APIENTRY`
# definition. Names listed here:
#   - Are still discovered by parse_registry() and stay in the
#     fixed_function command list (so they appear in the proc address
#     table emitted by generate_proc_address_cpp() and in the manifest).
#   - Get a forward declaration in gl_procaddress.gen.cpp like every
#     other fixed-function entry — at link time the declaration resolves
#     to the hand-written symbol instead of a generated stub.
#   - Are skipped from generate_fixed_function_cpp() body emission so
#     the linker doesn't see a duplicate definition.
#
# This is the same pattern as EXTRA_ALIASES — codegen escape hatch for
# entry points that need real behavior but where rewriting the entire
# 1.x compat-profile bag of tricks isn't worth it. The compat-shader
# rewriter (src/shader/CompatShaderRewrite.h) needs the matrix family
# to actually produce real values that flow into the synthesized
# `appgl_*` uniforms at draw time, so the matrix stack entry points
# go here. Everything else stays on the silent-stub path.
#
# Hand-written definitions live in src/runtime/AppGLMatrixOverrides.cpp and
# src/runtime/AppGLImmediateMode.cpp. The matrix-stack entries route into
# the per-context `MatrixStateMirror`; the immediate-mode geometry entries
# (glBegin/glVertex*/glColor*/glTexCoord*/glMultiTexCoord*/glEnd) land in
# a capture state on `GLContext` and drain into `MetalFrameGraph::
# encodeImmediateModeDraw` from `glEnd`. Both families must stay in
# `MANUAL_FIXED_FUNCTION_OVERRIDES` so the codegen does NOT emit a
# no-op `recordFixedFunctionStub` body that would collide at link time
# with the hand-written real definitions.
MANUAL_FIXED_FUNCTION_OVERRIDES = {
    # Matrix stack (routed to MatrixStateMirror).
    "glMatrixMode",
    "glLoadIdentity",
    "glLoadMatrixf",
    "glLoadMatrixd",
    "glLoadTransposeMatrixf",
    "glLoadTransposeMatrixd",
    "glMultMatrixf",
    "glMultMatrixd",
    "glMultTransposeMatrixf",
    "glMultTransposeMatrixd",
    "glPushMatrix",
    "glPopMatrix",
    "glTranslatef",
    "glTranslated",
    "glRotatef",
    "glRotated",
    "glScalef",
    "glScaled",
    "glOrtho",
    "glFrustum",
    # Phase 8X Group 4d follow-up¹⁷ — immediate-mode geometry capture
    # for Chobby / Chili widget chrome. Routes into
    # GLContext::{beginImmediate, immediateVertex, immediateColor,
    # immediateTexCoord, endImmediate} and drains into
    # MetalFrameGraph::encodeImmediateModeDraw on glEnd. glLightModel*
    # is silently accepted as a no-op — BAR Chobby sets
    # GL_LIGHT_MODEL_TWO_SIDE during its compat init step but nothing
    # downstream actually reads it.
    "glBegin",
    "glEnd",
    # Display-list lifecycle and replay are routed through a bounded
    # GLContext command recorder so Piglit GL 1.1 display-list smoke
    # tests exercise real clear/immediate-mode replay instead of the
    # generic silent stubs.
    "glNewList",
    "glEndList",
    "glCallList",
    "glCallLists",
    "glDeleteLists",
    "glGenLists",
    "glIsList",
    "glListBase",
    # glRect* expands to an immediate-mode quad, but in display lists it
    # must replay as an atomic draw command so it can raise
    # INVALID_OPERATION without leaking vertices when called inside a
    # surrounding glBegin/glEnd.
    "glRectd",
    "glRectdv",
    "glRectf",
    "glRectfv",
    "glRecti",
    "glRectiv",
    "glRects",
    "glRectsv",
    "glShadeModel",
    "glPushAttrib",
    "glPopAttrib",
    # Compat alpha-test state is real under AppGLCompatFeature::AlphaTest
    # admission and feeds fragment-discard synthesis.
    "glAlphaFunc",
    "glVertexPointer",
    "glColorPointer",
    "glSecondaryColorPointer",
    "glTexCoordPointer",
    "glEnableClientState",
    "glDisableClientState",
    "glRasterPos2d",
    "glRasterPos2dv",
    "glRasterPos2f",
    "glRasterPos2fv",
    "glRasterPos2i",
    "glRasterPos2iv",
    "glRasterPos2s",
    "glRasterPos2sv",
    "glRasterPos3d",
    "glRasterPos3dv",
    "glRasterPos3f",
    "glRasterPos3fv",
    "glRasterPos3i",
    "glRasterPos3iv",
    "glRasterPos3s",
    "glRasterPos3sv",
    "glRasterPos4d",
    "glRasterPos4dv",
    "glRasterPos4f",
    "glRasterPos4fv",
    "glRasterPos4i",
    "glRasterPos4iv",
    "glRasterPos4s",
    "glRasterPos4sv",
    "glWindowPos2i",
    "glWindowPos2iv",
    "glWindowPos2f",
    "glWindowPos2fv",
    "glWindowPos2d",
    "glWindowPos2dv",
    "glWindowPos2s",
    "glWindowPos2sv",
    "glWindowPos3f",
    "glWindowPos3fv",
    "glWindowPos3d",
    "glWindowPos3dv",
    "glWindowPos3i",
    "glWindowPos3iv",
    "glWindowPos3s",
    "glWindowPos3sv",
    "glBitmap",
    "glCopyPixels",
    "glClearAccum",
    "glAccum",
    "glDrawPixels",
    "glPixelZoom",
    "glPixelMapfv",
    "glPixelMapuiv",
    "glPixelMapusv",
    "glPixelTransferf",
    "glPixelTransferi",
    "glClipPlane",
    "glLineStipple",
    "glColorMaterial",
    "glMaterialf",
    "glMaterialfv",
    "glMateriali",
    "glMaterialiv",
    "glGetMaterialfv",
    "glGetMaterialiv",
    "glFogf",
    "glFogfv",
    "glFogi",
    "glFogiv",
    "glLightf",
    "glLightfv",
    "glLighti",
    "glLightiv",
    "glNormal3b",
    "glNormal3bv",
    "glNormal3d",
    "glNormal3dv",
    "glNormal3f",
    "glNormal3fv",
    "glNormal3i",
    "glNormal3iv",
    "glNormal3s",
    "glNormal3sv",
    "glTexEnvf",
    "glTexEnvfv",
    "glTexEnvi",
    "glTexEnviv",
    "glTexGend",
    "glTexGendv",
    "glTexGenf",
    "glTexGenfv",
    "glTexGeni",
    "glTexGeniv",
    "glSelectBuffer",
    "glRenderMode",
    "glInitNames",
    "glPushName",
    "glPopName",
    "glLoadName",
    "glVertex2d",
    "glVertex2dv",
    "glVertex2f",
    "glVertex2fv",
    "glVertex2i",
    "glVertex2iv",
    "glVertex2s",
    "glVertex2sv",
    "glVertex3d",
    "glVertex3dv",
    "glVertex3f",
    "glVertex3fv",
    "glVertex3i",
    "glVertex3iv",
    "glVertex3s",
    "glVertex3sv",
    "glVertex4d",
    "glVertex4dv",
    "glVertex4f",
    "glVertex4fv",
    "glVertex4i",
    "glVertex4iv",
    "glVertex4s",
    "glVertex4sv",
    "glColor3f",
    "glColor3fv",
    "glColor4f",
    "glColor4fv",
    "glSecondaryColor3f",
    "glSecondaryColor3fv",
    "glColor3ub",
    "glColor3ubv",
    "glColor4ub",
    "glColor4ubv",
    "glTexCoord1f",
    "glTexCoord1fv",
    "glTexCoord2f",
    "glTexCoord2fv",
    "glTexCoord3f",
    "glTexCoord3fv",
    "glTexCoord4f",
    "glTexCoord4fv",
    "glMultiTexCoord1f",
    "glMultiTexCoord1fv",
    "glMultiTexCoord2f",
    "glMultiTexCoord2fv",
    "glMultiTexCoord3f",
    "glMultiTexCoord3fv",
    "glMultiTexCoord4f",
    "glMultiTexCoord4fv",
    "glLightModelf",
    "glLightModelfv",
    "glLightModeli",
    "glLightModeliv",
    # Edge flags. Polygon-mode GL_LINE decomposition in
    # GLContextImmediate.inc.mm needs the per-vertex boundary bit to
    # decide which polygon edges become lines; a silent stub drew every
    # edge, which is what `spec@!opengl 1.0@gl-1.0-edgeflag` measures.
    "glEdgeFlag",
    "glEdgeFlagv",
    "glEdgeFlagPointer",
}

IMPLEMENTED_FUNCTIONS = {
    "glClearColor": {
        "state": "Smoke-tested",
        "firstPassingTestId": "bootstrap.clear-loop",
        "notes": "Animated clear loop drives the Metal-backed default framebuffer.",
    },
    "glClear": {
        "state": "Smoke-tested",
        "firstPassingTestId": "bootstrap.clear-loop",
        "notes": "Bootstrap clear path encodes a Metal render pass and presents it.",
    },
    "glViewport": {
        "state": "Smoke-tested",
        "firstPassingTestId": "bootstrap.clear-loop",
        "notes": "Viewport updates drive the drawable size.",
    },
    "glFlush": {
        "state": "Smoke-tested",
        "firstPassingTestId": "bootstrap.clear-loop",
        "notes": "Bootstrap flush presents the pending default framebuffer work.",
    },
    "glGetString": {
        "state": "Smoke-tested",
        "firstPassingTestId": "bootstrap.clear-loop",
        "notes": "AppGL reports conservative bootstrap identity strings.",
    },
    "glGetError": {
        "state": "Smoke-tested",
        "firstPassingTestId": "bootstrap.clear-loop",
        "notes": "Bootstrap runtime maintains a per-context error FIFO.",
    },
    "glDebugMessageCallback": {
        "state": "Smoke-tested",
        "firstPassingTestId": "bootstrap.clear-loop",
        "notes": "Bootstrap debug callback receives unsupported-entry-point diagnostics.",
    },
}

FEATURE_ENUM_RE = re.compile(r"^GL_VERSION_(\d+)_(\d+)$")
HEADER_TYPE_SPLIT_RE = re.compile(r"^#ifndef GL_VERSION_1_0$")
XML_PROTO_NAME_RE = re.compile(r"<name>([^<]+)</name>")
IDENTIFIER_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*$")


def normalize_c_decl(text: str) -> str:
    text = text.replace("\n", " ")
    text = re.sub(r"\s+", " ", text).strip()
    text = re.sub(r"\s+\*", " *", text)
    text = re.sub(r"\*\s+", "* ", text)
    text = re.sub(r"\s+\(", "(", text)
    text = re.sub(r"\(\s+", "(", text)
    text = re.sub(r"\s+\)", ")", text)
    text = re.sub(r"\s+,", ",", text)
    text = re.sub(r",\s*", ", ", text)
    return text


def flatten_xml(element: ET.Element) -> str:
    if element.tag == "apientry":
        return "APIENTRY"
    parts: list[str] = []
    if element.text:
        parts.append(element.text)
    for child in element:
        parts.append(flatten_xml(child))
        if child.tail:
            parts.append(child.tail)
    return "".join(parts)


def flatten_xml_without_name(element: ET.Element) -> str:
    parts: list[str] = []
    if element.text:
        parts.append(element.text)
    for child in element:
        if child.tag == "name":
            if child.tail:
                parts.append(child.tail)
            continue
        parts.append(flatten_xml(child))
        if child.tail:
            parts.append(child.tail)
    return "".join(parts)


def feature_version_string(feature_name: str) -> str:
    match = FEATURE_ENUM_RE.match(feature_name)
    if match is None:
        raise RuntimeError(f"Unexpected feature name: {feature_name}")
    return f"{match.group(1)}.{match.group(2)}"


def extract_command_signature(command: ET.Element) -> dict[str, object]:
    proto = command.find("proto")
    if proto is None:
        raise RuntimeError("Command missing <proto> block.")

    name_element = proto.find("name")
    if name_element is None or not name_element.text:
        raise RuntimeError("Command missing <proto><name>.")
    name = name_element.text

    return_type = normalize_c_decl(flatten_xml_without_name(proto))

    params: list[dict[str, str]] = []
    for param in command.findall("param"):
        declaration = normalize_c_decl(flatten_xml(param))
        name_node = param.find("name")
        if name_node is None or not name_node.text:
            raise RuntimeError(f"Command {name} has a param without a name.")
        params.append({"decl": declaration, "name": name_node.text})

    args_decl = "void" if not params else ", ".join(param["decl"] for param in params)
    return {
        "name": name,
        "return_type": return_type,
        "args_decl": args_decl,
        "params": params,
        "pfn": f"PFN{name.upper()}PROC",
    }


def make_manual_command_signature(
    name: str,
    return_type: str,
    args_decl: str,
    introduced_version: str,
) -> dict[str, object]:
    params: list[dict[str, str]] = []
    if args_decl != "void":
        for raw_decl in args_decl.split(","):
            declaration = normalize_c_decl(raw_decl)
            match = IDENTIFIER_RE.search(declaration)
            if match is None:
                raise RuntimeError(f"Manual command {name} has an unparsable argument: {raw_decl}")
            params.append({"decl": declaration, "name": match.group(0)})
    return {
        "name": name,
        "return_type": return_type,
        "args_decl": args_decl,
        "params": params,
        "pfn": f"PFN{name.upper()}PROC",
        "introduced_version": introduced_version,
    }


def parse_registry() -> tuple[
    ET.Element,
    list[dict[str, object]],
    list[dict[str, str]],
    list[str],
    list[dict[str, object]],
    list[dict[str, object]],
]:
    if not XML_PATH.exists():
        raise FileNotFoundError(f"Missing registry XML: {XML_PATH}")

    tree = ET.parse(XML_PATH)
    root = tree.getroot()

    commands_by_name: dict[str, ET.Element] = {}
    for command in root.findall("./commands/command"):
        proto_name = command.findtext("./proto/name")
        if proto_name:
            commands_by_name[proto_name] = command

    enums_by_name: dict[str, str] = {}
    for enum in root.findall(".//enum"):
        name = enum.attrib.get("name")
        value = enum.attrib.get("value")
        if name and value and name not in enums_by_name:
            enums_by_name[name] = value

    ordered_commands: "OrderedDict[str, str]" = OrderedDict()
    ordered_enums: "OrderedDict[str, str]" = OrderedDict()

    # Track every command that was ever required by a feature (with any
    # profile), regardless of whether the core profile later removed it.
    # The set difference against `ordered_commands` yields the compat-only
    # fixed-function entry points (matrix stack, immediate mode, display
    # lists, etc.) that we emit as no-op stubs in Landing C 3e.
    all_feature_commands: set[str] = set()

    for feature_name in SUPPORTED_FEATURES:
        feature = root.find(f"./feature[@api='gl'][@name='{feature_name}']")
        if feature is None:
            raise RuntimeError(f"Missing feature block: {feature_name}")

        for child in feature:
            profile = child.attrib.get("profile")
            if child.tag not in {"require", "remove"}:
                continue

            if child.tag == "require":
                # Track any required command regardless of profile so we
                # can later diff against the core set to find the
                # compat-only fixed-function entry points.
                for command_node in child.findall("command"):
                    all_feature_commands.add(command_node.attrib["name"])

            if profile not in (None, "core"):
                continue

            if child.tag == "require":
                for enum_node in child.findall("enum"):
                    enum_name = enum_node.attrib["name"]
                    if enum_name not in enums_by_name:
                        raise RuntimeError(f"Enum {enum_name} required by {feature_name} missing from registry.")
                    ordered_enums.pop(enum_name, None)
                    ordered_enums[enum_name] = enums_by_name[enum_name]
                for command_node in child.findall("command"):
                    command_name = command_node.attrib["name"]
                    if command_name not in commands_by_name:
                        raise RuntimeError(f"Command {command_name} required by {feature_name} missing from registry.")
                    ordered_commands.pop(command_name, None)
                    ordered_commands[command_name] = feature_name
            else:
                for enum_node in child.findall("enum"):
                    ordered_enums.pop(enum_node.attrib["name"], None)
                for command_node in child.findall("command"):
                    ordered_commands.pop(command_node.attrib["name"], None)

    commands = []
    for name, feature_name in ordered_commands.items():
        signature = extract_command_signature(commands_by_name[name])
        signature["introduced_version"] = feature_version_string(feature_name)
        commands.append(signature)

    command_names = {command["name"] for command in commands}
    for name, return_type, args_decl, introduced_version in EXTRA_EXTENSION_COMMANDS:
        if name in command_names:
            continue
        commands.append(make_manual_command_signature(name, return_type, args_decl, introduced_version))
        command_names.add(name)

    core_names = set(ordered_commands.keys())
    fixed_function_names = all_feature_commands - core_names

    # --- Landing C 3e: aliases forwarding into the core set ---------------
    # Walk every command in the registry; if it declares <alias name="X"/>
    # where X is in the core set and the alias source itself is NOT in core,
    # it's a forwardable alias (glBindBufferARB -> glBindBuffer and so on).
    # We emit the stub with the CORE target's signature under the alias
    # name — C linkage means only the symbol name matters at link time,
    # and external loaders resolve these via appglGetProcAddress and cast
    # the returned function pointer to whatever type they need.
    #
    # Aliases whose target lives in the FIXED-FUNCTION set (e.g.
    # glClientActiveTextureARB → glClientActiveTexture, the entire
    # glMultiTexCoord*ARB family → glMultiTexCoord*) are also emitted as
    # forwarders. The fixed-function target is itself a no-op stub from
    # generate_fixed_function_cpp(), so the alias forwarder ends up as a
    # no-op-via-indirection — but it resolves through appglGetProcAddress
    # to a real function pointer instead of NULL, which is the only
    # contract glad's loader cares about. Without this, hosts that probe
    # the ARB names crash on first call.
    aliases: list[dict[str, object]] = []
    fixed_function_signatures: dict[str, dict[str, object]] = {}

    def lookup_target_signature(target_name: str) -> dict[str, object] | None:
        target_signature = next(
            (c for c in commands if c["name"] == target_name), None
        )
        if target_signature is not None:
            return target_signature
        if target_name in fixed_function_names:
            cached = fixed_function_signatures.get(target_name)
            if cached is None:
                target_command = commands_by_name.get(target_name)
                if target_command is None:
                    return None
                cached = extract_command_signature(target_command)
                fixed_function_signatures[target_name] = cached
            return cached
        return None

    for alias_name, alias_cmd in commands_by_name.items():
        alias_node = alias_cmd.find("alias")
        if alias_node is None:
            continue
        target_name = alias_node.attrib.get("name")
        if target_name is None:
            continue
        if target_name not in core_names and target_name not in fixed_function_names:
            continue
        if alias_name in command_names:
            # The alias spelling already has its own generated dispatch slot
            # (core or explicitly promoted extension command), so emitting a
            # forwarding body would create a duplicate symbol.
            continue
        if alias_name in fixed_function_names:
            # The alias name is itself in the compat-only feature set, so
            # generate_fixed_function_cpp() already emits a no-op stub for
            # it. Avoid colliding by skipping the forwarder.
            continue
        target_signature = lookup_target_signature(target_name)
        if target_signature is None:
            raise RuntimeError(
                f"Alias {alias_name} targets command {target_name} "
                f"but no signature is available in either the core or "
                f"fixed-function tables."
            )
        aliases.append(
            {
                "name": alias_name,
                "target": target_name,
                "target_is_core": target_name in core_names,
                "return_type": target_signature["return_type"],
                "args_decl": target_signature["args_decl"],
                "params": target_signature["params"],
            }
        )

    # Inject EXTRA_ALIASES — registry omissions documented at the top of
    # this file. Each entry must point at a core target; the lookup will
    # error out if the override references a non-existent or fixed-function
    # target (use the regular registry path for fixed-function aliases).
    existing_alias_names = {entry["name"] for entry in aliases}
    for alias_name, target_name in EXTRA_ALIASES:
        if alias_name in core_names:
            continue
        if alias_name in existing_alias_names:
            # Registry has caught up — the override is now redundant. Skip
            # silently rather than failing so this list can stay in place
            # across registry updates.
            continue
        if target_name not in core_names:
            raise RuntimeError(
                f"EXTRA_ALIASES entry {alias_name} -> {target_name} "
                f"references a non-core target. Overrides must point at "
                f"the canonical core symbol."
            )
        target_signature = next(
            (c for c in commands if c["name"] == target_name), None
        )
        if target_signature is None:
            raise RuntimeError(
                f"EXTRA_ALIASES entry {alias_name} -> {target_name} "
                f"references unknown core command."
            )
        aliases.append(
            {
                "name": alias_name,
                "target": target_name,
                "target_is_core": True,
                "return_type": target_signature["return_type"],
                "args_decl": target_signature["args_decl"],
                "params": target_signature["params"],
            }
        )
        existing_alias_names.add(alias_name)

    aliases.sort(key=lambda entry: entry["name"])

    # --- Landing C 3e: fixed-function compat-only entry points ------------
    # The compat profile kept a long tail of GL 1.x-era entry points
    # (matrix stack, immediate mode, display lists, fog, lighting, pixel
    # transfer) that core removed. Engines like Recoil/BAR sometimes
    # probe these names during extension detection even though they
    # don't actually drive rendering through them. We emit no-op stubs
    # so appglGetProcAddress returns a valid (if inert) function pointer
    # instead of null, letting extension checks complete cleanly.
    fixed_function: list[dict[str, object]] = []
    for name in sorted(fixed_function_names):
        command = commands_by_name.get(name)
        if command is None:
            raise RuntimeError(
                f"Fixed-function command {name} missing from registry command table."
            )
        signature = extract_command_signature(command)
        fixed_function.append(signature)

    for enum_name, enum_value in EXTRA_EXTENSION_ENUMS:
        ordered_enums.pop(enum_name, None)
        ordered_enums[enum_name] = enum_value

    enums = [{"name": name, "value": value} for name, value in ordered_enums.items()]
    return (
        root,
        commands,
        enums,
        list(ordered_commands.values()),
        aliases,
        fixed_function,
    )


def extract_public_extension_surface(
    root: ET.Element,
) -> tuple[list[dict[str, object]], list[dict[str, str]]]:
    commands_by_name: dict[str, ET.Element] = {}
    for command in root.findall("./commands/command"):
        proto_name = command.findtext("./proto/name")
        if proto_name:
            commands_by_name[proto_name] = command

    enums_by_name: dict[str, str] = {}
    for enum in root.findall(".//enum"):
        name = enum.attrib.get("name")
        value = enum.attrib.get("value")
        if name and value and name not in enums_by_name:
            enums_by_name[name] = value

    extension_commands: "OrderedDict[str, dict[str, object]]" = OrderedDict()
    extension_enums: "OrderedDict[str, str]" = OrderedDict()
    for extension_name in PUBLIC_EXTENSION_FEATURES:
        extension = root.find(f"./extensions/extension[@name='{extension_name}']")
        if extension is None:
            raise RuntimeError(f"Missing public extension block: {extension_name}")
        supported_apis = extension.attrib.get("supported", "").split("|")
        if "gl" not in supported_apis and "glcore" not in supported_apis:
            raise RuntimeError(f"Public extension {extension_name} does not support desktop GL.")
        for requirement in extension.findall("require"):
            api = requirement.attrib.get("api")
            if api not in (None, "gl"):
                continue
            for enum_node in requirement.findall("enum"):
                enum_name = enum_node.attrib["name"]
                enum_value = enums_by_name.get(enum_name)
                if enum_value is None:
                    raise RuntimeError(
                        f"Enum {enum_name} required by {extension_name} missing from registry."
                    )
                extension_enums[enum_name] = enum_value
            for command_node in requirement.findall("command"):
                command_name = command_node.attrib["name"]
                command = commands_by_name.get(command_name)
                if command is None:
                    raise RuntimeError(
                        f"Command {command_name} required by {extension_name} missing from registry."
                    )
                signature = extract_command_signature(command)
                signature["introduced_version"] = extension_name
                extension_commands[command_name] = signature

    return list(extension_commands.values()), [
        {"name": name, "value": value}
        for name, value in extension_enums.items()
    ]


def extract_header_preamble(source_lines: list[str]) -> list[str]:
    preamble: list[str] = []
    for line in source_lines:
        if HEADER_TYPE_SPLIT_RE.match(line):
            break
        normalized = line.rstrip("\n").replace("#include <KHR/khrplatform.h>", '#include "khrplatform.h"')
        preamble.append(normalized)
    if not preamble:
        raise RuntimeError("Unable to extract glcorearb preamble from vendored header.")
    return preamble


def extract_type_block(root: ET.Element) -> list[str]:
    type_lines: list[str] = []
    for type_node in root.findall("./types/type"):
        if type_node.attrib.get("api") not in (None, "gl"):
            continue
        if type_node.attrib.get("name") == "khrplatform":
            type_lines.append('#include "khrplatform.h"')
            continue
        raw = flatten_xml(type_node).strip()
        if not raw:
            continue
        if "#" in raw:
            type_lines.extend(line.rstrip() for line in raw.splitlines() if line.strip())
        else:
            type_lines.append(normalize_c_decl(raw))
    if not type_lines:
        raise RuntimeError("Unable to extract GL type block from registry XML.")
    return type_lines


def generate_public_header(
    preamble: list[str],
    type_block: list[str],
    commands: list[dict[str, object]],
    enums: list[dict[str, str]],
    public_extensions: list[str],
) -> str:
    lines: list[str] = []
    lines.append("/*")
    lines.append(" * Generated by appgl-runtime/tools/gen_from_registry/generate_from_registry.py")
    lines.append(" * Inputs:")
    lines.append(" *   - appgl-runtime/tools/gen_from_registry/khronos/gl.xml")
    lines.append(" *   - appgl-runtime/tools/gen_from_registry/khronos/glcorearb.h")
    lines.append(" *   - appgl-runtime/tools/gen_from_registry/khronos/khrplatform.h")
    lines.append(" */")
    lines.append("")
    lines.extend(preamble)
    lines.append("")
    lines.extend(type_block)
    lines.append("")
    for feature_name in SUPPORTED_FEATURES:
        lines.append(f"#ifndef {feature_name}")
        lines.append(f"#define {feature_name} 1")
        lines.append("#endif")
    for extension_name in public_extensions:
        lines.append(f"#ifndef {extension_name}")
        lines.append(f"#define {extension_name} 1")
        lines.append("#endif")
    lines.append("")
    for enum in enums:
        lines.append(f"#ifndef {enum['name']}")
        lines.append(f"#define {enum['name']} {enum['value']}")
        lines.append("#endif")
    lines.append("")
    for command in commands:
        lines.append(
            f"typedef {command['return_type']} (APIENTRYP {command['pfn']})({command['args_decl']});"
        )
    lines.append("")
    for command in commands:
        lines.append(
            f"GLAPI {command['return_type']} APIENTRY {command['name']}({command['args_decl']});"
        )
    lines.append("")
    lines.append("#ifdef __cplusplus")
    lines.append("}")
    lines.append("#endif")
    lines.append("")
    lines.append("#endif")
    lines.append("")
    return "\n".join(lines)


def generate_enums_header(enums: list[dict[str, str]]) -> str:
    lines = [
        "#pragma once",
        "",
        "// Generated by appgl-runtime/tools/gen_from_registry/generate_from_registry.py",
        "",
    ]
    for enum in enums:
        lines.append(f"#ifndef {enum['name']}")
        lines.append(f"#define {enum['name']} {enum['value']}")
        lines.append("#endif")
    lines.append("")
    return "\n".join(lines)


def classify_subsystem(name: str) -> str:
    def contains_any(*needles: str) -> bool:
        return any(needle in name for needle in needles)

    dsa_prefixes = (
        "glCreateBuffers",
        "glNamedBuffer",
        "glClearNamedBuffer",
        "glMapNamedBuffer",
        "glUnmapNamedBuffer",
        "glFlushMappedNamedBufferRange",
        "glCreateFramebuffers",
        "glNamedFramebuffer",
        "glBlitNamedFramebuffer",
        "glCheckNamedFramebuffer",
        "glClearNamedFramebuffer",
        "glInvalidateNamedFramebuffer",
        "glCreateRenderbuffers",
        "glNamedRenderbuffer",
        "glCreateTextures",
        "glTexture",
        "glCompressedTexture",
        "glCopyTexture",
        "glGenerateTextureMipmap",
        "glBindTextureUnit",
        "glGetTexture",
        "glCreateVertexArrays",
        "glVertexArray",
        "glCreateSamplers",
        "glCreateQueries",
        "glCreateTransformFeedbacks",
    )
    if name.startswith(dsa_prefixes):
        return "direct state access"

    if contains_any("ProgramPipeline") or name == "glBindProgramPipeline":
        return "shaders and programs"

    shader_prefixes = (
        "glAttachShader",
        "glBindAttribLocation",
        "glBindFragDataLocation",
        "glCompileShader",
        "glCreateProgram",
        "glCreateShader",
        "glDeleteProgram",
        "glDeleteShader",
        "glDetachShader",
        "glGetActiveAttrib",
        "glGetActiveSubroutine",
        "glGetActiveSubroutineName",
        "glGetActiveUniform",
        "glGetActiveUniformBlock",
        "glGetActiveUniformName",
        "glGetAttachedShaders",
        "glGetAttribLocation",
        "glGetFragData",
        "glGetProgram",
        "glGetShader",
        "glGetSubroutine",
        "glGetUniform",
        "glGetUniformBlock",
        "glGetUniformIndices",
        "glGetUniformLocation",
        "glGetProgramBinary",
        "glGetProgramInterface",
        "glGetProgramPipeline",
        "glGetProgramResource",
        "glGetProgramStage",
        "glGetShaderPrecisionFormat",
        "glGetShaderSource",
        "glGetSubroutineIndex",
        "glGetSubroutineUniformLocation",
        "glIsProgram",
        "glIsShader",
        "glLinkProgram",
        "glProgramBinary",
        "glProgramParameteri",
        "glProgramUniform",
        "glShaderBinary",
        "glShaderSource",
        "glSpecializeShader",
        "glUniform",
        "glUniformBlockBinding",
        "glUseProgram",
        "glUseProgramStages",
        "glValidateProgram",
        "glCreateProgramPipelines",
        "glBindProgramPipeline",
        "glActiveShaderProgram",
        "glDeleteProgramPipelines",
        "glGenProgramPipelines",
        "glIsProgramPipeline",
    )
    if name.startswith(shader_prefixes) or contains_any(
        "Shader",
        "Program",
        "Uniform",
        "Subroutine",
        "FragData",
        "AtomicCounter",
        "AttribLocation",
    ):
        return "shaders and programs"

    framebuffer_prefixes = (
        "glBindFramebuffer",
        "glBindRenderbuffer",
        "glBlitFramebuffer",
        "glCheckFramebufferStatus",
        "glClearBuffer",
        "glDeleteFramebuffers",
        "glDeleteRenderbuffers",
        "glFramebuffer",
        "glGenFramebuffers",
        "glGenRenderbuffers",
        "glGenerateMipmap",
        "glGetFramebuffer",
        "glGetRenderbuffer",
        "glInvalidateFramebuffer",
        "glInvalidateSubFramebuffer",
        "glIsFramebuffer",
        "glIsRenderbuffer",
        "glReadBuffer",
        "glReadPixels",
        "glReadnPixels",
        "glRenderbuffer",
        "glDrawBuffers",
    )
    if name.startswith(framebuffer_prefixes) or contains_any("Framebuffer", "Renderbuffer"):
        return "framebuffers and renderbuffers"

    transform_feedback_prefixes = (
        "glBeginTransformFeedback",
        "glBindTransformFeedback",
        "glDeleteTransformFeedbacks",
        "glDrawTransformFeedback",
        "glEndTransformFeedback",
        "glGenTransformFeedbacks",
        "glGetTransformFeedback",
        "glGetTransformFeedbacki",
        "glGetTransformFeedbackiv",
        "glGetTransformFeedbackVarying",
        "glIsTransformFeedback",
        "glPauseTransformFeedback",
        "glResumeTransformFeedback",
        "glTransformFeedback",
    )
    if name.startswith(transform_feedback_prefixes):
        return "transform feedback"

    query_prefixes = (
        "glBeginConditionalRender",
        "glBeginQuery",
        "glDeleteQueries",
        "glDeleteSync",
        "glEndConditionalRender",
        "glEndQuery",
        "glFenceSync",
        "glGenQueries",
        "glGetQuery",
        "glGetQueryObject",
        "glGetSync",
        "glIsQuery",
        "glIsSync",
        "glQueryCounter",
        "glClientWaitSync",
        "glWaitSync",
    )
    if name.startswith(query_prefixes):
        return "queries and sync"

    compute_prefixes = (
        "glDispatchCompute",
        "glMemoryBarrier",
    )
    if name.startswith(compute_prefixes):
        return "compute"

    debug_prefixes = (
        "glDebugMessage",
        "glGetDebugMessageLog",
        "glGetGraphicsResetStatus",
        "glGetObjectLabel",
        "glGetObjectPtrLabel",
        "glObjectLabel",
        "glObjectPtrLabel",
        "glPopDebugGroup",
        "glPushDebugGroup",
    )
    if name.startswith(debug_prefixes):
        return "debug and introspection"

    texture_prefixes = (
        "glActiveTexture",
        "glBindSampler",
        "glBindTexture",
        "glCompressedTex",
        "glCopyTex",
        "glDeleteSamplers",
        "glDeleteTextures",
        "glGenSamplers",
        "glGenTextures",
        "glBindImageTexture",
        "glGetCompressedTexImage",
        "glGetMultisamplefv",
        "glGetSampler",
        "glGetTex",
        "glIsSampler",
        "glIsTexture",
        "glSampler",
        "glTex",
    )
    if name.startswith(texture_prefixes) or contains_any("Texture", "Sampler", "Image"):
        return "textures and samplers"

    buffer_prefixes = (
        "glBindBuffer",
        "glBindBuffers",
        "glBufferData",
        "glBufferStorage",
        "glBufferSubData",
        "glClearBufferData",
        "glClearBufferSubData",
        "glCopyBufferSubData",
        "glDeleteBuffers",
        "glFlushMappedBufferRange",
        "glGenBuffers",
        "glGetBuffer",
        "glGetNamedBuffer",
        "glGetnUniform",
        "glInvalidateBuffer",
        "glIsBuffer",
        "glMapBuffer",
        "glMapBufferRange",
        "glUnmapBuffer",
    )
    if name.startswith(buffer_prefixes) or (
        contains_any("Buffer") and not contains_any("Framebuffer", "Renderbuffer", "AtomicCounter")
    ):
        return "buffers and memory"

    draw_prefixes = (
        "glBindVertexArray",
        "glDeleteVertexArrays",
        "glDisableVertexAttrib",
        "glDraw",
        "glEnableVertexAttrib",
        "glGenVertexArrays",
        "glGetVertexAttrib",
        "glIsVertexArray",
        "glMultiDraw",
        "glPatchParameter",
        "glPrimitiveRestartIndex",
        "glVertexAttrib",
        "glVertexBindingDivisor",
    )
    if name.startswith(draw_prefixes) or contains_any("VertexArray", "VertexAttrib"):
        return "vertex input and drawing"

    state_prefixes = (
        "glBlend",
        "glClampColor",
        "glClear",
        "glClipControl",
        "glColorMask",
        "glCullFace",
        "glDepth",
        "glDisable",
        "glEnable",
        "glFinish",
        "glFlush",
        "glFrontFace",
        "glGetBoolean",
        "glGetDouble",
        "glGetError",
        "glGetFloat",
        "glGetFragmentShadingRate",
        "glGetInteger",
        "glGetInternalform",
        "glGetPointer",
        "glGetString",
        "glHint",
        "glIsEnabled",
        "glLineWidth",
        "glLogicOp",
        "glMinSampleShading",
        "glPixelStore",
        "glPointParameter",
        "glPointSize",
        "glPolygonMode",
        "glPolygonOffset",
        "glPolygonOffsetClamp",
        "glProvokingVertex",
        "glReleaseShaderCompiler",
        "glSampleCoverage",
        "glSampleMaski",
        "glScissor",
        "glShadingRate",
        "glStencil",
        "glViewport",
    )
    if name.startswith(state_prefixes):
        return "context and state"

    raise RuntimeError(f"Unresolved subsystem for function: {name}")


def generate_function_ids_header(commands: list[dict[str, object]]) -> str:
    lines = [
        "#pragma once",
        "",
        "#include <cstddef>",
        "",
        "namespace appgl {",
        "",
        "enum class FunctionId : std::size_t {",
    ]
    for command in commands:
        lines.append(f"    {command['name']},")
    lines.extend(
        [
            "    Count,",
            "};",
            "",
            "struct GLFunctionMetadata {",
            "    FunctionId id;",
            "    const char* name;",
            "    const char* subsystem;",
            "    const char* introducedVersion;",
            "};",
            "",
            "inline constexpr GLFunctionMetadata kGLFunctionMetadata[] = {",
        ]
    )
    for command in commands:
        subsystem = classify_subsystem(command["name"])
        lines.append(
            f'    {{FunctionId::{command["name"]}, "{command["name"]}", "{subsystem}", "{command["introduced_version"]}"}},'
        )
    lines.extend(
        [
            "};",
            "",
            "inline constexpr std::size_t kGLFunctionCount = static_cast<std::size_t>(FunctionId::Count);",
            "",
            "}  // namespace appgl",
            "",
        ]
    )
    return "\n".join(lines)


def generate_dispatch_header(commands: list[dict[str, object]]) -> str:
    lines = [
        "#pragma once",
        "",
        '#include "../../include/AppGL/glcorearb.h"',
        '#include "gl_function_ids.gen.h"',
        "",
        "namespace appgl {",
        "",
        "struct GLDispatchTable {",
    ]
    for command in commands:
        lines.append(f"    {command['pfn']} {command['name']} = nullptr;")
    lines.extend(
        [
            "};",
            "",
            "}  // namespace appgl",
            "",
        ]
    )
    return "\n".join(lines)


def generate_entrypoints_cpp(commands: list[dict[str, object]]) -> str:
    lines = [
        "// Generated by appgl-runtime/tools/gen_from_registry/generate_from_registry.py",
        "",
        '#include "gl_dispatch.gen.h"',
        '#include "../runtime/AppGLRuntime.h"',
        "",
    ]
    for command in commands:
        call_args = ", ".join(param["name"] for param in command["params"])
        lines.append(
            f'extern "C" {command["return_type"]} APIENTRY {command["name"]}({command["args_decl"]}) {{'
        )
        lines.append(
            f'    appgl::Runtime::shared().recordFunctionInvocation(appgl::FunctionId::{command["name"]}, "{command["name"]}");'
        )
        lines.append(
            f'    if (auto fn = appgl::Runtime::shared().dispatch().{command["name"]}) {{'
        )
        if command["return_type"] == "void":
            lines.append(f"        fn({call_args});" if call_args else "        fn();")
            lines.append("        return;")
            lines.append("    }")
            lines.append(
                f'    appgl::unimplementedReturn<void>(appgl::FunctionId::{command["name"]}, "{command["name"]}");'
            )
        else:
            lines.append(
                f"        return fn({call_args});" if call_args else "        return fn();"
            )
            lines.append("    }")
            lines.append(
                f'    return appgl::unimplementedReturn<{command["return_type"]}>(appgl::FunctionId::{command["name"]}, "{command["name"]}");'
            )
        lines.append("}")
        lines.append("")
    return "\n".join(lines)


def generate_proc_address_cpp(
    commands: list[dict[str, object]],
    aliases: list[dict[str, object]],
    fixed_function: list[dict[str, object]],
) -> str:
    # appglGetProcAddress is the canonical loader entry point used by
    # external GL loaders (glad / GLEW / in-engine loaders in Recoil/BAR)
    # to populate their dispatch tables against AppGL's generated extern
    # "C" entry points. The table is sorted so the runtime resolver can
    # binary-search without needing an unordered_map or a sort at startup.
    #
    # Landing C 3e extends the table with EXT/ARB alias forwarders and
    # fixed-function no-op stubs so engines that query legacy names
    # (glBindBufferARB, glMatrixMode, ...) get a non-null function
    # pointer and not a load failure.
    all_names = set(command["name"] for command in commands)
    for entry in aliases:
        all_names.add(entry["name"])
    for entry in fixed_function:
        all_names.add(entry["name"])
    for name, _ret, _args in MANUAL_EXTENSION_COMMANDS:
        all_names.add(name)
    sorted_names = sorted(all_names)

    lines = [
        "// Generated by appgl-runtime/tools/gen_from_registry/generate_from_registry.py",
        "",
        "#include <cstddef>",
        "#include <cstring>",
        "",
        '#include "../../include/AppGL/AppGL.h"',
        '#include "../../include/AppGL/glcorearb.h"',
        "",
        "// Forward declarations for alias + fixed-function stubs emitted in",
        "// gl_aliases.gen.cpp / gl_fixed_function.gen.cpp. Declaring them",
        "// here (rather than including those files' generated headers)",
        "// keeps the codegen graph simple and avoids a second include layer.",
        'extern "C" {',
    ]
    for entry in aliases:
        lines.append(
            f'{entry["return_type"]} APIENTRY {entry["name"]}({entry["args_decl"]});'
        )
    for entry in fixed_function:
        lines.append(
            f'{entry["return_type"]} APIENTRY {entry["name"]}({entry["args_decl"]});'
        )
    for name, ret, args in MANUAL_EXTENSION_COMMANDS:
        lines.append(f'{ret} APIENTRY {name}({args});')
    lines.extend(
        [
            "}  // extern \"C\"",
            "",
            "namespace {",
            "",
            "struct ProcEntry {",
            "    const char* name;",
            "    AppGLProc proc;",
            "};",
            "",
            "// Sorted alphabetically so appglGetProcAddress can binary-search",
            "// without sorting at startup. The table is const rather than",
            "// constexpr because reinterpret_cast between function pointer",
            "// types is not a constant expression — but function addresses are",
            "// link-time constants, so the const array still ends up in rodata.",
            "const ProcEntry kProcTable[] = {",
        ]
    )
    for name in sorted_names:
        lines.append(
            f'    {{"{name}", reinterpret_cast<AppGLProc>(&::{name})}},'
        )
    lines.extend(
        [
            "};",
            "",
            "constexpr std::size_t kProcTableSize = sizeof(kProcTable) / sizeof(kProcTable[0]);  // sizeof-based size is still a constant expression.",
            "",
            "}  // namespace",
            "",
            'extern "C" AppGLProc appglGetProcAddress(const char* name) {',
            "    if (name == nullptr) {",
            "        return nullptr;",
            "    }",
            "    std::size_t lo = 0;",
            "    std::size_t hi = kProcTableSize;",
            "    while (lo < hi) {",
            "        const std::size_t mid = lo + (hi - lo) / 2;",
            "        const int cmp = std::strcmp(name, kProcTable[mid].name);",
            "        if (cmp == 0) {",
            "            return kProcTable[mid].proc;",
            "        }",
            "        if (cmp < 0) {",
            "            hi = mid;",
            "        } else {",
            "            lo = mid + 1;",
            "        }",
            "    }",
            "    return nullptr;",
            "}",
            "",
        ]
    )
    return "\n".join(lines)


def generate_aliases_cpp(aliases: list[dict[str, object]]) -> str:
    # Emits extern "C" forwarders from each EXT/ARB alias name into its
    # canonical target. Most aliases delegate into a core entry point
    # declared in glcorearb.h; the rest delegate into a fixed-function
    # compat-profile stub emitted by generate_fixed_function_cpp() — for
    # those, we forward-declare the target inside the same extern "C"
    # block so the forwarder body can call it without pulling in a
    # second generated header.
    #
    # Signatures use the target's parameter types, not the alias's.
    # 27 aliases have type-mismatched legacy parameters
    # (GLhandleARB, GLsizeiptrARB, GLcharARB, ...) — because extern "C"
    # linkage matches only on symbol name and the underlying ABI types
    # are identical (khronos_ssize_t / GLuint / char), engines that
    # resolve via appglGetProcAddress and cast the returned pointer see
    # no ABI mismatch at the machine-code level.
    lines = [
        "// Generated by appgl-runtime/tools/gen_from_registry/generate_from_registry.py",
        "//",
        "// EXT/ARB alias forwarders — each extern \"C\" entry point below",
        "// delegates into its canonical target (core entry point or",
        "// fixed-function compat stub). External loaders can resolve",
        "// these legacy names via appglGetProcAddress and get a",
        "// functional (not null) function pointer.",
        "",
        '#include "../../include/AppGL/glcorearb.h"',
        "",
    ]

    # Forward declarations for fixed-function targets. These live in
    # gl_fixed_function.gen.cpp (linked into the same library), so the
    # forwarders only need a name + signature visible at compile time.
    fixed_function_targets: dict[str, dict[str, object]] = {}
    for entry in aliases:
        if entry.get("target_is_core"):
            continue
        target = str(entry["target"])
        if target in fixed_function_targets:
            continue
        fixed_function_targets[target] = entry

    if fixed_function_targets:
        lines.append("// Forward declarations for fixed-function targets defined in")
        lines.append("// gl_fixed_function.gen.cpp. The alias forwarder body needs the")
        lines.append("// target's prototype visible at compile time; the actual symbol")
        lines.append("// is resolved at link time within libAppGL.")
        lines.append('extern "C" {')
        for target_name in sorted(fixed_function_targets.keys()):
            entry = fixed_function_targets[target_name]
            lines.append(
                f'{entry["return_type"]} APIENTRY {target_name}({entry["args_decl"]});'
            )
        lines.append('}  // extern "C"')
        lines.append("")

    for entry in aliases:
        call_args = ", ".join(param["name"] for param in entry["params"])
        lines.append(
            f'extern "C" {entry["return_type"]} APIENTRY {entry["name"]}({entry["args_decl"]}) {{'
        )
        if entry["return_type"] == "void":
            lines.append(
                f"    ::{entry['target']}({call_args});" if call_args else f"    ::{entry['target']}();"
            )
        else:
            lines.append(
                f"    return ::{entry['target']}({call_args});" if call_args else f"    return ::{entry['target']}();"
            )
        lines.append("}")
        lines.append("")
    return "\n".join(lines)


def generate_fixed_function_cpp(fixed_function: list[dict[str, object]]) -> str:
    # Fixed-function compat-profile entry points (matrix stack, immediate
    # mode, display lists, pixel transfer, lighting, fog, etc.). Core
    # profile removed all of these but some engines still probe the
    # names during extension detection. Each stub records a trace into
    # the unimplemented coverage table so diagnostic tooling can surface
    # which legacy entry points a client is touching, then returns a
    # sensible default for the handful of non-void entries.
    #
    # Names listed in MANUAL_FIXED_FUNCTION_OVERRIDES are SKIPPED from
    # body emission here — a hand-written translation unit elsewhere in
    # the runtime provides the real `extern "C" APIENTRY` definition for
    # each one. The proc address table forward declarations
    # (generate_proc_address_cpp) still cover them, so engines that
    # resolve the name through appglGetProcAddress get a non-null
    # function pointer that lands in the hand-written code.
    suppressed = set(MANUAL_FIXED_FUNCTION_OVERRIDES)

    lines = [
        "// Generated by appgl-runtime/tools/gen_from_registry/generate_from_registry.py",
        "//",
        "// Fixed-function compat-only entry points emitted as no-op stubs so",
        "// extension probing from legacy engines succeeds. Every stub records",
        "// an unimplemented trace (so Runtime::coverageStore flags that the",
        "// client is touching a legacy path) and then no-ops. The remaining",
        "// non-void entries return conservative defaults: glGenLists → 0,",
        "// glIsList → GL_FALSE, glAreTexturesResident → GL_FALSE.",
        "//",
        "// A small set of fixed-function entries listed in",
        "// MANUAL_FIXED_FUNCTION_OVERRIDES (see generate_from_registry.py)",
        "// is intentionally absent from this file. Those entries are defined",
        "// by hand in a runtime translation unit so they can route into the",
        "// real per-context state — the matrix stack mirror, in particular,",
        "// feeds the synthesized fixed-function shader uniforms produced by",
        "// the compat-shader rewriter.",
        "",
        '#include "../../include/AppGL/glcorearb.h"',
        '#include "../runtime/AppGLRuntime.h"',
        "",
    ]

    nonvoid_defaults = {
        "glAreTexturesResident": "GL_FALSE",
        "glGenLists": "0u",
        "glIsList": "GL_FALSE",
        "glRenderMode": "0",
    }

    suppressed_seen = set()
    for entry in fixed_function:
        name = entry["name"]
        if name in suppressed:
            suppressed_seen.add(name)
            continue
        # Suppress unused-parameter warnings by casting each parameter
        # to void inside the stub. The cast is free at runtime and keeps
        # -Wunused-parameter quiet across 387 void stubs.
        ret = entry["return_type"]
        lines.append(
            f'extern "C" {ret} APIENTRY {name}({entry["args_decl"]}) {{'
        )
        for param in entry["params"]:
            lines.append(f"    (void){param['name']};")
        lines.append(
            f'    appgl::Runtime::shared().recordFixedFunctionStub("{name}");'
        )
        if ret == "void":
            lines.append("    return;")
        else:
            default = nonvoid_defaults.get(name)
            if default is None:
                raise RuntimeError(
                    f"Fixed-function entry {name} has non-void return {ret} "
                    f"but no default value configured in the codegen."
                )
            lines.append(f"    return {default};")
        lines.append("}")
        lines.append("")

    # Sanity check: every override must correspond to a real fixed-function
    # entry. A typo in MANUAL_FIXED_FUNCTION_OVERRIDES would otherwise
    # silently leak the hand-written symbol unbacked by a forward decl.
    missing = suppressed - suppressed_seen
    if missing:
        raise RuntimeError(
            "MANUAL_FIXED_FUNCTION_OVERRIDES references unknown fixed-function "
            f"entries: {sorted(missing)}"
        )

    return "\n".join(lines)


def generate_manifest(commands: list[dict[str, object]]) -> str:
    functions = []
    for command in commands:
        state = IMPLEMENTED_FUNCTIONS.get(command["name"], {})
        functions.append(
            {
                "name": command["name"],
                "subsystem": classify_subsystem(command["name"]),
                "introducedVersion": command["introduced_version"],
                "state": state.get("state", "Unimplemented"),
                "firstPassingTestId": state.get("firstPassingTestId", ""),
                "firstPassingBenchmarkId": "",
                "notes": state.get("notes", ""),
            }
        )

    payload = {
        "source": "Khronos OpenGL Registry gl.xml",
        "profile": "core",
        "api": "gl",
        "versionRange": ["1.0", "4.6"],
        "functions": functions,
    }
    return json.dumps(payload, indent=2) + "\n"


def main() -> None:
    if not SOURCE_HEADER.exists():
        raise FileNotFoundError(f"Missing vendored glcorearb.h: {SOURCE_HEADER}")
    if not VENDOR_KHR.exists():
        raise FileNotFoundError(f"Missing vendored khrplatform.h: {VENDOR_KHR}")

    root, commands, enums, _, aliases, fixed_function = parse_registry()
    extension_commands, extension_enums = extract_public_extension_surface(root)

    generated_enum_names = {entry["name"] for entry in enums}
    enums.extend(
        entry for entry in extension_enums
        if entry["name"] not in generated_enum_names
    )

    public_commands = list(commands)
    public_command_names = {entry["name"] for entry in public_commands}
    public_commands.extend(
        entry for entry in extension_commands
        if entry["name"] not in public_command_names
    )

    PUBLIC_INCLUDE_DIR.mkdir(parents=True, exist_ok=True)
    GENERATED_DIR.mkdir(parents=True, exist_ok=True)

    source_lines = SOURCE_HEADER.read_text().splitlines()
    preamble = extract_header_preamble(source_lines)
    type_block = extract_type_block(root)
    PUBLIC_HEADER.write_text(
        generate_public_header(
            preamble,
            type_block,
            public_commands,
            enums,
            PUBLIC_EXTENSION_FEATURES,
        )
    )
    shutil.copyfile(VENDOR_KHR, PUBLIC_KHR)
    ENUMS_HEADER.write_text(generate_enums_header(enums))
    FUNCTION_IDS_HEADER.write_text(generate_function_ids_header(commands))
    DISPATCH_HEADER.write_text(generate_dispatch_header(commands))
    ENTRYPOINTS_CPP.write_text(generate_entrypoints_cpp(commands))
    ALIASES_CPP.write_text(generate_aliases_cpp(aliases))
    FIXED_FUNCTION_CPP.write_text(generate_fixed_function_cpp(fixed_function))
    PROC_ADDRESS_CPP.write_text(generate_proc_address_cpp(commands, aliases, fixed_function))
    MANIFEST_JSON.write_text(generate_manifest(commands))

    print(
        f"Generated {len(commands)} entry points, "
        f"{len(aliases)} EXT/ARB alias forwarders, "
        f"{len(fixed_function)} fixed-function stubs."
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # pragma: no cover - build-time script
        print(f"error: {error}", file=sys.stderr)
        raise
