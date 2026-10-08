"""Send one conversion job to docling-serve and report its time and peak container memory.

Usage: measure_job.py <pdf> <first_page> <last_page> [docling_option=value ...]
Example: measure_job.py inputs/x.pdf 1 5 pdf_backend=pypdfium2 force_ocr=true

Used to size the container and compare docling options (see README "Test results").
Gives up after 5 minutes, or if the container restarts and loses the job.
"""
import os
import re
import subprocess
import sys
import threading
import time

import requests

URL = os.environ.get("DOCLING_URL", "http://localhost:5001")
CONTAINER = "docling_ocr_worker_cpu"
UNITS = {"B": 1 / 2**30, "KiB": 1 / 2**20, "MiB": 1 / 1024, "GiB": 1}


def mem_gib():
    out = subprocess.run(["docker", "stats", "--no-stream", "--format", "{{.MemUsage}}", CONTAINER],
                         capture_output=True, text=True).stdout
    m = re.match(r"([\d.]+)(\w+)", out)
    return float(m[1]) * UNITS[m[2]] if m else 0.0


def main():
    pdf, start, end = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    options = dict(kv.split("=", 1) for kv in sys.argv[4:])
    base, peak, stop = mem_gib(), [0.0], threading.Event()

    def sample():
        while not stop.is_set():
            peak[0] = max(peak[0], mem_gib())

    threading.Thread(target=sample, daemon=True).start()
    t0 = time.time()
    with open(pdf, "rb") as f:
        task = requests.post(f"{URL}/v1/convert/file/async", files={"files": f},
                             data={"to_formats": "md", "page_range": [start, end], **options},
                             timeout=300).json()["task_id"]
    status = "TIMEOUT(300s)"
    while time.time() - t0 < 300:
        try:
            r = requests.get(f"{URL}/v1/status/poll/{task}", timeout=60)
            if r.status_code == 404:
                status = "LOST(container restarted)"
                break
            status = r.json()["task_status"]
            if status not in ("pending", "started"):
                break
        except requests.RequestException:
            pass
        time.sleep(2)
    secs = time.time() - t0
    stop.set()
    md = ""
    if status in ("success", "partial_success"):
        md = requests.get(f"{URL}/v1/result/{task}", timeout=300).json()["document"]["md_content"] or ""
    print(f"pages={start}-{end} options={options} status={status} secs={secs:.1f} "
          f"sec_per_page={secs / (end - start + 1):.1f} base={base:.2f}GiB peak={peak[0]:.2f}GiB md_chars={len(md)}")


if __name__ == "__main__":
    main()
