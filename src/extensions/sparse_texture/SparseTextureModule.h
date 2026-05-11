#pragma once

namespace appgl {
class ExtensionContext;
}

namespace appgl::extensions::sparse_texture {

const char* extensionString();
bool isAvailable(ExtensionContext& ctx);
void initialize(ExtensionContext& ctx);
void shutdown();
bool isActive();

}  // namespace appgl::extensions::sparse_texture

