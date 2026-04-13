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

// Phase 7 Group 6 — version comparison (GL 3.3 vs 4.1 vs 4.6).
// Renders the same Phong sphere via three GL API paths, compares pairwise.
// Returns a JSON string with per-scene results and cross-version diffs.
std::string runVersionComparisonJSON();

}  // namespace appgl::tests
