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


def parse_registry() -> tuple[ET.Element, list[dict[str, object]], list[dict[str, str]], list[str]]:
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

    for feature_name in SUPPORTED_FEATURES:
        feature = root.find(f"./feature[@api='gl'][@name='{feature_name}']")
        if feature is None:
            raise RuntimeError(f"Missing feature block: {feature_name}")

        for child in feature:
            profile = child.attrib.get("profile")
            if profile not in (None, "core"):
                continue
            if child.tag not in {"require", "remove"}:
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
    enums = [{"name": name, "value": value} for name, value in ordered_enums.items()]
    return root, commands, enums, list(ordered_commands.values())


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
    enums: list[dict[str, str]]
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

    root, commands, enums, _ = parse_registry()

    PUBLIC_INCLUDE_DIR.mkdir(parents=True, exist_ok=True)
    GENERATED_DIR.mkdir(parents=True, exist_ok=True)

    source_lines = SOURCE_HEADER.read_text().splitlines()
    preamble = extract_header_preamble(source_lines)
    type_block = extract_type_block(root)
    PUBLIC_HEADER.write_text(generate_public_header(preamble, type_block, commands, enums))
    shutil.copyfile(VENDOR_KHR, PUBLIC_KHR)
    ENUMS_HEADER.write_text(generate_enums_header(enums))
    FUNCTION_IDS_HEADER.write_text(generate_function_ids_header(commands))
    DISPATCH_HEADER.write_text(generate_dispatch_header(commands))
    ENTRYPOINTS_CPP.write_text(generate_entrypoints_cpp(commands))
    MANIFEST_JSON.write_text(generate_manifest(commands))

    print(f"Generated {len(commands)} OpenGL 4.6 core entry points.")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # pragma: no cover - build-time script
        print(f"error: {error}", file=sys.stderr)
        raise
