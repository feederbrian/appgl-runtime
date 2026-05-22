#include "ExtensionRegistry.h"

#include "ExtensionContext.h"

#include <algorithm>
#include <array>
#include <mutex>
#include <vector>

#import <Metal/Metal.h>

namespace appgl::extensions {

namespace {

constexpr std::array<const char*, 61> kBaseExtensions = {
    "GL_KHR_debug",
    "GL_ARB_debug_output",
    "GL_ARB_multitexture",
    "GL_ARB_texture_env_combine",
    "GL_ARB_texture_compression",
    "GL_ARB_texture_float",
    "GL_EXT_texture_integer",
    "GL_EXT_texture_shared_exponent",
    "GL_ARB_texture_non_power_of_two",
    "GL_ARB_texture_query_lod",
    "GL_ARB_texture_query_levels",
    "GL_ARB_texture_barrier",
    "GL_ARB_shader_texture_image_samples",
    "GL_ARB_shader_viewport_layer_array",
    "GL_EXT_texture_shadow_lod",
    "GL_ARB_framebuffer_object",
    "GL_EXT_framebuffer_object",
    "GL_EXT_framebuffer_multisample",
    "GL_EXT_texture_filter_anisotropic",
    "GL_ARB_vertex_shader",
    "GL_ARB_fragment_shader",
    "GL_ARB_geometry_shader4",
    "GL_ARB_uniform_buffer_object",
    "GL_ARB_map_buffer_range",
    "GL_ARB_vertex_buffer_object",
    "GL_ARB_copy_buffer",
    "GL_ARB_draw_elements_base_vertex",
    "GL_EXT_pixel_buffer_object",
    "GL_ARB_shader_storage_buffer_object",
    "GL_ARB_explicit_attrib_location",
    "GL_ARB_explicit_uniform_location",
    "GL_ARB_buffer_storage",
    "GL_ARB_multi_draw_indirect",
    "GL_ARB_shader_draw_parameters",
    "GL_ARB_clip_control",
    "GL_ARB_seamless_cube_map",
    "GL_ARB_conservative_depth",
    "GL_ARB_timer_query",
    "GL_ARB_multisample",
    "GL_ARB_vertex_array_object",
    "GL_ARB_instanced_arrays",
    "GL_ARB_draw_instanced",
    "GL_ARB_base_instance",
    "GL_ARB_sampler_objects",
    "GL_ARB_texture_storage",
    "GL_ARB_sparse_texture",
    "GL_ARB_sparse_texture2",
    "GL_ARB_sparse_texture_clamp",
    "GL_EXT_direct_state_access",
    "GL_ARB_texture_swizzle",
    "GL_ARB_separate_shader_objects",
    "GL_ARB_program_interface_query",
    "GL_ARB_shading_language_420pack",
    "GL_ARB_shading_language_packing",
    "GL_EXT_fragment_shading_rate",
    "GL_ARB_texture_view",
    "GL_ARB_gpu_shader5",
    "GL_ARB_parallel_shader_compile",
    "GL_KHR_parallel_shader_compile",
    "GL_KHR_blend_equation_advanced",
    "GL_KHR_blend_equation_advanced_coherent",
};

const char* s3tcExtensionString() {
    return "GL_EXT_texture_compression_s3tc";
}

bool isS3TCAvailable(ExtensionContext& ctx) {
    id<MTLDevice> device = (__bridge id<MTLDevice>)ctx.metalDevice();
    if (device == nil) {
        return false;
    }
    bool supportsBC = [device supportsFamily:MTLGPUFamilyMac2];
    if ([device respondsToSelector:@selector(supportsBCTextureCompression)]) {
        supportsBC = supportsBC || [device supportsBCTextureCompression];
    }
    return supportsBC;
}

const char* astcLdrExtensionString() {
    return "GL_KHR_texture_compression_astc_ldr";
}

bool isASTCLDRAvailable(ExtensionContext& ctx) {
    id<MTLDevice> device = (__bridge id<MTLDevice>)ctx.metalDevice();
    return device != nil && [device supportsFamily:MTLGPUFamilyApple1];
}

struct CompressionExtensionRegistrar {
    CompressionExtensionRegistrar() {
        ExtensionRegistry::registerModule({
            "texture_compression_s3tc",
            s3tcExtensionString,
            isS3TCAvailable,
            nullptr,
            nullptr,
            {},
            {},
        });
        ExtensionRegistry::registerModule({
            "texture_compression_astc_ldr",
            astcLdrExtensionString,
            isASTCLDRAvailable,
            nullptr,
            nullptr,
            {},
            {},
        });
    }
};

const CompressionExtensionRegistrar kCompressionExtensionRegistrar;

struct RegistryState {
    bool initialized = false;
    std::vector<ExtensionModuleDescriptor> modules;
    std::vector<const char*> activeExtensions;
    std::string extensionBlob;
    SparseTextureHooks sparseTextureHooks;
    FragmentShadingRateHooks fragmentShadingRateHooks;
};

std::mutex& registryMutex() {
    static std::mutex mutex;
    return mutex;
}

RegistryState& registryState() {
    static RegistryState state;
    return state;
}

void rebuildExtensionBlob(RegistryState& state) {
    state.extensionBlob.clear();
    for (std::size_t i = 0; i < state.activeExtensions.size(); ++i) {
        if (i > 0) {
            state.extensionBlob.push_back(' ');
        }
        state.extensionBlob.append(state.activeExtensions[i]);
    }
}

void seedBaseExtensions(RegistryState& state) {
    state.activeExtensions.assign(kBaseExtensions.begin(), kBaseExtensions.end());
    state.sparseTextureHooks = {};
    state.fragmentShadingRateHooks = {};
}

bool hasExtension(const RegistryState& state, std::string_view extensionName) {
    return std::any_of(state.activeExtensions.begin(),
                       state.activeExtensions.end(),
                       [&](const char* extension) {
                           return extensionName == extension;
                       });
}

void appendExtensionIfMissing(RegistryState& state, const char* extension) {
    if (extension == nullptr || extension[0] == '\0' || hasExtension(state, extension)) {
        return;
    }
    state.activeExtensions.push_back(extension);
}

void ensureInitializedLocked(RegistryState& state) {
    if (!state.initialized) {
        seedBaseExtensions(state);
        rebuildExtensionBlob(state);
        state.initialized = true;
    }
}

void mergeSparseHooks(SparseTextureHooks& destination, const SparseTextureHooks& source) {
    if (source.handleTextureParameter != nullptr) destination.handleTextureParameter = source.handleTextureParameter;
    if (source.handleTextureParameterQuery != nullptr) destination.handleTextureParameterQuery = source.handleTextureParameterQuery;
    if (source.handleTextureStorage != nullptr) destination.handleTextureStorage = source.handleTextureStorage;
    if (source.handleTextureUpload != nullptr) destination.handleTextureUpload = source.handleTextureUpload;
    if (source.handleTextureReadback != nullptr) destination.handleTextureReadback = source.handleTextureReadback;
    if (source.handleInternalFormatQuery != nullptr) destination.handleInternalFormatQuery = source.handleInternalFormatQuery;
}

void mergeFragmentShadingRateHooks(FragmentShadingRateHooks& destination,
                                   const FragmentShadingRateHooks& source) {
    if (source.currentDrawRate != nullptr) destination.currentDrawRate = source.currentDrawRate;
    if (source.getFragmentShadingRates != nullptr) destination.getFragmentShadingRates = source.getFragmentShadingRates;
    if (source.shadingRate != nullptr) destination.shadingRate = source.shadingRate;
    if (source.shadingRateCombinerOps != nullptr) destination.shadingRateCombinerOps = source.shadingRateCombinerOps;
    if (source.framebufferShadingRate != nullptr) destination.framebufferShadingRate = source.framebufferShadingRate;
    if (source.queryBoolean != nullptr) destination.queryBoolean = source.queryBoolean;
    if (source.queryInteger != nullptr) destination.queryInteger = source.queryInteger;
    if (source.queryInteger64 != nullptr) destination.queryInteger64 = source.queryInteger64;
    if (source.queryFloat != nullptr) destination.queryFloat = source.queryFloat;
    if (source.queryDouble != nullptr) destination.queryDouble = source.queryDouble;
    if (source.attachRenderPass != nullptr) destination.attachRenderPass = source.attachRenderPass;
}

}  // namespace

void ExtensionRegistry::registerModule(const ExtensionModuleDescriptor& descriptor) {
    std::lock_guard<std::mutex> lock(registryMutex());
    registryState().modules.push_back(descriptor);
}

void ExtensionRegistry::initializeAll(ExtensionContext& ctx) {
    std::vector<ExtensionModuleDescriptor> modules;
    {
        std::lock_guard<std::mutex> lock(registryMutex());
        modules = registryState().modules;
    }

    std::vector<ExtensionModuleDescriptor> activeModules;
    std::vector<const char*> activeModuleExtensions;
    for (const ExtensionModuleDescriptor& module : modules) {
        const bool available = module.isAvailable == nullptr || module.isAvailable(ctx);
        if (!available) {
            continue;
        }
        if (module.initialize != nullptr) {
            module.initialize(ctx);
        }
        activeModules.push_back(module);
        activeModuleExtensions.push_back(module.extensionString != nullptr ? module.extensionString() : nullptr);
    }

    std::lock_guard<std::mutex> lock(registryMutex());
    RegistryState& state = registryState();
    seedBaseExtensions(state);
    for (std::size_t i = 0; i < activeModules.size(); ++i) {
        appendExtensionIfMissing(state, activeModuleExtensions[i]);
        mergeSparseHooks(state.sparseTextureHooks, activeModules[i].sparseTextureHooks);
        mergeFragmentShadingRateHooks(state.fragmentShadingRateHooks,
                                      activeModules[i].fragmentShadingRateHooks);
    }
    rebuildExtensionBlob(state);
    state.initialized = true;
}

void ExtensionRegistry::shutdownAll() {
    std::vector<ExtensionModuleDescriptor> modules;
    {
        std::lock_guard<std::mutex> lock(registryMutex());
        modules = registryState().modules;
    }
    for (const ExtensionModuleDescriptor& module : modules) {
        if (module.shutdown != nullptr) {
            module.shutdown();
        }
    }
    std::lock_guard<std::mutex> lock(registryMutex());
    RegistryState& state = registryState();
    state.initialized = false;
    seedBaseExtensions(state);
    rebuildExtensionBlob(state);
}

std::size_t ExtensionRegistry::extensionCount() {
    std::lock_guard<std::mutex> lock(registryMutex());
    RegistryState& state = registryState();
    ensureInitializedLocked(state);
    return state.activeExtensions.size();
}

const char* ExtensionRegistry::extensionAt(std::size_t index) {
    std::lock_guard<std::mutex> lock(registryMutex());
    RegistryState& state = registryState();
    ensureInitializedLocked(state);
    if (index >= state.activeExtensions.size()) {
        return nullptr;
    }
    return state.activeExtensions[index];
}

const std::string& ExtensionRegistry::extensionString() {
    std::lock_guard<std::mutex> lock(registryMutex());
    RegistryState& state = registryState();
    ensureInitializedLocked(state);
    return state.extensionBlob;
}

bool ExtensionRegistry::isExtensionActive(std::string_view extensionName) {
    std::lock_guard<std::mutex> lock(registryMutex());
    RegistryState& state = registryState();
    ensureInitializedLocked(state);
    return hasExtension(state, extensionName);
}

const SparseTextureHooks& ExtensionRegistry::sparseTextureHooks() {
    std::lock_guard<std::mutex> lock(registryMutex());
    RegistryState& state = registryState();
    ensureInitializedLocked(state);
    return state.sparseTextureHooks;
}

const FragmentShadingRateHooks& ExtensionRegistry::fragmentShadingRateHooks() {
    std::lock_guard<std::mutex> lock(registryMutex());
    RegistryState& state = registryState();
    ensureInitializedLocked(state);
    return state.fragmentShadingRateHooks;
}

}  // namespace appgl::extensions
