# Khronos Registry Inputs

This directory vendors the canonical inputs used to generate AppGL's public
OpenGL surface and internal manifest.

## Sources

- `gl.xml`
  - Source repository: `https://github.com/KhronosGroup/OpenGL-Registry`
  - Source path: `xml/gl.xml`
  - Source commit: `9cb90ca4902d588bef3c830fbb1da484893bd5fb`
  - SPDX marker in file header: `Apache-2.0`

- `glcorearb.h`
  - Source repository: `https://github.com/KhronosGroup/OpenGL-Registry`
  - Source path: `api/GL/glcorearb.h`
  - Source commit: `9cb90ca4902d588bef3c830fbb1da484893bd5fb`
  - SPDX marker in file header: `MIT`

- `khrplatform.h`
  - Source repository: `https://github.com/KhronosGroup/EGL-Registry`
  - Source path: `api/KHR/khrplatform.h`
  - Source commit: `3d7796b3721d93976b6bfe536aa97bbc4bce8667`
  - License text is embedded directly in the file header.

These files are vendored as read-only generator inputs.
