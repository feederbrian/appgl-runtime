#pragma once

namespace appgl {
class ExtensionContext;
}

namespace appgl::extensions::fp64 {

const char* extensionString();
const char* vertexAttrib64BitExtensionString();

bool buildFlagEnabled();
bool isAdvertisingHeld();
bool isAvailable(ExtensionContext& ctx);
void initialize(ExtensionContext& ctx);
void shutdown();
bool isActive();

}  // namespace appgl::extensions::fp64
