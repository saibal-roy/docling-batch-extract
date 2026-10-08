"""Convert PDFs in inputs/ to Markdown via a running docling-serve container.

Each PDF is split into page-range chunks that are converted in parallel, throttled
by the container's memory usage. Results go to outputs/<stem>.json, finished PDFs
move to completed/, and each PDF gets its own log at logs/<stem>.log.
See versions/plan-v6.md.
"""
import argparse
import json
import logging
import os
import re
import subprocess
import sys
import threading
import time
from collections import deque
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from datetime import datetime, timezone
from pathlib import Path

import requests
from pypdf import PdfReader

__version__ = "0.1.0"  # semantic version of the extractor; see CHANGELOG.md
FMT = logging.Formatter("%(asctime)s %(message)s", "%Y-%m-%dT%H:%M:%S")
UNITS = {"B": 1, "KiB": 2**10, "MiB": 2**20, "GiB": 2**30, "kB": 1e3, "MB": 1e6, "GB": 1e9}
DONE_STATES = ("success", "partial_success", "failure", "skipped")

# Run-level lines go to the console only; per-document lines go to the console and logs/<stem>.log.
class ConsoleFormatter(logging.Formatter):
    """Console lines name the document; the per-document log files don't need to."""

    def format(self, record):
        line = FMT.format(record)
        if record.name.startswith("extract.doc."):
            ts, msg = line.split(" ", 1)
            line = f"{ts} [{record.name[len('extract.doc.'):]}] {msg}"
        return line


console = logging.StreamHandler()
console.setFormatter(ConsoleFormatter())
run_log = logging.getLogger("extract")
run_log.addHandler(console)
run_log.setLevel(logging.INFO)
logging.getLogger("pypdf").setLevel(logging.ERROR)  # malformed PDFs are reported via DOC_FAILED


class ContainerRestarted(Exception):
    pass


class ServerDown(Exception):
    """docling-serve stayed unreachable: not the document's fault, so the run stops."""


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    p.add_argument("--input", default="inputs")
    p.add_argument("--output", default="outputs")
    p.add_argument("--completed", default="completed")
    p.add_argument("--errors", default="errors", help="PDFs that failed to convert are moved here")
    p.add_argument("--logs", default="logs", help="directory for per-document logs")
    p.add_argument("--url", default=os.environ.get("DOCLING_URL", "http://localhost:5001"),
                   help="docling-serve address (default: $DOCLING_URL or http://localhost:5001)")
    p.add_argument("--max-inflight", type=int, help="default: the container's DOCLING_SERVE_ENG_LOC_NUM_WORKERS")
    p.add_argument("--chunk-pages", type=int, default=5, help="page-range size for text PDFs; 0 = whole PDF")
    p.add_argument("--scanned-chunk-pages", type=int, default=0,
                   help="page-range size for scanned PDFs; 0 = whole PDF (parallel OCR jobs were slower)")
    p.add_argument("--mem-high", type=float, default=0.75, help="pause submissions above this memory fraction")
    p.add_argument("--container", default="docling_ocr_worker_cpu")
    p.add_argument("--pdf-backend", default="pypdfium2",
                   help="docling's default (docling_parse) exhausted memory on JBIG2-scanned PDFs")
    p.add_argument("--ocr", choices=("auto", "force", "default"), default="auto",
                   help="auto: force OCR on scanned PDFs (their embedded text layer is often garbled)")
    p.add_argument("--retries", type=int, default=2)
    p.add_argument("--heartbeat", type=int, default=30, help="seconds between PROGRESS lines")
    p.add_argument("--timeout", type=int, default=60, help="max seconds per page of a chunk (min 10 min)")
    return p.parse_args()


def doc_logger(logs_dir, pdf):
    """A logger writing only this document's events to logs/<stem>.log (replaced on each run)."""
    lg = logging.getLogger(f"extract.doc.{pdf.stem}")
    for h in list(lg.handlers):
        lg.removeHandler(h)
        h.close()
    fh = logging.FileHandler(Path(logs_dir) / f"{pdf.stem}.log", mode="w")
    fh.setFormatter(FMT)
    lg.addHandler(fh)
    lg.setLevel(logging.INFO)
    return lg  # propagates to "extract" -> console


class MemoryMonitor(threading.Thread):
    """Polls `docker stats` for the container's memory; `fraction` is None if unavailable."""

    def __init__(self, container):
        super().__init__(daemon=True)
        self.container, self.used, self.limit = container, None, None

    def sample(self):
        out = subprocess.run(
            ["docker", "stats", "--no-stream", "--format", "{{.MemUsage}}", self.container],
            capture_output=True, text=True, timeout=15,
        )
        m = re.findall(r"([\d.]+)\s*([KMG]?i?B)", out.stdout)
        if out.returncode != 0 or len(m) != 2:
            raise RuntimeError(out.stderr.strip() or out.stdout.strip())
        self.used, self.limit = (float(v) * UNITS[u] for v, u in m)

    def run(self):
        while True:
            try:
                self.sample()
            except Exception:
                self.used = self.limit = None
            time.sleep(5)

    @property
    def fraction(self):
        return self.used / self.limit if self.used and self.limit else None

    def __str__(self):
        if self.fraction is None:
            return "n/a"
        return f"{self.used / 2**30:.1f}/{self.limit / 2**30:.1f}GiB"


def server_workers(container, fallback=1):
    """The container's conversion worker count: running more jobs than this only queues them."""
    try:
        out = subprocess.run(["docker", "inspect", "-f", "{{range .Config.Env}}{{println .}}{{end}}", container],
                             capture_output=True, text=True, timeout=15)
        return int(re.search(r"^DOCLING_SERVE_ENG_LOC_NUM_WORKERS=(\d+)$", out.stdout, re.M)[1])
    except Exception:
        return fallback


def restart_count(container):
    try:
        out = subprocess.run(["docker", "inspect", "-f", "{{.RestartCount}}", container],
                             capture_output=True, text=True, timeout=15)
        return out.stdout.strip() if out.returncode == 0 else "n/a"
    except Exception:
        return "n/a"


def wait_healthy(url, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if requests.get(f"{url}/health", timeout=10).ok:
                return True
        except requests.RequestException:
            pass
        time.sleep(3)
    return False


def convert_chunk(args, pdf, start, end, force_ocr):
    """Convert pages start..end (1-based, inclusive) of one PDF; returns Markdown.

    The server can be slow to answer while it is busy converting, so poll errors are
    tolerated; only a container restart (task lost) aborts the chunk for resubmission.
    """
    restarts = restart_count(args.container)
    with open(pdf, "rb") as f:
        r = requests.post(
            f"{args.url}/v1/convert/file/async",
            files={"files": (pdf.name, f, "application/pdf")},
            data={"to_formats": "md", "page_range": [start, end], "pdf_backend": args.pdf_backend,
                  "force_ocr": str(force_ocr).lower()},
            timeout=300,
        )
    r.raise_for_status()
    task_id = r.json()["task_id"]
    limit = max(600, (end - start + 1) * args.timeout)
    deadline = time.time() + limit
    while True:
        if time.time() > deadline:
            raise TimeoutError(f"task {task_id} not finished after {limit}s")
        try:
            s = requests.get(f"{args.url}/v1/status/poll/{task_id}", timeout=60)
            if s.status_code == 404:
                raise ContainerRestarted(f"task {task_id} unknown to server")
            s.raise_for_status()
            if s.json()["task_status"] in DONE_STATES:
                break
        except requests.RequestException as e:
            if restart_count(args.container) != restarts:
                raise ContainerRestarted("container restarted while converting") from e
        time.sleep(3)
    res = requests.get(f"{args.url}/v1/result/{task_id}", timeout=300)
    res.raise_for_status()
    body = res.json()
    if body.get("status") not in ("success", "partial_success"):
        raise RuntimeError(f"docling status={body.get('status')} errors={body.get('errors')}")
    return body["document"]["md_content"] or ""


def run_chunk(args, doc, idx):
    """One chunk with retries; after a container restart, wait for health and resubmit."""
    start, end = doc["chunks"][idx]
    for attempt in range(args.retries + 1):
        t0 = time.time()
        try:
            return convert_chunk(args, doc["pdf"], start, end, doc["force_ocr"]), time.time() - t0
        except Exception as e:
            if attempt == args.retries:
                raise
            doc["log"].info(f"RETRY       chunk={idx + 1}/{len(doc['chunks'])} pages={start}-{end} "
                            f"attempt={attempt + 1} error={e!r} restarts={restart_count(args.container)}")
            if not wait_healthy(args.url, timeout=600):
                raise ServerDown("docling-serve did not become healthy again") from e


def engine_versions(args):
    """Versions that produced the output, recorded in every JSON so it can be re-processed selectively."""
    engine = {"pdf_backend": args.pdf_backend}
    try:
        v = requests.get(f"{args.url}/version", timeout=10).json()
        engine.update({"docling_serve": v.get("docling-serve"), "docling": v.get("docling")})
    except (requests.RequestException, ValueError):
        engine.update({"docling_serve": None, "docling": None})
    return engine


def finish_doc(args, doc):
    pdf = doc["pdf"]
    secs = time.time() - doc["started"]
    out = Path(args.output) / f"{pdf.stem}.json"
    tmp = out.with_suffix(".json.tmp")
    tmp.write_text(json.dumps({
        "source_file": pdf.name,
        "status": "success",
        "pages": doc["pages"],
        "chunks": len(doc["chunks"]),
        "force_ocr": doc["force_ocr"],
        "extractor_version": __version__,
        "engine": args.engine,
        "markdown": "\n\n".join(doc["results"][i] for i in range(len(doc["chunks"]))),
        "processing_time": round(secs, 1),
        "errors": [],
        "converted_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }, ensure_ascii=False, indent=2))
    os.replace(tmp, out)
    dest = Path(args.completed) / pdf.name
    os.replace(pdf, dest)
    doc["log"].info(f"DOC_DONE    pages={doc['pages']} chunks={len(doc['chunks'])} secs={secs:.1f} "
                    f"sec_per_page={secs / max(doc['pages'], 1):.2f} output={out} moved={dest}")


def fail_doc(args, pdf, lg, reason):
    """Move a PDF that cannot be converted to errors/ so the queue keeps moving."""
    dest = Path(args.errors) / pdf.name
    try:
        os.replace(pdf, dest)
    except OSError as e:
        dest = f"not moved ({e})"
    lg.info(f"DOC_FAILED  doc={pdf.name} reason=\"{reason}\" moved={dest}")


def is_scanned_page(page):
    """True if the page carries an image at least as large as the page itself (a scan)."""
    try:
        xobjects = page["/Resources"]["/XObject"]
    except (KeyError, TypeError):
        return False
    width = float(page.mediabox.width)
    for ref in xobjects.values():
        x = ref.get_object()
        if x.get("/Subtype") == "/Image" and int(x.get("/Width", 0)) >= width:
            return True
    return False


def plan_docs(args):
    docs, failed = [], 0
    for pdf in sorted(Path(args.input).glob("*.pdf")):
        lg = doc_logger(args.logs, pdf)
        try:
            reader = PdfReader(pdf)
            pages = len(reader.pages)
            scanned = sum(map(is_scanned_page, reader.pages)) / max(pages, 1)
        except Exception as e:
            fail_doc(args, pdf, lg, f"unreadable PDF: {e}")
            failed += 1
            continue
        is_scan = scanned >= 0.5
        force_ocr = args.ocr == "force" or (args.ocr == "auto" and is_scan)
        chunk_pages = args.scanned_chunk_pages if is_scan else args.chunk_pages
        size = chunk_pages if chunk_pages > 0 else pages
        chunks = [(s, min(s + size - 1, pages)) for s in range(1, pages + 1, size)]
        lg.info(f"DOC_START   doc={pdf.name} pages={pages} chunks={len(chunks)} chunk_pages={chunk_pages} "
                f"scanned_pages={scanned:.0%} force_ocr={force_ocr} size_mb={pdf.stat().st_size / 1e6:.1f}")
        docs.append({"pdf": pdf, "pages": pages, "chunks": chunks, "results": {}, "force_ocr": force_ocr,
                     "started": None, "failed": False, "log": lg})
    return docs, failed


def main():
    args = parse_args()
    for d in (args.output, args.completed, args.errors, args.logs):
        Path(d).mkdir(parents=True, exist_ok=True)
    if not wait_healthy(args.url, timeout=5):
        run_log.info(f"ERROR       docling-serve unreachable at {args.url}; start it with `docker compose up -d`")
        sys.exit(2)

    args.engine = engine_versions(args)
    args.max_inflight = args.max_inflight or server_workers(args.container)
    docs, failed = plan_docs(args)
    queue = deque((d, i) for d in docs for i in range(len(d["chunks"])))
    run_log.info(f"RUN_START   files={len(docs)} pages={sum(d['pages'] for d in docs)} chunks={len(queue)} "
                 f"max_inflight={args.max_inflight} chunk_pages={args.chunk_pages} "
                 f"scanned_chunk_pages={args.scanned_chunk_pages} version={__version__} "
                 f"docling_serve={args.engine['docling_serve']} restarts={restart_count(args.container)}")

    mem = MemoryMonitor(args.container)
    try:
        mem.sample()
    except Exception as e:
        run_log.info(f"WARNING     memory monitoring unavailable ({e}); using --max-inflight only")
    mem.start()

    ok, run_start, last_beat, throttled, server_down = 0, time.time(), time.time(), False, False
    running = {}  # future -> (doc, idx, submitted_at)
    with ThreadPoolExecutor(max_workers=args.max_inflight) as pool:
        while queue or running:
            over = mem.fraction is not None and mem.fraction >= args.mem_high
            if over != throttled:
                throttled = over
                run_log.info(f"THROTTLE    {'on' if over else 'off'} mem={mem}")
            # While throttled, still allow one chunk if nothing is running, so the run can't stall.
            while queue and len(running) < args.max_inflight and not (throttled and running):
                doc, idx = queue.popleft()
                if doc["failed"]:
                    continue
                doc["started"] = doc["started"] or time.time()
                start, end = doc["chunks"][idx]
                doc["log"].info(f"SUBMIT      chunk={idx + 1}/{len(doc['chunks'])} pages={start}-{end} mem={mem}")
                running[pool.submit(run_chunk, args, doc, idx)] = (doc, idx, time.time())

            done, _ = wait(running, timeout=2, return_when=FIRST_COMPLETED)
            for fut in done:
                doc, idx, _ = running.pop(fut)
                start, end = doc["chunks"][idx]
                if doc["failed"]:
                    continue
                try:
                    md, secs = fut.result()
                except ServerDown as e:
                    # Leave every unfinished PDF in inputs/ for the next run.
                    server_down = True
                    doc["failed"] = True
                    doc["log"].info(f"ABORTED     chunk={idx + 1} pages={start}-{end} reason=\"{e}\" "
                                    f"left_in={args.input}/")
                    queue.clear()
                    continue
                except Exception as e:
                    doc["failed"] = True
                    failed += 1
                    fail_doc(args, doc["pdf"], doc["log"], f"chunk {idx + 1} pages {start}-{end}: {e}")
                    continue
                doc["results"][idx] = md
                n = end - start + 1
                doc["log"].info(f"CHUNK_DONE  chunk={idx + 1}/{len(doc['chunks'])} pages={start}-{end} "
                                f"secs={secs:.1f} sec_per_page={secs / n:.2f} mem={mem}")
                if len(doc["results"]) == len(doc["chunks"]):
                    try:
                        finish_doc(args, doc)
                        ok += 1
                    except OSError as e:
                        failed += 1
                        doc["log"].info(f"DOC_FAILED  reason=\"write/move: {e}\"")

            if time.time() - last_beat >= args.heartbeat and running:
                now = time.time()
                for doc in {id(d): d for d, _, _ in running.values()}.values():
                    items = " ".join(f"#{i + 1}({now - t:.0f}s)" for d, i, t in running.values() if d is doc)
                    doc["log"].info(f"PROGRESS    running=[{items}] done={len(doc['results'])}/{len(doc['chunks'])} "
                                    f"elapsed={now - doc['started']:.0f}s mem={mem}")
                last_beat = now

    secs = time.time() - run_start
    done_pages = sum(d["pages"] for d in docs if not d["failed"])
    run_log.info(f"RUN_END     ok={ok} failed={failed} pages={done_pages} secs={secs:.1f} "
                 f"sec_per_page={secs / max(done_pages, 1):.2f} restarts={restart_count(args.container)}")
    if server_down:
        run_log.info(f"ERROR       docling-serve went down; unfinished PDFs left in {args.input}/")
        sys.exit(2)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
