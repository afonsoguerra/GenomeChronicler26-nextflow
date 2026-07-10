#!/usr/bin/env nextflow
/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    GenomeChronicler-nf
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    DSL2 Nextflow pipeline for running PGP-UK GenomeChronicler
    (https://github.com/PGP-UK/GenomeChronicler)

    Generates personal genome reports from BAM or gVCF files,
    including ancestry analysis, genotype tables, and a PDF report.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

nextflow.enable.dsl = 2

include { GENOMECHRONICLER } from './workflows/genomechronicler'

workflow {

    // Validate mandatory parameters
    if (!params.input) {
        error "ERROR: --input samplesheet not specified. Please provide a CSV samplesheet."
    }

    log.info """\

    ╔═══════════════════════════════════════════════════╗
    ║       GenomeChronicler - NF   P I P E L I N E    ║
    ╠═══════════════════════════════════════════════════╣
    ║  input        : ${params.input}
    ║  outdir       : ${params.outdir}
    ║  threads      : ${params.threads}
    ║  container    : ${params.gc_container}
    ╚═══════════════════════════════════════════════════╝
    """.stripIndent()

    GENOMECHRONICLER ()
}


