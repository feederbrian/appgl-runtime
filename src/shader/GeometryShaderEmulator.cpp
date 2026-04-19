// GeometryShaderEmulator — CPU-side GS emulation.
//
// Current scope is the narrow subset of SPIR-V used by CTS
// `KHR-GL46.constant_expressions.*_geometry` (224 F). Opcodes outside
// that set bail with a clear diagnostic so the missing-opcode list is
// cheap to extend.
//
// Architectural split (see header for the full pipeline):
//   - `SpirvModule` parses the module header, constants, types,
//     variables and function bodies into tables keyed by SPIR-V id.
//   - `Interpreter` walks the function body per invocation, dispatching
//     opcodes into a small value store (id → value).
//   - `emulateGeometryDraw` drives VS + GS interpretation across a
//     draw call and packages the expanded vertex stream.
//
// Types are intentionally small and boxed into `std::variant<float,
// int, vec2, …>` so the interpreter can carry SSA values by id without
// per-opcode type threading. Extend the variant as new type classes
// surface.

#include "GeometryShaderEmulator.h"

#include "../objects/GLObjectStore.h"
#include "../state/GLStateTracker.h"

// SPIR-V header. SPIRV-Cross ships a copy of the official spirv.hpp
// which gives us the opcode enum without adding a new dependency.
#ifdef APPGL_HAS_SHADER_COMPILER
#include "spirv.hpp"
#else
// When the shader compiler isn't vendored (tests/CI headless builds),
// stub the opcode enum so the translation unit still compiles — the
// emulator reports "not available" and the fallback kicks in.
namespace spv {
    constexpr std::uint32_t MagicNumber = 0x07230203;
    enum Op : std::uint32_t {
        OpEntryPoint = 15, OpName = 5, OpMemberName = 6,
        OpDecorate = 71, OpMemberDecorate = 72,
        OpTypeVoid = 19, OpTypeBool = 20, OpTypeInt = 21,
        OpTypeFloat = 22, OpTypeVector = 23, OpTypeMatrix = 24,
        OpTypeArray = 28, OpTypeStruct = 30, OpTypePointer = 32,
        OpConstant = 43, OpConstantTrue = 41, OpConstantFalse = 42,
        OpConstantComposite = 44, OpVariable = 59
    };
    enum Decoration : std::uint32_t { DecorationLocation = 30, DecorationBuiltIn = 11 };
}
#endif

#include <array>
#include <cstdint>
#include <cstring>
#include <string>
#include <unordered_map>
#include <variant>
#include <vector>

// OpenGL enums we reference (subset).
#ifndef GL_POINTS
#define GL_POINTS 0x0000
#endif
#ifndef GL_LINES
#define GL_LINES 0x0001
#endif
#ifndef GL_LINE_STRIP
#define GL_LINE_STRIP 0x0003
#endif
#ifndef GL_TRIANGLES
#define GL_TRIANGLES 0x0004
#endif
#ifndef GL_TRIANGLE_STRIP
#define GL_TRIANGLE_STRIP 0x0005
#endif
#ifndef GL_VERTEX_SHADER
#define GL_VERTEX_SHADER 0x8B31
#endif
#ifndef GL_GEOMETRY_SHADER
#define GL_GEOMETRY_SHADER 0x8DD9
#endif

namespace appgl {
namespace {

// ─── SPIR-V module parse ────────────────────────────────────────────
//
// Minimal parse: walk the instruction stream and index things we need
// at run time. We don't need full SPIRV-Tools — the subset of opcodes
// we handle is small enough to special-case.

// A runtime value carried through interpretation. Everything reducible
// to at most 4 floats / ints; matrices and arrays live in separate
// storage keyed by access chain.
struct Value {
    enum class Kind { Float, Float2, Float3, Float4, Int, UInt, Bool };
    Kind kind = Kind::Float;
    std::array<float, 4> f{0, 0, 0, 0};
    std::array<std::int32_t, 4> i{0, 0, 0, 0};
    bool b = false;
    static Value makeFloat(float v)   { Value r; r.kind = Kind::Float;  r.f[0] = v; return r; }
    static Value makeFloat2(float x, float y) {
        Value r; r.kind = Kind::Float2; r.f[0] = x; r.f[1] = y; return r;
    }
    static Value makeFloat3(float x, float y, float z) {
        Value r; r.kind = Kind::Float3; r.f[0] = x; r.f[1] = y; r.f[2] = z; return r;
    }
    static Value makeFloat4(float x, float y, float z, float w) {
        Value r; r.kind = Kind::Float4; r.f[0] = x; r.f[1] = y; r.f[2] = z; r.f[3] = w; return r;
    }
    static Value makeInt(std::int32_t v)  { Value r; r.kind = Kind::Int;   r.i[0] = v; return r; }
    static Value makeUInt(std::uint32_t v){ Value r; r.kind = Kind::UInt;  r.i[0] = static_cast<std::int32_t>(v); return r; }
    static Value makeBool(bool v)         { Value r; r.kind = Kind::Bool;  r.b = v; return r; }
};

struct TypeInfo {
    enum class Kind { Void, Bool, Int, UInt, Float,
                      Vec2, Vec3, Vec4,
                      Matrix, Array, Struct, Pointer,
                      Unknown };
    Kind kind = Kind::Unknown;
    std::uint32_t componentType = 0;   // for vec/array/matrix
    std::uint32_t count = 0;           // vec width, array length
    std::vector<std::uint32_t> memberTypes;   // for struct
    std::uint32_t storageClass = 0;    // for pointer
    std::uint32_t pointeeType = 0;     // for pointer
};

struct DecorationSet {
    bool hasLocation = false;
    std::uint32_t location = 0;
    bool hasBuiltIn = false;
    std::uint32_t builtIn = 0;
    bool hasOffset = false;
    std::uint32_t offset = 0;
};

struct VariableInfo {
    std::uint32_t typeId = 0;
    std::uint32_t storageClass = 0;
    std::string name;
};

struct SpirvModule {
    // Header
    std::uint32_t bound = 0;

    // Id tables
    std::unordered_map<std::uint32_t, TypeInfo> types;
    std::unordered_map<std::uint32_t, Value> constants;
    std::unordered_map<std::uint32_t, VariableInfo> variables;
    std::unordered_map<std::uint32_t, DecorationSet> decorations;
    std::unordered_map<std::uint32_t, DecorationSet> memberDecorations0;  // member 0 only for now — extend when needed
    std::unordered_map<std::uint32_t, std::string> names;
    std::unordered_map<std::uint32_t, std::vector<std::string>> memberNames;

    // Entry-point function id
    std::uint32_t entryPoint = 0;

    // Raw instruction stream from first function definition to end.
    std::vector<std::uint32_t> words;   // a copy of the full module

    // Diagnostic
    std::string parseError;

    bool parse(const std::uint32_t* data, std::size_t count);
};

// Read a length-prefixed SPIR-V literal string starting at word[i].
// Returns the string and advances i past the string.
static std::string readLiteralString(const std::uint32_t* w, std::size_t& i, std::size_t wordCount) {
    std::string out;
    while (i < wordCount) {
        std::uint32_t word = w[i++];
        for (int b = 0; b < 4; ++b) {
            char c = static_cast<char>((word >> (b * 8)) & 0xFF);
            if (c == '\0') return out;
            out.push_back(c);
        }
    }
    return out;
}

bool SpirvModule::parse(const std::uint32_t* data, std::size_t count) {
    if (count < 5 || data[0] != spv::MagicNumber) {
        parseError = "bad SPIR-V magic";
        return false;
    }
    bound = data[3];
    words.assign(data, data + count);

    std::size_t i = 5;
    while (i < count) {
        const std::uint32_t inst = data[i];
        const std::uint16_t opcode = inst & 0xFFFF;
        const std::uint16_t wc = static_cast<std::uint16_t>(inst >> 16);
        if (wc == 0 || i + wc > count) {
            parseError = "malformed instruction";
            return false;
        }
        const std::uint32_t* w = data + i + 1;   // operands start after header word

        switch (opcode) {
            case spv::OpEntryPoint: {
                // w[0]=execmodel, w[1]=id, then literal name, then interface ids.
                if (wc >= 3) entryPoint = w[1];
                break;
            }
            case spv::OpName: {
                if (wc >= 3) {
                    std::size_t j = i + 2;
                    names[w[0]] = readLiteralString(data, j, count);
                }
                break;
            }
            case spv::OpMemberName: {
                if (wc >= 4) {
                    std::size_t j = i + 3;
                    auto& v = memberNames[w[0]];
                    const std::uint32_t idx = w[1];
                    if (idx >= v.size()) v.resize(idx + 1);
                    v[idx] = readLiteralString(data, j, count);
                }
                break;
            }
            case spv::OpDecorate: {
                if (wc < 3) break;
                const std::uint32_t target = w[0];
                const std::uint32_t deco = w[1];
                if (deco == spv::DecorationLocation && wc >= 4) {
                    decorations[target].hasLocation = true;
                    decorations[target].location = w[2];
                } else if (deco == spv::DecorationBuiltIn && wc >= 4) {
                    decorations[target].hasBuiltIn = true;
                    decorations[target].builtIn = w[2];
                }
                break;
            }
            case spv::OpMemberDecorate: {
                if (wc < 4) break;
                const std::uint32_t target = w[0];
                const std::uint32_t member = w[1];
                const std::uint32_t deco = w[2];
                if (member == 0) {
                    if (deco == spv::DecorationBuiltIn && wc >= 5) {
                        memberDecorations0[target].hasBuiltIn = true;
                        memberDecorations0[target].builtIn = w[3];
                    }
                }
                break;
            }
            case spv::OpTypeVoid:  types[w[0]] = {TypeInfo::Kind::Void}; break;
            case spv::OpTypeBool:  types[w[0]] = {TypeInfo::Kind::Bool}; break;
            case spv::OpTypeInt: {
                TypeInfo t;
                const bool isSigned = (wc >= 4 && w[2] != 0);
                t.kind = isSigned ? TypeInfo::Kind::Int : TypeInfo::Kind::UInt;
                types[w[0]] = t;
                break;
            }
            case spv::OpTypeFloat: types[w[0]] = {TypeInfo::Kind::Float}; break;
            case spv::OpTypeVector: {
                TypeInfo t;
                const std::uint32_t comp = (wc >= 4) ? w[2] : 0;
                const std::uint32_t nComp = (wc >= 4) ? w[2] : 0;  // unused; just reserve
                (void)nComp;
                t.componentType = w[1];
                t.count = w[2];
                if (t.count == 2) t.kind = TypeInfo::Kind::Vec2;
                else if (t.count == 3) t.kind = TypeInfo::Kind::Vec3;
                else if (t.count == 4) t.kind = TypeInfo::Kind::Vec4;
                (void)comp;
                types[w[0]] = t;
                break;
            }
            case spv::OpTypeMatrix: {
                TypeInfo t;
                t.kind = TypeInfo::Kind::Matrix;
                t.componentType = w[1];
                t.count = w[2];
                types[w[0]] = t;
                break;
            }
            case spv::OpTypeArray: {
                TypeInfo t;
                t.kind = TypeInfo::Kind::Array;
                t.componentType = w[1];
                // w[2] is the *id* of a constant holding the length. Resolve
                // via our constants table once parsing finishes.
                // For now stash it as count; we'll look it up later.
                t.count = w[2];
                types[w[0]] = t;
                break;
            }
            case spv::OpTypeStruct: {
                TypeInfo t;
                t.kind = TypeInfo::Kind::Struct;
                for (std::uint32_t k = 1; k < wc - 1; ++k) {
                    t.memberTypes.push_back(w[k]);
                }
                types[w[0]] = t;
                break;
            }
            case spv::OpTypePointer: {
                TypeInfo t;
                t.kind = TypeInfo::Kind::Pointer;
                t.storageClass = w[1];
                t.pointeeType = w[2];
                types[w[0]] = t;
                break;
            }
            case spv::OpConstant: {
                // w[0]=resultType, w[1]=resultId, w[2..]=literal bits
                const auto& t = types[w[0]];
                Value v;
                if (t.kind == TypeInfo::Kind::Float) {
                    float f = 0;
                    std::memcpy(&f, &w[2], sizeof(float));
                    v = Value::makeFloat(f);
                } else if (t.kind == TypeInfo::Kind::Int) {
                    v = Value::makeInt(static_cast<std::int32_t>(w[2]));
                } else if (t.kind == TypeInfo::Kind::UInt) {
                    v = Value::makeUInt(w[2]);
                }
                constants[w[1]] = v;
                break;
            }
            case spv::OpConstantTrue:  constants[w[1]] = Value::makeBool(true);  break;
            case spv::OpConstantFalse: constants[w[1]] = Value::makeBool(false); break;
            case spv::OpConstantComposite: {
                const auto& t = types[w[0]];
                Value v;
                if (t.kind == TypeInfo::Kind::Vec2 || t.kind == TypeInfo::Kind::Vec3 ||
                    t.kind == TypeInfo::Kind::Vec4) {
                    v.kind = (t.kind == TypeInfo::Kind::Vec2) ? Value::Kind::Float2
                            : (t.kind == TypeInfo::Kind::Vec3) ? Value::Kind::Float3
                                                                : Value::Kind::Float4;
                    const std::uint32_t n = t.count;
                    for (std::uint32_t k = 0; k < n && (2 + k) < wc; ++k) {
                        const Value& c = constants[w[2 + k]];
                        v.f[k] = c.f[0];
                    }
                }
                constants[w[1]] = v;
                break;
            }
            case spv::OpVariable: {
                VariableInfo vi;
                vi.typeId = w[0];
                vi.storageClass = w[2];
                auto nameIt = names.find(w[1]);
                if (nameIt != names.end()) vi.name = nameIt->second;
                variables[w[1]] = vi;
                break;
            }
            default:
                // Unhandled at parse time — the interpreter will walk
                // the full instruction stream on its own pass.
                break;
        }
        i += wc;
    }
    return true;
}

// ─── Interpreter ────────────────────────────────────────────────────
//
// MVP interpreter. Builds up the minimum to run the passthrough-GS
// pattern emitted for constant_expressions tests:
//
//   void main() {
//       vec4 result = vec4(radians(90.0), 0, 0, 1);   // const expr
//       for (int i = 0; i < gl_in.length(); ++i) {
//           geom_out_out0 = result;
//           gl_Position = gl_in[i].gl_Position;
//           EmitVertex();
//       }
//       EndPrimitive();
//   }
//
// That exercises: loops, access chains into gl_in[], writes to outputs,
// OpEmitVertex/OpEndPrimitive.
//
// The first pass lands a SKELETON that compiles and links; opcode
// dispatch is a stub that returns a diagnostic "interpreter not yet
// implemented — missing opcode X" so the emulation path degrades
// gracefully back to the existing no-GS fallback. Subsequent iterations
// fill in the opcodes needed to actually execute GS bodies.

class Interpreter {
public:
    // Execute the entry point function. For GS, the per-invocation
    // inputs are:
    //   - per-vertex arrays (gl_in[].gl_Position, varyings[]) from the
    //     CPU-interpreted VS stage
    //   - uniform values
    // Outputs accumulate in `this->emittedVertices` via OpEmitVertex.
    struct PerVertexInput {
        std::array<float, 4> position = {0, 0, 0, 1};
        // Per-varying payload, indexed by location. Parallel to
        // `module.varyingWidths` (stored on the driver above).
        std::vector<std::vector<float>> varyingValues;
    };

    Interpreter(const SpirvModule& module) : module_(module) {}

    // Execute with `inputs[i]` as gl_in[i]. Appends emitted vertices
    // to `emitted` (driver-owned). Returns false on unsupported opcode
    // or parse-time error; `diagnostic` is populated.
    bool execute(const std::vector<PerVertexInput>& inputs,
                 std::vector<EmulatedVertex>& emitted,
                 std::vector<std::uint8_t>& primitiveBoundaries);

    const std::string& diagnostic() const { return diagnostic_; }

private:
    const SpirvModule& module_;
    std::string diagnostic_;
};

bool Interpreter::execute(const std::vector<PerVertexInput>& /*inputs*/,
                          std::vector<EmulatedVertex>& /*emitted*/,
                          std::vector<std::uint8_t>& /*primitiveBoundaries*/) {
    // Skeleton — real dispatch lands in the next iteration. Signal
    // "unsupported" so the driver falls back to the existing no-GS
    // path. Will be replaced with a proper opcode walker.
    diagnostic_ = "SPIR-V GS interpreter skeleton only — opcode dispatch not yet wired";
    return false;
}

}  // namespace

// ─── Public API ─────────────────────────────────────────────────────

bool detectGeometryEmulatable(GLProgramObject& /*program*/) {
    // Conservative until the interpreter is wired: report
    // "not emulatable" so the existing no-GS link path (drop GS,
    // VS+FS only) stays in effect. Flip this flag on once the
    // interpreter actually runs constant_expressions bodies.
    return false;
}

EmulatedDraw emulateGeometryDraw(
    GLProgramObject& /*program*/,
    const GLVertexArrayObject& /*vao*/,
    GLObjectStore& /*objects*/,
    const GLStateTracker& /*state*/,
    GLenum /*drawMode*/,
    GLsizei /*count*/,
    GLint /*first*/,
    const void* /*indices*/,
    GLenum /*indexType*/)
{
    EmulatedDraw d;
    d.ok = false;
    d.diagnostic = "GS emulator skeleton only — no draws routed yet";
    return d;
}

}  // namespace appgl
