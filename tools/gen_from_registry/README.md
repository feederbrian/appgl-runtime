AppGL now generates its canonical OpenGL surface from the official Khronos
registry inputs vendored under `khronos/`.

Current source of truth:

- `khronos/gl.xml`
- `khronos/glcorearb.h`
- `khronos/khrplatform.h`

The generator:

- parses `gl.xml` as XML,
- selects `api="gl"` and `profile="core"`,
- walks `GL_VERSION_1_0` through `GL_VERSION_4_6`,
- applies `<require>` and `<remove profile="core">`,
- emits the public filtered API header plus the runtime's generated dispatch,
  enums, function IDs, entry points, and coverage manifest.

The generated output under `appgl-runtime/src/generated/` is deterministic
and must never be edited by hand.
