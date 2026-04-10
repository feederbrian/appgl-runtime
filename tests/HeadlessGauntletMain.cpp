#include <iostream>
#include <string>

#include "GauntletRunner.h"

int main(int argc, char** argv) {
    const std::string phaseFilter = argc > 1 ? argv[1] : "phase-a";
    const std::string payload = appgl::tests::runGauntletJSON(phaseFilter);
    if (payload.empty()) {
        std::cerr << "Failed to generate gauntlet report.\n";
        return 1;
    }

    std::cout << payload << '\n';
    return appgl::tests::lastGauntletPassed() ? 0 : 2;
}
