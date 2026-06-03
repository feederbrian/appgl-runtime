# R5 Eviction Dry-Run

Status: R5-0 observe-only implementation.

R5-0 does not evict, discard, drain, or call `setPurgeableState`. It only
classifies residency records, counts dry-run candidates, and records scalar
touch telemetry from selected bind/draw/dispatch paths.

## Guardrails

- No pressure-handler mutation. The memory-pressure dispatch handler remains
  atomics-only.
- The R5 pass runs through the existing diagnostics/runtime inventory path,
  not from the dispatch-source event handler.
- Unknown or unclassified `ResourceResidencyKind` values default to
  `AUTHORITATIVE`/excluded.
- Unknown `MetalResidencyAuthorityClass` values default to
  `AUTHORITATIVE`/excluded.
- R5-0 counters for pressure mutations, purgeable-state calls, and drain
  requests must remain zero.
- Touch telemetry is scalar-only: one monotonic serial and per-operation
  counters. It does not allocate, take locks, mutate caches, or store resource
  handles.

## Classifier Model

R5 dry-run uses two behavior classes:

- `RECONSTRUCTABLE`: current record authority is reconstructable and the
  resource kind is known. These records are counted as dry-run candidates only.
- `AUTHORITATIVE`: all authoritative, transient, sparse-special, unknown-kind,
  and unknown-authority records. These are excluded.

This is intentionally conservative. A future kind should appear as excluded
until a gate explicitly proves its source, recipe, generation check, and
restore path.

## R5-1 Preconditions

R5-1 or later real eviction requires a fresh operator-aware design gate after
R5-0 data. The minimum precondition is proven Section 37 classifier coverage for
every resource kind present in the gate workloads. Misclassifying authoritative
data as reconstructable is data loss.

Before an eviction candidate can be approved, the gate must prove:

- the classifier marks every workload residency kind intentionally;
- authoritative/no-client-copy data is excluded;
- in-flight command-buffer and producer-pending resources are excluded or
  completed through an approved read-coherence drain;
- volatile restore is tested before any future `setPurgeableState` use;
- heap classes have separate accounting and targets;
- release-shaped binary shape is checked before GLTest perf/AE runs.

## R5-0 Probe

`appgl_r5_residency_probe` covers:

- unknown kind and unknown authority default-exclusion;
- reconstructable candidate byte accounting by heap;
- transient and sparse-special exclusion counters;
- zero mutation/purgeable/drain counters;
- scalar touch counter correctness and a `ns_per_touch` microbenchmark.
