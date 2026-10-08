"""Render the README's demo screenshot (docs/images/demo_run.png) from a real demo_run.sh run.

Usage: python docs/render_demo_screenshot.py <steps.log | demo-output.txt> [--title TEXT]

Takes the "6. First demo run" section of a tests/ubuntu_container_test.sh steps.log (or a plain
capture of `scripts/demo_run.sh` output), renders it as a terminal window with headless Chrome,
and crops it. Needs Google Chrome/Chromium (set CHROME=/path if not found) and Pillow
(installed with tests/requirements.txt). The text is never edited: the image shows the real run.
"""
import html
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "images" / "demo_run.png"
BG = (30, 31, 41)


def chrome():
    for c in (os.environ.get("CHROME"), "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
              shutil.which("google-chrome"), shutil.which("chromium"), shutil.which("chromium-browser")):
        if c and Path(c).exists():
            return c
    sys.exit("Chrome/Chromium not found: set CHROME=/path/to/chrome")


def demo_lines(path):
    text = Path(path).read_text()
    m = re.search(r"^######## 6\..*?\n(.*?)^######## 7\.", text, re.S | re.M)
    return (m[1] if m else text).strip("\n").splitlines()


def main():
    src = sys.argv[1]
    title = "scripts/demo_run.sh: first run on a new server"
    if "--title" in sys.argv:
        title = sys.argv[sys.argv.index("--title") + 1]
    os_line = next((ln for ln in demo_lines(src) if "OS: Ubuntu" in ln), "")
    host = re.search(r"Ubuntu (\d+\.\d+)", os_line)
    prompt = f"ops@ubuntu-{host[1] if host else 'server'}:/opt/app$"
    rows = [f'<span class="p">{prompt}</span> scripts/demo_run.sh --clean-after', ""]
    for line in demo_lines(src):
        e = html.escape(line)
        if line.startswith("== "):
            e = f'<span class="h">{e}</span>'
        e = e.replace("[ OK ]", '<span class="ok">[ OK ]</span>').replace("[WARN]", '<span class="w">[WARN]</span>')
        e = e.replace("[FAIL]", '<span class="f">[FAIL]</span>')
        if line.startswith("All checks passed"):
            e = f'<span class="ok">{e}</span>'
        e = re.sub(r"(\[\w+\])(?= (DOC_|SUBMIT|PROGRESS|CHUNK_))", r'<span class="d">\1</span>', e)
        e = re.sub(r"(DOC_DONE|RUN_END)", r'<span class="ok">\1</span>', e)
        rows.append(e)
    page = f"""<!doctype html><meta charset="utf-8"><style>
html,body{{margin:0;background:rgb{BG}}}
.win{{border-radius:10px;overflow:hidden;font:13px/1.45 Menlo,Consolas,monospace;color:#e6e6e6;
  background:rgb{BG};width:max-content}}
.bar{{background:#2d2f3b;padding:9px 12px;display:flex;gap:8px;align-items:center}}
.bar i{{width:12px;height:12px;border-radius:50%;display:inline-block}}
.bar span{{color:#a0a3b1;font:12px -apple-system,Segoe UI,sans-serif;margin-left:10px}}
pre{{margin:0;padding:14px 18px 18px;white-space:pre}}
.p,.ok{{color:#7ee787}} .h{{color:#79c0ff;font-weight:bold}} .w{{color:#e3b341}} .f{{color:#ff7b72}} .d{{color:#d2a8ff}}
</style><div class="win"><div class="bar"><i style="background:#ff5f56"></i><i style="background:#ffbd2e"></i>
<i style="background:#27c93f"></i><span>{html.escape(title)}</span></div><pre>{chr(10).join(rows)}</pre></div>"""
    with tempfile.TemporaryDirectory() as tmp:
        page_file, raw = Path(tmp, "demo.html"), Path(tmp, "raw.png")
        page_file.write_text(page)
        subprocess.run([chrome(), "--headless=new", "--disable-gpu", "--hide-scrollbars",
                        "--force-device-scale-factor=1.5", "--window-size=1500,1400",
                        f"--screenshot={raw}", page_file.as_uri()],
                       check=True, capture_output=True)
        im = Image.open(raw).convert("RGB")
        px, (w, h) = im.load(), im.size
        right = max(x for x in range(w) for y in range(0, h, 7) if px[x, y] != BG)
        bottom = max(y for y in range(h) for x in range(0, w, 7) if px[x, y] != BG)
        OUT.parent.mkdir(parents=True, exist_ok=True)
        im.crop((0, 0, min(w, right + 24), min(h, bottom + 24))).save(OUT, optimize=True)
    print(f"wrote {OUT.relative_to(ROOT)} ({Image.open(OUT).size[0]}×{Image.open(OUT).size[1]})")


if __name__ == "__main__":
    main()
