# Security policy

docling-batch-extract is a side project I maintain part-time. I take security reports seriously, because the documents it processes are often confidential.

## Supported versions

Only the latest release gets fixes. Right now that's **0.1.x**.

## Reporting a vulnerability

Please report it privately, not in a public issue:

1. Open the repository's **Security** tab and choose **Report a vulnerability** (GitHub private vulnerability reporting).
2. Describe what you found, which version and Ubuntu release you used, and the steps to reproduce it.

**Never attach real documents** or text extracted from them, yours or anyone else's. If a PDF is needed to show the problem, build a synthetic one with `tests/make_test_pdfs.py` or use the demo file in `scripts/demo-files/`.

I aim to reply within a week. If the report is confirmed, I'll fix it in a patch release, credit you in the release notes unless you'd rather stay anonymous, and publish an advisory once the fix is out.

## Scope

In scope: `extract.py`, the scripts in `scripts/` and `tests/`, `docker-compose.yml` and the setup it performs.

Out of scope: docling-serve and docling themselves. Report those to the [docling project](https://github.com/docling-project/docling-serve/security). If the problem only affects this project's way of running them (for example, a configuration that exposes the server), report it here.

## How the project is meant to be run

Most risk comes from running it differently from the design, so these are worth checking first:

- **docling-serve has no authentication.** `docker-compose.yml` publishes it on `127.0.0.1:5001` only. Acceptance check A25 and `scripts/demo_run.sh` fail if it's published anywhere else. Never open port 5001 in a firewall or security group.
- **Documents stay on the server.** Nothing is sent to an external service. Inputs, outputs and logs live in local folders that git ignores.
- **Setup runs as a normal user**, not root, on Ubuntu 26.04 LTS only.

The README's *Production security on AWS* section covers disk encryption, network access and how to reach the server without opening ports.
