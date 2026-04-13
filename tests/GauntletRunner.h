#pragma once

#include <cstddef>
#include <string>
#include <string_view>

namespace appgl::tests {

std::string runGauntletJSON(std::string_view phaseFilter);
std::size_t writeGauntletJSON(std::string_view phaseFilter, char* out, std::size_t cap);
bool lastGauntletPassed();

// Phase 7 Group 5a — 3-tier performance benchmark (light/medium/heavy).
// Returns a JSON string with per-tier metrics.
std::string runBenchmarkJSON();

}  // namespace appgl::tests
