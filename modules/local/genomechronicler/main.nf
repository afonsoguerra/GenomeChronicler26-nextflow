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
    tuple val(meta), path(bam, arity: '0..1'), path(vcf, arity: '0..1'), path(vep, arity: '0..1')

    output:
    tuple val(meta), path("results_${meta.id}/*_report_*.pdf"), emit: report
    tuple val(meta), path("results_${meta.id}/*genotypes*.xlsx"), emit: genotypes, optional: true
    tuple val(meta), path("results_${meta.id}/AncestryPlot.pdf"), emit: ancestry_plot, optional: true
    tuple val(meta), path("results_${meta.id}/**"), emit: all_results
    path "versions.yml", emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def has_bam = bam instanceof List ? false : true
    def has_vcf = vcf instanceof List ? false : true
    def has_vep = vep instanceof List ? false : true

    if (!has_bam && !has_vcf) {
        error "Sample ${meta.id}: neither BAM nor VCF provided"
    }

    def bam_arg  = has_bam ? "--bamFile ${bam}" : ''
    def vcf_arg  = has_vcf ? "--vcfFile ${vcf}" : ''
    def vep_arg  = has_vep ? "--vepFile ${vep}" : ''
    def threads_arg = "--GATKthreads ${params.threads}"
    def clean_arg   = params.no_clean_temp ? "--no_clean_temporary_files" : ''

    """
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
