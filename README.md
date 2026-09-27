# mutation plugin

Containerized maftools mutation analyses, migrated from the legacy Rust
wrapper `crates/node-bundles/nodes-io/src/mutation_analysis_container.rs`
(kind `mutation_analysis_container` → plugin kinds `mutation_analysis` and
`mutation_analysis_clinical`) following `docs/plugin-node-migration.md`.
One directory = one plugin family = one git-able unit.

## Layout

```text
mutation/
├── manifest.toml          # node contract: params, ports, image, resources
├── scripts/
│   └── mutation_analysis.R.sh  # the live runner (staged, run by Rscript)
├── Dockerfile             # image provenance (moved verbatim from
│                          #   containers/mutation-analysis/; build + push
│                          #   still via GHCR)
├── mutation_analysis.R    # the image-baked runner COPY-ed to
│                          #   /opt/autonomics/mutation_analysis.R
├── container_README.md    # the container-era README (moved verbatim)
├── test_mutation.sh       # image baseline + plugin-script smoke test
├── fixtures/
│   └── sample_mutations.maf  # copy of the workspace fixture the moved
│                             #   test uses; the original stays at
│                             #   fixtures/maf/ for the live Rust test
└── README.md
```

## Image

`ghcr.io/auto-nomics/autonomics/mutation-analysis@sha256:6f33327237fb5b5cb01b65b194244a742d791a0466844a6f5a9e18af2f99158a`
(tag `0.1.0`; base `docker.io/bioconductor/bioconductor` pinned by digest,
maftools >= 2.20.0 installed from Bioconductor, license MIT). The registry
entry lives in the workspace's `containers/image-inventory.tsv`.

The Dockerfile still `COPY`s `mutation_analysis.R` into the image so the
pinned digest stays reproducible from this tree. Like visualization, the
baked copy is now the image baseline: the live runner is
`scripts/mutation_analysis.R.sh`, staged per run and inserted at `argv[1]`
(`Rscript /work/.autonomics/script`). `test_mutation.sh` runs both — the
baked runner against the legacy `MUTATION_CONFIG` JSON contract, and the
manifest script against the `MUTATION_*` env contract — over the same
fixture so the two stay in sync.

## Why two kinds (the clinical input)

The legacy node exposed an **optional** second input port: a clinical file
that only the grouped TMB comparison reads. The v0 manifest `PortLayout`
has no optional-input concept (`compile_ports` emits required ports only,
and the DAG rejects an unconnected required port), and per-spec dynamic
ports do not exist for manifests (`ports_for_spec` ignores the spec). The
optional port therefore cannot be one kind with a sometimes-connected
second port.

The family splits by port layout, the documented rule for several
`[[nodes]]` in one plugin (both entries share this image and the empty
panel set):

- `mutation_analysis` — input port 0 (`maf`) only. Covers every operation;
  `tmb_groups` set without a clinical table fails at run time with the
  legacy "tmb groups require a clinical input" message.
- `mutation_analysis_clinical` — input ports 0 (`maf`) and 1 (`clinical`).
  Identical params, env, outputs, and script; `tmb_groups` plus the
  clinical table enable the per-sample Wilcoxon TMB comparison.

When the planned dynamic-port wave (the `lava_scan` follow-up) lands, the
two kinds can collapse back into one.

## Params

Per the legacy `MutationAnalysisContainerSpec`, exactly:

- `maf_path` (required string) and `clinical_path` (optional string) are
  provenance labels only — the legacy wrapper never sent them to the
  container and neither does the manifest; they shape the closed param
  schema so DAG authors can record what was wired where.
- `operation` is a string defaulting to `tmb` (v0 has no enum param type;
  the legacy snake_case `MutationAnalysisOperation` enum values are the
  valid spellings). Unsupported values fail at run time in the script's
  `switch` with the legacy "unsupported operation" stop instead of at
  schema-parse time.
- `panel_size_mb` (default 38.0, `exclusive_min` 0.0), `top_n` (default 20,
  `min` 1.0) carry the legacy `validate()` numeric bounds.
- The ten column mappings keep their legacy defaults; non-emptiness and the
  "MAF column mappings must be unique" rule are enforced by the script with
  the legacy messages (the DSL has no string predicates).
- `tmb_groups` is an optional string array. "Exactly two distinct nonempty
  labels" and "only valid for operation `tmb`" are enforced by the script
  with the legacy messages.
- `timeout_secs` / `artifact_prefix` / `cpus` / `memory` / `pids_limit`
  become node-level constants: 3600 s, `/artifacts/mutation_analysis`
  (clinical kind: `/artifacts/mutation_analysis_clinical`), and the
  resource profile `cpus 2.0 / memory 8Gi / pids_limit 512 / shm_size 1Gi`
  — the legacy defaults its optional per-instance overrides resolved to
  when omitted.

## Migration parity

The golden test
(`crates/container-plugin/tests/mutation_migration.rs` in the autonomics
workspace) compares the compiled `ContainerCommandSpec` against the legacy
Rust wrapper: image, outputs, network, rootfs, pull policy, resources,
timeout, and the full default env are byte-equal; the script preserves the
exact maftools analysis pipeline token for token. Deliberate deltas:

- **Kind rename**: `mutation_analysis_container` → `mutation_analysis`
  (plus the clinical-input kind above); artifact prefixes follow the kind
  (`/artifacts/mutation_analysis_container` →
  `/artifacts/mutation_analysis`). DAG specs referencing the old kind must
  be regenerated.
- **The JSON config blob became env vars.** The legacy wrapper serialized
  the whole spec into one `MUTATION_CONFIG` JSON string; the env renderer
  cannot emit JSON arrays (they space-join), so each param travels in its
  own `MUTATION_*` variable and the script reassembles the same `config`
  list — `tmb_groups` via a single-space `fixed = TRUE` `strsplit`, the
  exact inverse of the join (group labels containing spaces cannot
  round-trip; clinical group labels never contain them).
- **Output port 0 is a file.** The legacy node post-processed the TSV
  report into a DataFrame on port 0; plugin container nodes are
  File-to-File by policy (same delta as pathway-gsea). Consume
  `mutation_analysis_report.tsv` as a table downstream.
- **Validation moved into the script** for everything the DSL cannot
  express, with the legacy error messages; the failure point moves from
  registry build to container start.
- **Compiled command** is `["Rscript"]` + the staged script path where the
  legacy command was `["Rscript", "/opt/autonomics/mutation_analysis.R"]`.
- Numbers render through serde_json: `panel_size_mb` reaches the container
  as `"38.0"` where the legacy JSON carried `38` — identical after R's
  `as.numeric()`.

## Build and smoke test

```bash
podman build -f Dockerfile -t localhost/atc/mutation-analysis:0.1.0 .
./test_mutation.sh            # BUILD_IMAGE=0 reuses the local image
```

Publish and verify: see `container_README.md` (the GHCR push + digest
recovery flow is unchanged; the digest above is the one this manifest
pins).
