#pragma once

namespace appgl {
class ExtensionContext;
}

namespace appgl::extensions::fragment_shading_rate {

const char* extensionString();
bool isAvailable(ExtensionContext& ctx);
void initialize(ExtensionContext& ctx);
void shutdown();
bool isActive();

}  // namespace appgl::extensions::fragment_shading_rate
