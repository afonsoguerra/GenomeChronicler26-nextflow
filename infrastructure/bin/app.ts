#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { GenomeChroniclerStack } from '../lib/genome-chronicler-stack';

const app = new cdk.App();

const bucketPrefix = app.node.tryGetContext('bucketPrefix') ?? 'genomechronicler-test';

new GenomeChroniclerStack(app, 'GenomeChroniclerTestStack', {
  bucketPrefix,
  description: 'GenomeChronicler-nf test deployment: AWS Batch + S3 + VPC infrastructure for running the Nextflow genomics pipeline',
});
