"""gen3d studio — browser UI for the image -> GLB pipeline on the local GPU.

The 3D tier and the local LLM tier share one 16 GB card, so this server owns the
swap that `gen3d.cmd` does by hand: it stops llama-server before a job, runs
Hunyuan3D shape generation, decimates, and brings the worker back once the queue
drains. Jobs are serialised through a single worker thread — two shape models on
one card is an out-of-memory error, not a speedup.

Stdlib only (the hy3d venv's python), same as the rest of the harness:
    C:\\hy3d\\venv\\Scripts\\python.exe gen3d-ui.py
    -> http://127.0.0.1:8095/
"""

from __future__ import annotations

import json
import os
import queue
import re
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOST, PORT = "127.0.0.1", 8095
HY3D = Path(os.environ.get("HY3D_DIR", r"C:\hy3d"))
VENV_PY = Path(os.environ.get("HY3D_PYTHON", HY3D / "venv" / "Scripts" / "python.exe"))
OUT_DIR = Path(os.environ.get("GEN3D_OUT", HY3D / "out"))
UI_DIR = Path(__file__).resolve().parent
LLAMA_START = Path(os.environ.get("LLAMA_START", r"C:\llama.cpp\start-glm-server.cmd"))
LLAMA_URL = os.environ.get("LLAMA_URL", "http://127.0.0.1:8080")

# Single-view models offered in the picker. 2mini is not in the local HF cache,
# so choosing it downloads ~2 GB on first use — say so rather than surprising anyone.
MODELS = {
    "tencent/Hunyuan3D-2": "Hunyuan3D-2 — best geometry (~2 min)",
    "tencent/Hunyuan3D-2mini": "Hunyuan3D-2mini — fast draft (downloads ~2 GB on first use)",
}
MV_MODEL = "tencent/Hunyuan3D-2mv"   # picked automatically when 2-4 views are given
VIEWS = ["front", "back", "left", "right"]
MIME = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".glb": "model/gltf-binary",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".webp": "image/webp",
}
DETACHED = 0x00000008 | 0x00000200  # DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP


def now() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def safe_stem(name: str) -> str:
    stem = Path(name or "concept").stem
    stem = re.sub(r"[^A-Za-z0-9._-]+", "-", stem).strip("-.") or "concept"
    return stem[:60]


# --------------------------------------------------------------------------- jobs

class Job:
    def __init__(self, jid: str, stem: str, srcs: list[Path], model: str, faces: int):
        self.id = jid
        self.stem = stem
        self.srcs = srcs          # ordered front, back, left, right (as supplied)
        self.model = model
        self.faces = faces
        self.status = "queued"  # queued | running | done | error | cancelled
        self.step = ""
        self.created = now()
        self.started: str | None = None
        self.finished: str | None = None
        self.seconds: float | None = None
        self.out: str | None = None
        self.error: str | None = None
        self.log: list[str] = []

    def say(self, line: str) -> None:
        self.log.append(line.rstrip())
        del self.log[:-400]  # a long pipeline log is noise; keep the tail

    def public(self) -> dict:
        return {
            "id": self.id, "stem": self.stem, "model": self.model, "faces": self.faces,
            "status": self.status, "step": self.step, "created": self.created,
            "started": self.started, "finished": self.finished, "seconds": self.seconds,
            "out": self.out, "error": self.error,
            "views": [p.name for p in self.srcs],
            "multiview": len(self.srcs) > 1,
            "tail": self.log[-12:],
        }


JOBS: dict[str, Job] = {}
ORDER: list[str] = []
Q: "queue.Queue[str]" = queue.Queue()
LOCK = threading.Lock()
STATE = {"llama_stopped_by_us": False, "worker_busy": False}


def llama_up(timeout: float = 1.5) -> bool:
    try:
        with urllib.request.urlopen(f"{LLAMA_URL}/health", timeout=timeout):
            return True
    except Exception:
        return False


def stop_llama(job: Job) -> None:
    if not llama_up():
        return
    job.say("[vram] stopping local llama-server to free the card")
    subprocess.run(["taskkill", "/im", "llama-server.exe", "/f"], capture_output=True)
    STATE["llama_stopped_by_us"] = True
    for _ in range(20):
        if not llama_up(timeout=1.0):
            break
        time.sleep(0.5)


def start_llama() -> None:
    if not STATE["llama_stopped_by_us"] or llama_up():
        return
    if not LLAMA_START.exists():
        return
    subprocess.Popen(["cmd", "/c", str(LLAMA_START)], creationflags=DETACHED,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    STATE["llama_stopped_by_us"] = False


def run_step(job: Job, argv: list[str], step: str) -> int:
    job.step = step
    job.say(f"$ {' '.join(str(a) for a in argv)}")
    proc = subprocess.Popen(
        [str(a) for a in argv], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, encoding="utf-8", errors="replace", bufsize=1, cwd=str(UI_DIR),
    )
    assert proc.stdout is not None
    for line in proc.stdout:
        job.say(line)
    return proc.wait()


def worker() -> None:
    while True:
        jid = Q.get()
        job = JOBS[jid]
        if job.status == "cancelled":
            Q.task_done()
            continue
        STATE["worker_busy"] = True
        job.status, job.started = "running", now()
        t0 = time.time()
        try:
            OUT_DIR.mkdir(parents=True, exist_ok=True)
            out = OUT_DIR / f"{job.stem}.glb"
            n = 2
            while out.exists():  # never overwrite an earlier mesh
                out = OUT_DIR / f"{job.stem}-{n}.glb"
                n += 1
            stop_llama(job)
            if len(job.srcs) > 1:
                # gen3d_mv.py takes the output first, then front/back/left/right,
                # and decimates to 30k itself; skip our decimation pass below.
                argv = [VENV_PY, UI_DIR / "gen3d_mv.py", out, *job.srcs]
                script = "gen3d_mv.py"
            else:
                argv = [VENV_PY, UI_DIR / "gen3d.py", job.srcs[0], out, job.model]
                script = "gen3d.py"
            rc = run_step(job, argv, "shape generation")
            if rc != 0 or not out.exists():
                raise RuntimeError(f"{script} exited {rc}")
            if job.faces > 0 and len(job.srcs) == 1:
                rc = run_step(job, [VENV_PY, UI_DIR / "decimate.py", job.faces, out], "decimation")
                if rc != 0:
                    job.say(f"[warn] decimation failed (rc={rc}); keeping the full-resolution mesh")
            job.out = out.name
            job.status = "done"
            job.step = ""
        except Exception as exc:  # noqa: BLE001
            job.status, job.error, job.step = "error", str(exc), ""
            job.say(f"[error] {exc}")
        finally:
            job.seconds = round(time.time() - t0, 1)
            job.finished = now()
            STATE["worker_busy"] = False
            if Q.empty():  # nothing else waiting: give the card back to the LLM worker
                start_llama()
            Q.task_done()


# --------------------------------------------------------------------------- http

class Handler(BaseHTTPRequestHandler):
    server_version = "gen3d-ui"

    def log_message(self, fmt: str, *args) -> None:  # quiet; jobs carry their own log
        pass

    # -- helpers
    def send_bytes(self, body: bytes, ctype: str, code: int = 200) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, obj, code: int = 200) -> None:
        self.send_bytes(json.dumps(obj).encode("utf-8"), "application/json; charset=utf-8", code)

    def send_file(self, path: Path) -> None:
        if not path.is_file():
            self.send_bytes(b"not found", "text/plain; charset=utf-8", 404)
            return
        self.send_bytes(path.read_bytes(), MIME.get(path.suffix.lower(), "application/octet-stream"))

    def query(self) -> dict[str, str]:
        return {k: v[0] for k, v in urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).items()}

    # -- routes
    def do_GET(self) -> None:
        path = urllib.parse.urlparse(self.path).path
        if path in ("/", "/index.html"):
            self.send_file(UI_DIR / "gen3d-ui.html")
        elif path == "/api/state":
            self.send_json(self.state())
        elif path == "/api/log":
            job = JOBS.get(self.query().get("id", ""))
            self.send_bytes(("\n".join(job.log) if job else "no such job").encode("utf-8"),
                            "text/plain; charset=utf-8", 200 if job else 404)
        elif path.startswith("/files/"):
            name = urllib.parse.unquote(path[len("/files/"):])
            target = (OUT_DIR / name).resolve()
            if OUT_DIR.resolve() in target.parents:  # no path traversal out of the gallery
                self.send_file(target)
            else:
                self.send_bytes(b"forbidden", "text/plain; charset=utf-8", 403)
        else:
            self.send_bytes(b"not found", "text/plain; charset=utf-8", 404)

    def do_POST(self) -> None:
        path = urllib.parse.urlparse(self.path).path
        if path == "/api/upload":
            self.upload()
        elif path == "/api/generate":
            self.generate()
        elif path == "/api/cancel":
            job = JOBS.get(self.query().get("id", ""))
            if job and job.status == "queued":
                job.status = "cancelled"
                self.send_json({"ok": True})
            else:
                self.send_json({"ok": False, "error": "only queued jobs can be cancelled"}, 409)
        else:
            self.send_bytes(b"not found", "text/plain; charset=utf-8", 404)

    def read_body(self) -> bytes:
        return self.rfile.read(int(self.headers.get("Content-Length") or 0))

    def upload(self) -> None:
        """Store one view and return its filename; the client then posts /api/generate."""
        data = self.read_body()
        if not data:
            self.send_json({"error": "empty upload"}, 400)
            return
        name = self.query().get("name", "")
        suffix = Path(name).suffix.lower()
        OUT_DIR.mkdir(parents=True, exist_ok=True)
        stored = OUT_DIR / f"{safe_stem(name)}-{int(time.time() * 1000):x}.src{suffix if suffix in MIME else '.png'}"
        stored.write_bytes(data)
        self.send_json({"file": stored.name})

    def generate(self) -> None:
        try:
            req = json.loads(self.read_body() or b"{}")
        except json.JSONDecodeError:
            self.send_json({"error": "body must be JSON"}, 400)
            return
        files = [f for f in req.get("files", []) if f]
        if not files:
            self.send_json({"error": "no views given"}, 400)
            return
        if len(files) > len(VIEWS):
            self.send_json({"error": f"at most {len(VIEWS)} views"}, 400)
            return
        srcs = []
        for name in files:
            p = (OUT_DIR / Path(name).name)
            if not p.is_file():
                self.send_json({"error": f"unknown upload {name}"}, 400)
                return
            srcs.append(p)
        model = req.get("model", "tencent/Hunyuan3D-2")
        if len(srcs) > 1:
            model = MV_MODEL
        elif model not in MODELS:
            self.send_json({"error": f"unknown model {model}"}, 400)
            return
        try:
            faces = max(0, int(req.get("faces", 8000)))
        except (TypeError, ValueError):
            faces = 8000
        stem = safe_stem(req.get("stem") or files[0])
        stem = re.sub(r"-[0-9a-f]{9,}$", "", stem)  # drop the upload id from the mesh name
        jid = f"{int(time.time() * 1000):x}"
        job = Job(jid, stem, srcs, model, faces)
        with LOCK:
            JOBS[jid] = job
            ORDER.append(jid)
        Q.put(jid)
        self.send_json({"id": jid})

    def state(self) -> dict:
        with LOCK:
            jobs = [JOBS[j].public() for j in reversed(ORDER[-40:])]
        gallery = []
        if OUT_DIR.is_dir():
            for glb in sorted(OUT_DIR.glob("*.glb"), key=lambda p: p.stat().st_mtime, reverse=True)[:60]:
                if glb.name.endswith(".orig.glb"):
                    continue  # pre-decimation backup, not a deliverable
                gallery.append({
                    "name": glb.name,
                    "mb": round(glb.stat().st_size / 1e6, 2),
                    "at": datetime.fromtimestamp(glb.stat().st_mtime).isoformat(timespec="seconds"),
                })
        return {
            "jobs": jobs, "gallery": gallery, "models": MODELS,
            "queued": sum(1 for j in jobs if j["status"] == "queued"),
            "views": VIEWS, "mv_model": MV_MODEL,
            "busy": STATE["worker_busy"], "llama": llama_up(), "gpu": gpu_stats(),
            "out_dir": str(OUT_DIR),
        }


def gpu_stats() -> dict:
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu",
             "--format=csv,noheader,nounits"], capture_output=True, text=True, timeout=5).stdout.strip()
        name, util, used, total, temp = [p.strip() for p in out.splitlines()[0].split(",")]
        return {"name": name, "util": int(util), "used": int(used), "total": int(total), "temp": int(temp)}
    except Exception:  # noqa: BLE001
        return {}


def main() -> int:
    if not VENV_PY.exists():
        print(f"[gen3d-ui] hy3d python not found: {VENV_PY}", file=sys.stderr)
        return 1
    for name in ("gen3d.py", "gen3d_mv.py", "decimate.py", "gen3d-ui.html"):
        if not (UI_DIR / name).exists():
            print(f"[gen3d-ui] missing {UI_DIR / name}", file=sys.stderr)
            return 1
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    threading.Thread(target=worker, daemon=True).start()
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    srv.daemon_threads = True
    print(f"[gen3d-ui] http://{HOST}:{PORT}/   out={OUT_DIR}   python={VENV_PY}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n[gen3d-ui] stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
