cmake_minimum_required(VERSION 3.28)

# Pin the macOS deployment target so both AppGL and its vendored shader
# translator dependencies (glslang, SPIRV-Cross) produce object files
# targeting the same platform version that the consuming Xcode projects
# (ogl-46-mac framework and ogl-test-application) link against. Without
# this pin, CMake defaults to the host OS's current SDK version, which
# causes "built for newer macOS version than being linked" warnings for
# every translation unit in the static libs when those `.a` files are
# pulled into the 14.0-targeted Xcode framework build.
#
# Set BEFORE `project()` so it propagates to every sub-project registered
# via add_subdirectory (including third_party/glslang and SPIRV-Cross).
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "Minimum macOS deployment target")

project(AppGL LANGUAGES C CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(Python3 COMPONENTS Interpreter REQUIRED)

option(APPGL_REGENERATE "Regenerate AppGL generated files at configure time." OFF)
option(APPGL_VENDOR_THIRD_PARTY "Add vendored shader translator dependencies to the CMake graph." OFF)
option(APPGL_FP64_EMULATION
  "Enable the Decision F df64 emulation module substrate. Extension advertising remains gated by runtime validation."
  OFF)
option(APPGL_ENABLE_ASAN
  "Build with AddressSanitizer for development/debugging. DO NOT ship."
  OFF)
option(APPGL_DCR_SENTINEL_HOOKS
  "Compile DCR red-stub sentinel hooks for test harnesses. DO NOT ship."
  OFF)
option(APPGL_LOG_ALL "Compile all AppGL structured logging channels." OFF)
option(APPGL_LOG_DRAW "Compile AppGL draw-channel structured logging." OFF)
option(APPGL_LOG_SHADER "Compile AppGL shader-channel structured logging." OFF)
option(APPGL_LOG_TEXTURE "Compile AppGL texture-channel structured logging." OFF)
option(APPGL_LOG_BUFFER "Compile AppGL buffer-channel structured logging." OFF)
option(APPGL_LOG_PIPELINE "Compile AppGL pipeline-channel structured logging." OFF)

# AddressSanitizer flags applied globally when APPGL_ENABLE_ASAN is on.
# Apple's clang accepts `-fsanitize=address` for both compile and link.
# `-fno-omit-frame-pointer` keeps the leaf frame visible in ASAN reports.
# We drop `-O*` overrides to `-O1` so the report line numbers stay
# faithful while performance remains workable for CTS runs.
#
# Usage: `cmake -S . -B build -DAPPGL_ENABLE_ASAN=ON && cmake --build build`
# Runtime: `ASAN_OPTIONS="detect_leaks=0:abort_on_error=1" ./glcts ...`
#
# CTS suites are fork-bombed from glcts — use `abort_on_error=1` so the
# first heap-corruption report aborts the process at the failure site
# with a full backtrace, instead of sprays from subsequent corruption
# cascading through test teardown.
if(APPGL_ENABLE_ASAN)
  message(STATUS "AppGL: AddressSanitizer ENABLED (dev build)")
  add_compile_options(-fsanitize=address -fno-omit-frame-pointer -g -O1)
  add_link_options(-fsanitize=address)
endif()

set(APPGL_GENERATOR "${CMAKE_CURRENT_SOURCE_DIR}/tools/gen_from_registry/generate_from_registry.py")

if(APPGL_REGENERATE)
  execute_process(
    COMMAND "${Python3_EXECUTABLE}" "${APPGL_GENERATOR}"
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    COMMAND_ERROR_IS_FATAL ANY
  )
endif()

add_custom_target(appgl-codegen
  COMMAND "${Python3_EXECUTABLE}" "${APPGL_GENERATOR}"
  WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
  COMMENT "Regenerating AppGL generated files"
)

set(APPGL_SOURCES
  src/runtime/AppGLRuntime.cpp
  src/runtime/AppGLGroup8.cpp
  src/runtime/AppGLFeatureFlags.mm
  src/runtime/AppGLMatrixOverrides.cpp
  src/runtime/AppGLImmediateMode.cpp
  src/caps/GLCapabilities.mm
  src/context/GLContext.mm
  src/context/MetalFrameGraph.mm
  src/extensions/ExtensionContext.mm
  src/extensions/ExtensionRegistry.mm
  src/extensions/fp64/Fp64Extension.mm
  src/extensions/fp64/Fp64Module.mm
  src/extensions/fp64/Fp64StateBinding.mm
  src/extensions/fp64/Fp64Translation.mm
  src/extensions/fragment_shading_rate/FragmentShadingRateExtension.mm
  src/extensions/fragment_shading_rate/FragmentShadingRateModule.mm
  src/extensions/fragment_shading_rate/RasterizationRateMap.mm
  src/extensions/sparse_texture/MultisampleStorageImageEmulation.mm
  src/extensions/sparse_texture/SparseStorageImageEmulation.mm
  src/extensions/sparse_texture/SparseTextureAlloc.mm
  src/extensions/sparse_texture/SparseTextureBind.mm
  src/extensions/sparse_texture/SparseTextureExtension.mm
  src/extensions/sparse_texture/SparseTextureModule.mm
  src/debug/CoverageStore.cpp
  src/debug/TraceLog.cpp
  src/loader/DispatchInstall.cpp
  src/objects/GLObjectStore.cpp
  src/shader/CompatShaderRewrite.cpp
  src/shader/GeometryShaderEmulator.cpp
  src/shader/GLSLReflection.cpp
  src/shader/PipelineCache.cpp
  src/shader/ShaderInterpreter.cpp
  src/shader/ShaderTranslator.cpp
  src/shader/TessellationEmulator.cpp
  src/state/GLStateTracker.cpp
  src/state/IndexExpansion.cpp
  src/state/MatrixStateMirror.cpp
  src/state/MetalVertexDescriptorBuilder.mm
  src/generated/gl_entrypoints.gen.cpp
  src/generated/gl_procaddress.gen.cpp
  src/generated/gl_aliases.gen.cpp
  src/generated/gl_fixed_function.gen.cpp
)

set(APPGL_TEST_SUPPORT_SOURCES
  tests/GoldenCompare.cpp
  tests/GauntletRunner.cpp
  tests/LivePresentSentinel.mm
)

set(APPGL_PUBLIC_HEADERS
  include/AppGL/AppGL.h
  include/AppGL/extensions/ExtensionRegistry.h
  include/AppGL/extensions/fp64.h
  include/AppGL/extensions/fragment_shading_rate.h
  include/AppGL/extensions/sparse_texture.h
  include/AppGL/glcorearb.h
  include/AppGL/khrplatform.h
)

add_library(AppGLTestsSupport OBJECT ${APPGL_TEST_SUPPORT_SOURCES})

add_library(AppGL SHARED ${APPGL_SOURCES} ${APPGL_PUBLIC_HEADERS})
add_library(AppGL_static STATIC ${APPGL_SOURCES} ${APPGL_PUBLIC_HEADERS})

add_dependencies(AppGL appgl-codegen)
add_dependencies(AppGL_static appgl-codegen)
add_dependencies(AppGLTestsSupport appgl-codegen)

set_target_properties(AppGL PROPERTIES
  OUTPUT_NAME AppGL
  PUBLIC_HEADER "${APPGL_PUBLIC_HEADERS}"
)

set_target_properties(AppGL_static PROPERTIES
  OUTPUT_NAME AppGL
)

target_include_directories(AppGL
  PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
  PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
    "${CMAKE_CURRENT_SOURCE_DIR}/tests"
)

target_include_directories(AppGL_static
  PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
  PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
    "${CMAKE_CURRENT_SOURCE_DIR}/tests"
)

target_include_directories(AppGLTestsSupport
  PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
  PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
    "${CMAKE_CURRENT_SOURCE_DIR}/tests"
)

target_sources(AppGL PRIVATE $<TARGET_OBJECTS:AppGLTestsSupport>)
target_sources(AppGL_static PRIVATE $<TARGET_OBJECTS:AppGLTestsSupport>)

foreach(target AppGL AppGL_static AppGLTestsSupport)
  target_compile_definitions(${target} PRIVATE
    GL_SILENCE_DEPRECATION=1
    APPGL_FP64_EMULATION=$<IF:$<BOOL:${APPGL_FP64_EMULATION}>,1,0>
    APPGL_ENABLE_DCR_SENTINEL_HOOKS=$<IF:$<BOOL:${APPGL_DCR_SENTINEL_HOOKS}>,1,0>
    $<$<BOOL:${APPGL_LOG_ALL}>:APPGL_LOG_ALL=1>
    $<$<BOOL:${APPGL_LOG_DRAW}>:APPGL_LOG_DRAW=1>
    $<$<BOOL:${APPGL_LOG_SHADER}>:APPGL_LOG_SHADER=1>
    $<$<BOOL:${APPGL_LOG_TEXTURE}>:APPGL_LOG_TEXTURE=1>
    $<$<BOOL:${APPGL_LOG_BUFFER}>:APPGL_LOG_BUFFER=1>
    $<$<BOOL:${APPGL_LOG_PIPELINE}>:APPGL_LOG_PIPELINE=1>
  )
endforeach()

foreach(target AppGL AppGL_static)
  target_link_libraries(${target}
    PRIVATE
      "-framework Foundation"
      "-framework AppKit"
      "-framework QuartzCore"
      "-framework Metal"
  )
endforeach()

add_executable(appgl_gauntlet_cli tests/HeadlessGauntletMain.cpp)
add_dependencies(appgl_gauntlet_cli appgl-codegen)
target_include_directories(appgl_gauntlet_cli
  PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
    "${CMAKE_CURRENT_SOURCE_DIR}/tests"
)
target_compile_definitions(appgl_gauntlet_cli PRIVATE GL_SILENCE_DEPRECATION=1)
target_link_libraries(appgl_gauntlet_cli PRIVATE AppGL_static)

# Standalone ASAN reproducer for the SpirvModule heap-corruption bug
# (session-12 gl_in_array_length SIGSEGV). dlopens the shared dylib
# rather than static-linking so the DYLD_LIBRARY_PATH / ASAN-build
# wiring matches how real apps load the runtime. Only useful when
# APPGL_ENABLE_ASAN is on — otherwise the release dylib runs the
# shader without ever surfacing the corruption.
add_executable(asan_repro tests/asan_repro_gl_in_array_length.cpp)
target_include_directories(asan_repro
  PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
)
target_link_libraries(asan_repro PRIVATE "-ldl")

# DCR3 bar-b differential harness. It intentionally dlopens libAppGL.dylib
# and uses only the public loader surface so the same benchmark binary can
# be run against current and historical runtime dylibs.
add_executable(appgl_bar_b_benchmark tests/BarBBenchmarkMain.cpp)
target_include_directories(appgl_bar_b_benchmark
  PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
)
target_compile_definitions(appgl_bar_b_benchmark PRIVATE GL_SILENCE_DEPRECATION=1)
target_link_libraries(appgl_bar_b_benchmark PRIVATE "-ldl")

add_executable(appgl_feature_flags_probe tests/FeatureFlagsProbe.cpp)
add_dependencies(appgl_feature_flags_probe appgl-codegen)
target_include_directories(appgl_feature_flags_probe
  PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
)
target_compile_definitions(appgl_feature_flags_probe PRIVATE GL_SILENCE_DEPRECATION=1)
target_link_libraries(appgl_feature_flags_probe PRIVATE AppGL_static)

if(APPGL_VENDOR_THIRD_PARTY)
  set(BUILD_EXTERNAL OFF CACHE BOOL "" FORCE)
  set(ENABLE_GLSLANG_BINARIES OFF CACHE BOOL "" FORCE)
  set(ENABLE_GLSLANG_JS OFF CACHE BOOL "" FORCE)
  set(ENABLE_OPT OFF CACHE BOOL "" FORCE)
  set(GLSLANG_ENABLE_INSTALL OFF CACHE BOOL "" FORCE)
  set(GLSLANG_TESTS OFF CACHE BOOL "" FORCE)

  set(SPIRV_CROSS_CLI OFF CACHE BOOL "" FORCE)
  set(SPIRV_CROSS_ENABLE_TESTS OFF CACHE BOOL "" FORCE)
  set(SPIRV_CROSS_SKIP_INSTALL ON CACHE BOOL "" FORCE)

  add_subdirectory(third_party/glslang EXCLUDE_FROM_ALL)
  add_subdirectory(third_party/SPIRV-Cross EXCLUDE_FROM_ALL)

  foreach(target AppGL AppGL_static)
    target_compile_definitions(${target} PRIVATE APPGL_HAS_SHADER_COMPILER=1)
    target_link_libraries(${target} PRIVATE
      glslang
      glslang-default-resource-limits
      SPIRV
      spirv-cross-core
      spirv-cross-glsl
      spirv-cross-msl
    )
  endforeach()
endif()
