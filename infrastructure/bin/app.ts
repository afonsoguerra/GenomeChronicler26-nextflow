#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { NextflowBatchStack } from '../lib/nextflow-batch-stack';

const app = new cdk.App();

new NextflowBatchStack(app, 'NextflowBatchHelloStack', {
  description: 'Minimal Nextflow + AWS Batch infrastructure for hello-world testing',
});
