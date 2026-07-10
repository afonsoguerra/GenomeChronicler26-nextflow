#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# download_testdata.sh — Download GIAB NA12878 (HG001) benchmark VCF for
# testing GenomeChronicler-nf with real genotype data.
#
# Source: Genome in a Bottle Consortium (NIST)
#   https://ftp-trace.ncbi.nlm.nih.gov/giab/ftp/release/NA12878_HG001/
#   NISTv4.2.1/GRCh38/
#
# The GIAB v4.2.1 benchmark VCF contains high-confidence variant calls
# for NA12878 on GRCh38 (chromosomes 1-22). GenomeChronicler requires
# chromosomes without the "chr" prefix, so this script strips it.
#
# Usage:
#   bash bin/download_testdata.sh [OUTDIR]
#
# Outputs:
#   testdata/NA12878.g.vcf.gz          — Processed gVCF (chr prefix stripped)
#   testdata/samplesheet_NA12878.csv   — Ready-to-use samplesheet
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(dirname "$SCRIPT_DIR")"
OUTDIR="${1:-${PIPELINE_DIR}/testdata}"

GIAB_URL="https://ftp-trace.ncbi.nlm.nih.gov/giab/ftp/release/NA12878_HG001/NISTv4.2.1/GRCh38"
VCF_FILE="HG001_GRCh38_1_22_v4.2.1_benchmark.vcf.gz"
TBI_FILE="${VCF_FILE}.tbi"

mkdir -p "${OUTDIR}"
cd "${OUTDIR}"

echo "============================================"
echo " GenomeChronicler-nf: Download Test Data"
echo "============================================"
echo ""
echo "Source: GIAB HG001 (NA12878) v4.2.1 GRCh38"
echo "Output: ${OUTDIR}"
echo ""

# ---------- Download ----------
if [ -f "${VCF_FILE}" ]; then
    echo "[skip] ${VCF_FILE} already exists"
else
    echo "[download] ${VCF_FILE} (~120 MB) ..."
    wget -q --show-progress "${GIAB_URL}/${VCF_FILE}" -O "${VCF_FILE}"
    echo "[done] Downloaded ${VCF_FILE}"
fi

if [ -f "${TBI_FILE}" ]; then
    echo "[skip] ${TBI_FILE} already exists"
else
    echo "[download] ${TBI_FILE} ..."
    wget -q --show-progress "${GIAB_URL}/${TBI_FILE}" -O "${TBI_FILE}"
    echo "[done] Downloaded ${TBI_FILE}"
fi

# ---------- Strip chr prefix ----------
# GenomeChronicler reference uses chromosomes without "chr" prefix
# (GRCh38_full_analysis_set_plus_decoy_hla_noChr.fa)
FINAL_VCF="NA12878.g.vcf.gz"

if [ -f "${FINAL_VCF}" ]; then
    echo "[skip] ${FINAL_VCF} already exists"
else
    echo "[process] Stripping chr prefix and recompressing ..."

    # Check if bcftools is available
    if command -v bcftools &> /dev/null; then
        # Create chromosome rename map
        RENAME_MAP=$(mktemp)
        for i in $(seq 1 22) X Y M; do
            echo "chr${i} ${i}" >> "${RENAME_MAP}"
        done
        bcftools annotate --rename-chrs "${RENAME_MAP}" "${VCF_FILE}" -Oz -o "${FINAL_VCF}"
        bcftools index -t "${FINAL_VCF}"
        rm -f "${RENAME_MAP}"
    else
        # Fallback: use zcat + sed + gzip
        echo "  (bcftools not found, using sed fallback — no index created)"
        zcat "${VCF_FILE}" \
            | sed 's/^chr//' \
            | sed 's/contig=<ID=chr/contig=<ID=/' \
            | gzip > "${FINAL_VCF}"
    fi

    echo "  Created ${FINAL_VCF} ($(du -h ${FINAL_VCF} | cut -f1))"
fi

# ---------- Create samplesheet ----------
SAMPLESHEET="samplesheet_NA12878.csv"
# Use path relative to the pipeline root so the samplesheet is portable
RELATIVE_VCF="testdata/${FINAL_VCF}"
echo "sample,bam,vcf,vep" > "${SAMPLESHEET}"
echo "NA12878,,${RELATIVE_VCF}," >> "${SAMPLESHEET}"

echo ""
echo "============================================"
echo " Download complete!"
echo "============================================"
echo ""
echo "Files:"
ls -lh "${FINAL_VCF}" "${SAMPLESHEET}" 2>/dev/null
echo ""
echo "To run the pipeline:"
echo "  cd ${PIPELINE_DIR}"
echo "  ./nextflow run main.nf \\"
echo "      --input testdata/${SAMPLESHEET} \\"
echo "      --outdir results_NA12878 \\"
echo "      -profile apptainer"
echo ""
