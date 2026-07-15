/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    GenomeChronicler Module
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Runs the GenomeChronicler container on a single sample.
    Supports both BAM and gVCF input paths. VEP HTML summary is optional.

    Future decomposition: this single process can be split into:
      - GENOMECHRONICLER_ANCESTRY  (GATK/bcftools + PLINK PCA)
      - GENOMECHRONICLER_GENOTYPE  (afogeno generation)
      - GENOMECHRONICLER_TABLES    (report table generation + filtering)
      - GENOMECHRONICLER_REPORT    (LaTeX PDF compilation)
    Each would use the same container but with explicit script invocations.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process GENOMECHRONICLER_RUN {
    tag "$meta.id"
    label 'process_medium'

    container "${params.gc_container}"

    publishDir "${params.outdir}", mode: 'copy', pattern: '**'

    input:
    tuple val(meta), path(bam), path(vcf), path(vep)

    output:
    tuple val(meta), path("results_${meta.id}/*_report_*.pdf"), emit: report
    tuple val(meta), path("results_${meta.id}/*genotypes*.xlsx"), emit: genotypes, optional: true
    tuple val(meta), path("results_${meta.id}/AncestryPlot.pdf"), emit: ancestry_plot, optional: true
    tuple val(meta), path("results_${meta.id}/**"), emit: all_results
    path "versions.yml", emit: versions

    script:
    // Build the command dynamically based on which inputs are provided
    // Use find to locate staged files — avoids nested path issues on AWS Batch
    // where stageAs + .name produces doubled directory paths
    def bam_arg  = meta.input_type == 'bam' ? "--bamFile \$(find \$PWD -name '${bam.name}' -type f | head -1)" : ''
    def vcf_arg  = meta.input_type == 'vcf' ? "--vcfFile \$(find \$PWD -name '${vcf.name}' -type f | head -1)" : ''
    def vep_arg  = meta.has_vep             ? "--vepFile \$(find \$PWD -name '${vep.name}' -type f | head -1)" : ''
    def threads_arg = "--GATKthreads ${params.threads}"
    def clean_arg   = params.no_clean_temp ? "--no_clean_temporary_files" : ''

    """
    # Symlink GenomeChronicler's scripts and templates into the work directory
    # (the tool uses relative paths and expects these in CWD)
    ln -sf /GenomeChronicler/scripts scripts
    ln -sf /GenomeChronicler/templates templates
    ln -sf /GenomeChronicler/software software
    ln -sf /GenomeChronicler/reference reference

    # Run GenomeChronicler
    genomechronicler \\
        ${bam_arg} \\
        ${vcf_arg} \\
        ${vep_arg} \\
        --resultsDir \$PWD \\
        ${threads_arg} \\
        ${clean_arg}

    # Move results out of nested results/ directory for cleaner publishDir
    mv results/results_${meta.id} .

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        genomechronicler: \$(python3 -c "print('1.0.0')")
        container: ${params.gc_container}
        samtools: \$(samtools --version | head -1 | sed 's/samtools //')
        bcftools: \$(bcftools --version | head -1 | sed 's/bcftools //')
    END_VERSIONS
    """
}
