#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GENERATOR_PATH = ROOT / "tools" / "gen_from_registry" / "generate_from_registry.py"


def load_generator():
    spec = importlib.util.spec_from_file_location("appgl_registry_generator", GENERATOR_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load generator: {GENERATOR_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def report(name: str, passed: bool, detail: str = "") -> bool:
    suffix = f"\tdetail={detail}" if detail else ""
    print(f"ROW\t{name}\t{'PASS' if passed else 'FAIL'}{suffix}")
    return passed


def expected_outputs(generator) -> dict[Path, str]:
    root, commands, enums, _, aliases, fixed_function = generator.parse_registry()
    extension_commands, extension_enums = generator.extract_public_extension_surface(root)

    generated_enum_names = {entry["name"] for entry in enums}
    enums.extend(
        entry
        for entry in extension_enums
        if entry["name"] not in generated_enum_names
    )

    public_commands = list(commands)
    public_command_names = {entry["name"] for entry in public_commands}
    public_commands.extend(
        entry
        for entry in extension_commands
        if entry["name"] not in public_command_names
    )

    source_lines = generator.SOURCE_HEADER.read_text().splitlines()
    preamble = generator.extract_header_preamble(source_lines)
    type_block = generator.extract_type_block(root)
    return {
        generator.PUBLIC_HEADER: generator.generate_public_header(
            preamble,
            type_block,
            public_commands,
            enums,
            generator.PUBLIC_EXTENSION_FEATURES,
        ),
        generator.ENUMS_HEADER: generator.generate_enums_header(enums),
        generator.FUNCTION_IDS_HEADER: generator.generate_function_ids_header(commands),
        generator.DISPATCH_HEADER: generator.generate_dispatch_header(commands),
        generator.ENTRYPOINTS_CPP: generator.generate_entrypoints_cpp(commands),
        generator.ALIASES_CPP: generator.generate_aliases_cpp(aliases),
        generator.FIXED_FUNCTION_CPP: generator.generate_fixed_function_cpp(fixed_function),
        generator.PROC_ADDRESS_CPP: generator.generate_proc_address_cpp(
            commands, aliases, fixed_function
        ),
        generator.MANIFEST_JSON: generator.generate_manifest(commands),
    }


def main() -> int:
    generator = load_generator()
    failures = 0

    outputs = expected_outputs(generator)
    for path, expected in outputs.items():
        actual = path.read_text()
        failures += not report(
            f"codegen.deterministic.{path.name}",
            actual == expected,
            "matches-in-memory-generation" if actual == expected else "stale-generated-file",
        )
    public_khr_matches = generator.PUBLIC_KHR.read_bytes() == generator.VENDOR_KHR.read_bytes()
    failures += not report(
        "codegen.deterministic.khrplatform.h",
        public_khr_matches,
        "matches-vendored-source" if public_khr_matches else "stale-generated-file",
    )

    required_commands = {
        "glProgramParameteriARB": "glProgramParameteri",
        "glFramebufferTextureARB": "glFramebufferTexture",
        "glFramebufferTextureLayerARB": "glFramebufferTextureLayerARB",
        "glFramebufferTextureFaceARB": "glFramebufferTextureFaceARB",
    }
    public_header = generator.PUBLIC_HEADER.read_text()
    proc_table = generator.PROC_ADDRESS_CPP.read_text()
    dispatch_header = generator.DISPATCH_HEADER.read_text()
    aliases_source = generator.ALIASES_CPP.read_text()
    manifest = json.loads(generator.MANIFEST_JSON.read_text())
    manifest_names = {entry["name"] for entry in manifest["functions"]}

    failures += not report(
        "codegen.arb-gs4.public-extension-feature",
        "GL_ARB_geometry_shader4" in generator.PUBLIC_EXTENSION_FEATURES,
    )
    for command, dispatch_owner in sorted(required_commands.items()):
        failures += not report(
            f"codegen.arb-gs4.prototype.{command}",
            f" {command}(" in public_header,
        )
        failures += not report(
            f"codegen.arb-gs4.proc-address.{command}",
            f'"{command}"' in proc_table,
        )
        failures += not report(
            f"codegen.arb-gs4.dispatch-owner.{command}",
            dispatch_owner in dispatch_header,
        )
        failures += not report(
            f"codegen.arb-gs4.manifest-owner.{command}",
            dispatch_owner in manifest_names,
        )
        if dispatch_owner != command:
            failures += not report(
                f"codegen.arb-gs4.alias.{command}",
                f" {command}(" in aliases_source
                and f"::{dispatch_owner}(" in aliases_source,
            )

    required_tokens = {
        "GL_GEOMETRY_INPUT_TYPE_ARB": "0x8DDB",
        "GL_GEOMETRY_OUTPUT_TYPE_ARB": "0x8DDC",
        "GL_GEOMETRY_VERTICES_OUT_ARB": "0x8DDA",
        "GL_MAX_GEOMETRY_VARYING_COMPONENTS_ARB": "0x8DDD",
        "GL_MAX_VERTEX_VARYING_COMPONENTS_ARB": "0x8DDE",
    }
    enum_header = generator.ENUMS_HEADER.read_text()
    for token, value in sorted(required_tokens.items()):
        failures += not report(
            f"codegen.arb-gs4.enum.{token}",
            token in public_header
            and token in enum_header
            and value in public_header
            and value in enum_header,
        )

    status = "PASS" if failures == 0 else "FAIL"
    print(f"SUMMARY\t{status}\tfailures={failures}")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
