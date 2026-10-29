# Scan results

`results.csv` lists every finding from both scanners on the original `main.tf` and on the fixed one (`FAIL` = reported, `-` = not reported).

| | Checkov 3.3.30 | Trivy 0.76.1 |
|---|---|---|
| Original | 59 failed, 79 passed | 37 |
| Fixed | 52 failed | 25 |

Reproduce (the original is the first commit of `main.tf`):

```bash
mkdir -p /tmp/orig && git show $(git rev-list --max-parents=0 HEAD):main.tf > /tmp/orig/main.tf
checkov -d /tmp/orig --framework terraform --compact --quiet
trivy config /tmp/orig
checkov -d . --framework terraform --compact --quiet && trivy config .
```

Caution when reading the "fixed" column: both scanners skip an IAM policy that contains references they can't resolve, and Trivy drops `AWS-0345` once any S3 deny is attached to a role. Neither means the wildcards are gone. See `FINDINGS.md`, "What the scanners did".
