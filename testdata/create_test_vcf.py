import random
random.seed(42)

# Read some SNP positions from the reference BED
snps = []
# We'll create fake positions on chr1-chr22
for chrom in range(1, 23):
    for pos in range(10000, 10100, 10):
        ref = random.choice(['A', 'C', 'G', 'T'])
        alts = [b for b in ['A', 'C', 'G', 'T'] if b != ref]
        alt = random.choice(alts)
        gt = random.choice(['0/0', '0/1', '1/1'])
        snps.append((str(chrom), pos, ref, alt, gt))

with open('testdata/test_sample.g.vcf', 'w') as f:
    f.write('##fileformat=VCFv4.2
')
    f.write('##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">
')
    f.write('##FORMAT=<ID=DP,Number=1,Type=Integer,Description="Read depth">
')
    f.write('##FORMAT=<ID=GQ,Number=1,Type=Integer,Description="Genotype quality">
')
    f.write('##contig=<ID=1,length=248956422>
')
    for i in range(2, 23):
        f.write(f'##contig=<ID={i},length=100000000>
')
    f.write('#CHROM	POS	ID	REF	ALT	QUAL	FILTER	INFO	FORMAT	test_sample
')
    for chrom, pos, ref, alt, gt in snps:
        dp = random.randint(20, 50)
        gq = random.randint(30, 99)
        f.write(f'{chrom}	{pos}	.	{ref}	{alt}	{gq}	PASS	.	GT:DP:GQ	{gt}:{dp}:{gq}
')
    
print(f"Created VCF with {len(snps)} variants")
