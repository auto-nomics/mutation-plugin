#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: test_mutation.sh

Builds the maftools image and validates the tmb and top_genes contracts with
the deterministic repository fixture, twice: once through the image-baked
MUTATION_CONFIG runner (the published image baseline) and once through the
plugin manifest script (scripts/mutation_analysis.R.sh, the MUTATION_* env
contract the runtime actually executes).

Environment:
  MUTATION_IMAGE  Image tag (default localhost/atc/mutation-analysis:0.1.0)
  BUILD_IMAGE=0   Skip the Podman build
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage && exit 0
command -v podman >/dev/null || { echo "missing required command: podman" >&2; exit 1; }
command -v python3 >/dev/null || { echo "missing required command: python3" >&2; exit 1; }

# Plugin checkout root: this script lives at the plugin root, next to the
# Dockerfile it builds (moved out of the workspace's containers/ dir).
root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
image=${MUTATION_IMAGE:-localhost/atc/mutation-analysis:0.1.0}
build_image=${BUILD_IMAGE:-1}
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
runtime_flags=(
  --rm
  --network=none
  --read-only
  --security-opt=no-new-privileges
  --userns=keep-id
  --user="$(id -u):$(id -g)"
  --tmpfs=/tmp:rw,nosuid,nodev
)
cp "$root/fixtures/sample_mutations.maf" "$scratch/sample.maf"
printf 'sample_id\tgroup\nsample_a\tprimary\nsample_b\tcontrol\nsample_c\tprimary\nsample_d\tcontrol\n' \
  > "$scratch/clinical.tsv"

if [[ "$build_image" == 1 ]]; then
  podman build --network=host \
    -f "$root/Dockerfile" \
    -t "$image" "$root"
fi

# The plugin env contract: the same values the manifest renders for a tmb
# run with grouped comparison (numbers as serde_json literals, the group
# array space-joined by the env renderer and re-split in R).
plugin_env=(
  -e MUTATION_OPERATION=tmb
  -e MUTATION_PANEL_SIZE_MB=38.0
  -e MUTATION_TMB_GROUP_COL=group
  -e 'MUTATION_TMB_GROUPS=primary control'
  -e MUTATION_TOP_N=20
  -e MUTATION_GENE_COL=Hugo_Symbol
  -e MUTATION_VARIANT_COL=Variant_Classification
  -e MUTATION_TUMOR_SAMPLE_COL=Tumor_Sample_Barcode
  -e MUTATION_VARIANT_TYPE_COL=Variant_Type
  -e MUTATION_CHROMOSOME_COL=Chromosome
  -e MUTATION_START_POSITION_COL=Start_Position
  -e MUTATION_END_POSITION_COL=End_Position
  -e MUTATION_REFERENCE_ALLELE_COL=Reference_Allele
  -e MUTATION_TUMOR_SEQ_ALLELE_COL=Tumor_Seq_Allele2
)

assert_tmb_report() {
  python3 - "$1" "$2" <<'PY'
import csv
import json
import sys

with open(sys.argv[1], encoding="utf-8", newline="") as handle:
    rows = list(csv.DictReader(handle, delimiter="\t"))
assert len(rows) == 4, rows
assert {"sample_id", "group", "mutations", "panel_size_mb", "tmb_per_mb"} <= rows[0].keys()
assert {row["sample_id"] for row in rows} == {"sample_a", "sample_b", "sample_c", "sample_d"}
with open(sys.argv[2], encoding="utf-8") as handle:
    details = json.load(handle)
assert details["schema_version"] == "1.0"
assert details["operation"] == "tmb"
assert details["variant_count"] == 11
assert details["group_comparison"] == "wilcox:primary_vs_control"
PY
}

# Phase 1: the published image baseline — the baked ENTRYPOINT runner
# reading the legacy MUTATION_CONFIG JSON blob.
podman run "${runtime_flags[@]}" \
  -v "$scratch":/data:Z \
  -e AUTONOMICS_INPUT0=/data/sample.maf \
  -e AUTONOMICS_INPUT1=/data/clinical.tsv \
  -e AUTONOMICS_OUTPUT0=/data/tmb.tsv \
  -e AUTONOMICS_OUTPUT1=/data/tmb.json \
  -e 'MUTATION_CONFIG={"operation":"tmb","panel_size_mb":38,"tmb_group_col":"group","tmb_groups":["primary","control"],"gene_col":"Hugo_Symbol","variant_col":"Variant_Classification","tumor_sample_col":"Tumor_Sample_Barcode","variant_type_col":"Variant_Type","chromosome_col":"Chromosome","start_position_col":"Start_Position","end_position_col":"End_Position","reference_allele_col":"Reference_Allele","tumor_seq_allele_col":"Tumor_Seq_Allele2"}' \
  "$image"
assert_tmb_report "$scratch/tmb.tsv" "$scratch/tmb.json"

# Phase 2: the plugin contract — the manifest script (bind-mounted over the
# baked copy) reading the MUTATION_* env channel. Keeps the shipped script
# and the baked runner honest against the same fixture.
podman run "${runtime_flags[@]}" \
  -v "$scratch":/data:Z \
  -e AUTONOMICS_INPUT0=/data/sample.maf \
  -e AUTONOMICS_INPUT1=/data/clinical.tsv \
  -e AUTONOMICS_OUTPUT0=/data/tmb_plugin.tsv \
  -e AUTONOMICS_OUTPUT1=/data/tmb_plugin.json \
  --volume="$root/scripts/mutation_analysis.R.sh:/opt/autonomics/mutation_analysis.R:ro,Z" \
  "${plugin_env[@]}" \
  "$image"
assert_tmb_report "$scratch/tmb_plugin.tsv" "$scratch/tmb_plugin.json"

# Phase 3: top_genes through the baked runner (unchanged legacy baseline).
podman run "${runtime_flags[@]}" \
  -v "$scratch":/data:Z \
  -e AUTONOMICS_INPUT0=/data/sample.maf \
  -e AUTONOMICS_OUTPUT0=/data/top_genes.tsv \
  -e AUTONOMICS_OUTPUT1=/data/top_genes.json \
  -e 'MUTATION_CONFIG={"operation":"top_genes","top_n":20,"gene_col":"Hugo_Symbol","variant_col":"Variant_Classification","tumor_sample_col":"Tumor_Sample_Barcode","variant_type_col":"Variant_Type","chromosome_col":"Chromosome","start_position_col":"Start_Position","end_position_col":"End_Position","reference_allele_col":"Reference_Allele","tumor_seq_allele_col":"Tumor_Seq_Allele2"}' \
  "$image"

python3 - "$scratch/top_genes.tsv" "$scratch/top_genes.json" <<'PY'
import csv
import json
import sys

with open(sys.argv[1], encoding="utf-8", newline="") as handle:
    rows = list(csv.DictReader(handle, delimiter="\t"))
assert len(rows) == 3, rows
assert {"gene_id", "mutation_count", "sample_count", "rank"} <= rows[0].keys()
assert {row["gene_id"] for row in rows} == {"TP53", "KRAS", "BRAF"}
expected_counts = {"TP53": 4, "KRAS": 4, "BRAF": 3}
assert {row["gene_id"]: int(row["mutation_count"]) for row in rows} == expected_counts
with open(sys.argv[2], encoding="utf-8") as handle:
    details = json.load(handle)
assert details["operation"] == "top_genes"
assert details["gene_count"] == 3
PY

echo "mutation analysis tmb and top_genes smoke tests completed successfully."
