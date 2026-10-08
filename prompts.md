# Prompts

Prompts for building, running, maintaining and extending this solution with Claude (Claude Code or any coding agent).

The original build took many small requests, and several decisions only came out of testing on real documents and real hardware limits. These prompts put **the current validated design** up front, so a fresh build reaches it directly. The reasoning and evidence behind each decision are in [`versions/`](versions/) (plan-v1 → plan-v7), and the story is in [`STORY.md`](STORY.md). The build prompts and the reusable template are also published, with the approach behind them (real production requirements → reusable, cost-effective and reliable business solutions), on [saibal-roy.github.io](https://github.com/saibal-roy/saibal-roy.github.io/blob/main/prompts.md).

**Validated baseline these prompts describe** (go-ahead gate passed 2026-10-08):

| Area | Validated choice |
|------|------------------|
| Target machine | **2 vCPU / 8 GB RAM**, CPU only, no GPU |
| OS | **Ubuntu 26.04 LTS only**: the latest LTS; setup refuses others without `--force` |
| Engine | `docling-serve-cpu` **v1.36.0** (pinned), **1 worker × 2 threads**, ~6.5 GB limit, sized through `.env` |
| Security | API published on **127.0.0.1 only** (check A25); never open port 5001; no stored cloud keys |
| Dependencies | Latest LTS where one exists, otherwise the latest stable release, **always pinned**; upgraded only through the gate |
| Release | Semantic versioning from 0.1.0; `extractor_version` + `engine` in every JSON |
| Gate | `tests/ubuntu_container_test.sh`: Ubuntu 26.04 on a simulated 2 vCPU / 8 GB server, 18 acceptance checks |

| Part | Use it to |
|------|-----------|
| 1 — Build from scratch | Rebuild this tool with every validated decision built in |
| 2 — Operate and manage | Set up servers (incl. AWS EC2), the first demo run, pilot batches, day-to-day checks |
| 3 — Maintain | Upgrades (docling, Ubuntu LTS, packages), re-sizing, security reviews, releases |
| 4 — Explore and investigate | Diagnose slow or failing documents, compare quality and performance |
| 5 — Improve and extend | Page citations, RAG chunking, scale-out, S3 Files inputs, watch mode |
| 6 — Landing page and user site | Build, preview (both addresses) and maintain the GitHub Pages sites |
| 7 — Reusable template | Start **any** similar open-source tool with the same working method |
| 8 — Keeping this file current | Update prompts.md, STORY.md and the plans after every validated change |

How to use them:
- Run the Part 1 prompts in order, in a new empty folder, and review each result before moving on.
- Text in `<angle brackets>` is for you to fill in.
- Never paste client documents or their text into a prompt. Refer to them by path on your own machine, and keep them in git-ignored folders.
- Don't let the agent commit, push or create repositories unless you ask. Publishing stays your decision.

---

## Part 1 — Build from scratch

### 1.1 Context and plan

```text
I'm building a batch pipeline that converts PDFs (legal and claims-insurance documents, many scanned) into
Markdown for a RAG search index. It has to be a cost-effective alternative to cloud OCR APIs such
as AWS Textract or vision-LLM APIs. Target machine: 2 vCPU / 8 GB RAM, CPU only, no GPU, running
Ubuntu 26.04 LTS (only the latest Ubuntu LTS is supported). The pilot is about 500 documents
averaging about 47 pages. It's maintained part-time, so stability beats features: use the latest
LTS of everything that has one, otherwise the latest stable release, always pinned, and upgrade
only through the test gate.

Use docling-serve in Docker as the conversion engine: the CPU-only image
ghcr.io/docling-project/docling-serve-cpu pinned to an exact stable tag (never latest/main, never
a GPU variant). The container stays running between batches; the script must never start, stop
or restart it.

Before writing any code, write versions/plan-v1.md containing:
1. My requirements as a numbered list (E1, E2, …).
2. The design.
3. A table of acceptance criteria (A1, A2, …), each with a concrete check and a pass condition,
   mapped to the requirements.
4. A list of the defaults you chose that I might want to change.
Confirm the docling-serve API against http://localhost:5001/docs for the pinned version rather
than relying on memory. Whenever the plan changes, write a new plan-vN.md that starts with a
"Changes from vN-1" section (change → reason → evidence) and mark the old one superseded.
```

### 1.2 Container and sizing

```text
Write docker-compose.yml with a fixed project name (docling-batch-extract) for
docling-serve-cpu:${DOCLING_TAG:-v1.36.0}, container name docling_ocr_worker_cpu, restart: always,
UI disabled, local engine, 1 uvicorn worker. Publish the port on loopback only
("127.0.0.1:5001:5001"); the API has no authentication. Take sizing from .env with defaults for
the 2 vCPU / 8 GB target: DOCLING_SERVE_ENG_LOC_NUM_WORKERS=${DOCLING_WORKERS:-1}, threads
(DOCLING_NUM_THREADS / OMP_NUM_THREADS / MKL_NUM_THREADS)=${DOCLING_THREADS:-2}, memory limit
${DOCLING_MEMORY:-6500M}. Add a .env.example and git-ignore .env. Start it, wait for /health, and
report the image size, pull time and idle memory.
```

### 1.3 The extraction script

```text
Write extract.py: a single file using only the standard library plus requests and pypdf (pinned
to their latest stable versions in requirements.txt).

Folders and lifecycle
- Process inputs/*.pdf in sorted order. On success, write outputs/<stem>.json with source_file,
  status, pages, chunks, force_ocr, extractor_version, engine (docling_serve and docling versions
  from GET /version, pdf_backend), markdown, processing_time, errors and converted_at. Write it to
  a temp file and os.replace it, and only then move the PDF to completed/.
- A PDF that can't be converted (unreadable, docling error, retries used up) moves to errors/ and
  the run continues with the other files.
- If docling-serve itself goes down and doesn't come back, stop the run and leave the remaining
  PDFs in inputs/. A server outage must never be blamed on a document.
- inputs/ is the queue: running the script again processes only what is still there. The URL comes
  from --url or $DOCLING_URL (default http://localhost:5001).

Conversion
- Use the async API: POST /v1/convert/file/async with to_formats=md and page_range=[a, b], poll
  /v1/status/poll/{id}, then GET /v1/result/{id}. Treat success, partial_success, failure and
  skipped as finished states.
- Always send pdf_backend=pypdfium2. docling's default docling_parse used more than 6 GB on a single
  JBIG2-compressed scanned page and crashed the container.
- Detect scanned PDFs with pypdf: a page counts as scanned if it carries an image at least as wide
  as the page. If at least 50 % of pages are scanned, send force_ocr=true; scanners' embedded text
  layers are often garbled. Make this --ocr auto|force|default.
- Split text PDFs into 5-page ranges (--chunk-pages 5). Send scanned PDFs as one job
  (--scanned-chunk-pages 0); splitting scans raised peak memory.
- Queue the ranges in document order. --max-inflight defaults to the container's
  DOCLING_SERVE_ENG_LOC_NUM_WORKERS (read with docker inspect; fall back to 1), so client and server
  can't drift apart. A background thread reads container memory every 5 s, and new submissions
  pause above --mem-high 0.75; fall back to the in-flight limit if docker stats isn't available.

Robustness
- docling-serve stops answering HTTP while it converts. A poll timeout means "still busy, keep
  waiting", never "resubmit". Resubmit a range only if the container's RestartCount (docker inspect)
  changed or the task returns 404. Then wait for /health and retry, up to --retries 2.
- Allow --timeout 60 seconds per page for each job, with a minimum of 10 minutes.

Logging
- One log per PDF at logs/<stem>.log, replaced each time that PDF is processed, containing only
  that document's lines: DOC_START (pages, ranges, scanned %, force_ocr), SUBMIT, a PROGRESS
  heartbeat every 30 s, CHUNK_DONE, DOC_DONE (total seconds, pages, seconds per page) and
  DOC_FAILED / RETRY / ABORTED. The console shows the same lines tagged with the PDF name, plus
  RUN_START (incl. chunk sizes, version, docling version), THROTTLE and RUN_END. No cumulative log.

Exit codes: 0 all succeeded, 1 some PDFs failed, 2 server unreachable or down.

Versioning: semantic versioning from 0.1.0; __version__ in extract.py and --version. Define the
public contract (JSON schema, folders, options, exit codes, log lines) and the bump rules in
CHANGELOG.md (Keep a Changelog).
```

### 1.4 Tests, benchmarks and the go-ahead gate

```text
Create tests/ (pin reportlab in tests/requirements.txt):
- make_test_pdfs.py: text PDFs of 3, 5, 15 and 60 pages (headings, paragraphs, a table per page),
  a 20-page simulated scan (each page one full-page bitmap, no text layer), and a corrupt bad.pdf.
- measure_job.py: one job for a page range with any docling options; prints seconds and peak memory.
- run_acceptance.sh: every acceptance criterion as PASS/FAIL in an isolated tests/work/ directory
  (never the real folders): corrupt PDF, empty rerun, memory throttle, memory monitor unavailable,
  container restart mid-run, server down, one log per PDF, OCR only on scans, JSON schema incl.
  extractor_version/engine, and A25 "port published on 127.0.0.1 only". --bench-only runs
  per-PDF benchmarks after a warm-up job. Include PDFs from git-ignored tests/fixtures/.
- profile_benchmark.sh: recreate the container with --cpus/--workers/--threads/--memory/--tag,
  limit it with docker update --cpus, warm up, convert a fixed 95-page batch (text + scan), and
  record time, process memory (cgroup "anon", not docker stats, which counts reclaimable cache),
  memory-limit events and OOM kills. Restore the normal container afterwards.
- ubuntu_container_test.sh, the release gate: a fresh ubuntu:26.04 container pinned to 2 CPUs
  (--cpuset-cpus 0-1) against the host's Docker daemon (mounted socket,
  DOCLING_URL=host.docker.internal), as a non-root sudo user: setup_ubuntu.sh (must write the
  2 vCPU .env) → cap docling at 2 CPUs → checks → setup again → smoke test → cleanup.sh →
  demo_run.sh → run_acceptance.sh --quick. Pass the steps as an argument, give every step stdin
  from /dev/null, count a run as passed only if its log reaches a final marker line, and recreate
  the normal container afterwards.
- Everything must work with macOS's bash 3.2 and pass shellcheck -S warning.
Run them and fix anything that fails.
```

### 1.5 Documentation and open-source readiness

```text
Write the README for developers and operators: background, how it works, developer-machine and
Ubuntu 26.04 server setup, first demo run (with a real screenshot rendered from a gate run by
docs/render_demo_screenshot.py), operations, options, log format, server specification for the
validated 2 vCPU / 8 GB target, memory and throughput measured on that target, the pilot estimate
(pages × measured seconds per page) against cloud OCR pricing with sources and an "as of" date,
AWS EC2 deployment (m7i.large for batches; t3.large for small batches, with its burstable-credit
caveat; larger sizes marked "not validated"), production security on AWS (never open port 5001,
SSH from one IP or Session Manager, SSH tunnel for the API, IAM roles instead of keys, encrypted
EBS), the maintenance policy table of pinned versions, versioning and releases, publishing on
GitHub Pages, and test results. Use only measured numbers, always with the hardware they came from.
Update CLAUDE.md. Add an MIT LICENSE (copyright <name> (<github-url>)), a CHANGELOG.md, and
.gitignore rules: *.pdf (except licensed demo files), .env, .venv, tests/work, site output,
.claude/, plus a .gitignore inside each data folder (inputs, outputs, completed, errors, logs,
tests/fixtures) that keeps the folder but ignores its contents. Credit the author with links to
<website>, <LinkedIn> and <GitHub>. Finally, search the repository for client file names and
quoted document text, and remove them.
```

### 1.6 Continuous integration and releases

```text
Add .github/workflows/ci.yml (push to main, pull requests, manual, and workflow_call):
- Job 1 on ubuntu-26.04: fail if any PDF (other than licensed demo files listed in
  scripts/demo-files/README.md) or data-folder content is tracked; ruff with the committed
  ruff.toml (pinned ruff version); py_compile; shellcheck -S warning; docker compose config.
- Job 2 on ubuntu-26.04 only: free disk space; provision with scripts/setup_ubuntu.sh and check
  container, .env, venv, folders and cron; run setup again (one cron entry); remove the cron entry;
  smoke test (exit code 1 for a corrupt PDF); cleanup.sh; demo_run.sh; run_acceptance.sh --quick
  (--bench-only on manual runs with "benchmarks"). Put this run's summary in the job summary,
  upload it as an artifact, dump container logs on failure.
Add release.yml: tag vX.Y.Z → verify tag = __version__ = a dated CHANGELOG section → reuse ci.yml →
create the GitHub Release from that changelog section (relative links made absolute). Use the
latest major versions of actions/checkout, setup-python, upload-artifact, upload-pages-artifact
and deploy-pages. Validate with actionlint (declare ubuntu-26.04 in .github/actionlint.yaml if
your actionlint predates it).
```

---

## Part 2 — Operate and manage

### Server setup, sizing and cleanup scripts

```text
Write scripts/setup_ubuntu.sh for Ubuntu 26.04 LTS only (refuse other releases unless --force), run
as a non-root user with sudo, safe to run again: check CPUs, RAM and disk; install Docker Engine from
Docker's official apt repo, python3-venv, cron and flock; enable services only if systemd is
running; add the user to the docker group; create .venv and the data folders; write .env from the
machine (2 vCPU → 1 worker × 2 threads; more vCPUs → workers = vCPUs ÷ 2; memory = RAM − 1.5 GB;
keep an existing .env unless --resize); start the container and wait for /health ($DOCLING_URL);
install a marker-tagged cron entry; end with the "never open port 5001" reminder.
Also write scripts/cleanup.sh: list what it will remove and ask first; by default empty outputs/,
completed/, errors/ and logs/ but keep the folders, their .gitignore files, inputs/ and
tests/results/; flags --inputs, --results, --venv, --docker, --docker-image, --all, --dry-run, --yes.
Test cleanup on a temporary copy, never on real data.
```

### Deploy on AWS EC2

```text
Prepare an EC2 deployment for <documents/pages and deadline> on the validated 2 vCPU / 8 GB
target: m7i.large for sustained batches (not burstable), t3.large only for small or occasional
batches (burstable: baseline 30 % per vCPU; T3 Unlimited costs extra and ends up more expensive
than m7i.large at full load). Give me the exact launch settings: an Ubuntu 26.04 LTS AMI, 30 GB
encrypted gp3, an IAM role (no access keys), and a security group with SSH from my IP only (or
Session Manager) and NEVER an inbound rule for port 5001 (no authentication; use an SSH tunnel to
reach the API). I'll launch it myself; don't use any AWS credentials. On the instance run
scripts/setup_ubuntu.sh, then scripts/demo_run.sh, and report that instance's measured benchmark,
which replaces the Apple M2 estimate for planning. Remind me to stop the instance between batches.
```

### First demo run

```text
Run scripts/demo_run.sh on the newly deployed server. Explain any [FAIL] or [WARN] (OS release,
CPUs, RAM, Docker resources, loopback-only port, /health, venv, folders, empty inputs/) and how to
fix it. Report the machine's benchmark (s/page, pages/hour, peak memory, restarts) and what it
implies for the pilot deadline. Keep the report in logs/ only.
```

### Run a pilot batch

```text
Run the pilot batch on the server prepared with scripts/setup_ubuntu.sh, and record what really
happens:
1. Run scripts/demo_run.sh --clean-after first and stop if anything fails.
2. I'll upload the pilot PDFs to inputs/ over SFTP (or from S3 with the instance role). Run
   extract.py in tmux (not cron), and report progress from logs/ every hour: documents done,
   pages, sec/page, errors, memory.
3. At the end, report measured values only: document and page counts, total time, sec/page,
   scanned share (force_ocr=True in DOC_START lines), failures with reasons, container restarts,
   peak memory. Leave anything not measured as "not measured".
4. Never copy client documents, outputs or logs into the repository.
```

### Day-to-day

```text
Check the health of the extraction service: container status, /health, docling version, memory
against its limit, restart count, the port binding (127.0.0.1 only), and what's in inputs/,
completed/ and errors/. Summarise any PDFs in errors/ with the reason from each one's log.
```

```text
Summarise the last batch from logs/*.log: documents and pages processed, total and per-page time
(scanned vs text), the slowest five documents, any RETRY / THROTTLE / DOC_FAILED events, and
whether memory came close to the limit.
```

```text
<n> PDFs failed in errors/. For each, read its log and classify it as corrupt / encrypted /
timeout / server restart / other. Propose a fix per class, and move the ones that are likely to
succeed now back to inputs/. Don't modify the PDFs.
```

---

## Part 3 — Maintain

```text
Quarterly maintenance check (read-only first): compare every pin with the latest LTS / stable
release: Ubuntu LTS, docling-serve-cpu tags (stable vX.Y.Z only), requests, pypdf, reportlab,
ruff, mkdocs (stay on 1.x) / mkdocs-material, GitHub Actions majors, nginx:stable-alpine. Report
what's behind, what each upgrade could break, and propose an order. Change nothing until I agree.
```

```text
Upgrade docling-serve-cpu from <old> to <new> (a stable CPU tag, never latest/main or a GPU
variant): read the release notes for API changes; check the endpoints and parameters extract.py
uses against /docs; run tests/profile_benchmark.sh at 2 vCPU for 1×2 and 2×1 on <old> and <new>
(same batch, at least two runs each) and show me the text and scan times and process memory; if I
approve, set the tag, run tests/ubuntu_container_test.sh, and prepare a MINOR release whose notes
say the Markdown may change (re-index if needed). If anything fails, stay on <old> and report why.
```

```text
A new Ubuntu LTS (<version>) is out. Move setup_ubuntu.sh's supported release, the CI runners,
ubuntu_container_test.sh's default and the docs to it in one change; check Docker's apt repository
and GitHub's runner image support it first; run the gate on the new release; then update
prompts.md and the plans. Earlier results stay as history.
```

```text
Upgrade the Python packages and GitHub Actions to their latest stable versions: update the exact
pins (requirements.txt, tests/requirements.txt, CI's ruff, docs/requirements.txt within MkDocs 1.x,
action majors after checking their inputs/outputs still match our usage), run lint, the
acceptance suite and the gate, and write the change into CHANGELOG.md under the next version.
```

```text
Security review (read-only): confirm docker-compose.yml publishes 5001 on 127.0.0.1 only, A25
and demo_run.sh enforce it, the README forbids opening 5001, no credentials or client data are in
the repository or the built site (run the CI data guard and a search), and the pinned images and
packages have no known critical advisories. Report findings with evidence; fix nothing yet.
```

```text
Before I make this public (or publish a release), review what would ACTUALLY be published, not
what you remember, as a stranger, a client and a hiring manager would, with my reputation in mind
(<name>, <website>, <LinkedIn>, <GitHub>, public commit email <email>). All checks are read-only;
report first, then fix only what I approve.

0. Dry run: copy each repository folder (including .claude/, generated sites, data folders) to a
   throwaway directory, git init + git add -A + commit there with my name and email, and review
   that staged set. Delete the copy afterwards; never touch the real folders.
1. Personal data and local paths: email addresses other than <email>, my machine username, home or
   temp folder paths (/Users/…, /private/tmp/…), phone numbers, internal hostnames.
2. Secrets and client data: tokens and keys (gh*_, AKIA…, private keys, passwords), client or
   partner names, client file names, quoted document text, anything from .claude/, .env, logs or
   data folders. Data folders may contain only their own .gitignore; the only PDFs allowed are
   licensed demo files listed with their license.
3. Size and noise: file count, total size and the largest files; flag bloated or noisy content
   (raw test logs, apt output, screenshots heavier than needed) and suggest trimming only where it
   hurts readability or clone time.
4. Claims: every number measured and labelled with hardware and date; estimates labelled as
   estimates; prices sourced with an "as of" date; nothing claimed that wasn't run (e.g. a cloud
   pilot); no stale facts that contradict the validated state; no overstated titles or timelines;
   no invented figures. Tone: I set requirements and made the decisions, the AI executed; no
   claims that belittle engineers or other projects (state third-party trade-offs neutrally).
5. The first CI run: anything never run on GitHub yet is a risk. Check what the runner differs in
   (CPU architecture, CPU count, RAM, disk, Ubuntu image, preinstalled tools) and look for tests
   whose thresholds assume my machine (e.g. a memory threshold as a fraction of a limit that the
   runner sizes differently) and for steps that need credentials or interactive input.
6. Publishing mechanics: git push credentials (is a credential helper set up for HTTPS?), branch
   name, remotes, Pages source settings, and that commits will carry no co-author or AI trailer
   (author and committer = me).
7. Confidentiality judgement: does the public story reveal anything a client agreement might cover
   (identity, engagement, timelines, volumes)? Generalise the domain if in doubt and ask me.
Then classify each finding as "fix before publishing" or "can wait", with a one-line reason; after
any fix, re-run lint, tests, the site build and crawl, and this audit.
```

```text
Prepare release vX.Y.Z following CHANGELOG.md's versioning policy: classify every change since
the last tag against the public contract (JSON schema, folders, options, exit codes, log lines) as
MAJOR / MINOR / PATCH and propose the version; move the entries under a dated
"## [X.Y.Z] - YYYY-MM-DD" heading; set __version__ in extract.py; then run the release check:
CI green on Ubuntu 26.04, the gate passed, README / STORY.md / landing page numbers agree, a plan
for every behaviour change, no client identifiers anywhere (repo and built site). List anything
that fails. Don't tag or push: I'll do that.
```

---

## Part 4 — Explore and investigate

```text
<pdf> is slow or crashes the container. Using tests/measure_job.py, measure 1 page and 5 pages
with pdf_backend pypdfium2 vs docling_parse, with force_ocr true vs false, and with images_scale
1.0 vs 2.0. Report time, peak process memory and output quality (show a short excerpt). Don't
change extract.py until we've agreed on a fix.
```

```text
Compare the Markdown quality of <pdf> under --ocr auto vs force vs default: word spacing, table
structure, headings, and how stamps and signatures come out. Recommend a mode for this document
type, with evidence.
```

```text
Is a different server size worth it for <workload>? Run tests/profile_benchmark.sh for
<cpus>/<workers>/<threads> against the validated 2 vCPU 1×2 baseline (two runs each), and report
cost per 1,000 pages with current on-demand prices (with an "as of" date). Mark anything other
than 2 vCPU / 8 GB as not validated unless the gate is run on it.
```

```text
Explore the docling-serve options in /docs that could improve legal and claims documents for RAG (e.g.
table_mode, do_pdf_heading_hierarchy, md_page_break_placeholder, ocr_lang, chunking endpoints).
For each, state the expected benefit and the memory/time cost on 2 vCPU, and propose a benchmark.
```

---

## Part 5 — Improve and extend

Each of these produces a new `versions/plan-vN.md` (or a `proposal-*.md`) before any code is written, and goes through the gate before it ships.

```text
Add page markers to the Markdown (docling's md_page_break_placeholder) and store a per-page list
in the JSON, so RAG chunks can cite page numbers. Keep backwards compatibility (a MINOR release).
```

```text
Add RAG-ready chunking: call docling's hybrid chunker endpoint and store chunks with their heading
path and page numbers alongside the Markdown. Benchmark the extra time and memory on 2 vCPU.
```

```text
Scale out: given <N> documents per day and a deadline of <hours>, size the deployment as several
identical 2 vCPU / 8 GB servers (the validated size) and compare with one larger, unvalidated VM.
If servers share one inputs/, design claiming by atomic rename so no PDF is processed twice.
```

```text
Evaluate versions/proposal-s3-files-inputs.md (Amazon S3 Files as an optional input provider) as a
new plan version, without changing the default. Build a cost model for 10k / 100k / 1M documents
with current AWS prices (S3, S3 Files, EBS gp3, requests) and an "as of" date. Run
tests/profile_benchmark.sh with the folders on an S3 Files mount and on EBS, on the same
2 vCPU / 8 GB instance. Prototype claiming files by atomic rename into processing/<server-id>/ with
two servers on one queue, and add an acceptance check: no document processed twice, none lost.
Recommend go or no-go against the proposal's triggers. Local disk stays the default.
```

```text
Detect scanned pages per page instead of per document, and OCR only the scanned pages of mixed
PDFs. Measure the effect on a mixed document.
```

```text
Add a --watch mode that processes new PDFs as they arrive (ignoring partial uploads such as
*.part) as an alternative to cron, and a systemd unit to run it.
```

---

## Part 6 — Landing page and user site (GitHub Pages)

Plan: [`versions/landing-page-plan-v2.md`](versions/landing-page-plan-v2.md).

```text
Build the project site from versions/landing-page-plan-v2.md: MkDocs 1.x + Material (pinned),
docs/index.md as a custom landing page (problem, cost comparison, how it works, headline measured
numbers for the 2 vCPU / 8 GB target, what's next, buttons for Get started / First demo run /
Story / GitHub), system fonts, no CDN-loaded JavaScript, accessible link and contrast styles.
scripts/build_site.py assembles the site source from the repository's own Markdown in the same
folder layout (relative links keep working; folder links point at their index page); a MkDocs hook
points links to code and scripts at GitHub. GitHub-style heading anchors so README #links work.
Add .github/workflows/pages.yml that runs on every push to main (build --strict → crawl →
deploy-pages). Target Lighthouse ≥ 90
for performance and accessibility on phone and laptop.
```

```text
Create the GitHub Pages user site as a separate repository folder next to this one
(../<user>.github.io): a single static index.html (no build step, light/dark, mobile-friendly,
inline favicon) with my name, links to <website>, <LinkedIn> and <GitHub>, a card per project
linking to its documentation site and source, a README with publishing steps, .nojekyll, and
.github/workflows/pages.yml that on every push to main stages index.html, crawls its links with
scripts/check_site.py (--ignore docling-batch-extract/: project sites deploy from their own
repositories), then deploys with deploy-pages. Don't invent a bio; leave a marked place for my
own introduction.
```

```text
Preview both addresses exactly as GitHub Pages will serve them, before anything is published:
run scripts/preview_site.sh (user site from ../<user>.github.io at http://localhost:8080/, this
project at http://localhost:8080/docling-batch-extract/, nginx:stable-alpine with compression),
crawl both for broken links, anchors and assets, run Lighthouse on both home pages, and show me
screenshots at 375 px and 1280 px.
```

```text
Check (read-only, change nothing) whether my GitHub account is ready to publish both sites: run
scripts/check_github_pages.sh, explain every [TODO], and list what I need to do in the web
settings (verified email, public repositories, Pages source "GitHub Actions" for both
repositories, custom-domain implications). Don't create
repositories, push, or change settings yourself.
```

```text
The site and the repository have drifted, or a release changed the numbers: rebuild and preview
both sites with scripts/preview_site.sh, list every page whose source changed since the last
deploy, check that the landing page's headline numbers match the README and STORY.md, and fix any
mismatch at the source, never in the generated site.
```

---

## Part 7 — Reusable template for any solution like this

Use this as the **first prompt** for a new open-source tool built with Claude, for a client or not. It builds in the working method that made this project fast and safe: requirement IDs, versioned plans, evidence-based decisions, real-data testing early, sizing for cost on measured numbers, client-data protection, security by default, and CI from day one.

```text
You are acting as the engineering manager and lead engineer for a new open-source tool.

Context
- Problem: <what is slow, expensive or manual today, and for whom>
- Business constraint: <budget / cost per unit, data confidentiality, deadline>
- Target machine and platform: <e.g. 2 vCPU / 8 GB, CPU only, latest Ubuntu LTS only>
- Scale for the first real run: <e.g. N documents × M pages>
- Alternatives being replaced and their cost: <e.g. a cloud API at $X per unit>
- Engine or library to build on: <e.g. docling-serve-cpu, exact stable tag>
- Maintenance reality: <e.g. part-time maintainer → stability over features>
- License and owner: <MIT, name, website / LinkedIn / GitHub>

Working method (follow strictly)
1. Before any code, write versions/plan-v1.md: my requirements as E1…En, a design, acceptance
   criteria A1…An (concrete check + pass condition, mapped to requirements), and the defaults you
   chose. Ask me only questions whose answers change the design; when a choice is a trade-off,
   show me the measured numbers and let me decide.
2. Verify every external API, price and product claim against the real service or its current
   docs; never rely on memory. Cite prices with an "as of" date.
3. Within the first hour, run the design on ONE real input I provide (by path, never pasted).
   Measure time and real process memory per unit of work, and read the actual output.
4. Each time a requirement is added or evidence contradicts the plan, write plan-vN+1.md starting
   with "Changes from vN" (change → reason → evidence) and mark the old one superseded.
5. Build: minimal, pinned dependencies (latest LTS / stable); one obvious entry point; no input
   ever stops the batch; per-item logs; idempotent reruns; "busy" is not "down"; services bound to
   localhost unless they must be public; no stored credentials.
6. Tests: synthetic inputs with the real input's hard properties (no client data in tests), a
   PASS/FAIL acceptance script in an isolated directory, a profile benchmark for the target
   machine with repeated runs, and a go-ahead gate that rehearses a fresh server on the supported
   OS and target size. A gate passes only on an explicit final marker. Publish failed checks.
7. Client data: per-folder .gitignore files, a CI data guard, and a repository search for client
   identifiers before any release.
8. Ship: README (background, how it works, setup, operations, spec and capacity from measured
   numbers, cost comparison, security, maintenance policy, versioning, troubleshooting, test
   results), LICENSE, CHANGELOG (semantic versioning with a defined public contract), CLAUDE.md,
   setup / demo / cleanup scripts, CI + release workflows, a documentation site checked locally
   before publishing, and a prompts.md that rebuilds the validated design.
9. Keep STORY.md: a timeline with real times, what was caught and how, the system-thinking
   principles, and results tables that say "pending" until real numbers exist.
10. Before anything goes public, run a pre-publish review: what exactly is published, privacy
    and secrets, credibility of every claim, tone, first impressions, client confidentiality.
11. Don't commit, push or publish unless I ask.
Start with step 1.
```

---

## Part 8 — Keeping this file current

```text
We just finished <change> and the gate passed. Update prompts.md so a fresh build reaches today's
validated design directly: fold the decision into the relevant Part 1 prompt and the baseline
table (as a requirement, not as history), update the operate / maintain / site prompts it affects,
and keep the history itself in versions/. Then add the change to STORY.md's timeline with its real
time and evidence, and update CHANGELOG.md under the next version. Only include what was
validated; don't add numbers that weren't measured.
```
