/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    WORKFLOW: GENOMECHRONICLER
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Reads a samplesheet, validates inputs, and runs GenomeChronicler per sample.

    Samplesheet CSV format:
        sample,bam,vcf,vep
        NA12878,,/path/to/NA12878.g.vcf.gz,
        SAMPLE2,/path/to/SAMPLE2.bam,,/path/to/vep_summary.html

    Rules:
      - Each row must have either a bam or vcf column filled (not both, not neither)
      - vep is optional
      - sample is the sample ID used in output naming
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { GENOMECHRONICLER_RUN } from '../modules/local/genomechronicler/main'

workflow GENOMECHRONICLER {

    main:
    // Parse samplesheet
    Channel
        .fromPath(params.input, checkIfExists: true)
        .splitCsv(header: true, strip: true)
        .map { row ->
            // Validate: must have exactly one of bam or vcf
            def has_bam = row.bam && row.bam.trim()
            def has_vcf = row.vcf && row.vcf.trim()
            def has_vep = row.vep && row.vep.trim()

            if (!has_bam && !has_vcf) {
                error "ERROR: Sample '${row.sample}' has neither BAM nor VCF specified."
            }
            if (has_bam && has_vcf) {
                error "ERROR: Sample '${row.sample}' has both BAM and VCF specified. Please provide only one."
            }

            def meta = [
                id:         row.sample,
                input_type: has_bam ? 'bam' : 'vcf',
                has_vep:    has_vep
            ]

            def bam_file = has_bam ? file(row.bam, checkIfExists: true) : file("${projectDir}/assets/NO_FILE")
            def vcf_file = has_vcf ? file(row.vcf, checkIfExists: true) : file("${projectDir}/assets/NO_FILE2")
            def vep_file = has_vep ? file(row.vep, checkIfExists: true) : file("${projectDir}/assets/NO_FILE3")

            return [ meta, bam_file, vcf_file, vep_file ]
        }
        .set { ch_input }

    // Run GenomeChronicler
    GENOMECHRONICLER_RUN ( ch_input )

    emit:
    report       = GENOMECHRONICLER_RUN.out.report
    genotypes    = GENOMECHRONICLER_RUN.out.genotypes
    ancestry     = GENOMECHRONICLER_RUN.out.ancestry_plot
    all_results  = GENOMECHRONICLER_RUN.out.all_results
    versions     = GENOMECHRONICLER_RUN.out.versions
}
