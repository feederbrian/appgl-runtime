#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

#include "GauntletRunner.h"
#include "../src/runtime/AppGLRuntime.h"

int main(int argc, char** argv) {
    const std::string phaseFilter = argc > 1 ? argv[1] : "phase-a";

    // Benchmark mode: ./appgl_gauntlet_cli benchmark [output.json]
    if (phaseFilter == "benchmark") {
        const std::string payload = appgl::tests::runBenchmarkJSON();
        if (payload.empty()) {
            std::cerr << "Failed to generate benchmark report.\n";
            return 1;
        }
        std::cout << payload << '\n';

        // Optional: write to file.
        if (argc > 2) {
            const std::string outPath = argv[2];
            std::ofstream out(outPath, std::ios::binary);
            if (!out) {
                std::cerr << "Failed to open output path: " << outPath << "\n";
                return 3;
            }
            out << payload;
        }
        return 0;
    }

    // Version comparison mode: ./appgl_gauntlet_cli compare [output.json]
    if (phaseFilter == "compare") {
        const std::string payload = appgl::tests::runVersionComparisonJSON();
        if (payload.empty()) {
            std::cerr << "Failed to generate version comparison report.\n";
            return 1;
        }
        std::cout << payload << '\n';

        if (argc > 2) {
            const std::string outPath = argv[2];
            std::ofstream out(outPath, std::ios::binary);
            if (!out) {
                std::cerr << "Failed to open output path: " << outPath << "\n";
                return 3;
            }
            out << payload;
        }
        return 0;
    }

    const std::string payload = appgl::tests::runGauntletJSON(phaseFilter);
    if (payload.empty()) {
        std::cerr << "Failed to generate gauntlet report.\n";
        return 1;
    }

    std::cout << payload << '\n';

    // Optional second argument: write the post-run coverage snapshot JSON to
    // the given path. Used to refresh docs/appgl-coverage-snapshot-gate3.json
    // from CLI after Phase 3 gate work.
    if (argc > 2) {
        const std::string snapshotPath = argv[2];
        std::size_t required = appgl::Runtime::shared().writeCoverageSnapshotJSON(nullptr, 0);
        std::vector<char> buffer(required);
        appgl::Runtime::shared().writeCoverageSnapshotJSON(buffer.data(), buffer.size());
        std::ofstream out(snapshotPath, std::ios::binary);
        if (!out) {
            std::cerr << "Failed to open snapshot path: " << snapshotPath << "\n";
            return 3;
        }
        out.write(buffer.data(), static_cast<std::streamsize>(required - 1));
        if (!out) {
            std::cerr << "Failed to write coverage snapshot to: " << snapshotPath << "\n";
            return 3;
        }
    }

    // Optional third argument: write post-run diagnostics JSON to the given path.
    if (argc > 3) {
        const std::string diagPath = argv[3];
        std::size_t diagRequired = appgl::Runtime::shared().writeDiagnosticsJSON(nullptr, 0);
        std::vector<char> diagBuffer(diagRequired);
        appgl::Runtime::shared().writeDiagnosticsJSON(diagBuffer.data(), diagBuffer.size());
        std::ofstream diagOut(diagPath, std::ios::binary);
        if (diagOut) {
            diagOut.write(diagBuffer.data(), static_cast<std::streamsize>(diagRequired - 1));
        }
    }

    return appgl::tests::lastGauntletPassed() ? 0 : 2;
}
