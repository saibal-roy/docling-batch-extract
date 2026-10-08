---
hide:
  - navigation
  - toc
---

# Batch PDF → Markdown for RAG, on one CPU-only server

**docling-batch-extract** turns folders of PDFs (including scanned legal and claims-insurance documents) into Markdown JSON for retrieval-augmented search. It runs unattended on a single **2 vCPU / 8 GB server with no GPU** (Ubuntu 26.04 LTS), using [docling-serve](https://github.com/docling-project/docling-serve). It's a low-cost alternative to cloud OCR APIs, and documents never leave your machine.

[Get started](guide.md#developer-machine-setup-macos--windows--linux-desktop){ .md-button .md-button--primary }
[First demo run](guide.md#quick-setup-on-ubuntu-recommended){ .md-button }
[How it was built](STORY.md){ .md-button }
[GitHub](https://github.com/saibal-roy/docling-batch-extract){ .md-button }

<div class="grid cards" markdown>

-   :material-scale-balance: **Pilot: ~23,500 pages**

    ---

    500 documents × ~47 pages. **~30–35 h and ~$3–3.5** of compute on one 2 vCPU / 8 GB VM (EC2 `m7i.large`), against **~$35** (text only) or **~$353** (with tables) on AWS Textract.

    Estimated from measured seconds per page; cloud prices as of October 2026. [Details](guide.md#pilot-batch-estimate-500-documents--47-pages)

-   :material-speedometer: **Measured, not guessed**

    ---

    **~5 s per page on 2 vCPU** (4.6–5.4 s, Apple M2 limited to 2 CPUs). Process memory peaks at **2.8 GiB** of the 6.5 GB limit. Every number lists the hardware it was measured on.

    [Throughput and memory](guide.md#throughput-measured-2-vcpu-target)

-   :material-check-decagram: **Tested end to end**

    ---

    18 acceptance checks: corrupt files, container restarts, server outages, memory throttling, loopback-only port. **Go-ahead gate:** the full operator workflow in a fresh **Ubuntu 26.04 LTS** container on a simulated **2 vCPU / 8 GB** server.

    [Validation results](tests/results/index.md)

-   :material-robot-outline: **Built with Claude, documented as it went**

    ---

    A real production requirement turned into a **reusable, tested open-source solution**: versioned plans, each decision backed by evidence, a go-ahead gate, and prompts to rebuild it. Built in one day.

    [Story](STORY.md) · [Design history](versions/index.md) · [Prompts](prompts.md)

</div>

## How it works

```text
inputs/*.pdf ──► extract.py ──► docling-serve (CPU container, 6.5 GB, 1 worker × 2 threads)
                   │   page ranges, max 2 in flight, paused above 75 % memory
                   ├─ success ─► outputs/<name>.json  +  PDF moved to completed/
                   ├─ bad PDF ─► errors/   (reason in the log)
                   └─ always ──► logs/<name>.log
```

- **Text PDFs** are split into 5-page ranges that convert in parallel. **Scans** are detected automatically, converted whole, and OCR'd by docling, because their embedded text layers are often garbled.
- **No input can stop a batch.** Corrupt files go to `errors/` with a reason. If the server restarts, lost work is resent. If the server goes down, unfinished files stay in `inputs/`.
- **One log per document** with page count, timing and memory, for monitoring and audit.

## Quick start

```bash
git clone https://github.com/saibal-roy/docling-batch-extract.git
cd docling-batch-extract
scripts/setup_ubuntu.sh        # Ubuntu 26.04 LTS: Docker, venv, sizing (.env), container, cron
scripts/demo_run.sh            # environment checks + a benchmark for this machine
cp ~/your-pdfs/*.pdf inputs/ && .venv/bin/python extract.py
```

Validated on **2 vCPU / 8 GB**. **On AWS:** EC2 `m7i.large` (~$0.10/hour; stop it between batches), or `t3.large` for small batches. See [Deploying on AWS EC2](guide.md#deploying-on-aws-ec2).
Developer machine (macOS / Windows / Linux desktop): see the [Guide](guide.md#developer-machine-setup-macos--windows--linux-desktop).

## What we learned

| Finding | Decision |
|---------|----------|
| docling's default PDF reader used **6.35 GB on one page** of a JBIG2-compressed scan | Use `pypdfium2`: 19 s, 2.6 GB |
| Scanners' text layers run words together | Force docling's own OCR on scans: cleaner **and** faster |
| The service doesn't answer while converting; resending on timeout caused out-of-memory crashes | Resend only when the container actually restarted |
| Splitting scans into ranges raised peak memory | Convert scans whole |
| Laptop benchmarks varied by ~35 % between identical runs | Only differences larger than that are claimed |
| docling v1.36.0 is ~20–25 % faster on scans but ~45–80 % slower on text PDFs than v1.30.0 (2 vCPU) | v1.36.0 for scan-heavy legal and claims batches; regression recorded for future upgrades |
| `docker stats` reported the 6.35 GiB limit; real process memory peaked at 2.8 GiB | Measure cgroup `anon` memory: 8 GB is enough |

More in the [Guide's test results](guide.md#findings-that-shaped-the-design) and the [design history](versions/index.md).

**What's next:** many small servers sharing one queue of documents in Amazon S3 through **S3 Files** (NFS). A [proposal](versions/proposal-s3-files-inputs.md) weighs it against EBS, the S3 API and Mountpoint, and sets out when it's worth building.

**Publish your own copy:** fork it, check your GitHub account with `scripts/check_github_pages.sh`, and follow [Publishing the documentation site](guide.md#publishing-the-documentation-site-github-pages).
