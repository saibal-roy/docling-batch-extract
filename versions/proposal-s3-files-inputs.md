# Proposal: Amazon S3 (via S3 Files) as an optional input provider

**Status:** Proposal for discussion, **not implemented**. It is part of the design thinking for the next stage of the solution. Local disk (EBS) stays the default and the only validated option.
**Author:** Saibal Roy · **Date:** 2026-10-08

## 1. Business context

The solution exists to make document extraction **cheap enough to run at pilot scale and beyond** on small CPU servers (2 vCPU / 8 GB). Today, documents must first be copied onto the server's disk (EBS), and every server has its own `inputs/`, `outputs/`, `completed/` and `errors/`. That works for a pilot of about 500 documents. It strains as the business grows:

| Growth step | What breaks with local disk only |
|-------------|----------------------------------|
| **Many files** (tens of thousands of documents, several archives) | EBS has to be sized, and paid for, ahead of the largest batch. Copying documents to each server is a manual step |
| **More than one server** (the validated way to scale is more 2 vCPU servers) | Each server has its own folders. Documents must be split up by hand, and results collected from several disks |
| **Documents already in S3** (common for products built on AWS) | Duplicate storage: S3 copy + EBS copy, plus the transfer step |

## 2. The idea

Keep the extractor's file-based workflow unchanged, but let `inputs/` (and optionally `outputs/`, `completed/`, `errors/`) live **in an S3 bucket mounted as a file system with Amazon S3 Files**.

Amazon S3 Files (generally available since April 2026) exposes a general-purpose S3 bucket as a **shared NFS v4.1+ file system**: POSIX operations, close-to-open consistency, about 1 ms latency for active data (EFS-backed), mountable from EC2, ECS, EKS and Lambda. The same objects stay reachable through the S3 API. ([The New Stack](https://thenewstack.io/aws-s3-files-filesystem), [StorageNewsletter](https://www.storagenewsletter.com/2026/04/09/aws-launches-s3-files-making-s3-buckets-accessible-as-file-systems/))

```
            Upload (S3 API, console, other systems)
                          │
                 ┌────────▼─────────┐
                 │   S3 bucket      │  inputs/  outputs/  completed/  errors/
                 └────────┬─────────┘
                    S3 Files (NFS)
          ┌───────────────┼───────────────┐
   2 vCPU server A   2 vCPU server B   2 vCPU server C     ← identical, each runs docling + extract.py
   (claims a PDF, converts it, writes JSON, moves the PDF)
```

**Why it fits this design:**
- **Minimal change.** `extract.py` already works on folders. With a mount, `--input /mnt/s3files/inputs` mostly just works, which keeps the code small and the maintenance part-time.
- **Scale-out without coordination servers.** Several identical 2 vCPU servers can share one queue, with no message broker to run.
- **Storage paid by use.** No pre-sized EBS volume per server for documents. EBS shrinks to the OS and the docling image.
- **Documents already in S3 stay there.** No duplicate copy.

## 3. Options considered

| Option | For | Against | Verdict |
|--------|-----|---------|---------|
| **Local EBS (today)** | Simplest; validated; fastest file I/O | Pre-sized per server; manual copy; no sharing between servers | Keep as the default |
| **Pull/push with the S3 API** (boto3 in `extract.py`) | Precise control; plain S3 pricing | New code paths (download, upload, retries, claiming); the "folders are the state" model has to be rebuilt in code | More code to maintain part-time |
| **Mountpoint for Amazon S3** (FUSE) | Free client; good for sequential reads | Limited write and rename semantics: moving PDFs between folders, temp-file-then-rename JSON writes and locks don't map well | Doesn't fit the folder-state model |
| **Amazon S3 Files (NFS)** | POSIX semantics (rename, locks) suit the folder model; shared across servers; the S3 API still works for uploads and integrations | Newer service; EFS-backed pricing for active data; NFS consistency and rename cost must be tested | **Preferred candidate, to validate** |
| **Amazon EFS directly** | Mature shared NFS | Data isn't in S3, so other systems can't use it directly; storage cost | Fallback if S3 Files doesn't fit |

## 4. Design sketch (if adopted)

1. **Provider stays a path.** Add `--storage local|s3files` only for checks and documentation. The behaviour change is pointing the folders at the mount (`/mnt/s3files/...`). Local disk stays the default.
2. **Claiming files across servers.** Before converting, a server renames `inputs/x.pdf` to `processing/<server-id>/x.pdf`. On a POSIX file system that rename is atomic, so exactly one server wins and the others skip the file. A server that dies leaves its claim behind; a sweep moves claims older than N hours back to `inputs/`.
3. **Write path unchanged.** Write `outputs/<name>.json.tmp` and then rename it. Move the PDF only after the JSON exists. Per-document logs could stay on local disk, with one summary per document written to the bucket.
4. **Setup.** `setup_ubuntu.sh --s3files <file-system-id>` would install the NFS client, add the mount to `/etc/fstab` with TLS, and check access. The instance gets an **IAM role**, with no access keys stored.
5. **Security.**
   - The bucket stays private.
   - S3 Files mount targets live in the VPC.
   - Security-group rules allow NFS only from the extractor servers.
   - Encryption at rest (SSE-KMS) and in transit (TLS).
   - **Port 5001 stays loopback-only**, exactly as today.
   - Client documents never leave the AWS account.

## 5. Risks and open questions

| Risk / question | How to find out |
|-----------------|-----------------|
| **Cost at scale.** Is S3 storage plus S3 Files' charges for active data and requests really cheaper than EBS for this workload? | Model it with current AWS pricing for 10k / 100k / 1M documents, and measure actual request counts per document |
| **Throughput.** Does NFS latency slow the extractor? | `tests/profile_benchmark.sh` with the folders on an S3 Files mount, compared with EBS on the same 2 vCPU instance |
| **Rename and lock semantics** across servers (claiming, temp-file renames) | A new acceptance check: two servers, one queue, no document processed twice, none lost |
| **Large PDFs** (hundreds of MB) on first read | Benchmark with large real scans |
| **Operational complexity** for a part-time maintainer | Count new moving parts: mount, IAM, VPC endpoints, KMS. Prefer zero new code paths |

## 6. When to build it (triggers)

Build this only when at least one of these is true:
- Batches regularly exceed what one 2 vCPU server finishes within the deadline, so several servers are needed.
- The document archive already lives in S3 and copying it to EBS is a recurring chore.
- EBS sized for peak batches costs measurably more than the S3 Files model from §5.

## 7. How it would be validated (same gate as everything else)

1. Write a plan version with requirements and acceptance checks (including "no double processing across 2 servers").
2. Measure: `tests/profile_benchmark.sh` on EBS against S3 Files on the 2 vCPU / 8 GB target. Use a cost model from current AWS prices with an "as of" date.
3. Extend the go-ahead gate with an S3 Files mount, two servers and one queue. Ship it as a **MINOR** release with local disk still the default.
