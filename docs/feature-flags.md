# AppGL Feature Flags

AppGL resolves runtime feature flags with one shared launch-time resolver.
The S23 precedence rule is deterministic:

1. Command-line arguments on the host process.
2. Porter environment variables.
3. User JSON config.
4. Built-in default.

Malformed or unreadable JSON files are ignored. Startup falls back to the next
lower source instead of crashing.

## Command Line

Boolean flags accept either generic or per-flag forms:

```bash
--appgl-enable=f64-emulation
--appgl-disable=f64-emulation
--appgl-f64-emulation=1
--appgl-f64-emulation=false
--appgl-no-f64-emulation
```

If the same flag appears more than once on the command line, the last matching
argument wins within the command-line source.

## Environment

Each feature owns its compatibility environment-variable aliases. Environment
variables use AppGL's existing boolean convention: presence means enabled unless
the value is an explicit false token.

Accepted true tokens: `1`, `true`, `yes`, `on`, `enable`, `enabled`.
Accepted false tokens: `0`, `false`, `no`, `off`, `disable`, `disabled`.

## JSON Config

Search order:

1. `APPGL_OPTIONS_JSON` or `APPGL_CONFIG_JSON` if set.
2. `appgl-options.json` in the current working directory.
3. `appgl-options.json` next to the process executable.
4. `appgl-options.json` in the app bundle resources.

Flag keys may be top-level or nested under `appgl` or `features`.
Boolean values may be booleans, boolean strings, numbers, or objects with an
`enabled`, `force`, or `value` member.

```json
{
  "appgl": {
    "features": {
      "f64-emulation": true
    }
  }
}
```

## Initial Consumer

`f64-emulation` is the first shared-infrastructure consumer. It keeps the older
aliases `fp64-emulation`, `gpu-shader-fp64`, and `vertex-attrib-64bit`, plus the
existing environment variables:

```bash
APPGL_ENABLE_FP64_EMULATION=1
APPGL_ENABLE_GPU_SHADER_FP64=1
APPGL_ENABLE_VERTEX_ATTRIB_64BIT=1
```
