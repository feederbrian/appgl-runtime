cmake_minimum_required(VERSION 3.28)

project(AppGL LANGUAGES C CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(Python3 COMPONENTS Interpreter REQUIRED)

option(APPGL_REGENERATE "Regenerate AppGL generated files at configure time." OFF)
option(APPGL_VENDOR_THIRD_PARTY "Add vendored shader translator dependencies to the CMake graph." OFF)

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
  src/caps/GLCapabilities.mm
  src/context/GLContext.mm
  src/context/MetalFrameGraph.mm
  src/debug/CoverageStore.cpp
  src/debug/TraceLog.cpp
  src/loader/DispatchInstall.cpp
  src/objects/GLObjectStore.cpp
  src/shader/GLSLReflection.cpp
  src/shader/PipelineCache.cpp
  src/shader/ShaderTranslator.cpp
  src/state/GLStateTracker.cpp
  src/state/IndexExpansion.cpp
  src/state/MetalVertexDescriptorBuilder.mm
  src/generated/gl_entrypoints.gen.cpp
  src/generated/gl_procaddress.gen.cpp
  src/generated/gl_aliases.gen.cpp
  src/generated/gl_fixed_function.gen.cpp
)

set(APPGL_TEST_SUPPORT_SOURCES
  tests/GoldenCompare.cpp
  tests/GauntletRunner.cpp
)

set(APPGL_PUBLIC_HEADERS
  include/AppGL/AppGL.h
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
  target_compile_definitions(${target} PRIVATE GL_SILENCE_DEPRECATION=1)
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
