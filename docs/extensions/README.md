# AppGL Extension Modules

Sprint 19 Decision H4 / Item 55 establishes extension modules as the boundary
between core GL behavior and optional runtime-advertised extension behavior.

The foundation layer is `src/extensions/ExtensionRegistry.{h,mm}` plus
`src/extensions/ExtensionContext.h`. Individual extension architecture notes
land with the module migrations that introduce their behavior.
