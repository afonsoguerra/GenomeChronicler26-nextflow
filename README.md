# GenomeChronicler-nf

DSL2 Nextflow pipeline for running [PGP-UK GenomeChronicler](https://github.com/PGP-UK/GenomeChronicler) — a personal genome report generator that produces ancestry analysis, genotype tables, and a comprehensive PDF report from BAM or gVCF files.

## Overview

This pipeline wraps the GenomeChronicler container (`ghcr.io/pgp-uk/genomechronicler:latest`) in a modern Nextflow DSL2 framework, following nf-core conventions. It supports:

- **BAM input** — runs GATK HaplotypeCaller internally for variant calling, then ancestry + report generation
- **gVCF input** — skips variant calling, goes directly to ancestry + report generation (faster)
- **Optional VEP** — include a VEP HTML summary file for additional variant annotation tables
- **Multi-sample** — process multiple samples in parallel via a CSV samplesheet

## Quick Start

```bash
# With Singularity/Apptainer (recommended for HPC)
nextflow run main.nf \
    --input samplesheet.csv \
    --outdir results \
    -profile singularity

# With Docker
nextflow run main.nf \
    --input samplesheet.csv \
    --outdir results \
    -profile docker
```

## Samplesheet Format

Create a CSV file with the following columns:

```csv
sample,bam,vcf,vep
NA12878,,/path/to/NA12878.g.vcf.gz,
SAMPLE_A,/path/to/SAMPLE_A.bam,,/path/to/vep_summary.html
SAMPLE_B,,/path/to/SAMPLE_B.g.vcf.gz,/path/to/vep_summary_B.html
```

**Rules:**
- Each row must have **either** `bam` **or** `vcf` (not both)
- `vep` is optional — leave empty to skip VEP summary tables
- `sample` is the sample identifier used in output file naming

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--input` | *required* | Path to samplesheet CSV |
| `--outdir` | `results` | Output directory |
| `--threads` | `4` | Threads for GATK genotyping steps |
| `--no_clean_temp` | `false` | Keep intermediate files |
| `--gc_container` | `ghcr.io/pgp-uk/genomechronicler:latest` | Container image |

## Output

For each sample, the pipeline produces:

```
results/
└── <sample_id>/
    └── results_<sample_id>/
        ├── <sample_id>_report_<date>.pdf    # Main genome report
        ├── <sample_id>genotypes<date>.xlsx   # Genotype tables workbook
        ├── AncestryPlot.pdf                  # Ancestry PCA plot
        ├── SampleName.txt
        └── <sample_id>.processingLog.stderr.txt
```

## Profiles

- `singularity` — Use Singularity container engine
- `apptainer` — Use Apptainer container engine  
- `docker` — Use Docker container engine
- `test` — Minimal test configuration

## Test Data

A download script is included to fetch the [GIAB](https://www.nist.gov/programs-projects/genome-bottle) NA12878 (HG001) v4.2.1 benchmark VCF for GRCh38 from the NCBI FTP:

```bash
# Download and prepare test data (~120 MB)
bash bin/download_testdata.sh

# Run pipeline with test data
nextflow run main.nf \
    --input testdata/samplesheet_NA12878.csv \
    --outdir results_NA12878 \
    -profile apptainer
```

The script downloads the GIAB benchmark VCF, strips the `chr` prefix to match GenomeChronicler's reference (GRCh38 without chr prefix), and creates a ready-to-use samplesheet. Expected runtime is ~2 minutes on 8 threads.

## Requirements

- Nextflow >= 22.10.0
- Container engine: Singularity/Apptainer or Docker
- The GenomeChronicler container includes all dependencies (samtools, bcftools, GATK, PLINK, R, LaTeX)

## Architecture

```
main.nf                              # Entry point
├── workflows/genomechronicler.nf    # Workflow: samplesheet parsing + orchestration
├── modules/local/genomechronicler/  # Process: container wrapper
│   └── main.nf
├── conf/
│   ├── base.config                  # Resource defaults
│   └── test.config                  # Test profile
└── nextflow.config                  # Global configuration
```

The pipeline is structured for future decomposition: the single `GENOMECHRONICLER_RUN` process can be split into per-step processes (ancestry, genotyping, tables, report) when finer resource control or step-level resume is needed.

## Credits

- [GenomeChronicler](https://github.com/PGP-UK/GenomeChronicler) by PGP-UK
- Original DSL1 wrapper by [cgpu](https://github.com/cgpu/genomechronicler-nf)
- Pipeline built following [nf-core](https://nf-co.re/) best practices
