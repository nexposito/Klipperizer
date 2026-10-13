# ============================================================
#  Klipperizer — Servidor web (painel touch para display 5")
#  Roda localmente (127.0.0.1:8080) e acessa os módulos lib/
#  via CLI: klipperizer --list | --flash <perfil> <modo>
# ============================================================
import json
import os
import subprocess
import threading
import queue
from pathlib import Path

from flask import Flask, Response, jsonify, render_template, request, stream_with_context

BASE = Path(__file__).resolve().parent.parent
CLI = str(BASE / "klipperizer")
app = Flask(__name__)

# Estado global do job de flash (um por vez)
job_lock = threading.Lock()
job = {"running": False, "perfil": None, "modo": None, "returncode": None}
log_queue = queue.Queue()


def _run_flash(perfil, modo):
    """Executa o CLI em background e alimenta o log em tempo real."""
    try:
        proc = subprocess.Popen(
            ["bash", CLI, "--flash", perfil, modo],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            cwd=str(BASE),
        )
        for line in proc.stdout:
            log_queue.put(line.rstrip("\n"))
        proc.wait()
        job["returncode"] = proc.returncode
    except Exception as exc:  # noqa: BLE001
        log_queue.put(f"ERRO INTERNO: {exc}")
        job["returncode"] = 1
    finally:
        job["running"] = False


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/boards")
def boards():
    """Lista as placas agrupadas por categoria (lê os YAMLs)."""
    out = subprocess.run(
        ["bash", CLI, "--list"], capture_output=True, text=True, check=True
    )
    return app.response_class(out.stdout, mimetype="application/json")


@app.route("/api/start", methods=["POST"])
def start():
    """Inicia o flash. Body: {perfil: caminho, modo: can|usb}"""
    data = request.get_json(force=True)
    perfil, modo = data.get("perfil"), data.get("modo")
    if modo not in ("can", "usb"):
        return jsonify({"erro": "modo inválido"}), 400
    if not perfil or not (BASE / perfil).exists():
        return jsonify({"erro": "perfil não encontrado"}), 400
    with job_lock:
        if job["running"]:
            return jsonify({"erro": "já existe um flash em andamento"}), 409
        job.update(running=True, perfil=perfil, modo=modo, returncode=None)
    threading.Thread(target=_run_flash, args=(perfil, modo), daemon=True).start()
    return jsonify({"ok": True})


@app.route("/api/status")
def status():
    return jsonify(job)


@app.route("/api/log")
def log_stream():
    """SSE: envia as linhas do log em tempo real para o painel."""
    def generate():
        while True:
            try:
                line = log_queue.get(timeout=1)
                yield f"data: {json.dumps({'line': line})}\n\n"
            except queue.Empty:
                yield ": keep-alive\n\n"

    return Response(
        stream_with_context(generate()),
        mimetype="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, threaded=True)
