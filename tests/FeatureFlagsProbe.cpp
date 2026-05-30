#include <iostream>

#include "../src/extensions/fp64/Fp64Module.h"

int main() {
    std::cout << "{\"fp64RuntimeFlag\":"
              << (appgl::extensions::fp64::runtimeFlagEnabled() ? "true" : "false")
              << "}\n";
    return 0;
}
