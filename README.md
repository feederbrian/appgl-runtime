# AppGL

An OpenGL 4.6 → Metal translation layer for macOS, shipping as `libAppGL.dylib`.

---

## ⚠ Pre-release — not ready for use

**This repository is published for transparency, not for consumption.** It is not packaged, not
supported, and not ready to build against. There are no installation instructions yet, and issues and
pull requests are not being accepted.

A substantial internal rework is planned before this becomes usable. Until that lands, treat anything
here as subject to change without notice.

---

## Where it stands

Conformance measured 2026-08-12:

| suite | configuration | standing |
|---|---|---|
| **Khronos CTS** (`KHR-GL46`, 19,716 cases) | df64 emulation **enabled** | 19,402 pass · 4 fail · 310 not-supported |
| **Piglit** (7,324 rows run) | default | 4,316 pass · 587 fail · 2,421 skip |

AppGL is a single binary whose behaviour is selected at runtime via environment flags — there is no
separate "feature build." The CTS row above is **not** the default configuration: df64 emulation is
off unless enabled (`APPGL_ENABLE_FP64_EMULATION=1`, or the `f64-emulation` feature flag), and with
it off the not-supported count is substantially higher.

Two caveats we would rather state than have you discover:

- **The default-configuration CTS standing is not published here.** We have an internal figure, but
  it has not been re-measured against the current pin, and replacing one unverified number with
  another is not an improvement. It will be published when it is re-run.
- **The Piglit row is a partial surface.** The canonical Piglit surface is 7,878 rows; the row above
  covers the 7,324 that were executed. Roughly 450 of the remainder are binaries piglit does not
  build on macOS. A run over a different subset is a *differential*, not a standing, and cannot be
  quoted as a percentage of the canonical surface.

---

## License

See [`LICENSE`](LICENSE).

Third-party components retain their own licenses. AppGL vendors
[SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross) and
[glslang](https://github.com/KhronosGroup/glslang), both Apache-2.0; see [`NOTICE`](NOTICE).

## Security

Please do not open public issues for security findings. See [`SECURITY.md`](SECURITY.md).
