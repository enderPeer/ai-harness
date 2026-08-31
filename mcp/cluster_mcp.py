"""cluster_mcp.py — the ai-harness cluster as MCP tools for a coding agent.

Speaks MCP over stdio (JSON-RPC 2.0, newline-delimited) with no dependencies,
same as the rest of the harness. Wire it into an agent with:

    "mcp": { "cluster": { "type": "local",
                          "command": ["C:\\\\hy3d\\\\venv\\\\Scripts\\\\python.exe",
                                      "C:\\\\Users\\\\end\\\\dev\\\\ai-harness\\\\mcp\\\\cluster_mcp.py"] } }

What it exposes: the state of every tier, the image->3D pipeline, ComfyUI on
adler, a shell on either server, and the free LLM workers themselves — so an
agent can hand bulk work to hardware that costs nothing instead of doing it in
its own context.
"""

from __future__ import annotations

import json
import os
import re
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

VERSION = "0.1.0"
PROTOCOL_FALLBACK = "2024-11-05"

STUDIO = os.environ.get("GEN3D_URL", "http://127.0.0.1:8095")
DASHBOARD = os.environ.get("DASHBOARD_URL", "http://127.0.0.1:8090")
COMFY = os.environ.get("COMFY_URL", "http://127.0.0.1:9188")
WORKERS = {
    "local": os.environ.get("LOCAL_LLM_URL", "http://127.0.0.1:8080"),
    "specht": os.environ.get("SPECHT_LLM_URL", "http://127.0.0.1:9088"),
    "barza": os.environ.get("BARZA_LLM_URL", "https://185.41.242.227:53018"),
    # The night coder shares specht's cards with the GLM, so exactly one of
    # "specht" and "night" answers at a time. See scripts/night-coder.ps1.
    "night": os.environ.get("NIGHT_LLM_URL", "http://127.0.0.1:9089"),
}
# barza is off-site: TLS with a self-signed cert (no public CA can issue for a
# bare IP) plus a bearer key. Both live in ~/.config, never in this repo.
BARZA_CERT = os.environ.get("BARZA_CERT", str(Path.home() / ".config" / "barza-llama.crt"))
BARZA_KEY_FILE = os.environ.get("BARZA_KEY_FILE", str(Path.home() / ".config" / "barza-llama.key"))
CONNECT = os.environ.get("SSH_CONNECT", r"C:\Program Files\Git\mingw64\bin\connect.exe")
SSH_KEY = os.environ.get("SSH_KEY", str(Path.home() / ".ssh" / "id_ed25519"))
HOSTS = {  # name -> (socks port for its wireproxy, tunnel address)
    "adler": ("1080", "10.71.0.1"),
    "specht": ("1081", "10.72.0.1"),
}


# ----------------------------------------------------------------- http helpers

def barza_auth() -> dict[str, str]:
    try:
        return {"Authorization": "Bearer " + Path(BARZA_KEY_FILE).read_text(encoding="utf-8").strip()}
    except OSError:
        return {}


def barza_ssl():
    try:
        return ssl.create_default_context(cafile=BARZA_CERT)
    except OSError:
        return None


def http(url: str, data: bytes | None = None, ctype: str = "application/json", timeout: int = 30,
         headers: dict[str, str] | None = None, context=None):
    req = urllib.request.Request(url, data=data, method="POST" if data is not None else "GET")
    if data is not None:
        req.add_header("Content-Type", ctype)
    for key, value in (headers or {}).items():
        req.add_header(key, value)
    with urllib.request.urlopen(req, timeout=timeout, context=context) as r:
        body = r.read()
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        return body.decode("utf-8", "replace")


def alive(url: str, timeout: int = 4) -> bool:
    # barza's health check is open but still TLS: without its pinned CA the
    # probe fails verification and the tier would be reported down.
    ctx = barza_ssl() if url.startswith(WORKERS["barza"]) else None
    try:
        http(url, timeout=timeout, context=ctx)
        return True
    except Exception:
        return False


def ssh(host: str, command: str, timeout: int = 120) -> tuple[int, str]:
    """Run a command on a server. sshd cannot reach user ports here, but running
    a command in user context is exactly what does work — see net/wgexpose.py."""
    if host not in HOSTS:
        return 2, f"unknown host {host!r}; expected one of {', '.join(HOSTS)}"
    socks, ip = HOSTS[host]
    argv = [
        "ssh", "-o", f'ProxyCommand="{CONNECT}" -S 127.0.0.1:{socks} %h %p',
        "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-i", SSH_KEY,
        f"end@{ip}", command,
    ]
    try:
        p = subprocess.run(argv, capture_output=True, text=True, encoding="utf-8",
                           errors="replace", timeout=timeout)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, f"timed out after {timeout}s"


# ----------------------------------------------------------------------- tools

def t_cluster_status(_args: dict) -> str:
    lines = []
    for name, url, probe in [
        ("dashboard", DASHBOARD, f"{DASHBOARD}/api/interfaces"),
        ("gen3d studio", STUDIO, f"{STUDIO}/api/state"),
        ("llm local (RTX 4080, 32k)", WORKERS["local"], f"{WORKERS['local']}/health"),
        ("llm specht (2x AMD, 131k)", WORKERS["specht"], f"{WORKERS['specht']}/health"),
        ("llm barza (Qwen3.8-27B Q5)", WORKERS["barza"], f"{WORKERS['barza']}/health"),
        ("llm night (Qwen3.8 262k)", WORKERS["night"], f"{WORKERS['night']}/health"),
        ("ComfyUI (adler RTX 4090)", COMFY, f"{COMFY}/system_stats"),
    ]:
        lines.append(f"{'up  ' if alive(probe) else 'DOWN'} {name:28} {url}")
    try:
        gpu = http(f"{STUDIO}/api/state", timeout=6).get("gpu", {})
        if gpu:
            lines.append(f"\nlocal GPU: {gpu['name']} — {gpu['util']}% · "
                         f"{gpu['used']}/{gpu['total']} MiB · {gpu['temp']}C")
    except Exception:
        pass
    return "\n".join(lines)


def t_gen3d_generate(args: dict) -> str:
    images = args.get("images") or ([args["image"]] if args.get("image") else [])
    if not images:
        return "error: give `image` (one path) or `images` (up to four: front, back, left, right)"
    stored = []
    for path in images[:4]:
        p = Path(path)
        if not p.is_file():
            return f"error: no such image {p}"
        r = http(f"{STUDIO}/api/upload?name={urllib.parse.quote(p.name)}",
                 data=p.read_bytes(), ctype="application/octet-stream", timeout=60)
        stored.append(r["file"])
    body = {"files": stored, "faces": int(args.get("faces", 8000))}
    if args.get("model"):
        body["model"] = args["model"]
    if args.get("name"):
        body["stem"] = args["name"]
    r = http(f"{STUDIO}/api/generate", data=json.dumps(body).encode(), timeout=30)
    if "id" not in r:
        return f"error: {r}"
    kind = "multi-view (Hunyuan3D-2mv)" if len(stored) > 1 else "single view"
    return (f"queued job {r['id']} — {kind}, {len(stored)} image(s).\n"
            f"The local LLM worker is stopped for the run and restarts when the queue drains.\n"
            f"Poll with gen3d_job; a single view takes ~2 min, four views ~2.5 min.")


def t_gen3d_job(args: dict) -> str:
    state = http(f"{STUDIO}/api/state", timeout=15)
    jobs = state.get("jobs", [])
    if not jobs:
        return "no jobs yet"
    jid = args.get("job_id")
    job = next((j for j in jobs if j["id"] == jid), None) if jid else jobs[0]
    if job is None:
        return f"no job {jid}"
    out = [f"job {job['id']} — {job['stem']}",
           f"status: {job['status']}" + (f" ({job['step']})" if job["step"] else ""),
           f"model : {job['model']}   views: {len(job['views'])}   faces: {job['faces']}"]
    if job.get("seconds"):
        out.append(f"took  : {job['seconds']}s")
    if job.get("out"):
        out.append(f"mesh  : {state['out_dir']}\\{job['out']}")
    if job.get("error"):
        out.append(f"error : {job['error']}")
    if job["status"] == "running" and job.get("tail"):
        out.append("--- log ---\n" + "\n".join(job["tail"][-4:]))
    return "\n".join(out)


def t_gen3d_gallery(_args: dict) -> str:
    state = http(f"{STUDIO}/api/state", timeout=15)
    if not state.get("gallery"):
        return "no meshes yet"
    return "\n".join(f"{g['name']:40} {g['mb']:6.2f} MB  {g['at']}  "
                     f"{state['out_dir']}\\{g['name']}" for g in state["gallery"])


def t_comfy_status(_args: dict) -> str:
    try:
        q = http(f"{COMFY}/queue", timeout=15)
        s = http(f"{COMFY}/system_stats", timeout=15)
    except Exception as exc:
        return f"ComfyUI unreachable at {COMFY}: {exc}"
    dev = (s.get("devices") or [{}])[0]
    running, pending = len(q.get("queue_running", [])), len(q.get("queue_pending", []))
    out = [f"ComfyUI {s.get('system', {}).get('comfyui_version', '?')} on adler",
           f"queue: {running} running, {pending} pending"]
    if dev:
        free, total = dev.get("vram_free", 0), dev.get("vram_total", 1)
        out.append(f"{dev.get('name', 'gpu')}: {(total - free) / 1e9:.1f}/{total / 1e9:.1f} GB VRAM in use")
    return "\n".join(out)


def comfy_output_names() -> list[str]:
    """ComfyUI output filenames, newest first. /history is oldest-first."""
    hist = http(f"{COMFY}/history", timeout=25)
    names: list[str] = []
    for record in hist.values():
        for node in (record.get("outputs") or {}).values():
            for img in node.get("images", []):
                if img.get("type") == "output" and img["filename"] not in names:
                    names.append(img["filename"])
    names.reverse()
    return names


def t_comfy_outputs(args: dict) -> str:
    try:
        names = comfy_output_names()
    except Exception as exc:  # noqa: BLE001
        return f"ComfyUI unreachable at {COMFY}: {exc}"
    if not names:
        return "ComfyUI has produced nothing yet"
    limit = int(args.get("limit", 30))
    # Group the front/back/left/right sets: a complete one feeds the multi-view
    # 3D model directly, which is the whole point of listing them.
    sets: dict[str, set[str]] = {}
    for n in names:
        m = re.match(r"(.+?)-(front|back|left|right)(_\d+_)?\.\w+$", n, re.I)
        if m:
            sets.setdefault(m.group(1), set()).add(m.group(2).lower())
    out = [f"{len(names)} outputs on adler ({COMFY})", "", "most recent:"]
    out += [f"  {n}" for n in names[:limit]]
    complete = sorted(k for k, v in sets.items() if len(v) == 4)
    if complete:
        out += ["", f"complete 4-view sets ({len(complete)}) — pass one to gen3d_generate:"]
        out += [f"  {k}" for k in complete]
    partial = sorted((k, sorted(v)) for k, v in sets.items() if len(v) < 4)
    if partial:
        out += ["", f"incomplete sets ({len(partial)}):"]
        out += [f"  {k}: {', '.join(v)}" for k, v in partial[:20]]
    return "\n".join(out)


def t_comfy_fetch(args: dict) -> str:
    """Pull outputs off adler to local disk. No credentials: it is our ComfyUI,
    reached over the tunnel, so /view serves them directly."""
    out_dir = Path(args.get("out_dir") or (Path.home() / "Downloads" / "comfy"))
    names = args.get("files") or []
    prefix = args.get("set")
    if prefix:
        try:
            available = comfy_output_names()
        except Exception as exc:  # noqa: BLE001
            return f"ComfyUI unreachable at {COMFY}: {exc}"
        order = {"front": 0, "back": 1, "left": 2, "right": 3}
        matched = [n for n in available if n.startswith(prefix + "-")]

        def view_rank(name: str) -> int:
            for view, rank in order.items():
                if f"-{view}_" in name or name.endswith(f"-{view}.png"):
                    return rank
            return 9

        names = sorted(matched, key=view_rank)
    if not names:
        return "error: give `files` (output filenames) or `set` (a name prefix like vet3-plate-carrier)"
    out_dir.mkdir(parents=True, exist_ok=True)
    saved = []
    for name in names:
        query = urllib.parse.urlencode({"filename": name, "type": "output", "subfolder": ""})
        try:
            with urllib.request.urlopen(f"{COMFY}/view?{query}", timeout=120) as r:
                data = r.read()
        except Exception as exc:  # noqa: BLE001
            return f"error fetching {name}: {exc}"
        dst = out_dir / name
        dst.write_bytes(data)
        saved.append(f"  {dst}  ({len(data) / 1e6:.1f} MB)")
    return (f"fetched {len(saved)} file(s) from adler:\n" + "\n".join(saved) +
            "\n\nPass these paths to gen3d_generate (in front, back, left, right order) to mesh them.")


def t_remote_run(args: dict) -> str:
    host, command = args.get("host", ""), args.get("command", "")
    if not command:
        return "error: `command` is required"
    rc, out = ssh(host, command, timeout=int(args.get("timeout", 120)))
    return f"[{host} exit {rc}]\n{out.strip() or '(no output)'}"


def t_worker_ask(args: dict) -> str:
    """Hand a self-contained task to a free local model instead of burning agent context."""
    prompt = args.get("prompt", "")
    if not prompt:
        return "error: `prompt` is required"
    worker = args.get("worker") or "night"
    if worker not in WORKERS:
        return f"error: worker must be one of {', '.join(WORKERS)}"
    # night and specht take turns on the same two cards. If the caller did not
    # name one explicitly, use whichever is actually resident rather than
    # failing on a tier that is simply off shift.
    note = ""
    if not args.get("worker") and not alive(f"{WORKERS['night']}/health", timeout=3):
        worker = "specht"
        note = "\n(night coder is off shift; answered by the GLM instead)"
    files = args.get("files") or []
    for f in files:
        p = Path(f)
        if not p.is_file():
            return f"error: no such file {p}"
        prompt += f"\n\n--- FILE: {p} ---\n" + p.read_text(encoding="utf-8", errors="replace")
    payload = {
        "messages": ([{"role": "system", "content": args["system"]}] if args.get("system") else [])
                    + [{"role": "user", "content": prompt}],
        "max_tokens": int(args.get("max_tokens", 4000)),
        "temperature": float(args.get("temperature", 0.7)),
        "stream": False,
    }
    if args.get("no_think", True):
        # Measured on this cluster: reasoning models spend the whole budget
        # "thinking" on mechanical work and return nothing.
        payload["chat_template_kwargs"] = {"enable_thinking": False}
    t0 = time.time()
    extra = barza_auth() if worker == "barza" else None
    ctx = barza_ssl() if worker == "barza" else None
    try:
        r = http(f"{WORKERS[worker]}/v1/chat/completions", data=json.dumps(payload).encode(),
                 timeout=int(args.get("timeout", 600)), headers=extra, context=ctx)
    except Exception as exc:
        return f"error: {worker} worker failed: {exc}"
    if "choices" not in r:
        return f"error: {r}"
    usage = r.get("usage", {})
    text = r["choices"][0]["message"].get("content") or "(empty)"
    return (f"{text}\n\n--- {worker}: {usage.get('completion_tokens', '?')} tokens "
            f"in {time.time() - t0:.0f}s (free) ---{note}")


TOOLS = [
    {
        "name": "cluster_status",
        "description": "Which tiers of the ai-harness cluster are up (local 4080, specht 2x AMD, adler 4090) and what the local GPU is doing. Call this first when something is unreachable.",
        "inputSchema": {"type": "object", "properties": {}},
        "fn": t_cluster_status,
    },
    {
        "name": "gen3d_generate",
        "description": "Turn concept art into a game-ready GLB mesh on the local RTX 4080 (Hunyuan3D). Give one image, or up to four views (front, back, left, right) to use the multi-view model, which is markedly better on backs and sides. Takes ~2 minutes and stops the local LLM worker for the duration.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "image": {"type": "string", "description": "Path to a single concept image."},
                "images": {"type": "array", "items": {"type": "string"},
                            "description": "Up to four view images, ordered front, back, left, right."},
                "faces": {"type": "integer", "description": "Target face count after decimation (default 8000; multi-view uses 30000)."},
                "name": {"type": "string", "description": "Base name for the mesh file."},
            },
        },
        "fn": t_gen3d_generate,
    },
    {
        "name": "gen3d_job",
        "description": "Status and log tail of an image->3D job. Defaults to the most recent one.",
        "inputSchema": {"type": "object", "properties": {"job_id": {"type": "string"}}},
        "fn": t_gen3d_job,
    },
    {
        "name": "gen3d_gallery",
        "description": "List the GLB meshes produced so far, with their paths on disk.",
        "inputSchema": {"type": "object", "properties": {}},
        "fn": t_gen3d_gallery,
    },
    {
        "name": "comfy_status",
        "description": "ComfyUI queue depth and 4090 VRAM on adler — check before queueing image generation.",
        "inputSchema": {"type": "object", "properties": {}},
        "fn": t_comfy_status,
    },
    {
        "name": "comfy_outputs",
        "description": "List the art ComfyUI has generated on adler, newest first, and group the front/back/left/right sets. A complete 4-view set can go straight into gen3d_generate for a much better mesh.",
        "inputSchema": {"type": "object", "properties": {"limit": {"type": "integer", "description": "How many recent filenames to show (default 30)."}}},
        "fn": t_comfy_outputs,
    },
    {
        "name": "comfy_fetch",
        "description": "Download ComfyUI outputs from adler to local disk. No credentials needed — it is our own instance over the tunnel. Give `set` (a name prefix like 'vet3-plate-carrier') to pull a whole view set in front/back/left/right order, or `files` for exact filenames.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "set": {"type": "string", "description": "Name prefix; pulls every view of that set, correctly ordered."},
                "files": {"type": "array", "items": {"type": "string"}, "description": "Exact output filenames."},
                "out_dir": {"type": "string", "description": "Where to save (default ~/Downloads/comfy)."},
            },
        },
        "fn": t_comfy_fetch,
    },
    {
        "name": "remote_run",
        "description": "Run a shell command on one of the servers ('adler' or 'specht') as user end, over the WireGuard tunnel. Use it to inspect GPUs (nvidia-smi, radeontop), manage llama.cpp servers, or work with files in the remote home directory.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "host": {"type": "string", "enum": ["adler", "specht"]},
                "command": {"type": "string", "description": "Shell command to run."},
                "timeout": {"type": "integer", "description": "Seconds before giving up (default 120)."},
            },
            "required": ["host", "command"],
        },
        "fn": t_remote_run,
    },
    {
        "name": "worker_ask",
        "description": "Delegate a self-contained task to a free LLM worker: 'specht' has 131k context (whole-file audits, long documents), 'local' is fastest at ~100 tok/s and 32k, 'barza' is Qwen3.8-27B at Q5 (32k, ~35 tok/s) and scored 51/51 against the GLMs' 47 and 45 on an executed code benchmark — prefer it when correctness matters more than speed. Workers reliably produce self-contained artifacts — summaries, plans, single modules, reviews — and reliably fail at quoting existing code verbatim. Costs nothing, so prefer it over doing bulk reading yourself.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "prompt": {"type": "string"},
                "worker": {"type": "string", "enum": ["specht", "local", "barza", "night"], "description": "night = Qwen3.8-27B at 262k, the most capable and the one to hand real work to; specht = GLM at 131k; local = fastest; barza = same model as night but off-site at 32k. night and specht share cards, so only one answers at a time. Default night, falling back to specht."},
                "files": {"type": "array", "items": {"type": "string"}, "description": "Files to append to the prompt."},
                "system": {"type": "string"},
                "max_tokens": {"type": "integer"},
                "no_think": {"type": "boolean", "description": "Disable the reasoning phase (default true) — it exhausts the budget on mechanical tasks."},
            },
            "required": ["prompt"],
        },
        "fn": t_worker_ask,
    },
]
BY_NAME = {t["name"]: t for t in TOOLS}


# ------------------------------------------------------------------ jsonrpc io

def send(msg: dict) -> None:
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def reply(rid, result) -> None:
    send({"jsonrpc": "2.0", "id": rid, "result": result})


def fail(rid, code: int, message: str) -> None:
    send({"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}})


def handle(msg: dict) -> None:
    method, rid = msg.get("method"), msg.get("id")
    params = msg.get("params") or {}

    if method == "initialize":
        asked = params.get("protocolVersion")
        reply(rid, {
            "protocolVersion": asked if isinstance(asked, str) else PROTOCOL_FALLBACK,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": "ai-harness-cluster", "version": VERSION},
        })
    elif method in ("notifications/initialized", "notifications/cancelled"):
        pass  # notifications carry no id and want no answer
    elif method == "ping":
        reply(rid, {})
    elif method == "tools/list":
        reply(rid, {"tools": [{k: t[k] for k in ("name", "description", "inputSchema")} for t in TOOLS]})
    elif method == "tools/call":
        name = params.get("name")
        tool = BY_NAME.get(name)
        if tool is None:
            fail(rid, -32602, f"unknown tool {name!r}")
            return
        try:
            text = tool["fn"](params.get("arguments") or {})
            reply(rid, {"content": [{"type": "text", "text": str(text)}]})
        except Exception as exc:  # noqa: BLE001 — surface it to the agent, keep serving
            reply(rid, {"content": [{"type": "text", "text": f"{type(exc).__name__}: {exc}"}],
                        "isError": True})
    elif method in ("resources/list", "prompts/list"):
        reply(rid, {"resources": [], "prompts": []})
    elif rid is not None:
        fail(rid, -32601, f"method not found: {method}")


def main() -> int:
    # The transport is UTF-8 JSON; Windows would otherwise use the console codepage
    # and die on the first non-ASCII byte in a tool result.
    sys.stdin.reconfigure(encoding="utf-8")
    sys.stdout.reconfigure(encoding="utf-8", newline='\n')
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        try:
            handle(msg)
        except Exception as exc:  # noqa: BLE001 — one bad message must not kill the server
            if msg.get("id") is not None:
                fail(msg["id"], -32603, f"{type(exc).__name__}: {exc}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
