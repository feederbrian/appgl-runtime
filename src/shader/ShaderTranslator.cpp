#include "ShaderTranslator.h"

#ifdef APPGL_HAS_SHADER_COMPILER

#include <glslang/Public/ShaderLang.h>
#include <glslang/Public/ResourceLimits.h>
#include <SPIRV/GlslangToSpv.h>
#include <spirv_msl.hpp>

#include "../extensions/ExtensionRegistry.h"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <memory>
#include <mutex>
#include <set>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace appgl {
namespace {

bool findMatchingParen(const std::string& text,
                       std::size_t open,
                       std::size_t& close);

std::once_flag g_glslangInitFlag;
constexpr std::uint32_t kDefaultUniformSyntheticBinding = 1024u;
constexpr std::uint32_t kFragCoordParamsBufferSlot = 15u;
constexpr std::uint32_t kFragmentShadingRateParamsBufferSlot = 30u;
constexpr std::uint32_t kMultisampleStorageImageSampleCountsBufferSlot = 30u;
constexpr std::uint32_t kClipControlYSignPreferredBufferSlot = 29u;
constexpr std::uint32_t kTextureReductionModesPreferredBufferSlot = 14u;
constexpr std::uint32_t kTextureLodBiasesPreferredBufferSlot = 13u;
constexpr std::uint32_t kImplicitLodBiasCorrectionPreferredBufferSlot = 12u;
constexpr std::uint32_t kTextureBorderClampModesPreferredBufferSlot = 11u;
constexpr std::uint32_t kTextureBorderClampColorsPreferredBufferSlot = 10u;
constexpr std::uint32_t kTextureBufferSizesGraphicsBufferSlot = 22u;
constexpr std::uint32_t kTextureBufferSizesComputeBufferSlot = 29u;
constexpr std::uint32_t kMaxMetalBufferSlot = 30u;
constexpr std::uint32_t kMaxDirectMetalSamplerSlots = 16u;
constexpr std::uint32_t kMultisampleSampledSidecarTextureSlotOffset = 64u;
constexpr std::uint32_t kMultisampleStorageSparseResidencyTextureSlotOffset = 96u;

GLenum storageImageTargetForType(const spirv_cross::SPIRType& imageType) {
    if (imageType.basetype != spirv_cross::SPIRType::Image ||
        imageType.image.sampled != 2) {
        return 0;
    }
    switch (imageType.image.dim) {
        case spv::Dim2D:
            if (imageType.image.ms) {
                return imageType.image.arrayed
                    ? GL_TEXTURE_2D_MULTISAMPLE_ARRAY
                    : GL_TEXTURE_2D_MULTISAMPLE;
            }
            return imageType.image.arrayed
                ? GL_TEXTURE_2D_ARRAY
                : GL_TEXTURE_2D;
        case spv::Dim3D:
            return imageType.image.ms ? 0 : GL_TEXTURE_3D;
        case spv::DimCube:
            if (imageType.image.ms) {
                return 0;
            }
            return imageType.image.arrayed
                ? GL_TEXTURE_CUBE_MAP_ARRAY
                : GL_TEXTURE_CUBE_MAP;
        case spv::DimRect:
            return imageType.image.ms ? 0 : GL_TEXTURE_RECTANGLE;
        case spv::DimBuffer:
            return imageType.image.ms ? 0 : GL_TEXTURE_BUFFER;
        default:
            return 0;
    }
}

GLenum sampledImageUniformTypeForType(spirv_cross::Compiler& compiler,
                                      const spirv_cross::SPIRType& sampledType) {
    if (sampledType.basetype != spirv_cross::SPIRType::SampledImage &&
        sampledType.basetype != spirv_cross::SPIRType::Image) {
        return GL_SAMPLER_2D;
    }
    const spirv_cross::SPIRType& imageType = sampledType;
    spirv_cross::SPIRType::BaseType scalarBase = spirv_cross::SPIRType::Float;
    try {
        scalarBase = compiler.get_type(imageType.image.type).basetype;
    } catch (...) {
    }
    const bool isShadowSampler =
        imageType.image.depth == 1 &&
        scalarBase == spirv_cross::SPIRType::Float;
    auto choose = [&](GLenum floatType, GLenum intType, GLenum uintType) {
        if (scalarBase == spirv_cross::SPIRType::Int) return intType;
        if (scalarBase == spirv_cross::SPIRType::UInt) return uintType;
        return floatType;
    };
    switch (imageType.image.dim) {
        case spv::Dim1D:
            if (isShadowSampler) {
                return imageType.image.arrayed
                    ? GL_SAMPLER_1D_ARRAY_SHADOW
                    : GL_SAMPLER_1D_SHADOW;
            }
            return imageType.image.arrayed
                ? choose(GL_SAMPLER_1D_ARRAY, GL_INT_SAMPLER_1D_ARRAY, GL_UNSIGNED_INT_SAMPLER_1D_ARRAY)
                : choose(GL_SAMPLER_1D, GL_INT_SAMPLER_1D, GL_UNSIGNED_INT_SAMPLER_1D);
        case spv::Dim2D:
            if (imageType.image.ms) {
                return imageType.image.arrayed
                    ? choose(GL_SAMPLER_2D_MULTISAMPLE_ARRAY, GL_INT_SAMPLER_2D_MULTISAMPLE_ARRAY, GL_UNSIGNED_INT_SAMPLER_2D_MULTISAMPLE_ARRAY)
                    : choose(GL_SAMPLER_2D_MULTISAMPLE, GL_INT_SAMPLER_2D_MULTISAMPLE, GL_UNSIGNED_INT_SAMPLER_2D_MULTISAMPLE);
            }
            if (isShadowSampler) {
                return imageType.image.arrayed
                    ? GL_SAMPLER_2D_ARRAY_SHADOW
                    : GL_SAMPLER_2D_SHADOW;
            }
            return imageType.image.arrayed
                ? choose(GL_SAMPLER_2D_ARRAY, GL_INT_SAMPLER_2D_ARRAY, GL_UNSIGNED_INT_SAMPLER_2D_ARRAY)
                : choose(GL_SAMPLER_2D, GL_INT_SAMPLER_2D, GL_UNSIGNED_INT_SAMPLER_2D);
        case spv::Dim3D:
            return choose(GL_SAMPLER_3D, GL_INT_SAMPLER_3D, GL_UNSIGNED_INT_SAMPLER_3D);
        case spv::DimCube:
            if (isShadowSampler) {
                return imageType.image.arrayed
                    ? GL_SAMPLER_CUBE_MAP_ARRAY_SHADOW
                    : GL_SAMPLER_CUBE_SHADOW;
            }
            return imageType.image.arrayed
                ? choose(GL_SAMPLER_CUBE_MAP_ARRAY, GL_INT_SAMPLER_CUBE_MAP_ARRAY, GL_UNSIGNED_INT_SAMPLER_CUBE_MAP_ARRAY)
                : choose(GL_SAMPLER_CUBE, GL_INT_SAMPLER_CUBE, GL_UNSIGNED_INT_SAMPLER_CUBE);
        case spv::DimRect:
            if (isShadowSampler) {
                return GL_SAMPLER_2D_RECT_SHADOW;
            }
            return choose(GL_SAMPLER_2D_RECT, GL_INT_SAMPLER_2D_RECT, GL_UNSIGNED_INT_SAMPLER_2D_RECT);
        case spv::DimBuffer:
            return choose(GL_SAMPLER_BUFFER, GL_INT_SAMPLER_BUFFER, GL_UNSIGNED_INT_SAMPLER_BUFFER);
        default:
            return GL_SAMPLER_2D;
    }
}

GLenum storageImageUniformTypeForType(spirv_cross::Compiler& compiler,
                                      const spirv_cross::SPIRType& imageType) {
    if (imageType.basetype != spirv_cross::SPIRType::Image) {
        return GL_IMAGE_2D;
    }
    spirv_cross::SPIRType::BaseType scalarBase = spirv_cross::SPIRType::Float;
    try {
        scalarBase = compiler.get_type(imageType.image.type).basetype;
    } catch (...) {
    }
    auto choose = [&](GLenum floatType, GLenum intType, GLenum uintType) {
        if (scalarBase == spirv_cross::SPIRType::Int) return intType;
        if (scalarBase == spirv_cross::SPIRType::UInt) return uintType;
        return floatType;
    };
    switch (imageType.image.dim) {
        case spv::Dim1D:
            return imageType.image.arrayed
                ? choose(GL_IMAGE_1D_ARRAY, GL_INT_IMAGE_1D_ARRAY, GL_UNSIGNED_INT_IMAGE_1D_ARRAY)
                : choose(GL_IMAGE_1D, GL_INT_IMAGE_1D, GL_UNSIGNED_INT_IMAGE_1D);
        case spv::Dim2D:
            if (imageType.image.ms) {
                return imageType.image.arrayed
                    ? choose(GL_IMAGE_2D_MULTISAMPLE_ARRAY, GL_INT_IMAGE_2D_MULTISAMPLE_ARRAY, GL_UNSIGNED_INT_IMAGE_2D_MULTISAMPLE_ARRAY)
                    : choose(GL_IMAGE_2D_MULTISAMPLE, GL_INT_IMAGE_2D_MULTISAMPLE, GL_UNSIGNED_INT_IMAGE_2D_MULTISAMPLE);
            }
            return imageType.image.arrayed
                ? choose(GL_IMAGE_2D_ARRAY, GL_INT_IMAGE_2D_ARRAY, GL_UNSIGNED_INT_IMAGE_2D_ARRAY)
                : choose(GL_IMAGE_2D, GL_INT_IMAGE_2D, GL_UNSIGNED_INT_IMAGE_2D);
        case spv::Dim3D:
            return choose(GL_IMAGE_3D, GL_INT_IMAGE_3D, GL_UNSIGNED_INT_IMAGE_3D);
        case spv::DimCube:
            return imageType.image.arrayed
                ? choose(GL_IMAGE_CUBE_MAP_ARRAY, GL_INT_IMAGE_CUBE_MAP_ARRAY, GL_UNSIGNED_INT_IMAGE_CUBE_MAP_ARRAY)
                : choose(GL_IMAGE_CUBE, GL_INT_IMAGE_CUBE, GL_UNSIGNED_INT_IMAGE_CUBE);
        case spv::DimRect:
            return choose(GL_IMAGE_2D_RECT, GL_INT_IMAGE_2D_RECT, GL_UNSIGNED_INT_IMAGE_2D_RECT);
        case spv::DimBuffer:
            return choose(GL_IMAGE_BUFFER, GL_INT_IMAGE_BUFFER, GL_UNSIGNED_INT_IMAGE_BUFFER);
        default:
            return GL_IMAGE_2D;
    }
}

template <typename CompilerT>
void applySpirvModuleOptions(CompilerT& compiler,
                             const TranslatorOptions& options) {
    if (!options.spirvEntryPointName.empty()) {
        const auto entries = compiler.get_entry_points_and_stages();
        for (const auto& entry : entries) {
            if (entry.name == options.spirvEntryPointName) {
                compiler.rename_entry_point(entry.name, "main0", entry.execution_model);
                compiler.set_entry_point("main0", entry.execution_model);
                break;
            }
        }
    }
    if (options.specializationConstants.empty()) {
        return;
    }
    for (const auto& sc : compiler.get_specialization_constants()) {
        const auto valueIt = options.specializationConstants.find(sc.constant_id);
        if (valueIt == options.specializationConstants.end()) {
            continue;
        }
        auto& constant = compiler.get_constant(sc.id);
        const auto& type = compiler.get_type(constant.constant_type);
        switch (type.basetype) {
            case spirv_cross::SPIRType::Boolean:
                constant.m.c[0].r[0].u32 = valueIt->second != 0 ? 1u : 0u;
                break;
            case spirv_cross::SPIRType::Int:
                constant.m.c[0].r[0].i32 =
                    static_cast<std::int32_t>(valueIt->second);
                break;
            case spirv_cross::SPIRType::UInt:
                constant.m.c[0].r[0].u32 = valueIt->second;
                break;
            case spirv_cross::SPIRType::Float:
                static_assert(sizeof(constant.m.c[0].r[0].f32) == sizeof(valueIt->second),
                              "SPIR-V float specialization constants are 32-bit");
                std::memcpy(&constant.m.c[0].r[0].f32,
                            &valueIt->second,
                            sizeof(valueIt->second));
                break;
            default:
                constant.m.c[0].r[0].u32 = valueIt->second;
                break;
        }
        constant.specialization = false;
    }
}

bool sparseStorageImageSidecarTarget(GLenum target) {
    switch (target) {
        case GL_TEXTURE_2D:
        case GL_TEXTURE_2D_ARRAY:
        case GL_TEXTURE_CUBE_MAP:
        case GL_TEXTURE_CUBE_MAP_ARRAY:
        case GL_TEXTURE_3D:
        case GL_TEXTURE_RECTANGLE:
            return true;
        default:
            return false;
    }
}

struct StorageImageAccessVariables {
    std::unordered_set<std::uint32_t> reads;
    std::unordered_set<std::uint32_t> writes;
};

struct StorageBufferAccessVariables {
    std::unordered_set<std::uint32_t> writes;
};

template <typename ResourceList>
StorageImageAccessVariables storageImageAccessVariables(
    const std::uint32_t* spirv,
    std::size_t wordCount,
    const ResourceList& storageImages) {
    std::unordered_set<std::uint32_t> storageIds;
    std::unordered_map<std::uint32_t, std::uint32_t> baseForId;
    for (const auto& image : storageImages) {
        storageIds.insert(image.id);
        baseForId[image.id] = image.id;
    }

    StorageImageAccessVariables access;
    std::size_t cursor = 5;  // SPIR-V header.
    while (spirv != nullptr && cursor < wordCount) {
        const std::uint32_t first = spirv[cursor];
        const std::uint16_t op = static_cast<std::uint16_t>(first & 0xffffu);
        const std::uint16_t length = static_cast<std::uint16_t>(first >> 16u);
        if (length == 0 || cursor + length > wordCount) {
            break;
        }
        const std::uint32_t* inst = spirv + cursor;
        auto baseFor = [&](std::uint32_t id) -> std::uint32_t {
            auto it = baseForId.find(id);
            return it == baseForId.end() ? 0u : it->second;
        };
        auto mapResultFrom = [&](std::uint32_t resultId,
                                 std::uint32_t sourceId) {
            const std::uint32_t base = baseFor(sourceId);
            if (base != 0) {
                baseForId[resultId] = base;
            }
        };

        switch (static_cast<spv::Op>(op)) {
            case spv::OpLoad:
                if (length >= 4) {
                    mapResultFrom(inst[2], inst[3]);
                }
                break;
            case spv::OpAccessChain:
            case spv::OpInBoundsAccessChain:
            case spv::OpPtrAccessChain:
                if (length >= 4) {
                    mapResultFrom(inst[2], inst[3]);
                }
                break;
            case spv::OpCopyObject:
            case spv::OpImage:
                if (length >= 4) {
                    mapResultFrom(inst[2], inst[3]);
                }
                break;
            case spv::OpPhi:
                if (length >= 5) {
                    for (std::uint16_t i = 3; i + 1 < length; i += 2) {
                        const std::uint32_t base = baseFor(inst[i]);
                        if (base != 0) {
                            baseForId[inst[2]] = base;
                            break;
                        }
                    }
                }
                break;
            case spv::OpSelect:
                if (length >= 6) {
                    const std::uint32_t trueBase = baseFor(inst[4]);
                    const std::uint32_t falseBase = baseFor(inst[5]);
                    if (trueBase != 0 && trueBase == falseBase) {
                        baseForId[inst[2]] = trueBase;
                    }
                }
                break;
            case spv::OpImageWrite:
                if (length >= 4) {
                    const std::uint32_t base = baseFor(inst[1]);
                    if (storageIds.find(base) != storageIds.end()) {
                        access.writes.insert(base);
                    }
                }
                break;
            case spv::OpImageRead:
            case spv::OpImageSparseRead:
                if (length >= 5) {
                    const std::uint32_t base = baseFor(inst[3]);
                    if (storageIds.find(base) != storageIds.end()) {
                        access.reads.insert(base);
                    }
                }
                break;
            default:
                break;
        }

        cursor += length;
    }
    return access;
}

template <typename ResourceList>
StorageBufferAccessVariables storageBufferAccessVariables(
    const std::uint32_t* spirv,
    std::size_t wordCount,
    const ResourceList& storageBuffers) {
    std::unordered_set<std::uint32_t> storageIds;
    std::unordered_map<std::uint32_t, std::uint32_t> baseForId;
    for (const auto& buffer : storageBuffers) {
        storageIds.insert(buffer.id);
        baseForId[buffer.id] = buffer.id;
    }

    StorageBufferAccessVariables access;
    std::size_t cursor = 5;  // SPIR-V header.
    while (spirv != nullptr && cursor < wordCount) {
        const std::uint32_t first = spirv[cursor];
        const std::uint16_t op = static_cast<std::uint16_t>(first & 0xffffu);
        const std::uint16_t length = static_cast<std::uint16_t>(first >> 16u);
        if (length == 0 || cursor + length > wordCount) {
            break;
        }
        const std::uint32_t* inst = spirv + cursor;
        auto baseFor = [&](std::uint32_t id) -> std::uint32_t {
            auto it = baseForId.find(id);
            return it == baseForId.end() ? 0u : it->second;
        };
        auto mapResultFrom = [&](std::uint32_t resultId,
                                 std::uint32_t sourceId) {
            const std::uint32_t base = baseFor(sourceId);
            if (base != 0) {
                baseForId[resultId] = base;
            }
        };
        auto markWrite = [&](std::uint32_t pointerId) {
            const std::uint32_t base = baseFor(pointerId);
            if (storageIds.find(base) != storageIds.end()) {
                access.writes.insert(base);
            }
        };

        switch (static_cast<spv::Op>(op)) {
            case spv::OpLoad:
                if (length >= 4) {
                    mapResultFrom(inst[2], inst[3]);
                }
                break;
            case spv::OpAccessChain:
            case spv::OpInBoundsAccessChain:
            case spv::OpPtrAccessChain:
                if (length >= 4) {
                    mapResultFrom(inst[2], inst[3]);
                }
                break;
            case spv::OpCopyObject:
                if (length >= 4) {
                    mapResultFrom(inst[2], inst[3]);
                }
                break;
            case spv::OpPhi:
                if (length >= 5) {
                    for (std::uint16_t i = 3; i + 1 < length; i += 2) {
                        const std::uint32_t base = baseFor(inst[i]);
                        if (base != 0) {
                            baseForId[inst[2]] = base;
                            break;
                        }
                    }
                }
                break;
            case spv::OpSelect:
                if (length >= 6) {
                    const std::uint32_t trueBase = baseFor(inst[4]);
                    const std::uint32_t falseBase = baseFor(inst[5]);
                    if (trueBase != 0 && trueBase == falseBase) {
                        baseForId[inst[2]] = trueBase;
                    }
                }
                break;
            case spv::OpStore:
            case spv::OpCopyMemory:
            case spv::OpCopyMemorySized:
                if (length >= 2) {
                    markWrite(inst[1]);
                }
                break;
            case spv::OpAtomicStore:
                if (length >= 2) {
                    markWrite(inst[1]);
                }
                break;
            case spv::OpAtomicExchange:
            case spv::OpAtomicCompareExchange:
            case spv::OpAtomicCompareExchangeWeak:
            case spv::OpAtomicIIncrement:
            case spv::OpAtomicIDecrement:
            case spv::OpAtomicIAdd:
            case spv::OpAtomicISub:
            case spv::OpAtomicSMin:
            case spv::OpAtomicUMin:
            case spv::OpAtomicSMax:
            case spv::OpAtomicUMax:
            case spv::OpAtomicAnd:
            case spv::OpAtomicOr:
            case spv::OpAtomicXor:
                if (length >= 4) {
                    markWrite(inst[3]);
                }
                break;
            default:
                break;
        }

        cursor += length;
    }
    return access;
}

bool isIdentifierChar(char ch) {
    return std::isalnum(static_cast<unsigned char>(ch)) || ch == '_';
}

bool findMain0ParameterEnd(const std::string& msl, std::size_t& paramEnd);
void threadTextureReductionModesThroughHelpers(std::string& msl,
                                               const std::string& paramName);

bool replaceWholeToken(std::string& text,
                       std::size_t begin,
                       const std::string& needle,
                       const std::string& replacement,
                       std::size_t end = std::string::npos) {
    bool changed = false;
    if (end == std::string::npos || end > text.size()) {
        end = text.size();
    }
    std::size_t pos = begin;
    while ((pos = text.find(needle, pos)) != std::string::npos && pos < end) {
        const std::size_t after = pos + needle.size();
        if (after < text.size() && isIdentifierChar(text[after])) {
            pos = after;
            continue;
        }
        text.replace(pos, needle.size(), replacement);
        const auto delta = static_cast<std::ptrdiff_t>(replacement.size()) -
            static_cast<std::ptrdiff_t>(needle.size());
        if (delta != 0 && end != std::string::npos) {
            end = static_cast<std::size_t>(
                static_cast<std::ptrdiff_t>(end) + delta);
        }
        pos += replacement.size();
        changed = true;
    }
    return changed;
}

bool lowerFp64VertexStageInputs(std::string& msl) {
    struct Fp64Input {
        std::string name;
        std::string suffix;
        std::uint32_t location = 0;
    };
    struct AttributeLine {
        std::size_t lineStart = 0;
        std::size_t lineEnd = 0;
        std::size_t attrNumberStart = 0;
        std::size_t attrNumberEnd = 0;
        std::string typeName;
        std::string name;
        std::uint32_t originalLocation = 0;
        std::uint32_t adjustedLocation = 0;
        std::uint32_t sourceOrder = 0;
    };
    std::vector<Fp64Input> inputs;
    std::vector<AttributeLine> attributes;

    const std::string structNeedle = "struct main0_in";
    const std::size_t structPos = msl.find(structNeedle);
    if (structPos == std::string::npos) {
        return false;
    }
    const std::size_t structOpen = msl.find('{', structPos);
    if (structOpen == std::string::npos) {
        return false;
    }
    std::size_t structClose = msl.find("};", structOpen);
    if (structClose == std::string::npos) {
        return false;
    }

    std::size_t lineStart = structOpen + 1;
    std::uint32_t sourceOrder = 0;
    while (lineStart < structClose) {
        std::size_t lineEnd = msl.find('\n', lineStart);
        if (lineEnd == std::string::npos || lineEnd > structClose) {
            lineEnd = structClose;
        }
        const std::string line = msl.substr(lineStart, lineEnd - lineStart);
        const std::size_t attrPos = line.find("[[attribute(");
        if (attrPos != std::string::npos) {
            std::size_t typePos = 0;
            while (typePos < line.size() &&
                   std::isspace(static_cast<unsigned char>(line[typePos]))) {
                ++typePos;
            }
            std::size_t typeEnd = typePos;
            while (typeEnd < line.size() && isIdentifierChar(line[typeEnd])) {
                ++typeEnd;
            }
            const std::string typeName =
                line.substr(typePos, typeEnd - typePos);
            std::size_t nameStart = typeEnd;
            while (nameStart < line.size() &&
                   std::isspace(static_cast<unsigned char>(line[nameStart]))) {
                ++nameStart;
            }
            std::size_t nameEnd = nameStart;
            while (nameEnd < line.size() && isIdentifierChar(line[nameEnd])) {
                ++nameEnd;
            }
            const std::string name = line.substr(nameStart, nameEnd - nameStart);
            const std::size_t locStart = attrPos + std::strlen("[[attribute(");
            std::size_t locEnd = locStart;
            std::uint32_t location = 0;
            while (locEnd < line.size() &&
                   std::isdigit(static_cast<unsigned char>(line[locEnd]))) {
                location = location * 10u +
                    static_cast<std::uint32_t>(line[locEnd] - '0');
                ++locEnd;
            }
            if (!name.empty() && locEnd > locStart) {
                AttributeLine attr;
                attr.lineStart = lineStart;
                attr.lineEnd = lineEnd;
                attr.attrNumberStart = lineStart + locStart;
                attr.attrNumberEnd = lineStart + locEnd;
                attr.typeName = typeName;
                attr.name = name;
                attr.originalLocation = location;
                attr.adjustedLocation = location;
                attr.sourceOrder = sourceOrder++;
                attributes.push_back(std::move(attr));
            }
        }
        lineStart = lineEnd + 1;
    }

    auto fp64SlotCount = [](const std::string& typeName) -> std::uint32_t {
        return (typeName == "appgl_df64x3" || typeName == "appgl_df64x4")
            ? 2u : 1u;
    };
    std::vector<std::size_t> sorted;
    sorted.reserve(attributes.size());
    for (std::size_t i = 0; i < attributes.size(); ++i) {
        sorted.push_back(i);
    }
    std::stable_sort(sorted.begin(), sorted.end(),
                     [&](std::size_t a, std::size_t b) {
                         if (attributes[a].originalLocation !=
                             attributes[b].originalLocation) {
                             return attributes[a].originalLocation <
                                    attributes[b].originalLocation;
                         }
                         return attributes[a].sourceOrder <
                                attributes[b].sourceOrder;
                     });
    std::uint32_t nextMslLocation = 0;
    for (std::size_t idx : sorted) {
        AttributeLine& attr = attributes[idx];
        if (attr.originalLocation > nextMslLocation) {
            nextMslLocation = attr.originalLocation;
        }
        attr.adjustedLocation = nextMslLocation;
        nextMslLocation += fp64SlotCount(attr.typeName);
    }

    std::string newBody;
    newBody.reserve(structClose - structOpen + attributes.size() * 24u);
    std::size_t cursor = structOpen + 1;
    bool changed = false;
    bool loweredAny = false;
    for (const auto& attr : attributes) {
        newBody.append(msl, cursor, attr.lineStart - cursor);
        const std::string line = msl.substr(attr.lineStart,
                                           attr.lineEnd - attr.lineStart);
        std::string replacement;
        if (attr.typeName == "appgl_df64") {
            replacement = "    uint2 " + attr.name + " [[attribute(" +
                std::to_string(attr.adjustedLocation) + ")]];";
        } else if (attr.typeName == "appgl_df64x2") {
            replacement = "    uint4 " + attr.name + " [[attribute(" +
                std::to_string(attr.adjustedLocation) + ")]];";
        } else if (attr.typeName == "appgl_df64x3") {
            replacement = "    uint4 " + attr.name + "_0 [[attribute(" +
                std::to_string(attr.adjustedLocation) + ")]];\n    uint2 " +
                attr.name + "_1 [[attribute(" +
                std::to_string(attr.adjustedLocation + 1u) + ")]];";
        } else if (attr.typeName == "appgl_df64x4") {
            replacement = "    uint4 " + attr.name + "_0 [[attribute(" +
                std::to_string(attr.adjustedLocation) + ")]];\n    uint4 " +
                attr.name + "_1 [[attribute(" +
                std::to_string(attr.adjustedLocation + 1u) + ")]];";
        } else if (attr.adjustedLocation != attr.originalLocation) {
            replacement = line;
            replacement.replace(attr.attrNumberStart - attr.lineStart,
                                attr.attrNumberEnd - attr.attrNumberStart,
                                std::to_string(attr.adjustedLocation));
        } else {
            replacement = line;
        }

        if (attr.typeName.rfind("appgl_df64", 0) == 0) {
            Fp64Input input;
            input.name = attr.name;
            input.suffix = attr.typeName.substr(std::strlen("appgl_df64"));
            input.location = attr.adjustedLocation;
            inputs.push_back(std::move(input));
            loweredAny = true;
        }
        changed = changed || replacement != line;
        newBody.append(replacement);
        cursor = attr.lineEnd;
    }
    newBody.append(msl, cursor, structClose - cursor);
    if (changed) {
        const std::size_t bodyStart = structOpen + 1;
        const std::size_t oldBodySize = structClose - bodyStart;
        msl.replace(bodyStart, oldBodySize, newBody);
        structClose = bodyStart + newBody.size();
    }

    if (inputs.empty()) {
        return loweredAny;
    }

    const std::size_t mainPos = msl.find("main0(");
    if (mainPos == std::string::npos) {
        return true;
    }
    std::size_t paramEnd = mainPos;
    if (!findMain0ParameterEnd(msl, paramEnd)) {
        return true;
    }
    const std::size_t bodyOpen = msl.find('{', paramEnd);
    if (bodyOpen == std::string::npos) {
        return true;
    }

    for (const auto& input : inputs) {
        replaceWholeToken(msl, bodyOpen + 1, "in." + input.name, input.name);
    }

    std::string injection;
    for (const auto& input : inputs) {
        if (input.suffix.empty()) {
            injection += "\n    appgl_df64 " + input.name +
                " = appgl_df64_from_words2(in." + input.name + ");";
        } else if (input.suffix == "x2") {
            injection += "\n    appgl_df64x2 " + input.name +
                " = appgl_df64x2(appgl_df64_from_words2(in." +
                input.name + ".xy), appgl_df64_from_words2(in." +
                input.name + ".zw));";
        } else if (input.suffix == "x3") {
            injection += "\n    appgl_df64x3 " + input.name +
                " = appgl_df64x3(appgl_df64_from_words2(in." +
                input.name + "_0.xy), appgl_df64_from_words2(in." +
                input.name + "_0.zw), appgl_df64_from_words2(in." +
                input.name + "_1));";
        } else if (input.suffix == "x4") {
            injection += "\n    appgl_df64x4 " + input.name +
                " = appgl_df64x4(appgl_df64_from_words2(in." +
                input.name + "_0.xy), appgl_df64_from_words2(in." +
                input.name + "_0.zw), appgl_df64_from_words2(in." +
                input.name + "_1.xy), appgl_df64_from_words2(in." +
                input.name + "_1.zw));";
        }
    }
    if (!injection.empty()) {
        msl.insert(bodyOpen + 1, injection);
    }
    return true;
}

bool rewriteVertexMatrixArrayInputs(
    std::string& msl,
    spirv_cross::CompilerMSL& compiler,
    const spirv_cross::ShaderResources& resources,
    bool includeFp64LoweredInputs,
    std::string* reason) {
    struct MatrixArrayInput {
        std::string name;
        std::string sourcePrefix;
        std::string reasonScope;
        std::uint32_t arrayCount = 1;
        std::uint32_t columnCount = 1;
    };

    std::vector<MatrixArrayInput> inputs;
    for (const auto& input : resources.stage_inputs) {
        const auto& type = compiler.get_type(input.type_id);
        if (type.columns <= 1 || type.array.empty()) {
            continue;
        }

        std::string sourcePrefix;
        std::string reasonScope;
        if (type.basetype == spirv_cross::SPIRType::Float) {
            sourcePrefix = "in.";
            reasonScope = "native";
        } else if (includeFp64LoweredInputs &&
                   type.basetype == spirv_cross::SPIRType::Double) {
            reasonScope = "fp64 lowered";
        } else {
            continue;
        }

        std::uint32_t arrayCount = 1;
        for (const auto dim : type.array) {
            if (dim == 0) {
                arrayCount = 0;
                break;
            }
            arrayCount *= static_cast<std::uint32_t>(dim);
        }
        if (arrayCount == 0) {
            continue;
        }

        MatrixArrayInput entry;
        entry.name = input.name;
        entry.sourcePrefix = std::move(sourcePrefix);
        entry.reasonScope = std::move(reasonScope);
        entry.arrayCount = arrayCount;
        entry.columnCount = type.columns;
        inputs.push_back(std::move(entry));
    }
    if (inputs.empty()) {
        return true;
    }

    const std::size_t mainPos = msl.find("main0(");
    if (mainPos == std::string::npos) {
        if (reason != nullptr) {
            *reason = "vertex matrix-array input rewrite: missing main0";
        }
        return false;
    }
    std::size_t paramEnd = mainPos;
    if (!findMain0ParameterEnd(msl, paramEnd)) {
        if (reason != nullptr) {
            *reason =
                "vertex matrix-array input rewrite: malformed main0 params";
        }
        return false;
    }
    const std::size_t bodyOpen = msl.find('{', paramEnd);
    if (bodyOpen == std::string::npos) {
        if (reason != nullptr) {
            *reason = "vertex matrix-array input rewrite: missing main0 body";
        }
        return false;
    }

    for (const auto& input : inputs) {
        const std::uint32_t flatCount =
            input.arrayCount * input.columnCount;
        for (std::uint32_t flat = 0; flat < flatCount; ++flat) {
            const std::string source =
                input.sourcePrefix + input.name + "_" + std::to_string(flat);
            const std::string expected =
                "    " + input.name + "[" + std::to_string(flat) +
                "] = " + source + ";";
            const std::size_t pos = msl.find(expected, bodyOpen + 1);
            if (pos == std::string::npos) {
                if (reason != nullptr) {
                    *reason =
                        "vertex matrix-array input rewrite: missing exact " +
                        input.reasonScope + " assignment `" + expected + "`";
                }
                return false;
            }
            const std::uint32_t arrayIndex = flat / input.columnCount;
            const std::uint32_t columnIndex = flat % input.columnCount;
            const std::string replacement =
                "    " + input.name + "[" + std::to_string(arrayIndex) +
                "][" + std::to_string(columnIndex) + "] = " + source + ";";
            msl.replace(pos, expected.size(), replacement);
        }
    }
    return true;
}

std::string fp64StageTransportType(const std::string& typeName) {
    if (typeName == "appgl_df64") return "float";
    if (typeName == "appgl_df64x2") return "float2";
    if (typeName == "appgl_df64x3") return "float3";
    if (typeName == "appgl_df64x4") return "float4";
    return {};
}

struct Fp64StageField {
    std::string name;
    std::string typeName;
    std::string transportType;
};

std::vector<Fp64StageField> rewriteFp64StageStructFields(
    std::string& msl,
    const std::string& structName)
{
    std::vector<Fp64StageField> fields;
    const std::size_t structPos = msl.find("struct " + structName);
    if (structPos == std::string::npos ||
        msl.find("appgl_df64", structPos) == std::string::npos) {
        return fields;
    }
    const std::size_t braceOpen = msl.find('{', structPos);
    if (braceOpen == std::string::npos) {
        return fields;
    }
    const std::size_t braceClose = msl.find("};", braceOpen);
    if (braceClose == std::string::npos) {
        return fields;
    }

    std::string rewrittenBody;
    rewrittenBody.reserve(braceClose - braceOpen);
    std::size_t lineStart = braceOpen + 1;
    while (lineStart < braceClose) {
        std::size_t lineEnd = msl.find('\n', lineStart);
        if (lineEnd == std::string::npos || lineEnd > braceClose) {
            lineEnd = braceClose;
        }
        std::string line = msl.substr(lineStart, lineEnd - lineStart);
        const std::size_t typePos = line.find("appgl_df64");
        const bool stageField =
            line.find("[[user(locn") != std::string::npos;
        if (typePos != std::string::npos && stageField) {
            std::size_t typeEnd = typePos;
            while (typeEnd < line.size() && isIdentifierChar(line[typeEnd])) {
                ++typeEnd;
            }
            const std::string typeName = line.substr(typePos, typeEnd - typePos);
            const std::string transportType = fp64StageTransportType(typeName);
            if (!transportType.empty()) {
                std::size_t nameStart = typeEnd;
                while (nameStart < line.size() &&
                       std::isspace(static_cast<unsigned char>(line[nameStart]))) {
                    ++nameStart;
                }
                std::size_t nameEnd = nameStart;
                while (nameEnd < line.size() && isIdentifierChar(line[nameEnd])) {
                    ++nameEnd;
                }
                if (nameEnd > nameStart) {
                    fields.push_back({
                        line.substr(nameStart, nameEnd - nameStart),
                        typeName,
                        transportType
                    });
                    line.replace(typePos, typeName.size(), transportType);
                }
            }
        }
        rewrittenBody += line;
        if (lineEnd < braceClose) {
            rewrittenBody += '\n';
        }
        lineStart = lineEnd + 1;
    }

    if (!fields.empty()) {
        msl.replace(braceOpen + 1, braceClose - (braceOpen + 1),
                    rewrittenBody);
    }
    return fields;
}

bool rewriteVertexFp64StageOutputTransport(std::string& msl) {
    auto fields = rewriteFp64StageStructFields(msl, "main0_out");
    if (fields.empty()) {
        return false;
    }

    const std::size_t mainPos = msl.find("main0(");
    if (mainPos == std::string::npos) {
        return true;
    }
    std::size_t paramEnd = mainPos;
    if (!findMain0ParameterEnd(msl, paramEnd)) {
        return true;
    }
    const std::size_t bodyOpen = msl.find('{', paramEnd);
    if (bodyOpen == std::string::npos) {
        return true;
    }

    for (const auto& field : fields) {
        const std::string assignNeedle = "out." + field.name + " = ";
        std::size_t pos = bodyOpen + 1;
        while ((pos = msl.find(assignNeedle, pos)) != std::string::npos) {
            const std::size_t rhsStart = pos + assignNeedle.size();
            const std::size_t semi = msl.find(';', rhsStart);
            if (semi == std::string::npos) {
                break;
            }
            const std::string rhs = msl.substr(rhsStart, semi - rhsStart);
            const std::string replacement =
                "appgl_df64_to_float(" + rhs + ")";
            msl.replace(rhsStart, semi - rhsStart, replacement);
            pos = rhsStart + replacement.size();
        }
    }
    return true;
}

bool rewriteFragmentFp64StageInputTransport(std::string& msl) {
    auto fields = rewriteFp64StageStructFields(msl, "main0_in");
    if (fields.empty()) {
        return false;
    }

    const std::size_t mainPos = msl.find("main0(");
    if (mainPos == std::string::npos) {
        return true;
    }
    std::size_t paramEnd = mainPos;
    if (!findMain0ParameterEnd(msl, paramEnd)) {
        return true;
    }
    const std::size_t bodyOpen = msl.find('{', paramEnd);
    if (bodyOpen == std::string::npos) {
        return true;
    }

    for (const auto& field : fields) {
        const std::string needle = "in." + field.name;
        const std::string replacement =
            "appgl_df64_from_float(" + needle + ")";
        std::size_t pos = bodyOpen + 1;
        while ((pos = msl.find(needle, pos)) != std::string::npos) {
            const bool leftOk =
                (pos == 0) || !isIdentifierChar(msl[pos - 1]);
            const std::size_t right = pos + needle.size();
            const bool rightOk =
                (right >= msl.size()) || !isIdentifierChar(msl[right]);
            if (leftOk && rightOk) {
                msl.replace(pos, needle.size(), replacement);
                pos += replacement.size();
            } else {
                pos += needle.size();
            }
        }
    }
    return true;
}

bool rewritePackedFp64DefaultUniforms(std::string& msl) {
    const std::size_t uniformsPos = msl.find("struct _DefaultUniforms");
    if (uniformsPos == std::string::npos ||
        msl.find("packed_appgl_df64", uniformsPos) == std::string::npos) {
        return false;
    }

    const std::size_t braceOpen = msl.find('{', uniformsPos);
    if (braceOpen == std::string::npos) {
        return false;
    }
    const std::size_t braceClose = msl.find("};", braceOpen);
    if (braceClose == std::string::npos) {
        return false;
    }

    struct PackedField {
        std::string packedType;
        std::string unpackedType;
        std::string name;
    };
    std::vector<PackedField> fields;
    std::size_t lineStart = braceOpen + 1;
    while (lineStart < braceClose) {
        std::size_t lineEnd = msl.find('\n', lineStart);
        if (lineEnd == std::string::npos || lineEnd > braceClose) {
            lineEnd = braceClose;
        }
        const std::string line = msl.substr(lineStart, lineEnd - lineStart);
        const std::size_t typePos = line.find("packed_appgl_df64");
        if (typePos != std::string::npos) {
            std::size_t typeEnd = typePos;
            while (typeEnd < line.size() && isIdentifierChar(line[typeEnd])) {
                ++typeEnd;
            }
            const std::string packedType =
                line.substr(typePos, typeEnd - typePos);
            std::size_t nameStart = typeEnd;
            while (nameStart < line.size() &&
                   std::isspace(static_cast<unsigned char>(line[nameStart]))) {
                ++nameStart;
            }
            std::size_t nameEnd = nameStart;
            while (nameEnd < line.size() && isIdentifierChar(line[nameEnd])) {
                ++nameEnd;
            }
            if (nameEnd > nameStart) {
                fields.push_back({
                    packedType,
                    packedType.substr(std::strlen("packed_")),
                    line.substr(nameStart, nameEnd - nameStart)
                });
            }
        }
        lineStart = lineEnd + 1;
    }

    if (fields.empty()) {
        return false;
    }

    if (msl.find("struct packed_appgl_df64") == std::string::npos) {
        const std::size_t insertPos = msl.find("struct appgl_df64mat2x2");
        if (insertPos != std::string::npos) {
            const char* packedDefs = R"MSL(
struct packed_appgl_df64 {
    uint2 words;
};

struct packed_appgl_df64x2 {
    uint2 x;
    uint2 y;
};

struct packed_appgl_df64x3 {
    uint2 x;
    uint2 y;
    uint2 z;
};

struct packed_appgl_df64x4 {
    uint2 x;
    uint2 y;
    uint2 z;
    uint2 w;
};

inline appgl_df64 appgl_df64_from_packed(packed_appgl_df64 v)
{
    return appgl_df64(v.words);
}

inline appgl_df64x2 appgl_df64_from_packed(packed_appgl_df64x2 v)
{
    return appgl_df64x2(appgl_df64(v.x), appgl_df64(v.y));
}

inline appgl_df64x3 appgl_df64_from_packed(packed_appgl_df64x3 v)
{
    return appgl_df64x3(appgl_df64(v.x), appgl_df64(v.y), appgl_df64(v.z));
}

inline appgl_df64x4 appgl_df64_from_packed(packed_appgl_df64x4 v)
{
    return appgl_df64x4(appgl_df64(v.x), appgl_df64(v.y), appgl_df64(v.z), appgl_df64(v.w));
}

)MSL";
            msl.insert(insertPos, packedDefs);
        }
    }

    for (const auto& field : fields) {
        const std::string ctor = field.unpackedType + "(";
        std::size_t pos = 0;
        while ((pos = msl.find(ctor, pos)) != std::string::npos) {
            const std::size_t argStart = pos + ctor.size();
            const std::size_t close = msl.find(')', argStart);
            if (close == std::string::npos) {
                break;
            }
            const std::string arg = msl.substr(argStart, close - argStart);
            const std::string suffix = "." + field.name;
            if (arg.size() >= suffix.size() &&
                arg.compare(arg.size() - suffix.size(), suffix.size(),
                            suffix) == 0) {
                const std::string replacement =
                    "appgl_df64_from_packed(" + arg + ")";
                msl.replace(pos, close + 1 - pos, replacement);
                pos += replacement.size();
            } else {
                pos = close + 1;
            }
        }
    }

    return true;
}

bool injectFp64FractOverloads(std::string& msl) {
    if (msl.find("struct appgl_df64") == std::string::npos ||
        msl.find("appgl_df64_fract") != std::string::npos) {
        return false;
    }

    static constexpr const char* kTruncHelper =
        "inline appgl_df64 appgl_df64_trunc(appgl_df64 value) { "
        "return appgl_df64_from_float(trunc(appgl_df64_to_float(value))); }";
    const std::size_t helperPos = msl.find(kTruncHelper);
    if (helperPos == std::string::npos) {
        return false;
    }

    const std::size_t insertPos = msl.find('\n', helperPos);
    if (insertPos == std::string::npos) {
        return false;
    }

    static constexpr const char* kFractOverloads = R"MSL(
inline appgl_df64 appgl_df64_fract(appgl_df64 value) { return appgl_df64_sub(value, appgl_df64_floor(value)); }
inline appgl_df64x2 appgl_df64_fract(appgl_df64x2 value) { return appgl_df64x2(appgl_df64_fract(value.x), appgl_df64_fract(value.y)); }
inline appgl_df64x3 appgl_df64_fract(appgl_df64x3 value) { return appgl_df64x3(appgl_df64_fract(value.x), appgl_df64_fract(value.y), appgl_df64_fract(value.z)); }
inline appgl_df64x4 appgl_df64_fract(appgl_df64x4 value) { return appgl_df64x4(appgl_df64_fract(value.x), appgl_df64_fract(value.y), appgl_df64_fract(value.z), appgl_df64_fract(value.w)); }
inline appgl_df64 fract(appgl_df64 value) { return appgl_df64_fract(value); }
inline appgl_df64x2 fract(appgl_df64x2 value) { return appgl_df64_fract(value); }
inline appgl_df64x3 fract(appgl_df64x3 value) { return appgl_df64_fract(value); }
inline appgl_df64x4 fract(appgl_df64x4 value) { return appgl_df64_fract(value); }
)MSL";
    msl.insert(insertPos + 1, kFractOverloads);
    return true;
}

void fixStorageImageSignedCoordinateCasts(std::string& msl) {
    struct CoordVar {
        std::string name;
        const char* castType;
    };
    std::vector<CoordVar> coords;

    std::size_t lineStart = 0;
    while (lineStart < msl.size()) {
        const std::size_t lineEnd = msl.find('\n', lineStart);
        const std::size_t end =
            (lineEnd == std::string::npos) ? msl.size() : lineEnd;
        std::size_t p = lineStart;
        while (p < end && std::isspace(static_cast<unsigned char>(msl[p]))) {
            ++p;
        }

        const char* castType = nullptr;
        std::size_t typeLen = 0;
        if (p + 4 <= end && msl.compare(p, 4, "int ") == 0) {
            castType = "uint";
            typeLen = 3;
        } else if (p + 5 <= end && msl.compare(p, 5, "int2 ") == 0) {
            castType = "uint2";
            typeLen = 4;
        } else if (p + 5 <= end && msl.compare(p, 5, "int3 ") == 0) {
            castType = "uint3";
            typeLen = 4;
        }
        if (castType != nullptr) {
            p += typeLen;
            while (p < end && std::isspace(static_cast<unsigned char>(msl[p]))) {
                ++p;
            }
            const std::size_t nameStart = p;
            while (p < end && isIdentifierChar(msl[p])) {
                ++p;
            }
            if (p > nameStart) {
                coords.push_back({msl.substr(nameStart, p - nameStart), castType});
            }
        }

        if (lineEnd == std::string::npos) break;
        lineStart = lineEnd + 1;
    }

    auto replaceReadCoord = [&](const CoordVar& coord) {
        const std::string needle = ".read(" + coord.name;
        const std::string replacement =
            ".read(" + std::string(coord.castType) + "(" + coord.name + ")";
        std::size_t pos = 0;
        while ((pos = msl.find(needle, pos)) != std::string::npos) {
            const std::size_t after = pos + needle.size();
            if (after < msl.size() && isIdentifierChar(msl[after])) {
                pos = after;
                continue;
            }
            msl.replace(pos, needle.size(), replacement);
            pos += replacement.size();
        }
    };

    auto replaceWriteCoord = [&](const CoordVar& coord) {
        const std::string needle = ", " + coord.name;
        const std::string replacement =
            ", " + std::string(coord.castType) + "(" + coord.name + ")";
        std::size_t pos = 0;
        while ((pos = msl.find(needle, pos)) != std::string::npos) {
            const std::size_t line = msl.rfind('\n', pos);
            const std::size_t begin = (line == std::string::npos) ? 0 : line + 1;
            const std::size_t writePos = msl.rfind(".write(", pos);
            const std::size_t after = pos + needle.size();
            if (writePos == std::string::npos || writePos < begin ||
                (after < msl.size() && isIdentifierChar(msl[after]))) {
                pos = after;
                continue;
            }
            msl.replace(pos, needle.size(), replacement);
            pos += replacement.size();
        }
    };

    for (const auto& coord : coords) {
        replaceReadCoord(coord);
        replaceWriteCoord(coord);
    }
}

bool injectFragmentCoordYFixup(std::string& msl,
                               bool pixelCenterInteger) {
    static constexpr const char* kFragCoordParam =
        "float4 gl_FragCoord [[position]]";
    static constexpr const char* kParamsName = "_appgl_FragCoordParams";
    if (msl.find(kFragCoordParam) == std::string::npos ||
        msl.find(kParamsName) != std::string::npos) {
        return false;
    }

    const std::size_t mainPos = msl.find("main0(");
    if (mainPos == std::string::npos) return false;
    const std::size_t paramStart = mainPos + 6;
    std::size_t depth = 1;
    std::size_t paramEnd = paramStart;
    while (paramEnd < msl.size() && depth > 0) {
        const char c = msl[paramEnd];
        if (c == '(') {
            ++depth;
        } else if (c == ')') {
            --depth;
            if (depth == 0) break;
        }
        ++paramEnd;
    }
    if (depth != 0 || paramEnd >= msl.size()) return false;

    const std::size_t bodyOpen = msl.find('{', paramEnd);
    if (bodyOpen == std::string::npos) return false;

    const std::string param =
        ", constant float4& " + std::string(kParamsName) +
        " [[buffer(" + std::to_string(kFragCoordParamsBufferSlot) + ")]]";
    msl.insert(paramEnd, param);
    const std::size_t adjustedBodyOpen = bodyOpen + param.size();

    const char* bias = pixelCenterInteger ? "-0.5f" : "0.0f";
    const std::string injection =
        "\n    // Sprint 18 Bank D-3: shader-side FragCoord-Y synthesis.\n"
        "    // Metal [[position]].y is top-left; when GL clip origin is LOWER_LEFT,\n"
        "    // buffer(15) flips it to GL bottom-left without touching the\n"
        "    // 5930a4d/c196254 FBO readback orientation markers.\n"
        "    gl_FragCoord.y = _appgl_FragCoordParams.x +\n"
        "        (_appgl_FragCoordParams.y * gl_FragCoord.y) +\n"
        "        (_appgl_FragCoordParams.z * " + std::string(bias) + ");";
    msl.insert(adjustedBodyOpen + 1, injection);
    return true;
}

bool rewriteFragmentSamplePositionYForGL(std::string& msl) {
    static constexpr const char* kSamplePositionDecl =
        "float2 gl_SamplePosition = get_sample_position(gl_SampleID);";
    static constexpr const char* kSamplePositionYFlip =
        "float2 gl_SamplePosition = get_sample_position(gl_SampleID);\n"
        "    gl_SamplePosition.y = 1.0f - gl_SamplePosition.y;";
    if (msl.find("gl_SamplePosition.y = 1.0f - gl_SamplePosition.y") !=
        std::string::npos) {
        return false;
    }
    bool rewritten = false;
    std::size_t pos = 0;
    while ((pos = msl.find(kSamplePositionDecl, pos)) != std::string::npos) {
        msl.replace(pos, std::strlen(kSamplePositionDecl), kSamplePositionYFlip);
        pos += std::strlen(kSamplePositionYFlip);
        rewritten = true;
    }
    return rewritten;
}

bool rewriteFragmentInterpolateAtOffsetYForGL(std::string& msl) {
    static constexpr const char* kCallNeedle = ".interpolate_at_offset(";
    static constexpr const char* kHelperName =
        "appgl_gl_to_metal_interpolate_offset";
    static constexpr const char* kUsingAnchor = "using namespace metal;\n";
    static constexpr const char* kHelper =
        "\nstatic inline float2 appgl_gl_to_metal_interpolate_offset(float2 p)\n"
        "{\n"
        "    return float2(p.x, 1.0f - p.y);\n"
        "}\n";

    bool rewritten = false;
    std::size_t pos = 0;
    while ((pos = msl.find(kCallNeedle, pos)) != std::string::npos) {
        const std::size_t open = pos + std::strlen(kCallNeedle) - 1u;
        std::size_t close = std::string::npos;
        if (!findMatchingParen(msl, open, close)) {
            pos += std::strlen(kCallNeedle);
            continue;
        }
        const std::string arg = msl.substr(open + 1u, close - open - 1u);
        if (arg.find(kHelperName) != std::string::npos) {
            pos = close + 1u;
            continue;
        }
        const std::string replacement =
            std::string(kHelperName) + "(" + arg + ")";
        msl.replace(open + 1u, close - open - 1u, replacement);
        pos = open + 1u + replacement.size();
        rewritten = true;
    }

    if (rewritten &&
        msl.find("static inline float2 appgl_gl_to_metal_interpolate_offset") ==
            std::string::npos) {
        const std::size_t usingPos = msl.find(kUsingAnchor);
        if (usingPos != std::string::npos) {
            msl.insert(usingPos + std::strlen(kUsingAnchor), kHelper);
        } else {
            msl.insert(0, kHelper);
        }
    }
    return rewritten;
}

bool eraseNoOpFragDepthWrite(std::string& msl) {
    static constexpr const char* kDepthField =
        "float gl_FragDepth [[depth(any)]];";
    static constexpr const char* kDepthAssign =
        "out.gl_FragDepth = gl_FragCoord.z;";
    if (msl.find("float4 gl_FragCoord [[position]]") == std::string::npos ||
        msl.find(kDepthField) == std::string::npos ||
        msl.find(kDepthAssign) == std::string::npos) {
        return false;
    }

    std::size_t depthMentions = 0;
    std::size_t search = 0;
    while ((search = msl.find("gl_FragDepth", search)) != std::string::npos) {
        ++depthMentions;
        search += std::strlen("gl_FragDepth");
    }
    if (depthMentions != 2) {
        return false;
    }

    auto eraseLineContaining = [&](const char* needle) -> bool {
        const std::size_t pos = msl.find(needle);
        if (pos == std::string::npos) {
            return false;
        }
        const std::size_t lineStart = msl.rfind('\n', pos);
        const std::size_t eraseStart =
            (lineStart == std::string::npos) ? 0 : lineStart + 1;
        const std::size_t lineEnd = msl.find('\n', pos);
        const std::size_t eraseEnd =
            (lineEnd == std::string::npos) ? msl.size() : lineEnd + 1;
        msl.erase(eraseStart, eraseEnd - eraseStart);
        return true;
    };
    auto eraseOnce = [](std::string& text,
                        const std::string& needle) -> bool {
        const std::size_t pos = text.find(needle);
        if (pos == std::string::npos) {
            return false;
        }
        text.erase(pos, needle.size());
        return true;
    };
    auto eraseFragCoordFixupBlock = [](std::string& text) -> bool {
        static constexpr const char* kMarker =
            "    // Sprint 18 Bank D-3: shader-side FragCoord-Y synthesis.";
        const std::size_t begin = text.find(kMarker);
        if (begin == std::string::npos) {
            return false;
        }
        const std::size_t zLine = text.find("_appgl_FragCoordParams.z", begin);
        if (zLine == std::string::npos) {
            return false;
        }
        const std::size_t semi = text.find(';', zLine);
        if (semi == std::string::npos) {
            return false;
        }
        const std::size_t lineEnd = text.find('\n', semi);
        const std::size_t end =
            (lineEnd == std::string::npos) ? text.size() : lineEnd + 1;
        text.erase(begin, end - begin);
        return true;
    };

    // GLSL `gl_FragDepth = gl_FragCoord.z` is a semantic no-op. Keeping it as
    // an explicit Metal depth output can introduce a strict-compare precision
    // edge versus fixed-function raster depth, so let Metal use its native
    // raster depth when SPIRV-Cross emitted exactly this pattern.
    const bool erasedAssign = eraseLineContaining(kDepthAssign);
    const bool erasedField = eraseLineContaining(kDepthField);
    if (erasedAssign && erasedField) {
        std::string trial = msl;
        (void)eraseFragCoordFixupBlock(trial);
        (void)eraseOnce(trial, ", float4 gl_FragCoord [[position]]");
        (void)eraseOnce(trial, "float4 gl_FragCoord [[position]], ");
        const std::string fragCoordParams =
            ", constant float4& _appgl_FragCoordParams [[buffer(" +
            std::to_string(kFragCoordParamsBufferSlot) + ")]]";
        const std::string leadingFragCoordParams =
            "constant float4& _appgl_FragCoordParams [[buffer(" +
            std::to_string(kFragCoordParamsBufferSlot) + ")]], ";
        (void)eraseOnce(trial, fragCoordParams);
        (void)eraseOnce(trial, leadingFragCoordParams);
        if (trial.find("gl_FragCoord") == std::string::npos &&
            trial.find("_appgl_FragCoordParams") == std::string::npos) {
            msl = std::move(trial);
        }
    }
    return erasedAssign && erasedField;
}

bool findMain0ParameterEnd(const std::string& msl, std::size_t& paramEnd) {
    std::size_t searchPos = 0;
    while (true) {
        const std::size_t mainPos = msl.find("main0(", searchPos);
        if (mainPos == std::string::npos) return false;
        if (mainPos > 0 && isIdentifierChar(msl[mainPos - 1])) {
            searchPos = mainPos + 1;
            continue;
        }
        const std::size_t paramStart = mainPos + 6;
        std::size_t depth = 1;
        paramEnd = paramStart;
        while (paramEnd < msl.size() && depth > 0) {
            const char c = msl[paramEnd];
            if (c == '(') {
                ++depth;
            } else if (c == ')') {
                --depth;
                if (depth == 0) break;
            }
            ++paramEnd;
        }
        if (depth != 0 || paramEnd >= msl.size()) {
            return false;
        }
        std::size_t afterParams = paramEnd + 1;
        while (afterParams < msl.size() &&
               std::isspace(static_cast<unsigned char>(msl[afterParams]))) {
            ++afterParams;
        }
        if (afterParams < msl.size() && msl[afterParams] == '{') {
            return true;
        }
        searchPos = paramStart;
    }
}

bool adjustVertexInstanceIDForMetalBaseInstance(std::string& msl) {
    static constexpr const char* kInstanceAttr = "[[instance_id]]";
    static constexpr const char* kBaseInstanceAttr = "[[base_instance]]";
    std::size_t paramEnd = 0;
    if (!findMain0ParameterEnd(msl, paramEnd)) {
        return false;
    }
    const std::size_t mainPos = msl.rfind("main0(", paramEnd);
    if (mainPos == std::string::npos) {
        return false;
    }
    const std::size_t paramStart = mainPos + std::strlen("main0(");
    const std::size_t instanceAttr = msl.find(kInstanceAttr, paramStart);
    if (instanceAttr == std::string::npos || instanceAttr > paramEnd) {
        return false;
    }
    const std::size_t existingBaseAttr =
        msl.find(kBaseInstanceAttr, paramStart);
    if (existingBaseAttr != std::string::npos && existingBaseAttr < paramEnd) {
        return false;
    }

    std::size_t nameEnd = instanceAttr;
    while (nameEnd > paramStart &&
           std::isspace(static_cast<unsigned char>(msl[nameEnd - 1]))) {
        --nameEnd;
    }
    std::size_t nameStart = nameEnd;
    while (nameStart > paramStart && isIdentifierChar(msl[nameStart - 1])) {
        --nameStart;
    }
    if (nameStart == nameEnd) {
        return false;
    }
    const std::string instanceName = msl.substr(nameStart, nameEnd - nameStart);

    std::size_t bodyOpen = paramEnd + 1;
    while (bodyOpen < msl.size() &&
           std::isspace(static_cast<unsigned char>(msl[bodyOpen]))) {
        ++bodyOpen;
    }
    if (bodyOpen >= msl.size() || msl[bodyOpen] != '{') {
        return false;
    }

    const std::string baseParam = ", uint appgl_BaseInstance [[base_instance]]";
    const std::string adjustment =
        "\n    " + instanceName + " -= appgl_BaseInstance;";
    std::string patched = msl;
    const std::size_t instanceAttrEnd = instanceAttr + std::strlen(kInstanceAttr);
    patched.insert(instanceAttrEnd, baseParam);
    if (instanceAttrEnd <= bodyOpen) {
        bodyOpen += baseParam.size();
    }
    patched.insert(bodyOpen + 1, adjustment);
    msl = std::move(patched);
    return true;
}

std::unordered_set<std::string> collectTextureBufferResourceNames(
    spirv_cross::Compiler& compiler,
    const spirv_cross::ShaderResources& resources) {
    std::unordered_set<std::string> names;
    auto isBufferImageType = [&](std::uint32_t typeId) {
        if (typeId == 0) {
            return false;
        }
        try {
            const auto& type = compiler.get_type(typeId);
            return type.image.dim == spv::DimBuffer;
        } catch (...) {
            return false;
        }
    };
    auto visit = [&](const auto& list) {
        for (const auto& res : list) {
            if (!isBufferImageType(res.type_id) &&
                !isBufferImageType(res.base_type_id)) {
                continue;
            }
            if (!res.name.empty()) {
                names.insert(res.name);
            }
            const std::string compilerName = compiler.get_name(res.id);
            if (!compilerName.empty()) {
                names.insert(compilerName);
            }
        }
    };
    visit(resources.sampled_images);
    visit(resources.separate_images);
    visit(resources.storage_images);
    return names;
}

bool injectTextureBufferSizeSidecar(
    std::string& msl,
    const std::unordered_set<std::string>& textureBufferNames,
    std::uint32_t bufferSlot) {
    static constexpr const char* kSidecarName = "_appgl_TextureBufferSizes";
    const std::string bufferAttribute =
        "[[buffer(" + std::to_string(bufferSlot) + ")]]";
    if (textureBufferNames.empty() ||
        msl.find(kSidecarName) != std::string::npos ||
        msl.find(bufferAttribute) != std::string::npos) {
        return false;
    }
    std::size_t paramEnd = 0;
    if (!findMain0ParameterEnd(msl, paramEnd)) {
        return false;
    }

    std::vector<std::pair<std::string, std::string>> replacements;
    for (const std::string& name : textureBufferNames) {
        if (name.empty()) {
            continue;
        }
        const std::string textureMarker = name + " [[texture(";
        std::size_t markerPos = msl.find(textureMarker);
        if (markerPos == std::string::npos) {
            continue;
        }
        std::size_t slotPos = markerPos + textureMarker.size();
        std::uint32_t slot = 0;
        bool haveDigit = false;
        while (slotPos < msl.size() &&
               std::isdigit(static_cast<unsigned char>(msl[slotPos]))) {
            haveDigit = true;
            slot = slot * 10u + static_cast<std::uint32_t>(msl[slotPos] - '0');
            ++slotPos;
        }
        if (!haveDigit) {
            continue;
        }

        const std::string textureSizeExpr =
            name + ".get_width() * " + name + ".get_height()";
        const std::string sidecarExpr =
            std::string(kSidecarName) + "[" + std::to_string(slot) + "]";
        if (msl.find(textureSizeExpr) != std::string::npos) {
            replacements.emplace_back(textureSizeExpr, sidecarExpr);
        }
    }

    if (replacements.empty()) {
        return false;
    }
    const std::string param =
        ", constant uint* " + std::string(kSidecarName) + " [[buffer(" +
        std::to_string(bufferSlot) + ")]]";
    msl.insert(paramEnd, param);
    for (const auto& replacement : replacements) {
        std::size_t pos = 0;
        while ((pos = msl.find(replacement.first, pos)) != std::string::npos) {
            msl.replace(pos, replacement.first.size(), replacement.second);
            pos += replacement.second.size();
        }
    }
    threadTextureReductionModesThroughHelpers(msl, kSidecarName);
    return true;
}

// Shadow-compare coordinate control. Bit 0 flips FBO-produced 2D depth
// coordinates for LOWER_LEFT rendering. Bit 1 clamps cube/cube-array
// directions to the selected face interior when seamless cube sampling is
// disabled. The cube inset is derived from the actual lookup LOD, including
// implicit, bias, and explicit-gradient forms. Returns false with the input
// untouched when a required rewrite anchor is unavailable.
bool injectDepthCompareControl(std::string& msl) {
    static constexpr const char* kControlName = "_appgl_CmpControls";
    static constexpr const char* kOneDMipName = "_appgl_Cmp1DMips";
    static constexpr const char* kHelperOneDMipName =
        "_appgl_Cmp1DMipsForHelper";
    const std::string oneDMipGlobalArgs = kOneDMipName;
    const std::string oneDMipHelperArgs = kHelperOneDMipName;
    const std::string oneDMipHelperParams =
        ", texture2d<float> " +
        std::string(kHelperOneDMipName);
    if (msl.find("sample_compare") == std::string::npos &&
        msl.find("gather_compare") == std::string::npos) {
        return false;
    }
    if (msl.find(kControlName) != std::string::npos) {
        return false;
    }

    std::size_t paramEnd = 0;
    if (!findMain0ParameterEnd(msl, paramEnd)) {
        return false;
    }
    const std::size_t mainPos = msl.find("main0(");
    const std::size_t paramStart = mainPos + 6;
    const std::string params = msl.substr(paramStart, paramEnd - paramStart);
    // Collect all depth receiver names and Metal texture slots from the
    // entry-point signature. Cube-array calls place the array index between
    // the coordinate and compare value, which matters when locating an
    // optional LOD-control argument.
    struct CompareReceiver {
        std::string name;
        unsigned slot = 0;
        bool cube = false;
        bool cubeArray = false;
        std::string helperControlExpr;
    };
    std::vector<CompareReceiver> receivers;
    struct CompareReceiverType {
        const char* needle;
        bool cube;
        bool cubeArray;
    };
    for (const CompareReceiverType receiverType : {
             CompareReceiverType{"depth2d_array<", false, false},
             CompareReceiverType{"depth2d<", false, false},
             CompareReceiverType{"depthcube_array<", true, true},
             CompareReceiverType{"depthcube<", true, false},
         }) {
        const char* typeNeedle = receiverType.needle;
        std::size_t search = 0;
        while ((search = params.find(typeNeedle, search)) != std::string::npos) {
            const std::size_t close = params.find('>', search);
            if (close == std::string::npos) break;
            std::size_t nameStart = close + 1;
            while (nameStart < params.size() &&
                   std::isspace(static_cast<unsigned char>(params[nameStart]))) {
                ++nameStart;
            }
            std::size_t nameEnd = nameStart;
            while (nameEnd < params.size() &&
                   (std::isalnum(static_cast<unsigned char>(params[nameEnd])) ||
                    params[nameEnd] == '_')) {
                ++nameEnd;
            }
            const std::size_t texAttr = params.find("[[texture(", nameEnd);
            if (nameEnd > nameStart && texAttr != std::string::npos) {
                const std::size_t slotStart = texAttr + 10;
                const unsigned slot = static_cast<unsigned>(
                    std::strtoul(params.c_str() + slotStart, nullptr, 10));
                receivers.push_back({
                    params.substr(nameStart, nameEnd - nameStart),
                    slot,
                    receiverType.cube,
                    receiverType.cubeArray,
                    {},
                });
            }
            search = nameEnd;
        }
    }
    if (receivers.empty()) {
        return false;
    }

    // Abandonment is observable: a compare shader we could not safely
    // rewrite stays UNFLIPPED (pre-fix behavior, fast) — loud stderr so
    // a silently-unflipped shader cannot masquerade as fixed.
    static std::atomic<std::uint64_t> abandonCount{0};
    const auto abandonRewrite = [&](const char* why) -> bool {
        const std::uint64_t n =
            abandonCount.fetch_add(1, std::memory_order_relaxed) + 1;
        std::fprintf(stderr,
            "[APPGL] compare-flip rewrite ABANDONED (%s) total=%llu — "
            "shader keeps unflipped compare sampling\n",
            why, static_cast<unsigned long long>(n));
        std::fflush(stderr);
        return false;
    };

    // All mutations land on a working copy so any anchor failure can
    // fall back to the untouched original.
    std::string working = msl;

    static constexpr const char* kHelperControlName =
        "_appgl_CmpControlForHelper";
    std::vector<std::string> helperNames;
    std::vector<std::string> helperReceiverNames;
    std::size_t helperScan = 0;
    while (true) {
        const std::size_t depth2dPos = working.find("depth2d", helperScan);
        const std::size_t depthCubePos = working.find("depthcube", helperScan);
        if (depth2dPos == std::string::npos &&
            depthCubePos == std::string::npos) {
            break;
        }
        const bool cube = depth2dPos == std::string::npos ||
            (depthCubePos != std::string::npos && depthCubePos < depth2dPos);
        helperScan = cube ? depthCubePos : depth2dPos;
        const bool cubeArray = cube &&
            working.compare(helperScan, 16, "depthcube_array<") == 0;
        const std::size_t typeLength = cube ? 9u : 7u;
        const std::size_t open = working.rfind('(', helperScan);
        const std::size_t prevClose = working.rfind(')', helperScan);
        if (open == std::string::npos ||
            (prevClose != std::string::npos && prevClose > open)) {
            helperScan += typeLength;
            continue;
        }
        std::size_t nameEnd = open;
        while (nameEnd > 0 &&
               std::isspace(static_cast<unsigned char>(working[nameEnd - 1]))) {
            --nameEnd;
        }
        std::size_t nameStart = nameEnd;
        while (nameStart > 0 &&
               (std::isalnum(static_cast<unsigned char>(working[nameStart - 1])) ||
                working[nameStart - 1] == '_')) {
            --nameStart;
        }
        const std::string helperName =
            working.substr(nameStart, nameEnd - nameStart);
        const std::size_t typeClose = working.find('>', helperScan);
        if (helperName.empty() || helperName == "main0" ||
            typeClose == std::string::npos) {
            helperScan += typeLength;
            continue;
        }
        std::size_t receiverStart = typeClose + 1;
        while (receiverStart < working.size() &&
               std::isspace(static_cast<unsigned char>(working[receiverStart]))) {
            ++receiverStart;
        }
        std::size_t receiverEnd = receiverStart;
        while (receiverEnd < working.size() &&
               (std::isalnum(static_cast<unsigned char>(working[receiverEnd])) ||
                working[receiverEnd] == '_')) {
            ++receiverEnd;
        }
        std::size_t signatureDepth = 1;
        std::size_t signatureCursor = open + 1;
        while (signatureCursor < working.size() && signatureDepth > 0) {
            if (working[signatureCursor] == '(') ++signatureDepth;
            else if (working[signatureCursor] == ')') --signatureDepth;
            ++signatureCursor;
        }
        std::size_t afterSignature = signatureCursor;
        while (afterSignature < working.size() &&
               std::isspace(static_cast<unsigned char>(working[afterSignature]))) {
            ++afterSignature;
        }
        if (signatureDepth != 0 || afterSignature >= working.size() ||
            working[afterSignature] != '{' || receiverEnd <= receiverStart) {
            helperScan += typeLength;
            continue;
        }
        const std::string receiverName =
            working.substr(receiverStart, receiverEnd - receiverStart);
        const auto helperIt =
            std::find(helperNames.begin(), helperNames.end(), helperName);
        if (helperIt != helperNames.end()) {
            const std::size_t index = static_cast<std::size_t>(
                std::distance(helperNames.begin(), helperIt));
            if (helperReceiverNames[index] != receiverName) {
                return abandonRewrite("multi-depth-receiver-helper");
            }
        } else {
            helperNames.push_back(helperName);
            helperReceiverNames.push_back(receiverName);
            receivers.push_back({
                receiverName,
                0u,
                cube,
                cubeArray,
                kHelperControlName,
            });
        }
        helperScan = receiverEnd;
    }

    struct ArgumentSpan {
        std::size_t start = 0;
        std::size_t end = 0;
    };
    const auto trimmed = [](std::string value) {
        const std::size_t begin = value.find_first_not_of(" \t\r\n");
        if (begin == std::string::npos) return std::string();
        const std::size_t end = value.find_last_not_of(" \t\r\n");
        return value.substr(begin, end - begin + 1);
    };

    // Wrap the coordinate argument (first arg after the sampler) of every
    // compare call. Cube receivers select an overload that computes the
    // face inset from the call's own LOD-control form.
    bool wrapped = false;
    bool needs1DMips = false;
    for (const auto& receiver : receivers) {
        if (receiver.helperControlExpr.empty() && receiver.slot >= 32u) continue;
        for (const char* call : {".sample_compare(", ".gather_compare("}) {
            const bool sampleCompare =
                std::strcmp(call, ".sample_compare(") == 0;
            const std::string needle = receiver.name + call;
            std::size_t pos = 0;
            while ((pos = working.find(needle, pos)) != std::string::npos) {
                const std::size_t argsStart = pos + needle.size();
                std::size_t cursor = argsStart;
                std::size_t depth = 1;
                std::size_t argStart = argsStart;
                std::vector<ArgumentSpan> args;
                while (cursor < working.size() && depth > 0) {
                    const char c = working[cursor];
                    if (c == '(') {
                        ++depth;
                    } else if (c == ')') {
                        --depth;
                        if (depth == 0) {
                            args.push_back({argStart, cursor});
                        }
                    } else if (c == ',' && depth == 1) {
                        args.push_back({argStart, cursor});
                        argStart = cursor + 1;
                    }
                    ++cursor;
                }
                if (depth != 0 || args.size() < 2 ||
                    args[1].end <= args[1].start) {
                    pos = argsStart;
                    continue;
                }
                const std::size_t coordStart = args[1].start;
                const std::size_t coordEnd = args[1].end;
                const std::string coordExpr =
                    working.substr(coordStart, coordEnd - coordStart);
                const std::string controlExpr =
                    receiver.helperControlExpr.empty()
                        ? (std::string(kControlName) + "[" +
                           std::to_string(receiver.slot) + "]")
                        : receiver.helperControlExpr;
                const std::string normalizedCoord = trimmed(coordExpr);
                const bool promotedOneDCoord =
                    normalizedCoord.rfind("float2(", 0) == 0 &&
                    (normalizedCoord.find(", 0.5)") != std::string::npos ||
                     normalizedCoord.find(", 0.5f)") != std::string::npos);
                std::string replacement;
                if (!receiver.cube && promotedOneDCoord &&
                    args.size() >= 3u) {
                    const std::string& mipArgsExpr =
                        receiver.helperControlExpr.empty()
                            ? oneDMipGlobalArgs : oneDMipHelperArgs;
                    const std::string samplerExpr = trimmed(working.substr(
                        args[0].start, args[0].end - args[0].start));
                    const std::string compareExpr = trimmed(working.substr(
                        args[2].start, args[2].end - args[2].start));
                    std::string helper;
                    bool recognized = false;
                    if (sampleCompare) {
                        if (args.size() >= 4u) {
                            const std::string option = trimmed(working.substr(
                                args[3].start,
                                args[3].end - args[3].start));
                            if (option.rfind("level(", 0) == 0) {
                                helper = "_appgl_cmpSample1DLevel";
                                recognized = args.size() <= 5u;
                            } else if (option.rfind("gradient2d(", 0) == 0) {
                                helper = "_appgl_cmpSample1DGradient";
                                recognized = args.size() <= 5u;
                            } else if (option.rfind("bias(", 0) == 0) {
                                helper = "_appgl_cmpSample1DBias";
                            }
                        }
                    }
                    if (recognized) {
                        replacement = helper + "(" + receiver.name + ", " +
                            mipArgsExpr + ", " + samplerExpr + ", " +
                            coordExpr + ", " + compareExpr + ", " +
                            controlExpr;
                        for (std::size_t argIndex = 3u;
                             argIndex < args.size(); ++argIndex) {
                            replacement += ", " + trimmed(working.substr(
                                args[argIndex].start,
                                args[argIndex].end - args[argIndex].start));
                        }
                        replacement += ")";
                        working.replace(pos, cursor - pos, replacement);
                        wrapped = true;
                        needs1DMips = true;
                        pos += replacement.size();
                        continue;
                    }
                }
                if (!receiver.cube) {
                    replacement =
                        " _appgl_cmpFlip2DCoord(" + coordExpr + ", " +
                        controlExpr + ".flags)";
                } else {
                    std::string helper =
                        "_appgl_cmpClampCubeImplicitCoord";
                    std::string option;
                    const std::size_t optionIndex = receiver.cubeArray ? 4u : 3u;
                    if (sampleCompare && args.size() > optionIndex) {
                        option = trimmed(working.substr(
                            args[optionIndex].start,
                            args[optionIndex].end - args[optionIndex].start));
                        if (option.rfind("bias(", 0) == 0) {
                            helper = "_appgl_cmpClampCubeBiasCoord";
                        } else if (option.rfind("gradientcube(", 0) == 0) {
                            helper = "_appgl_cmpClampCubeGradientCoord";
                        } else if (option.rfind("level(", 0) == 0) {
                            helper = "_appgl_cmpClampCubeLevelCoord";
                        } else {
                            option.clear();
                        }
                    }
                    replacement = " " + helper + "(" + receiver.name +
                        ", " + coordExpr;
                    if (!option.empty()) {
                        replacement += ", " + option;
                    }
                    replacement += ", " + controlExpr + ")";
                }
                working.replace(coordStart, coordEnd - coordStart, replacement);
                wrapped = true;
                pos = coordStart + replacement.size();
            }
        }
    }
    if (!wrapped) {
        return false;
    }

    // Inject the compare-control parameter into main0(...). Slot selection
    // follows the _appgl_ClipControlYSign preferred-slot pattern: take
    // the first fragment-stage buffer index not already present in the
    // generated MSL; the frame graph reads the actual slot back from
    // the "[[buffer(N)]]" needle (depthCompareControlBufferSlot).
    // GLSL helper functions that perform the lookup are emitted by
    // SPIRV-Cross as standalone MSL functions with the texture/sampler
    // threaded through their parameter lists (the Warzone
    // shadow_mapping.glsl shape). The control buffer must be
    // threaded the same way or the wrapped call sites inside helpers
    // reference an out-of-scope identifier — which fails compilation,
    // and an uncached compile failure re-runs per draw (the e2a876d
    // live regression). Mirror SPIRV-Cross: every non-main0 function
    // whose parameter list contains a depth receiver gets one control
    // reference. Calls from main0 select the entry for their actual texture
    // argument; nested helpers forward their own reference.
    {
        for (std::size_t helperIndex = 0;
             helperIndex < helperNames.size(); ++helperIndex) {
            const std::string& name = helperNames[helperIndex];
            const std::string needle = name + "(";
            std::size_t pos = 0;
            while ((pos = working.find(needle, pos)) != std::string::npos) {
                // Reject partial identifier matches (e.g. xNAME().
                if (pos > 0 &&
                    (std::isalnum(static_cast<unsigned char>(working[pos - 1])) ||
                     working[pos - 1] == '_')) {
                    pos += needle.size();
                    continue;
                }
                std::size_t depth = 1;
                std::size_t cursor = pos + needle.size();
                while (cursor < working.size() && depth > 0) {
                    if (working[cursor] == '(') ++depth;
                    else if (working[cursor] == ')') --depth;
                    ++cursor;
                }
                if (depth != 0) {
                    return abandonRewrite("call-paren-imbalance");
                }
                const std::size_t closeParen = cursor - 1;
                std::size_t after = cursor;
                while (after < working.size() &&
                       std::isspace(static_cast<unsigned char>(working[after]))) {
                    ++after;
                }
                const bool isDefinition =
                    after < working.size() && working[after] == '{';
                std::string insertion;
                if (isDefinition) {
                    if (needs1DMips) {
                        insertion = oneDMipHelperParams;
                    }
                    insertion += ", constant _appgl_CmpControl& " +
                        std::string(kHelperControlName);
                } else {
                    const std::string callArgs = working.substr(
                        pos + needle.size(),
                        closeParen - (pos + needle.size()));
                    std::string controlArg;
                    std::string mipArrayArg;
                    for (const auto& receiver : receivers) {
                        std::size_t argPos = 0;
                        while ((argPos = callArgs.find(receiver.name, argPos)) !=
                               std::string::npos) {
                            const bool leftBoundary = argPos == 0 ||
                                (!std::isalnum(static_cast<unsigned char>(
                                     callArgs[argPos - 1])) &&
                                 callArgs[argPos - 1] != '_');
                            const std::size_t argEnd =
                                argPos + receiver.name.size();
                            const bool rightBoundary = argEnd == callArgs.size() ||
                                (!std::isalnum(static_cast<unsigned char>(
                                     callArgs[argEnd])) &&
                                 callArgs[argEnd] != '_');
                            if (leftBoundary && rightBoundary) {
                                if (receiver.helperControlExpr.empty()) {
                                    controlArg = std::string(kControlName) +
                                        "[" + std::to_string(receiver.slot) +
                                        "]";
                                    mipArrayArg = oneDMipGlobalArgs;
                                } else {
                                    controlArg = kHelperControlName;
                                    mipArrayArg = oneDMipHelperArgs;
                                }
                                break;
                            }
                            argPos = argEnd;
                        }
                        if (!controlArg.empty()) break;
                    }
                    if (controlArg.empty()) {
                        return abandonRewrite("helper-control-argument");
                    }
                    if (needs1DMips) {
                        insertion = ", " + mipArrayArg;
                    }
                    insertion += ", " + controlArg;
                }
                working.insert(closeParen, insertion);
                pos = closeParen + insertion.size() + 1;
            }
        }
    }

    if (!findMain0ParameterEnd(working, paramEnd)) {
        return abandonRewrite("main0-signature");
    }
    std::uint32_t chosenControlSlot = 0;
    std::uint32_t chosenMipSlot = 0;
    bool haveControlSlot = false;
    for (const std::uint32_t candidate : {29u, 28u, 27u, 26u, 20u, 19u, 18u, 17u}) {
        const std::string attr = "[[buffer(" + std::to_string(candidate) + ")]]";
        if (working.find(attr) == std::string::npos) {
            chosenControlSlot = candidate;
            haveControlSlot = true;
            break;
        }
    }
    bool haveMipSlot = !needs1DMips;
    if (needs1DMips) {
        for (const std::uint32_t candidate :
             {2u, 3u, 4u, 5u, 6u, 7u, 8u, 9u, 10u, 11u, 12u, 13u,
              14u, 15u, 16u, 17u, 18u, 19u, 20u, 21u, 22u, 23u,
              24u, 25u, 26u, 27u, 28u, 29u, 30u}) {
            const std::string attr =
                "[[texture(" + std::to_string(candidate) + ")]]";
            if (working.find(attr) == std::string::npos) {
                chosenMipSlot = candidate;
                haveMipSlot = true;
                break;
            }
        }
    }
    if (!haveControlSlot || !haveMipSlot) {
        return abandonRewrite("no-free-buffer-slot");
    }
    std::string param;
    if (needs1DMips) {
        param = ", texture2d<float> " +
            std::string(kOneDMipName) + " [[texture(" +
            std::to_string(chosenMipSlot) + ")]]";
    }
    param += ", constant _appgl_CmpControl* " +
        std::string(kControlName) + " [[buffer(" +
        std::to_string(chosenControlSlot) + ")]]";
    working.insert(paramEnd, param);

    // Inject the coordinate helper ABOVE every function that may call
    // it — immediately after `using namespace metal;` (helpers precede
    // the fragment entry point in SPIRV-Cross emission, so anchoring on
    // "fragment " placed it too late for helper-body call sites).
    static constexpr const char* kHelper = R"APPGL(
struct _appgl_CmpControl
{
    uint flags;
    uint mipFilter;
    float lodBias;
    float minLod;
    float maxLod;
    uint oneDSampleState;
    uint oneDMipCount;
    float borderDepth;
};

static inline float _appgl_cmp1DCompare(
    float depth, float ref, uint compareFunc)
{
    return float(compareFunc == 7u) +
           float(compareFunc == 1u) * float(ref < depth) +
           float(compareFunc == 2u) * float(ref == depth) +
           float(compareFunc == 3u) * float(ref <= depth) +
           float(compareFunc == 4u) * float(ref > depth) +
           float(compareFunc == 5u) * float(ref != depth) +
           float(compareFunc == 6u) * float(ref >= depth);
}

static inline float2 _appgl_cmpFlip2DCoord(float2 c, uint flags)
{
    return (flags & 1u) != 0u ? float2(c.x, 1.0f - c.y) : c;
}

static inline float _appgl_cmp1DRawLod(depth2d<float> tex, float2 c)
{
    float rho = max(abs(dfdx(c.x)), abs(dfdy(c.x))) *
        max(float(tex.get_width()), 1.0f);
    return log2(max(rho, 1.0e-20f));
}

static inline float _appgl_cmp1DGradientLod(depth2d<float> tex,
                                             gradient2d gradients)
{
    float rho = max(abs(gradients.dPdx.x), abs(gradients.dPdy.x)) *
        max(float(tex.get_width()), 1.0f);
    return log2(max(rho, 1.0e-20f));
}

static inline uint2 _appgl_cmp1DLevels(
    float lod, constant _appgl_CmpControl& control, thread float& blend)
{
    uint mipCount = max(control.oneDMipCount, 1u);
    float maxMip = float(mipCount - 1u);
    float minLod = clamp(control.minLod, 0.0f, maxMip);
    float maxLod = clamp(max(control.maxLod, minLod), minLod, maxMip);
    float clampedLod = control.mipFilter == 0u
        ? 0.0f : clamp(lod, minLod, maxLod);
    if (control.mipFilter == 2u) {
        float low = floor(clampedLod);
        float high = min(low + 1.0f, maxMip);
        blend = clampedLod - low;
        return uint2(uint(low), uint(high));
    }
    blend = 0.0f;
    uint level = uint(clamp(rint(clampedLod), 0.0f, maxMip));
    return uint2(level);
}

static inline uint _appgl_cmp1DMipIndex(
    uint level, constant _appgl_CmpControl& control)
{
    return level;
}

static inline float _appgl_cmp1DSampleAt(
    APPGL_CMP1D_MIP_PARAMS, uint index, sampler smp,
    float2 coord, float ref, bool linear,
    constant _appgl_CmpControl& control);

static inline float _appgl_cmp1DSampleAtOffset(
    APPGL_CMP1D_MIP_PARAMS, uint index, sampler smp,
    float2 coord, float ref, bool linear,
    constant _appgl_CmpControl& control, int2 offset);

static inline float4 _appgl_cmp1DGatherAt(
    APPGL_CMP1D_MIP_PARAMS, uint index, sampler smp,
    float2 coord, float ref, constant _appgl_CmpControl& control);

static inline float4 _appgl_cmp1DGatherAtOffset(
    APPGL_CMP1D_MIP_PARAMS, uint index, sampler smp,
    float2 coord, float ref, constant _appgl_CmpControl& control,
    int2 offset);

static inline float _appgl_cmp1DSampleLod(
    APPGL_CMP1D_MIP_PARAMS, sampler smp, float2 c, float ref,
    float lod, constant _appgl_CmpControl& control)
{
    float blend = 0.0f;
    uint2 levels = _appgl_cmp1DLevels(lod, control, blend);
    float2 coord(c.x, 0.25f);
    uint filterBit = lod <= 0.0f ? 3u : 2u;
    bool linear = ((control.oneDSampleState >> filterBit) & 1u) != 0u;
    float low = _appgl_cmp1DSampleAt(
        APPGL_CMP1D_MIP_ARGS, _appgl_cmp1DMipIndex(levels.x, control),
        smp, coord, ref, linear, control);
    if (levels.x == levels.y) return low;
    float high = _appgl_cmp1DSampleAt(
        APPGL_CMP1D_MIP_ARGS, _appgl_cmp1DMipIndex(levels.y, control),
        smp, coord, ref, linear, control);
    return mix(low, high, blend);
}

static inline float _appgl_cmp1DSampleLodOffset(
    APPGL_CMP1D_MIP_PARAMS, sampler smp, float2 c, float ref,
    float lod, constant _appgl_CmpControl& control, int2 offset)
{
    float blend = 0.0f;
    uint2 levels = _appgl_cmp1DLevels(lod, control, blend);
    float2 coord(c.x, 0.25f);
    int2 oneDOffset(offset.x, 0);
    uint filterBit = lod <= 0.0f ? 3u : 2u;
    bool linear = ((control.oneDSampleState >> filterBit) & 1u) != 0u;
    float low = _appgl_cmp1DSampleAtOffset(
        APPGL_CMP1D_MIP_ARGS, _appgl_cmp1DMipIndex(levels.x, control),
        smp, coord, ref, linear, control, oneDOffset);
    if (levels.x == levels.y) return low;
    float high = _appgl_cmp1DSampleAtOffset(
        APPGL_CMP1D_MIP_ARGS, _appgl_cmp1DMipIndex(levels.y, control),
        smp, coord, ref, linear, control, oneDOffset);
    return mix(low, high, blend);
}

static inline float _appgl_cmpSample1DImplicit(
    depth2d<float> tex, APPGL_CMP1D_MIP_PARAMS, sampler smp,
    float2 c, float ref, constant _appgl_CmpControl& control)
{
    if ((control.flags & 4u) == 0u) {
        return tex.sample_compare(
            smp, _appgl_cmpFlip2DCoord(c, control.flags), ref);
    }
    return _appgl_cmp1DSampleLod(
        APPGL_CMP1D_MIP_ARGS, smp, c, ref,
        _appgl_cmp1DRawLod(tex, c) + control.lodBias, control);
}

static inline float _appgl_cmpSample1DImplicitOffset(
    depth2d<float> tex, APPGL_CMP1D_MIP_PARAMS, sampler smp,
    float2 c, float ref, constant _appgl_CmpControl& control, int2 offset)
{
    if ((control.flags & 4u) == 0u) {
        return tex.sample_compare(
            smp, _appgl_cmpFlip2DCoord(c, control.flags), ref, offset);
    }
    return _appgl_cmp1DSampleLodOffset(
        APPGL_CMP1D_MIP_ARGS, smp, c, ref,
        _appgl_cmp1DRawLod(tex, c) + control.lodBias, control, offset);
}

static inline float _appgl_cmpSample1DLevel(
    depth2d<float> tex, APPGL_CMP1D_MIP_PARAMS, sampler smp,
    float2 c, float ref, constant _appgl_CmpControl& control, level options)
{
    if ((control.flags & 4u) == 0u) {
        return tex.sample_compare(
            smp, _appgl_cmpFlip2DCoord(c, control.flags), ref, options);
    }
    return _appgl_cmp1DSampleLod(
        APPGL_CMP1D_MIP_ARGS, smp, c, ref, options.lod, control);
}

static inline float _appgl_cmpSample1DLevel(
    depth2d<float> tex, APPGL_CMP1D_MIP_PARAMS, sampler smp,
    float2 c, float ref, constant _appgl_CmpControl& control, level options,
    int2 offset)
{
    if ((control.flags & 4u) == 0u) {
        return tex.sample_compare(
            smp, _appgl_cmpFlip2DCoord(c, control.flags), ref,
            options, offset);
    }
    return _appgl_cmp1DSampleLodOffset(
        APPGL_CMP1D_MIP_ARGS, smp, c, ref, options.lod, control, offset);
}

static inline float _appgl_cmpSample1DGradient(
    depth2d<float> tex, APPGL_CMP1D_MIP_PARAMS, sampler smp,
    float2 c, float ref, constant _appgl_CmpControl& control,
    gradient2d gradients)
{
    if ((control.flags & 4u) == 0u) {
        return tex.sample_compare(
            smp, _appgl_cmpFlip2DCoord(c, control.flags), ref, gradients);
    }
    return _appgl_cmp1DSampleLod(
        APPGL_CMP1D_MIP_ARGS, smp, c, ref,
        _appgl_cmp1DGradientLod(tex, gradients) + control.lodBias, control);
}

static inline float _appgl_cmpSample1DGradient(
    depth2d<float> tex, APPGL_CMP1D_MIP_PARAMS, sampler smp,
    float2 c, float ref, constant _appgl_CmpControl& control,
    gradient2d gradients, int2 offset)
{
    if ((control.flags & 4u) == 0u) {
        return tex.sample_compare(
            smp, _appgl_cmpFlip2DCoord(c, control.flags), ref,
            gradients, offset);
    }
    return _appgl_cmp1DSampleLodOffset(
        APPGL_CMP1D_MIP_ARGS, smp, c, ref,
        _appgl_cmp1DGradientLod(tex, gradients) + control.lodBias,
        control, offset);
}

static inline float _appgl_cmpSample1DBias(
    depth2d<float> tex, APPGL_CMP1D_MIP_PARAMS, sampler smp,
    float2 c, float ref, constant _appgl_CmpControl& control, bias options)
{
    if ((control.flags & 4u) == 0u) {
        return tex.sample_compare(
            smp, _appgl_cmpFlip2DCoord(c, control.flags), ref, options);
    }
    return _appgl_cmp1DSampleLod(
        APPGL_CMP1D_MIP_ARGS, smp, c, ref,
        _appgl_cmp1DRawLod(tex, c) + control.lodBias + options.value,
        control);
}

static inline float _appgl_cmpSample1DBias(
    depth2d<float> tex, APPGL_CMP1D_MIP_PARAMS, sampler smp,
    float2 c, float ref, constant _appgl_CmpControl& control, bias options,
    int2 offset)
{
    if ((control.flags & 4u) == 0u) {
        return tex.sample_compare(
            smp, _appgl_cmpFlip2DCoord(c, control.flags), ref,
            options, offset);
    }
    return _appgl_cmp1DSampleLodOffset(
        APPGL_CMP1D_MIP_ARGS, smp, c, ref,
        _appgl_cmp1DRawLod(tex, c) + control.lodBias + options.value,
        control, offset);
}

static inline float4 _appgl_cmpGather1D(
    depth2d<float> tex, APPGL_CMP1D_MIP_PARAMS, sampler smp,
    float2 c, float ref, constant _appgl_CmpControl& control)
{
    if ((control.flags & 4u) == 0u) {
        return tex.gather_compare(
            smp, _appgl_cmpFlip2DCoord(c, control.flags), ref);
    }
    return _appgl_cmp1DGatherAt(
        APPGL_CMP1D_MIP_ARGS, _appgl_cmp1DMipIndex(0u, control), smp,
        float2(c.x, 0.25f), ref, control);
}

static inline float4 _appgl_cmpGather1DOffset(
    depth2d<float> tex, APPGL_CMP1D_MIP_PARAMS, sampler smp,
    float2 c, float ref, constant _appgl_CmpControl& control, int2 offset)
{
    if ((control.flags & 4u) == 0u) {
        return tex.gather_compare(
            smp, _appgl_cmpFlip2DCoord(c, control.flags), ref, offset);
    }
    return _appgl_cmp1DGatherAtOffset(
        APPGL_CMP1D_MIP_ARGS, _appgl_cmp1DMipIndex(0u, control), smp,
        float2(c.x, 0.25f), ref, control, int2(offset.x, 0));
}

static inline float _appgl_cmpCubeRawLod(float3 c, gradientcube gradients,
                                         float width)
{
    float3 a = abs(c);
    float majorCoord;
    float2 minor;
    float2 dMinorDx;
    float2 dMinorDy;
    float dMajorDx;
    float dMajorDy;
    if (a.x >= a.y && a.x >= a.z) {
        majorCoord = c.x;
        minor = c.yz;
        dMinorDx = gradients.dPdx.yz;
        dMinorDy = gradients.dPdy.yz;
        dMajorDx = sign(majorCoord) * gradients.dPdx.x;
        dMajorDy = sign(majorCoord) * gradients.dPdy.x;
    } else if (a.y >= a.z) {
        majorCoord = c.y;
        minor = c.xz;
        dMinorDx = gradients.dPdx.xz;
        dMinorDy = gradients.dPdy.xz;
        dMajorDx = sign(majorCoord) * gradients.dPdx.y;
        dMajorDy = sign(majorCoord) * gradients.dPdy.y;
    } else {
        majorCoord = c.z;
        minor = c.xy;
        dMinorDx = gradients.dPdx.xy;
        dMinorDy = gradients.dPdy.xy;
        dMajorDx = sign(majorCoord) * gradients.dPdx.z;
        dMajorDy = sign(majorCoord) * gradients.dPdy.z;
    }
    float major = max(abs(majorCoord), 1.0e-20f);
    float denominator = major * major;
    float2 projectedDx =
        0.5f * (dMinorDx * major - minor * dMajorDx) / denominator;
    float2 projectedDy =
        0.5f * (dMinorDy * major - minor * dMajorDy) / denominator;
    float rho = max(length(projectedDx), length(projectedDy)) *
        max(width, 1.0f);
    return log2(max(rho, 1.0e-20f));
}

template<typename T>
static inline uint _appgl_cmpCubeLevel(T tex, float lod,
                                       constant _appgl_CmpControl& control)
{
    uint mipCount = max(tex.get_num_mip_levels(), 1u);
    float maxMip = float(mipCount - 1u);
    float minLod = clamp(control.minLod, 0.0f, maxMip);
    float maxLod = clamp(max(control.maxLod, minLod), minLod, maxMip);
    float clampedLod = clamp(lod, minLod, maxLod);
    float selectedLod = control.mipFilter == 2u
        ? ceil(clampedLod) : rint(clampedLod);
    return uint(clamp(selectedLod, 0.0f, maxMip));
}

static inline float3 _appgl_cmpClampCubeCoord(float3 c, float width,
                                              uint flags)
{
    if ((flags & 2u) == 0u) return c;
    float3 a = abs(c);
    float major = max(a.x, max(a.y, a.z));
    float edge = major * max(0.0f, 1.0f - 1.0f / max(width, 1.0f));
    float3 clamped = clamp(c, float3(-edge), float3(edge));
    if (a.x >= a.y && a.x >= a.z) clamped.x = c.x;
    else if (a.y >= a.z) clamped.y = c.y;
    else clamped.z = c.z;
    return clamped;
}

template<typename T>
static inline float3 _appgl_cmpClampCubeImplicitCoord(
    T tex, float3 c, constant _appgl_CmpControl& control)
{
    if ((control.flags & 2u) == 0u) return c;
    gradientcube gradients(dfdx(c), dfdy(c));
    float lod = _appgl_cmpCubeRawLod(
        c, gradients, float(tex.get_width())) + control.lodBias;
    uint level = _appgl_cmpCubeLevel(tex, lod, control);
    return _appgl_cmpClampCubeCoord(
        c, float(tex.get_width(level)), control.flags);
}

template<typename T>
static inline float3 _appgl_cmpClampCubeBiasCoord(
    T tex, float3 c, bias options,
    constant _appgl_CmpControl& control)
{
    if ((control.flags & 2u) == 0u) return c;
    gradientcube gradients(dfdx(c), dfdy(c));
    float lod = _appgl_cmpCubeRawLod(
        c, gradients, float(tex.get_width())) +
        control.lodBias + options.value;
    uint level = _appgl_cmpCubeLevel(tex, lod, control);
    return _appgl_cmpClampCubeCoord(
        c, float(tex.get_width(level)), control.flags);
}

template<typename T>
static inline float3 _appgl_cmpClampCubeGradientCoord(
    T tex, float3 c, gradientcube gradients,
    constant _appgl_CmpControl& control)
{
    if ((control.flags & 2u) == 0u) return c;
    float lod = _appgl_cmpCubeRawLod(
        c, gradients, float(tex.get_width())) + control.lodBias;
    uint level = _appgl_cmpCubeLevel(tex, lod, control);
    return _appgl_cmpClampCubeCoord(
        c, float(tex.get_width(level)), control.flags);
}

template<typename T>
static inline float3 _appgl_cmpClampCubeLevelCoord(
    T tex, float3 c, level options,
    constant _appgl_CmpControl& control)
{
    if ((control.flags & 2u) == 0u) return c;
    uint selectedLevel = _appgl_cmpCubeLevel(tex, options.lod, control);
    return _appgl_cmpClampCubeCoord(
        c, float(tex.get_width(selectedLevel)), control.flags);
}
)APPGL";
    std::string helperSource = std::string(
        "#define APPGL_CMP1D_MIP_PARAMS "
        "texture2d<float> _appgl_cmpMips\n"
        "#define APPGL_CMP1D_MIP_ARGS _appgl_cmpMips\n") +
        kHelper;
    helperSource += R"APPGL(
static inline int _appgl_cmp1DWrapIndex(
    int x, int width, uint state, thread bool& border)
{
    uint wrap = state & 3u;
    border = false;
    if (wrap == 0u) {
        int wrapped = x % width;
        return wrapped < 0 ? wrapped + width : wrapped;
    }
    if (wrap == 1u) {
        int period = width * 2;
        int mirrored = x % period;
        if (mirrored < 0) mirrored += period;
        return mirrored < width ? mirrored : period - mirrored - 1;
    }
    if (wrap == 3u) {
        border = x < 0 || x >= width;
    }
    return clamp(x, 0, width - 1);
}

static inline float _appgl_cmp1DTap(
    APPGL_CMP1D_MIP_PARAMS, uint index, int x, float ref,
    constant _appgl_CmpControl& control)
{
    int logicalWidth = int(max(_appgl_cmpMips.get_width() >> index, 1u));
    bool border = false;
    int wrapped = _appgl_cmp1DWrapIndex(
        x, logicalWidth, control.oneDSampleState, border);
    float depth = border
        ? control.borderDepth
        : _appgl_cmpMips.read(uint2(uint(wrapped), index * 2u)).x;
    return _appgl_cmp1DCompare(
        depth, ref, (control.flags >> 8u) & 7u);
}

static inline float _appgl_cmp1DSampleAtOffset(
    APPGL_CMP1D_MIP_PARAMS, uint index, sampler smp,
    float2 coord, float ref, bool linear,
    constant _appgl_CmpControl& control, int2 offset)
{
    float logicalWidth = float(max(
        _appgl_cmpMips.get_width() >> index, 1u));
    if (!linear) {
        int x = int(floor(coord.x * logicalWidth)) + offset.x;
        return _appgl_cmp1DTap(
            APPGL_CMP1D_MIP_ARGS, index, x, ref, control);
    }
    float footprint = coord.x * logicalWidth - 0.5f;
    int lowX = int(floor(footprint)) + offset.x;
    float blend = fract(footprint);
    float low = _appgl_cmp1DTap(
        APPGL_CMP1D_MIP_ARGS, index, lowX, ref, control);
    float high = _appgl_cmp1DTap(
        APPGL_CMP1D_MIP_ARGS, index, lowX + 1, ref, control);
    return mix(low, high, blend);
}

static inline float _appgl_cmp1DSampleAt(
    APPGL_CMP1D_MIP_PARAMS, uint index, sampler smp,
    float2 coord, float ref, bool linear,
    constant _appgl_CmpControl& control)
{
    return _appgl_cmp1DSampleAtOffset(
        APPGL_CMP1D_MIP_ARGS, index, smp, coord, ref, linear,
        control, int2(0));
}

static inline float4 _appgl_cmp1DGatherAt(
    APPGL_CMP1D_MIP_PARAMS, uint index, sampler smp,
    float2 coord, float ref, constant _appgl_CmpControl& control)
{
    float value = _appgl_cmp1DSampleAt(
        APPGL_CMP1D_MIP_ARGS, index, smp, coord, ref, false,
        control);
    return float4(value);
}

static inline float4 _appgl_cmp1DGatherAtOffset(
    APPGL_CMP1D_MIP_PARAMS, uint index, sampler smp,
    float2 coord, float ref, constant _appgl_CmpControl& control,
    int2 offset)
{
    float value = _appgl_cmp1DSampleAtOffset(
        APPGL_CMP1D_MIP_ARGS, index, smp, coord, ref, false,
        control, offset);
    return float4(value);
}
#undef APPGL_CMP1D_MIP_ARGS
#undef APPGL_CMP1D_MIP_PARAMS
)APPGL";
    static constexpr const char* kUsingAnchor = "using namespace metal;\n";
    const std::size_t usingPos = working.find(kUsingAnchor);
    if (usingPos != std::string::npos) {
        working.insert(usingPos + std::strlen(kUsingAnchor), helperSource);
    } else {
        const std::size_t entryPos = working.find("fragment ");
        if (entryPos == std::string::npos) {
            return abandonRewrite("no-entry-anchor");
        }
        working.insert(entryPos, helperSource);
    }
    msl = std::move(working);
    return true;
}

bool injectPrimitiveFragmentShadingRateCombiner(std::string& msl) {
    static constexpr const char* kPrimitiveRateAttr = "[[primitive_shading_rate]]";
    static constexpr const char* kStateName = "_appgl_FSRState";
    static constexpr const char* kCombineFunction = "appgl_fsr_combine_vertex_rate";
    if (msl.find(kPrimitiveRateAttr) == std::string::npos ||
        msl.find(kStateName) != std::string::npos) {
        return false;
    }

    const std::string bufferAttr =
        "[[buffer(" + std::to_string(kFragmentShadingRateParamsBufferSlot) + ")]]";
    if (msl.find(bufferAttr) != std::string::npos) {
        return false;
    }

    std::size_t paramEnd = 0;
    if (!findMain0ParameterEnd(msl, paramEnd)) {
        return false;
    }

    bool wrappedAssignment = false;
    static constexpr const char* kAssignNeedle = ".spv_ShadingRateEXT =";
    std::size_t pos = 0;
    while ((pos = msl.find(kAssignNeedle, pos)) != std::string::npos) {
        const std::size_t rhsStart = pos + std::strlen(kAssignNeedle);
        const std::size_t semi = msl.find(';', rhsStart);
        if (semi == std::string::npos) {
            break;
        }

        std::string rhs = msl.substr(rhsStart, semi - rhsStart);
        if (rhs.find(kCombineFunction) != std::string::npos) {
            pos = semi + 1;
            continue;
        }
        const std::size_t exprBegin = rhs.find_first_not_of(" \t\r\n");
        const std::size_t exprEnd = rhs.find_last_not_of(" \t\r\n");
        if (exprBegin == std::string::npos || exprEnd == std::string::npos) {
            pos = semi + 1;
            continue;
        }

        const std::string expr = rhs.substr(exprBegin, exprEnd - exprBegin + 1);
        const std::string replacement =
            " " + std::string(kCombineFunction) + "((" + expr + "), " + kStateName + ")";
        msl.replace(rhsStart, semi - rhsStart, replacement);
        pos = rhsStart + replacement.size();
        wrappedAssignment = true;
    }

    if (!wrappedAssignment) {
        return false;
    }

    if (!findMain0ParameterEnd(msl, paramEnd)) {
        return false;
    }
    const std::string param =
        ", constant AppGLFragmentShadingRateState& " + std::string(kStateName) +
        " [[buffer(" + std::to_string(kFragmentShadingRateParamsBufferSlot) + ")]]";
    msl.insert(paramEnd, param);

    const std::string support = R"MSL(
struct AppGLFragmentShadingRateState {
    uint apiRate;
    uint attachmentRate;
    uint combinerOp0;
    uint combinerOp1;
};

inline uint appgl_fsr_width(uint rate) {
    return 1u << ((rate >> 2u) & 3u);
}

inline uint appgl_fsr_height(uint rate) {
    return 1u << (rate & 3u);
}

inline uint appgl_fsr_pack(uint width, uint height) {
    const uint x = width >= 4u ? 2u : (width >= 2u ? 1u : 0u);
    const uint y = height >= 4u ? 2u : (height >= 2u ? 1u : 0u);
    return (x << 2u) | y;
}

inline uint appgl_fsr_combine(uint first, uint second, uint op) {
    if (op == 0u) return first;
    if (op == 1u) return second;
    const uint fw = appgl_fsr_width(first);
    const uint fh = appgl_fsr_height(first);
    const uint sw = appgl_fsr_width(second);
    const uint sh = appgl_fsr_height(second);
    if (op == 2u) return appgl_fsr_pack(fw < sw ? fw : sw, fh < sh ? fh : sh);
    if (op == 3u) return appgl_fsr_pack(fw > sw ? fw : sw, fh > sh ? fh : sh);
    if (op == 4u) return appgl_fsr_pack(fw * sw, fh * sh);
    return first;
}

inline uint appgl_fsr_combine_vertex_rate(uint primitiveRate,
                                          constant AppGLFragmentShadingRateState& state) {
    const uint primitiveCombined =
        appgl_fsr_combine(state.apiRate, primitiveRate, state.combinerOp0);
    return appgl_fsr_combine(primitiveCombined, state.attachmentRate, state.combinerOp1);
}

)MSL";
    const std::string usingNeedle = "using namespace metal;\n";
    const std::size_t usingPos = msl.find(usingNeedle);
    const std::size_t insertPos =
        usingPos == std::string::npos ? 0 : usingPos + usingNeedle.size();
    msl.insert(insertPos, support);
    return true;
}

std::vector<std::string> findUnsafeArrayNamesForElementType(const std::string& msl,
                                                            const char* elementType) {
    const std::string kDeclPrefix =
        std::string("spvUnsafeArray<") + elementType + ",";
    std::vector<std::string> names;

    std::size_t scan = 0;
    while ((scan = msl.find(kDeclPrefix, scan)) != std::string::npos) {
        const std::size_t close = msl.find('>', scan + kDeclPrefix.size());
        if (close == std::string::npos) {
            break;
        }
        std::size_t nameStart = close + 1;
        while (nameStart < msl.size() &&
               std::isspace(static_cast<unsigned char>(msl[nameStart]))) {
            ++nameStart;
        }
        if (nameStart >= msl.size() ||
            !isIdentifierChar(msl[nameStart]) ||
            std::isdigit(static_cast<unsigned char>(msl[nameStart]))) {
            scan = close + 1;
            continue;
        }
        std::size_t nameEnd = nameStart + 1;
        while (nameEnd < msl.size() && isIdentifierChar(msl[nameEnd])) {
            ++nameEnd;
        }
        names.emplace_back(msl.substr(nameStart, nameEnd - nameStart));
        scan = nameEnd;
    }
    return names;
}

bool eraseLiteralZeroComponentIndex(std::string& msl, std::size_t pos) {
    const std::size_t prefixEnd = msl.find('[', pos);
    if (prefixEnd == std::string::npos) {
        return false;
    }
    std::size_t indexEnd = prefixEnd + 1;
    while (indexEnd < msl.size() &&
           std::isdigit(static_cast<unsigned char>(msl[indexEnd]))) {
        ++indexEnd;
    }
    if (indexEnd == prefixEnd + 1 ||
        indexEnd + 3 >= msl.size() ||
        msl[indexEnd] != ']' ||
        msl[indexEnd + 1] != '[' ||
        msl[indexEnd + 2] != '0' ||
        msl[indexEnd + 3] != ']') {
        return false;
    }
    msl.erase(indexEnd + 1, 3);
    return true;
}

std::unordered_map<std::string, std::string> collectUserFieldTypes(const std::string& msl) {
    std::unordered_map<std::string, std::string> fields;
    std::size_t attr = 0;
    while ((attr = msl.find("[[user(", attr)) != std::string::npos) {
        const std::size_t lineStart = msl.rfind('\n', attr);
        std::size_t cursor = (lineStart == std::string::npos) ? 0 : lineStart + 1;
        while (cursor < attr && std::isspace(static_cast<unsigned char>(msl[cursor]))) {
            ++cursor;
        }
        const std::size_t typeStart = cursor;
        while (cursor < attr && isIdentifierChar(msl[cursor])) {
            ++cursor;
        }
        const std::string type = msl.substr(typeStart, cursor - typeStart);
        while (cursor < attr && std::isspace(static_cast<unsigned char>(msl[cursor]))) {
            ++cursor;
        }
        const std::size_t nameStart = cursor;
        while (cursor < attr && isIdentifierChar(msl[cursor])) {
            ++cursor;
        }
        if (nameStart != cursor &&
            (type == "float2" || type == "float3" || type == "float4")) {
            fields.emplace(msl.substr(nameStart, cursor - nameStart), type);
        }
        attr += 8;
    }
    return fields;
}

bool lhsAssignsUserFieldOfType(const std::string& msl,
                               std::size_t lineStart,
                               std::size_t rhsStart,
                               const std::string& elementType,
                               const std::unordered_map<std::string, std::string>& userFields) {
    const std::size_t eq = msl.rfind('=', rhsStart);
    if (eq == std::string::npos || eq < lineStart) {
        return false;
    }
    for (std::size_t cursor = eq + 1; cursor < rhsStart; ++cursor) {
        if (!std::isspace(static_cast<unsigned char>(msl[cursor]))) {
            return false;
        }
    }
    std::size_t end = eq;
    while (end > lineStart && std::isspace(static_cast<unsigned char>(msl[end - 1]))) {
        --end;
    }
    std::size_t fieldStart = end;
    while (fieldStart > lineStart && isIdentifierChar(msl[fieldStart - 1])) {
        --fieldStart;
    }
    if (fieldStart == end || fieldStart == lineStart || msl[fieldStart - 1] != '.') {
        return false;
    }
    const auto found = userFields.find(msl.substr(fieldStart, end - fieldStart));
    return found != userFields.end() && found->second == elementType;
}

bool fixUnsafeArrayDoubleIndex(std::string& msl) {
    // SPIRV-Cross can emit helper arrays as `array[i][0]` even when the
    // helper element is already the value being assigned. For scalar
    // floats this is always invalid; for vector varyings, keep the repair
    // scoped to assignments into same-typed user stage fields so legitimate
    // vector component reads are left intact.
    std::vector<std::string> scalarNames = findUnsafeArrayNamesForElementType(msl, "float");

    bool changed = false;
    for (const std::string& name : scalarNames) {
        const std::string prefix = name + "[";
        std::size_t pos = 0;
        while ((pos = msl.find(prefix, pos)) != std::string::npos) {
            if (pos > 0 && isIdentifierChar(msl[pos - 1])) {
                pos += prefix.size();
                continue;
            }
            if (!eraseLiteralZeroComponentIndex(msl, pos)) {
                pos += prefix.size();
                continue;
            }
            pos += prefix.size();
            changed = true;
        }
    }

    const auto userFields = collectUserFieldTypes(msl);
    for (const char* elementType : {"float2", "float3", "float4"}) {
        for (const std::string& name : findUnsafeArrayNamesForElementType(msl, elementType)) {
            const std::string prefix = name + "[";
            std::size_t pos = 0;
            while ((pos = msl.find(prefix, pos)) != std::string::npos) {
                if (pos > 0 && isIdentifierChar(msl[pos - 1])) {
                    pos += prefix.size();
                    continue;
                }
                const std::size_t lineStart = msl.rfind('\n', pos);
                const std::size_t lineBegin = (lineStart == std::string::npos) ? 0 : lineStart + 1;
                if (!lhsAssignsUserFieldOfType(msl, lineBegin, pos, elementType, userFields) ||
                    !eraseLiteralZeroComponentIndex(msl, pos)) {
                    pos += prefix.size();
                    continue;
                }
                pos += prefix.size();
                changed = true;
            }
        }
    }
    return changed;
}

std::uint32_t chooseFreeBufferSlot(const std::string& msl,
                                   std::uint32_t preferredSlot) {
    bool used[kMaxMetalBufferSlot + 1u] = {};
    static constexpr const char* kBufferAttr = "[[buffer(";
    static constexpr std::size_t kBufferAttrLen = 9;
    std::size_t pos = 0;
    while ((pos = msl.find(kBufferAttr, pos)) != std::string::npos) {
        std::size_t cursor = pos + kBufferAttrLen;
        std::uint32_t slot = 0;
        bool haveDigit = false;
        while (cursor < msl.size() &&
               std::isdigit(static_cast<unsigned char>(msl[cursor]))) {
            haveDigit = true;
            slot = slot * 10u + static_cast<std::uint32_t>(msl[cursor] - '0');
            ++cursor;
        }
        if (haveDigit && slot <= kMaxMetalBufferSlot) {
            used[slot] = true;
        }
        pos = cursor;
    }

    if (preferredSlot <= kMaxMetalBufferSlot && !used[preferredSlot]) {
        return preferredSlot;
    }
    for (int slot = static_cast<int>(kMaxMetalBufferSlot); slot >= 0; --slot) {
        if (!used[slot]) {
            return static_cast<std::uint32_t>(slot);
        }
    }
    return preferredSlot;
}

std::string findPositionFieldName(const std::string& msl) {
    const std::size_t attr = msl.find("[[position]]");
    if (attr == std::string::npos) {
        return {};
    }
    const std::size_t lineStart = msl.rfind('\n', attr);
    std::size_t cursor = attr;
    while (cursor > (lineStart == std::string::npos ? 0 : lineStart) &&
           !isIdentifierChar(msl[cursor - 1])) {
        --cursor;
    }
    const std::size_t nameEnd = cursor;
    while (cursor > (lineStart == std::string::npos ? 0 : lineStart) &&
           isIdentifierChar(msl[cursor - 1])) {
        --cursor;
    }
    if (cursor == nameEnd) {
        return {};
    }
    return msl.substr(cursor, nameEnd - cursor);
}

bool findMain0Body(const std::string& msl,
                   std::size_t& paramEnd,
                   std::size_t& bodyOpen,
                   std::size_t& bodyClose) {
    if (!findMain0ParameterEnd(msl, paramEnd)) {
        return false;
    }
    bodyOpen = msl.find('{', paramEnd);
    if (bodyOpen == std::string::npos) {
        return false;
    }
    std::size_t depth = 1;
    bodyClose = bodyOpen + 1;
    while (bodyClose < msl.size() && depth > 0) {
        const char c = msl[bodyClose];
        if (c == '{') {
            ++depth;
        } else if (c == '}') {
            --depth;
            if (depth == 0) {
                break;
            }
        }
        ++bodyClose;
    }
    return depth == 0 && bodyClose < msl.size();
}

std::uint32_t injectClipControlYSignFixup(std::string& msl) {
    static constexpr const char* kParamName = "_appgl_ClipControlYSign";
    if (msl.find(kParamName) != std::string::npos) {
        return kMaxMetalBufferSlot + 1u;
    }
    // Clip/cull-distance shaders already carry explicit rasterizer clipping
    // state and, for cull distance, may use a CPU prepass plus filtered draw.
    // Keep those paths on the legacy viewport/readback orientation model.
    if (msl.find("gl_ClipDistance") != std::string::npos ||
        msl.find("gl_CullDistance") != std::string::npos ||
        msl.find("[[clip_distance]]") != std::string::npos) {
        return kMaxMetalBufferSlot + 1u;
    }

    const std::string positionField = findPositionFieldName(msl);
    if (positionField.empty()) {
        return kMaxMetalBufferSlot + 1u;
    }

    std::size_t paramEnd = 0;
    std::size_t bodyOpen = 0;
    std::size_t bodyClose = 0;
    if (!findMain0Body(msl, paramEnd, bodyOpen, bodyClose)) {
        return kMaxMetalBufferSlot + 1u;
    }

    struct Insertion {
        std::size_t pos;
        std::string text;
    };
    std::vector<Insertion> insertions;
    std::size_t scan = bodyOpen + 1;
    while ((scan = msl.find("return", scan)) != std::string::npos && scan < bodyClose) {
        if ((scan > 0 && isIdentifierChar(msl[scan - 1])) ||
            (scan + 6 < msl.size() && isIdentifierChar(msl[scan + 6]))) {
            scan += 6;
            continue;
        }
        std::size_t cursor = scan + 6;
        while (cursor < bodyClose &&
               std::isspace(static_cast<unsigned char>(msl[cursor]))) {
            ++cursor;
        }
        if (cursor >= bodyClose ||
            !isIdentifierChar(msl[cursor]) ||
            std::isdigit(static_cast<unsigned char>(msl[cursor]))) {
            scan += 6;
            continue;
        }
        const std::size_t nameStart = cursor;
        while (cursor < bodyClose && isIdentifierChar(msl[cursor])) {
            ++cursor;
        }
        const std::string resultName = msl.substr(nameStart, cursor - nameStart);
        while (cursor < bodyClose &&
               std::isspace(static_cast<unsigned char>(msl[cursor]))) {
            ++cursor;
        }
        if (cursor >= bodyClose || msl[cursor] != ';') {
            scan += 6;
            continue;
        }

        const std::size_t lineStart = msl.rfind('\n', scan);
        const std::size_t lineBegin = lineStart == std::string::npos ? 0 : lineStart + 1;
        std::size_t indentEnd = lineBegin;
        while (indentEnd < scan &&
               std::isspace(static_cast<unsigned char>(msl[indentEnd])) &&
               msl[indentEnd] != '\n') {
            ++indentEnd;
        }
        const std::string indent = msl.substr(lineBegin, indentEnd - lineBegin);
        insertions.push_back({
            scan,
            indent + resultName + "." + positionField +
                ".y *= " + kParamName + ";\n"
        });
        scan = cursor + 1;
    }
    if (insertions.empty()) {
        return kMaxMetalBufferSlot + 1u;
    }

    const std::uint32_t slot =
        chooseFreeBufferSlot(msl, kClipControlYSignPreferredBufferSlot);
    const std::size_t paramStart = msl.rfind('(', paramEnd);
    bool hasExistingParams = false;
    if (paramStart != std::string::npos) {
        for (std::size_t i = paramStart + 1; i < paramEnd; ++i) {
            if (!std::isspace(static_cast<unsigned char>(msl[i]))) {
                hasExistingParams = true;
                break;
            }
        }
    }
    const std::string param =
        std::string(hasExistingParams ? ", " : "") +
        "constant float& " + std::string(kParamName) +
        " [[buffer(" + std::to_string(slot) + ")]]";
    msl.insert(paramEnd, param);
    for (auto it = insertions.rbegin(); it != insertions.rend(); ++it) {
        msl.insert(it->pos + param.size(), it->text);
    }
    return slot;
}

bool parseUnsignedAfter(const std::string& text,
                        std::size_t cursor,
                        std::uint32_t& value,
                        std::size_t* end = nullptr) {
    if (cursor >= text.size() ||
        !std::isdigit(static_cast<unsigned char>(text[cursor]))) {
        return false;
    }
    std::uint32_t parsed = 0;
    while (cursor < text.size() &&
           std::isdigit(static_cast<unsigned char>(text[cursor]))) {
        parsed = parsed * 10u + static_cast<std::uint32_t>(text[cursor] - '0');
        ++cursor;
    }
    value = parsed;
    if (end != nullptr) {
        *end = cursor;
    }
    return true;
}

bool appendUnique(std::vector<std::string>& values, std::string value) {
    if (std::find(values.begin(), values.end(), value) != values.end()) {
        return false;
    }
    values.push_back(std::move(value));
    return true;
}

bool injectMultisampleSampledImageSidecars(std::string& msl) {
    static constexpr const char* kSidecarPrefix = "appgl_ms_sampled_sidecar_";
    static constexpr std::size_t kSidecarPrefixLen = 25;

    std::vector<std::string> params;
    std::size_t pos = 0;
    while ((pos = msl.find(kSidecarPrefix, pos)) != std::string::npos) {
        std::uint32_t sourceSlot = 0;
        std::size_t afterSlot = 0;
        if (!parseUnsignedAfter(msl, pos + kSidecarPrefixLen,
                                sourceSlot, &afterSlot)) {
            pos += kSidecarPrefixLen;
            continue;
        }

        const std::string sidecarName =
            std::string(kSidecarPrefix) + std::to_string(sourceSlot);
        if (msl.find(" " + sidecarName + " [[texture(") != std::string::npos) {
            pos = afterSlot;
            continue;
        }

        const std::string textureAttr =
            "[[texture(" + std::to_string(sourceSlot) + ")]]";
        const std::size_t attrPos = msl.find(textureAttr);
        if (attrPos == std::string::npos) {
            pos = afterSlot;
            continue;
        }

        const std::size_t lineStart = msl.rfind('\n', attrPos);
        std::size_t segmentBegin =
            (lineStart == std::string::npos) ? 0 : lineStart + 1u;
        const std::size_t paren = msl.rfind('(', attrPos);
        if (paren != std::string::npos && paren >= segmentBegin) {
            segmentBegin = paren + 1u;
        }
        std::size_t typeStart = msl.find("texture2d_ms", segmentBegin);
        if (typeStart == std::string::npos || typeStart > attrPos) {
            pos = afterSlot;
            continue;
        }
        const std::size_t templateStart = msl.find('<', typeStart);
        const std::size_t templateEnd = msl.find('>', templateStart);
        if (templateStart == std::string::npos ||
            templateEnd == std::string::npos ||
            templateEnd > attrPos) {
            pos = afterSlot;
            continue;
        }

        const std::string templateArgs =
            msl.substr(templateStart + 1, templateEnd - templateStart - 1);
        const std::uint32_t sidecarSlot =
            sourceSlot + kMultisampleSampledSidecarTextureSlotOffset;
        appendUnique(params,
            ", texture2d_array<" + templateArgs + "> " + sidecarName +
            " [[texture(" + std::to_string(sidecarSlot) + ")]]");
        pos = afterSlot;
    }

    if (params.empty()) {
        return false;
    }
    std::size_t paramEnd = 0;
    if (!findMain0ParameterEnd(msl, paramEnd)) {
        return false;
    }
    std::string insertion;
    for (const auto& param : params) {
        insertion += param;
    }
    msl.insert(paramEnd, insertion);
    return true;
}

bool injectMultisampleStorageReadSidecars(std::string& msl) {
    static constexpr const char* kSidecarPrefix =
        "appgl_ms_storage_read_sidecar_";
    static constexpr std::size_t kSidecarPrefixLen =
        sizeof("appgl_ms_storage_read_sidecar_") - 1u;

    std::vector<std::string> params;
    std::size_t pos = 0;
    while ((pos = msl.find(kSidecarPrefix, pos)) != std::string::npos) {
        std::uint32_t sourceSlot = 0;
        std::size_t afterSlot = 0;
        if (!parseUnsignedAfter(msl, pos + kSidecarPrefixLen,
                                sourceSlot, &afterSlot)) {
            pos += kSidecarPrefixLen;
            continue;
        }

        const std::string sidecarName =
            std::string(kSidecarPrefix) + std::to_string(sourceSlot);
        if (msl.find(" " + sidecarName + " [[texture(") != std::string::npos) {
            pos = afterSlot;
            continue;
        }

        const std::string textureAttr =
            "[[texture(" + std::to_string(sourceSlot) + ")]]";
        const std::size_t attrPos = msl.find(textureAttr);
        if (attrPos == std::string::npos) {
            pos = afterSlot;
            continue;
        }

        const std::size_t lineStart = msl.rfind('\n', attrPos);
        const std::size_t lineBegin =
            (lineStart == std::string::npos) ? 0 : lineStart + 1u;
        const std::size_t typeStart = msl.rfind("texture2d_ms", attrPos);
        if (typeStart == std::string::npos || typeStart < lineBegin) {
            pos = afterSlot;
            continue;
        }
        const std::size_t templateStart = msl.find('<', typeStart);
        const std::size_t templateEnd = msl.find('>', templateStart);
        if (templateStart == std::string::npos ||
            templateEnd == std::string::npos ||
            templateEnd > attrPos) {
            pos = afterSlot;
            continue;
        }

        const std::string templateArgs =
            msl.substr(templateStart + 1, templateEnd - templateStart - 1);
        const std::uint32_t sidecarSlot =
            sourceSlot + kMultisampleSampledSidecarTextureSlotOffset;
        appendUnique(params,
            ", texture2d_array<" + templateArgs + "> " + sidecarName +
            " [[texture(" + std::to_string(sidecarSlot) + ")]]");
        pos = afterSlot;
    }

    if (params.empty()) {
        return false;
    }
    std::size_t paramEnd = 0;
    if (!findMain0ParameterEnd(msl, paramEnd)) {
        return false;
    }
    std::string insertion;
    for (const auto& param : params) {
        insertion += param;
    }
    msl.insert(paramEnd, insertion);
    return true;
}

bool injectFixedFunctionSampleMask(std::string& msl) {
    if (msl.find("[[sample_mask]]") != std::string::npos) {
        return false;
    }
    const std::string structNeedle = "struct main0_out";
    const std::size_t structPos = msl.find(structNeedle);
    if (structPos == std::string::npos) {
        return false;
    }
    const std::size_t bracePos = msl.find('{', structPos);
    const std::size_t structEnd = msl.find("};", bracePos);
    if (bracePos == std::string::npos || structEnd == std::string::npos) {
        return false;
    }
    const std::string returnPattern = "    return out;";
    if (msl.find(returnPattern) == std::string::npos) {
        return false;
    }

    msl.insert(structEnd, "    uint appgl_SampleMask [[sample_mask]];\n");

    std::size_t paramEnd = 0;
    if (!findMain0ParameterEnd(msl, paramEnd)) {
        return false;
    }
    const std::uint32_t sampleMaskSlot = chooseFreeBufferSlot(msl, 21u);
    const std::size_t paramBegin = msl.rfind('(', paramEnd);
    bool hasExistingParam = false;
    if (paramBegin != std::string::npos) {
        for (std::size_t i = paramBegin + 1; i < paramEnd; ++i) {
            if (!std::isspace(static_cast<unsigned char>(msl[i]))) {
                hasExistingParam = true;
                break;
            }
        }
    }
    msl.insert(paramEnd,
               std::string(hasExistingParam ? ", " : "") +
               "constant uint& appgl_SampleMask [[buffer(" +
               std::to_string(sampleMaskSlot) + ")]]");

    const std::string assignment =
        "    out.appgl_SampleMask = appgl_SampleMask;\n";
    std::string out;
    out.reserve(msl.size() + assignment.size());
    std::size_t pos = 0;
    while (pos < msl.size()) {
        const std::size_t idx = msl.find(returnPattern, pos);
        if (idx == std::string::npos) {
            out.append(msl, pos, std::string::npos);
            break;
        }
        out.append(msl, pos, idx - pos);
        out.append(assignment);
        out.append(returnPattern);
        pos = idx + returnPattern.size();
    }
    msl = std::move(out);
    return true;
}

bool injectGlNumSamplesParameter(std::string& msl) {
    if (msl.find("_RESERVED_IDENTIFIER_FIXUP_gl_NumSamples") != std::string::npos) {
        return false;
    }
    std::size_t paramEnd = 0;
    if (!findMain0ParameterEnd(msl, paramEnd)) {
        return false;
    }
    const std::size_t paramBegin = msl.rfind('(', paramEnd);
    bool hasExistingParam = false;
    if (paramBegin != std::string::npos) {
        for (std::size_t i = paramBegin + 1; i < paramEnd; ++i) {
            if (!std::isspace(static_cast<unsigned char>(msl[i]))) {
                hasExistingParam = true;
                break;
            }
        }
    }
    msl.insert(paramEnd,
               std::string(hasExistingParam ? ", " : "") +
               "constant int& _RESERVED_IDENTIFIER_FIXUP_gl_NumSamples [[buffer(0)]]");
    return true;
}

bool injectSparseSampledImageSidecars(std::string& msl) {
    static constexpr const char* kSidecarPrefix =
        "appgl_sparse_sampled_sidecar_";
    static constexpr std::size_t kSidecarPrefixLen =
        sizeof("appgl_sparse_sampled_sidecar_") - 1u;

    std::vector<std::string> params;
    std::size_t pos = 0;
    while ((pos = msl.find(kSidecarPrefix, pos)) != std::string::npos) {
        std::uint32_t sourceSlot = 0;
        std::size_t afterSlot = 0;
        if (!parseUnsignedAfter(msl, pos + kSidecarPrefixLen,
                                sourceSlot, &afterSlot)) {
            pos += kSidecarPrefixLen;
            continue;
        }

        const std::string sidecarName =
            std::string(kSidecarPrefix) + std::to_string(sourceSlot);
        if (msl.find(" " + sidecarName + " [[texture(") != std::string::npos) {
            pos = afterSlot;
            continue;
        }

        const std::string textureAttr =
            "[[texture(" + std::to_string(sourceSlot) + ")]]";
        const std::size_t attrPos = msl.find(textureAttr);
        if (attrPos == std::string::npos) {
            pos = afterSlot;
            continue;
        }

        const std::size_t lineStart = msl.rfind('\n', attrPos);
        const std::size_t lineBegin =
            (lineStart == std::string::npos) ? 0 : lineStart + 1u;
        const std::size_t typeStart = msl.rfind("texture", attrPos);
        if (typeStart == std::string::npos || typeStart < lineBegin) {
            pos = afterSlot;
            continue;
        }

        const std::size_t templateStart = msl.find('<', typeStart);
        const std::size_t templateEnd = msl.find('>', templateStart);
        if (templateStart == std::string::npos ||
            templateEnd == std::string::npos ||
            templateEnd > attrPos) {
            pos = afterSlot;
            continue;
        }

        const std::string textureType =
            msl.substr(typeStart, templateEnd - typeStart + 1u);
        const std::uint32_t sidecarSlot =
            sourceSlot + kMultisampleSampledSidecarTextureSlotOffset;
        appendUnique(params,
            ", " + textureType + " " + sidecarName +
            " [[texture(" + std::to_string(sidecarSlot) + ")]]");
        pos = afterSlot;
    }

    if (params.empty()) {
        return false;
    }
    std::size_t paramEnd = 0;
    if (!findMain0ParameterEnd(msl, paramEnd)) {
        return false;
    }
    std::string insertion;
    for (const auto& param : params) {
        insertion += param;
    }
    msl.insert(paramEnd, insertion);
    return true;
}

bool injectMultisampleStorageImageSampleCounts(std::string& msl) {
    static constexpr const char* kSampleCountsName =
        "appgl_ms_storage_image_samples";
    static constexpr const char* kSampleCountsParam =
        "constant uint* appgl_ms_storage_image_samples";
    if (msl.find(kSampleCountsName) == std::string::npos ||
        msl.find(kSampleCountsParam) != std::string::npos) {
        return false;
    }

    std::size_t paramEnd = 0;
    if (!findMain0ParameterEnd(msl, paramEnd)) return false;
    const std::uint32_t slot = chooseFreeBufferSlot(
        msl, kMultisampleStorageImageSampleCountsBufferSlot);

    const std::string param =
        ", constant uint* " + std::string(kSampleCountsName) +
        " [[buffer(" +
        std::to_string(slot) + ")]]";
    msl.insert(paramEnd, param);
    return true;
}

bool injectMultisampleStorageSparseResidencyTextures(std::string& msl) {
    static constexpr const char* kResidencyPrefix =
        "appgl_ms_storage_sparse_";
    static constexpr const char* kMarkerPrefix =
        "APPGL_MS_STORAGE_SPARSE_RESIDENCY_SLOT_";
    static constexpr std::size_t kMarkerPrefixLen =
        sizeof("APPGL_MS_STORAGE_SPARSE_RESIDENCY_SLOT_") - 1u;

    std::vector<std::string> params;
    std::size_t pos = 0;
    while ((pos = msl.find(kMarkerPrefix, pos)) != std::string::npos) {
        std::uint32_t sourceSlot = 0;
        std::size_t afterSlot = 0;
        if (!parseUnsignedAfter(msl, pos + kMarkerPrefixLen,
                                sourceSlot, &afterSlot)) {
            pos += kMarkerPrefixLen;
            continue;
        }

        bool arrayed = false;
        const std::string arrayToken = "_ARRAY_";
        const std::size_t arrayTokenPos = msl.find(arrayToken, afterSlot);
        if (arrayTokenPos != std::string::npos && arrayTokenPos - afterSlot < 16u) {
            const std::size_t valuePos = arrayTokenPos + arrayToken.size();
            arrayed = valuePos < msl.size() && msl[valuePos] == '1';
        }

        const std::string residencyName =
            std::string(kResidencyPrefix) + std::to_string(sourceSlot);
        if (msl.find(" " + residencyName + " [[texture(") != std::string::npos) {
            pos = afterSlot;
            continue;
        }

        const std::string textureAttr =
            "[[texture(" + std::to_string(sourceSlot) + ")]]";
        const std::size_t attrPos = msl.find(textureAttr);
        if (attrPos == std::string::npos) {
            pos = afterSlot;
            continue;
        }

        const std::size_t lineStart = msl.rfind('\n', attrPos);
        const std::size_t lineBegin =
            (lineStart == std::string::npos) ? 0 : lineStart + 1u;
        const std::size_t typeStart = msl.rfind("texture2d_array", attrPos);
        if (typeStart == std::string::npos || typeStart < lineBegin) {
            pos = afterSlot;
            continue;
        }

        const std::size_t templateStart = msl.find('<', typeStart);
        const std::size_t templateEnd = msl.find('>', templateStart);
        if (templateStart == std::string::npos ||
            templateEnd == std::string::npos ||
            templateEnd > attrPos) {
            pos = afterSlot;
            continue;
        }

        std::string templateArgs =
            msl.substr(templateStart + 1, templateEnd - templateStart - 1);
        const std::size_t accessPos = templateArgs.find("access::");
        if (accessPos != std::string::npos) {
            const std::size_t accessEnd = templateArgs.find(',', accessPos);
            templateArgs.replace(accessPos,
                                 accessEnd == std::string::npos
                                     ? std::string::npos
                                     : accessEnd - accessPos,
                                 "access::read");
        }

        const std::uint32_t residencySlot =
            sourceSlot + kMultisampleStorageSparseResidencyTextureSlotOffset;
        const std::string nativeType =
            arrayed ? "texture2d_ms_array" : "texture2d_ms";
        appendUnique(params,
            ", " + nativeType + "<" + templateArgs + "> " +
            residencyName + " [[texture(" +
            std::to_string(residencySlot) + ")]]");
        pos = afterSlot;
    }

    if (params.empty()) {
        return false;
    }
    std::size_t paramEnd = 0;
    if (!findMain0ParameterEnd(msl, paramEnd)) {
        return false;
    }
    std::string insertion;
    for (const auto& param : params) {
        insertion += param;
    }
    msl.insert(paramEnd, insertion);
    return true;
}

std::string trimCopy(const std::string& value) {
    std::size_t begin = 0;
    while (begin < value.size() &&
           std::isspace(static_cast<unsigned char>(value[begin]))) {
        ++begin;
    }
    std::size_t end = value.size();
    while (end > begin &&
           std::isspace(static_cast<unsigned char>(value[end - 1]))) {
        --end;
    }
    return value.substr(begin, end - begin);
}

std::vector<std::string> splitTopLevelCommas(const std::string& text) {
    std::vector<std::string> parts;
    std::size_t begin = 0;
    int parenDepth = 0;
    int bracketDepth = 0;
    int angleDepth = 0;
    for (std::size_t i = 0; i < text.size(); ++i) {
        const char ch = text[i];
        if (ch == '(') {
            ++parenDepth;
        } else if (ch == ')' && parenDepth > 0) {
            --parenDepth;
        } else if (ch == '[') {
            ++bracketDepth;
        } else if (ch == ']' && bracketDepth > 0) {
            --bracketDepth;
        } else if (ch == '<') {
            ++angleDepth;
        } else if (ch == '>' && angleDepth > 0) {
            --angleDepth;
        } else if (ch == ',' && parenDepth == 0 &&
                   bracketDepth == 0 && angleDepth == 0) {
            parts.push_back(trimCopy(text.substr(begin, i - begin)));
            begin = i + 1;
        }
    }
    parts.push_back(trimCopy(text.substr(begin)));
    return parts;
}

bool findMatchingParen(const std::string& text,
                       std::size_t open,
                       std::size_t& close) {
    if (open >= text.size() || text[open] != '(') {
        return false;
    }
    int depth = 1;
    for (std::size_t i = open + 1; i < text.size(); ++i) {
        if (text[i] == '(') {
            ++depth;
        } else if (text[i] == ')') {
            --depth;
            if (depth == 0) {
                close = i;
                return true;
            }
        }
    }
    return false;
}

struct MultisampleTextureVar {
    std::string name;
    std::uint32_t metalSlot = 0;
    bool arrayed = false;
};

std::vector<MultisampleTextureVar> collectMultisampleSampledTextureVars(
    const std::string& msl) {
    std::vector<MultisampleTextureVar> vars;
    std::set<std::pair<std::string, std::uint32_t>> seen;

    std::size_t attrPos = 0;
    while ((attrPos = msl.find("[[texture(", attrPos)) != std::string::npos) {
        std::size_t cursor = attrPos + std::strlen("[[texture(");
        std::uint32_t slot = 0;
        if (!parseUnsignedAfter(msl, cursor, slot, &cursor)) {
            attrPos += std::strlen("[[texture(");
            continue;
        }

        const std::size_t lineStart = msl.rfind('\n', attrPos);
        std::size_t segmentBegin =
            (lineStart == std::string::npos) ? 0 : lineStart + 1u;
        const std::size_t comma = msl.rfind(',', attrPos);
        if (comma != std::string::npos && comma >= segmentBegin) {
            segmentBegin = comma + 1u;
        }
        const std::size_t paren = msl.rfind('(', attrPos);
        if (paren != std::string::npos && paren >= segmentBegin) {
            segmentBegin = paren + 1u;
        }
        const std::size_t typeStart = msl.find("texture2d_ms", segmentBegin);
        if (typeStart == std::string::npos || typeStart > attrPos) {
            attrPos += std::strlen("[[texture(");
            continue;
        }

        const bool arrayed =
            msl.compare(typeStart,
                        std::strlen("texture2d_ms_array"),
                        "texture2d_ms_array") == 0;
        const std::size_t templateStart = msl.find('<', typeStart);
        const std::size_t templateEnd = msl.find('>', templateStart);
        if (templateStart == std::string::npos ||
            templateEnd == std::string::npos ||
            templateEnd > attrPos) {
            attrPos += std::strlen("[[texture(");
            continue;
        }

        const std::string templateArgs =
            msl.substr(templateStart + 1, templateEnd - templateStart - 1);
        if (templateArgs.find("access::") != std::string::npos) {
            attrPos += std::strlen("[[texture(");
            continue;
        }

        std::size_t nameStart = templateEnd + 1;
        while (nameStart < attrPos &&
               std::isspace(static_cast<unsigned char>(msl[nameStart]))) {
            ++nameStart;
        }
        std::size_t nameEnd = nameStart;
        while (nameEnd < attrPos && isIdentifierChar(msl[nameEnd])) {
            ++nameEnd;
        }
        if (nameEnd > nameStart) {
            std::string name = msl.substr(nameStart, nameEnd - nameStart);
            if (seen.insert({name, slot}).second) {
                vars.push_back({std::move(name), slot, arrayed});
            }
        }
        attrPos += std::strlen("[[texture(");
    }

    return vars;
}

bool rewriteMultisampleSampledImageReads(std::string& msl) {
    bool changed = false;
    const auto vars = collectMultisampleSampledTextureVars(msl);

    for (const auto& var : vars) {
        const std::string sidecarName =
            "appgl_ms_sampled_sidecar_" + std::to_string(var.metalSlot);
        const std::string sampleCount =
            "appgl_ms_storage_image_samples[" +
            std::to_string(var.metalSlot) + "]";
        const std::string needle = var.name + ".read(";
        std::size_t pos = 0;
        while ((pos = msl.find(needle, pos)) != std::string::npos) {
            const std::size_t open = pos + needle.size() - 1u;
            std::size_t close = std::string::npos;
            if (!findMatchingParen(msl, open, close)) {
                break;
            }

            const std::string original = msl.substr(pos, close - pos + 1u);
            const auto args =
                splitTopLevelCommas(msl.substr(open + 1u, close - open - 1u));
            std::string sidecarRead;
            if (!var.arrayed && args.size() >= 2u) {
                sidecarRead =
                    sidecarName + ".read(" + args[0] + ", uint(" +
                    args[1] + "))";
            } else if (var.arrayed && args.size() >= 3u) {
                sidecarRead =
                    sidecarName + ".read(" + args[0] + ", (uint(" +
                    args[1] + ") * max(" + sampleCount +
                    ", 1u) + uint(" + args[2] + ")))";
            } else {
                pos = close + 1u;
                continue;
            }

            const std::string replacement =
                "((" + sampleCount + " == 0u) ? " +
                original + " : " + sidecarRead + ")";
            msl.replace(pos, original.size(), replacement);
            pos += replacement.size();
            changed = true;
        }
    }

    return changed;
}

bool findMatchingBracket(const std::string& text,
                         std::size_t open,
                         std::size_t& close) {
    if (open >= text.size() || text[open] != '[') {
        return false;
    }
    int depth = 1;
    for (std::size_t i = open + 1; i < text.size(); ++i) {
        if (text[i] == '[') {
            ++depth;
        } else if (text[i] == ']') {
            --depth;
            if (depth == 0) {
                close = i;
                return true;
            }
        }
    }
    return false;
}

bool parseDecimalUInt(const std::string& text,
                      std::size_t& cursor,
                      std::uint32_t& value) {
    if (cursor >= text.size() ||
        !std::isdigit(static_cast<unsigned char>(text[cursor]))) {
        return false;
    }
    std::uint32_t parsed = 0;
    while (cursor < text.size() &&
           std::isdigit(static_cast<unsigned char>(text[cursor]))) {
        parsed = parsed * 10u +
            static_cast<std::uint32_t>(text[cursor] - '0');
        ++cursor;
    }
    value = parsed;
    return true;
}

void skipWhitespace(const std::string& text,
                    std::size_t& cursor,
                    std::size_t end = std::string::npos) {
    if (end == std::string::npos || end > text.size()) {
        end = text.size();
    }
    while (cursor < end &&
           std::isspace(static_cast<unsigned char>(text[cursor]))) {
        ++cursor;
    }
}

bool collapseOversizedDirectSamplerArrays(std::string& msl) {
    struct SamplerArray {
        std::string name;
    };
    std::vector<SamplerArray> collapsed;
    bool changed = false;
    static constexpr const char* kNeedle = "array<sampler,";
    static constexpr std::size_t kNeedleLen = sizeof("array<sampler,") - 1u;

    std::size_t pos = 0;
    while ((pos = msl.find(kNeedle, pos)) != std::string::npos) {
        std::size_t cursor = pos + kNeedleLen;
        skipWhitespace(msl, cursor);
        std::uint32_t arraySize = 0;
        if (!parseDecimalUInt(msl, cursor, arraySize)) {
            pos += kNeedleLen;
            continue;
        }
        skipWhitespace(msl, cursor);
        if (cursor >= msl.size() || msl[cursor] != '>') {
            pos += kNeedleLen;
            continue;
        }
        const std::size_t typeEnd = cursor + 1;
        std::size_t nameBegin = typeEnd;
        skipWhitespace(msl, nameBegin);
        std::size_t nameEnd = nameBegin;
        while (nameEnd < msl.size() && isIdentifierChar(msl[nameEnd])) {
            ++nameEnd;
        }
        if (nameEnd == nameBegin) {
            pos = typeEnd;
            continue;
        }

        const std::size_t lineEnd = msl.find('\n', nameEnd);
        const std::size_t searchEnd =
            lineEnd == std::string::npos ? msl.size() : lineEnd;
        const std::size_t samplerAttr = msl.find("[[sampler(", nameEnd);
        if (samplerAttr == std::string::npos || samplerAttr > searchEnd) {
            pos = typeEnd;
            continue;
        }
        cursor = samplerAttr + std::strlen("[[sampler(");
        std::uint32_t samplerSlot = 0;
        if (!parseDecimalUInt(msl, cursor, samplerSlot)) {
            pos = typeEnd;
            continue;
        }

        if (samplerSlot + arraySize <= kMaxDirectMetalSamplerSlots) {
            pos = typeEnd;
            continue;
        }

        const std::string name = msl.substr(nameBegin, nameEnd - nameBegin);
        msl.replace(pos, typeEnd - pos, "sampler");
        collapsed.push_back({name});
        pos += std::strlen("sampler");
        changed = true;
    }

    std::sort(collapsed.begin(), collapsed.end(),
              [](const SamplerArray& a, const SamplerArray& b) {
                  return a.name < b.name;
              });
    collapsed.erase(
        std::unique(collapsed.begin(), collapsed.end(),
                    [](const SamplerArray& a, const SamplerArray& b) {
                        return a.name == b.name;
                    }),
        collapsed.end());

    for (const auto& sampler : collapsed) {
        pos = 0;
        while ((pos = msl.find(sampler.name, pos)) != std::string::npos) {
            if (pos > 0 && isIdentifierChar(msl[pos - 1])) {
                pos += sampler.name.size();
                continue;
            }
            const std::size_t afterName = pos + sampler.name.size();
            if (afterName < msl.size() && isIdentifierChar(msl[afterName])) {
                pos = afterName;
                continue;
            }
            std::size_t bracket = afterName;
            skipWhitespace(msl, bracket);
            if (bracket >= msl.size() || msl[bracket] != '[' ||
                (bracket + 1 < msl.size() && msl[bracket + 1] == '[')) {
                pos = afterName;
                continue;
            }
            std::size_t close = std::string::npos;
            if (!findMatchingBracket(msl, bracket, close)) {
                pos = afterName;
                continue;
            }
            msl.erase(afterName, close - afterName + 1);
            pos = afterName;
            changed = true;
        }
    }

    return changed;
}

// SPIRV-Cross can lower image1DArray atomics to `atomic_ptr[int2(...)]`.
// Metal only accepts scalar pointer subscripts, so linearize those vector
// coordinates through the same helper macros used for 2D/3D image atomics.
bool rewriteVectorImageAtomicBufferSubscripts(std::string& msl) {
    bool changed = false;
    static constexpr const char* kSuffix = "_atomic";
    static constexpr std::size_t kSuffixLen =
        sizeof("_atomic") - 1u;

    std::size_t pos = 0;
    while ((pos = msl.find("_atomic[", pos)) != std::string::npos) {
        std::size_t nameStart = pos;
        while (nameStart > 0 && isIdentifierChar(msl[nameStart - 1])) {
            --nameStart;
        }
        const std::size_t nameEnd = pos + kSuffixLen;
        if (nameStart >= pos || nameEnd >= msl.size() || msl[nameEnd] != '[') {
            pos = nameEnd + 1;
            continue;
        }

        const std::string atomicName =
            msl.substr(nameStart, nameEnd - nameStart);
        if (atomicName.size() <= kSuffixLen) {
            pos = nameEnd + 1;
            continue;
        }
        const std::string imageName =
            atomicName.substr(0, atomicName.size() - kSuffixLen);
        if (msl.find(" " + imageName + " [[texture(") == std::string::npos) {
            pos = nameEnd + 1;
            continue;
        }

        std::size_t close = std::string::npos;
        if (!findMatchingBracket(msl, nameEnd, close)) {
            pos = nameEnd + 1;
            continue;
        }
        const std::string indexExpr =
            trimCopy(msl.substr(nameEnd + 1, close - nameEnd - 1));
        const bool vector2Index =
            indexExpr.rfind("int2(", 0) == 0 ||
            indexExpr.rfind("uint2(", 0) == 0;
        const bool vector3Index =
            indexExpr.rfind("int3(", 0) == 0 ||
            indexExpr.rfind("uint3(", 0) == 0;
        if (!vector2Index && !vector3Index) {
            pos = close + 1;
            continue;
        }

        const char* helper = vector2Index
            ? "spvImage2DAtomicCoord("
            : "spvImage3DAtomicCoord(";
        const std::string replacement =
            std::string(helper) + indexExpr + ", " + imageName + ")";
        msl.replace(nameEnd + 1, close - nameEnd - 1, replacement);
        pos = nameEnd + 1 + replacement.size();
        changed = true;
    }
    return changed;
}

// Texel-buffer storage images with atomics are backed by one MTLBuffer.
// Keep imageLoad coherent with imageAtomic* by reading that buffer sidecar,
// not Metal's texture view alias, inside the same dispatch.
bool rewriteTexelBufferImageAtomicReads(std::string& msl) {
    bool changed = false;
    static constexpr const char* kReadNeedle =
        ".read(spvTexelBufferCoord(";
    static constexpr const char* kCoordFn = "spvTexelBufferCoord";

    auto atomicTypeForName = [&](const std::string& atomicName) -> std::string {
        std::size_t pos = 0;
        while ((pos = msl.find(atomicName + " [[buffer(", pos)) !=
               std::string::npos) {
            const std::size_t lineStart =
                msl.rfind('\n', pos) == std::string::npos
                    ? 0
                    : msl.rfind('\n', pos) + 1;
            const std::string line = msl.substr(lineStart, pos - lineStart);
            if (line.find("atomic_uint") != std::string::npos) {
                return "atomic_uint";
            }
            if (line.find("atomic_int") != std::string::npos) {
                return "atomic_int";
            }
            pos += atomicName.size();
        }
        return {};
    };

    std::size_t pos = 0;
    while ((pos = msl.find(kReadNeedle, pos)) != std::string::npos) {
        std::size_t nameStart = pos;
        while (nameStart > 0 && isIdentifierChar(msl[nameStart - 1])) {
            --nameStart;
        }
        if (nameStart == pos) {
            pos += std::strlen(kReadNeedle);
            continue;
        }
        const std::string imageName = msl.substr(nameStart, pos - nameStart);
        const std::string atomicName = imageName + "_atomic";
        const std::string atomicType = atomicTypeForName(atomicName);
        if (atomicType.empty()) {
            pos += std::strlen(kReadNeedle);
            continue;
        }

        const std::size_t readOpen = pos + std::strlen(".read");
        std::size_t readClose = std::string::npos;
        if (!findMatchingParen(msl, readOpen, readClose)) {
            pos += std::strlen(kReadNeedle);
            continue;
        }
        const std::size_t coordFn = msl.find(kCoordFn, readOpen);
        if (coordFn == std::string::npos || coordFn > readClose) {
            pos = readClose + 1;
            continue;
        }
        const std::size_t coordOpen = coordFn + std::strlen(kCoordFn);
        std::size_t coordClose = std::string::npos;
        if (!findMatchingParen(msl, coordOpen, coordClose) ||
            coordClose > readClose) {
            pos = readClose + 1;
            continue;
        }
        std::size_t component = readClose + 1;
        skipWhitespace(msl, component);
        if (component + 2 > msl.size() ||
            msl[component] != '.' || msl[component + 1] != 'x') {
            pos = readClose + 1;
            continue;
        }

        const std::string indexExpr =
            trimCopy(msl.substr(coordOpen + 1, coordClose - coordOpen - 1));
        const std::string replacement =
            "atomic_load_explicit((volatile device " + atomicType + "*)&" +
            atomicName + "[" + indexExpr + "], memory_order_relaxed)";
        const std::size_t replaceEnd = component + 2;
        msl.replace(nameStart, replaceEnd - nameStart, replacement);
        pos = nameStart + replacement.size();
        changed = true;
    }
    return changed;
}

// Metal accepts cube-array textures for sampling, but storage-image writes are
// reliable through a 2D-array view. Rewrite SPIRV-Cross's generated accessors
// from (coord, face, cube) to (coord, cube * 6 + face) for those image params.
std::string cubeArrayLayerExpression(const std::string& faceExpr,
                                     const std::string& arrayExpr) {
    const std::string face = trimCopy(faceExpr);
    const std::string array = trimCopy(arrayExpr);
    auto prefixBefore = [](const std::string& s, const char* token) {
        const std::size_t pos = s.find(token);
        return pos == std::string::npos
            ? std::string()
            : trimCopy(s.substr(0, pos));
    };

    std::string facePrefix = prefixBefore(face, "% 6u");
    if (facePrefix.empty()) {
        facePrefix = prefixBefore(face, "% 6");
    }
    std::string arrayPrefix = prefixBefore(array, "/ 6u");
    if (arrayPrefix.empty()) {
        arrayPrefix = prefixBefore(array, "/ 6");
    }
    if (!facePrefix.empty() && facePrefix == arrayPrefix) {
        return facePrefix;
    }

    return "(" + face + " + (" + array + ") * 6u)";
}

bool retargetCubeArrayStorageImagesAs2DArray(
    std::string& msl,
    const std::vector<std::uint32_t>& metalTextureSlots) {
    std::vector<std::string> variableNames;
    std::unordered_set<std::string> variableNameSet;
    bool changed = false;
    auto retargetAtTextureAttr = [&](std::size_t search,
                                     bool requireAccessQualifier) {
        const std::size_t typePos = msl.rfind("texturecube_array<", search);
        if (typePos == std::string::npos) {
            return;
        }
        const std::size_t typeEnd = msl.find('>', typePos);
        if (typeEnd == std::string::npos || typeEnd > search) {
            return;
        }
        const bool hasAccessQualifier = msl.find("access::", typePos) < typeEnd;
        if (requireAccessQualifier && !hasAccessQualifier) {
            return;
        }
        std::size_t nameStart = typeEnd + 1;
        while (nameStart < search &&
               std::isspace(static_cast<unsigned char>(msl[nameStart]))) {
            ++nameStart;
        }
        std::size_t nameEnd = nameStart;
        while (nameEnd < search && isIdentifierChar(msl[nameEnd])) {
            ++nameEnd;
        }
        if (nameStart >= search || nameEnd <= nameStart) {
            return;
        }
        const std::string variableName =
            msl.substr(nameStart, nameEnd - nameStart);
        if (variableNameSet.insert(variableName).second) {
            variableNames.push_back(variableName);
        }
        msl.replace(typePos,
                    std::strlen("texturecube_array"),
                    "texture2d_array");
        changed = true;
    };

    for (std::uint32_t slot : metalTextureSlots) {
        const std::string attr = "[[texture(" + std::to_string(slot) + ")]]";
        std::size_t search = 0;
        while ((search = msl.find(attr, search)) != std::string::npos) {
            retargetAtTextureAttr(search, false);
            search += attr.size();
        }
    }
    if (metalTextureSlots.empty()) {
        std::size_t typePos = 0;
        while ((typePos = msl.find("texturecube_array<", typePos)) !=
               std::string::npos) {
            const std::size_t attrPos = msl.find("[[texture(", typePos);
            if (attrPos != std::string::npos) {
                const std::size_t attrEnd = msl.find(")]]", attrPos);
                if (attrEnd != std::string::npos) {
                    retargetAtTextureAttr(attrPos, true);
                }
            }
            typePos += std::strlen("texturecube_array");
        }
    }

    auto retargetVariableDeclarations = [&](const std::string& varName) {
        std::size_t typePos = 0;
        while ((typePos = msl.find("texturecube_array<", typePos)) !=
               std::string::npos) {
            const std::size_t typeEnd = msl.find('>', typePos);
            if (typeEnd == std::string::npos) {
                break;
            }
            std::size_t nameStart = typeEnd + 1;
            while (nameStart < msl.size() &&
                   std::isspace(static_cast<unsigned char>(msl[nameStart]))) {
                ++nameStart;
            }
            const std::size_t nameEnd = nameStart + varName.size();
            if (nameEnd <= msl.size() &&
                msl.compare(nameStart, varName.size(), varName) == 0 &&
                (nameEnd == msl.size() || !isIdentifierChar(msl[nameEnd]))) {
                msl.replace(typePos,
                            std::strlen("texturecube_array"),
                            "texture2d_array");
                typePos += std::strlen("texture2d_array");
                changed = true;
            } else {
                typePos += std::strlen("texturecube_array");
            }
        }
    };
    auto rewriteAccessor = [&](const std::string& varName,
                               const char* accessor,
                               std::size_t expectedArgs) {
        const std::string needle = varName + "." + accessor + "(";
        std::size_t pos = 0;
        while ((pos = msl.find(needle, pos)) != std::string::npos) {
            const std::size_t open = pos + needle.size() - 1;
            std::size_t close = std::string::npos;
            if (!findMatchingParen(msl, open, close)) {
                break;
            }
            std::vector<std::string> args =
                splitTopLevelCommas(msl.substr(open + 1, close - open - 1));
            if (args.size() != expectedArgs) {
                pos = close + 1;
                continue;
            }
            std::string replacement = varName + "." + accessor + "(";
            if (expectedArgs == 4) {
                replacement += args[0] + ", " + args[1] + ", " +
                    cubeArrayLayerExpression(args[2], args[3]) + ")";
            } else {
                replacement += args[0] + ", " +
                    cubeArrayLayerExpression(args[1], args[2]) + ")";
            }
            msl.replace(pos, close + 1 - pos, replacement);
            pos += replacement.size();
            changed = true;
        }
    };
    auto rewriteArraySize = [&](const std::string& varName) {
        const std::string needle = varName + ".get_array_size()";
        std::size_t pos = 0;
        while ((pos = msl.find(needle, pos)) != std::string::npos) {
            if (pos > 0 && isIdentifierChar(msl[pos - 1])) {
                pos += needle.size();
                continue;
            }
            std::size_t suffix = pos + needle.size();
            while (suffix < msl.size() &&
                   std::isspace(static_cast<unsigned char>(msl[suffix]))) {
                ++suffix;
            }
            if (suffix < msl.size() && msl[suffix] == ')') {
                ++suffix;
                while (suffix < msl.size() &&
                       std::isspace(static_cast<unsigned char>(msl[suffix]))) {
                    ++suffix;
                }
            }
            if (msl.compare(suffix, 4, "/ 6") == 0) {
                pos += needle.size();
                continue;
            }
            const std::string replacement = "(" + needle + " / 6u)";
            msl.replace(pos, needle.size(), replacement);
            pos += replacement.size();
            changed = true;
        }
    };

    for (const auto& name : variableNames) {
        retargetVariableDeclarations(name);
        rewriteAccessor(name, "write", 4);
        rewriteAccessor(name, "read", 3);
        rewriteArraySize(name);
    }

    return changed;
}

bool retargetCubeStorageImagesAs2DArray(
    std::string& msl,
    const std::vector<std::uint32_t>& metalTextureSlots) {
    std::vector<std::string> variableNames;
    std::unordered_set<std::string> variableNameSet;
    bool changed = false;
    auto retargetAtTextureAttr = [&](std::size_t search,
                                     bool requireAccessQualifier) {
        const std::size_t typePos = msl.rfind("texturecube<", search);
        if (typePos == std::string::npos) {
            return;
        }
        const std::size_t typeEnd = msl.find('>', typePos);
        if (typeEnd == std::string::npos || typeEnd > search) {
            return;
        }
        const bool hasAccessQualifier = msl.find("access::", typePos) < typeEnd;
        if (requireAccessQualifier && !hasAccessQualifier) {
            return;
        }
        std::size_t nameStart = typeEnd + 1;
        while (nameStart < search &&
               std::isspace(static_cast<unsigned char>(msl[nameStart]))) {
            ++nameStart;
        }
        std::size_t nameEnd = nameStart;
        while (nameEnd < search && isIdentifierChar(msl[nameEnd])) {
            ++nameEnd;
        }
        if (nameStart >= search || nameEnd <= nameStart) {
            return;
        }
        const std::string variableName =
            msl.substr(nameStart, nameEnd - nameStart);
        if (variableNameSet.insert(variableName).second) {
            variableNames.push_back(variableName);
        }
        msl.replace(typePos, std::strlen("texturecube"), "texture2d_array");
        changed = true;
    };

    for (std::uint32_t slot : metalTextureSlots) {
        const std::string attr = "[[texture(" + std::to_string(slot) + ")]]";
        std::size_t search = 0;
        while ((search = msl.find(attr, search)) != std::string::npos) {
            retargetAtTextureAttr(search, false);
            search += attr.size();
        }
    }
    if (metalTextureSlots.empty()) {
        std::size_t typePos = 0;
        while ((typePos = msl.find("texturecube<", typePos)) !=
               std::string::npos) {
            const std::size_t attrPos = msl.find("[[texture(", typePos);
            if (attrPos != std::string::npos) {
                const std::size_t attrEnd = msl.find(")]]", attrPos);
                if (attrEnd != std::string::npos) {
                    retargetAtTextureAttr(attrPos, true);
                }
            }
            typePos += std::strlen("texturecube");
        }
    }

    auto retargetVariableDeclarations = [&](const std::string& varName) {
        std::size_t typePos = 0;
        while ((typePos = msl.find("texturecube<", typePos)) !=
               std::string::npos) {
            const std::size_t typeEnd = msl.find('>', typePos);
            if (typeEnd == std::string::npos) {
                break;
            }
            std::size_t nameStart = typeEnd + 1;
            while (nameStart < msl.size() &&
                   std::isspace(static_cast<unsigned char>(msl[nameStart]))) {
                ++nameStart;
            }
            const std::size_t nameEnd = nameStart + varName.size();
            if (nameEnd <= msl.size() &&
                msl.compare(nameStart, varName.size(), varName) == 0 &&
                (nameEnd == msl.size() || !isIdentifierChar(msl[nameEnd]))) {
                msl.replace(typePos,
                            std::strlen("texturecube"),
                            "texture2d_array");
                typePos += std::strlen("texture2d_array");
                changed = true;
            } else {
                typePos += std::strlen("texturecube");
            }
        }
    };

    for (const auto& name : variableNames) {
        retargetVariableDeclarations(name);
    }

    return changed;
}

std::vector<std::pair<std::string, std::uint32_t>>
collectTextureVariableSlotsForMetalSlots(
    const std::string& msl,
    const std::vector<std::uint32_t>& metalTextureSlots,
    const char* typePrefix) {
    std::vector<std::pair<std::string, std::uint32_t>> variableSlots;
    std::set<std::pair<std::string, std::uint32_t>> seen;

    auto collectAtAttr = [&](const std::string& attr,
                             std::uint32_t metalSlot) {
        std::size_t search = 0;
        while ((search = msl.find(attr, search)) != std::string::npos) {
            const std::size_t lineStart = msl.rfind('\n', search);
            const std::size_t lineBegin =
                (lineStart == std::string::npos) ? 0 : lineStart + 1u;
            std::size_t segmentBegin = lineBegin;
            const std::size_t comma = msl.rfind(',', search);
            if (comma != std::string::npos && comma >= segmentBegin) {
                segmentBegin = comma + 1u;
            }
            const std::size_t paren = msl.rfind('(', search);
            if (paren != std::string::npos && paren >= segmentBegin) {
                segmentBegin = paren + 1u;
            }
            const std::size_t typePos = msl.find(typePrefix, segmentBegin);
            if (typePos == std::string::npos || typePos > search) {
                search += attr.size();
                continue;
            }
            if (typePos > 0 && isIdentifierChar(msl[typePos - 1])) {
                search += attr.size();
                continue;
            }
            const std::size_t typeTemplate = msl.find('<', typePos);
            if (typeTemplate == std::string::npos || typeTemplate > search) {
                search += attr.size();
                continue;
            }
            const std::size_t typeEnd = msl.find('>', typeTemplate);
            if (typeEnd == std::string::npos || typeEnd > search) {
                search += attr.size();
                continue;
            }
            std::size_t nameStart = typeEnd + 1;
            while (nameStart < search &&
                   std::isspace(static_cast<unsigned char>(msl[nameStart]))) {
                ++nameStart;
            }
            std::size_t nameEnd = nameStart;
            while (nameEnd < search && isIdentifierChar(msl[nameEnd])) {
                ++nameEnd;
            }
            if (nameEnd > nameStart) {
                std::string name = msl.substr(nameStart, nameEnd - nameStart);
                if (seen.insert({name, metalSlot}).second) {
                    variableSlots.push_back({std::move(name), metalSlot});
                }
            }
            search += attr.size();
        }
    };

    for (std::uint32_t slot : metalTextureSlots) {
        collectAtAttr("[[texture(" + std::to_string(slot) + ")]]", slot);
        collectAtAttr("[[id(" + std::to_string(slot) + ")]]", slot);
    }

    return variableSlots;
}

bool rewriteMultisampleStorageImageWritesToSidecars(
    std::string& msl,
    const std::vector<std::uint32_t>& metalTextureSlots,
    const std::vector<std::uint32_t>& arrayMetalTextureSlots) {
    struct StorageMSVar {
        std::string name;
        std::uint32_t metalSlot = 0;
        bool arrayed = false;
    };
    std::vector<StorageMSVar> variables;
    std::set<std::pair<std::string, std::uint32_t>> seen;
    const std::set<std::uint32_t> arraySlots(
        arrayMetalTextureSlots.begin(), arrayMetalTextureSlots.end());
    bool changed = false;

    auto collectAndRetargetAtAttr =
        [&](const std::string& attr, std::uint32_t metalSlot) {
        std::size_t search = 0;
        while ((search = msl.find(attr, search)) != std::string::npos) {
            const std::size_t lineStart = msl.rfind('\n', search);
            const std::size_t lineBegin =
                (lineStart == std::string::npos) ? 0 : lineStart + 1u;
            auto validTypePos = [&](std::size_t pos,
                                    std::size_t len) -> bool {
                return pos != std::string::npos &&
                    pos >= lineBegin &&
                    pos < search &&
                    (pos == 0 || !isIdentifierChar(msl[pos - 1])) &&
                    (pos + len >= msl.size() ||
                     !isIdentifierChar(msl[pos + len]));
            };
            std::size_t typePos = std::string::npos;
            bool arrayedByType = false;
            const std::size_t arrayTypeLen =
                std::strlen("texture2d_ms_array");
            const std::size_t plainTypeLen = std::strlen("texture2d_ms");
            const std::size_t arrayTypePos =
                msl.rfind("texture2d_ms_array", search);
            if (validTypePos(arrayTypePos, arrayTypeLen)) {
                typePos = arrayTypePos;
                arrayedByType = true;
            }
            const std::size_t plainTypePos =
                msl.rfind("texture2d_ms", search);
            if (validTypePos(plainTypePos, plainTypeLen) &&
                (typePos == std::string::npos || plainTypePos > typePos)) {
                typePos = plainTypePos;
                arrayedByType = false;
            }
            if (typePos == std::string::npos) {
                search += attr.size();
                continue;
            }
            const bool arrayed =
                arrayedByType ||
                arraySlots.find(metalSlot) != arraySlots.end();
            const std::size_t typeNameLen = arrayed
                ? arrayTypeLen
                : plainTypeLen;
            const std::size_t typeTemplate = msl.find('<', typePos);
            if (typeTemplate == std::string::npos || typeTemplate > search) {
                search += attr.size();
                continue;
            }
            const std::size_t typeEnd = msl.find('>', typeTemplate);
            if (typeEnd == std::string::npos || typeEnd > search) {
                search += attr.size();
                continue;
            }
            const bool writable =
                msl.find("access::write", typeTemplate) < typeEnd ||
                msl.find("access::read_write", typeTemplate) < typeEnd;
            if (!writable) {
                search += attr.size();
                continue;
            }

            std::size_t nameStart = typeEnd + 1;
            while (nameStart < search &&
                   std::isspace(static_cast<unsigned char>(msl[nameStart]))) {
                ++nameStart;
            }
            std::size_t nameEnd = nameStart;
            while (nameEnd < search && isIdentifierChar(msl[nameEnd])) {
                ++nameEnd;
            }
            if (nameEnd > nameStart) {
                std::string name = msl.substr(nameStart, nameEnd - nameStart);
                if (seen.insert({name, metalSlot}).second) {
                    variables.push_back({std::move(name), metalSlot, arrayed});
                }
            }

            msl.replace(typePos, typeNameLen, "texture2d_array");
            const std::ptrdiff_t delta =
                static_cast<std::ptrdiff_t>(std::strlen("texture2d_array")) -
                static_cast<std::ptrdiff_t>(typeNameLen);
            search = static_cast<std::size_t>(
                static_cast<std::ptrdiff_t>(search) + delta) + attr.size();
            changed = true;
        }
    };

    for (std::uint32_t slot : metalTextureSlots) {
        collectAndRetargetAtAttr(
            "[[texture(" + std::to_string(slot) + ")]]", slot);
        collectAndRetargetAtAttr(
            "[[id(" + std::to_string(slot) + ")]]", slot);
    }
    {
        std::set<std::uint32_t> fallbackTextureSlots;
        std::set<std::uint32_t> fallbackIdSlots;
        std::size_t typePos = 0;
        while ((typePos = msl.find("texture2d_ms", typePos)) !=
               std::string::npos) {
            const std::size_t templateStart = msl.find('<', typePos);
            const std::size_t templateEnd = msl.find('>', templateStart);
            if (templateStart == std::string::npos ||
                templateEnd == std::string::npos) {
                typePos += std::strlen("texture2d_ms");
                continue;
            }
            const bool writable =
                msl.find("access::write", templateStart) < templateEnd ||
                msl.find("access::read_write", templateStart) < templateEnd;
            if (!writable) {
                typePos += std::strlen("texture2d_ms");
                continue;
            }
            const std::size_t paramEnd =
                msl.find_first_of(",)", templateEnd);
            auto collectSlot = [&](const char* attrPrefix,
                                   std::set<std::uint32_t>& slots) {
                const std::size_t attr = msl.find(attrPrefix, templateEnd);
                if (attr == std::string::npos ||
                    (paramEnd != std::string::npos && attr > paramEnd)) {
                    return;
                }
                std::uint32_t slot = 0;
                std::size_t after = 0;
                if (parseUnsignedAfter(
                        msl,
                        attr + std::strlen(attrPrefix),
                        slot,
                        &after)) {
                    slots.insert(slot);
                }
            };
            collectSlot("[[texture(", fallbackTextureSlots);
            collectSlot("[[id(", fallbackIdSlots);
            typePos = templateEnd + 1;
        }
        for (std::uint32_t slot : fallbackTextureSlots) {
            collectAndRetargetAtAttr(
                "[[texture(" + std::to_string(slot) + ")]]", slot);
        }
        for (std::uint32_t slot : fallbackIdSlots) {
            collectAndRetargetAtAttr(
                "[[id(" + std::to_string(slot) + ")]]", slot);
        }
    }

    auto retargetVariableDeclarations =
        [&](const std::string& varName) {
        std::size_t namePos = 0;
        while ((namePos = msl.find(varName, namePos)) != std::string::npos) {
            if ((namePos > 0 && isIdentifierChar(msl[namePos - 1])) ||
                (namePos + varName.size() < msl.size() &&
                 isIdentifierChar(msl[namePos + varName.size()]))) {
                namePos += varName.size();
                continue;
            }
            const std::size_t lineStart = msl.rfind('\n', namePos);
            std::size_t segmentBegin =
                (lineStart == std::string::npos) ? 0 : lineStart + 1u;
            const std::size_t paren = msl.rfind('(', namePos);
            if (paren != std::string::npos && paren >= segmentBegin) {
                segmentBegin = paren + 1u;
            }

            const std::size_t arrayTypeLen =
                std::strlen("texture2d_ms_array");
            const std::size_t plainTypeLen = std::strlen("texture2d_ms");
            std::size_t typePos =
                msl.rfind("texture2d_ms_array", namePos);
            std::size_t typeLen = arrayTypeLen;
            if (typePos == std::string::npos || typePos < segmentBegin ||
                typePos > namePos) {
                typePos = msl.rfind("texture2d_ms", namePos);
                typeLen = plainTypeLen;
            }
            if (typePos == std::string::npos || typePos < segmentBegin ||
                typePos > namePos) {
                namePos += varName.size();
                continue;
            }
            const std::size_t typeTemplate = msl.find('<', typePos);
            const std::size_t typeEnd = msl.find('>', typeTemplate);
            if (typeTemplate == std::string::npos ||
                typeEnd == std::string::npos ||
                typeEnd > namePos) {
                namePos += varName.size();
                continue;
            }
            msl.replace(typePos, typeLen, "texture2d_array");
            namePos += varName.size();
            changed = true;
        }
    };

    for (const auto& var : variables) {
        retargetVariableDeclarations(var.name);
    }

    auto identifierBeforeMember =
        [](const std::string& expr,
           const std::string& member) -> std::string {
        const std::size_t memberPos = expr.find(member);
        if (memberPos == std::string::npos) {
            return {};
        }
        std::size_t nameBegin = memberPos;
        while (nameBegin > 0 && isIdentifierChar(expr[nameBegin - 1])) {
            --nameBegin;
        }
        if (nameBegin == memberPos) {
            return {};
        }
        return expr.substr(nameBegin, memberPos - nameBegin);
    };
    auto findVectorTempInitializer =
        [&](const std::string& tempName,
            std::size_t before,
            std::string& xy,
            std::string& z) -> bool {
        if (tempName.empty()) {
            return false;
        }
        for (const char* ctor : {"int3(", "uint3("}) {
            const std::string needle = tempName + " = " + ctor;
            const std::size_t assign = msl.rfind(needle, before);
            if (assign == std::string::npos) {
                continue;
            }
            if (assign > 0 && isIdentifierChar(msl[assign - 1])) {
                continue;
            }
            const std::size_t open =
                assign + tempName.size() + std::strlen(" = ");
            std::size_t close = std::string::npos;
            if (!findMatchingParen(msl, open + std::strlen(ctor) - 1u, close)) {
                continue;
            }
            const auto ctorArgs = splitTopLevelCommas(
                msl.substr(open + std::strlen(ctor),
                           close - open - std::strlen(ctor)));
            if (ctorArgs.size() < 2u) {
                continue;
            }
            xy = ctorArgs[0];
            z = ctorArgs[1];
            return true;
        }
        return false;
    };
    auto implicitArraySampleKey =
        [&](const std::string& coord,
            const std::string& layer,
            std::size_t before) -> std::string {
        std::string keyCoord = coord;
        std::string keyLayer = layer;
        const std::string coordTemp =
            identifierBeforeMember(coord, ".xy");
        const std::string layerTemp =
            identifierBeforeMember(layer, ".z");
        std::string sourceCoord;
        std::string sourceLayer;
        if (!layerTemp.empty() &&
            findVectorTempInitializer(
                layerTemp, before, sourceCoord, sourceLayer)) {
            keyLayer = sourceLayer;
            if (!coordTemp.empty() && coordTemp == layerTemp) {
                keyCoord = sourceCoord;
            }
        }
        return keyCoord + "|" + keyLayer;
    };

    for (const auto& var : variables) {
        const std::string sampleCountElement =
            "appgl_ms_storage_image_samples[" +
            std::to_string(var.metalSlot) + "]";
        const std::string sampleCount =
            "max(" + sampleCountElement + ", 1u)";
        const std::string needle = var.name + ".write(";
        std::unordered_map<std::string, std::uint32_t> implicitSampleByLayer;
        std::size_t pos = 0;
        while ((pos = msl.find(needle, pos)) != std::string::npos) {
            if (pos > 0 && isIdentifierChar(msl[pos - 1])) {
                pos += needle.size();
                continue;
            }
            const std::size_t open = pos + needle.size() - 1u;
            std::size_t close = std::string::npos;
            if (!findMatchingParen(msl, open, close)) {
                break;
            }

            const auto args = splitTopLevelCommas(
                msl.substr(open + 1u, close - open - 1u));
            if ((!var.arrayed && args.size() < 2u) ||
                (var.arrayed && args.size() < 3u)) {
                pos = close + 1u;
                continue;
            }

            const std::string value = args[0];
            const std::string coord = args[1];
            const std::string layer = var.arrayed ? args[2] : std::string("0u");
            std::string sample;
            if ((!var.arrayed && args.size() >= 3u) ||
                (var.arrayed && args.size() >= 4u)) {
                sample = var.arrayed ? args[3] : args[2];
            } else if (msl.find("gl_SampleID") != std::string::npos) {
                sample = "gl_SampleID";
            } else {
                const std::string key = var.arrayed
                    ? implicitArraySampleKey(coord, layer, pos)
                    : coord + "|" + layer;
                const std::uint32_t ordinal = implicitSampleByLayer[key]++;
                sample = std::to_string(ordinal) + "u";
            }

            const std::string sidecarSlice = var.arrayed
                ? "(uint(" + layer + ") * " + sampleCount +
                      " + uint(" + sample + "))"
                : "(uint(" + sample + ") + (" + sampleCountElement + " * 0u))";
            const std::string replacement =
                var.name + ".write(" + value + ", " + coord +
                ", " + sidecarSlice + ")";
            msl.replace(pos, close + 1u - pos, replacement);
            pos += replacement.size();
            changed = true;
        }
    }

    return changed;
}

bool rewriteMultisampleStorageImageReadsFromSidecars(
    std::string& msl,
    const std::vector<std::uint32_t>& metalTextureSlots,
    const std::vector<std::uint32_t>& arrayMetalTextureSlots) {
    struct StorageMSVar {
        std::string name;
        std::uint32_t metalSlot = 0;
        bool arrayed = false;
    };
    std::vector<StorageMSVar> variables;
    std::set<std::pair<std::string, std::uint32_t>> seen;
    const std::set<std::uint32_t> arraySlots(
        arrayMetalTextureSlots.begin(), arrayMetalTextureSlots.end());
    bool changed = false;

    auto collectAndRetargetAtAttr =
        [&](const std::string& attr, std::uint32_t metalSlot) {
        std::size_t search = 0;
        while ((search = msl.find(attr, search)) != std::string::npos) {
            const std::size_t lineStart = msl.rfind('\n', search);
            const std::size_t lineBegin =
                (lineStart == std::string::npos) ? 0 : lineStart + 1u;
            auto validTypePos = [&](std::size_t pos,
                                    std::size_t len) -> bool {
                return pos != std::string::npos &&
                    pos >= lineBegin &&
                    pos < search &&
                    (pos == 0 || !isIdentifierChar(msl[pos - 1])) &&
                    (pos + len >= msl.size() ||
                     !isIdentifierChar(msl[pos + len]));
            };
            std::size_t typePos = std::string::npos;
            bool arrayedByType = false;
            const std::size_t arrayTypeLen =
                std::strlen("texture2d_ms_array");
            const std::size_t plainTypeLen = std::strlen("texture2d_ms");
            const std::size_t arrayTypePos =
                msl.rfind("texture2d_ms_array", search);
            if (validTypePos(arrayTypePos, arrayTypeLen)) {
                typePos = arrayTypePos;
                arrayedByType = true;
            }
            const std::size_t plainTypePos =
                msl.rfind("texture2d_ms", search);
            if (validTypePos(plainTypePos, plainTypeLen) &&
                (typePos == std::string::npos || plainTypePos > typePos)) {
                typePos = plainTypePos;
                arrayedByType = false;
            }
            if (typePos == std::string::npos) {
                search += attr.size();
                continue;
            }
            const bool arrayed =
                arrayedByType ||
                arraySlots.find(metalSlot) != arraySlots.end();
            const std::size_t typeTemplate = msl.find('<', typePos);
            if (typeTemplate == std::string::npos || typeTemplate > search) {
                search += attr.size();
                continue;
            }
            const std::size_t typeEnd = msl.find('>', typeTemplate);
            if (typeEnd == std::string::npos || typeEnd > search) {
                search += attr.size();
                continue;
            }
            const bool readonly =
                msl.find("access::read", typeTemplate) < typeEnd &&
                msl.find("access::read_write", typeTemplate) >= typeEnd;
            if (!readonly) {
                search += attr.size();
                continue;
            }

            std::size_t nameStart = typeEnd + 1;
            while (nameStart < search &&
                   std::isspace(static_cast<unsigned char>(msl[nameStart]))) {
                ++nameStart;
            }
            std::size_t nameEnd = nameStart;
            while (nameEnd < search && isIdentifierChar(msl[nameEnd])) {
                ++nameEnd;
            }
            if (nameEnd > nameStart) {
                std::string name = msl.substr(nameStart, nameEnd - nameStart);
                if (seen.insert({name, metalSlot}).second) {
                    variables.push_back({std::move(name), metalSlot, arrayed});
                }
            }

            search += attr.size();
        }
    };

    for (std::uint32_t slot : metalTextureSlots) {
        collectAndRetargetAtAttr(
            "[[texture(" + std::to_string(slot) + ")]]", slot);
        collectAndRetargetAtAttr(
            "[[id(" + std::to_string(slot) + ")]]", slot);
    }

    for (const auto& var : variables) {
        const std::string sampleCountElement =
            "appgl_ms_storage_image_samples[" +
            std::to_string(var.metalSlot) + "]";
        const std::string sampleCount =
            "max(" + sampleCountElement + ", 1u)";
        const std::string sidecarName =
            "appgl_ms_storage_read_sidecar_" +
            std::to_string(var.metalSlot);
        const std::string needle = var.name + ".read(";
        std::size_t pos = 0;
        while ((pos = msl.find(needle, pos)) != std::string::npos) {
            if (pos > 0 && isIdentifierChar(msl[pos - 1])) {
                pos += needle.size();
                continue;
            }
            const std::size_t open = pos + needle.size() - 1u;
            std::size_t close = std::string::npos;
            if (!findMatchingParen(msl, open, close)) {
                break;
            }

            const std::string original = msl.substr(pos, close - pos + 1u);
            const auto args = splitTopLevelCommas(
                msl.substr(open + 1u, close - open - 1u));
            if ((!var.arrayed && args.size() < 2u) ||
                (var.arrayed && args.size() < 3u)) {
                pos = close + 1u;
                continue;
            }

            const std::string coord = args[0];
            const std::string sample = var.arrayed ? args[2] : args[1];
            const std::string sidecarSlice = var.arrayed
                ? "(uint(" + args[1] + ") * " + sampleCount +
                      " + uint(" + sample + "))"
                : "uint(" + sample + ")";
            const std::string replacement =
                "((" + sampleCountElement + " == 0u) ? " + original +
                " : " + sidecarName + ".read(" + coord + ", " +
                sidecarSlice + "))";
            msl.replace(pos, close + 1u - pos, replacement);
            pos += replacement.size();
            changed = true;
        }
    }

    return changed;
}

bool rewriteMultisampleStorageImageArraySizes(
    std::string& msl,
    const std::vector<std::uint32_t>& metalTextureSlots) {
    bool changed = false;
    const auto variableSlots = collectTextureVariableSlotsForMetalSlots(
        msl, metalTextureSlots, "texture2d_array");

    for (const auto& entry : variableSlots) {
        const std::string& varName = entry.first;
        const std::uint32_t metalSlot = entry.second;
        const std::string bareNeedle = varName + ".get_array_size()";
        std::size_t pos = 0;
        while ((pos = msl.find(bareNeedle, pos)) != std::string::npos) {
            std::size_t exprStart = pos;
            const std::size_t exprEnd = pos + bareNeedle.size();

            if (pos > 0 && isIdentifierChar(msl[pos - 1])) {
                pos += bareNeedle.size();
                continue;
            }
            if (pos > 0 && msl[pos - 1] == '.') {
                std::size_t prefixStart = pos - 1;
                while (prefixStart > 0 &&
                       isIdentifierChar(msl[prefixStart - 1])) {
                    --prefixStart;
                }
                if (prefixStart == pos - 1) {
                    pos += bareNeedle.size();
                    continue;
                }
                exprStart = prefixStart;
            }

            const std::string expr = msl.substr(exprStart, exprEnd - exprStart);
            if (expr.find("appgl_ms_storage_image_samples") != std::string::npos) {
                pos = exprEnd;
                continue;
            }
            const std::string replacement =
                "(" + expr + " / max(appgl_ms_storage_image_samples[" +
                std::to_string(metalSlot) + "], 1u))";
            msl.replace(exprStart, exprEnd - exprStart, replacement);
            pos = exprStart + replacement.size();
            changed = true;
        }
    }

    return changed;
}

bool rewriteMultisampleStorageImageSampleQueries(
    std::string& msl,
    const std::vector<std::uint32_t>& metalTextureSlots) {
    bool changed = false;
    const auto variableSlots = collectTextureVariableSlotsForMetalSlots(
        msl, metalTextureSlots, "texture2d");

    for (const auto& entry : variableSlots) {
        const std::string& varName = entry.first;
        const std::uint32_t metalSlot = entry.second;
        const std::string bareNeedle = varName + ".get_num_samples()";
        std::size_t pos = 0;
        while ((pos = msl.find(bareNeedle, pos)) != std::string::npos) {
            std::size_t exprStart = pos;
            const std::size_t exprEnd = pos + bareNeedle.size();

            if (pos > 0 && isIdentifierChar(msl[pos - 1])) {
                pos += bareNeedle.size();
                continue;
            }
            if (pos > 0 && msl[pos - 1] == '.') {
                std::size_t prefixStart = pos - 1;
                while (prefixStart > 0 &&
                       isIdentifierChar(msl[prefixStart - 1])) {
                    --prefixStart;
                }
                if (prefixStart == pos - 1) {
                    pos += bareNeedle.size();
                    continue;
                }
                exprStart = prefixStart;
            }

            const std::string expr = msl.substr(exprStart, exprEnd - exprStart);
            if (expr.find("appgl_ms_storage_image_samples") != std::string::npos) {
                pos = exprEnd;
                continue;
            }
            const std::string replacement =
                "appgl_ms_storage_image_samples[" +
                std::to_string(metalSlot) + "]";
            msl.replace(exprStart, exprEnd - exprStart, replacement);
            pos = exprStart + replacement.size();
            changed = true;
        }

        const std::string shimNeedle =
            "_appgl_imageSamples_" + varName + "(";
        pos = 0;
        while ((pos = msl.find(shimNeedle, pos)) != std::string::npos) {
            if (pos > 0 && isIdentifierChar(msl[pos - 1])) {
                pos += shimNeedle.size();
                continue;
            }
            const std::size_t open = pos + shimNeedle.size() - 1u;
            std::size_t close = std::string::npos;
            if (!findMatchingParen(msl, open, close)) {
                pos += shimNeedle.size();
                continue;
            }
            std::size_t afterCall = close + 1u;
            while (afterCall < msl.size() &&
                   std::isspace(static_cast<unsigned char>(msl[afterCall]))) {
                ++afterCall;
            }
            if (afterCall < msl.size() && msl[afterCall] == '{') {
                pos += shimNeedle.size();
                continue;
            }
            const std::string replacement =
                "appgl_ms_storage_image_samples[" +
                std::to_string(metalSlot) + "]";
            msl.replace(pos, close + 1u - pos, replacement);
            pos += replacement.size();
            changed = true;
        }
    }

    return changed;
}

bool rewriteAppglImageSamplesShimQueries(std::string& msl) {
    static constexpr const char* kPrefix = "_appgl_imageSamples_";
    static constexpr std::size_t kPrefixLen =
        sizeof("_appgl_imageSamples_") - 1u;
    bool changed = false;

    auto findTextureSlotForName =
        [&](const std::string& varName, std::uint32_t& slot) -> bool {
        std::size_t pos = 0;
        while ((pos = msl.find(varName, pos)) != std::string::npos) {
            if ((pos > 0 && isIdentifierChar(msl[pos - 1])) ||
                (pos + varName.size() < msl.size() &&
                 isIdentifierChar(msl[pos + varName.size()]))) {
                pos += varName.size();
                continue;
            }
            std::size_t cursor = pos + varName.size();
            while (cursor < msl.size() &&
                   std::isspace(static_cast<unsigned char>(msl[cursor]))) {
                ++cursor;
            }
            static constexpr const char* kTextureAttr = "[[texture(";
            if (cursor >= msl.size() ||
                msl.compare(cursor, std::strlen(kTextureAttr), kTextureAttr) !=
                    0) {
                pos += varName.size();
                continue;
            }
            return parseUnsignedAfter(
                msl, cursor + std::strlen(kTextureAttr), slot, nullptr);
        }
        return false;
    };

    std::size_t pos = 0;
    while ((pos = msl.find(kPrefix, pos)) != std::string::npos) {
        if (pos > 0 && isIdentifierChar(msl[pos - 1])) {
            pos += kPrefixLen;
            continue;
        }
        std::size_t nameEnd = pos + kPrefixLen;
        while (nameEnd < msl.size() && isIdentifierChar(msl[nameEnd])) {
            ++nameEnd;
        }
        if (nameEnd == pos + kPrefixLen ||
            nameEnd >= msl.size() ||
            msl[nameEnd] != '(') {
            pos += kPrefixLen;
            continue;
        }
        std::size_t close = std::string::npos;
        if (!findMatchingParen(msl, nameEnd, close)) {
            pos += kPrefixLen;
            continue;
        }
        std::size_t afterCall = close + 1u;
        while (afterCall < msl.size() &&
               std::isspace(static_cast<unsigned char>(msl[afterCall]))) {
            ++afterCall;
        }
        if (afterCall < msl.size() && msl[afterCall] == '{') {
            pos += kPrefixLen;
            continue;
        }

        const std::string varName =
            msl.substr(pos + kPrefixLen, nameEnd - pos - kPrefixLen);
        std::uint32_t slot = 0;
        if (!findTextureSlotForName(varName, slot)) {
            pos += kPrefixLen;
            continue;
        }
        const std::string replacement =
            "appgl_ms_storage_image_samples[" + std::to_string(slot) + "]";
        msl.replace(pos, close + 1u - pos, replacement);
        pos += replacement.size();
        changed = true;
    }

    return changed;
}

bool findMatchingBrace(const std::string& text,
                       std::size_t open,
                       std::size_t& close) {
    if (open >= text.size() || text[open] != '{') {
        return false;
    }
    int depth = 1;
    for (std::size_t i = open + 1; i < text.size(); ++i) {
        if (text[i] == '{') {
            ++depth;
        } else if (text[i] == '}') {
            --depth;
            if (depth == 0) {
                close = i;
                return true;
            }
        }
    }
    return false;
}

struct MslFunctionDefinition {
    std::string name;
    std::size_t paramOpen = 0;
    std::size_t paramClose = 0;
    std::size_t bodyOpen = 0;
    std::size_t bodyClose = 0;
};

std::vector<MslFunctionDefinition> findTopLevelFunctionDefinitions(
    const std::string& msl) {
    std::vector<MslFunctionDefinition> functions;
    int braceDepth = 0;
    for (std::size_t i = 0; i < msl.size(); ++i) {
        const char ch = msl[i];
        if (ch == '{') {
            ++braceDepth;
            continue;
        }
        if (ch == '}') {
            if (braceDepth > 0) {
                --braceDepth;
            }
            continue;
        }
        if (ch != '(' || braceDepth != 0) {
            continue;
        }

        std::size_t nameEnd = i;
        while (nameEnd > 0 &&
               std::isspace(static_cast<unsigned char>(msl[nameEnd - 1]))) {
            --nameEnd;
        }
        std::size_t nameBegin = nameEnd;
        while (nameBegin > 0 && isIdentifierChar(msl[nameBegin - 1])) {
            --nameBegin;
        }
        if (nameBegin == nameEnd) {
            continue;
        }

        std::size_t paramClose = 0;
        if (!findMatchingParen(msl, i, paramClose)) {
            continue;
        }
        std::size_t afterParams = paramClose + 1;
        while (afterParams < msl.size() &&
               std::isspace(static_cast<unsigned char>(msl[afterParams]))) {
            ++afterParams;
        }
        if (afterParams >= msl.size() || msl[afterParams] != '{') {
            i = paramClose;
            continue;
        }
        std::size_t bodyClose = 0;
        if (!findMatchingBrace(msl, afterParams, bodyClose)) {
            continue;
        }

        MslFunctionDefinition fn;
        fn.name = msl.substr(nameBegin, nameEnd - nameBegin);
        fn.paramOpen = i;
        fn.paramClose = paramClose;
        fn.bodyOpen = afterParams;
        fn.bodyClose = bodyClose;
        functions.push_back(std::move(fn));
        i = bodyClose;
    }
    return functions;
}

bool containsFunctionCallInRange(const std::string& text,
                                 std::size_t begin,
                                 std::size_t end,
                                 const std::string& callee) {
    std::size_t pos = begin;
    while ((pos = text.find(callee, pos)) != std::string::npos && pos < end) {
        const std::size_t afterName = pos + callee.size();
        if ((pos > 0 && isIdentifierChar(text[pos - 1])) ||
            (afterName < text.size() && isIdentifierChar(text[afterName]))) {
            pos = afterName;
            continue;
        }
        std::size_t open = afterName;
        while (open < end &&
               std::isspace(static_cast<unsigned char>(text[open]))) {
            ++open;
        }
        if (open >= end || text[open] != '(') {
            pos = afterName;
            continue;
        }
        std::size_t close = 0;
        if (!findMatchingParen(text, open, close)) {
            return false;
        }
        return close <= end;
    }
    return false;
}

void threadTextureReductionModesThroughHelpers(std::string& msl,
                                               const std::string& paramName) {
    const std::vector<MslFunctionDefinition> functions =
        findTopLevelFunctionDefinitions(msl);
    if (functions.empty()) {
        return;
    }

    std::unordered_set<std::string> needsModes;
    for (const auto& fn : functions) {
        const std::string body =
            msl.substr(fn.bodyOpen + 1, fn.bodyClose - fn.bodyOpen - 1);
        if (body.find(paramName) != std::string::npos) {
            needsModes.insert(fn.name);
        }
    }

    bool changed = true;
    while (changed) {
        changed = false;
        for (const auto& fn : functions) {
            if (needsModes.find(fn.name) != needsModes.end()) {
                continue;
            }
            for (const auto& callee : needsModes) {
                if (containsFunctionCallInRange(
                        msl, fn.bodyOpen + 1, fn.bodyClose, callee)) {
                    needsModes.insert(fn.name);
                    changed = true;
                    break;
                }
            }
        }
    }
    if (needsModes.empty()) {
        return;
    }

    struct Insertion {
        std::size_t pos = 0;
        std::string text;
    };
    std::vector<Insertion> insertions;
    const std::string helperParam = "constant uint* " + paramName;
    for (const auto& fn : functions) {
        for (const auto& callee : needsModes) {
            if (callee == fn.name && callee != "main0") {
                continue;
            }
            std::size_t pos = fn.bodyOpen + 1;
            while ((pos = msl.find(callee, pos)) != std::string::npos &&
                   pos < fn.bodyClose) {
                const std::size_t afterName = pos + callee.size();
                if ((pos > 0 && isIdentifierChar(msl[pos - 1])) ||
                    (afterName < msl.size() && isIdentifierChar(msl[afterName]))) {
                    pos = afterName;
                    continue;
                }
                std::size_t open = afterName;
                while (open < fn.bodyClose &&
                       std::isspace(static_cast<unsigned char>(msl[open]))) {
                    ++open;
                }
                if (open >= fn.bodyClose || msl[open] != '(') {
                    pos = afterName;
                    continue;
                }
                std::size_t close = 0;
                if (!findMatchingParen(msl, open, close) || close > fn.bodyClose) {
                    break;
                }
                const std::string args = msl.substr(open + 1, close - open - 1);
                if (args.find(paramName) == std::string::npos) {
                    const std::string trimmed = trimCopy(args);
                    insertions.push_back({
                        close,
                        trimmed.empty() ? paramName : ", " + paramName});
                }
                pos = close + 1;
            }
        }

        if (fn.name == "main0" ||
            needsModes.find(fn.name) == needsModes.end()) {
            continue;
        }
        const std::string params =
            msl.substr(fn.paramOpen + 1, fn.paramClose - fn.paramOpen - 1);
        if (params.find(paramName) != std::string::npos) {
            continue;
        }
        insertions.push_back({
            fn.paramClose,
            trimCopy(params).empty() ? helperParam : ", " + helperParam});
    }

    std::sort(insertions.begin(), insertions.end(),
              [](const Insertion& a, const Insertion& b) {
                  return a.pos > b.pos;
              });
    for (const auto& insertion : insertions) {
        msl.insert(insertion.pos, insertion.text);
    }
}

void threadNamedParameterThroughHelpers(std::string& msl,
                                        const std::string& paramName,
                                        const std::string& helperParam) {
    const std::vector<MslFunctionDefinition> functions =
        findTopLevelFunctionDefinitions(msl);
    if (functions.empty()) {
        return;
    }

    std::unordered_set<std::string> needsParam;
    for (const auto& fn : functions) {
        const std::string body =
            msl.substr(fn.bodyOpen + 1, fn.bodyClose - fn.bodyOpen - 1);
        if (body.find(paramName) != std::string::npos) {
            needsParam.insert(fn.name);
        }
    }

    bool changed = true;
    while (changed) {
        changed = false;
        for (const auto& fn : functions) {
            if (needsParam.find(fn.name) != needsParam.end()) {
                continue;
            }
            for (const auto& callee : needsParam) {
                if (containsFunctionCallInRange(
                        msl, fn.bodyOpen + 1, fn.bodyClose, callee)) {
                    needsParam.insert(fn.name);
                    changed = true;
                    break;
                }
            }
        }
    }
    if (needsParam.empty()) {
        return;
    }

    struct Insertion {
        std::size_t pos = 0;
        std::string text;
    };
    std::vector<Insertion> insertions;
    for (const auto& fn : functions) {
        for (const auto& callee : needsParam) {
            if (callee == fn.name && callee != "main0") {
                continue;
            }
            std::size_t pos = fn.bodyOpen + 1;
            while ((pos = msl.find(callee, pos)) != std::string::npos &&
                   pos < fn.bodyClose) {
                const std::size_t afterName = pos + callee.size();
                if ((pos > 0 && isIdentifierChar(msl[pos - 1])) ||
                    (afterName < msl.size() &&
                     isIdentifierChar(msl[afterName]))) {
                    pos = afterName;
                    continue;
                }
                std::size_t open = afterName;
                while (open < fn.bodyClose &&
                       std::isspace(static_cast<unsigned char>(msl[open]))) {
                    ++open;
                }
                if (open >= fn.bodyClose || msl[open] != '(') {
                    pos = afterName;
                    continue;
                }
                std::size_t close = 0;
                if (!findMatchingParen(msl, open, close) ||
                    close > fn.bodyClose) {
                    break;
                }
                const std::string args =
                    msl.substr(open + 1, close - open - 1);
                if (args.find(paramName) == std::string::npos) {
                    const std::string trimmed = trimCopy(args);
                    insertions.push_back({
                        close,
                        trimmed.empty() ? paramName : ", " + paramName});
                }
                pos = close + 1;
            }
        }

        if (fn.name == "main0" ||
            needsParam.find(fn.name) == needsParam.end()) {
            continue;
        }
        const std::string params =
            msl.substr(fn.paramOpen + 1, fn.paramClose - fn.paramOpen - 1);
        if (params.find(paramName) != std::string::npos) {
            continue;
        }
        insertions.push_back({
            fn.paramClose,
            trimCopy(params).empty() ? helperParam : ", " + helperParam});
    }

    std::sort(insertions.begin(), insertions.end(),
              [](const Insertion& a, const Insertion& b) {
                  return a.pos > b.pos;
              });
    for (const auto& insertion : insertions) {
        msl.insert(insertion.pos, insertion.text);
    }
}

void threadMainTextureParamsThroughHelpers(std::string& msl,
                                           const std::string& paramPrefix) {
    const std::vector<MslFunctionDefinition> functions =
        findTopLevelFunctionDefinitions(msl);
    const auto mainIt =
        std::find_if(functions.begin(), functions.end(),
                     [](const MslFunctionDefinition& fn) {
                         return fn.name == "main0";
                     });
    if (mainIt == functions.end()) {
        return;
    }

    const std::vector<std::string> params = splitTopLevelCommas(
        msl.substr(mainIt->paramOpen + 1,
                   mainIt->paramClose - mainIt->paramOpen - 1));
    for (const std::string& param : params) {
        if (param.find(paramPrefix) == std::string::npos ||
            param.find("[[texture(") == std::string::npos) {
            continue;
        }
        const std::size_t attr = param.find("[[texture(");
        std::string helperParam = trimCopy(param.substr(0, attr));
        if (helperParam.empty()) {
            continue;
        }
        std::size_t nameEnd = helperParam.size();
        while (nameEnd > 0 &&
               std::isspace(static_cast<unsigned char>(
                   helperParam[nameEnd - 1]))) {
            --nameEnd;
        }
        std::size_t nameBegin = nameEnd;
        while (nameBegin > 0 && isIdentifierChar(helperParam[nameBegin - 1])) {
            --nameBegin;
        }
        if (nameBegin == nameEnd) {
            continue;
        }
        const std::string paramName =
            helperParam.substr(nameBegin, nameEnd - nameBegin);
        if (paramName.find(paramPrefix) != 0) {
            continue;
        }
        threadNamedParameterThroughHelpers(msl, paramName, helperParam);
    }
}

enum class TextureReductionTextureKind {
    Unsupported,
    Texture1D,
    Texture1DArray,
    Texture2D,
    Texture2DArray,
    Texture3D,
    TextureCube,
};

struct TextureReductionParam {
    std::string name;
    TextureReductionTextureKind kind = TextureReductionTextureKind::Unsupported;
    std::uint32_t slot = 0;
};

TextureReductionTextureKind textureReductionKindForType(const std::string& type) {
    auto isFloatTexture = [&](const char* textureName) {
        const std::string needle = std::string(textureName) + "<float";
        const std::size_t pos = type.find(needle);
        if (pos == std::string::npos) {
            return false;
        }
        const std::size_t after = pos + needle.size();
        return after < type.size() && (type[after] == '>' || type[after] == ',');
    };
    if (isFloatTexture("texture1d_array")) {
        return TextureReductionTextureKind::Texture1DArray;
    }
    if (isFloatTexture("texture1d")) {
        return TextureReductionTextureKind::Texture1D;
    }
    if (isFloatTexture("texture2d_array")) {
        return TextureReductionTextureKind::Texture2DArray;
    }
    if (isFloatTexture("texture2d")) {
        return TextureReductionTextureKind::Texture2D;
    }
    if (isFloatTexture("texture3d")) {
        return TextureReductionTextureKind::Texture3D;
    }
    if (isFloatTexture("texturecube")) {
        return TextureReductionTextureKind::TextureCube;
    }
    return TextureReductionTextureKind::Unsupported;
}

std::vector<TextureReductionParam> textureReductionParams(const std::string& msl) {
    std::size_t paramEnd = 0;
    if (!findMain0ParameterEnd(msl, paramEnd)) {
        return {};
    }
    const std::size_t mainPos = msl.find("main0(");
    if (mainPos == std::string::npos) {
        return {};
    }
    const std::size_t paramStart = mainPos + std::strlen("main0");
    const std::vector<std::string> params =
        splitTopLevelCommas(msl.substr(paramStart + 1, paramEnd - paramStart - 1));

    std::vector<TextureReductionParam> result;
    for (const std::string& param : params) {
        const std::size_t textureAttr = param.find("[[texture(");
        if (textureAttr == std::string::npos) {
            continue;
        }
        std::uint32_t slot = 0;
        std::size_t afterSlot = 0;
        if (!parseUnsignedAfter(param, textureAttr + std::strlen("[[texture("),
                                slot, &afterSlot)) {
            continue;
        }

        std::string prefix = trimCopy(param.substr(0, textureAttr));
        if (prefix.empty()) {
            continue;
        }
        std::size_t nameEnd = prefix.size();
        while (nameEnd > 0 &&
               std::isspace(static_cast<unsigned char>(prefix[nameEnd - 1]))) {
            --nameEnd;
        }
        std::size_t nameBegin = nameEnd;
        while (nameBegin > 0 && isIdentifierChar(prefix[nameBegin - 1])) {
            --nameBegin;
        }
        if (nameBegin == nameEnd) {
            continue;
        }
        TextureReductionParam parsed;
        parsed.name = prefix.substr(nameBegin, nameEnd - nameBegin);
        parsed.kind = textureReductionKindForType(prefix.substr(0, nameBegin));
        parsed.slot = slot;
        if (parsed.kind != TextureReductionTextureKind::Unsupported) {
            result.push_back(std::move(parsed));
        }
    }
    return result;
}

enum class IntegerBorderTextureKind {
    Unsupported,
    Int1D,
    UInt1D,
    Int1DArray,
    UInt1DArray,
    Int2D,
    UInt2D,
    Int2DArray,
    UInt2DArray,
    Int3D,
    UInt3D,
};

struct IntegerBorderTextureParam {
    std::string name;
    IntegerBorderTextureKind kind = IntegerBorderTextureKind::Unsupported;
    std::uint32_t slot = 0;
};

bool mslTextureTypeMatches(const std::string& type,
                           const char* textureName,
                           const char* scalarName) {
    const std::string needle =
        std::string(textureName) + "<" + scalarName;
    const std::size_t pos = type.find(needle);
    if (pos == std::string::npos) {
        return false;
    }
    const std::size_t after = pos + needle.size();
    return after < type.size() && (type[after] == '>' || type[after] == ',');
}

IntegerBorderTextureKind integerBorderKindForType(const std::string& type) {
    if (mslTextureTypeMatches(type, "texture1d_array", "int")) {
        return IntegerBorderTextureKind::Int1DArray;
    }
    if (mslTextureTypeMatches(type, "texture1d_array", "uint")) {
        return IntegerBorderTextureKind::UInt1DArray;
    }
    if (mslTextureTypeMatches(type, "texture1d", "int")) {
        return IntegerBorderTextureKind::Int1D;
    }
    if (mslTextureTypeMatches(type, "texture1d", "uint")) {
        return IntegerBorderTextureKind::UInt1D;
    }
    if (mslTextureTypeMatches(type, "texture2d_array", "int")) {
        return IntegerBorderTextureKind::Int2DArray;
    }
    if (mslTextureTypeMatches(type, "texture2d_array", "uint")) {
        return IntegerBorderTextureKind::UInt2DArray;
    }
    if (mslTextureTypeMatches(type, "texture2d", "int")) {
        return IntegerBorderTextureKind::Int2D;
    }
    if (mslTextureTypeMatches(type, "texture2d", "uint")) {
        return IntegerBorderTextureKind::UInt2D;
    }
    if (mslTextureTypeMatches(type, "texture3d", "int")) {
        return IntegerBorderTextureKind::Int3D;
    }
    if (mslTextureTypeMatches(type, "texture3d", "uint")) {
        return IntegerBorderTextureKind::UInt3D;
    }
    return IntegerBorderTextureKind::Unsupported;
}

std::vector<IntegerBorderTextureParam> integerBorderTextureParams(
    const std::string& msl) {
    std::size_t paramEnd = 0;
    if (!findMain0ParameterEnd(msl, paramEnd)) {
        return {};
    }
    const std::size_t mainPos = msl.find("main0(");
    if (mainPos == std::string::npos) {
        return {};
    }
    const std::size_t paramStart = mainPos + std::strlen("main0");
    const std::vector<std::string> params =
        splitTopLevelCommas(msl.substr(paramStart + 1, paramEnd - paramStart - 1));

    std::vector<IntegerBorderTextureParam> result;
    for (const std::string& param : params) {
        const std::size_t textureAttr = param.find("[[texture(");
        if (textureAttr == std::string::npos) {
            continue;
        }
        std::uint32_t slot = 0;
        std::size_t afterSlot = 0;
        if (!parseUnsignedAfter(param,
                                textureAttr + std::strlen("[[texture("),
                                slot,
                                &afterSlot)) {
            continue;
        }

        std::string prefix = trimCopy(param.substr(0, textureAttr));
        if (prefix.empty()) {
            continue;
        }
        std::size_t nameEnd = prefix.size();
        while (nameEnd > 0 &&
               std::isspace(static_cast<unsigned char>(prefix[nameEnd - 1]))) {
            --nameEnd;
        }
        std::size_t nameBegin = nameEnd;
        while (nameBegin > 0 && isIdentifierChar(prefix[nameBegin - 1])) {
            --nameBegin;
        }
        if (nameBegin == nameEnd) {
            continue;
        }

        IntegerBorderTextureParam parsed;
        parsed.name = prefix.substr(nameBegin, nameEnd - nameBegin);
        parsed.kind = integerBorderKindForType(prefix.substr(0, nameBegin));
        parsed.slot = slot;
        if (parsed.kind != IntegerBorderTextureKind::Unsupported) {
            result.push_back(std::move(parsed));
        }
    }
    return result;
}

const char* integerTextureBorderClampHelperSource() {
    return R"APPGL(

static inline bool appgl_integer_border_oob_1d(float coord, constant uint* modes, uint slot) {
    uint mask = modes[slot];
    return ((mask & 0x1u) != 0u) && (coord < 0.0f || coord >= 1.0f);
}

static inline bool appgl_integer_border_oob_2d(float2 coord, constant uint* modes, uint slot) {
    uint mask = modes[slot];
    return (((mask & 0x1u) != 0u) && (coord.x < 0.0f || coord.x >= 1.0f)) ||
           (((mask & 0x2u) != 0u) && (coord.y < 0.0f || coord.y >= 1.0f));
}

static inline bool appgl_integer_border_oob_2d_size(float2 coord, constant uint* modes, uint slot, uint width, uint height) {
    uint mask = modes[slot];
    bool rectCoords = (mask & 0x8u) != 0u;
    float maxX = rectCoords ? float(width) : 1.0f;
    float maxY = rectCoords ? float(height) : 1.0f;
    return (((mask & 0x1u) != 0u) && (coord.x < 0.0f || coord.x >= maxX)) ||
           (((mask & 0x2u) != 0u) && (coord.y < 0.0f || coord.y >= maxY));
}

static inline bool appgl_integer_border_oob_3d(float3 coord, constant uint* modes, uint slot) {
    uint mask = modes[slot];
    return (((mask & 0x1u) != 0u) && (coord.x < 0.0f || coord.x >= 1.0f)) ||
           (((mask & 0x2u) != 0u) && (coord.y < 0.0f || coord.y >= 1.0f)) ||
           (((mask & 0x4u) != 0u) && (coord.z < 0.0f || coord.z >= 1.0f));
}

static inline int4 appgl_texture_border_i_1d(texture1d<int> tex, sampler smp, float coord, constant uint* modes, constant int4* colors, uint slot) {
    if (appgl_integer_border_oob_1d(coord, modes, slot)) return colors[slot];
    return tex.sample(smp, coord);
}

static inline uint4 appgl_texture_border_u_1d(texture1d<uint> tex, sampler smp, float coord, constant uint* modes, constant int4* colors, uint slot) {
    if (appgl_integer_border_oob_1d(coord, modes, slot)) return as_type<uint4>(colors[slot]);
    return tex.sample(smp, coord);
}

static inline int4 appgl_texture_border_i_1d_array(texture1d_array<int> tex, sampler smp, float coord, uint layer, constant uint* modes, constant int4* colors, uint slot) {
    if (appgl_integer_border_oob_1d(coord, modes, slot)) return colors[slot];
    return tex.sample(smp, coord, layer);
}

static inline uint4 appgl_texture_border_u_1d_array(texture1d_array<uint> tex, sampler smp, float coord, uint layer, constant uint* modes, constant int4* colors, uint slot) {
    if (appgl_integer_border_oob_1d(coord, modes, slot)) return as_type<uint4>(colors[slot]);
    return tex.sample(smp, coord, layer);
}

static inline int4 appgl_texture_border_i_2d(texture2d<int> tex, sampler smp, float2 coord, constant uint* modes, constant int4* colors, uint slot) {
    if (appgl_integer_border_oob_2d_size(coord, modes, slot, tex.get_width(), tex.get_height())) return colors[slot];
    return tex.sample(smp, coord);
}

static inline uint4 appgl_texture_border_u_2d(texture2d<uint> tex, sampler smp, float2 coord, constant uint* modes, constant int4* colors, uint slot) {
    if (appgl_integer_border_oob_2d_size(coord, modes, slot, tex.get_width(), tex.get_height())) return as_type<uint4>(colors[slot]);
    return tex.sample(smp, coord);
}

static inline int4 appgl_texture_border_i_2d_array(texture2d_array<int> tex, sampler smp, float2 coord, uint layer, constant uint* modes, constant int4* colors, uint slot) {
    if (appgl_integer_border_oob_2d(coord, modes, slot)) return colors[slot];
    return tex.sample(smp, coord, layer);
}

static inline uint4 appgl_texture_border_u_2d_array(texture2d_array<uint> tex, sampler smp, float2 coord, uint layer, constant uint* modes, constant int4* colors, uint slot) {
    if (appgl_integer_border_oob_2d(coord, modes, slot)) return as_type<uint4>(colors[slot]);
    return tex.sample(smp, coord, layer);
}

static inline int4 appgl_texture_border_i_3d(texture3d<int> tex, sampler smp, float3 coord, constant uint* modes, constant int4* colors, uint slot) {
    if (appgl_integer_border_oob_3d(coord, modes, slot)) return colors[slot];
    return tex.sample(smp, coord);
}

static inline uint4 appgl_texture_border_u_3d(texture3d<uint> tex, sampler smp, float3 coord, constant uint* modes, constant int4* colors, uint slot) {
    if (appgl_integer_border_oob_3d(coord, modes, slot)) return as_type<uint4>(colors[slot]);
    return tex.sample(smp, coord);
}
)APPGL";
}

void threadIntegerTextureBorderClampParamsThroughHelpers(
    std::string& msl,
    const std::string& modesName,
    const std::string& colorsName) {
    const std::vector<MslFunctionDefinition> functions =
        findTopLevelFunctionDefinitions(msl);
    if (functions.empty()) {
        return;
    }

    std::unordered_set<std::string> needsParams;
    for (const auto& fn : functions) {
        const std::string body =
            msl.substr(fn.bodyOpen + 1, fn.bodyClose - fn.bodyOpen - 1);
        if (body.find(modesName) != std::string::npos ||
            body.find(colorsName) != std::string::npos) {
            needsParams.insert(fn.name);
        }
    }

    bool changed = true;
    while (changed) {
        changed = false;
        for (const auto& fn : functions) {
            if (needsParams.find(fn.name) != needsParams.end()) {
                continue;
            }
            for (const auto& callee : needsParams) {
                if (containsFunctionCallInRange(
                        msl, fn.bodyOpen + 1, fn.bodyClose, callee)) {
                    needsParams.insert(fn.name);
                    changed = true;
                    break;
                }
            }
        }
    }
    if (needsParams.empty()) {
        return;
    }

    struct Insertion {
        std::size_t pos = 0;
        std::string text;
    };
    std::vector<Insertion> insertions;
    const std::string helperParams =
        "constant uint* " + modesName +
        ", constant int4* " + colorsName;
    const std::string callParams = ", " + modesName + ", " + colorsName;
    for (const auto& fn : functions) {
        for (const auto& callee : needsParams) {
            if (callee == fn.name && callee != "main0") {
                continue;
            }
            std::size_t pos = fn.bodyOpen + 1;
            while ((pos = msl.find(callee, pos)) != std::string::npos &&
                   pos < fn.bodyClose) {
                const std::size_t afterName = pos + callee.size();
                if ((pos > 0 && isIdentifierChar(msl[pos - 1])) ||
                    (afterName < msl.size() && isIdentifierChar(msl[afterName]))) {
                    pos = afterName;
                    continue;
                }
                std::size_t open = afterName;
                while (open < fn.bodyClose &&
                       std::isspace(static_cast<unsigned char>(msl[open]))) {
                    ++open;
                }
                if (open >= fn.bodyClose || msl[open] != '(') {
                    pos = afterName;
                    continue;
                }
                std::size_t close = 0;
                if (!findMatchingParen(msl, open, close) || close > fn.bodyClose) {
                    break;
                }
                const std::string args = msl.substr(open + 1, close - open - 1);
                if (args.find(modesName) == std::string::npos &&
                    args.find(colorsName) == std::string::npos) {
                    const std::string trimmed = trimCopy(args);
                    insertions.push_back({
                        close,
                        trimmed.empty() ? modesName + ", " + colorsName : callParams});
                }
                pos = close + 1;
            }
        }

        if (fn.name == "main0" ||
            needsParams.find(fn.name) == needsParams.end()) {
            continue;
        }
        const std::string params =
            msl.substr(fn.paramOpen + 1, fn.paramClose - fn.paramOpen - 1);
        if (params.find(modesName) != std::string::npos ||
            params.find(colorsName) != std::string::npos) {
            continue;
        }
        insertions.push_back({
            fn.paramClose,
            trimCopy(params).empty() ? helperParams : ", " + helperParams});
    }

    std::sort(insertions.begin(), insertions.end(),
              [](const Insertion& a, const Insertion& b) {
                  return a.pos > b.pos;
              });
    for (const auto& insertion : insertions) {
        msl.insert(insertion.pos, insertion.text);
    }
}

bool injectIntegerTextureBorderClamp(std::string& msl) {
    static constexpr const char* kModesName =
        "_appgl_TextureBorderClampModes";
    static constexpr const char* kColorsName =
        "_appgl_TextureBorderClampColors";
    if (msl.find(kModesName) != std::string::npos ||
        msl.find(".sample(") == std::string::npos) {
        return false;
    }
    const std::vector<IntegerBorderTextureParam> params =
        integerBorderTextureParams(msl);
    if (params.empty()) {
        return false;
    }

    struct Replacement {
        std::size_t begin = 0;
        std::size_t end = 0;
        std::string text;
    };
    std::vector<Replacement> replacements;
    for (const IntegerBorderTextureParam& param : params) {
        const std::string needle = param.name + ".sample(";
        std::size_t pos = 0;
        while ((pos = msl.find(needle, pos)) != std::string::npos) {
            if (pos > 0 && isIdentifierChar(msl[pos - 1])) {
                pos += needle.size();
                continue;
            }
            const std::size_t open =
                pos + param.name.size() + std::strlen(".sample");
            std::size_t close = 0;
            if (!findMatchingParen(msl, open, close)) {
                pos += needle.size();
                continue;
            }
            const std::vector<std::string> args =
                splitTopLevelCommas(msl.substr(open + 1, close - open - 1));
            const std::string slot = std::to_string(param.slot) + "u";
            std::string helper;
            std::vector<std::string> helperArgs;
            switch (param.kind) {
                case IntegerBorderTextureKind::Int1D:
                    if (args.size() == 2) {
                        helper = "appgl_texture_border_i_1d";
                        helperArgs = {args[0], args[1]};
                    }
                    break;
                case IntegerBorderTextureKind::UInt1D:
                    if (args.size() == 2) {
                        helper = "appgl_texture_border_u_1d";
                        helperArgs = {args[0], args[1]};
                    }
                    break;
                case IntegerBorderTextureKind::Int1DArray:
                    if (args.size() == 3) {
                        helper = "appgl_texture_border_i_1d_array";
                        helperArgs = {args[0], args[1], args[2]};
                    }
                    break;
                case IntegerBorderTextureKind::UInt1DArray:
                    if (args.size() == 3) {
                        helper = "appgl_texture_border_u_1d_array";
                        helperArgs = {args[0], args[1], args[2]};
                    }
                    break;
                case IntegerBorderTextureKind::Int2D:
                    if (args.size() == 2) {
                        helper = "appgl_texture_border_i_2d";
                        helperArgs = {args[0], args[1]};
                    }
                    break;
                case IntegerBorderTextureKind::UInt2D:
                    if (args.size() == 2) {
                        helper = "appgl_texture_border_u_2d";
                        helperArgs = {args[0], args[1]};
                    }
                    break;
                case IntegerBorderTextureKind::Int2DArray:
                    if (args.size() == 3) {
                        helper = "appgl_texture_border_i_2d_array";
                        helperArgs = {args[0], args[1], args[2]};
                    }
                    break;
                case IntegerBorderTextureKind::UInt2DArray:
                    if (args.size() == 3) {
                        helper = "appgl_texture_border_u_2d_array";
                        helperArgs = {args[0], args[1], args[2]};
                    }
                    break;
                case IntegerBorderTextureKind::Int3D:
                    if (args.size() == 2) {
                        helper = "appgl_texture_border_i_3d";
                        helperArgs = {args[0], args[1]};
                    }
                    break;
                case IntegerBorderTextureKind::UInt3D:
                    if (args.size() == 2) {
                        helper = "appgl_texture_border_u_3d";
                        helperArgs = {args[0], args[1]};
                    }
                    break;
                case IntegerBorderTextureKind::Unsupported:
                    break;
            }

            if (!helper.empty()) {
                std::string replacement = helper + "(" + param.name;
                for (const std::string& arg : helperArgs) {
                    replacement += ", " + trimCopy(arg);
                }
                replacement += ", " + std::string(kModesName) +
                    ", " + std::string(kColorsName) +
                    ", " + slot + ")";
                replacements.push_back({pos, close + 1, std::move(replacement)});
            }
            pos = close + 1;
        }
    }
    if (replacements.empty()) {
        return false;
    }

    std::sort(replacements.begin(), replacements.end(),
              [](const Replacement& a, const Replacement& b) {
                  return a.begin > b.begin;
              });
    for (const Replacement& replacement : replacements) {
        msl.replace(replacement.begin,
                    replacement.end - replacement.begin,
                    replacement.text);
    }

    std::size_t paramEnd = 0;
    if (!findMain0ParameterEnd(msl, paramEnd)) {
        return false;
    }
    const std::uint32_t modesSlot =
        chooseFreeBufferSlot(msl, kTextureBorderClampModesPreferredBufferSlot);
    std::string withModesParam = msl;
    const std::string modesParam =
        ", constant uint* " + std::string(kModesName) +
        " [[buffer(" + std::to_string(modesSlot) + ")]]";
    withModesParam.insert(paramEnd, modesParam);
    const std::uint32_t colorsSlot =
        chooseFreeBufferSlot(withModesParam,
                             kTextureBorderClampColorsPreferredBufferSlot);
    const std::string paramsText =
        modesParam +
        ", constant int4* " + std::string(kColorsName) +
        " [[buffer(" + std::to_string(colorsSlot) + ")]]";
    msl.insert(paramEnd, paramsText);
    threadIntegerTextureBorderClampParamsThroughHelpers(
        msl, kModesName, kColorsName);

    const std::string usingNeedle = "using namespace metal;\n";
    const std::size_t usingPos = msl.find(usingNeedle);
    if (usingPos != std::string::npos) {
        msl.insert(usingPos + usingNeedle.size(),
                   integerTextureBorderClampHelperSource());
    } else {
        msl.insert(0, std::string(integerTextureBorderClampHelperSource()) + "\n");
    }
    return true;
}

std::string textureReductionHelperSource(
    const std::unordered_set<std::string>& lodBiasedHelpers) {
    std::string source = R"APPGL(

static inline float4 appgl_texred_reduce4(float4 a, float4 b, uint mode) {
    return mode == 0x8007u ? min(a, b) : max(a, b);
}

static inline float appgl_texred_center(int i, uint size) {
    uint safeSize = size == 0u ? 1u : size;
    return (float(i) + 0.5f) / float(safeSize);
}

static inline uint appgl_texred_mode(uint packedMode) {
    return packedMode & 0x7fffffffu;
}

static inline float2 appgl_texred_sample_coord_2d(float2 coord, uint packedMode) {
    return (packedMode & 0x80000000u) != 0u ? float2(coord.x, 1.0f - coord.y) : coord;
}

static inline float3 appgl_texred_sample_coord_3d(float3 coord, uint packedMode) {
    return (packedMode & 0x80000000u) != 0u ? float3(coord.x, 1.0f - coord.y, coord.z) : coord;
}

static inline int2 appgl_texred_sample_offset_2d(int2 offset, uint packedMode) {
    return (packedMode & 0x80000000u) != 0u ? int2(offset.x, -offset.y) : offset;
}

static inline int3 appgl_texred_sample_offset_3d(int3 offset, uint packedMode) {
    return (packedMode & 0x80000000u) != 0u ? int3(offset.x, -offset.y, offset.z) : offset;
}

static inline float4 appgl_texture_minmax_1d(texture1d<float> tex, sampler smp, float coord, constant uint* modes, uint slot) {
    uint mode = appgl_texred_mode(modes[slot]);
    if (mode == 0x9367u) return tex.sample(smp, coord);
    uint w = tex.get_width();
    float p = coord * float(w == 0u ? 1u : w) - 0.5f;
    int base = int(floor(p));
    float4 r = tex.sample(smp, appgl_texred_center(base, w));
    r = appgl_texred_reduce4(r, tex.sample(smp, appgl_texred_center(base + 1, w)), mode);
    return r;
}

static inline float4 appgl_texture_minmax_1d_array(texture1d_array<float> tex, sampler smp, float coord, uint layer, constant uint* modes, uint slot) {
    uint mode = appgl_texred_mode(modes[slot]);
    if (mode == 0x9367u) return tex.sample(smp, coord, layer);
    uint w = tex.get_width();
    float p = coord * float(w == 0u ? 1u : w) - 0.5f;
    int base = int(floor(p));
    float4 r = tex.sample(smp, appgl_texred_center(base, w), layer);
    r = appgl_texred_reduce4(r, tex.sample(smp, appgl_texred_center(base + 1, w), layer), mode);
    return r;
}

static inline float4 appgl_texture_minmax_2d(texture2d<float> tex, sampler smp, float2 coord, constant uint* modes, uint slot) {
    uint packedMode = modes[slot];
    uint mode = appgl_texred_mode(packedMode);
    coord = appgl_texred_sample_coord_2d(coord, packedMode);
    if (mode == 0x9367u) return tex.sample(smp, coord);
    uint w = tex.get_width();
    uint h = tex.get_height();
    float2 size = float2(float(w == 0u ? 1u : w), float(h == 0u ? 1u : h));
    int2 base = int2(floor(coord * size - float2(0.5f)));
    float2 c00 = float2(appgl_texred_center(base.x, w), appgl_texred_center(base.y, h));
    float2 c10 = float2(appgl_texred_center(base.x + 1, w), appgl_texred_center(base.y, h));
    float2 c01 = float2(appgl_texred_center(base.x, w), appgl_texred_center(base.y + 1, h));
    float2 c11 = float2(appgl_texred_center(base.x + 1, w), appgl_texred_center(base.y + 1, h));
    float4 r = tex.sample(smp, c00);
    r = appgl_texred_reduce4(r, tex.sample(smp, c10), mode);
    r = appgl_texred_reduce4(r, tex.sample(smp, c01), mode);
    r = appgl_texred_reduce4(r, tex.sample(smp, c11), mode);
    return r;
}

static inline float4 appgl_texture_minmax_2d_array(texture2d_array<float> tex, sampler smp, float2 coord, uint layer, constant uint* modes, uint slot) {
    uint packedMode = modes[slot];
    uint mode = appgl_texred_mode(packedMode);
    coord = appgl_texred_sample_coord_2d(coord, packedMode);
    if (mode == 0x9367u) return tex.sample(smp, coord, layer);
    uint w = tex.get_width();
    uint h = tex.get_height();
    float2 size = float2(float(w == 0u ? 1u : w), float(h == 0u ? 1u : h));
    int2 base = int2(floor(coord * size - float2(0.5f)));
    float2 c00 = float2(appgl_texred_center(base.x, w), appgl_texred_center(base.y, h));
    float2 c10 = float2(appgl_texred_center(base.x + 1, w), appgl_texred_center(base.y, h));
    float2 c01 = float2(appgl_texred_center(base.x, w), appgl_texred_center(base.y + 1, h));
    float2 c11 = float2(appgl_texred_center(base.x + 1, w), appgl_texred_center(base.y + 1, h));
    float4 r = tex.sample(smp, c00, layer);
    r = appgl_texred_reduce4(r, tex.sample(smp, c10, layer), mode);
    r = appgl_texred_reduce4(r, tex.sample(smp, c01, layer), mode);
    r = appgl_texred_reduce4(r, tex.sample(smp, c11, layer), mode);
    return r;
}

static inline float4 appgl_texture_minmax_3d(texture3d<float> tex, sampler smp, float3 coord, constant uint* modes, uint slot) {
    uint packedMode = modes[slot];
    uint mode = appgl_texred_mode(packedMode);
    coord = appgl_texred_sample_coord_3d(coord, packedMode);
    if (mode == 0x9367u) return tex.sample(smp, coord);
    uint w = tex.get_width();
    uint h = tex.get_height();
    uint d = tex.get_depth();
    float3 size = float3(float(w == 0u ? 1u : w), float(h == 0u ? 1u : h), float(d == 0u ? 1u : d));
    int3 base = int3(floor(coord * size - float3(0.5f)));
    float4 r = tex.sample(smp, float3(appgl_texred_center(base.x, w), appgl_texred_center(base.y, h), appgl_texred_center(base.z, d)));
    r = appgl_texred_reduce4(r, tex.sample(smp, float3(appgl_texred_center(base.x + 1, w), appgl_texred_center(base.y, h), appgl_texred_center(base.z, d))), mode);
    r = appgl_texred_reduce4(r, tex.sample(smp, float3(appgl_texred_center(base.x, w), appgl_texred_center(base.y + 1, h), appgl_texred_center(base.z, d))), mode);
    r = appgl_texred_reduce4(r, tex.sample(smp, float3(appgl_texred_center(base.x + 1, w), appgl_texred_center(base.y + 1, h), appgl_texred_center(base.z, d))), mode);
    r = appgl_texred_reduce4(r, tex.sample(smp, float3(appgl_texred_center(base.x, w), appgl_texred_center(base.y, h), appgl_texred_center(base.z + 1, d))), mode);
    r = appgl_texred_reduce4(r, tex.sample(smp, float3(appgl_texred_center(base.x + 1, w), appgl_texred_center(base.y, h), appgl_texred_center(base.z + 1, d))), mode);
    r = appgl_texred_reduce4(r, tex.sample(smp, float3(appgl_texred_center(base.x, w), appgl_texred_center(base.y + 1, h), appgl_texred_center(base.z + 1, d))), mode);
    r = appgl_texred_reduce4(r, tex.sample(smp, float3(appgl_texred_center(base.x + 1, w), appgl_texred_center(base.y + 1, h), appgl_texred_center(base.z + 1, d))), mode);
    return r;
}

struct appgl_texred_cube_coord {
    float2 uv;
    uint face;
};

static inline appgl_texred_cube_coord appgl_texred_cube_face(float3 dir) {
    float3 ad = abs(dir);
    appgl_texred_cube_coord out;
    if (ad.x >= ad.y && ad.x >= ad.z) {
        float inv = 1.0f / (ad.x > 0.000001f ? ad.x : 0.000001f);
        out.face = dir.x >= 0.0f ? 0u : 1u;
        out.uv = dir.x >= 0.0f ? float2(-dir.z, -dir.y) * inv : float2(dir.z, -dir.y) * inv;
    } else if (ad.y >= ad.x && ad.y >= ad.z) {
        float inv = 1.0f / (ad.y > 0.000001f ? ad.y : 0.000001f);
        out.face = dir.y >= 0.0f ? 2u : 3u;
        out.uv = dir.y >= 0.0f ? float2(dir.x, dir.z) * inv : float2(dir.x, -dir.z) * inv;
    } else {
        float inv = 1.0f / (ad.z > 0.000001f ? ad.z : 0.000001f);
        out.face = dir.z >= 0.0f ? 4u : 5u;
        out.uv = dir.z >= 0.0f ? float2(dir.x, -dir.y) * inv : float2(-dir.x, -dir.y) * inv;
    }
    out.uv = out.uv * 0.5f + float2(0.5f);
    return out;
}

static inline float3 appgl_texred_cube_dir(uint face, float2 uv) {
    float sc = uv.x * 2.0f - 1.0f;
    float tc = uv.y * 2.0f - 1.0f;
    if (face == 0u) return normalize(float3(1.0f, -tc, -sc));
    if (face == 1u) return normalize(float3(-1.0f, -tc, sc));
    if (face == 2u) return normalize(float3(sc, 1.0f, tc));
    if (face == 3u) return normalize(float3(sc, -1.0f, -tc));
    if (face == 4u) return normalize(float3(sc, -tc, 1.0f));
    return normalize(float3(-sc, -tc, -1.0f));
}

static inline float4 appgl_texture_minmax_cube(texturecube<float> tex, sampler smp, float3 coord, constant uint* modes, uint slot) {
    uint mode = appgl_texred_mode(modes[slot]);
    if (mode == 0x9367u) return tex.sample(smp, coord);
    uint w = tex.get_width();
    appgl_texred_cube_coord fc = appgl_texred_cube_face(coord);
    float2 size = float2(float(w == 0u ? 1u : w));
    int2 base = int2(floor(fc.uv * size - float2(0.5f)));
    float2 c00 = float2(appgl_texred_center(base.x, w), appgl_texred_center(base.y, w));
    float2 c10 = float2(appgl_texred_center(base.x + 1, w), appgl_texred_center(base.y, w));
    float2 c01 = float2(appgl_texred_center(base.x, w), appgl_texred_center(base.y + 1, w));
    float2 c11 = float2(appgl_texred_center(base.x + 1, w), appgl_texred_center(base.y + 1, w));
    float4 r = tex.sample(smp, appgl_texred_cube_dir(fc.face, c00));
    r = appgl_texred_reduce4(r, tex.sample(smp, appgl_texred_cube_dir(fc.face, c10)), mode);
    r = appgl_texred_reduce4(r, tex.sample(smp, appgl_texred_cube_dir(fc.face, c01)), mode);
    r = appgl_texred_reduce4(r, tex.sample(smp, appgl_texred_cube_dir(fc.face, c11)), mode);
    return r;
}
)APPGL";
    // Keep injected helper-local samples out of the later resource-name pass,
    // which would otherwise apply the same LOD bias a second time.
    const std::string helperTextureName = "_appgl_texred_tex";
    std::size_t textureNamePos = 0;
    while ((textureNamePos = source.find("tex", textureNamePos)) !=
           std::string::npos) {
        const std::size_t afterName = textureNamePos + std::strlen("tex");
        if ((textureNamePos == 0 ||
             !isIdentifierChar(source[textureNamePos - 1])) &&
            (afterName == source.size() ||
             !isIdentifierChar(source[afterName]))) {
            source.replace(textureNamePos,
                           std::strlen("tex"),
                           helperTextureName);
            textureNamePos += helperTextureName.size();
        } else {
            textureNamePos = afterName;
        }
    }
    if (lodBiasedHelpers.empty()) {
        return source;
    }

    struct Insertion {
        std::size_t pos = 0;
        std::string text;
    };
    std::vector<Insertion> insertions;
    const std::string sampleNeedle = helperTextureName + ".sample(";
    for (const MslFunctionDefinition& fn :
         findTopLevelFunctionDefinitions(source)) {
        if (lodBiasedHelpers.find(fn.name) == lodBiasedHelpers.end()) {
            continue;
        }
        insertions.push_back({fn.paramClose, ", float lodBias"});
        std::size_t samplePos = fn.bodyOpen + 1;
        while ((samplePos = source.find(sampleNeedle, samplePos)) !=
                   std::string::npos &&
               samplePos < fn.bodyClose) {
            const std::size_t open = samplePos +
                helperTextureName.size() + std::strlen(".sample");
            std::size_t close = 0;
            if (!findMatchingParen(source, open, close) ||
                close > fn.bodyClose) {
                break;
            }
            insertions.push_back({close, ", bias(lodBias)"});
            samplePos = close + 1;
        }
    }
    std::sort(insertions.begin(), insertions.end(),
              [](const Insertion& a, const Insertion& b) {
                  return a.pos > b.pos;
              });
    for (const Insertion& insertion : insertions) {
        source.insert(insertion.pos, insertion.text);
    }
    return source;
}

bool injectTextureReductionMinmax(std::string& msl,
                                  bool applyImplicitLodBias) {
    static constexpr const char* kParamName = "_appgl_TextureReductionModes";
    static constexpr const char* kLodBiasParamName =
        "_appgl_TextureLodBiases";
    static constexpr const char* kImplicitCorrectionName =
        "_appgl_ImplicitLodBiasCorrection";
    if (msl.find(kParamName) != std::string::npos ||
        msl.find(".sample(") == std::string::npos) {
        return false;
    }
    const std::vector<TextureReductionParam> params =
        textureReductionParams(msl);
    if (params.empty()) {
        return false;
    }

    struct Replacement {
        std::size_t begin = 0;
        std::size_t end = 0;
        std::string text;
    };
    std::vector<Replacement> replacements;
    std::unordered_set<std::string> lodBiasedHelpers;
    for (const TextureReductionParam& param : params) {
        const std::string needle = param.name + ".sample(";
        std::size_t pos = 0;
        while ((pos = msl.find(needle, pos)) != std::string::npos) {
            if (pos > 0 && isIdentifierChar(msl[pos - 1])) {
                pos += needle.size();
                continue;
            }
            const std::size_t open = pos + param.name.size() + std::strlen(".sample");
            std::size_t close = 0;
            if (!findMatchingParen(msl, open, close)) {
                pos += needle.size();
                continue;
            }
            const std::vector<std::string> args =
                splitTopLevelCommas(msl.substr(open + 1, close - open - 1));
            std::string replacement;
            bool usesReductionHelper = false;
            const std::string slot = std::to_string(param.slot) + "u";
            if (param.kind == TextureReductionTextureKind::Texture1D &&
                args.size() == 2) {
                replacement = "appgl_texture_minmax_1d(" + param.name + ", " +
                    args[0] + ", " + args[1] + ", " + kParamName + ", " + slot + ")";
                usesReductionHelper = true;
            } else if (param.kind == TextureReductionTextureKind::Texture1DArray &&
                       args.size() == 3) {
                replacement = "appgl_texture_minmax_1d_array(" + param.name + ", " +
                    args[0] + ", " + args[1] + ", " + args[2] + ", " +
                    kParamName + ", " + slot + ")";
                usesReductionHelper = true;
            } else if (param.kind == TextureReductionTextureKind::Texture2D &&
                       args.size() == 2) {
                replacement = "appgl_texture_minmax_2d(" + param.name + ", " +
                    args[0] + ", " + args[1] + ", " + kParamName + ", " + slot + ")";
                usesReductionHelper = true;
            } else if (param.kind == TextureReductionTextureKind::Texture2DArray &&
                       args.size() == 3) {
                replacement = "appgl_texture_minmax_2d_array(" + param.name + ", " +
                    args[0] + ", " + args[1] + ", " + args[2] + ", " +
                    kParamName + ", " + slot + ")";
                usesReductionHelper = true;
            } else if (param.kind == TextureReductionTextureKind::Texture3D &&
                       args.size() == 2) {
                replacement = "appgl_texture_minmax_3d(" + param.name + ", " +
                    args[0] + ", " + args[1] + ", " + kParamName + ", " + slot + ")";
                usesReductionHelper = true;
            } else if (param.kind == TextureReductionTextureKind::TextureCube &&
                       args.size() == 2) {
                replacement = "appgl_texture_minmax_cube(" + param.name + ", " +
                    args[0] + ", " + args[1] + ", " + kParamName + ", " + slot + ")";
                usesReductionHelper = true;
            } else {
                std::vector<std::string> rewrittenArgs = args;
                std::size_t firstExtraArg = 0;
                const char* coordHelper = nullptr;
                const char* offsetType = nullptr;
                const char* offsetHelper = nullptr;
                if (param.kind == TextureReductionTextureKind::Texture2D &&
                    args.size() > 2) {
                    firstExtraArg = 2;
                    coordHelper = "appgl_texred_sample_coord_2d";
                    offsetType = "int2";
                    offsetHelper = "appgl_texred_sample_offset_2d";
                } else if (param.kind == TextureReductionTextureKind::Texture2DArray &&
                           args.size() > 3) {
                    firstExtraArg = 3;
                    coordHelper = "appgl_texred_sample_coord_2d";
                    offsetType = "int2";
                    offsetHelper = "appgl_texred_sample_offset_2d";
                } else if (param.kind == TextureReductionTextureKind::Texture3D &&
                           args.size() > 2) {
                    firstExtraArg = 2;
                    coordHelper = "appgl_texred_sample_coord_3d";
                    offsetType = "int3";
                    offsetHelper = "appgl_texred_sample_offset_3d";
                }
                if (coordHelper != nullptr) {
                    rewrittenArgs[1] = std::string(coordHelper) + "(" +
                        trimCopy(rewrittenArgs[1]) + ", " + kParamName + "[" +
                        slot + "])";
                    for (std::size_t i = firstExtraArg;
                         i < rewrittenArgs.size();
                         ++i) {
                        const std::string trimmed = trimCopy(rewrittenArgs[i]);
                        std::size_t afterType = std::strlen(offsetType);
                        while (afterType < trimmed.size() &&
                               std::isspace(static_cast<unsigned char>(
                                   trimmed[afterType]))) {
                            ++afterType;
                        }
                        if (trimmed.rfind(offsetType, 0) == 0 &&
                            afterType < trimmed.size() &&
                            trimmed[afterType] == '(') {
                            rewrittenArgs[i] = std::string(offsetHelper) + "(" +
                                trimmed + ", " + kParamName + "[" + slot + "])";
                        }
                    }
                    replacement = param.name + ".sample(";
                    for (std::size_t i = 0; i < rewrittenArgs.size(); ++i) {
                        if (i > 0) {
                            replacement += ", ";
                        }
                        replacement += trimCopy(rewrittenArgs[i]);
                    }
                    replacement += ")";
                }
            }
            if (!replacement.empty()) {
                // Metal has bias sample options for 2D/3D/cube textures, but
                // not texture1d; specialize only compatible helper kinds.
                std::string helperName;
                switch (param.kind) {
                    case TextureReductionTextureKind::Texture2D:
                        helperName = "appgl_texture_minmax_2d";
                        break;
                    case TextureReductionTextureKind::Texture2DArray:
                        helperName = "appgl_texture_minmax_2d_array";
                        break;
                    case TextureReductionTextureKind::Texture3D:
                        helperName = "appgl_texture_minmax_3d";
                        break;
                    case TextureReductionTextureKind::TextureCube:
                        helperName = "appgl_texture_minmax_cube";
                        break;
                    default:
                        break;
                }
                if (usesReductionHelper && applyImplicitLodBias &&
                    !helperName.empty()) {
                    replacement.insert(
                        replacement.size() - 1,
                        ", (" + std::string(kLodBiasParamName) + "[" + slot +
                            "] + " + kImplicitCorrectionName + ")");
                    lodBiasedHelpers.insert(std::move(helperName));
                }
                replacements.push_back({pos, close + 1, std::move(replacement)});
            }
            pos = close + 1;
        }
    }
    if (replacements.empty()) {
        return false;
    }

    std::sort(replacements.begin(), replacements.end(),
              [](const Replacement& a, const Replacement& b) {
                  return a.begin > b.begin;
              });
    for (const Replacement& replacement : replacements) {
        msl.replace(replacement.begin,
                    replacement.end - replacement.begin,
                    replacement.text);
    }

    std::size_t paramEnd = 0;
    if (!findMain0ParameterEnd(msl, paramEnd)) {
        return false;
    }
    const std::uint32_t bufferSlot =
        chooseFreeBufferSlot(msl, kTextureReductionModesPreferredBufferSlot);
    const std::string param =
        ", constant uint* " + std::string(kParamName) +
        " [[buffer(" + std::to_string(bufferSlot) + ")]]";
    msl.insert(paramEnd, param);
    threadTextureReductionModesThroughHelpers(msl, kParamName);

    const std::string usingNeedle = "using namespace metal;\n";
    const std::size_t usingPos = msl.find(usingNeedle);
    const std::string helperSource =
        textureReductionHelperSource(lodBiasedHelpers);
    if (usingPos != std::string::npos) {
        msl.insert(usingPos + usingNeedle.size(), helperSource);
    } else {
        msl.insert(0, helperSource + "\n");
    }
    return true;
}

bool rewriteTextureSampleLodBiasArg(const std::string& arg,
                                     const std::string& bufferName,
                                     const std::string& implicitCorrectionName,
                                     const std::string& slot,
                                     std::string& replacement,
                                    bool* usedImplicitCorrection) {
    const std::string trimmed = trimCopy(arg);
    const bool isLevel = trimmed.rfind("level", 0) == 0;
    const bool isBias = trimmed.rfind("bias", 0) == 0;
    if (!isLevel && !isBias) {
        return false;
    }
    const char* intrinsic = isLevel ? "level" : "bias";
    const std::size_t intrinsicLen = std::strlen(intrinsic);
    if (trimmed.size() <= intrinsicLen ||
        (trimmed[intrinsicLen] != '(' &&
         !std::isspace(static_cast<unsigned char>(trimmed[intrinsicLen])))) {
        return false;
    }
    std::size_t open = intrinsicLen;
    while (open < trimmed.size() &&
           std::isspace(static_cast<unsigned char>(trimmed[open]))) {
        ++open;
    }
    if (open >= trimmed.size() || trimmed[open] != '(') {
        return false;
    }
    std::size_t close = 0;
    if (!findMatchingParen(trimmed, open, close)) {
        return false;
    }
    std::size_t tail = close + 1;
    while (tail < trimmed.size() &&
           std::isspace(static_cast<unsigned char>(trimmed[tail]))) {
        ++tail;
    }
    if (tail != trimmed.size()) {
        return false;
    }
    const std::string inner = trimCopy(trimmed.substr(open + 1, close - open - 1));
    if (inner.empty()) {
        return false;
    }
    const std::string biased =
        "((" + inner + ") + " + bufferName + "[" + slot + "])";
    if (isLevel) {
        replacement = "level(max(0.0, " + biased + "))";
    } else {
        replacement = "bias((" + biased + ") + " + implicitCorrectionName + ")";
        if (usedImplicitCorrection != nullptr) {
            *usedImplicitCorrection = true;
        }
    }
    return true;
}

bool rewriteTextureSampleGradientArg(
    const std::string& arg,
    const std::string& bufferName,
    const std::string& implicitCorrectionName,
    const std::string& slot,
    std::string& replacement) {
    const std::string trimmed = trimCopy(arg);
    const char* intrinsic = nullptr;
    if (trimmed.rfind("gradient2d", 0) == 0) {
        intrinsic = "gradient2d";
    } else if (trimmed.rfind("gradient3d", 0) == 0) {
        intrinsic = "gradient3d";
    } else {
        return false;
    }

    const std::size_t intrinsicLen = std::strlen(intrinsic);
    if (trimmed.size() <= intrinsicLen ||
        (trimmed[intrinsicLen] != '(' &&
         !std::isspace(static_cast<unsigned char>(trimmed[intrinsicLen])))) {
        return false;
    }
    std::size_t open = intrinsicLen;
    while (open < trimmed.size() &&
           std::isspace(static_cast<unsigned char>(trimmed[open]))) {
        ++open;
    }
    if (open >= trimmed.size() || trimmed[open] != '(') {
        return false;
    }
    std::size_t close = 0;
    if (!findMatchingParen(trimmed, open, close)) {
        return false;
    }
    std::size_t tail = close + 1;
    while (tail < trimmed.size() &&
           std::isspace(static_cast<unsigned char>(trimmed[tail]))) {
        ++tail;
    }
    if (tail != trimmed.size() ||
        trimmed.find(bufferName) != std::string::npos ||
        trimmed.find(implicitCorrectionName) != std::string::npos) {
        return false;
    }

    std::vector<std::string> derivatives = splitTopLevelCommas(
        trimmed.substr(open + 1, close - open - 1));
    if (derivatives.size() != 2u ||
        trimCopy(derivatives[0]).empty() ||
        trimCopy(derivatives[1]).empty()) {
        return false;
    }
    const std::string totalBias =
        "(" + bufferName + "[" + slot + "] + " +
        implicitCorrectionName + ")";
    const std::string derivativeScale = "exp2(" + totalBias + ")";
    replacement = std::string(intrinsic) + "((" +
        trimCopy(derivatives[0]) + ") * " + derivativeScale + ", (" +
        trimCopy(derivatives[1]) + ") * " + derivativeScale + ")";
    return true;
}

void threadTextureLodBiasParamsThroughHelpers(
    std::string& msl,
    const std::string& lodBiasesName,
    const std::string& implicitCorrectionName) {
    const std::vector<MslFunctionDefinition> functions =
        findTopLevelFunctionDefinitions(msl);
    if (functions.empty()) {
        return;
    }

    const bool hasImplicitCorrection = !implicitCorrectionName.empty();
    std::unordered_set<std::string> needsParams;
    for (const auto& fn : functions) {
        const std::string body =
            msl.substr(fn.bodyOpen + 1, fn.bodyClose - fn.bodyOpen - 1);
        if (body.find(lodBiasesName) != std::string::npos ||
            (hasImplicitCorrection &&
             body.find(implicitCorrectionName) != std::string::npos)) {
            needsParams.insert(fn.name);
        }
    }

    bool changed = true;
    while (changed) {
        changed = false;
        for (const auto& fn : functions) {
            if (needsParams.find(fn.name) != needsParams.end()) {
                continue;
            }
            for (const auto& callee : needsParams) {
                if (containsFunctionCallInRange(
                        msl, fn.bodyOpen + 1, fn.bodyClose, callee)) {
                    needsParams.insert(fn.name);
                    changed = true;
                    break;
                }
            }
        }
    }
    if (needsParams.empty()) {
        return;
    }

    struct Insertion {
        std::size_t pos = 0;
        std::string text;
    };
    std::vector<Insertion> insertions;
    std::string helperParams = "constant float* " + lodBiasesName;
    std::string callParams = ", " + lodBiasesName;
    if (hasImplicitCorrection) {
        helperParams += ", constant float& " + implicitCorrectionName;
        callParams += ", " + implicitCorrectionName;
    }

    for (const auto& fn : functions) {
        for (const auto& callee : needsParams) {
            if (callee == fn.name && callee != "main0") {
                continue;
            }
            std::size_t pos = fn.bodyOpen + 1;
            while ((pos = msl.find(callee, pos)) != std::string::npos &&
                   pos < fn.bodyClose) {
                const std::size_t afterName = pos + callee.size();
                if ((pos > 0 && isIdentifierChar(msl[pos - 1])) ||
                    (afterName < msl.size() && isIdentifierChar(msl[afterName]))) {
                    pos = afterName;
                    continue;
                }
                std::size_t open = afterName;
                while (open < fn.bodyClose &&
                       std::isspace(static_cast<unsigned char>(msl[open]))) {
                    ++open;
                }
                if (open >= fn.bodyClose || msl[open] != '(') {
                    pos = afterName;
                    continue;
                }
                std::size_t close = 0;
                if (!findMatchingParen(msl, open, close) || close > fn.bodyClose) {
                    break;
                }
                const std::string args = msl.substr(open + 1, close - open - 1);
                const bool alreadyThreaded =
                    args.find(lodBiasesName) != std::string::npos ||
                    (hasImplicitCorrection &&
                     args.find(implicitCorrectionName) != std::string::npos);
                if (!alreadyThreaded) {
                    const std::string trimmed = trimCopy(args);
                    const std::string emptyArgs =
                        lodBiasesName +
                        (hasImplicitCorrection
                             ? ", " + implicitCorrectionName
                             : std::string());
                    insertions.push_back({
                        close,
                        trimmed.empty() ? emptyArgs : callParams});
                }
                pos = close + 1;
            }
        }

        if (fn.name == "main0" ||
            needsParams.find(fn.name) == needsParams.end()) {
            continue;
        }
        const std::string params =
            msl.substr(fn.paramOpen + 1, fn.paramClose - fn.paramOpen - 1);
        const bool alreadyThreaded =
            params.find(lodBiasesName) != std::string::npos ||
            (hasImplicitCorrection &&
             params.find(implicitCorrectionName) != std::string::npos);
        if (alreadyThreaded) {
            continue;
        }
        insertions.push_back({
            fn.paramClose,
            trimCopy(params).empty() ? helperParams : ", " + helperParams});
    }

    std::sort(insertions.begin(), insertions.end(),
              [](const Insertion& a, const Insertion& b) {
                  return a.pos > b.pos;
              });
    for (const auto& insertion : insertions) {
        msl.insert(insertion.pos, insertion.text);
    }
}

bool injectTextureLodBiases(std::string& msl,
                            bool applyImplicitLodBias) {
    static constexpr const char* kParamName = "_appgl_TextureLodBiases";
    static constexpr const char* kImplicitCorrectionName =
        "_appgl_ImplicitLodBiasCorrection";
    const bool hasReductionLodBiasReference =
        msl.find(kParamName) != std::string::npos;
    if (!hasReductionLodBiasReference &&
        msl.find(".sample(") == std::string::npos) {
        return false;
    }
    const std::string originalMsl = msl;
    const std::vector<TextureReductionParam> params =
        textureReductionParams(msl);
    if (params.empty()) {
        return false;
    }

    struct Replacement {
        std::size_t begin = 0;
        std::size_t end = 0;
        std::string text;
    };
    std::vector<Replacement> replacements;
    bool needsImplicitCorrection =
        msl.find(kImplicitCorrectionName) != std::string::npos;
    for (const TextureReductionParam& param : params) {
        const std::string needle = param.name + ".sample(";
        std::size_t pos = 0;
        while ((pos = msl.find(needle, pos)) != std::string::npos) {
            if (pos > 0 && isIdentifierChar(msl[pos - 1])) {
                pos += needle.size();
                continue;
            }
            const std::size_t open = pos + param.name.size() + std::strlen(".sample");
            std::size_t close = 0;
            if (!findMatchingParen(msl, open, close)) {
                pos += needle.size();
                continue;
            }
            std::vector<std::string> args =
                splitTopLevelCommas(msl.substr(open + 1, close - open - 1));
            bool changed = false;
            bool hasExplicitLodControl = false;
            bool hasRewrittenLevelOrBias = false;
            const std::string slot = std::to_string(param.slot) + "u";
            for (std::string& arg : args) {
                std::string rewritten;
                if (rewriteTextureSampleLodBiasArg(
                        arg,
                        kParamName,
                        kImplicitCorrectionName,
                        slot,
                        rewritten,
                        &needsImplicitCorrection)) {
                    arg = std::move(rewritten);
                    changed = true;
                    hasExplicitLodControl = true;
                    hasRewrittenLevelOrBias = true;
                }
            }
            for (std::string& arg : args) {
                const std::string trimmed = trimCopy(arg);
                if (trimmed.rfind("gradient", 0) != 0) {
                    continue;
                }
                hasExplicitLodControl = true;
                if (hasRewrittenLevelOrBias) {
                    continue;
                }
                std::string rewritten;
                if (rewriteTextureSampleGradientArg(
                        arg,
                        kParamName,
                        kImplicitCorrectionName,
                        slot,
                        rewritten)) {
                    arg = std::move(rewritten);
                    changed = true;
                    needsImplicitCorrection = true;
                }
            }
            const bool supportsMetalBias =
                param.kind != TextureReductionTextureKind::Texture1D &&
                param.kind != TextureReductionTextureKind::Texture1DArray;
            if (!hasExplicitLodControl &&
                applyImplicitLodBias &&
                supportsMetalBias) {
                const std::size_t insertIndex =
                    param.kind == TextureReductionTextureKind::Texture1DArray ||
                    param.kind == TextureReductionTextureKind::Texture2DArray
                        ? 3u
                        : 2u;
                if (args.size() >= insertIndex) {
                    args.insert(
                        args.begin() + static_cast<std::ptrdiff_t>(insertIndex),
                        "bias((" + std::string(kParamName) + "[" + slot +
                            "]) + " + kImplicitCorrectionName + ")");
                    changed = true;
                    needsImplicitCorrection = true;
                }
            }
            if (changed) {
                std::string replacement = param.name + ".sample(";
                for (std::size_t i = 0; i < args.size(); ++i) {
                    if (i > 0) {
                        replacement += ", ";
                    }
                    replacement += trimCopy(args[i]);
                }
                replacement += ")";
                replacements.push_back({pos, close + 1, std::move(replacement)});
            }
            pos = close + 1;
        }
    }
    if (replacements.empty() && !hasReductionLodBiasReference) {
        return false;
    }

    std::sort(replacements.begin(), replacements.end(),
              [](const Replacement& a, const Replacement& b) {
                  return a.begin > b.begin;
              });
    for (const Replacement& replacement : replacements) {
        msl.replace(replacement.begin,
                    replacement.end - replacement.begin,
                    replacement.text);
    }

    std::size_t paramEnd = 0;
    if (!findMain0ParameterEnd(msl, paramEnd)) {
        msl = originalMsl;
        return false;
    }
    const std::size_t mainPos = msl.find("main0(");
    const std::string mainParams =
        mainPos != std::string::npos && mainPos < paramEnd
            ? msl.substr(mainPos, paramEnd - mainPos)
            : std::string();
    const bool hasLodBiasParam =
        mainParams.find(kParamName) != std::string::npos;
    const bool hasImplicitCorrectionParam =
        mainParams.find(kImplicitCorrectionName) != std::string::npos;
    std::string param;
    if (!hasLodBiasParam) {
        const std::uint32_t bufferSlot =
            chooseFreeBufferSlot(msl, kTextureLodBiasesPreferredBufferSlot);
        param =
            ", constant float* " + std::string(kParamName) +
            " [[buffer(" + std::to_string(bufferSlot) + ")]]";
    }
    if (needsImplicitCorrection && !hasImplicitCorrectionParam) {
        std::string withLodBiasParam = msl;
        if (!param.empty()) {
            withLodBiasParam.insert(paramEnd, param);
        }
        const std::uint32_t correctionSlot =
            chooseFreeBufferSlot(withLodBiasParam,
                                 kImplicitLodBiasCorrectionPreferredBufferSlot);
        param += ", constant float& " +
            std::string(kImplicitCorrectionName) +
            " [[buffer(" + std::to_string(correctionSlot) + ")]]";
    }
    if (!param.empty()) {
        msl.insert(paramEnd, param);
    }
    threadTextureLodBiasParamsThroughHelpers(
        msl,
        kParamName,
        needsImplicitCorrection ? kImplicitCorrectionName : "");
    return true;
}

void ensureGlslangInit() {
    std::call_once(g_glslangInitFlag, []() {
        glslang::InitializeProcess();
    });
}

EShLanguage glStageToEsh(GLenum stage) {
    switch (stage) {
        case GL_VERTEX_SHADER:          return EShLangVertex;
        case GL_FRAGMENT_SHADER:        return EShLangFragment;
        case GL_GEOMETRY_SHADER:        return EShLangGeometry;
        case GL_TESS_CONTROL_SHADER:    return EShLangTessControl;
        case GL_TESS_EVALUATION_SHADER: return EShLangTessEvaluation;
        case GL_COMPUTE_SHADER:         return EShLangCompute;
        default:                        return EShLangVertex;
    }
}

spv::ExecutionModel glStageToSpvModel(GLenum stage) {
    switch (stage) {
        case GL_VERTEX_SHADER:          return spv::ExecutionModelVertex;
        case GL_FRAGMENT_SHADER:        return spv::ExecutionModelFragment;
        case GL_GEOMETRY_SHADER:        return spv::ExecutionModelGeometry;
        case GL_TESS_CONTROL_SHADER:    return spv::ExecutionModelTessellationControl;
        case GL_TESS_EVALUATION_SHADER: return spv::ExecutionModelTessellationEvaluation;
        case GL_COMPUTE_SHADER:         return spv::ExecutionModelGLCompute;
        default:                        return spv::ExecutionModelVertex;
    }
}

GLenum spirvBaseTypeToGL(const spirv_cross::SPIRType& type) {
    using BT = spirv_cross::SPIRType::BaseType;
    if (type.basetype == BT::Float) {
        if (type.columns > 1) {
            // Matrix types — columns × vecsize (rows).
            // GL uses "matCxR" naming where C = columns, R = rows.
            if (type.columns == 2 && type.vecsize == 2) return GL_FLOAT_MAT2;
            if (type.columns == 2 && type.vecsize == 3) return GL_FLOAT_MAT2x3;
            if (type.columns == 2 && type.vecsize == 4) return GL_FLOAT_MAT2x4;
            if (type.columns == 3 && type.vecsize == 2) return GL_FLOAT_MAT3x2;
            if (type.columns == 3 && type.vecsize == 3) return GL_FLOAT_MAT3;
            if (type.columns == 3 && type.vecsize == 4) return GL_FLOAT_MAT3x4;
            if (type.columns == 4 && type.vecsize == 2) return GL_FLOAT_MAT4x2;
            if (type.columns == 4 && type.vecsize == 3) return GL_FLOAT_MAT4x3;
            if (type.columns == 4 && type.vecsize == 4) return GL_FLOAT_MAT4;
            return GL_FLOAT_MAT4;
        }
        switch (type.vecsize) {
            case 1: return GL_FLOAT;
            case 2: return GL_FLOAT_VEC2;
            case 3: return GL_FLOAT_VEC3;
            case 4: return GL_FLOAT_VEC4;
            default: return GL_FLOAT;
        }
    }
    if (type.basetype == BT::Double) {
        if (type.columns > 1) {
            // Matrix types — columns × vecsize (rows).
            // GL uses "dmatCxR" naming where C = columns, R = rows.
            if (type.columns == 2 && type.vecsize == 2) return GL_DOUBLE_MAT2;
            if (type.columns == 2 && type.vecsize == 3) return GL_DOUBLE_MAT2x3;
            if (type.columns == 2 && type.vecsize == 4) return GL_DOUBLE_MAT2x4;
            if (type.columns == 3 && type.vecsize == 2) return GL_DOUBLE_MAT3x2;
            if (type.columns == 3 && type.vecsize == 3) return GL_DOUBLE_MAT3;
            if (type.columns == 3 && type.vecsize == 4) return GL_DOUBLE_MAT3x4;
            if (type.columns == 4 && type.vecsize == 2) return GL_DOUBLE_MAT4x2;
            if (type.columns == 4 && type.vecsize == 3) return GL_DOUBLE_MAT4x3;
            if (type.columns == 4 && type.vecsize == 4) return GL_DOUBLE_MAT4;
            return GL_DOUBLE_MAT4;
        }
        switch (type.vecsize) {
            case 1: return GL_DOUBLE;
            case 2: return GL_DOUBLE_VEC2;
            case 3: return GL_DOUBLE_VEC3;
            case 4: return GL_DOUBLE_VEC4;
            default: return GL_DOUBLE;
        }
    }
    if (type.basetype == BT::Int) {
        switch (type.vecsize) {
            case 1: return GL_INT;
            case 2: return GL_INT_VEC2;
            case 3: return GL_INT_VEC3;
            case 4: return GL_INT_VEC4;
            default: return GL_INT;
        }
    }
    if (type.basetype == BT::UInt) {
        switch (type.vecsize) {
            case 1: return GL_UNSIGNED_INT;
            case 2: return GL_UNSIGNED_INT_VEC2;
            case 3: return GL_UNSIGNED_INT_VEC3;
            case 4: return GL_UNSIGNED_INT_VEC4;
            default: return GL_UNSIGNED_INT;
        }
    }
    if (type.basetype == BT::Boolean) {
        switch (type.vecsize) {
            case 1: return GL_BOOL;
            case 2: return GL_BOOL_VEC2;
            case 3: return GL_BOOL_VEC3;
            case 4: return GL_BOOL_VEC4;
            default: return GL_BOOL;
        }
    }
    if (type.basetype == BT::SampledImage || type.basetype == BT::Image) {
        return GL_SAMPLER_2D;
    }
    return GL_FLOAT;
}

bool spirvModuleDeclaresFp64(const std::uint32_t* spirv,
                             std::size_t wordCount) {
    if (spirv == nullptr || wordCount <= 5) {
        return false;
    }
    std::size_t cursor = 5;  // SPIR-V header.
    while (cursor < wordCount) {
        const std::uint32_t first = spirv[cursor];
        const std::uint16_t op = static_cast<std::uint16_t>(first & 0xffffu);
        const std::uint16_t length = static_cast<std::uint16_t>(first >> 16u);
        if (length == 0 || cursor + length > wordCount) {
            break;
        }
        const std::uint32_t* inst = spirv + cursor;
        if (static_cast<spv::Op>(op) == spv::OpTypeFloat &&
            length >= 3 && inst[2] == 64u) {
            return true;
        }
        cursor += length;
    }
    return false;
}

bool spirvTypeUsesFp64(spirv_cross::Compiler& compiler,
                       const spirv_cross::SPIRType& type,
                       std::unordered_set<std::uint32_t>& visiting) {
    if (type.basetype == spirv_cross::SPIRType::Double) {
        return true;
    }
    if (type.self != 0 && !visiting.insert(type.self).second) {
        return false;
    }
    if ((type.basetype == spirv_cross::SPIRType::Image ||
         type.basetype == spirv_cross::SPIRType::SampledImage) &&
        type.image.type != 0) {
        if (spirvTypeUsesFp64(compiler, compiler.get_type(type.image.type),
                              visiting)) {
            return true;
        }
    }
    for (std::uint32_t memberTypeId : type.member_types) {
        if (spirvTypeUsesFp64(compiler, compiler.get_type(memberTypeId),
                              visiting)) {
            return true;
        }
    }
    return false;
}

bool spirvTypeUsesFp64(spirv_cross::Compiler& compiler,
                       const spirv_cross::SPIRType& type) {
    std::unordered_set<std::uint32_t> visiting;
    return spirvTypeUsesFp64(compiler, type, visiting);
}

bool resourcesUseFragmentShadingRateBuiltins(
        const spirv_cross::ShaderResources& resources) {
    auto contains = [](const auto& builtins) {
        for (const auto& builtin : builtins) {
            if (builtin.builtin == spv::BuiltInShadingRateKHR ||
                builtin.builtin == spv::BuiltInPrimitiveShadingRateKHR) {
                return true;
            }
        }
        return false;
    };
    return contains(resources.builtin_inputs) ||
           contains(resources.builtin_outputs);
}

bool resourcesUseMultiviewBuiltins(
        const spirv_cross::ShaderResources& resources) {
    auto contains = [](const auto& builtins) {
        for (const auto& builtin : builtins) {
            if (builtin.builtin == spv::BuiltInViewIndex) {
                return true;
            }
        }
        return false;
    };
    return contains(resources.builtin_inputs) ||
           contains(resources.builtin_outputs);
}

bool resourcesUse1DImages(spirv_cross::Compiler& compiler,
                          const spirv_cross::ShaderResources& resources) {
    auto contains1DImage = [&](const auto& images) {
        for (const auto& image : images) {
            const auto& type = compiler.get_type(image.type_id);
            if ((type.basetype == spirv_cross::SPIRType::Image ||
                 type.basetype == spirv_cross::SPIRType::SampledImage) &&
                type.image.dim == spv::Dim1D) {
                return true;
            }
        }
        return false;
    };
    return contains1DImage(resources.sampled_images) ||
           contains1DImage(resources.separate_images) ||
           contains1DImage(resources.storage_images);
}

bool isDefaultUniformBlockResource(spirv_cross::Compiler& compiler,
                                   const spirv_cross::Resource& resource) {
    const auto& blockType = compiler.get_type(resource.base_type_id);
    const std::string typeName = compiler.get_name(blockType.self);
    return resource.name == "_DefaultUniforms" || typeName == "_DefaultUniforms";
}

// Clone glslang's default TBuiltInResource and overwrite the limits
// that the CTS KHR-GL46.limits tests cross-check between
// glGetIntegerv(GL_MAX_*) on the CPU side and the GLSL built-in
// constants (gl_MaxVertexAttribs, gl_MaxDrawBuffers, …) that glslang
// materialises inside compiled shaders. Without matching values the
// tests flag the mismatch and fail.
//
// Values must match GLCapabilities.mm's `integerLimits_` table. Kept
// in lockstep manually — the per-category tests will surface any drift.
static TBuiltInResource makeAppGLBuiltInResources() {
    TBuiltInResource r = *GetDefaultResources();
    // Vertex stage.
    r.maxVertexAttribs = 32;
    r.maxVertexUniformComponents = 4096;
    r.maxVertexUniformVectors = 1024;        // components / 4
    // Per-stage texture-image-unit limits must match
    // GLCapabilities.mm's GL_MAX_*_TEXTURE_IMAGE_UNITS values. Graphics
    // stages advertise 48; compute intentionally stays at 16 because
    // the direct Metal compute sampler path is limited to that range.
    // CTS cross-checks the GLSL gl_Max*TextureImageUnits constants
    // against the GL-advertised values, so both tables must agree.
    r.maxVertexTextureImageUnits = 48;
    r.maxVertexOutputComponents = 128;
    r.maxVertexOutputVectors = 32;
    r.maxVertexAtomicCounters = 0;
    r.maxVertexAtomicCounterBuffers = 0;
    r.maxVertexImageUniforms = 16;
    // Fragment stage.
    r.maxFragmentUniformComponents = 4096;
    r.maxFragmentUniformVectors = 1024;
    r.maxFragmentInputComponents = 128;
    r.maxFragmentInputVectors = 32;
    r.maxFragmentAtomicCounters = 8;
    r.maxFragmentAtomicCounterBuffers = 2;
    r.maxFragmentImageUniforms = 16;
    // Combined / pipeline.
    r.maxTextureImageUnits = 48;            // per-stage fragment tex units
    r.maxCombinedTextureImageUnits = 144;
    r.maxDrawBuffers = 8;
    r.maxVaryingComponents = 128;
    r.maxVaryingVectors = 32;
    r.maxImageUnits = 16;
    r.maxImageSamples = 4;
    r.maxCombinedImageUniforms = 48;
    r.maxCombinedImageUnitsAndFragmentOutputs = 48;
    r.maxCombinedShaderOutputResources = 48;
    // Atomic counters. CTS gl4cLimitsTests.cpp:236 insists on at least
    // 4 bindings; we advertise 8 binding points and keep the CPU-emulated
    // GS path aligned with CTS' four-counter workload.
    r.maxAtomicCounterBindings = 8;
    r.maxAtomicCounterBufferSize = 32;
    r.maxTessControlAtomicCounters = 0;
    r.maxTessEvaluationAtomicCounters = 0;
    r.maxGeometryAtomicCounters = 4;
    r.maxGeometryAtomicCounterBuffers = 4;
    r.maxCombinedAtomicCounters = 12;
    r.maxCombinedAtomicCounterBuffers = 8;
    // Image uniforms per tess / geometry.
    r.maxTessControlImageUniforms = 16;
    r.maxTessEvaluationImageUniforms = 16;
    r.maxGeometryImageUniforms = 16;
    // Per-stage tess / geometry texture image units (match GL advert
    // per 4245d6b).
    r.maxTessControlTextureImageUnits = 48;
    r.maxTessEvaluationTextureImageUnits = 48;
    r.maxGeometryTextureImageUnits = 48;
    // Compute stage.
    r.maxComputeAtomicCounterBuffers = 8;
    r.maxComputeAtomicCounters = 8;
    r.maxComputeImageUniforms = 16;
    r.maxComputeTextureImageUnits = 16;
    // Clip / cull distances (GL 4.6 Table 23.53 — minimums 8/8, combined 8).
    // CTS `clip_distance.coverage` compiles a VS that writes
    // `gl_MaxClipDistances` to a transform-feedback output and
    // compares the value against `glGetIntegerv(GL_MAX_CLIP_DISTANCES)`.
    // The GLSL built-in constant is materialized by glslang from
    // `resources.maxClipDistances` — although glslang's default is 8,
    // we set it explicitly here to keep both caps in lockstep and
    // guard against any later default change in the vendored glslang.
    r.maxClipDistances = 8;
    r.maxCullDistances = 8;
    r.maxCombinedClipAndCullDistances = 8;
    r.maxTransformFeedbackInterleavedComponents = 128;
    return r;
}

}  // namespace

std::vector<std::uint32_t> ShaderTranslator::compileGLSL(std::string_view source, GLenum stage, int version, std::string* log) const {
    ensureGlslangInit();

    EShLanguage eshStage = glStageToEsh(stage);
    glslang::TShader shader(eshStage);

    const char* sourcePtr = source.data();
    int sourceLen = static_cast<int>(source.size());
    shader.setStringsWithLengths(&sourcePtr, &sourceLen, 1);

    const bool usesAtomicCounters =
        source.find("atomic_uint") != std::string_view::npos ||
        source.find("atomicCounter") != std::string_view::npos;
    const bool usesShaderStorageBuffers =
        source.find("shader_storage_buffer_object") != std::string_view::npos ||
        source.find(" buffer ") != std::string_view::npos ||
        source.find(") buffer") != std::string_view::npos ||
        source.find("\nbuffer ") != std::string_view::npos;
    const bool redeclaresPerVertexBlock =
        source.find("gl_PerVertex") != std::string_view::npos &&
        source.find('{') != std::string_view::npos;

    // Sprint 9 Phase 3 (CKPT103): glslang's strict version-based gating of
    // ARB_sample_shading + OES_sample_variables built-ins (gl_NumSamples,
    // gl_SampleID, gl_SamplePosition, gl_SampleMaskIn, gl_SampleMask)
    // makes them undeclared at GLSL versions < 450 (core) without an
    // explicit `#extension` directive. CTS sample_variables.* and
    // shader_multisample_interpolation.render.* tests use #version 440
    // without the extension declaration — real GL drivers accept this
    // (the spec-strict behavior is unhelpful in practice). Inject the
    // extension declarations as a preamble so the symbol table populates
    // for these built-ins. Preamble runs after #version directive
    // processing, so version-dependent gating already saw the user's
    // #version pick.
    static const char* kFragmentSamplePreamble =
        "#extension GL_ARB_sample_shading : enable\n"
        "#extension GL_OES_sample_variables : enable\n"
        "#extension GL_OES_shader_multisample_interpolation : enable\n";
    std::string preamble;
    if (usesAtomicCounters) {
        // glslang's Vulkan path gates the GL 4.2/4.6 atomic-counter built-ins
        // more strictly than desktop GL drivers. CTS supplies #version 420/450
        // shaders without explicit extension lines; inject the desktop-GL
        // extensions as a preamble so atomic_uint and atomicCounter* parse.
        preamble += "#extension GL_ARB_shader_atomic_counters : enable\n";
        preamble += "#extension GL_ARB_shader_atomic_counter_ops : enable\n";
    }
    if (usesAtomicCounters || usesShaderStorageBuffers) {
        preamble += "#extension GL_ARB_shading_language_420pack : enable\n";
        preamble += "#extension GL_ARB_shader_storage_buffer_object : enable\n";
    }
    if (redeclaresPerVertexBlock) {
        // Glslang gates built-in block redeclaration at GLSL 4.10 or
        // ARB_separate_shader_objects. Desktop GL 4.x CTS shaders often
        // redeclare gl_PerVertex in #version 400/420 sources, so enable
        // the GL extension for the glslang-visible frontend only.
        preamble += "#extension GL_ARB_separate_shader_objects : enable\n";
    }
    if (eshStage == EShLangFragment) {
        preamble += kFragmentSamplePreamble;
    }
    if (!preamble.empty()) {
        shader.setPreamble(preamble.c_str());
        if (std::getenv("APPGL_TRACE_GLSLANG") != nullptr) {
            std::fprintf(stderr, "[glslang-preamble] stage=%d preamble set: %zu bytes\n",
                static_cast<int>(eshStage), preamble.size());
        }
    }

    // Target Vulkan SPIR-V with relaxed rules so glslang accepts bare
    // uniforms from OpenGL GLSL. Bare uniforms are wrapped into a single
    // global uniform block (UBO) that SPIRV-Cross maps to a Metal buffer.
    shader.setEnvInput(glslang::EShSourceGlsl, eshStage, glslang::EShClientVulkan, glslang::EShTargetVulkan_1_0);
    shader.setEnvClient(glslang::EShClientVulkan, glslang::EShTargetVulkan_1_0);
    shader.setEnvTarget(glslang::EShTargetSpv, glslang::EShTargetSpv_1_0);
    shader.setEnvInputVulkanRulesRelaxed();
    shader.setAutoMapLocations(true);
    shader.setAutoMapBindings(true);
    shader.setGlobalUniformBlockName("_DefaultUniforms");
    shader.setGlobalUniformSet(0);
    shader.setGlobalUniformBinding(0);

    // AppGL built-in-resource overrides: match the CPU-side caps
    // reported by GLCapabilities.mm so CTS limits tests (which
    // compare GLSL gl_Max* constants against glGetIntegerv) pass.
    static const TBuiltInResource appglResources = makeAppGLBuiltInResources();
    const TBuiltInResource* resources = &appglResources;
    TBuiltInResource atomicVertexResources;
    if (usesAtomicCounters && eshStage == EShLangVertex) {
        atomicVertexResources = appglResources;
        // Public GL caps still advertise zero vertex atomic counters, which
        // preserves cap-gated tests. The SSO atomicCounters case nonetheless
        // compiles a vertex shader containing atomic_uint; allow glslang to
        // produce SPIR-V so the already-supported Metal atomic-counter binding
        // path can execute it.
        atomicVertexResources.maxVertexAtomicCounters = 8;
        atomicVertexResources.maxVertexAtomicCounterBuffers = 1;
        resources = &atomicVertexResources;
    }
    EShMessages messages = static_cast<EShMessages>(EShMsgSpvRules | EShMsgVulkanRules);

    if (!shader.parse(resources, version, false, messages)) {
        if (log != nullptr) {
            *log = shader.getInfoLog();
        }
        if (std::getenv("APPGL_TRACE_GLSLANG") != nullptr) {
            std::fprintf(stderr, "[glslang-parse-fail] stage=%d log=%s\n",
                static_cast<int>(eshStage), shader.getInfoLog());
        }
        return {};
    }

    glslang::TProgram program;
    program.addShader(&shader);
    if (!program.link(messages)) {
        if (log != nullptr) {
            *log = program.getInfoLog();
        }
        if (std::getenv("APPGL_TRACE_GLSLANG") != nullptr) {
            std::fprintf(stderr, "[glslang-link-fail] stage=%d log=%s\n",
                static_cast<int>(eshStage), program.getInfoLog());
        }
        return {};
    }

    std::vector<unsigned int> spirv;
    glslang::SpvOptions spvOptions;
    spvOptions.disableOptimizer = false;
    spvOptions.optimizeSize = true;
    glslang::GlslangToSpv(*program.getIntermediate(eshStage), spirv, &spvOptions);

    if (spirv.empty()) {
        if (log != nullptr) {
            *log = "SPIR-V generation produced empty output.";
        }
        return {};
    }

    if (log != nullptr) {
        *log = "ok";
    }

    return std::vector<std::uint32_t>(spirv.begin(), spirv.end());
}

std::vector<std::uint32_t> ShaderTranslator::compileGLSLStageProgram(
    const std::vector<std::string>& sources, GLenum stage, int version,
    std::string* log) const {
    if (sources.empty()) {
        if (log != nullptr) {
            *log = "no GLSL sources supplied";
        }
        return {};
    }

    ensureGlslangInit();

    const EShLanguage eshStage = glStageToEsh(stage);
    std::vector<const char*> sourcePtrs(sources.size());
    std::vector<int> sourceLens(sources.size());
    std::vector<std::string> preambles(sources.size());
    std::vector<std::unique_ptr<glslang::TShader>> shaders;
    shaders.reserve(sources.size());

    auto makePreamble = [&](std::string_view source) {
        const bool usesAtomicCounters =
            source.find("atomic_uint") != std::string_view::npos ||
            source.find("atomicCounter") != std::string_view::npos;
        const bool usesShaderStorageBuffers =
            source.find("shader_storage_buffer_object") != std::string_view::npos ||
            source.find(" buffer ") != std::string_view::npos ||
            source.find(") buffer") != std::string_view::npos ||
            source.find("\nbuffer ") != std::string_view::npos;
        const bool redeclaresPerVertexBlock =
            source.find("gl_PerVertex") != std::string_view::npos &&
            source.find('{') != std::string_view::npos;

        std::string preamble;
        if (usesAtomicCounters) {
            preamble += "#extension GL_ARB_shader_atomic_counters : enable\n";
            preamble += "#extension GL_ARB_shader_atomic_counter_ops : enable\n";
        }
        if (usesAtomicCounters || usesShaderStorageBuffers) {
            preamble += "#extension GL_ARB_shading_language_420pack : enable\n";
            preamble += "#extension GL_ARB_shader_storage_buffer_object : enable\n";
        }
        if (redeclaresPerVertexBlock) {
            preamble += "#extension GL_ARB_separate_shader_objects : enable\n";
        }
        if (eshStage == EShLangFragment) {
            preamble += "#extension GL_ARB_sample_shading : enable\n";
            preamble += "#extension GL_OES_sample_variables : enable\n";
            preamble += "#extension GL_OES_shader_multisample_interpolation : enable\n";
        }
        return preamble;
    };

    for (std::size_t i = 0; i < sources.size(); ++i) {
        sourcePtrs[i] = sources[i].data();
        sourceLens[i] = static_cast<int>(sources[i].size());
        preambles[i] = makePreamble(sources[i]);

        auto shader = std::make_unique<glslang::TShader>(eshStage);
        shader->setStringsWithLengths(&sourcePtrs[i], &sourceLens[i], 1);
        if (!preambles[i].empty()) {
            shader->setPreamble(preambles[i].c_str());
        }
        shader->setEnvInput(glslang::EShSourceGlsl, eshStage,
                            glslang::EShClientVulkan,
                            glslang::EShTargetVulkan_1_0);
        shader->setEnvClient(glslang::EShClientVulkan,
                             glslang::EShTargetVulkan_1_0);
        shader->setEnvTarget(glslang::EShTargetSpv,
                             glslang::EShTargetSpv_1_0);
        shader->setEnvInputVulkanRulesRelaxed();
        shader->setAutoMapLocations(true);
        shader->setAutoMapBindings(true);
        shader->setGlobalUniformBlockName("_DefaultUniforms");
        shader->setGlobalUniformSet(0);
        shader->setGlobalUniformBinding(0);
        shaders.push_back(std::move(shader));
    }

    static const TBuiltInResource appglResources = makeAppGLBuiltInResources();
    const TBuiltInResource* resources = &appglResources;
    const EShMessages messages =
        static_cast<EShMessages>(EShMsgSpvRules | EShMsgVulkanRules);

    glslang::TProgram program;
    for (std::size_t i = 0; i < shaders.size(); ++i) {
        if (!shaders[i]->parse(resources, version, false, messages)) {
            if (log != nullptr) {
                *log = std::string("source ") + std::to_string(i) +
                    " parse: " + shaders[i]->getInfoLog();
            }
            return {};
        }
        program.addShader(shaders[i].get());
    }

    if (!program.link(messages)) {
        if (log != nullptr) {
            *log = std::string("link: ") + program.getInfoLog();
        }
        return {};
    }

    glslang::SpvOptions spvOptions;
    spvOptions.disableOptimizer = false;
    spvOptions.optimizeSize = true;

    std::vector<unsigned int> spirv;
    glslang::GlslangToSpv(*program.getIntermediate(eshStage), spirv,
                          &spvOptions);
    if (spirv.empty()) {
        if (log != nullptr) {
            *log = "GlslangToSpv produced empty output";
        }
        return {};
    }

    if (log != nullptr) {
        *log = "ok";
    }
    return std::vector<std::uint32_t>(spirv.begin(), spirv.end());
}

LinkedProgramSpirv ShaderTranslator::compileGLSLProgram(
    std::string_view vertexSource, std::string_view fragmentSource,
    int version, std::string* log) const {
    LinkedProgramSpirv result;
    ensureGlslangInit();

    glslang::TShader vsShader(EShLangVertex);
    glslang::TShader fsShader(EShLangFragment);

    // Configure both shaders identically to the per-stage `compileGLSL`
    // path so glslang sees the same dialect / target / global-uniform
    // settings for both halves of the program. The only thing different
    // about this path is that both shaders are eventually attached to the
    // SAME `glslang::TProgram` so the cross-stage interface matcher can
    // see vertex outputs and fragment inputs together.
    //
    // Critical: glslang::TShader::setStringsWithLengths stores the
    // POINTERS we pass in (not the strings) and dereferences them at
    // parse() time. The `sourcePtr` / `sourceLen` locals must therefore
    // outlive the parse() call below — keeping them in this function's
    // stack frame rather than a nested helper lambda is required. (An
    // earlier draft used a configureShader lambda; glslang then read
    // dangling stack memory after the lambda returned, yielding parse
    // errors like `'Ä' : unexpected token` and link errors like
    // `Missing entry point`.)
    const char* vsSourcePtr = vertexSource.data();
    const int vsSourceLen = static_cast<int>(vertexSource.size());
    const char* fsSourcePtr = fragmentSource.data();
    const int fsSourceLen = static_cast<int>(fragmentSource.size());

    vsShader.setStringsWithLengths(&vsSourcePtr, &vsSourceLen, 1);
    vsShader.setEnvInput(glslang::EShSourceGlsl, EShLangVertex,
                         glslang::EShClientVulkan, glslang::EShTargetVulkan_1_0);
    vsShader.setEnvClient(glslang::EShClientVulkan, glslang::EShTargetVulkan_1_0);
    vsShader.setEnvTarget(glslang::EShTargetSpv, glslang::EShTargetSpv_1_0);
    vsShader.setEnvInputVulkanRulesRelaxed();
    vsShader.setAutoMapLocations(true);
    vsShader.setAutoMapBindings(true);
    vsShader.setGlobalUniformBlockName("_DefaultUniforms");
    vsShader.setGlobalUniformSet(0);
    vsShader.setGlobalUniformBinding(0);
    fsShader.setStringsWithLengths(&fsSourcePtr, &fsSourceLen, 1);
    fsShader.setEnvInput(glslang::EShSourceGlsl, EShLangFragment,
                         glslang::EShClientVulkan, glslang::EShTargetVulkan_1_0);
    fsShader.setEnvClient(glslang::EShClientVulkan, glslang::EShTargetVulkan_1_0);
    fsShader.setEnvTarget(glslang::EShTargetSpv, glslang::EShTargetSpv_1_0);
    fsShader.setEnvInputVulkanRulesRelaxed();
    fsShader.setAutoMapLocations(true);
    fsShader.setAutoMapBindings(true);
    fsShader.setGlobalUniformBlockName("_DefaultUniforms");
    fsShader.setGlobalUniformSet(0);
    fsShader.setGlobalUniformBinding(0);
    // AppGL built-in-resource overrides: match the CPU-side caps
    // reported by GLCapabilities.mm so CTS limits tests (which
    // compare GLSL gl_Max* constants against glGetIntegerv) pass.
    static const TBuiltInResource appglResources = makeAppGLBuiltInResources();
    const TBuiltInResource* resources = &appglResources;
    EShMessages messages = static_cast<EShMessages>(EShMsgSpvRules | EShMsgVulkanRules);

    if (!vsShader.parse(resources, version, false, messages)) {
        if (log != nullptr) {
            *log = std::string("vertex parse: ") + vsShader.getInfoLog();
        }
        return result;
    }
    if (!fsShader.parse(resources, version, false, messages)) {
        if (log != nullptr) {
            *log = std::string("fragment parse: ") + fsShader.getInfoLog();
        }
        return result;
    }

    glslang::TProgram program;
    program.addShader(&vsShader);
    program.addShader(&fsShader);

    if (!program.link(messages)) {
        const std::string linkLog = std::string("link: ") + program.getInfoLog();
        if (log != nullptr) {
            *log = linkLog;
        }
        result.linkLog = linkLog;  // CKPT79: propagate so caller can decide fail-vs-fallback
        return result;
    }

    // Run cross-stage IO mapping so glslang's default GLSL IO resolver
    // assigns matching `DecorationLocation` values to vertex outputs and
    // fragment inputs that share a name. The resolver walks the pipeline
    // in-order, sees both stages because we attached them to the same
    // TProgram above, and produces a coherent location table — which is
    // exactly what BAR observed missing in the followup⁴ Metal NSErrors.
    //
    // Without this pass, varyings in the SPIR-V come out either
    // unlocated or with per-stage-independent locations, and SPIRV-Cross
    // emits the mangled `m_NN_<name>` member form without `[[user(locN)]]`
    // attributes — which Metal rejects at `MTLRenderPipelineState`
    // creation time with a varying-mismatch error.
    if (!program.mapIO()) {
        const std::string mapIOLog = std::string("mapIO: ") + program.getInfoLog();
        if (log != nullptr) {
            *log = mapIOLog;
        }
        result.linkLog = mapIOLog;  // CKPT79: propagate (mapIO failures are typically recoverable via per-stage fallback, but caller decides)
        return result;
    }

    glslang::SpvOptions spvOptions;
    spvOptions.disableOptimizer = false;
    spvOptions.optimizeSize = true;

    std::vector<unsigned int> vsSpirv;
    std::vector<unsigned int> fsSpirv;
    glslang::GlslangToSpv(*program.getIntermediate(EShLangVertex), vsSpirv, &spvOptions);
    glslang::GlslangToSpv(*program.getIntermediate(EShLangFragment), fsSpirv, &spvOptions);

    if (vsSpirv.empty() || fsSpirv.empty()) {
        if (log != nullptr) {
            *log = "GlslangToSpv produced empty output for at least one stage";
        }
        return result;
    }

    result.vertexSpirv.assign(vsSpirv.begin(), vsSpirv.end());
    result.fragmentSpirv.assign(fsSpirv.begin(), fsSpirv.end());
    result.linkSucceeded = true;
    if (log != nullptr) {
        *log = "ok";
    }
    return result;
}

std::string ShaderTranslator::spirvToMSL(const std::uint32_t* spirv, std::size_t wordCount, const BindingMap& bindings, std::string* log) const {
    return spirvToMSL(spirv, wordCount, bindings, log, TranslatorOptions{});
}

std::string ShaderTranslator::spirvToMSL(const std::uint32_t* spirv, std::size_t wordCount, const BindingMap& bindings, std::string* log, const TranslatorOptions& options) const {
    // T4D probe: dump the INPUT SPIR-V before SPIRV-Cross runs, so we
    // capture it even when compile() throws or returns empty MSL.
    // Useful for diagnosing translator failures (isolines TES landed
    // here in 2026-04-26 while debugging tc2te.data_pass_through).
    // Pairs with APPGL_DUMP_MSL via the same counter — but the counter
    // bump happens later (post-compile) for the existing dump site, so
    // this helper allocates its own.  When BOTH envs are set, we want
    // ONE counter so spv/msl pair by index — moved to the top of the
    // function and shared.
    if (const char* spirvDumpPath = std::getenv("APPGL_DUMP_SPIRV_INPUT")) {
        static std::atomic<int> spvInputCounter{0};
        const int n = spvInputCounter.fetch_add(1);
        char path[512];
        std::snprintf(path, sizeof(path), "%s/spv_%04d.spv", spirvDumpPath, n);
        if (FILE* f = std::fopen(path, "wb")) {
            std::fwrite(spirv, sizeof(std::uint32_t), wordCount, f);
            std::fclose(f);
        }
    }
    try {
        spirv_cross::CompilerMSL compiler(spirv, wordCount);
        applySpirvModuleOptions(compiler, options);
        const auto execModel = compiler.get_execution_model();
        const bool isTessControl = (execModel == spv::ExecutionModelTessellationControl);
        const bool isTessEval = (execModel == spv::ExecutionModelTessellationEvaluation);
        const bool isVertex = (execModel == spv::ExecutionModelVertex);
        const bool isGeometry = (execModel == spv::ExecutionModelGeometry);
        const bool isFragment = (execModel == spv::ExecutionModelFragment);
        const bool isGraphicsStage =
            isVertex || isTessControl || isTessEval || isGeometry || isFragment;
        (void)isTessControl; (void)isTessEval; (void)isVertex;
        (void)isGeometry; (void)isFragment; (void)isGraphicsStage;

        const auto shaderResourcesForOptions = compiler.get_shader_resources();

        spirv_cross::CompilerMSL::Options mslOpts;
        mslOpts.platform = spirv_cross::CompilerMSL::Options::macOS;
        // Native Metal texture1d backings are single-mip in AppGL due
        // AGX descriptor/assertion limits. Extension paths that need
        // mipmapped 1D/1D-array sampling or query visibility lower 1D
        // image/sampler declarations to 2D/2D-array. Keep the option off
        // for non-1D shaders so extension advertising does not perturb
        // unrelated SPIRV-Cross emission or compiler behavior.
        const bool extensionNeeds1DAs2D =
            extensions::ExtensionRegistry::isExtensionActive("GL_ARB_sparse_texture_clamp") ||
            extensions::ExtensionRegistry::isExtensionActive("GL_ARB_texture_query_levels");
        mslOpts.texture_1D_as_2D =
            extensionNeeds1DAs2D && resourcesUse1DImages(compiler, shaderResourcesForOptions);
        mslOpts.texel_buffer_texture_width = 8192;
        mslOpts.sample_dref_lod_cube_as_nearest_level =
            extensions::ExtensionRegistry::isExtensionActive("GL_EXT_texture_shadow_lod");
        // Step 8 (tessellation on Metal via SPIRV-Cross): when the shader is
        // a tess stage, we emit MSL compatible with Metal's native tess
        // pipeline (TCS-as-compute + TES-as-vertex-function + hardware
        // tessellator). The Metal-side wiring is not yet in place, so
        // this emission is gated behind APPGL_ENABLE_METAL_TESS=1 — when
        // unset, tess stages fall back to the CPU interpreter path.
        //
        // SPIRV-Cross emits for the three stages under these options:
        //  * VS (when `vertex_for_tessellation=true, capture_output_to_
        //    buffer=true`): `kernel` that writes per-vertex attribs to
        //    a buffer indexed by gl_VertexID. Input comes via
        //    MTLStageInputOutputDescriptor bound to the compute encoder.
        //  * TCS (auto on `ExecutionModelTessellationControl`): `kernel`
        //    with per-thread `[[stage_in]]` pulling VS output buffer,
        //    threadgroup `gl_in[]`, per-CP output buffer at buffer(28),
        //    patch output at buffer(27), tess factor buffer at
        //    buffer(26).
        //  * TES (auto on `ExecutionModelTessellationEvaluation`):
        //    `vertex` function intended for an MTLRenderPipeline with
        //    `tessellationEnabled = YES`. `raw_buffer_tese_input=true`
        //    makes it read per-CP (buffer 22) and per-patch (buffer 20)
        //    inputs from buffers, enabling nested-array varyings.
        static const bool metalTessEnvEnabled = []() {
            const char* v = std::getenv("APPGL_ENABLE_METAL_TESS");
            return v != nullptr && v[0] != '0' && v[0] != '\0';
        }();
        const bool metalTessEnabled = metalTessEnvEnabled || options.forceTessellation;
        if (metalTessEnabled && (isTessControl || isTessEval)) {
            if (isTessEval) {
                mslOpts.raw_buffer_tese_input = true;
                // Path J' Option E.4 (`0ee35f2`): explicit-flag-gated
                // emission opt-in for TES main0_in field order. When set,
                // SPIRV-Cross's `add_interface_block` emits TES Input
                // members in `inputs_by_location_insertion_order` order
                // (the order in which add_msl_shader_input was called)
                // instead of TES IR-walk order. The recorded order
                // matches TCS main0_out emission once the β orchestrator
                // iterates TCS active interface IDs in ascending order
                // (sort below at line 811-823). Without this flag,
                // E.4's recording is observably a no-op.
                mslOpts.input_emission_in_call_order = true;
            }
            mslOpts.tess_domain_origin_lower_left = true;
            // Phase 3: route TCS VS-input through a buffer rather than
            // [[stage_in]] so Metal doesn't reject the kernel with
            // "invalid type 'main0_in' of input declaration with
            // attribute 'stage_in'". With `multi_patch_workgroup` on,
            // SPIRV-Cross emits the TCS reading VS output directly from
            // `input_buffer_var_name` rather than via a struct-typed
            // stage-input, which sidesteps the MSL member-attribute
            // requirement.
            if (isTessControl) {
                mslOpts.multi_patch_workgroup = true;
                // Option C [metal-tess-TF] (SPIRV-Cross commit 26adef0):
                // classify TCS user-varying outputs by TES consumption
                // when a sibling-TES SPIR-V is provided. TES-consumed
                // outputs land in main0_out (per-CP device buffer) at
                // matching offsets; TCS-internal-only outputs (read by
                // TCS itself after barrier()) route to threadgroup
                // memory instead. Closes the per-CP stride mismatch on
                // tc_barriers / data_pass_through / gl_PerVertex-padded
                // tests where TCS's main0_out included slots TES doesn't
                // declare. Effective only when siblingTesInputSpirv
                // populates `name` on each MSLShaderInterfaceVariable
                // (see the wiring block below).
                mslOpts.split_tcs_outputs_by_consumption = true;
            }
        }
        // Phase 3 of metal-tess: VS-as-compute for tess programs. When
        // the caller opts in (tess program link time), emit the VS
        // as a `kernel` with `capture_output_to_buffer=true` so the
        // per-vertex outputs land in a Metal buffer the TCS compute
        // dispatch can pull via its `[[stage_in]]` descriptor.
        if (options.forceVertexForTessellation && isVertex) {
            mslOpts.vertex_for_tessellation = true;
            mslOpts.capture_output_to_buffer = true;
        }
        // Phase 3B [metal-tess-TF]: route TES as a compute kernel via
        // the AppGL fork's `tess_evaluation_as_compute` option. The
        // emission differs from the vertex-function form in three
        // ways: entry type is `kernel`, Metal-intrinsic args
        // (`[[position_in_patch]]`, `[[patch_id]]`) are replaced with
        // reads from a domain-coord buffer, and TES output is written
        // to a TF-capture buffer instead of being returned. Requires
        // `raw_buffer_tese_input = true` (already set above by
        // `forceTessellation`) and `capture_output_to_buffer = true`
        // so the upstream SPIRV-Cross switch at
        // `add_variable_to_interface_block` routes `main0_out` through
        // a `device main0_out& out = spvOut[i]` reference instead of
        // a returned local variable.
        if (options.forceTessEvalAsCompute && isTessEval) {
            mslOpts.tess_evaluation_as_compute = true;
            mslOpts.capture_output_to_buffer = true;
        }
        if (isTessEval && options.tesePatchVertices != 0) {
            mslOpts.tese_input_patch_vertices = options.tesePatchVertices;
        }
        // Sprint 5 Phase 1: Path L Class 2A — full-precision tess level
        // shadow buffer flag. Apply to BOTH TCS-compute (writes both half
        // and full per Path L extension `635380d`) AND TES-compute (reads
        // from full per Path L `4f626b9`).
        if (options.useFullPrecisionTessLevelBuffer &&
            (isTessControl || isTessEval)) {
            mslOpts.use_full_precision_tess_level_buffer = true;
        }
        // Sprint 3 [metal-mesh-GS]: route GS source into the
        // mesh-shader emission path when the linked program's GS
        // shape is supported by the SPIRV-Cross patch's MVP coverage
        // and the device has mesh-shader capability. Only emitted on
        // ExecutionModelGeometry — gated by isGeometry. Caller is
        // responsible for the capability + shape gate (link-time).
        if (options.forceGeometryShaderAsMesh && isGeometry) {
            mslOpts.geometry_shader_as_mesh = true;
        }
        // Path E mitigation [metal-tess-TF Checkpoint 11]: kernel-exit
        // device-memory barrier on VS-as-compute targeting mesh-GS.
        // Apple's AIR optimizer eliminates `device main0_out* spvOut`
        // writes when the consumer is a different encoder family
        // (mesh render pipeline) than the producer (compute encoder).
        // The barrier provides the alternative signal that blocks
        // elimination — see SPIRV-Cross fork commit e06f883 + AppGL-W
        // Checkpoint 10 falsification of H11c.
        if (options.forceComputeKernelDeviceBarrierAtExit && isVertex) {
            mslOpts.force_compute_kernel_device_barrier_at_exit = true;
        }
        // Path E++ mitigation [Checkpoint 11 escalation, fork 76aacf7]:
        // emit `volatile device main0_out*` for spvOut. Required when
        // the barrier alone is insufficient — AIR optimizer is
        // spec-obligated to preserve writes through volatile.
        if (options.forceComputeKernelDeviceVolatileWrites && isVertex) {
            mslOpts.force_compute_kernel_device_volatile_writes = true;
        }
        // Path E+++ mitigation [Checkpoint 11 escalation 3, fork 915d81c]:
        // atomic_store_explicit on spvOut field writes. Strength-tier
        // ladder terminus for spec-defensible mitigations.
        if (options.forceComputeKernelAtomicWritesOnSpvOut && isVertex) {
            mslOpts.force_compute_kernel_atomic_writes_on_spvOut = true;
        }
        // Path E+++ diagnostic [orthogonal to strength tiers]: emit
        // entry-counter atomic increment for 2-bit signal decoding.
        if (options.forceComputeKernelEntryCounterProbe && isVertex) {
            mslOpts.force_compute_kernel_entry_counter_probe = true;
        }
        // Path G [Checkpoint 15, fork f19ce45]: ACTUAL fix for the
        // VS-as-compute kernel-doesn't-execute symptom. Emits
        // `[[threads_per_grid]]` for spvStageInputSize so the bounds
        // check returns the dispatched grid size (not the broken
        // [[grid_size]] which returns 0).
        if (options.forceThreadsPerGridForStageInputSize && isVertex) {
            mslOpts.force_threads_per_grid_for_stage_input_size = true;
        }
        // MSL 2.2 (macOS 10.15+, 2019) required for:
        //   - `[[primitive_id]]` in fragment shaders on macOS — without it
        //     SPIRV-Cross throws `PrimitiveId on macOS requires MSL 2.2`
        //     and the FS translation returns empty. That made
        //     `geometry_shader.primitive_counter.primitive_id_from_fragment`
        //     render the clear color because the pipeline had no FS.
        //   - `[[barycentric]]` inputs (relevant for future GLSL_EXT_
        //     fragment_shader_barycentric support).
        // We're safe to bump: 10.15 is below every macOS version we
        // support as a host (12.0+), so every target platform has a
        // Metal driver ≥ MSL 2.2. Keep an eye on Apple-platform
        // regressions via the CTS sweep if we ever go back to 10.14
        // testing.
        //
        // CKPT122 (Sprint 11 Phase 2 Cluster A Day 7 gamma-pivot):
        // bump to MSL 2.3 so SPIRV-Cross can emit pull-model
        // interpolation (`stage_in.X.interpolate_at_sample(N)` /
        // `interpolate_at_centroid()` / `interpolate_at_offset(o)`).
        // Without 2.3, SPIRV-Cross throws "Pull-model interpolation
        // requires MSL 2.3." for every FS using `interpolateAt*` GLSL
        // functions, leaving the program unlinked. CTS
        // KHR-GL46.shader_multisample_interpolation.render.{interpolate_at_*}
        // (72F before this fix) all hit this wall. MSL 2.3 minimum
        // matches macOS 11 Big Sur (Nov 2020), well below our 12.0+
        // host minimum.
        //
        // Sprint 19: only shaders that actually use GL_EXT_fragment_shading_rate
        // builtins need MSL 2.4 (`[[shading_rate]]` /
        // `[[primitive_shading_rate]]`). Keep the rest of the runtime on the
        // long-held MSL 2.3 ABI so unrelated translated/GS pass-through
        // pipelines do not inherit FSR-specific compiler behavior.
        if (resourcesUseMultiviewBuiltins(shaderResourcesForOptions)) {
            mslOpts.multiview = true;
            mslOpts.multiview_layered_rendering = true;
        }
        if (options.fp64EmulationAvailable &&
            spirvModuleDeclaresFp64(spirv, wordCount)) {
            mslOpts.appgl_fp64_emulation = true;
        }
        if (resourcesUseFragmentShadingRateBuiltins(shaderResourcesForOptions)) {
            mslOpts.set_msl_version(2, 4);
        } else {
            mslOpts.set_msl_version(2, 3);
        }
        mslOpts.enable_decoration_binding = true;
        // Pad fragment outputs to vec4 so Metal doesn't reject pipelines
        // where the shader outputs fewer components than the render target
        // format (e.g. float → MTLPixelFormatRGBA8Unorm).
        mslOpts.pad_fragment_output_components = true;
        // Step 7 (phase-7-1): env-gated argument-buffers (Tier-2)
        // emission. When APPGL_ENABLE_ARGUMENT_BUFFERS=1, SPIRV-Cross
        // emits the fragment/vertex/compute entry points with
        // `constant spvDescriptorSetBufferN& spvDescriptorSetN
        // [[buffer(N)]]` arguments instead of individual
        // `[[texture(N)]]` / `[[sampler(N)]]` / `[[buffer(N)]]`
        // parameters. Unlocks Metal's per-stage 31-texture limit
        // (matches Metal 3 bindless resource counts) and is required
        // for the advertised GL_MAX_TEXTURE_IMAGE_UNITS=48 to work on
        // shaders that actually sample all 48 units.
        //
        // THE METAL-SIDE BINDING IS NOT YET WIRED — enabling this env
        // var WILL BREAK tests because the CPU-side encoder still
        // calls setFragmentTexture/Sampler/Buffer with direct slots.
        // A follow-up phase 7-2 adds the argument-buffer construction
        // on the consumer side. This commit's scope is just the
        // translator opt-in; leaving the baseline untouched so the
        // full Phase 6 arc + the 67-test win stack stays intact.
        //
        // Tier-2 (vs Tier-1): Apple Silicon M1+ supports Tier-2
        // (writable images on macOS + higher resource limits). We
        // advertise + require Apple7-class GPUs, so Tier-2 is always
        // the right pick.
        const bool forceArgBuf = options.forceArgumentBuffers ||
            (std::getenv("APPGL_ENABLE_ARGUMENT_BUFFERS") != nullptr);
        if (forceArgBuf) {
            // MSL 3.0 required for Tier-2 full mutable aliasing —
            // SPIRV-Cross throws "Full mutable aliasing of argument
            // buffer descriptors only works on Metal 3+" when this
            // option is enabled with MSL < 3.0. Available on macOS 13
            // (Ventura, 2022) and later; safe bump because we require
            // Apple7+ GPUs which are all on macOS ≥ 13 by now.
            mslOpts.set_msl_version(3, 0);
            mslOpts.argument_buffers = true;
            mslOpts.argument_buffers_tier =
                spirv_cross::CompilerMSL::Options::ArgumentBuffersTier::Tier2;
        }
        compiler.set_msl_options(mslOpts);

        // Phase 7 [metal-tess-TF]: cross-stage wiring (Track 2 scaffold).
        // When translating TCS-as-compute and the caller passed the linked
        // TES's SPIR-V, walk TES's INPUT user varyings and call
        // add_msl_shader_output on this (TCS) CompilerMSL for each. Tells
        // SPIRV-Cross "the next stage reads slots N..M, ensure your
        // main0_out includes them at matching locations." Filters out
        // built-ins (gl_TessCoord, gl_PrimitiveID, gl_PatchVerticesIn,
        // gl_Position, gl_PointSize, gl_ClipDistance) — those are handled
        // by SPIRV-Cross's own gl_PerVertex propagation, and propagating
        // them as user-named outputs would inject placeholder uint slots
        // that displace the user-varying layout (observed in scaffold v1
        // as a `uint m_111` field corrupting tc_position offsets).
        // Filters out per-patch (`patch in`) varyings — TES's per-patch
        // inputs come from the patch buffer (atIndex 20), not the per-CP
        // buffer (atIndex 22).
        if (isTessControl && options.siblingTesInputSpirv != nullptr &&
            options.siblingTesInputWordCount > 0) {
            try {
                spirv_cross::Compiler tesSibling(
                    options.siblingTesInputSpirv, options.siblingTesInputWordCount);
                const auto activeIds = tesSibling.get_active_interface_variables();
                std::size_t wired = 0;
                std::size_t skippedBuiltin = 0;
                std::size_t skippedPatch = 0;
                // Sprint 4 Phase 1 fix: SPIRV-Cross's
                // `add_msl_shader_output` keys `outputs_by_location` on
                // (location, component). When TES has multiple loose
                // top-level varyings without explicit
                // `layout(location=N)` decorations, glslang's auto-
                // assignment may not emit `OpDecorate Location` (for
                // monolithic programs in particular), and our
                // `has_decoration(... Location)` test returns false →
                // all entries collapse to (0, 0) and only the last-
                // added survives in the map. The downstream
                // `classify_tcs_outputs_by_consumption` then sees
                // only one name in `consumed_names`, the other TCS
                // outputs land in threadgroup memory, and TES reads
                // zero. Assign a unique synthetic location per wired
                // entry. Critically, TCS's emitted main0_out struct
                // field order is determined by location-sort, while
                // TES's main0_in is laid out by SPIR-V variable ID.
                // To keep the per-CP buffer stride / field offsets
                // matched cross-stage, use the TES variable's ID as
                // the synthetic location (offset to a high range so
                // it doesn't collide with natural < 64 locations or
                // the classifier's 0xF000_0000+ range).
                for (auto id : activeIds) {
                    const spv::StorageClass sc = tesSibling.get_storage_class(id);
                    if (sc != spv::StorageClassInput) continue;
                    // Direct-decorated builtins (rare for tess: gl_PrimitiveID
                    // / gl_PatchVerticesIn might land here as standalone
                    // variables) — skip.
                    if (tesSibling.has_decoration(id, spv::DecorationBuiltIn)) {
                        ++skippedBuiltin;
                        continue;
                    }
                    // Block-typed variables (interface blocks like `in OUT_TC
                    // { … } in_data[]` and gl_PerVertex) — the user-named
                    // block is already coordinated across stages by
                    // glslang's link+mapIO at the location level, so TCS-
                    // out's emission already includes the matching block on
                    // the symmetric output side. Calling add_msl_shader_output
                    // with a block-typed variable causes SPIRV-Cross to
                    // synthesize a placeholder `uint m_<id>` member that
                    // displaces the user-varying layout (observed in scaffold
                    // v1/v2 as `uint m_111` corrupting tc_position offsets).
                    // Skip blocks entirely; only wire loose top-level
                    // varyings — those are the ones that can mismatch
                    // between sibling stages without coordination.
                    const auto& varType = tesSibling.get_type_from_variable(id);
                    const auto typeSelfId = varType.self;
                    if (tesSibling.has_decoration(typeSelfId, spv::DecorationBlock) ||
                        tesSibling.has_decoration(typeSelfId, spv::DecorationBufferBlock)) {
                        ++skippedBuiltin;  // counter doubles for "block-skipped"
                        continue;
                    }
                    if (!varType.member_types.empty() &&
                        tesSibling.has_member_decoration(typeSelfId, 0, spv::DecorationBuiltIn)) {
                        ++skippedBuiltin;
                        continue;
                    }
                    if (tesSibling.has_decoration(id, spv::DecorationPatch)) {
                        ++skippedPatch;
                        continue;
                    }
                    spirv_cross::MSLShaderInterfaceVariable sib;
                    // When TES emits an explicit Location decoration,
                    // honor it (separable programs path). Otherwise
                    // synthesize from the TES variable's ID — IDs are
                    // unique per module and ID-order matches TES's
                    // main0_in field-emission order, so TCS's
                    // location-sort emission of main0_out lands fields
                    // at the same offsets TES reads from.
                    sib.location = tesSibling.has_decoration(id, spv::DecorationLocation)
                        ? tesSibling.get_decoration(id, spv::DecorationLocation)
                        : (0xE0000000u + (std::uint32_t)id);
                    sib.component = tesSibling.has_decoration(id, spv::DecorationComponent)
                        ? tesSibling.get_decoration(id, spv::DecorationComponent) : 0;
                    sib.format = spirv_cross::MSL_SHADER_VARIABLE_FORMAT_OTHER;
                    sib.builtin = spv::BuiltInMax;
                    sib.vecsize = varType.vecsize > 0 ? varType.vecsize : 1;
                    sib.rate = spirv_cross::MSL_SHADER_VARIABLE_RATE_PER_VERTEX;
                    // Option C [metal-tess-TF]: feed the sibling's source
                    // name so the TCS classifier (split_tcs_outputs_by
                    // _consumption) can name-match across stages.
                    // Separable programs auto-assign locations per-stage
                    // independently, so location alone is unstable as a
                    // cross-stage identifier.
                    sib.name = tesSibling.get_name(id);
                    compiler.add_msl_shader_output(sib);
                    ++wired;
                    if (std::getenv("APPGL_DUMP_TESOUT")) {
                        std::fprintf(stderr,
                            "APPGL_DETECTOR xstage_name id=%u name='%s' loc=%u "
                            "vecsize=%u\n",
                            (unsigned)id, sib.name.c_str(),
                            (unsigned)sib.location, (unsigned)sib.vecsize);
                    }
                }
                if (std::getenv("APPGL_DETECTOR_TF") || std::getenv("APPGL_TRACE_TESS")) {
                    std::fprintf(stderr,
                        "APPGL_DETECTOR lift_xstage stage=tcs sibling=tes-input "
                        "active=%zu wired=%zu skipped_builtin=%zu skipped_patch=%zu\n",
                        activeIds.size(), wired, skippedBuiltin, skippedPatch);
                }
            } catch (const std::exception& e) {
                if (std::getenv("APPGL_TRACE_TESS")) {
                    std::fprintf(stderr,
                        "[APPGL] cross-stage wiring (TCS←TES) failed: %s\n", e.what());
                }
            }
        }

        // tc_barriers cluster — inverse direction. When translating TES
        // and the caller passed the linked TCS's SPIR-V, walk TCS's
        // OUTPUT interface variables and call add_msl_shader_input on
        // this (TES) CompilerMSL for each USER VARYING the TES doesn't
        // already declare. The mismatch this closes: TCS uses some of
        // its own outputs internally (read after barrier()), so SPIRV-
        // Cross can't trim main0_out — the device per-CP buffer stride
        // grows beyond what TES's main0_in covers, and TES reads at the
        // wrong offset. By teaching TES "the previous stage put extra
        // slots in your input struct," we re-align the per-CP stride.
        // Filters mirror the TCS-direction block: builtins, blocks,
        // and `patch out` are skipped.
        //
        // Option C supersedes this branch entirely. When TCS uses
        // `split_tcs_outputs_by_consumption=true` + name-aware wiring
        // via siblingTesInputSpirv, its main0_out is trimmed to TES-
        // consumed slots only — the per-CP stride matches TES's
        // main0_in natively. The TES-side padding workaround adds
        // duplicate inputs (location-based dedup misses tcs-out /
        // tes-in pairs that lack OpDecorate Location), corrupting
        // layouts under Option C. Disabled unconditionally now that
        // Option C is the canonical cross-stage path; siblingTcsOutput
        // Spirv option still exists on TranslatorOptions for binary-
        // compat, but no longer triggers any emission change. Keeping
        // the block in place until callers stop populating the option
        // (cosmetic cleanup).
        // Sprint 6 Phase 1 sub-task 2: Path J' β orchestrator TES-input
        // extension. Re-enabled now that SPIRV-Cross fork's Path J'
        // Option E.2 (`01cfa15`) lands. Option E.2 widens Option E's
        // Pass 1 gathering to capture all natural Input variable names
        // (with OR without OpDecorate Location). Pass 3 dedupes
        // synthetic-range entries against the widened natural-name set,
        // covering monolithic programs (CKPT30 finding: TES inputs lack
        // Location decoration in monolithic programs but have names).
        const bool isTessEvalAny = isTessEval ||
            (isVertex && options.forceTessEvalAsCompute);  // false-safe; TES path is isTessEval
        if (isTessEvalAny && options.siblingTcsOutputSpirv != nullptr &&
            options.siblingTcsOutputWordCount > 0) {
            try {
                spirv_cross::Compiler tcsSibling(
                    options.siblingTcsOutputSpirv, options.siblingTcsOutputWordCount);
                // Collect TES's natural input NAMES — used to filter TCS
                // outputs to "those that TES actually reads." TCS-internal
                // outputs (like barrier_guarded_*'s test_vector) must NOT
                // be added; SPIRV-Cross's Pass 3 dedupe only fires when
                // names match natural entries. TCS-internal-only outputs
                // (NOT in TES inputs) wouldn't have a natural counterpart,
                // would be added as new entries → m_<N> placeholders.
                std::set<std::string> tesInputNames;
                {
                    const auto activeTes = compiler.get_active_interface_variables();
                    for (auto id : activeTes) {
                        if (compiler.get_storage_class(id) != spv::StorageClassInput) continue;
                        const std::string& name = compiler.get_name(id);
                        if (name.empty()) continue;
                        tesInputNames.insert(name);
                    }
                }
                // Legacy alias for diagnostic line below.
                std::set<std::pair<std::uint32_t,std::uint32_t>> tesInputLocs;
                // Path J' E.4 synchronized landing — paired with
                // SPIRV-Cross `0ee35f2` flag-gated emission. CKPT42 A/B
                // test confirmed Config B (flag + ID-ascending sort)
                // PASSES while Config A (flag only) FAILS. E.4's
                // emission aspect honors call order — and our call
                // order is the iteration order of
                // `get_active_interface_variables()` (an unordered_set
                // returning non-deterministic iteration). Sorting
                // active TCS interface IDs ascending reproduces TCS's
                // natural main0_out emission walk (SPIR-V variable IDs
                // ascend in declaration order). Without this sort,
                // call order mismatches TCS emission and TES main0_in
                // bytes don't align with TCS main0_out bytes.
                std::vector<spirv_cross::ID> activeIds;
                {
                    const auto activeSet = tcsSibling.get_active_interface_variables();
                    activeIds.assign(activeSet.begin(), activeSet.end());
                    std::sort(activeIds.begin(), activeIds.end(),
                        [](spirv_cross::ID a, spirv_cross::ID b) {
                            return static_cast<std::uint32_t>(a) <
                                   static_cast<std::uint32_t>(b);
                        });
                }
                std::size_t wired = 0;
                std::size_t skippedBuiltin = 0;
                std::size_t skippedPatch = 0;
                std::size_t skippedExisting = 0;
                for (auto id : activeIds) {
                    const spv::StorageClass sc = tcsSibling.get_storage_class(id);
                    if (sc != spv::StorageClassOutput) continue;
                    if (tcsSibling.has_decoration(id, spv::DecorationBuiltIn)) {
                        ++skippedBuiltin;
                        continue;
                    }
                    const auto& varType = tcsSibling.get_type_from_variable(id);
                    const auto typeSelfId = varType.self;
                    if (tcsSibling.has_decoration(typeSelfId, spv::DecorationBlock) ||
                        tcsSibling.has_decoration(typeSelfId, spv::DecorationBufferBlock)) {
                        ++skippedBuiltin;
                        continue;
                    }
                    if (!varType.member_types.empty() &&
                        tcsSibling.has_member_decoration(typeSelfId, 0, spv::DecorationBuiltIn)) {
                        ++skippedBuiltin;
                        continue;
                    }
                    if (tcsSibling.has_decoration(id, spv::DecorationPatch)) {
                        ++skippedPatch;
                        continue;
                    }
                    // Skip TCS outputs that TES doesn't read — those are
                    // TCS-internal varyings (like barrier_guarded_*'s
                    // test_vector). Option E.2's Pass 3 only dedupes if
                    // the synthetic-range name matches a natural entry;
                    // TCS-internal outputs wouldn't match → added as new
                    // entries → m_<N> placeholders → barrier regression.
                    const std::string tcsName = tcsSibling.get_name(id);
                    if (tcsName.empty() || !tesInputNames.count(tcsName)) {
                        ++skippedExisting;
                        continue;
                    }
                    // Synthetic location (0xE0000000+id). Option E.2's
                    // Pass 3 (`01cfa15`) dedupes synthetic-range entries
                    // against natural names (with/without Location
                    // decoration). Re-orders TES main0_in emission to
                    // match TCS main0_out emission order — Path J'
                    // field-order parity goal.
                    const std::uint32_t loc = tcsSibling.has_decoration(id, spv::DecorationLocation)
                        ? tcsSibling.get_decoration(id, spv::DecorationLocation)
                        : (0xE0000000u + (std::uint32_t)id);
                    const std::uint32_t comp = tcsSibling.has_decoration(id, spv::DecorationComponent)
                        ? tcsSibling.get_decoration(id, spv::DecorationComponent) : 0;
                    spirv_cross::MSLShaderInterfaceVariable sib;
                    sib.location = loc;
                    sib.component = comp;
                    sib.format = spirv_cross::MSL_SHADER_VARIABLE_FORMAT_OTHER;
                    sib.builtin = spv::BuiltInMax;
                    sib.vecsize = varType.vecsize > 0 ? varType.vecsize : 1;
                    sib.rate = spirv_cross::MSL_SHADER_VARIABLE_RATE_PER_VERTEX;
                    sib.name = tcsName;
                    compiler.add_msl_shader_input(sib);
                    ++wired;
                }
                if (std::getenv("APPGL_DETECTOR_TF") || std::getenv("APPGL_TRACE_TESS")) {
                    std::fprintf(stderr,
                        "APPGL_DETECTOR lift_xstage stage=tes sibling=tcs-output "
                        "active=%zu wired=%zu skipped_builtin=%zu skipped_patch=%zu skipped_existing=%zu\n",
                        activeIds.size(), wired, skippedBuiltin, skippedPatch, skippedExisting);
                }
            } catch (const std::exception& e) {
                if (std::getenv("APPGL_TRACE_TESS")) {
                    std::fprintf(stderr,
                        "[APPGL] cross-stage wiring (TES←TCS) failed: %s\n", e.what());
                }
            }
        }

        // Sprint 17 Day 3+ BONUS-1 [clip_control]: drive SPIRV-Cross's
        // depth-fixup flag from the per-link `clipDepthMode` snapshot
        // captured at translation time.
        //   GL_NEGATIVE_ONE_TO_ONE (GL default, [-1,+1] clip-z) →
        //     fixup_clipspace=true; SPIRV-Cross emits
        //     `gl_Position.z = (z + w) * 0.5` so the [0,+1] Metal
        //     clip-z range receives the correctly-mapped value.
        //   GL_ZERO_TO_ONE (D3D-like [0,+1] clip-z) →
        //     fixup_clipspace=false; the GL clip-z range already
        //     matches Metal's, no shader-side mapping needed.
        // Origin side (`flip_vert_y`) stays default false — AppGL
        // already handles the GL bottom-up → Metal top-down convention
        // via the viewport descriptor's `originY = rtH - glY - glH`
        // flip in MetalFrameGraph (single-source-of-truth). Enabling
        // SPIRV-Cross flip_vert_y here would compound with that
        // viewport-flip into a double-flip artifact on UPPER_LEFT.
        spirv_cross::CompilerGLSL::Options glslOpts = compiler.get_common_options();
        glslOpts.vertex.fixup_clipspace =
            (options.clipDepthMode == GL_NEGATIVE_ONE_TO_ONE);
        compiler.set_common_options(glslOpts);

        // Remap uniform buffers (UBOs + push constants) to Metal buffer slots.
        // UBO arrays occupy consecutive Metal buffer indices, so we compute
        // a running offset rather than using uniformBufferBase + glBinding
        // (which would overlap when array sizes > 1).
        //
        // IMPORTANT: filter to only ACTIVE UBOs. In linked SPIR-V, an
        // unused UBO may share the same binding number as an active one
        // (glslang assigns binding=0 to dead variables). If we register
        // both with add_msl_resource_binding, the inactive one's slot
        // overwrites the active one's (keyed by desc_set+binding),
        // causing a Metal buffer slot mismatch at draw time.
        auto resources = compiler.get_shader_resources();
        auto activeVars = compiler.get_active_interface_variables();
        constexpr std::uint32_t kAtomicCounterSyntheticBindingBase = 64;
        const std::uint32_t atomicCounterDirectBufferBase =
            bindings.atomicCounterBufferBase;
        auto isAtomicCounterStorageBuffer = [&](const spirv_cross::Resource& res) {
            auto hasAtomicCounterName = [](const std::string& name) {
                return name.find("AtomicCounter") != std::string::npos ||
                       name.find("atomicCounter") != std::string::npos;
            };
            if (hasAtomicCounterName(res.name)) return true;
            try {
                const auto& type = compiler.get_type(res.base_type_id);
                if (hasAtomicCounterName(compiler.get_name(type.self))) return true;
            } catch (...) {
            }
            return false;
        };
        auto parseAtomicCounterBlockBinding = [](const std::string& name,
                                                 std::uint32_t& binding) {
            const char* needle = "AtomicCounterBlock_";
            const std::size_t pos = name.find(needle);
            if (pos == std::string::npos) return false;
            const std::size_t start = pos + std::strlen(needle);
            if (start >= name.size() ||
                !std::isdigit(static_cast<unsigned char>(name[start]))) {
                return false;
            }
            char* end = nullptr;
            const unsigned long value =
                std::strtoul(name.c_str() + start, &end, 10);
            if (end == name.c_str() + start) return false;
            binding = static_cast<std::uint32_t>(value);
            return true;
        };
        auto atomicCounterStorageBinding = [&](const spirv_cross::Resource& res) {
            std::uint32_t parsed = 0;
            if (parseAtomicCounterBlockBinding(res.name, parsed)) return parsed;
            try {
                const auto& type = compiler.get_type(res.base_type_id);
                if (parseAtomicCounterBlockBinding(
                        compiler.get_name(type.self), parsed)) {
                    return parsed;
                }
            } catch (...) {
            }
            return compiler.get_decoration(res.id, spv::DecorationBinding);
        };

        // GL 4.6 §7.4.1 (separate programs) — when a shader is compiled
        // as a separable program via glCreateShaderProgramv, glslang's
        // setAutoMapLocations(true) assigns Location decorations to bare
        // top-level `in`/`out` varyings but *leaves interface-block*
        // variables undecorated (the block member SPIR-V decorations
        // use MemberDecoration/Offset rather than an OpVariable-level
        // Location). SPIRV-Cross then emits MSL without any
        // `[[user(locnN)]]` attribute and Metal can't match the VS's
        // stage_out names (e.g. `vs_out_color`) against the FS's
        // stage_in names (e.g. `fs_in_color`) across a program
        // pipeline. CTS `vertex_attrib_binding.basic-*` exercises this.
        //
        // Synthesize Location decorations here so MSL gets
        // `[[user(locnN)]]` on every user varying. Sort interface
        // variables by SPIR-V source name so the VS and FS independent
        // compilations agree: both stages declare the same blocks in
        // the same GLSL order, producing the same sort key and
        // therefore the same Location values. Keep any glslang-assigned
        // Location untouched; only fill in missing ones starting from
        // the next-available slot.
        auto assignMissingLocations = [&compiler](
            auto& vars) {
            // Determine the highest already-used Location so we don't
            // collide with explicit `layout(location=N)` qualifiers.
            std::uint32_t nextLoc = 0;
            bool anyExplicit = false;
            for (auto& v : vars) {
                if (compiler.has_decoration(v.id, spv::DecorationLocation)) {
                    auto loc = compiler.get_decoration(v.id, spv::DecorationLocation);
                    if (!anyExplicit || loc >= nextLoc) {
                        nextLoc = loc + 1;
                        anyExplicit = true;
                    }
                }
            }
            // Collect vars that still need a Location, sorted by the
            // block's SPIR-V name (set by glslang from the GLSL
            // interface block's *type* name — identical across VS/FS
            // for matching blocks per GLSL 4.60 §4.4.1).
            struct Pending {
                std::uint32_t id;
                std::string sortKey;
            };
            std::vector<Pending> pending;
            for (auto& v : vars) {
                if (compiler.has_decoration(v.id, spv::DecorationLocation)) {
                    continue;
                }
                Pending p;
                p.id = v.id;
                // Prefer the block type name (stable across VS/FS);
                // fall back to variable name when not an interface block.
                p.sortKey = compiler.get_name(v.base_type_id);
                if (p.sortKey.empty()) {
                    p.sortKey = v.name;
                }
                pending.push_back(p);
            }
            std::sort(pending.begin(), pending.end(),
                [](const Pending& a, const Pending& b) {
                    return a.sortKey < b.sortKey;
                });
            for (const auto& p : pending) {
                compiler.set_decoration(p.id, spv::DecorationLocation, nextLoc);
                nextLoc++;
            }
        };
        auto repairDuplicateLocations = [&compiler](
            auto& vars) {
            std::set<std::pair<std::uint32_t, std::uint32_t>> occupied;
            auto outputIndex = [&compiler](const auto& v) -> std::uint32_t {
                if (compiler.has_decoration(v.id, spv::DecorationIndex)) {
                    return compiler.get_decoration(v.id, spv::DecorationIndex);
                }
                return 0u;
            };
            auto markOccupied = [&](std::uint32_t first, std::uint32_t count,
                                    std::uint32_t index) {
                count = std::max<std::uint32_t>(1, count);
                for (std::uint32_t i = 0; i < count; ++i) {
                    occupied.emplace(first + i, index);
                }
            };
            auto arraySlots = [&compiler](const auto& v) -> std::uint32_t {
                const auto& type = compiler.get_type(v.type_id);
                if (!type.array.empty() && type.array[0] > 0) {
                    return type.array[0];
                }
                return 1u;
            };
            for (auto& v : vars) {
                if (!compiler.has_decoration(v.id, spv::DecorationLocation)) {
                    continue;
                }
                std::uint32_t loc =
                    compiler.get_decoration(v.id, spv::DecorationLocation);
                const std::uint32_t slots = arraySlots(v);
                const std::uint32_t index = outputIndex(v);
                bool collides = false;
                for (std::uint32_t i = 0; i < slots; ++i) {
                    if (occupied.count({loc + i, index}) != 0) {
                        collides = true;
                        break;
                    }
                }
                if (collides) {
                    loc = 0;
                    while (true) {
                        bool freeRange = true;
                        for (std::uint32_t i = 0; i < slots; ++i) {
                            if (occupied.count({loc + i, index}) != 0) {
                                freeRange = false;
                                break;
                            }
                        }
                        if (freeRange) break;
                        ++loc;
                    }
                    compiler.set_decoration(v.id, spv::DecorationLocation, loc);
                }
                markOccupied(loc, slots, index);
            }
        };
        if (execModel == spv::ExecutionModelVertex) {
            assignMissingLocations(resources.stage_inputs);
            assignMissingLocations(resources.stage_outputs);
        } else if (execModel == spv::ExecutionModelGeometry) {
            assignMissingLocations(resources.stage_outputs);
        } else if (execModel == spv::ExecutionModelTessellationEvaluation &&
                   options.forceTessellation &&
                   !options.forceTessEvalAsCompute) {
            assignMissingLocations(resources.stage_outputs);
        } else if (execModel == spv::ExecutionModelFragment) {
            assignMissingLocations(resources.stage_inputs);
            assignMissingLocations(resources.stage_outputs);
            repairDuplicateLocations(resources.stage_outputs);
        }

        {
            // Sort by GL binding to get a deterministic assignment order
            // that matches between spirvToMSL and reflect.
            struct UBOEntry { std::uint32_t glBinding; spirv_cross::Resource* res; std::uint32_t arraySize; };
            auto spirvArrayElementCount = [](const spirv_cross::SPIRType& type) -> std::uint32_t {
                std::uint32_t count = 1;
                for (const auto dim : type.array) {
                    count *= dim > 0 ? static_cast<std::uint32_t>(dim) : 1u;
                }
                return count;
            };
            std::vector<UBOEntry> sortedUBOs;
            for (auto& ubo : resources.uniform_buffers) {
                // Skip UBOs not actively referenced in this stage.
                if (activeVars.find(ubo.id) == activeVars.end()) continue;
                UBOEntry e;
                e.glBinding = compiler.get_decoration(ubo.id, spv::DecorationBinding);
                e.res = &ubo;
                const auto& varType = compiler.get_type(ubo.type_id);
                e.arraySize = !varType.array.empty() ? spirvArrayElementCount(varType) : 1;
                sortedUBOs.push_back(e);
            }
            std::sort(sortedUBOs.begin(), sortedUBOs.end(),
                      [](const UBOEntry& a, const UBOEntry& b) { return a.glBinding < b.glBinding; });

            // UBOs and SSBOs live in separate binding namespaces in GL but
            // share (desc_set=0, binding=N) under the Vulkan-rules-relaxed
            // glslang output we feed into SPIRV-Cross. Move user UBOs to
            // set 1. The synthetic default-uniform block also appears in
            // resources.uniform_buffers on some programs; give it a private
            // binding inside set 1 so `uniform int x;` cannot alias a real
            // `layout(binding=0) uniform Block`.
            bool defaultUniformActive = false;
            for (auto& entry : sortedUBOs) {
                if (!isDefaultUniformBlockResource(compiler, *entry.res)) {
                    continue;
                }
                defaultUniformActive = true;
                compiler.set_decoration(entry.res->id, spv::DecorationDescriptorSet, 1);
                compiler.set_decoration(entry.res->id, spv::DecorationBinding,
                                        kDefaultUniformSyntheticBinding);
                spirv_cross::MSLResourceBinding binding;
                binding.stage = compiler.get_execution_model();
                binding.desc_set = 1;
                binding.binding = kDefaultUniformSyntheticBinding;
                binding.msl_buffer = bindings.uniformBufferBase;
                compiler.add_msl_resource_binding(binding);
            }

            std::uint32_t nextSlot = bindings.uniformBufferBase +
                (defaultUniformActive ? 1u : 0u);
            for (auto& entry : sortedUBOs) {
                if (isDefaultUniformBlockResource(compiler, *entry.res)) {
                    continue;
                }
                compiler.set_decoration(entry.res->id,
                    spv::DecorationDescriptorSet, 1);
                spirv_cross::MSLResourceBinding binding;
                binding.stage = compiler.get_execution_model();
                binding.desc_set = 1;  // UBO descriptor set (mirrors set_decoration above)
                binding.binding = entry.glBinding;
                binding.msl_buffer = nextSlot;
                compiler.add_msl_resource_binding(binding);
                nextSlot += entry.arraySize;
            }
        }

        // Step 7-2 consolidation: argument-buffers layout needs three
        // additional scoped adjustments relative to the direct-binding
        // baseline (all gated on APPGL_ENABLE_ARGUMENT_BUFFERS):
        //
        //   (a) The argument-buffer variables themselves (one per
        //       descriptor set) must sit at Metal buffer slots that
        //       don't collide with VBOs (`vertexBufferBase` = 0..15),
        //       push-constants (`uniformBufferBase` = 16), or legacy
        //       UBO slots (16..). We pin them at [[buffer(24)]] and
        //       [[buffer(25)]] for descriptor sets 0 and 1. SPIRV-Cross
        //       would otherwise auto-allocate starting from 0, stomping
        //       the VBO slot 0 on the VS stage.
        //
        //   (b) Storage images would otherwise get `msl_texture =
        //       textureBase + glBinding`, which under argument_buffers
        //       becomes [[id(glBinding)]] inside spvDescriptorSetBuffer0
        //       — colliding with sampled_images at 2*glBinding_sampled.
        //       Offset storage-image ids to 128+ so they live in a
        //       clearly-separated range.
        //
        //   (c) SSBOs would otherwise get `msl_buffer = storageBufferBase
        //       + K (=28+K)`, colliding with sampled-image ids 2*14..
        //       inside the same argument buffer. Offset SSBO ids to 192+
        //       so they sit above both sampled (0..) and storage (128..)
        //       image ranges.
        //
        // Full id-space layout per argument buffer (desc_set 0):
        //   [0..127]    sampled_images   (2*N for image, 2*N+1 for sampler)
        //   [128..191]  storage_images
        //   [192..255]  SSBOs
        //   [256..263]  atomic counters
        //
        // Desc_set 1 contains only UBOs, so no internal collision risk.
        // Push constants stay as a direct [[buffer(16)]] binding per
        // SPIRV-Cross's convention (they're never placed inside an
        // argument buffer by `analyze_argument_buffers`).
        const bool useArgBuf = forceArgBuf;
        if (useArgBuf) {
            // (a) Argument-buffer self-bindings. One per descriptor set
            // in use (0 = samplers/storage/SSBOs; 1 = UBOs). When a
            // descriptor set has no resources, the binding is silently
            // ignored by SPIRV-Cross.
            for (uint32_t set = 0; set < 2; ++set) {
                spirv_cross::MSLResourceBinding argBufBinding;
                argBufBinding.stage = compiler.get_execution_model();
                argBufBinding.desc_set = set;
                argBufBinding.binding = spirv_cross::kArgumentBufferBinding;
                argBufBinding.msl_buffer = 24 + set;
                compiler.add_msl_resource_binding(argBufBinding);
            }
        }

        // Remap push-constant blocks (SPIRV-Cross treats default-block uniforms
        // as a push-constant buffer when coming from OpenGL GLSL).
        for (auto& pc : resources.push_constant_buffers) {
            spirv_cross::MSLResourceBinding binding;
            binding.stage = compiler.get_execution_model();
            binding.desc_set = spirv_cross::kPushConstDescSet;
            binding.binding = spirv_cross::kPushConstBinding;
            binding.msl_buffer = bindings.uniformBufferBase;
            compiler.add_msl_resource_binding(binding);
        }

        // Remap shader-storage buffer objects (GL 4.3+). Assign Metal
        // buffer slots SEQUENTIALLY from `storageBufferBase` in
        // glBinding-sorted order — NOT `storageBufferBase + glBinding`
        // directly. GL permits bindings up to GL_MAX_SHADER_STORAGE_
        // BUFFER_BINDINGS (spec minimum 8), but Metal only exposes
        // 31 total buffer slots per stage of which we've reserved a
        // handful for SSBOs. Sequential allocation lets a shader
        // declare `layout(binding=7) buffer X` without us overflowing
        // Metal's slot budget — the reflection path mirrors this
        // ordering so dispatch-time bindings line up.
        //
        // Covers KHR-GL46.compute_shader.one-work-group which
        // iterates through bindings 0..7 over several sub-dispatches.
        {
            struct SSBORef { std::uint32_t glBinding; spirv_cross::Resource* res; };
            std::vector<SSBORef> sortedSSBOs;
            for (auto& ssbo : resources.storage_buffers) {
                if (isAtomicCounterStorageBuffer(ssbo)) continue;
                SSBORef r;
                r.glBinding = compiler.get_decoration(ssbo.id, spv::DecorationBinding);
                r.res = &ssbo;
                sortedSSBOs.push_back(r);
            }
            std::sort(sortedSSBOs.begin(), sortedSSBOs.end(),
                      [](const SSBORef& a, const SSBORef& b) { return a.glBinding < b.glBinding; });
            std::uint32_t nextSSBOSlot = bindings.storageBufferBase;
            for (std::size_t i = 0; i < sortedSSBOs.size(); ++i) {
                auto& entry = sortedSSBOs[i];
                std::uint32_t slotSpan = 1;
                const auto& varType = compiler.get_type(entry.res->type_id);
                if (!varType.array.empty()) {
                    slotSpan = 1;
                    for (const auto dim : varType.array) {
                        slotSpan *= dim > 0 ? static_cast<std::uint32_t>(dim) : 1u;
                    }
                }
                spirv_cross::MSLResourceBinding binding;
                binding.stage = compiler.get_execution_model();
                // Step 7-2 consolidation (c) — SSBO msl_buffer offset to
                // 192+ under argument_buffers mode to avoid colliding
                // with sampled-image ids (2*n) and storage-image ids
                // (128+n) within the same spvDescriptorSetBuffer0.
                // Direct-binding path unchanged (sequential from
                // storageBufferBase=28), but uses a private descriptor
                // set/key so sampled-image synthetic bindings 0..N do
                // not overwrite SSBO remaps that share GL binding
                // numbers.
                if (useArgBuf) {
                    binding.desc_set =
                        compiler.get_decoration(entry.res->id,
                                                spv::DecorationDescriptorSet);
                    binding.binding = entry.glBinding;
                    binding.msl_buffer = 192 + entry.glBinding;
                } else {
                    constexpr std::uint32_t kDirectSSBODescSet = 3;
                    const std::uint32_t syntheticBinding =
                        static_cast<std::uint32_t>(i);
                    compiler.set_decoration(entry.res->id,
                        spv::DecorationDescriptorSet, kDirectSSBODescSet);
                    compiler.set_decoration(entry.res->id,
                        spv::DecorationBinding, syntheticBinding);
                    binding.desc_set = kDirectSSBODescSet;
                    binding.binding = syntheticBinding;
                    binding.msl_buffer = nextSSBOSlot;
                    nextSSBOSlot += slotSpan;
                }
                compiler.add_msl_resource_binding(binding);
            }
        }

        // Atomic counters occupy their own GL binding namespace and
        // SPIRV-Cross lowers them as buffer resources. Under argument
        // buffers, leave SSBOs in the 192+ range and put atomic counters
        // above them so `layout(binding=N) uniform atomic_uint` cannot
        // collide with `layout(binding=N) buffer`.
        for (auto& atomicCounter : resources.atomic_counters) {
            const std::uint32_t glBinding =
                compiler.get_decoration(atomicCounter.id, spv::DecorationBinding);
            const std::uint32_t syntheticBinding =
                kAtomicCounterSyntheticBindingBase + glBinding;
            compiler.set_decoration(atomicCounter.id, spv::DecorationDescriptorSet, 0);
            compiler.set_decoration(atomicCounter.id, spv::DecorationBinding, syntheticBinding);
            spirv_cross::MSLResourceBinding binding;
            binding.stage = compiler.get_execution_model();
            binding.desc_set = 0;
            binding.binding = syntheticBinding;
            binding.msl_buffer = useArgBuf
                ? (256 + glBinding)
                : (atomicCounterDirectBufferBase + glBinding);
            compiler.add_msl_resource_binding(binding);
        }
        for (auto& atomicCounter : resources.storage_buffers) {
            if (!isAtomicCounterStorageBuffer(atomicCounter)) continue;
            const std::uint32_t glBinding =
                atomicCounterStorageBinding(atomicCounter);
            const std::uint32_t syntheticBinding =
                kAtomicCounterSyntheticBindingBase + glBinding;
            compiler.set_decoration(atomicCounter.id, spv::DecorationDescriptorSet, 0);
            compiler.set_decoration(atomicCounter.id, spv::DecorationBinding, syntheticBinding);
            spirv_cross::MSLResourceBinding binding;
            binding.stage = compiler.get_execution_model();
            binding.desc_set = 0;
            binding.binding = syntheticBinding;
            binding.msl_buffer = useArgBuf
                ? (256 + glBinding)
                : (atomicCounterDirectBufferBase + glBinding);
            compiler.add_msl_resource_binding(binding);
        }

        // Sprint 8 B Cluster F F1 Day 9 (CKPT81): unified sequential
        // allocator across sampled + storage images. Both occupy the
        // same Metal texture slot pool per stage; on Apple Silicon
        // outside argument-buffer mode, that pool is capped at 31 per
        // stage. CKPT77 fixed sampled images by collapsing GL bindings
        // 0..47 into [0, sampled_count). CKPT81 extends the same shape
        // to storage images: they're allocated AFTER the sampled
        // images at `nextSampledSlot..` rather than from the global
        // `storageImageBase=48` (which sat past Metal's 31-texture
        // limit and silently failed pipeline build, mirroring CKPT76's
        // sampled-binding-at-39 diagnostic, this time for image
        // uniforms).
        //
        // Apple-Silicon-31-resource-cap-cluster pattern, 3rd instance
        // (CKPT58 vertex attrs + CKPT76 sampled textures + CKPT81
        // storage images). The pool partition `sampled at 0..47,
        // storage at 48..55` was correct for the GL-spec advertised
        // limits but wrong for the underlying Metal hardware cap.
        std::uint32_t unifiedNextTextureSlot = bindings.textureBase;
        struct StorageImageAccessFixup {
            std::uint32_t metalSlot = 0;
            bool argumentBufferId = false;
            bool nonWritable = false;
            bool nonReadable = false;
        };
        std::vector<StorageImageAccessFixup> storageImageAccessFixups;
        std::vector<std::uint32_t> cubeStorageImageSlots;
        std::vector<std::uint32_t> cubeArrayStorageImageSlots;
        std::vector<std::uint32_t> multisampleStorageImageSlots;
        std::vector<std::uint32_t> multisampleStorageImageArraySlots;

        // Remap sampled images (combined image samplers).
        //
        // Step 7-2: with argument_buffers enabled, Image and Sampler
        // halves of each SampledImage must land at DISTINCT argument-
        // buffer `[[id(N)]]` slots — SPIRV-Cross treats equal indices
        // as descriptor aliasing, which trips its fixup_hooks lambda
        // with a zero `overlapping_var_id` → Variant::get<SPIRVariable>
        // at spirv_common.hpp:1644 throws "nullptr". The argbuf branch
        // gives image and sampler separate id ranges (2*glBinding and
        // 2*glBinding + 1).
        //
        // Sprint 8 B Cluster F F1 Day 5 (CKPT77): in the direct-binding
        // path, allocate Metal texture/sampler slots SEQUENTIALLY in
        // glBinding-sorted order — NOT `textureBase + glBinding`
        // directly. GL advertises GL_MAX_TEXTURE_IMAGE_UNITS = 48 and
        // CTS layout_binding tests legally declare
        // `layout(binding=39) uniform sampler2D s;` (and binding values
        // up to 47 across binding_array_size sub-tests). However Apple
        // Silicon Metal silently fails pipeline state build when MSL
        // declares `[[texture(N)]]` for N >= 31 in the fragment stage
        // outside argument-buffer mode — `newRenderPipelineState…`
        // returns nil, the draw is queued against a non-bound pipeline,
        // no fragment runs, and the framebuffer stays at clear color.
        // This shape was diagnosed in CKPT76 via the APPGL_LOG_LB
        // trace: glUnit=39, metalSlot=39, texture pointer non-null,
        // but rendered pixel = (0,0,0,1) instead of the expected
        // green texture (0,1,0,1). The MSL dump showed
        // `[[texture(39)]]` emitted directly from GL binding 39.
        //
        // Sequential allocation collapses the [0..47] GL binding range
        // into the dense [0..N) Metal slot range where N is the count
        // of sampled images actually used in the program — typically
        // 1..16 for cluster F tests, well inside Metal's 31-texture
        // budget. The runtime-side resolver still uses the original
        // `glBinding` for the GL texture-unit lookup (via the GL
        // sampler uniform value), and `metalBinding` for the Metal
        // slot. Reflection mirrors the same sort + sequential index so
        // dispatch-time `setFragmentTexture(tex, atIndex:metalBinding)`
        // lines up with the MSL `[[texture(metalBinding)]]` slot.
        //
        // Sampler arrays (`uniform sampler2D arr[N]`) consume N
        // consecutive Metal slots — the runtime adds `arrayElement` to
        // `metalBinding` when binding each element (see
        // GLContext.mm::resolveStage). Sequential allocator must
        // advance `nextSlot` by the array size per entry so the next
        // sampler doesn't collide with arr[N-1].
        //
        // Argument-buffer mode is unchanged (uses distinct
        // 2*glBinding / 2*glBinding+1 ranges inside spvDescriptorSetBuffer0
        // — argbuf programs sit on the deferred path and aren't part
        // of the current cluster F failure mode).
        {
            struct SampledRef {
                std::uint32_t glBinding;
                std::uint32_t id;
                std::uint32_t arraySize;  // 1 for scalar, N for `samplerXX arr[N]`
                spirv_cross::Resource* res;
            };
            std::vector<SampledRef> sortedSampled;
            for (auto& img : resources.sampled_images) {
                SampledRef r;
                r.glBinding = compiler.get_decoration(img.id, spv::DecorationBinding);
                r.id = img.id;
                const auto& imgType = compiler.get_type(img.type_id);
                r.arraySize = imgType.array.empty()
                    ? 1u
                    : (imgType.array[0] > 0 ? imgType.array[0] : 1u);
                r.res = &img;
                sortedSampled.push_back(r);
            }
            std::sort(sortedSampled.begin(), sortedSampled.end(),
                      [](const SampledRef& a, const SampledRef& b) {
                          if (a.glBinding != b.glBinding) return a.glBinding < b.glBinding;
                          return a.id < b.id;
                      });
            for (std::size_t i = 0; i < sortedSampled.size(); ++i) {
                auto& entry = sortedSampled[i];
                spirv_cross::MSLResourceBinding binding;
                binding.stage = compiler.get_execution_model();
                binding.desc_set = compiler.get_decoration(entry.res->id, spv::DecorationDescriptorSet);
                if (useArgBuf) {
                    binding.binding = entry.glBinding;
                    binding.msl_texture = bindings.textureBase + 2 * entry.glBinding;
                    binding.msl_sampler = bindings.samplerBase + 2 * entry.glBinding + 1;
                } else {
                    // GLSL sampler uniforms without layout(binding=N)
                    // can share DecorationBinding=0. SPIRV-Cross keys
                    // add_msl_resource_binding on (stage,set,binding),
                    // so make the direct-Metal key unique while
                    // reflection preserves the original GL binding for
                    // runtime sampler-unit lookup.
                    const auto syntheticBinding = static_cast<std::uint32_t>(i);
                    compiler.set_decoration(entry.id, spv::DecorationBinding,
                                            syntheticBinding);
                    binding.binding = syntheticBinding;
                    binding.msl_texture = unifiedNextTextureSlot;
                    binding.msl_sampler = unifiedNextTextureSlot;
                    unifiedNextTextureSlot += entry.arraySize;
                }
                compiler.add_msl_resource_binding(binding);
            }
        }

        // Remap storage images (imageLoad/imageStore — GL `image2D` etc.).
        // These map to MSL `texture2d<T, access::read|write|read_write>`
        // and share Metal's single per-stage texture slot pool with
        // sampled images. Three independent collision concerns drive
        // the layout here:
        //
        //  (i) GL's sampler-uniform and image-uniform binding spaces
        //      are INDEPENDENT — a shader can legally declare both
        //      `layout(binding=0) uniform sampler2D s;` AND
        //      `layout(binding=0) uniform image2D i;` and the two
        //      units refer to different GL state. Metal has a single
        //      texture slot pool so we partition it: sampled at
        //      `textureBase..+47` (matches GL_MAX_TEXTURE_IMAGE_UNITS
        //      = 48 in caps) and storage at
        //      `storageImageBase..+7` (GL_MAX_IMAGE_UNITS = 8).
        //
        // (ii) Two storage-image uniforms can land with the same
        //      glBinding — e.g. `layout(rgba8) uniform image2D a;`
        //      and `layout(rgba8) uniform image2D b;`, both with no
        //      explicit binding, both taking SPIR-V
        //      DecorationBinding=0 from glslang. GL 4.6 §7.6 lets the
        //      app then call `glUniform1i(locA, 0)` and
        //      `glUniform1i(locB, 1)` to route them to distinct image
        //      units at runtime. Metal requires distinct per-resource
        //      slot indices, so we allocate SEQUENTIALLY from the
        //      storage-image range in glBinding-sorted order —
        //      mirroring how SSBOs are packed (see above) — and the
        //      reflection-side mirror uses the same ordering so
        //      dispatch-time binding resolution lines up.
        //
        // (iii) SPIRV-Cross's `add_msl_resource_binding` keys its
        //       table on `(stage, desc_set, binding)`. Both sampler
        //       and storage image arrive with desc_set=0 and the
        //       same glBinding, so two writes to the same triple
        //       silently overwrite each other. Fix: reassign storage
        //       images' `DecorationDescriptorSet` to 2 (unused —
        //       UBOs already sit at set=1) in direct-binding mode.
        //       Argument-buffer mode keeps set=0, but still assigns a
        //       unique synthetic binding and dense `[[id(N)]]` in the
        //       storage-image range so same-glBinding image uniforms
        //       do not collapse to one argument-buffer field.
        //
        // Reflection (in reflect() below) mirrors the sort and the
        // sequential `metalBinding = storageImageBase + seq`
        // assignment, while keeping the original glBinding for the
        // runtime-side glUniform1i lookup — that field drives the
        // GL image-unit → texture resolution in dispatchCompute /
        // resolveImageBindings.
        //
        // KHR-GL46.compute_shader.copy-image and resource-image also
        // rely on the GL-side bind routing to read a sampled binding
        // back into an image binding at draw time — that still works
        // because the routing happens via distinct reflection lists
        // (sampledTextures vs storageImages) with distinct metalSlot
        // values.
        {
            // Filter out declared-but-unused storage images to match
            // what reflect() does. SPIRV-Cross's dead-code pass elides
            // inactive images from the emitted MSL, so including them
            // in the sequential index allocation here would make
            // active images land at different msl_texture slots than
            // reflection expects — reflection also filters by
            // `get_active_interface_variables()`. Mirror that filter
            // so both sides agree on the seq→slot mapping.
            const auto activeVarsForImages = compiler.get_active_interface_variables();
            struct StorageImgRef {
                std::uint32_t glBinding;
                std::uint32_t id;
                std::uint32_t arraySize;
                bool nonWritable;
                bool nonReadable;
                bool cube = false;
                bool cubeArray = false;
                bool multisample = false;
                bool multisampleArray = false;
            };
            std::vector<StorageImgRef> sortedStorageImages;
            for (auto& img : resources.storage_images) {
                if (activeVarsForImages.find(img.id) == activeVarsForImages.end())
                    continue;
                StorageImgRef r;
                r.glBinding = compiler.get_decoration(img.id, spv::DecorationBinding);
                r.id = img.id;
                const auto& imgType = compiler.get_type(img.type_id);
                r.arraySize = imgType.array.empty()
                    ? 1u
                    : (imgType.array[0] > 0 ? imgType.array[0] : 1u);
                const auto& baseType = compiler.get_type(img.base_type_id);
                const auto& imageType =
                    imgType.basetype == spirv_cross::SPIRType::Image
                        ? imgType : baseType;
                r.cube =
                    imageType.basetype == spirv_cross::SPIRType::Image &&
                    imageType.image.dim == spv::DimCube &&
                    !imageType.image.arrayed &&
                    !imageType.image.ms;
                r.cubeArray =
                    imageType.basetype == spirv_cross::SPIRType::Image &&
                    imageType.image.dim == spv::DimCube &&
                    imageType.image.arrayed &&
                    !imageType.image.ms;
                r.multisampleArray =
                    imageType.basetype == spirv_cross::SPIRType::Image &&
                    imageType.image.dim == spv::Dim2D &&
                    imageType.image.ms &&
                    imageType.image.arrayed;
                r.multisample =
                    imageType.basetype == spirv_cross::SPIRType::Image &&
                    imageType.image.dim == spv::Dim2D &&
                    imageType.image.ms;
                r.nonWritable = compiler.has_decoration(img.id, spv::DecorationNonWritable);
                r.nonReadable = compiler.has_decoration(img.id, spv::DecorationNonReadable);
                sortedStorageImages.push_back(r);
            }
            std::sort(sortedStorageImages.begin(), sortedStorageImages.end(),
                      [](const StorageImgRef& a, const StorageImgRef& b) {
                          if (a.glBinding != b.glBinding) return a.glBinding < b.glBinding;
                          return a.id < b.id;
                      });
            std::uint32_t nextArgBufStorageImageSlot = 0;
            for (std::size_t i = 0; i < sortedStorageImages.size(); ++i) {
                const auto& entry = sortedStorageImages[i];
                spirv_cross::MSLResourceBinding binding;
                binding.stage = compiler.get_execution_model();
                if (useArgBuf) {
                    // Argument-buffer mode still shares one set-0
                    // id-space, but multiple image uniforms can have the
                    // same original GL binding and be routed later via
                    // glUniform1i. Give SPIRV-Cross a unique binding key
                    // and assign a dense id in the storage-image range
                    // while reflection keeps the original glBinding for
                    // runtime image-unit lookup.
                    const std::uint32_t syntheticBinding =
                        static_cast<std::uint32_t>(i);
                    compiler.set_decoration(entry.id,
                        spv::DecorationDescriptorSet, 0);
                    compiler.set_decoration(entry.id,
                        spv::DecorationBinding, syntheticBinding);
                    binding.desc_set = 0;
                    binding.binding = syntheticBinding;
                    binding.msl_texture = 128 + nextArgBufStorageImageSlot;
                    binding.msl_buffer =
                        bindings.storageImageAtomicBufferBase + static_cast<std::uint32_t>(i);
                    nextArgBufStorageImageSlot += std::max<std::uint32_t>(
                        entry.arraySize, 1u);
                    if (isGraphicsStage ||
                        execModel == spv::ExecutionModelGLCompute) {
                        storageImageAccessFixups.push_back({
                            binding.msl_texture, true,
                            entry.nonWritable, entry.nonReadable});
                    }
                    if (entry.cubeArray) {
                        cubeArrayStorageImageSlots.push_back(binding.msl_texture);
                    }
                    if (entry.cube) {
                        cubeStorageImageSlots.push_back(binding.msl_texture);
                    }
                    if (entry.multisample) {
                        multisampleStorageImageSlots.push_back(binding.msl_texture);
                    }
                    if (entry.multisampleArray) {
                        multisampleStorageImageArraySlots.push_back(binding.msl_texture);
                    }
                } else {
                    constexpr std::uint32_t kStorageImageDescSet = 2;
                    // Override both the descriptor-set AND the
                    // binding so the (stage, set, binding) triple is
                    // unique per image uniform even when multiple
                    // images came in with the same glBinding. The
                    // overridden binding is a SEQUENTIAL index into
                    // the sorted order, so reflection can reproduce
                    // it deterministically.
                    compiler.set_decoration(entry.id,
                        spv::DecorationDescriptorSet, kStorageImageDescSet);
                    compiler.set_decoration(entry.id,
                        spv::DecorationBinding, static_cast<std::uint32_t>(i));
                    binding.desc_set = kStorageImageDescSet;
                    binding.binding = static_cast<std::uint32_t>(i);
                    // CKPT81: allocate after the sampled-image
                    // sequential pool, not from the legacy
                    // `storageImageBase=48` constant. Same pool as
                    // sampled (Metal has one texture slot pool per
                    // stage), capped at 31 on Apple Silicon outside
                    // argbuf mode. Reflection mirrors below.
                    binding.msl_texture = unifiedNextTextureSlot;
                    binding.msl_buffer =
                        bindings.storageImageAtomicBufferBase + static_cast<std::uint32_t>(i);
                    unifiedNextTextureSlot += 1;
                    if (isGraphicsStage ||
                        execModel == spv::ExecutionModelGLCompute) {
                        storageImageAccessFixups.push_back({
                            binding.msl_texture, false,
                            entry.nonWritable, entry.nonReadable});
                    }
                    if (entry.cubeArray) {
                        cubeArrayStorageImageSlots.push_back(binding.msl_texture);
                    }
                    if (entry.cube) {
                        cubeStorageImageSlots.push_back(binding.msl_texture);
                    }
                    if (entry.multisample) {
                        multisampleStorageImageSlots.push_back(binding.msl_texture);
                    }
                    if (entry.multisampleArray) {
                        multisampleStorageImageArraySlots.push_back(binding.msl_texture);
                    }
                }
                compiler.add_msl_resource_binding(binding);
            }
        }

        const std::unordered_set<std::string> textureBufferResourceNames =
            collectTextureBufferResourceNames(compiler, resources);
        std::string msl = compiler.compile();

        if (!useArgBuf) {
            // Metal direct bindings expose 16 sampler-state slots. Texture
            // arrays can span higher slots, so oversized GLSL sampler arrays
            // keep their per-element texture array and share the first sampler.
            (void)collapseOversizedDirectSamplerArrays(msl);
        }
        (void)rewriteVectorImageAtomicBufferSubscripts(msl);
        (void)rewriteTexelBufferImageAtomicReads(msl);
        const std::uint32_t textureBufferSizeSlot =
            execModel == spv::ExecutionModelGLCompute
                ? kTextureBufferSizesComputeBufferSlot
                : kTextureBufferSizesGraphicsBufferSlot;
        (void)injectTextureBufferSizeSidecar(
            msl, textureBufferResourceNames, textureBufferSizeSlot);
        (void)fixUnsafeArrayDoubleIndex(msl);

        if (isVertex && mslOpts.appgl_fp64_emulation) {
            (void)lowerFp64VertexStageInputs(msl);
            (void)rewriteVertexFp64StageOutputTransport(msl);
        }
        if (isVertex) {
            std::string matrixArrayRewriteReason;
            if (!rewriteVertexMatrixArrayInputs(
                    msl,
                    compiler,
                    resources,
                    mslOpts.appgl_fp64_emulation,
                    &matrixArrayRewriteReason)) {
                if (log != nullptr) {
                    *log = matrixArrayRewriteReason;
                }
                return {};
            }
        }
        if (isVertex) {
            (void)injectPrimitiveFragmentShadingRateCombiner(msl);
            (void)adjustVertexInstanceIDForMetalBaseInstance(msl);
        }
        if (isVertex && options.enableClipControlYSignFixup) {
            (void)injectClipControlYSignFixup(msl);
        }

        if (isFragment && mslOpts.appgl_fp64_emulation) {
            (void)rewriteFragmentFp64StageInputTransport(msl);
        }
        if (mslOpts.appgl_fp64_emulation) {
            (void)rewritePackedFp64DefaultUniforms(msl);
            (void)injectFp64FractOverloads(msl);
        }
        if (isFragment) {
            // Sprint 18 Bank D-3 (`textures_bind_unit`): SPIRV-Cross
            // maps GLSL gl_FragCoord to Metal's top-left
            // `[[position]]`. For OpenGL's default LOWER_LEFT
            // convention, flip the fragment-side built-in through a
            // tiny per-draw buffer(15) payload. This is deliberately
            // separate from the 5930a4d/c196254 FBO readback
            // orientation markers: readback already unflips the
            // rendered renderbuffer; the shader's texelFetch coordinate
            // must be GL-space before the write happens.
            const auto& execModes = compiler.get_execution_mode_bitset();
            const bool originUpperLeft = options.fragmentCoordOriginUpperLeft;
            const bool pixelCenterInteger =
                execModes.get(spv::ExecutionModePixelCenterInteger);
            if (!originUpperLeft) {
                (void)injectFragmentCoordYFixup(msl, pixelCenterInteger);
            }
            // Compare coordinate control also owns nonseamless cube
            // clamping, so it must be present for UPPER_LEFT shaders even
            // though their 2D Y-flip flag stays clear.
            (void)injectDepthCompareControl(msl);
            (void)rewriteFragmentSamplePositionYForGL(msl);
            (void)rewriteFragmentInterpolateAtOffsetYForGL(msl);
        }

        // SSBO block arrays are lowered through argument buffers when
        // storage buffers are present. SPIRV-Cross emits these as
        // `[1] /* unsized array hack */` inside the argument-buffer struct,
        // but GL block arrays bind consecutive SSBO slots and the generated
        // MSL indexes the full declared range. Patch the argument-buffer
        // member declaration to the reflected fixed array size so indices
        // beyond zero reach the slots populated by resolveSSBOBindings().
        if (useArgBuf) {
            auto replaceAll = [](std::string& text,
                                 const std::string& needle,
                                 const std::string& replacement) {
                std::size_t pos = 0;
                while ((pos = text.find(needle, pos)) != std::string::npos) {
                    text.replace(pos, needle.size(), replacement);
                    pos += replacement.size();
                }
            };
            for (auto& ssbo : resources.storage_buffers) {
                if (isAtomicCounterStorageBuffer(ssbo)) continue;
                const auto& varType = compiler.get_type(ssbo.type_id);
                if (varType.array.empty() || varType.array[0] <= 1) {
                    continue;
                }
                const std::uint32_t glBinding =
                    compiler.get_decoration(ssbo.id, spv::DecorationBinding);
                const std::string attr =
                    "[[id(" + std::to_string(192 + glBinding) + ")]]";
                replaceAll(msl,
                    attr + "[1] /* unsized array hack */",
                    attr + "[" + std::to_string(varType.array[0]) + "]");
            }

            // Function parameters that take an argument-buffer member array
            // by reference can keep SPIRV-Cross's `[0]` size even after the
            // field declaration is widened above. Repair those references by
            // reading the emitted field name and array size directly.
            std::size_t pos = 0;
            while ((pos = msl.find("[[id(", pos)) != std::string::npos) {
                const std::size_t lineEnd = msl.find('\n', pos);
                const std::size_t effectiveLineEnd =
                    lineEnd == std::string::npos ? msl.size() : lineEnd;
                const std::size_t attrEnd = msl.find("]]", pos);
                if (attrEnd == std::string::npos ||
                    attrEnd + 2 >= effectiveLineEnd ||
                    msl[attrEnd + 2] != '[') {
                    pos += 5;
                    continue;
                }

                const std::size_t arrayOpen = attrEnd + 2;
                const std::size_t arrayClose =
                    msl.find(']', arrayOpen + 1);
                if (arrayClose == std::string::npos ||
                    arrayClose > effectiveLineEnd) {
                    pos = arrayOpen + 1;
                    continue;
                }

                std::uint32_t arraySize = 0;
                bool digitsOnly = true;
                for (std::size_t i = arrayOpen + 1; i < arrayClose; ++i) {
                    const unsigned char c =
                        static_cast<unsigned char>(msl[i]);
                    if (!std::isdigit(c)) {
                        digitsOnly = false;
                        break;
                    }
                    arraySize = arraySize * 10u +
                        static_cast<std::uint32_t>(msl[i] - '0');
                }
                if (!digitsOnly || arraySize <= 1) {
                    pos = arrayClose + 1;
                    continue;
                }

                std::size_t nameEnd = pos;
                while (nameEnd > 0) {
                    const unsigned char c =
                        static_cast<unsigned char>(msl[nameEnd - 1]);
                    if (!std::isspace(c)) break;
                    --nameEnd;
                }
                std::size_t nameBegin = nameEnd;
                while (nameBegin > 0) {
                    const unsigned char c =
                        static_cast<unsigned char>(msl[nameBegin - 1]);
                    if (!(std::isalnum(c) || c == '_')) break;
                    --nameBegin;
                }
                if (nameBegin == nameEnd) {
                    pos = arrayClose + 1;
                    continue;
                }

                const std::string name =
                    msl.substr(nameBegin, nameEnd - nameBegin);
                replaceAll(msl,
                    "(&" + name + ")[0]",
                    "(&" + name + ")[" + std::to_string(arraySize) + "]");
                pos = arrayClose + 1;
            }
        }

        // Sprint 18 Item 42 / shader_image_load_store: storage-image MSL
        // post-process, matching the established R3B padded-array and
        // R-argbuf spvBufferSizeConstants rewrite pattern. GL image
        // memory qualifiers are lowered to SPIR-V decorations:
        //   readonly  => NonWritable => Metal access::read
        //   writeonly => NonReadable => Metal access::write
        // SPIRV-Cross's AppGL fork intentionally emits read_write for
        // readonly storage images to keep reflection conservative, but
        // direct Metal pipelines need the precise access qualifier:
        // graphics image-read paths otherwise return zero, and compute
        // shaders with many readonly images can exceed writable-texture
        // limits before dispatch.
        if ((isGraphicsStage || execModel == spv::ExecutionModelGLCompute) &&
            !storageImageAccessFixups.empty()) {
            auto accessChar = [](char ch) {
                return (ch >= 'a' && ch <= 'z') ||
                       (ch >= 'A' && ch <= 'Z') ||
                       (ch >= '0' && ch <= '9') ||
                       ch == '_' || ch == ':';
            };
            auto setTextureAccess = [&](const StorageImageAccessFixup& fixup,
                                        const char* access) {
                std::vector<std::string> variableNames;
                std::unordered_set<std::string> variableNameSet;
                const std::string attr =
                    std::string("[[") +
                    (fixup.argumentBufferId ? "id(" : "texture(") +
                    std::to_string(fixup.metalSlot) + ")]]";
                const std::string replacement =
                    std::string("access::") + access;

                auto rememberVariableName = [&](std::size_t close,
                                                std::size_t limit) {
                    std::size_t nameStart = close + 1;
                    while (nameStart < limit &&
                           std::isspace(static_cast<unsigned char>(msl[nameStart]))) {
                        ++nameStart;
                    }
                    while (nameStart < limit && msl[nameStart] == '&') {
                        ++nameStart;
                        while (nameStart < limit &&
                               std::isspace(static_cast<unsigned char>(msl[nameStart]))) {
                            ++nameStart;
                        }
                    }
                    std::size_t nameEnd = nameStart;
                    while (nameEnd < limit && isIdentifierChar(msl[nameEnd])) {
                        ++nameEnd;
                    }
                    if (nameEnd <= nameStart) {
                        return;
                    }
                    const std::string variableName =
                        msl.substr(nameStart, nameEnd - nameStart);
                    if (variableNameSet.insert(variableName).second) {
                        variableNames.push_back(variableName);
                    }
                };

                auto applyTextureAccess = [&](std::size_t typePos,
                                              std::size_t close) {
                    const std::size_t accessPos = msl.find("access::", typePos);
                    if (accessPos != std::string::npos && accessPos < close) {
                        std::size_t accessEnd = accessPos;
                        while (accessEnd < close && accessChar(msl[accessEnd])) {
                            ++accessEnd;
                        }
                        const std::size_t oldAccessLen = accessEnd - accessPos;
                        msl.replace(accessPos, accessEnd - accessPos,
                                    replacement);
                        return
                            static_cast<std::ptrdiff_t>(replacement.size()) -
                            static_cast<std::ptrdiff_t>(oldAccessLen);
                    }
                    const std::string insertion =
                        std::string(", ") + replacement;
                    msl.insert(close, insertion);
                    return static_cast<std::ptrdiff_t>(insertion.size());
                };

                std::size_t search = 0;
                while ((search = msl.find(attr, search)) != std::string::npos) {
                    const std::size_t attrPos = search;
                    const std::size_t lineStart = msl.rfind('\n', search);
                    const std::size_t begin =
                        (lineStart == std::string::npos) ? 0 : lineStart + 1;
                    const std::size_t typePos = msl.rfind("texture", search);
                    if (typePos == std::string::npos || typePos < begin) {
                        search += attr.size();
                        continue;
                    }
                    const std::size_t close = msl.find('>', typePos);
                    if (close == std::string::npos || close >= search) {
                        search += attr.size();
                        continue;
                    }
                    rememberVariableName(close, search);
                    const auto delta = applyTextureAccess(typePos, close);
                    search = static_cast<std::size_t>(
                        static_cast<std::ptrdiff_t>(attrPos) + delta) +
                        attr.size();
                }

                // Compute subroutine lowering threads storage images through
                // helper signatures; keep those parameter types consistent
                // with the bound entry-point texture declaration.
                for (const auto& variableName : variableNames) {
                    std::size_t typePos = 0;
                    while ((typePos = msl.find("texture", typePos)) !=
                           std::string::npos) {
                        const std::size_t close = msl.find('>', typePos);
                        if (close == std::string::npos) {
                            break;
                        }
                        std::size_t nameStart = close + 1;
                        while (nameStart < msl.size() &&
                               std::isspace(static_cast<unsigned char>(
                                   msl[nameStart]))) {
                            ++nameStart;
                        }
                        while (nameStart < msl.size() &&
                               msl[nameStart] == '&') {
                            ++nameStart;
                            while (nameStart < msl.size() &&
                                   std::isspace(static_cast<unsigned char>(
                                       msl[nameStart]))) {
                                ++nameStart;
                            }
                        }
                        const std::size_t nameEnd =
                            nameStart + variableName.size();
                        if (nameEnd <= msl.size() &&
                            msl.compare(nameStart, variableName.size(),
                                        variableName) == 0 &&
                            (nameEnd == msl.size() ||
                             !isIdentifierChar(msl[nameEnd]))) {
                            const auto delta =
                                applyTextureAccess(typePos, close);
                            typePos = static_cast<std::size_t>(
                                static_cast<std::ptrdiff_t>(typePos) +
                                delta) + std::strlen("texture");
                        } else {
                            typePos += std::strlen("texture");
                        }
                    }
                }
            };

            for (const auto& fixup : storageImageAccessFixups) {
                if (fixup.nonWritable && !fixup.nonReadable) {
                    setTextureAccess(fixup, "read");
                } else if (fixup.nonReadable && !fixup.nonWritable) {
                    setTextureAccess(fixup, "write");
                }
            }
        }

        if (!resources.storage_images.empty()) {
            (void)retargetCubeStorageImagesAs2DArray(
                msl, cubeStorageImageSlots);
            (void)retargetCubeArrayStorageImagesAs2DArray(
                msl, cubeArrayStorageImageSlots);
            (void)rewriteMultisampleStorageImageWritesToSidecars(
                msl,
                multisampleStorageImageSlots,
                multisampleStorageImageArraySlots);
            (void)rewriteMultisampleStorageImageReadsFromSidecars(
                msl,
                multisampleStorageImageSlots,
                multisampleStorageImageArraySlots);
            (void)rewriteMultisampleStorageImageSampleQueries(
                msl, multisampleStorageImageSlots);
            (void)rewriteMultisampleStorageImageSampleQueries(
                msl, multisampleStorageImageArraySlots);
            (void)rewriteMultisampleStorageImageArraySizes(
                msl, multisampleStorageImageArraySlots);
            (void)rewriteAppglImageSamplesShimQueries(msl);
        }

        if (execModel == spv::ExecutionModelGLCompute ||
            execModel == spv::ExecutionModelFragment ||
            execModel == spv::ExecutionModelVertex) {
            (void)rewriteMultisampleSampledImageReads(msl);
        }
        (void)injectMultisampleSampledImageSidecars(msl);
        (void)injectMultisampleStorageReadSidecars(msl);
        threadMainTextureParamsThroughHelpers(
            msl, "appgl_ms_storage_read_sidecar_");
        (void)injectSparseSampledImageSidecars(msl);
        (void)injectMultisampleStorageImageSampleCounts(msl);
        threadTextureReductionModesThroughHelpers(
            msl, "appgl_ms_storage_image_samples");
        (void)injectMultisampleStorageSparseResidencyTextures(msl);

        // SPIRV-Cross lowers GLSL image coordinates as signed integer
        // temporaries (`int2`, `int3`), but Metal storage texture
        // read/write APIs require unsigned coordinates. Apple Metal's
        // compiler rejects `texture2d.read(int2)` outright, leaving the
        // compute PSO null and graphics image reads returning the clear
        // path. Cast only coordinates used in storage texture accessors.
        if (!resources.storage_images.empty()) {
            fixStorageImageSignedCoordinateCasts(msl);
        }

        // Sprint 18 Item 32 candidate: GL storage-image side effects
        // survive `discard`, while Metal can suppress texture writes in
        // a fragment that terminates with `discard_fragment()`. CTS
        // shader_image_load_store.basic-allFormats-store uses exactly
        // this "imageStore then discard" shape with no color output.
        // For pure write-only fragment-void shaders, return normally
        // instead: no color is produced, but the image side effect is
        // preserved. Leave read+write copy shaders on the existing
        // discard path; CTS single-byte_data_alignment already depends
        // on that shape preserving both imageLoad and imageStore.
        if (isFragment &&
            msl.find("fragment void ") != std::string::npos &&
            msl.find("access::write") != std::string::npos &&
            msl.find("access::read") == std::string::npos) {
            const std::string discard = "discard_fragment();";
            const std::string ret = "return;";
            std::size_t pos = 0;
            while ((pos = msl.find(discard, pos)) != std::string::npos) {
                msl.replace(pos, discard.size(), ret);
                pos += ret.size();
            }
        }

        // Sprint 18 Item42: graphics-stage argument buffers need SSBO
        // `.length()` / OpArrayLength sizes, but Metal's argument-buffer
        // encoding does not reliably surface SPIRV-Cross's
        // `spvBufferSizeConstants` pointer member for this shape. Keep
        // SSBO resources in the set-0 argbuf, but route the size sidecar
        // through a direct graphics buffer slot. Slot 30 is outside the
        // argbuf self-bindings (24/25) and the direct path is not active
        // for these SSBOs.
        if (useArgBuf &&
            (execModel == spv::ExecutionModelVertex ||
             execModel == spv::ExecutionModelFragment) &&
            msl.find("spvBufferSizeConstants") != std::string::npos) {
            auto replaceAll = [](std::string& text,
                                 const std::string& needle,
                                 const std::string& replacement) {
                std::size_t pos = 0;
                while ((pos = text.find(needle, pos)) != std::string::npos) {
                    text.replace(pos, needle.size(), replacement);
                    pos += replacement.size();
                }
            };
            replaceAll(msl,
                "spvBufferSizeConstants [[buffer(25)]]",
                "spvBufferSizeConstants [[buffer(30)]]");
            replaceAll(msl,
                "spvDescriptorSet0.spvBufferSizeConstants",
                "spvBufferSizeConstants");
        }

        // Runtime-sized array handling for SSBOs: SPIRV-Cross emits MSL
        // with `[65536]` for trailing `OpTypeRuntimeArray` members
        // (configured via backend.unsized_array_fallback_literal in the
        // patched third_party/SPIRV-Cross). The "1" default — which the
        // upstream MSL backend previously used — caused Apple GPUs to
        // silently drop `device T&` writes past index 0 under reference
        // semantics. Only actual runtime arrays get the large fallback;
        // fixed-size `[1]` members (e.g. `struct sC { uint3 mA[1]; };`)
        // keep their declared size because they take the `else if(size)`
        // branch in CompilerGLSL::to_array_size.
        {
            static constexpr const char* kPaddedArrayNeedle =
                "template <typename T, int stride>\n"
                "struct spvPaddedArrayElement { T data; char padding[stride - sizeof(T)]; };";
            static constexpr const char* kPaddedArrayReplacement =
                "template <typename T, int stride, bool hasPadding = (stride > sizeof(T))>\n"
                "struct spvPaddedArrayElement { T data; char padding[stride - sizeof(T)]; };\n"
                "\n"
                "template <typename T, int stride>\n"
                "struct spvPaddedArrayElement<T, stride, false> { T data; };";
            const std::size_t pos = msl.find(kPaddedArrayNeedle);
            if (pos != std::string::npos) {
                msl.replace(pos, std::strlen(kPaddedArrayNeedle), kPaddedArrayReplacement);
            }
        }

        // gl_ClipDistance / gl_CullDistance array-to-flattened rewrite:
        // SPIRV-Cross's MSL backend declares ClipDistance/CullDistance as
        // split individual `[[user(clipN)]]` / `[[user(cullN)]]` outputs
        // on `main0_out` (see CompilerMSL::entry_point_args around
        // BuiltInClipDistance/BuiltInCullDistance). But function-body
        // access chains like `out.gl_CullDistance[0] = ...` still
        // reference the unsplit array member that no longer exists on
        // the struct, causing MSL compilation to fail with:
        //   error: no member named 'gl_CullDistance' in 'main0_out'
        //
        // CTS KHR-GL46.cull_distance.* (201 tests) all trip on this.
        // Rewrite the literal access-chain pattern to the split name:
        //   out.gl_CullDistance[N] → out.gl_CullDistance_N
        //   out.gl_ClipDistance[N] → out.gl_ClipDistance_N
        // for N in [0..15] (gl_MaxCullDistances + gl_MaxClipDistances
        // are each 8 per GL spec, but grow the window to 16 so any
        // vendor extension or test that crosses the floor still matches).
        {
            std::string out;
            out.reserve(msl.size());
            const auto rewriteOne = [&out](const std::string& s, const char* arrayName) {
                std::string pattern = std::string(".") + arrayName + "[";
                std::size_t pos = 0;
                while (pos < s.size()) {
                    const std::size_t idx = s.find(pattern, pos);
                    if (idx == std::string::npos) {
                        out.append(s, pos, std::string::npos);
                        return;
                    }
                    out.append(s, pos, idx - pos);
                    // Parse the N in `[N]`.
                    const std::size_t numStart = idx + pattern.size();
                    std::size_t numEnd = numStart;
                    while (numEnd < s.size() && s[numEnd] >= '0' && s[numEnd] <= '9') ++numEnd;
                    if (numEnd == numStart || numEnd >= s.size() || s[numEnd] != ']') {
                        // Not a literal integer subscript — bail without rewriting this instance.
                        out.append(s, idx, pattern.size());
                        pos = idx + pattern.size();
                        continue;
                    }
                    out.append(".");
                    out.append(arrayName);
                    out.append("_");
                    out.append(s, numStart, numEnd - numStart);
                    pos = numEnd + 1;  // skip ']'
                }
            };
            rewriteOne(msl, "gl_CullDistance");
            msl = std::move(out);
            // Intentionally do NOT rewrite `gl_ClipDistance[N]`. Unlike
            // CullDistance, Metal has a hardware `[[clip_distance]]`
            // attribute which SPIRV-Cross emits on `main0_out` under the
            // exact unsplit name `gl_ClipDistance`. SPIRV-Cross's own
            // output *writes both* the split user-varying
            // (`out.gl_ClipDistance_N = EXPR;`) and the hardware copy-back
            // (`out.gl_ClipDistance[N] = out.gl_ClipDistance_N;`) in the
            // emitted function body. Rewriting the hardware write to
            // `out.gl_ClipDistance_N = out.gl_ClipDistance_N;` made it a
            // no-op, leaving the `[[clip_distance]]` array uninitialised —
            // Metal then read garbage (typically negative) and clipped
            // every pixel. That was the root cause of CTS
            // clip_distance.functional + cull_distance.functional_*
            // (~400 tests) all reporting "vertex unexpectedly clipped".
        }

        // [[point_size]] for point primitives is handled purely through
        // `MTLRenderPipelineDescriptor.inputPrimitiveTopology = Point`
        // — Metal defaults point_size to 1.0 in that mode when the VS
        // doesn't write it. A prior iteration of this file injected
        // `out.gl_PointSize = 1.0;` into every VS MSL body, but that
        // caused `AGXMetalG13X Error Domain Code=3: "Vertex shader
        // writes point size but inputPrimitiveTopology is
        // MTLPrimitiveTopologyClassTriangle"` for every triangle /
        // line draw in the suite (all `shaders.arrays.*`, many of
        // `pixelstoragemodes.*`, etc. — 4k+ regressions on sweep s17).
        // Removed unconditionally.

        // gl_CullDistance → [[clip_distance]] routing (vertex stages only).
        //
        // Metal has no `[[cull_distance]]` attribute. GL 4.6 §14.6.3 cull
        // semantics are per-primitive — "discard the whole primitive iff
        // ∃ channel i such that ALL vertices have cull_distance[i] < 0" —
        // and can only be exactly emulated through a compute pre-pass
        // that sees every vertex of a primitive before rasterization
        // (deferred). The pragmatic quick-fix is to route each cull
        // channel into an extra `[[clip_distance]]` slot, which gives
        // correct behaviour for two of three cases:
        //   - all-positive on a channel → primitive drawn (matches cull)
        //   - all-negative on a channel → primitive discarded (matches)
        //   - mixed-sign on a channel   → per-pixel clip instead of full
        //     draw. Over-clips on triangles/lines with mixed-sign cull
        //     channels. Exact for points (1-vertex primitives).
        //
        // SPIRV-Cross emits `gl_CullDistance_K [[user(cullK)]]` user
        // varyings for cull distances — they carry the value as plain
        // interpolated data but don't drive HW culling. We post-process:
        //   1. Count `gl_CullDistance_K` declarations in main0_out (M).
        //   2. Locate `float gl_ClipDistance [[clip_distance]] [N];` and
        //      resize to [N+M]. If absent (0-clip shader), insert with
        //      size [M].
        //   3. For each `out.gl_CullDistance_K = EXPR;` statement, append
        //      a sibling `out.gl_ClipDistance[N+K] = EXPR;` so the HW
        //      clip array sees the cull value.
        // Only applied to vertex shaders (MSL `vertex main0_out main0(`).
        // Fragment/compute stages have no rasterizer clipping and don't
        // declare `[[clip_distance]]` at all.
        //
        // Sprint 17 Day 7+ Bank-Group-H Path B Component A2: when the
        // caller flags `disableCullDistanceClipRouting`, the CPU
        // `emulateVsCullPrepass` handles GL §14.6.3 per-primitive cull
        // by filtering the index buffer; routing cull→[[clip_distance]]
        // here would then over-clip at the per-fragment level for any
        // vertex with a negative cull value on a non-culled channel
        // (Phase 2 confirmed via CTS test design at glcCullDistance
        // .cpp:2236-2246).
        // Sprint 17 Day 9+ Bank-Group-H R13 sub-bank item_4 (dynamic-
        // index cull writes): runs UNGATED by
        // `disableCullDistanceClipRouting` because the issue is
        // unconditional MSL invalidity. SPIRV-Cross's MSL backend
        // flattens `gl_CullDistance` into per-index struct fields
        // (`gl_CullDistance_K [[user(cullK)]]`) but emits
        // `out.gl_CullDistance[expr]` (array access) when the VS code
        // dynamically indexes the array — `gl_CullDistance` is no
        // longer a struct member after flattening, so the access is
        // invalid. The static-index post-processing below matches
        // `out.gl_CullDistance_K = EXPR;` lines (and skips when Path B
        // disables cull→clip routing); dynamic-index lines never match
        // either pattern. Without this transform, CTS
        // `cull_distance.functional_test_item_4`
        // (use_dynamic_index_based_writes) writes were dropped on both
        // Path B (CPU does its own cull, but flattened fields are also
        // read by the FS for fetch_culldistances variants) and the
        // legacy cull→clip routing.
        //
        // Route dynamic-index writes through a local
        // `spvUnsafeArray<float, M>` then unroll a copy-back to the
        // flattened struct fields just before `return out;`. The
        // copy-back lines have static indices so the cull→clip pass
        // below picks them up and emits HW clip-distance siblings
        // automatically (when not disabled by Path B).
        if (msl.find("vertex ") != std::string::npos
            && msl.find("gl_CullDistance_0 [[user(cull0)]]") != std::string::npos) {
            int cullCountForDyn = 0;
            for (int k = 0; k < 8; ++k) {
                char needle[64];
                std::snprintf(needle, sizeof(needle),
                              "gl_CullDistance_%d [[user(cull%d)]]", k, k);
                if (msl.find(needle) != std::string::npos) {
                    cullCountForDyn = k + 1;
                } else {
                    break;
                }
            }
            // Detect any `out.gl_CullDistance[<expr>]` where the bracket
            // contents are NOT a single decimal literal (digit run + `]`).
            // Static-index emit is `out.gl_CullDistance_K = ...` (no
            // `[`), so any `out.gl_CullDistance[` is dynamic. Only fire
            // when at least one such line exists AND we have flattened
            // fields to route to.
            const std::string dynPrefix = "out.gl_CullDistance[";
            const bool hasDynCullWrite =
                cullCountForDyn > 0 &&
                msl.find(dynPrefix) != std::string::npos;
            if (hasDynCullWrite) {
                // Locate `main0_out out = {};` (the function-entry decl
                // emitted by SPIRV-Cross for vertex stages) and inject
                // a synthetic local cull array right after.
                const std::string outInitLine = "main0_out out = {};";
                std::size_t outInitPos = msl.find(outInitLine);
                if (outInitPos != std::string::npos) {
                    std::size_t injectPos = outInitPos + outInitLine.size();
                    std::string localDecl =
                        "\n    spvUnsafeArray<float, " +
                        std::to_string(cullCountForDyn) +
                        "> _appgl_cullDist = {};";
                    msl.insert(injectPos, localDecl);
                    // Replace every `out.gl_CullDistance[` with
                    // `_appgl_cullDist[`. The injection above moved the
                    // remainder of the buffer, so the find-replace pass
                    // operates on the post-injection string.
                    std::size_t scan = 0;
                    while (true) {
                        std::size_t hit = msl.find(dynPrefix, scan);
                        if (hit == std::string::npos) break;
                        msl.replace(hit, dynPrefix.size(), "_appgl_cullDist[");
                        scan = hit + std::string("_appgl_cullDist[").size();
                    }
                    // Insert the unrolled copy-back to flattened struct
                    // fields just before `return out;`. The static-index
                    // cull→clip pass below then picks up these lines and
                    // emits HW `out.gl_ClipDistance[N+K]` siblings.
                    const std::string returnStmt = "return out;";
                    std::size_t retPos = msl.rfind(returnStmt);
                    if (retPos != std::string::npos) {
                        std::string copyBack;
                        copyBack.reserve(cullCountForDyn * 64);
                        for (int k = 0; k < cullCountForDyn; ++k) {
                            copyBack += "    out.gl_CullDistance_";
                            copyBack += std::to_string(k);
                            copyBack += " = _appgl_cullDist[";
                            copyBack += std::to_string(k);
                            copyBack += "];\n";
                        }
                        msl.insert(retPos, copyBack);
                    }
                }
            }
        }
        // Static-index cull→clip routing (Sprint 17 Day 7+ Path B
        // Component A2 disable gate restored). The dynamic-index
        // transform above unconditionally fixes the broken MSL; this
        // block additionally synthesizes HW `[[clip_distance]]`
        // siblings for static-index cull writes when the caller does
        // NOT have a CPU pre-pass to handle GL §14.6.3 cull semantics.
        if (msl.find("vertex ") != std::string::npos
            && msl.find("gl_CullDistance_0 [[user(cull0)]]") != std::string::npos
            && !options.disableCullDistanceClipRouting) {
            // Count cull distances (gl_CullDistance_0 through _7).
            int cullCount = 0;
            for (int k = 0; k < 8; ++k) {
                char needle[64];
                std::snprintf(needle, sizeof(needle),
                              "gl_CullDistance_%d [[user(cull%d)]]", k, k);
                if (msl.find(needle) != std::string::npos) {
                    cullCount = k + 1;
                } else {
                    break;
                }
            }
            if (cullCount > 0) {
                // Find the HW clip-distance declaration and extract N.
                // Pattern: `float gl_ClipDistance [[clip_distance]] [N];`
                int clipCount = 0;
                const std::string clipDeclPrefix = "float gl_ClipDistance [[clip_distance]] [";
                std::size_t clipDeclPos = msl.find(clipDeclPrefix);
                if (clipDeclPos != std::string::npos) {
                    // Parse N between '[' and ']'.
                    std::size_t nStart = clipDeclPos + clipDeclPrefix.size();
                    std::size_t nEnd = nStart;
                    while (nEnd < msl.size() && msl[nEnd] >= '0' && msl[nEnd] <= '9') ++nEnd;
                    if (nEnd > nStart && nEnd < msl.size() && msl[nEnd] == ']') {
                        clipCount = std::stoi(msl.substr(nStart, nEnd - nStart));
                        // Resize in place by rewriting the size digits.
                        const int newSize = clipCount + cullCount;
                        if (newSize <= 8) {   // Metal HW clip cap is 8 total
                            std::string newSizeStr = std::to_string(newSize);
                            msl.replace(nStart, nEnd - nStart, newSizeStr);
                        } else {
                            clipCount = -1;   // Skip if we'd overflow.
                        }
                    }
                } else {
                    // No HW clip distance. Insert a fresh declaration
                    // before the first `gl_CullDistance_0` declaration.
                    const std::string firstCullDecl = "float gl_CullDistance_0 [[user(cull0)]];";
                    std::size_t insertPos = msl.find(firstCullDecl);
                    if (insertPos != std::string::npos && cullCount <= 8) {
                        std::string newDecl = "float gl_ClipDistance [[clip_distance]] ["
                            + std::to_string(cullCount) + "];\n    ";
                        msl.insert(insertPos, newDecl);
                        clipCount = 0;
                    } else {
                        clipCount = -1;   // Skip.
                    }
                }

                if (clipCount >= 0) {
                    // For each cull write (`out.gl_CullDistance_K = EXPR;`)
                    // append a sibling HW clip write at slot clipCount+K.
                    std::string rebuilt;
                    rebuilt.reserve(msl.size() + cullCount * 64);
                    std::size_t pos = 0;
                    while (pos < msl.size()) {
                        const std::size_t nl = msl.find('\n', pos);
                        const std::size_t lineEnd = (nl == std::string::npos) ? msl.size() : nl + 1;
                        rebuilt.append(msl, pos, lineEnd - pos);
                        // Check for `out.gl_CullDistance_K = EXPR;`.
                        const std::string_view line(msl.data() + pos, lineEnd - pos);
                        const std::string cullLhs = "out.gl_CullDistance_";
                        std::size_t lhsPos = line.find(cullLhs);
                        if (lhsPos != std::string_view::npos) {
                            // Parse K.
                            std::size_t kStart = lhsPos + cullLhs.size();
                            std::size_t kEnd = kStart;
                            while (kEnd < line.size() && line[kEnd] >= '0' && line[kEnd] <= '9') ++kEnd;
                            if (kEnd > kStart && kEnd < line.size()) {
                                int k = std::stoi(std::string(line.substr(kStart, kEnd - kStart)));
                                if (k < cullCount) {
                                    // Find " = " and the trailing ";".
                                    std::size_t eqPos = line.find(" = ", kEnd);
                                    std::size_t semiPos = line.rfind(';', line.size() - 1);
                                    if (eqPos != std::string_view::npos
                                        && semiPos != std::string_view::npos
                                        && semiPos > eqPos + 3) {
                                        std::string rhs(line.substr(eqPos + 3, semiPos - (eqPos + 3)));
                                        // Preserve the leading whitespace.
                                        std::size_t wsEnd = 0;
                                        while (wsEnd < line.size()
                                               && (line[wsEnd] == ' ' || line[wsEnd] == '\t')) {
                                            ++wsEnd;
                                        }
                                        std::string prefix(line.substr(0, wsEnd));
                                        rebuilt.append(prefix);
                                        rebuilt.append("out.gl_ClipDistance[");
                                        rebuilt.append(std::to_string(clipCount + k));
                                        rebuilt.append("] = ");
                                        rebuilt.append(rhs);
                                        rebuilt.append(";\n");
                                    }
                                }
                            }
                        }
                        pos = lineEnd;
                    }
                    msl = std::move(rebuilt);
                }
            }
        }

        // SPIRV-Cross's "copy internal per-vertex block to split user(N)
        // outputs" pass sometimes leaves dangling references to a SPIR-V
        // variable ID that's never emitted as a local (observed as
        // `_NN._RESERVED_IDENTIFIER_FIXUP_gl_CullDistance[K]` on the RHS
        // of the redundant copy-back writes). The immediately-preceding
        // statements already wrote the correct values to the split
        // outputs (e.g. `out.gl_CullDistance_0 = culldistance_data[0];`),
        // so the reserved-identifier copy-back is a duplicate that only
        // fails because its source variable was optimized away. Strip
        // any line where the marker appears as an access-chain member
        // (`.{marker}`) — that's the dangling-RHS shape. Standalone
        // uses (struct definitions, threadgroup/spvUnsafeArray locals
        // for mesh-shader gl_PerVertex / gl_in / gl_out) lack the
        // leading dot and are preserved.
        {
            const std::string kAccessMarker = "._RESERVED_IDENTIFIER_FIXUP_gl_";
            std::string out;
            out.reserve(msl.size());
            std::size_t pos = 0;
            while (pos < msl.size()) {
                const std::size_t nl = msl.find('\n', pos);
                const std::size_t lineEnd = (nl == std::string::npos) ? msl.size() : nl + 1;
                const std::string_view line(msl.data() + pos, lineEnd - pos);
                if (line.find(kAccessMarker) == std::string_view::npos) {
                    out.append(line);
                }
                pos = lineEnd;
            }
            msl = std::move(out);
        }

        // CKPT120 (Sprint 11 Phase 2 Cluster A MSAA Day 5):
        // gl_SampleMask write-through fix for non-MSAA framebuffers.
        // GL 4.6 §17.3.3 + ARB_sample_shading: writes to gl_SampleMask
        // have NO EFFECT when MSAA is disabled / sample-count is 1
        // (the per-sample raster path doesn't run). Metal's
        // `[[sample_mask]]` is unconditional — a 0-write at single-sample
        // gates ALL fragment writes, dropping the entire draw. CTS
        // sample_variables.mask.*.samples_0.* (36F) hits this: shader
        // unconditionally writes `gl_SampleMask = u_sampleMask &
        // gl_SampleMaskIn` → mask_zero → 0 → fragment dropped → texture
        // stays clear-green → verifier expects red → FAIL.
        //
        // CKPT121 (Day 6): gate the override on actual sample count so
        // MSAA-mask correctness is preserved for samples > 1.
        // glslang/SPIRV-Cross emits gl_NumSamples as a `[[buffer(0)]]`
        // int parameter — but no runtime path plumbs that buffer, so
        // it reads garbage. Replace it with Metal's `raster_sample_count()`
        // intrinsic (MSL 2.1+ / macOS 10.14+, well within our target):
        //   1. Strip the `constant int& ..._gl_NumSamples [[buffer(0)]],`
        //      parameter from `main0`.
        //   2. Inject a local `int _RESERVED_IDENTIFIER_FIXUP_gl_NumSamples
        //      = int(get_num_samples());` at the top of `main0`.
        //      `get_num_samples()` is the rasterization sample count of
        //      the bound color attachment; existing references in the
        //      shader body resolve to this local without further edits.
        //   3. Gate the gl_SampleMask=UINT_MAX override on
        //      `_RESERVED_IDENTIFIER_FIXUP_gl_NumSamples == 1`.
        // This restores MSAA-mask behaviour for samples > 1 while
        // keeping the samples_0 fix from Day 5.
        if (execModel == spv::ExecutionModelFragment
            && msl.find("[[sample_mask]]") != std::string::npos) {
            (void)injectGlNumSamplesParameter(msl);
            // Gate on `_RESERVED_IDENTIFIER_FIXUP_gl_NumSamples == 1`.
            // The MSL keeps SPIRV-Cross's `[[buffer(0)]]` parameter for
            // gl_NumSamples; the runtime (MetalFrameGraph) writes the
            // FBO's color-attachment sampleCount to that buffer slot at
            // each draw, so the comparison reads a genuine sample count
            // (1 for non-MSAA, 2/4/8/... for MSAA). When samples == 1
            // (per GL spec, MSAA disabled), force gl_SampleMask=UINT_MAX
            // to neutralize Metal's unconditional [[sample_mask]] gating.
            // For samples > 1, preserve the user's mask write.
            const bool glNumSamplesUsesArgBuf =
                msl.find("_RESERVED_IDENTIFIER_FIXUP_gl_NumSamples [[id(0)]]") !=
                    std::string::npos &&
                msl.find("spvDescriptorSet0") != std::string::npos;
            const std::string glNumSamplesExpr =
                glNumSamplesUsesArgBuf
                    ? "(*spvDescriptorSet0._RESERVED_IDENTIFIER_FIXUP_gl_NumSamples)"
                    : "_RESERVED_IDENTIFIER_FIXUP_gl_NumSamples";
            const std::string returnPattern = "    return out;";
            const std::string injection =
                "    if (" + glNumSamplesExpr + " == 1) "
                "{ out.gl_SampleMask = 0xFFFFFFFFu; }\n";
            std::string out2;
            out2.reserve(msl.size() + 128);
            std::size_t pos = 0;
            while (pos < msl.size()) {
                const std::size_t idx = msl.find(returnPattern, pos);
                if (idx == std::string::npos) {
                    out2.append(msl, pos, std::string::npos);
                    break;
                }
                out2.append(msl, pos, idx - pos);
                out2.append(injection);
                out2.append(returnPattern);
                pos = idx + returnPattern.size();
            }
            msl = std::move(out2);
        }
        if (execModel == spv::ExecutionModelFragment) {
            (void)injectFixedFunctionSampleMask(msl);
            (void)eraseNoOpFragDepthWrite(msl);
        }

        if (execModel == spv::ExecutionModelFragment ||
            execModel == spv::ExecutionModelVertex) {
            const bool applyImplicitLodBias =
                execModel == spv::ExecutionModelFragment;
            injectTextureReductionMinmax(msl, applyImplicitLodBias);
            injectTextureLodBiases(msl, applyImplicitLodBias);
            injectIntegerTextureBorderClamp(msl);
        }

        if ((execModel == spv::ExecutionModelFragment ||
             execModel == spv::ExecutionModelVertex) &&
            msl.find("volatile") != std::string::npos &&
            (msl.find("float3x3") != std::string::npos ||
             msl.find("float4x3") != std::string::npos ||
             msl.find("float3x4") != std::string::npos)) {
            auto replaceAll = [](std::string& text,
                                 const std::string& from,
                                 const std::string& to) {
                std::size_t pos = 0;
                while ((pos = text.find(from, pos)) != std::string::npos) {
                    text.replace(pos, from.size(), to);
                    pos += to.size();
                }
            };
            // SPIRV-Cross maps GLSL `coherent` SSBOs to volatile device
            // pointers. Metal's matrix/vector helper methods are not
            // volatile-qualified, so dynamic indexing of matrix members
            // fails library compilation. Preserve address space and constness;
            // drop only the qualifier that Metal cannot apply to matrices.
            replaceAll(msl, "volatile const device ", "const device ");
            replaceAll(msl, "volatile device ", "device ");
        }

        if (log != nullptr) {
            *log = "ok";
        }
        // Diagnostic dumps: APPGL_DUMP_MSL writes the generated MSL to
        // msl_NNNN.metal; APPGL_DUMP_SPIRV writes the *input* SPIR-V to
        // spv_NNNN.spv. The pair shares a counter so msl_0007.metal and
        // spv_0007.spv are produced from the same translator invocation,
        // letting SPIRV-W round-trip the input SPIR-V through their local
        // spirv-cross and compare emission against ours. SPIR-V execution
        // model in word[2] of each OpEntryPoint identifies the stage —
        // run `spirv-dis spv_NNNN.spv | head` to disambiguate VS / TCS /
        // TES / FS / Compute.
        const char* mslDumpPath = std::getenv("APPGL_DUMP_MSL");
        const char* spirvDumpPath = std::getenv("APPGL_DUMP_SPIRV");
        if (mslDumpPath != nullptr || spirvDumpPath != nullptr) {
            static std::atomic<int> counter{0};
            const int n = counter.fetch_add(1);
            char path[512];
            if (mslDumpPath != nullptr) {
                std::snprintf(path, sizeof(path), "%s/msl_%04d.metal", mslDumpPath, n);
                if (FILE* f = std::fopen(path, "w")) {
                    std::fwrite(msl.data(), 1, msl.size(), f);
                    std::fclose(f);
                }
            }
            if (spirvDumpPath != nullptr) {
                std::snprintf(path, sizeof(path), "%s/spv_%04d.spv", spirvDumpPath, n);
                if (FILE* f = std::fopen(path, "wb")) {
                    std::fwrite(spirv, sizeof(std::uint32_t), wordCount, f);
                    std::fclose(f);
                }
            }
        }
        return msl;
    } catch (const spirv_cross::CompilerError& e) {
        if (log != nullptr) {
            *log = std::string("SPIRV-Cross error: ") + e.what();
        }
        // Step 7 debug: SPIRV-Cross throw → log to stderr when
        // APPGL_DUMP_MSL is set so argument-buffer experimentation
        // isn't silent. Caught at the `spirvToMSL` frame; callers see
        // the empty return.
        if (std::getenv("APPGL_DUMP_MSL") != nullptr) {
            std::fprintf(stderr, "[APPGL] SPIRV-Cross throw: %s\n", e.what());
        }
        return {};
    }
}

ShaderReflection ShaderTranslator::reflect(const std::uint32_t* spirv, std::size_t wordCount, const BindingMap& bindings, std::string* log) const {
    return reflect(spirv, wordCount, bindings, log, TranslatorOptions{});
}

ShaderReflection ShaderTranslator::reflect(const std::uint32_t* spirv, std::size_t wordCount, const BindingMap& bindings, std::string* log, const TranslatorOptions& options) const {
    ShaderReflection result;
    try {
        spirv_cross::Compiler compiler(spirv, wordCount);
        applySpirvModuleOptions(compiler, options);
        auto resources = compiler.get_shader_resources();
        auto isAtomicCounterStorageBuffer = [&](const spirv_cross::Resource& res) {
            auto hasAtomicCounterName = [](const std::string& name) {
                return name.find("AtomicCounter") != std::string::npos ||
                       name.find("atomicCounter") != std::string::npos;
            };
            if (hasAtomicCounterName(res.name)) return true;
            try {
                const auto& type = compiler.get_type(res.base_type_id);
                if (hasAtomicCounterName(compiler.get_name(type.self))) return true;
            } catch (...) {
            }
            return false;
        };
        result.usesFragmentShadingRateBuiltins =
            resourcesUseFragmentShadingRateBuiltins(resources);
        result.usesFp64 = spirvModuleDeclaresFp64(spirv, wordCount);
        result.fp64TranslationActive =
            result.usesFp64 && options.fp64EmulationAvailable;

        // Vertex inputs (stage_inputs). SPIR-V assigns one OpDecorate
        // Location per input, but SPIRV-Cross MSL EXPANDS arrays and
        // matrix columns into individual `[[attribute(K)]]` slots. FP64
        // dvec3/dvec4 columns are then lowered to two uint-backed Metal
        // attributes. The reflection's .location must match those EXPANDED
        // MSL slots so getAttribLocation("arr[K]") resolves to the real
        // Metal attribute — otherwise a later non-array input ends up
        // colliding with an earlier array's element slots. For example:
        //   in float clipdistance_data[1];  // SPIR-V loc 0 → MSL attr 0
        //   in float culldistance_data[8];  // SPIR-V loc 1 → MSL attr 1..8
        //   in vec2 position;               // SPIR-V loc 2 → MSL attr 9
        // Pre-fix, position was reported at location 2 and CTS's
        // vertexAttribPointer(getAttribLocation("position"), …) wrote
        // into Metal attribute 2 which is actually culldistance_data_1.
        //
        // Re-derive the expanded locations by sorting inputs by their
        // SPIR-V Location and walking them, accumulating per-array
        // slot counts so each subsequent input starts after the
        // previous one's full transport size.
        struct InputEntry {
            spirv_cross::Resource* res;
            std::uint32_t spirvLocation;
            std::uint32_t arrayCount;
            std::uint32_t columnCount;
            std::uint32_t metalSlotsPerColumn;
            std::uint32_t metalSlotCount;
        };
        auto vertexInputArrayCount =
            [](const spirv_cross::SPIRType& type) -> std::uint32_t {
                std::uint32_t count = 1;
                for (const auto dim : type.array) {
                    count *= dim > 0 ? static_cast<std::uint32_t>(dim) : 1u;
                }
                return count;
            };
        auto vertexInputColumnCount =
            [](const spirv_cross::SPIRType& type) -> std::uint32_t {
                return type.columns > 1 ? type.columns : 1u;
            };
        auto vertexInputMetalSlotsPerColumn =
            [](const spirv_cross::SPIRType& type) -> std::uint32_t {
                return (type.basetype == spirv_cross::SPIRType::Double &&
                        type.vecsize > 2) ? 2u : 1u;
            };
        std::vector<InputEntry> sortedInputs;
        sortedInputs.reserve(resources.stage_inputs.size());
        for (auto& input : resources.stage_inputs) {
            InputEntry e;
            e.res = &input;
            e.spirvLocation = compiler.get_decoration(input.id, spv::DecorationLocation);
            const auto& type = compiler.get_type(input.type_id);
            e.arrayCount = vertexInputArrayCount(type);
            e.columnCount = vertexInputColumnCount(type);
            e.metalSlotsPerColumn = vertexInputMetalSlotsPerColumn(type);
            e.metalSlotCount =
                e.arrayCount * e.columnCount * e.metalSlotsPerColumn;
            sortedInputs.push_back(e);
        }
        std::stable_sort(sortedInputs.begin(), sortedInputs.end(),
                         [](const InputEntry& a, const InputEntry& b) {
                             return a.spirvLocation < b.spirvLocation;
                         });
        // Walk in SPIR-V location order; emit MSL-remapped locations so
        // each array/matrix aggregate takes contiguous transport slots and
        // the next input starts after the previous input's final slot. Array
        // inputs emit one source location per element; matrices emit one per
        // column; fp64 dvec3/dvec4 columns emit two Metal transport slots for
        // that same GL source location. This matches SPIRV-Cross MSL output
        // after `rewriteFp64VertexInputs()`: `dmat3` is 3 GL source columns
        // and 6 Metal attributes, while `mat3` is 3 source columns and 3
        // Metal attributes. The pipeline builder
        // in MetalFrameGraph.mm iterates `vertexInputs` and sets
        // `vertexDescriptor.attributes[input.location].format`, so
        // missing per-element entries would leave Metal attributes
        // 2..8 unset even with a correctly-bound VAO.
        std::uint32_t nextMslLocation = 0;
        for (auto& entry : sortedInputs) {
            if (entry.spirvLocation > nextMslLocation) {
                nextMslLocation = entry.spirvLocation;
            }
            const auto& type = compiler.get_type(entry.res->type_id);
            const GLenum glType = spirvBaseTypeToGL(type);
            const bool containsFp64 = spirvTypeUsesFp64(compiler, type);
            std::uint32_t metalSlotOffset = 0;
            for (std::uint32_t arrayIndex = 0;
                 arrayIndex < entry.arrayCount; ++arrayIndex) {
                const std::string logicalName = entry.arrayCount > 1
                    ? (entry.res->name + "[" + std::to_string(arrayIndex) + "]")
                    : entry.res->name;
                for (std::uint32_t column = 0;
                     column < entry.columnCount; ++column) {
                    const std::uint32_t sourceLocation =
                        entry.spirvLocation +
                        arrayIndex * entry.columnCount + column;
                    for (std::uint32_t transportSlot = 0;
                         transportSlot < entry.metalSlotsPerColumn;
                         ++transportSlot) {
                        ShaderReflection::VertexInput vi;
                        vi.location = nextMslLocation + metalSlotOffset++;
                        vi.sourceLocation = sourceLocation;
                        vi.name = logicalName;
                        vi.type = glType;
                        vi.containsFp64 = containsFp64;
                        result.vertexInputs.push_back(std::move(vi));
                    }
                }
            }
            nextMslLocation += entry.metalSlotCount;
        }

        // Uniform buffers — two-pass approach:
        //  Pass 1: compute Metal slot assignments for ACTIVE UBOs only,
        //          matching spirvToMSL (which must skip inactive UBOs to
        //          avoid binding-collision with add_msl_resource_binding).
        //  Pass 2: emit ResourceBindings for ALL UBOs (active + inactive)
        //          so that declared-but-unused blocks still appear in the
        //          program's uniform block list (CTS queries them).
        auto activeVars = compiler.get_active_interface_variables();
        {
            struct UBORef { std::uint32_t glBinding; std::uint32_t arraySize;
                            spirv_cross::Resource* res; bool active; };
            auto spirvArrayElementCount = [](const spirv_cross::SPIRType& type) -> std::uint32_t {
                std::uint32_t count = 1;
                for (const auto dim : type.array) {
                    count *= dim > 0 ? static_cast<std::uint32_t>(dim) : 1u;
                }
                return count;
            };
            std::vector<UBORef> sortedUBOs;
            for (auto& ubo : resources.uniform_buffers) {
                UBORef r;
                r.glBinding = compiler.get_decoration(ubo.id, spv::DecorationBinding);
                const auto& vt = compiler.get_type(ubo.type_id);
                r.arraySize = !vt.array.empty() ? spirvArrayElementCount(vt) : 1;
                r.res = &ubo;
                r.active = (activeVars.find(ubo.id) != activeVars.end());
                sortedUBOs.push_back(r);
            }
            // Sort active UBOs first (by glBinding), inactive last.
            std::sort(sortedUBOs.begin(), sortedUBOs.end(),
                      [](const UBORef& a, const UBORef& b) {
                          if (a.active != b.active) return a.active > b.active;
                          return a.glBinding < b.glBinding;
                      });

            // Assign Metal slots to ACTIVE UBOs with running offset
            // (matching spirvToMSL). If the default-uniform block is active,
            // reserve slot 16 for it and start real UBOs at 17. Inactive
            // UBOs get a dummy slot (30) — data bound there is harmless
            // (Metal ignores unmatched slots).
            bool defaultUniformActive = false;
            for (auto& entry : sortedUBOs) {
                if (entry.active &&
                    isDefaultUniformBlockResource(compiler, *entry.res)) {
                    defaultUniformActive = true;
                    break;
                }
            }
            std::uint32_t nextSlot = bindings.uniformBufferBase +
                (defaultUniformActive ? 1u : 0u);
            for (auto& entry : sortedUBOs) {
                auto& ubo = *entry.res;
            ShaderReflection::ResourceBinding rb;
            rb.glBinding = entry.glBinding;
            rb.active = entry.active;
            // Sprint 8 B Cluster F F1 Day 2 (CKPT74): track whether
            // the GLSL had an explicit `layout(binding=N)` qualifier
            // on this UBO. Required for block-array consecutive
            // binding semantics — explicit bindings give b[i] = N+i,
            // implicit bindings give b[i] = 0 (default) for all i.
            rb.hasExplicitBinding =
                compiler.has_decoration(ubo.id, spv::DecorationBinding);
            const bool isDefaultUniform =
                isDefaultUniformBlockResource(compiler, ubo);
            if (entry.active && isDefaultUniform) {
                rb.metalBinding = bindings.uniformBufferBase;
            } else if (entry.active) {
                rb.metalBinding = nextSlot;
                nextSlot += entry.arraySize;
            } else {
                rb.metalBinding = 30; // dummy — not in the Metal shader
            }
            // Use the block TYPE name for introspection. The variable name
            // (ubo.name) is the instance name when present, or the type name
            // when the block has no instance name.
            const auto& uboType = compiler.get_type(ubo.base_type_id);
            const std::string typeName = compiler.get_name(uboType.self);
            rb.name = typeName.empty() ? ubo.name : typeName;
            rb.hasInstanceName = (!typeName.empty() && ubo.name != typeName);
            const auto& type = compiler.get_type(ubo.base_type_id);
            rb.byteSize = compiler.get_declared_struct_size(type);
            rb.containsFp64 = spirvTypeUsesFp64(compiler, type);
            // entry.arraySize is 1 for non-arrays AND for 1-element arrays.
            // Distinguish them by checking the SPIR-V variable type directly.
            {
                const auto& varType = compiler.get_type(ubo.type_id);
                if (!varType.array.empty()) {
                    rb.blockArraySize = entry.arraySize; // true array product (even if [1])
                }
            }

            // Enumerate struct members for per-stage uniform buffer packing.
            // Struct members are recursively flattened: for a member
            // `S s;` where S has fields `a`, `b`, the output contains
            // entries named `s.a`, `s.b` with offsets relative to the
            // UBO base, not the struct base.
            std::function<void(const spirv_cross::SPIRType&, const std::string&, std::size_t)>
                flattenMembers = [&](const spirv_cross::SPIRType& parentType,
                                     const std::string& prefix,
                                     std::size_t baseOffset) {
                for (std::uint32_t mi = 0; mi < parentType.member_types.size(); ++mi) {
                    const auto& memberType = compiler.get_type(parentType.member_types[mi]);
                    std::string memberName = compiler.get_member_name(parentType.self, mi);
                    std::size_t memberOffset = baseOffset +
                        compiler.type_struct_member_offset(parentType, mi);

                    // Recurse into nested struct members.
                    if (memberType.basetype == spirv_cross::SPIRType::Struct &&
                        memberType.columns == 1 && memberType.array.empty()) {
                        std::string childPrefix = prefix.empty()
                            ? memberName : (prefix + "." + memberName);
                        flattenMembers(memberType, childPrefix, memberOffset);
                        continue;
                    }
                    // Recurse into arrays of structs.
                    if (memberType.basetype == spirv_cross::SPIRType::Struct &&
                        !memberType.array.empty() && memberType.array[0] > 0) {
                        std::size_t elemStride = compiler.get_declared_struct_member_size(parentType, mi)
                            / memberType.array[0];
                        for (std::uint32_t ai = 0; ai < memberType.array[0]; ++ai) {
                            std::string elemPrefix = (prefix.empty() ? memberName : (prefix + "." + memberName))
                                + "[" + std::to_string(ai) + "]";
                            flattenMembers(memberType, elemPrefix,
                                           memberOffset + ai * elemStride);
                        }
                        continue;
                    }

                    // Multi-dim array of non-struct: expand outer dims,
                    // keep innermost as arraySize. GL 4.6 §7.3.1.1 —
                    // parallel to the SSBO path's flattenSSBO. CTS
                    // `program_interface_query.arrays-of-arrays` declares
                    // `uniform vec4 a[3][4][5]` and expects 12 entries
                    // (3*4) with arraySize=5 each.
                    if (!memberType.array.empty() && memberType.array.size() > 1 &&
                        memberType.basetype != spirv_cross::SPIRType::Struct) {
                        // SPIRV-Cross order is innermost-first: for GLSL
                        // `vec4 a[3][4][5]` array = [5, 4, 3].
                        const std::uint32_t innermostDim = memberType.array[0];
                        GLint baseArrayStride = 0;
                        try {
                            baseArrayStride = static_cast<GLint>(
                                compiler.type_struct_member_array_stride(parentType, mi));
                        } catch (...) {}
                        if (baseArrayStride <= 0 &&
                            compiler.has_member_decoration(parentType.self, mi,
                                spv::DecorationArrayStride)) {
                            baseArrayStride = static_cast<GLint>(
                                compiler.get_member_decoration(parentType.self, mi,
                                    spv::DecorationArrayStride));
                        }
                        std::uint32_t totalCombos = 1;
                        for (std::size_t d = 1; d < memberType.array.size(); ++d) {
                            totalCombos *= (memberType.array[d] > 0 ? memberType.array[d] : 1);
                        }
                        std::size_t memberTotalSize = 0;
                        try {
                            memberTotalSize =
                                compiler.get_declared_struct_member_size(parentType, mi);
                        } catch (...) {}
                        const GLint perEntryStride =
                            totalCombos > 0 && memberTotalSize > 0
                                ? static_cast<GLint>(memberTotalSize / totalCombos)
                                : baseArrayStride;
                        const GLint innerArrayStride =
                            innermostDim > 0 && perEntryStride > 0
                                ? perEntryStride / static_cast<GLint>(innermostDim)
                                : baseArrayStride;
                        for (std::uint32_t combo = 0; combo < totalCombos; ++combo) {
                            std::string subscript;
                            std::uint32_t remain = combo;
                            std::vector<std::uint32_t> indices;
                            for (std::size_t d = 1; d < memberType.array.size(); ++d) {
                                const std::uint32_t dimSize =
                                    memberType.array[d] > 0 ? memberType.array[d] : 1;
                                indices.push_back(remain % dimSize);
                                remain /= dimSize;
                            }
                            for (auto it = indices.rbegin(); it != indices.rend(); ++it) {
                                subscript += "[" + std::to_string(*it) + "]";
                            }
                            ShaderReflection::UniformMember member;
                            member.name = (prefix.empty()
                                ? memberName : (prefix + "." + memberName)) + subscript;
                            member.offset = memberOffset + combo * perEntryStride;
                            member.size = static_cast<std::size_t>(perEntryStride);
                            member.type = spirvBaseTypeToGL(memberType);
                            member.containsFp64 = spirvTypeUsesFp64(compiler, memberType);
                            rb.containsFp64 = rb.containsFp64 || member.containsFp64;
                            member.isArray = true;
                            member.arraySize = innermostDim;
                            member.arrayStride = innerArrayStride;
                            if (memberType.columns > 1) {
                                member.isRowMajor = compiler.has_member_decoration(
                                    parentType.self, mi, spv::DecorationRowMajor);
                            }
                            if (compiler.has_member_decoration(parentType.self, mi,
                                    spv::DecorationMatrixStride)) {
                                member.matrixStride = static_cast<GLint>(
                                    compiler.get_member_decoration(parentType.self, mi,
                                        spv::DecorationMatrixStride));
                            }
                            rb.members.push_back(std::move(member));
                        }
                        continue;
                    }

                    ShaderReflection::UniformMember member;
                    member.name = prefix.empty()
                        ? memberName : (prefix + "." + memberName);
                    member.offset = memberOffset;
                    member.size = compiler.get_declared_struct_member_size(parentType, mi);
                    member.type = spirvBaseTypeToGL(memberType);
                    member.containsFp64 = spirvTypeUsesFp64(compiler, memberType);
                    rb.containsFp64 = rb.containsFp64 || member.containsFp64;
                    // Detect row_major decoration on matrix members.
                    // A block-level `layout(row_major)` causes SPIRV-Cross
                    // to decorate each matrix member via
                    // DecorationColMajor=false, so only DecorationRowMajor
                    // reliably signals row_major on the member.
                    if (memberType.columns > 1) {
                        member.isRowMajor = compiler.has_member_decoration(
                            parentType.self, mi, spv::DecorationRowMajor);
                    }
                    // Detect array members.
                    if (!memberType.array.empty()) {
                        member.isArray = true;
                        if (memberType.array[0] > 0) {
                            member.arraySize = memberType.array[0];
                        }
                    }
                    // Block-member strides.
                    if (compiler.has_member_decoration(parentType.self, mi,
                            spv::DecorationArrayStride)) {
                        member.arrayStride = static_cast<GLint>(
                            compiler.get_member_decoration(parentType.self, mi,
                                spv::DecorationArrayStride));
                    }
                    if (compiler.has_member_decoration(parentType.self, mi,
                            spv::DecorationMatrixStride)) {
                        member.matrixStride = static_cast<GLint>(
                            compiler.get_member_decoration(parentType.self, mi,
                                spv::DecorationMatrixStride));
                    }
                    // Fallback array stride from declared-size when SPIR-V
                    // didn't decorate the member with DecorationArrayStride.
                    // That happens for array members of nested structs (the
                    // block-level std140 decoration flows to the outer
                    // struct's members but not to inner struct members' own
                    // array decorations — CTS
                    // `shaders.struct.uniform.nested_struct_array_*` ships
                    // `uniform S s[2]; struct S { ... T b[3]; ... };
                    // struct T { ... vec2 b[2]; };` and the innermost
                    // `vec2 b[2]` had stride=0, so
                    // `buildStageUniformBuffer`'s per-element unpadding
                    // loop never fired and element 1 stayed at the initial
                    // zero fill). The inner stride is still std140 because
                    // the whole block is std140; `size / arraySize` gives
                    // the correct value.
                    if (member.isArray && member.arraySize > 0 &&
                        member.arrayStride == 0 && member.size > 0) {
                        member.arrayStride = static_cast<GLint>(
                            member.size / static_cast<std::size_t>(member.arraySize));
                    }
                    rb.members.push_back(std::move(member));
                }
            };
            flattenMembers(type, "", 0);

            // Ensure byteSize covers all flattened members. SPIRV-Cross's
            // get_declared_struct_size can undercount for the last member
            // of a struct (it omits trailing padding — e.g., uvec4 reported
            // as 12 bytes instead of 16). Compute the true member extent
            // from the GL type's component count × 4 bytes.
            for (const auto& m : rb.members) {
                // Compute scalar component count from the GL type.
                std::size_t memberExtent = m.size;  // default fallback
                switch (m.type) {
                    case GL_FLOAT: case GL_INT: case GL_UNSIGNED_INT: case GL_BOOL:
                        memberExtent = 4; break;
                    case GL_FLOAT_VEC2: case GL_INT_VEC2: case GL_UNSIGNED_INT_VEC2: case GL_BOOL_VEC2:
                        memberExtent = 8; break;
                    case GL_FLOAT_VEC3: case GL_INT_VEC3: case GL_UNSIGNED_INT_VEC3: case GL_BOOL_VEC3:
                        memberExtent = 12; break;
                    case GL_FLOAT_VEC4: case GL_INT_VEC4: case GL_UNSIGNED_INT_VEC4: case GL_BOOL_VEC4:
                        memberExtent = 16; break;
                    // Matrices: major vectors × 16 in std140. Row-major
                    // rectangular matrices are reflected with RowMajor
                    // decoration, so their major vector count is rows.
                    case GL_FLOAT_MAT2:   memberExtent = 2 * 16; break;
                    case GL_FLOAT_MAT3:   memberExtent = 3 * 16; break;
                    case GL_FLOAT_MAT4:   memberExtent = 4 * 16; break;
                    case GL_FLOAT_MAT2x3: memberExtent = (m.isRowMajor ? 3 : 2) * 16; break;
                    case GL_FLOAT_MAT2x4: memberExtent = (m.isRowMajor ? 4 : 2) * 16; break;
                    case GL_FLOAT_MAT3x2: memberExtent = (m.isRowMajor ? 2 : 3) * 16; break;
                    case GL_FLOAT_MAT3x4: memberExtent = (m.isRowMajor ? 4 : 3) * 16; break;
                    case GL_FLOAT_MAT4x2: memberExtent = (m.isRowMajor ? 2 : 4) * 16; break;
                    case GL_FLOAT_MAT4x3: memberExtent = (m.isRowMajor ? 3 : 4) * 16; break;
                    default: break;
                }
                // For arrays, total extent = arraySize × stride (stride = vec4-aligned element)
                if (m.arraySize > 0) {
                    // Each array element is rounded up to vec4 alignment (16 bytes)
                    std::size_t elemAligned = (memberExtent + 15) & ~std::size_t(15);
                    memberExtent = m.arraySize * elemAligned;
                }
                std::size_t memberEnd = m.offset + memberExtent;
                if (memberEnd > rb.byteSize) {
                    rb.byteSize = (memberEnd + 15) & ~std::size_t(15);
                }
            }
            rb.byteSize = (rb.byteSize + 15) & ~std::size_t(15);

            result.uniformBlocks.push_back(std::move(rb));
            } // end for sortedUBOs
        } // end UBO block

        // Push-constant blocks (default-block uniforms from OpenGL).
        for (auto& pc : resources.push_constant_buffers) {
            ShaderReflection::ResourceBinding rb;
            rb.glBinding = 0;
            rb.metalBinding = bindings.uniformBufferBase;
            rb.name = pc.name;
            const auto& type = compiler.get_type(pc.base_type_id);
            rb.byteSize = compiler.get_declared_struct_size(type);
            rb.containsFp64 = spirvTypeUsesFp64(compiler, type);

            // Enumerate default-block members recursively. GLSL default
            // uniforms can include structs and arrays-of-structs; GL exposes
            // the flattened leaves via glGetUniformLocation, e.g.
            // `s[0].field`, not the top-level struct object.
            std::function<void(const spirv_cross::SPIRType&,
                               const std::string&,
                               std::size_t)> flattenDefaultMembers;
            flattenDefaultMembers =
                [&](const spirv_cross::SPIRType& parentType,
                    const std::string& prefix,
                    std::size_t baseOffset) {
                for (std::uint32_t mi = 0;
                     mi < parentType.member_types.size(); ++mi) {
                    const auto& memberType =
                        compiler.get_type(parentType.member_types[mi]);
                    const std::string memberName =
                        compiler.get_member_name(parentType.self, mi);
                    const std::size_t memberOffset = baseOffset +
                        compiler.type_struct_member_offset(parentType, mi);
                    const std::string qualifiedName = prefix.empty()
                        ? memberName : (prefix + "." + memberName);

                    if (memberType.basetype == spirv_cross::SPIRType::Struct &&
                        memberType.columns == 1 && memberType.array.empty()) {
                        flattenDefaultMembers(memberType, qualifiedName,
                                              memberOffset);
                        continue;
                    }
                    if (memberType.basetype == spirv_cross::SPIRType::Struct &&
                        !memberType.array.empty() && memberType.array[0] > 0) {
                        const std::size_t elemStride =
                            compiler.get_declared_struct_member_size(
                                parentType, mi) / memberType.array[0];
                        for (std::uint32_t ai = 0; ai < memberType.array[0];
                             ++ai) {
                            flattenDefaultMembers(
                                memberType,
                                qualifiedName + "[" + std::to_string(ai) + "]",
                                memberOffset + ai * elemStride);
                        }
                        continue;
                    }

                    if (!memberType.array.empty() &&
                        memberType.array.size() > 1 &&
                        memberType.basetype != spirv_cross::SPIRType::Struct) {
                        const std::uint32_t innermostDim =
                            memberType.array[0];
                        GLint baseArrayStride = 0;
                        try {
                            baseArrayStride = static_cast<GLint>(
                                compiler.type_struct_member_array_stride(parentType, mi));
                        } catch (...) {}
                        if (baseArrayStride <= 0 &&
                            compiler.has_member_decoration(
                                parentType.self, mi,
                                spv::DecorationArrayStride)) {
                            baseArrayStride = static_cast<GLint>(
                                compiler.get_member_decoration(
                                    parentType.self, mi,
                                    spv::DecorationArrayStride));
                        }
                        std::uint32_t totalCombos = 1;
                        for (std::size_t d = 1; d < memberType.array.size();
                             ++d) {
                            totalCombos *=
                                memberType.array[d] > 0 ? memberType.array[d] : 1;
                        }
                        const std::size_t memberTotalSize =
                            compiler.get_declared_struct_member_size(parentType, mi);
                        const std::size_t perEntryStride =
                            totalCombos > 0 && memberTotalSize > 0
                                ? memberTotalSize / totalCombos
                                : static_cast<std::size_t>(baseArrayStride);
                        const GLint innerArrayStride =
                            innermostDim > 0 && perEntryStride > 0
                                ? static_cast<GLint>(perEntryStride / innermostDim)
                                : baseArrayStride;
                        for (std::uint32_t combo = 0; combo < totalCombos;
                             ++combo) {
                            std::string subscript;
                            std::uint32_t remain = combo;
                            std::vector<std::uint32_t> indices;
                            for (std::size_t d = 1;
                                 d < memberType.array.size(); ++d) {
                                const std::uint32_t dimSize =
                                    memberType.array[d] > 0
                                        ? memberType.array[d] : 1;
                                indices.push_back(remain % dimSize);
                                remain /= dimSize;
                            }
                            for (auto it = indices.rbegin();
                                 it != indices.rend(); ++it) {
                                subscript += "[" + std::to_string(*it) + "]";
                            }

                            ShaderReflection::UniformMember member;
                            member.name = qualifiedName + subscript;
                            member.offset = memberOffset +
                                combo * perEntryStride;
                            member.size = perEntryStride;
                            member.type = spirvBaseTypeToGL(memberType);
                            member.containsFp64 =
                                spirvTypeUsesFp64(compiler, memberType);
                            rb.containsFp64 =
                                rb.containsFp64 || member.containsFp64;
                            member.isArray = true;
                            member.arraySize = innermostDim;
                            member.arrayStride = innerArrayStride;
                            if (memberType.columns > 1) {
                                member.isRowMajor =
                                    compiler.has_member_decoration(
                                        parentType.self, mi,
                                        spv::DecorationRowMajor);
                            }
                            if (compiler.has_member_decoration(
                                    parentType.self, mi,
                                    spv::DecorationMatrixStride)) {
                                member.matrixStride = static_cast<GLint>(
                                    compiler.get_member_decoration(
                                        parentType.self, mi,
                                        spv::DecorationMatrixStride));
                            }
                            rb.members.push_back(std::move(member));
                        }
                        continue;
                    }

                    ShaderReflection::UniformMember member;
                    member.name = qualifiedName;
                    member.offset = memberOffset;
                    member.size =
                        compiler.get_declared_struct_member_size(parentType, mi);
                    member.type = spirvBaseTypeToGL(memberType);
                    member.containsFp64 =
                        spirvTypeUsesFp64(compiler, memberType);
                    rb.containsFp64 = rb.containsFp64 || member.containsFp64;
                    if (!memberType.array.empty() && memberType.array[0] > 0) {
                        member.isArray = true;
                        member.arraySize = memberType.array[0];
                    }
                    if (compiler.has_member_decoration(
                            parentType.self, mi,
                            spv::DecorationArrayStride)) {
                        member.arrayStride = static_cast<GLint>(
                            compiler.get_member_decoration(
                                parentType.self, mi,
                                spv::DecorationArrayStride));
                        if (member.arraySize > 0 && member.arrayStride > 0) {
                            member.size = std::max<std::size_t>(
                                member.size,
                                static_cast<std::size_t>(member.arrayStride) *
                                    static_cast<std::size_t>(member.arraySize));
                        }
                    }
                    if (memberType.columns > 1) {
                        member.isRowMajor = compiler.has_member_decoration(
                            parentType.self, mi, spv::DecorationRowMajor);
                    }
                    if (compiler.has_member_decoration(
                            parentType.self, mi,
                            spv::DecorationMatrixStride)) {
                        member.matrixStride = static_cast<GLint>(
                            compiler.get_member_decoration(
                                parentType.self, mi,
                                spv::DecorationMatrixStride));
                    }
                    rb.members.push_back(std::move(member));
                }
            };
            flattenDefaultMembers(type, "", 0);
            for (const auto& member : rb.members) {
                rb.byteSize = std::max<std::size_t>(
                    rb.byteSize, member.offset + member.size);
            }

            result.uniformBlocks.push_back(std::move(rb));
        }

        // Sampled images.
        //
        // Step 7-3 follow-up: under argument_buffers mode, reflection's
        // metalBinding doubles as the argbuf `[[id(N)]]` slot so the
        // Metal-side bind code uses it directly without resource-type-
        // specific translation. The values here must match the
        // `msl_texture` / `msl_sampler` set by the translator's
        // `add_msl_resource_binding` calls (see the phase-7-2
        // consolidation comment in spirvToMSL):
        //
        //   sampled_images: msl_texture = 2*glBinding, sampler = +1
        //   storage_images: msl_texture = 128 + glBinding
        //   SSBOs:          msl_buffer  = 192 + glBinding
        //   UBOs:           msl_buffer  = 16 + seq  (same as direct)
        //
        // Direct-binding mode keeps the existing textureBase /
        // storageBufferBase sequential assignment so baseline Metal
        // slot layout is unchanged.
        //
        // Lifetime invariant: `APPGL_ENABLE_ARGUMENT_BUFFERS` is read
        // once per reflect() call, mirroring the equivalent check in
        // spirvToMSL(). Both run at glLinkProgram time (for a given
        // program) and nothing downstream re-reads the env var, so as
        // long as the env is set before linkProgram (which is how the
        // gate is used — set once at process start), reflection and
        // translation always agree. If the env var were toggled mid-
        // process, new programs would pick up the new mode; already-
        // linked programs retain their old mode until relinked.
        const bool useArgBufReflection = options.forceArgumentBuffers ||
            (std::getenv("APPGL_ENABLE_ARGUMENT_BUFFERS") != nullptr);
        // Sprint 8 B Cluster F F1 Day 5 (CKPT77): mirror spirvToMSL's
        // sequential allocator for the direct-binding path so the
        // reflected `metalBinding` matches the MSL-emitted
        // `[[texture(N)]]` slot. Sort by (glBinding, id) and walk a
        // running counter that advances by each entry's array size.
        // See the matching block in spirvToMSL above for the full
        // rationale. Argument-buffer mode keeps its 2*glBinding mapping.
        //
        // Day 9 (CKPT81): unified counter with storage-images so both
        // share Metal's per-stage texture slot pool (Apple Silicon
        // 31-cap). Walks sampled first, then storage, in lockstep with
        // spirvToMSL's `unifiedNextTextureSlot`.
        std::uint32_t unifiedNextTextureSlotR = bindings.textureBase;
        {
            struct SampledRefR {
                std::uint32_t glBinding;
                std::uint32_t id;
                std::uint32_t arraySize;
                spirv_cross::Resource* res;
            };
            std::vector<SampledRefR> sortedSampled;
            for (auto& img : resources.sampled_images) {
                SampledRefR r;
                r.glBinding = compiler.get_decoration(img.id, spv::DecorationBinding);
                r.id = img.id;
                const auto& imgType = compiler.get_type(img.type_id);
                r.arraySize = imgType.array.empty()
                    ? 1u
                    : (imgType.array[0] > 0 ? imgType.array[0] : 1u);
                r.res = &img;
                sortedSampled.push_back(r);
            }
            std::sort(sortedSampled.begin(), sortedSampled.end(),
                      [](const SampledRefR& a, const SampledRefR& b) {
                          if (a.glBinding != b.glBinding) return a.glBinding < b.glBinding;
                          return a.id < b.id;
                      });
            for (auto& entry : sortedSampled) {
                ShaderReflection::ResourceBinding rb;
                rb.glBinding = entry.glBinding;
                rb.uniformLocation =
                    compiler.has_decoration(entry.res->id, spv::DecorationLocation)
                        ? static_cast<GLint>(compiler.get_decoration(entry.res->id, spv::DecorationLocation))
                        : -1;
                rb.arraySize = entry.arraySize;
                const auto& sampledType = compiler.get_type(entry.res->type_id);
                rb.glType = sampledImageUniformTypeForType(compiler, sampledType);
                if (useArgBufReflection) {
                    rb.metalBinding = 2 * entry.glBinding;
                } else {
                    rb.metalBinding = unifiedNextTextureSlotR;
                    unifiedNextTextureSlotR += entry.arraySize;
                }
                rb.name = entry.res->name;
                result.sampledTextures.push_back(std::move(rb));
            }
        }

        // Storage images (imageLoad/imageStore targets). Distinct from
        // sampled textures because the GL binding model differs: storage
        // images are bound via glBindImageTexture(unit, tex, …), not via
        // a sampler uniform that names a texture unit. Dispatch-time
        // binding resolution iterates this list separately and looks up
        // imageBindings[glBinding] rather than a uniform value.
        //
        // Phase 7 cleanup (a): filter to ACTIVE storage images only.
        // A declared-but-unused `uniform image2D` would stay in
        // `resources.storage_images` but SPIRV-Cross's dead-code pass
        // drops it from the emitted MSL, so Metal's argument-encoder
        // reflection doesn't see it either. Pushing the inactive
        // binding into the GL-side list gave `ComputeDispatchInfo::
        // textures` entries whose `metalSlot` was outside the
        // encoder's enumerated index range, triggering
        //   "index (N) is outside of the valid index range [M, M]"
        // on `compute_shader.pipeline-post-fs` (shared GLSL source
        // with a #define-toggled input-image use, so the pre-fs
        // compile drops g_input_image but retains its declaration).
        auto activeStorageImages = compiler.get_active_interface_variables();
        auto storageImageAccesses =
            storageImageAccessVariables(spirv, wordCount, resources.storage_images);
        {
            // Mirror the (glBinding, id) sort used by spirvToMSL so
            // reflection's `metalBinding` lines up with each image's
            // MSL-declared `[[texture(N)]]` exactly. The sequential-
            // allocation path below depends on seeing the images in
            // the same deterministic order. See the phase-7
            // consolidation comment in spirvToMSL for the full
            // rationale — summary: (1) disjoint from sampled
            // textures via `storageImageBase`, (2) sequentially
            // packed so two images sharing a glBinding land at
            // distinct Metal slots, (3) runtime resolves via the
            // original `glBinding` (read from SPIR-V here) + any
            // glUniform1i override, not via `metalBinding`.
            struct StorageImgRef {
                std::uint32_t glBinding;
                std::uint32_t id;
                std::uint32_t arraySize = 1;
                bool multisample = false;
                bool multisampleArray = false;
                GLenum storageTarget = 0;
                GLenum glType = GL_IMAGE_2D;
                bool sparseRead = false;
                bool sparseWrite = false;
                bool nonWritable = false;
                bool nonReadable = false;
                bool containsFp64 = false;
                spirv_cross::Resource* res;
            };
            std::vector<StorageImgRef> sortedStorageImages;
            for (auto& img : resources.storage_images) {
                if (activeStorageImages.find(img.id) == activeStorageImages.end())
                    continue;
                StorageImgRef r;
                r.glBinding = compiler.get_decoration(img.id, spv::DecorationBinding);
                r.id = img.id;
                const auto& varType = compiler.get_type(img.type_id);
                const auto& baseType = compiler.get_type(img.base_type_id);
                r.arraySize = varType.array.empty()
                    ? 1u
                    : (varType.array[0] > 0 ? varType.array[0] : 1u);
                const auto& imageType =
                    varType.basetype == spirv_cross::SPIRType::Image
                        ? varType : baseType;
                r.multisample =
                    imageType.basetype == spirv_cross::SPIRType::Image &&
                    imageType.image.ms &&
                    imageType.image.dim == spv::Dim2D &&
                    imageType.image.sampled == 2;
                r.multisampleArray = r.multisample && imageType.image.arrayed;
                r.storageTarget = storageImageTargetForType(imageType);
                r.glType = storageImageUniformTypeForType(compiler, imageType);
                r.nonWritable =
                    compiler.has_decoration(img.id, spv::DecorationNonWritable);
                r.nonReadable =
                    compiler.has_decoration(img.id, spv::DecorationNonReadable);
                r.containsFp64 = spirvTypeUsesFp64(compiler, imageType);
                r.sparseRead =
                    storageImageAccesses.reads.find(img.id) !=
                        storageImageAccesses.reads.end() &&
                    sparseStorageImageSidecarTarget(r.storageTarget);
                r.sparseWrite =
                    storageImageAccesses.writes.find(img.id) !=
                        storageImageAccesses.writes.end() &&
                    sparseStorageImageSidecarTarget(r.storageTarget);
                r.res = &img;
                sortedStorageImages.push_back(r);
            }
            std::sort(sortedStorageImages.begin(), sortedStorageImages.end(),
                      [](const StorageImgRef& a, const StorageImgRef& b) {
                          if (a.glBinding != b.glBinding) return a.glBinding < b.glBinding;
                          return a.id < b.id;
                      });
            std::uint32_t nextArgBufStorageImageSlotR = 0;
            for (std::size_t i = 0; i < sortedStorageImages.size(); ++i) {
                const auto& entry = sortedStorageImages[i];
                ShaderReflection::ResourceBinding rb;
                // Preserve the ORIGINAL glBinding — runtime uses it
                // (plus any glUniform1i override) to pick the GL
                // image unit. metalBinding is the synthetic Metal
                // slot chosen by our sequential allocator.
                rb.glBinding = entry.glBinding;
                rb.uniformLocation =
                    compiler.has_decoration(entry.res->id, spv::DecorationLocation)
                        ? static_cast<GLint>(compiler.get_decoration(entry.res->id, spv::DecorationLocation))
                        : -1;
                rb.glType = entry.glType;
                rb.arraySize = entry.arraySize;
                if (useArgBufReflection) {
                    rb.metalBinding = 128 + nextArgBufStorageImageSlotR;
                    rb.metalAtomicBufferBinding =
                        bindings.storageImageAtomicBufferBase + static_cast<std::uint32_t>(i);
                    nextArgBufStorageImageSlotR += std::max<std::uint32_t>(
                        entry.arraySize, 1u);
                } else {
                    // CKPT81: shared pool with sampled images.
                    rb.metalBinding = unifiedNextTextureSlotR;
                    rb.metalAtomicBufferBinding =
                        bindings.storageImageAtomicBufferBase + static_cast<std::uint32_t>(i);
                    unifiedNextTextureSlotR += 1;
                }
                rb.name = entry.res->name;
                rb.multisampleStorageImage = entry.multisample;
                rb.multisampleStorageImageArray = entry.multisampleArray;
                rb.storageImageTarget = entry.storageTarget;
                rb.storageImageNonWritable = entry.nonWritable;
                rb.storageImageNonReadable = entry.nonReadable;
                rb.sparseStorageImageRead = entry.sparseRead;
                rb.sparseStorageImageWrite = entry.sparseWrite;
                rb.containsFp64 = entry.containsFp64;
                result.storageImages.push_back(std::move(rb));
            }
        }

        // Shader-storage buffer objects (GL 4.3+). Metal side: SSBOs live
        // in buffer slots above UBOs. Sequential allocation in glBinding-
        // sorted order, matching spirvToMSL's MSLResourceBinding setup
        // — a shader with `layout(binding=7)` gets Metal slot
        // storageBufferBase+1 (2nd in sorted order) even though the GL
        // binding is 7, because Metal only has 31 buffer slots total.
        //
        // First: collect and sort SSBOs by glBinding to match spirvToMSL.
        std::vector<std::pair<std::uint32_t, spirv_cross::Resource*>> sortedSSBOs;
        auto ssboActive = compiler.get_active_interface_variables();
        auto ssboAccesses =
            storageBufferAccessVariables(spirv, wordCount, resources.storage_buffers);
        for (auto& ssbo : resources.storage_buffers) {
            if (isAtomicCounterStorageBuffer(ssbo)) continue;
            sortedSSBOs.emplace_back(
                compiler.get_decoration(ssbo.id, spv::DecorationBinding), &ssbo);
        }
        std::sort(sortedSSBOs.begin(), sortedSSBOs.end(),
                  [](auto& a, auto& b) { return a.first < b.first; });
        std::uint32_t nextSSBOSlot = bindings.storageBufferBase;
        for (auto& ssboEntry : sortedSSBOs) {
            auto& ssbo = *ssboEntry.second;
            ShaderReflection::ResourceBinding rb;
            rb.glBinding = ssboEntry.first;
            {
                const auto& varType = compiler.get_type(ssbo.type_id);
                if (!varType.array.empty()) {
                    std::uint32_t count = 1;
                    for (const auto dim : varType.array) {
                        count *= dim > 0 ? static_cast<std::uint32_t>(dim) : 1u;
                    }
                    rb.blockArraySize = count;
                }
            }
            const std::uint32_t slotSpan =
                rb.blockArraySize > 0 ? rb.blockArraySize : 1u;
            // Sprint 8 B Cluster F F1 Day 2 (CKPT74): track explicit
            // binding for SSBO block-array consecutive semantics.
            rb.hasExplicitBinding =
                compiler.has_decoration(ssbo.id, spv::DecorationBinding);
            // Step 7-3 follow-up: argbuf reflection mirror — see the
            // sampled_images block above for the full rationale. SSBOs
            // under argbuf live at [[id(192 + glBinding)]] inside
            // spvDescriptorSetBuffer0.
            if (useArgBufReflection) {
                rb.metalBinding = 192 + rb.glBinding;
            } else {
                rb.metalBinding = nextSSBOSlot;
                nextSSBOSlot += slotSpan;
            }
            rb.active = (ssboActive.find(ssbo.id) != ssboActive.end());
            rb.storageBufferWritten =
                ssboAccesses.writes.find(ssbo.id) != ssboAccesses.writes.end();
            const auto& ssboType = compiler.get_type(ssbo.base_type_id);
            rb.containsFp64 = spirvTypeUsesFp64(compiler, ssboType);
            const std::string typeName = compiler.get_name(ssboType.self);
            rb.name = typeName.empty() ? ssbo.name : typeName;
            rb.hasInstanceName = (!typeName.empty() && ssbo.name != typeName);
            // Block-array dimension: `buffer B { ... } e[2];` → 2.
            // Parallel to the UBO reflection path above. Drives the
            // per-instance block-entry expansion in mergeStorageBlocks and
            // reserves consecutive Metal slots matching SPIRV-Cross MSL.
            // byteSize may be zero if the block contains a trailing
            // unbounded array (common for SSBOs) — callers must not
            // rely on it for draw-time binding size.
            try {
                rb.byteSize = compiler.get_declared_struct_size(ssboType);
            } catch (...) {
                rb.byteSize = 0;
            }
            // Recursively flatten struct members. GL 4.6 §7.3.1.1:
            // each scalar/vector/matrix leaf is a separate buffer
            // variable. For `buffer B { UU a[3]; mat4 b; }`, UU
            // containing `U a;` containing `vec4 b;`, the flat
            // output contains "a[0].a.b", "a[0].a.c", etc. alongside
            // "b". CTS `program_interface_query.ssb-types` exercises
            // the nested case.
            // `topLevelArraySize` plumbed through recursion so every
            // nested leaf reports the GL 4.6 §7.3.1
            // GL_TOP_LEVEL_ARRAY_SIZE of its outermost block member.
            // Default 1 (scalar top). Set when we enter an array-of-
            // struct at the TOP LEVEL only (isTopLevel=true) so that
            // deeper arrays don't overwrite it.
            std::function<void(const spirv_cross::SPIRType&, const std::string&, std::size_t, GLint, GLint, bool)>
                flattenSSBO = [&](const spirv_cross::SPIRType& parentType,
                                   const std::string& prefix,
                                   std::size_t baseOffset,
                                   GLint topLevelArraySize,
                                   GLint topLevelArrayStride,
                                   bool isTopLevel) {
                for (std::uint32_t mi = 0; mi < parentType.member_types.size(); ++mi) {
                    const auto& memberType = compiler.get_type(parentType.member_types[mi]);
                    std::string memberName = compiler.get_member_name(parentType.self, mi);
                    std::size_t memberOffset = baseOffset;
                    try {
                        memberOffset += compiler.type_struct_member_offset(parentType, mi);
                    } catch (...) { /* unbounded-tail member — stays at baseOffset */ }

                    // SPIRV-Cross stores `type.array` innermost-first
                    // per OpTypeArray nesting. For GLSL `vec4 a[5][4][3]`
                    // the array is [3, 4, 5] — array[0] is the innermost
                    // dim (3), array.back() is the outermost (5).
                    const bool hasArr = !memberType.array.empty();
                    const std::uint32_t innermostDim = hasArr
                        ? memberType.array[0] : 0;
                    const std::uint32_t outermostDim = hasArr
                        ? memberType.array.back() : 0;
                    GLint reflectedArrayStride = 0;
                    if (hasArr) {
                        try {
                            reflectedArrayStride = static_cast<GLint>(
                                compiler.type_struct_member_array_stride(parentType, mi));
                        } catch (...) {}
                        if (reflectedArrayStride <= 0 &&
                            compiler.has_member_decoration(parentType.self, mi,
                                spv::DecorationArrayStride)) {
                            reflectedArrayStride = static_cast<GLint>(
                                compiler.get_member_decoration(parentType.self, mi,
                                    spv::DecorationArrayStride));
                        }
                    }

                    // Compute this member's effective top-level size:
                    // - at the top level, it's the member's own
                    //   outermost array dim (or 1 if not an array).
                    // - unbounded top-level arrays of scalars/vectors
                    //   (`data[]`) still report a top-level array size of 1;
                    //   the member's GL_ARRAY_SIZE below remains 0 to
                    //   represent the runtime array.
                    // - unbounded top-level arrays of structs (`s[]`) keep 0,
                    //   and nested leaves inherit that unsized top-level.
                    // - below the top level, inherit the incoming value.
                    GLint effTopLevel = topLevelArraySize;
                    GLint effTopLevelStride = topLevelArrayStride;
                    if (isTopLevel) {
                        if (!hasArr) {
                            effTopLevel = 1;
                            effTopLevelStride = 0;
                        } else if (outermostDim > 0) {
                            effTopLevel = static_cast<GLint>(outermostDim);
                            effTopLevelStride = reflectedArrayStride;
                        } else if (memberType.basetype == spirv_cross::SPIRType::Struct) {
                            effTopLevel = 0;  // unsized top-level struct array
                            effTopLevelStride = reflectedArrayStride;
                        } else {
                            effTopLevel = 1;  // runtime array, top-level member count
                            effTopLevelStride = reflectedArrayStride;
                        }
                    }

                    // Recurse into nested struct members.
                    if (memberType.basetype == spirv_cross::SPIRType::Struct &&
                        memberType.columns == 1 && memberType.array.empty()) {
                        std::string childPrefix = prefix.empty()
                            ? memberName : (prefix + "." + memberName);
                        flattenSSBO(memberType, childPrefix, memberOffset,
                                    effTopLevel, effTopLevelStride, false);
                        continue;
                    }
                    // Recurse into arrays of structs. SSBO buffer-variable
                    // enumeration exposes only the first element of an array
                    // member, including unsized tails (`s[]`), then recurses
                    // into that element's aggregate leaves.
                    if (memberType.basetype == spirv_cross::SPIRType::Struct &&
                        !memberType.array.empty()) {
                        std::string elemPrefix =
                            (prefix.empty() ? memberName : (prefix + "." + memberName)) + "[0]";
                        flattenSSBO(memberType, elemPrefix, memberOffset,
                                    effTopLevel, effTopLevelStride, false);
                        continue;
                    }

                    // Multi-dim array of non-struct (e.g. `vec4 a[5][4][3]`).
                    // GL 4.6 §7.3.1: expand all outer dims into separate
                    // entries, keep ONLY the innermost as the entry's
                    // arraySize. For `vec4 a[5][4][3]` (SPIR-V array =
                    // [3, 4, 5]): emit 5*4=20 entries named "a[i][j]"
                    // with arraySize=3, topLevelArraySize=5.
                    if (hasArr && memberType.array.size() > 1 &&
                        memberType.basetype != spirv_cross::SPIRType::Struct) {
                        // Outer dims are array[1..end-1] in SPIR-V order;
                        // walk them in reverse so we emit names in
                        // GLSL subscript order (outermost first).
                        GLint baseArrayStride = reflectedArrayStride;
                        // Total product of outer dims (dims above array[0]).
                        std::uint32_t totalCombos = 1;
                        for (std::size_t d = 1; d < memberType.array.size(); ++d) {
                            totalCombos *= (memberType.array[d] > 0 ? memberType.array[d] : 1);
                        }
                        // Total byte size of the whole multi-dim member
                        // — used to compute GL_TOP_LEVEL_ARRAY_STRIDE
                        // (bytes between outermost elements = total / outerDim).
                        std::size_t memberTotalSize = 0;
                        try {
                            memberTotalSize = compiler.get_declared_struct_member_size(parentType, mi);
                        } catch (...) {}
                        // Per-entry stride for offset bookkeeping: each
                        // flattened member represents one innermost array
                        // slice, while topLevelArrayStride below keeps the
                        // distance between outermost elements.
                        const GLint perEntryStride =
                            totalCombos > 0 && memberTotalSize > 0
                                ? static_cast<GLint>(memberTotalSize / totalCombos)
                                : baseArrayStride;
                        const GLint innerArrayStride =
                            innermostDim > 0 && perEntryStride > 0
                                ? perEntryStride / static_cast<GLint>(innermostDim)
                                : baseArrayStride;
                        GLint tlStride = 0;
                        if (outermostDim > 0 && memberTotalSize > 0) {
                            tlStride = static_cast<GLint>(memberTotalSize / outermostDim);
                        } else if (baseArrayStride > 0) {
                            tlStride = baseArrayStride;
                        }
                        for (std::uint32_t combo = 0; combo < totalCombos; ++combo) {
                            // Decompose `combo` into per-dim indices.
                            // combo layout: least-significant = innermost
                            // outer dim (array[1]). Reverse to get
                            // outermost-first subscript.
                            std::string subscript;
                            std::uint32_t remain = combo;
                            // Walk from innermost-outer (array[1]) up to
                            // outermost (array.back()). At each step
                            // capture the index modulo that dim.
                            std::vector<std::uint32_t> indices;
                            for (std::size_t d = 1; d < memberType.array.size(); ++d) {
                                const std::uint32_t dimSize =
                                    memberType.array[d] > 0 ? memberType.array[d] : 1;
                                indices.push_back(remain % dimSize);
                                remain /= dimSize;
                            }
                            // indices are innermost-outer first; reverse
                            // to outermost-first for GLSL "[i][j]..." order.
                            for (auto it = indices.rbegin(); it != indices.rend(); ++it) {
                                subscript += "[" + std::to_string(*it) + "]";
                            }

                            ShaderReflection::UniformMember member;
                            member.name = (prefix.empty()
                                ? memberName : (prefix + "." + memberName)) + subscript;
                            member.offset = memberOffset + combo * perEntryStride;
                            member.size = perEntryStride;
                            member.type = spirvBaseTypeToGL(memberType);
                            member.containsFp64 = spirvTypeUsesFp64(compiler, memberType);
                            rb.containsFp64 = rb.containsFp64 || member.containsFp64;
                            member.topLevelArraySize = effTopLevel;
                            member.topLevelArrayStride = tlStride;
                            member.isArray = true;
                            member.arraySize = innermostDim;  // 0 for unbounded
                            member.arrayStride = innerArrayStride;
                            // Row-major decoration (matrix of array).
                            if (memberType.columns > 1) {
                                member.isRowMajor = compiler.has_member_decoration(
                                    parentType.self, mi, spv::DecorationRowMajor);
                            }
                            if (compiler.has_member_decoration(parentType.self, mi,
                                    spv::DecorationMatrixStride)) {
                                member.matrixStride = static_cast<GLint>(
                                    compiler.get_member_decoration(parentType.self, mi,
                                        spv::DecorationMatrixStride));
                            }
                            rb.members.push_back(std::move(member));
                        }
                        continue;
                    }

                    ShaderReflection::UniformMember member;
                    member.name = prefix.empty()
                        ? memberName : (prefix + "." + memberName);
                    member.offset = memberOffset;
                    try {
                        member.size = compiler.get_declared_struct_member_size(parentType, mi);
                    } catch (...) {
                        member.size = 0;  // unbounded tail
                    }
                    member.type = spirvBaseTypeToGL(memberType);
                    member.containsFp64 = spirvTypeUsesFp64(compiler, memberType);
                    rb.containsFp64 = rb.containsFp64 || member.containsFp64;
                    member.topLevelArraySize = effTopLevel;
                    member.topLevelArrayStride = effTopLevelStride;
                    // Row-major decoration (matrix members only).
                    if (memberType.columns > 1) {
                        member.isRowMajor = compiler.has_member_decoration(
                            parentType.self, mi, spv::DecorationRowMajor);
                    }
                    if (hasArr) {
                        member.isArray = true;
                        member.arraySize = innermostDim;  // 0 for unbounded
                    }
                    if (compiler.has_member_decoration(parentType.self, mi,
                            spv::DecorationArrayStride)) {
                        member.arrayStride = static_cast<GLint>(
                            compiler.get_member_decoration(parentType.self, mi,
                                spv::DecorationArrayStride));
                        // Single-dim top-level array member (e.g.
                        // `vec4 data[]` or `vec4 data[N]`): top-level
                        // stride equals the member's array stride.
                        if (isTopLevel) {
                            member.topLevelArrayStride = member.arrayStride;
                        }
                    }
                    if (hasArr && member.arrayStride == 0) {
                        member.arrayStride = reflectedArrayStride;
                    }
                    if (hasArr && member.arraySize > 0 &&
                        member.arrayStride == 0 && member.size > 0) {
                        member.arrayStride = static_cast<GLint>(
                            member.size / static_cast<std::size_t>(member.arraySize));
                    }
                    if (compiler.has_member_decoration(parentType.self, mi,
                            spv::DecorationMatrixStride)) {
                        member.matrixStride = static_cast<GLint>(
                            compiler.get_member_decoration(parentType.self, mi,
                                spv::DecorationMatrixStride));
                    }
                    rb.members.push_back(std::move(member));
                }
            };
            flattenSSBO(ssboType, "", 0, 1, 0, true);
            for (const auto& member : rb.members) {
                if (member.size == 0) {
                    continue;
                }
                rb.byteSize = std::max(
                    rb.byteSize,
                    member.offset + member.size);
            }
            rb.byteSize = (rb.byteSize + 15) & ~std::size_t(15);
            result.storageBuffers.push_back(std::move(rb));
        }

        // Check for gl_PointSize usage.
        for (auto& builtin : resources.stage_outputs) {
            if (compiler.has_decoration(builtin.id, spv::DecorationBuiltIn)) {
                auto builtinType = static_cast<spv::BuiltIn>(compiler.get_decoration(builtin.id, spv::DecorationBuiltIn));
                if (builtinType == spv::BuiltInPointSize) {
                    result.usesPointSize = true;
                }
            }
        }

        if (log != nullptr) {
            *log = "ok";
        }
    } catch (const spirv_cross::CompilerError& e) {
        if (log != nullptr) {
            *log = std::string("SPIRV-Cross reflection error: ") + e.what();
        }
    }
    return result;
}

ComputeExecutionModes extractComputeModes(const std::uint32_t* spirv, std::size_t wordCount) {
    ComputeExecutionModes modes;
    if (!spirv || wordCount < 5) return modes;
    try {
        spirv_cross::Compiler compiler(spirv, wordCount);
        // Extract local_size_x/y/z from ExecutionModeLocalSize — the only
        // reliable source for compute-shader thread group dimensions on
        // the Metal side. glslang emits this decoration for every compute
        // shader; if it somehow isn't present, the (1,1,1) defaults
        // above keep dispatchThreadgroups from receiving a zero size.
        const auto& bitset = compiler.get_execution_mode_bitset();
        if (bitset.get(spv::ExecutionModeLocalSize)) {
            modes.localSizeX = std::max<std::uint32_t>(1,
                compiler.get_execution_mode_argument(spv::ExecutionModeLocalSize, 0));
            modes.localSizeY = std::max<std::uint32_t>(1,
                compiler.get_execution_mode_argument(spv::ExecutionModeLocalSize, 1));
            modes.localSizeZ = std::max<std::uint32_t>(1,
                compiler.get_execution_mode_argument(spv::ExecutionModeLocalSize, 2));
        }
    } catch (...) {}
    return modes;
}

TessellationModes extractTessellationModes(const std::uint32_t* spirv, std::size_t wordCount) {
    TessellationModes modes;
    if (!spirv || wordCount < 5) return modes;
    try {
        spirv_cross::Compiler compiler(spirv, wordCount);
        auto& bitset = compiler.get_execution_mode_bitset();

        // TCS: output vertices
        if (bitset.get(spv::ExecutionModeOutputVertices)) {
            modes.outputVertices = static_cast<int>(
                compiler.get_execution_mode_argument(spv::ExecutionModeOutputVertices));
        }

        // TES: primitive mode
        if (bitset.get(spv::ExecutionModeTriangles))
            modes.genMode = GL_TRIANGLES;
        else if (bitset.get(spv::ExecutionModeQuads))
            modes.genMode = GL_QUADS;
        else if (bitset.get(spv::ExecutionModeIsolines))
            modes.genMode = GL_ISOLINES;

        // TES: spacing
        if (bitset.get(spv::ExecutionModeSpacingEqual))
            modes.genSpacing = GL_EQUAL;
        else if (bitset.get(spv::ExecutionModeSpacingFractionalEven))
            modes.genSpacing = GL_FRACTIONAL_EVEN;
        else if (bitset.get(spv::ExecutionModeSpacingFractionalOdd))
            modes.genSpacing = GL_FRACTIONAL_ODD;

        // TES: vertex ordering
        if (bitset.get(spv::ExecutionModeVertexOrderCw))
            modes.genVertexOrder = GL_CW;
        else
            modes.genVertexOrder = GL_CCW;

        // TES: point mode
        modes.pointMode = bitset.get(spv::ExecutionModePointMode);
    } catch (...) {}
    return modes;
}

// Phase 6 [metal-tess-TF]: reflect the TES output struct layout under
// the same SPIRV-Cross options that the TES-as-compute MSL translation
// uses. Returns member names + byte offsets so the transform-feedback
// writer can locate each GL-declared TF varying by name in the emitted
// `main0_out` struct and copy the per-vertex bytes to the bound TF
// buffer.
//
// As of `6feb2fa` (third_party: SPIRV-Cross MSL introspection helper),
// SPIRV-Cross exposes `CompilerMSL::get_msl_interface_layout(...)`
// returning the canonical member list that the compiler actually emits.
// This replaces the hand-rolled reconstruction (~225 lines previously)
// with a direct query — eliminates the whole class of "AppGL mirrors
// SPIRV-Cross logic and silently decays as patches evolve" bugs that
// surfaced in T4C as the 32B-per-vertex stride drift on
// data_pass_through-class shapes.
StageOutputLayout ShaderTranslator::reflectStageOutputLayout(
    const std::uint32_t* spirv, std::size_t wordCount,
    const TranslatorOptions& options) const
{
    StageOutputLayout out;
    if (spirv == nullptr || wordCount < 5) return out;
    try {
        spirv_cross::CompilerMSL compiler(spirv, wordCount);
        applySpirvModuleOptions(compiler, options);
        // Mirror the MSL options the TES-as-compute translation uses,
        // so the helper reports the exact layout the kernel writes.
        spirv_cross::CompilerMSL::Options mslOpts = compiler.get_msl_options();
        mslOpts.set_msl_version(2, 2);
        const auto execModel = compiler.get_execution_model();
        const bool isTessEval = (execModel == spv::ExecutionModelTessellationEvaluation);
        const bool isVertex = (execModel == spv::ExecutionModelVertex);
        if (options.forceTessellation && isTessEval) {
            mslOpts.raw_buffer_tese_input = true;
            mslOpts.tess_domain_origin_lower_left = true;
        }
        if (options.forceTessEvalAsCompute && isTessEval) {
            mslOpts.tess_evaluation_as_compute = true;
            mslOpts.capture_output_to_buffer = true;
        }
        // Sprint 15 Q3-Option-B Phase 2 [metal-tf-vs]: mirror the
        // VS-as-compute MSL options here so the reflected output
        // struct layout matches the kernel-emitted output buffer's
        // per-vertex stride byte-for-byte. Without this gate, an
        // identical SPIR-V would be reflected as a conventional
        // `vertex` MSL output (returned struct) which can have
        // different padding from the `kernel` form (capture-to-
        // buffer struct), and the per-varying byte-offsets we
        // resolve at link time would not match the runtime layout.
        if (options.forceVertexForTessellation && isVertex) {
            mslOpts.vertex_for_tessellation = true;
            mslOpts.capture_output_to_buffer = true;
        }
        compiler.set_msl_options(mslOpts);
        // Compile to materialize the emitted struct in SPIRV-Cross's
        // internals. We discard the text — only the post-compile
        // reflection state matters.
        (void)compiler.compile();

        // Single-call query for the actual emitted main0_out layout.
        // SPIRV-Cross knows what it wrote; we mirror, not re-derive.
        const spirv_cross::MSLInterfaceLayout layout =
            compiler.get_msl_interface_layout(spv::StorageClassOutput, /*patch=*/false);
        if (layout.members.empty()) return out;

        // Translate MSLInterfaceMember → StageOutputLayout::Member.
        // The helper provides MSL-padded offset/size; we additionally
        // compute glPackedBytes (tight GL packing: vec3=12B, no pad)
        // for the TF writer's GL-side buffer copy.
        out.members.reserve(layout.members.size());
        for (const auto& m : layout.members) {
            StageOutputLayout::Member dst;
            dst.name = m.name;
            dst.offset = m.offset;
            dst.size = m.size;
            dst.isBuiltIn = m.is_builtin;
            dst.builtIn = static_cast<std::uint32_t>(m.builtin);
            // GL-tight byte size: scalar * vecsize * columns * max(array_size, 1).
            // (vec3 in MSL is padded to 16 bytes; in GL TF it's 12.)
            const std::size_t scalarBytes = (m.bit_width + 7) / 8;
            const std::size_t vec = m.vecsize > 0 ? m.vecsize : 1;
            const std::size_t cols = m.columns > 0 ? m.columns : 1;
            const std::size_t arr = m.array_size > 0 ? m.array_size : 1;
            dst.glPackedBytes = scalarBytes * vec * cols * arr;
            switch (m.base_type) {
                case spirv_cross::SPIRType::Boolean:
                case spirv_cross::SPIRType::SByte:
                case spirv_cross::SPIRType::Short:
                case spirv_cross::SPIRType::Int:
                case spirv_cross::SPIRType::Int64:
                    dst.baseType = 1;
                    break;
                case spirv_cross::SPIRType::UByte:
                case spirv_cross::SPIRType::UShort:
                case spirv_cross::SPIRType::UInt:
                case spirv_cross::SPIRType::UInt64:
                    dst.baseType = 2;
                    break;
                default:
                    dst.baseType = 0;
                    break;
            }
            out.members.push_back(std::move(dst));
        }
        out.structSize = layout.struct_size;

        if (std::getenv("APPGL_TRACE_TESS")) {
            std::fprintf(stderr,
                "[APPGL] reflectStageOutputLayout: structSize=%zu members=%zu (helper)\n",
                out.structSize, out.members.size());
            for (const auto& m : out.members) {
                std::fprintf(stderr,
                    "[APPGL]   member '%s' offset=%zu size=%zu baseType=%u builtin=%d\n",
                    m.name.c_str(), m.offset, m.size,
                    static_cast<unsigned>(m.baseType),
                    m.isBuiltIn ? (int)m.builtIn : -1);
            }
        }
    } catch (const std::exception&) {
        out = {};
    } catch (...) {
        out = {};
    }
    return out;
}

}  // namespace appgl

#else  // !APPGL_HAS_SHADER_COMPILER

namespace appgl {

std::vector<std::uint32_t> ShaderTranslator::compileGLSL(std::string_view source, GLenum stage, int version, std::string* log) const {
    (void)source;
    (void)stage;
    (void)version;
    if (log != nullptr) {
        *log = "Shader translator dependencies are vendored; GLSL compilation is not enabled in the bootstrap build yet.";
    }
    return {};
}

std::vector<std::uint32_t> ShaderTranslator::compileGLSLStageProgram(
    const std::vector<std::string>& sources, GLenum stage, int version,
    std::string* log) const {
    (void)sources;
    (void)stage;
    (void)version;
    if (log != nullptr) {
        *log = "Same-stage GLSL linking is not enabled in the bootstrap build yet.";
    }
    return {};
}

std::string ShaderTranslator::spirvToMSL(const std::uint32_t* spirv, std::size_t wordCount, const BindingMap& bindings, std::string* log) const {
    (void)spirv;
    (void)wordCount;
    (void)bindings;
    if (log != nullptr) {
        *log = "SPIR-V to MSL translation is not enabled in the bootstrap build yet.";
    }
    return {};
}

LinkedProgramSpirv ShaderTranslator::compileGLSLProgram(
    std::string_view vertexSource, std::string_view fragmentSource,
    int version, std::string* log) const {
    (void)vertexSource;
    (void)fragmentSource;
    (void)version;
    if (log != nullptr) {
        *log = "Cross-stage GLSL link is not enabled in the bootstrap build yet.";
    }
    return {};
}

ShaderReflection ShaderTranslator::reflect(const std::uint32_t* spirv, std::size_t wordCount, const BindingMap& bindings, std::string* log) const {
    return reflect(spirv, wordCount, bindings, log, TranslatorOptions{});
}

ShaderReflection ShaderTranslator::reflect(const std::uint32_t* spirv, std::size_t wordCount, const BindingMap& bindings, std::string* log, const TranslatorOptions&) const {
    (void)spirv;
    (void)wordCount;
    (void)bindings;
    if (log != nullptr) {
        *log = "Shader reflection is not enabled in the bootstrap build yet.";
    }
    return {};
}

StageOutputLayout ShaderTranslator::reflectStageOutputLayout(
    const std::uint32_t*, std::size_t, const TranslatorOptions&) const
{
    return {};
}

TessellationModes extractTessellationModes(const std::uint32_t*, std::size_t) {
    return {};
}

ComputeExecutionModes extractComputeModes(const std::uint32_t*, std::size_t) {
    return {};
}

}  // namespace appgl

#endif  // APPGL_HAS_SHADER_COMPILER
