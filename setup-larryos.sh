#!/usr/bin/env bash
# =============================================================================
# setup-larryos.sh — LarryOS: stack de inferencia local (se ejecuta como USUARIO,
# no como root, DESPUÉS del primer arranque de la instalación de archinstall).
#
#   ./setup-larryos.sh [paso ...]        pasos: check build models config services hermes verify
#   ./setup-larryos.sh                   = todos, en ese orden
#
# Variables de entorno útiles (todas opcionales):
#   LARRY_HOME   raíz de datos            (def. ~/.local/share/larryos)
#   EMB_DEVICE   NPU | GPU | CPU          (def. NPU)   dispositivo de embeddings
#   SKIP_CHECKS=1  no abortar si faltan NPU/Vulkan (p. ej. al probar en otra máquina)
#   SKIP_HERMES=1  no instalar Hermes Agent
# =============================================================================
set -Eeuo pipefail
trap 'echo "ERROR en la línea $LINENO: $BASH_COMMAND" >&2' ERR

# ---- Versiones fijadas (reproducibilidad) -----------------------------------
LLAMA_CPP_REPO="https://github.com/ggml-org/llama.cpp.git"
LLAMA_CPP_REF="${LLAMA_CPP_REF:-cbb1c1c50bba81929387dea473873d1df87a6212}"
SQLITE_VEC_REPO="https://github.com/asg017/sqlite-vec.git"
SQLITE_VEC_REF="${SQLITE_VEC_REF:-04d28bd21773981e2d266bbf6aa4efbd011eb4f6}"   # v0.1.10-alpha.4
SQLITE_VEC_VERSION="0.1.10-alpha.4"
LLAMA_SWAP_TAG="${LLAMA_SWAP_TAG:-v275}"
HERMES_INSTALL_URL="https://hermes-agent.nousresearch.com/install.sh"

# ---- Modelos ----------------------------------------------------------------
QWEN_REPO="unsloth/Qwen3.6-35B-A3B-GGUF";                 QWEN_PATTERN="*UD-IQ4_XS*"
RERANK_REPO="ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF";     RERANK_PATTERN="*.gguf"
GRANITE_REPO="lmstudio-community/granite-4.0-h-micro-GGUF"
GRANITE_QUANT="${GRANITE_QUANT:-Q6_K}";                    GRANITE_PATTERN="*${GRANITE_QUANT}*"
EMB_HF_ID="Qwen/Qwen3-Embedding-0.6B"
EMB_DEVICE="${EMB_DEVICE:-NPU}"
EMB_MAXLEN="${EMB_MAXLEN:-512}"          # forma estática: [1, EMB_MAXLEN]
EMB_DIM=1024                             # dimensión nativa de Qwen3-Embedding-0.6B
MAIN_CTX="${MAIN_CTX:-131072}"

# ---- Rutas ------------------------------------------------------------------
LARRY_HOME="${LARRY_HOME:-$HOME/.local/share/larryos}"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/larryos"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SRC="$LARRY_HOME/src"; BIN="$LARRY_HOME/bin"; LIB="$LARRY_HOME/lib"
MODELS="$LARRY_HOME/models"; DB_DIR="$LARRY_HOME/db"; CACHE="$LARRY_HOME/cache"
VENV="$LARRY_HOME/venv-ov"; DL="$LARRY_HOME/downloads"
LLAMA_SERVER="$BIN/llama-server"
PORT_BASE=5800; LISTEN="127.0.0.1:8080"

log()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[aviso]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "falta '$1' (instala el paquete correspondiente)"; }

# ---- Topología de CPU: Arrow Lake = 6 P + 8 E + 2 LP-E, sin SMT --------------
count_cpus() { python3 -c 'import sys
n=0
for p in sys.argv[1].split(","):
    a,_,b=p.partition("-"); n+=(int(b)-int(a)+1) if b else 1
print(n)' "$1"; }
detect_topology() {
  P_CPUS="$(cat /sys/devices/cpu_core/cpus 2>/dev/null || true)"
  E_CPUS="$(cat /sys/devices/cpu_atom/cpus 2>/dev/null || true)"
  if [ -z "$P_CPUS" ]; then
    warn "no hay /sys/devices/cpu_core: asumo P-cores 0-5 y E-cores 6-13"
    P_CPUS="0-5"; E_CPUS="6-13"
  fi
  P_N="$(count_cpus "$P_CPUS")"; E_N="$(count_cpus "${E_CPUS:-0}")"
}

# =============================================================================
step_check() {
  log "Comprobando entorno"
  [ "$(id -u)" -ne 0 ] || die "ejecútalo como usuario normal, no como root"
  for c in git cmake ninja gcc g++ curl python3 uv jq; do need "$c"; done
  [ -f /usr/include/sqlite3ext.h ] || die "falta sqlite3ext.h (paquete 'sqlite')"
  [ -f /usr/include/vulkan/vulkan.h ] || die "falta vulkan-headers"
  command -v glslc >/dev/null || die "falta glslc (paquete 'shaderc')"
  local flags; flags="$(grep -m1 '^flags' /proc/cpuinfo || true)"
  for f in avx2 avx_vnni; do
    grep -qw "$f" <<<"$flags" || warn "la CPU no declara '$f' (¿no es un Core Ultra 9 285H?)"
  done
  grep -qw avx512f <<<"$flags" && warn "la CPU declara AVX-512: los repos CachyOS v4 serían aplicables (esta config usa v3)"
  if [ "${SKIP_CHECKS:-0}" != 1 ]; then
    [ -e /dev/accel/accel0 ] || die "no existe /dev/accel/accel0: NPU sin driver (intel-npu-driver + linux-firmware-intel + reinicio)"
    id -nG | tr ' ' '\n' | grep -qx render || die "tu usuario no está en el grupo 'render': sudo usermod -aG render \$USER && reinicia sesión"
    vulkaninfo --summary 2>/dev/null | grep -qi 'Intel' || die "vulkaninfo no ve la iGPU Intel (paquete vulkan-intel)"
  fi
}

make_dirs() { mkdir -p "$SRC" "$BIN" "$LIB" "$MODELS" "$DB_DIR" "$CACHE/ov" "$DL" "$CFG_DIR" "$UNIT_DIR" "$LARRY_HOME/logs"; }

# =============================================================================
build_llama() {
  log "Compilando llama.cpp @ ${LLAMA_CPP_REF:0:10} (Vulkan + native, estático)"
  local d="$SRC/llama.cpp"
  [ -d "$d/.git" ] || git clone --filter=blob:none "$LLAMA_CPP_REPO" "$d"
  git -C "$d" fetch --quiet origin "$LLAMA_CPP_REF" 2>/dev/null || git -C "$d" fetch --quiet origin
  git -C "$d" checkout --quiet "$LLAMA_CPP_REF"
  cmake -S "$d" -B "$d/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="-O3 -march=native" -DCMAKE_CXX_FLAGS="-O3 -march=native" \
    -DGGML_VULKAN=ON -DGGML_NATIVE=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=ON
  cmake --build "$d/build" --target llama-server llama-bench -j "$(nproc)"
  install -m755 "$d/build/bin/llama-server" "$d/build/bin/llama-bench" "$BIN/"
  "$LLAMA_SERVER" --version 2>&1 | head -n2 || true
}

build_sqlite_vec() {
  log "Compilando sqlite-vec ${SQLITE_VEC_VERSION} (-O3 -march=native)"
  local d="$SRC/sqlite-vec" b="$SRC/sqlite-vec-build"
  [ -d "$d/.git" ] || git clone --filter=blob:none "$SQLITE_VEC_REPO" "$d"
  git -C "$d" fetch --quiet origin "$SQLITE_VEC_REF" 2>/dev/null || git -C "$d" fetch --quiet origin --tags
  git -C "$d" checkout --quiet "$SQLITE_VEC_REF"
  rm -rf "$b"; mkdir -p "$b"
  # El Makefile oficial genera sqlite-vec.h con envsubst y espera un 'vendor/' con el
  # amalgamation; aquí se usa el sqlite3ext.h del sistema y se genera la cabecera con sed.
  local v="$SQLITE_VEC_VERSION" maj min pat
  IFS=. read -r maj min pat <<<"${v%%-*}"
  sed -e "s|\${VERSION}|$v|g" -e "s|\${DATE}|$(date -u +%FT%TZ)|g" \
      -e "s|\${SOURCE}|$(git -C "$d" rev-parse HEAD)|g" \
      -e "s|\${VERSION_MAJOR}|$maj|g" -e "s|\${VERSION_MINOR}|$min|g" -e "s|\${VERSION_PATCH}|$pat|g" \
      "$d/sqlite-vec.h.tmpl" > "$b/sqlite-vec.h"
  cp "$d"/sqlite-vec*.c "$b/"          # sqlite-vec.c incluye los .c auxiliares
  gcc -fPIC -shared -O3 -march=native -I"$b" "$b/sqlite-vec.c" -o "$LIB/vec0.so"
  python3 - "$LIB/vec0.so" <<'PY'
import sqlite3, sys
c = sqlite3.connect(":memory:"); c.enable_load_extension(True); c.load_extension(sys.argv[1].removesuffix(".so"))
print("sqlite-vec", c.execute("select vec_version()").fetchone()[0], "| FTS5:", bool(c.execute("select sqlite_compileoption_used('ENABLE_FTS5')").fetchone()[0]))
PY
}

install_llama_swap() {
  log "Instalando llama-swap ${LLAMA_SWAP_TAG}"
  local ver="${LLAMA_SWAP_TAG#v}" base="https://github.com/mostlygeek/llama-swap/releases/download/${LLAMA_SWAP_TAG}"
  local tgz="llama-swap_${ver}_linux_amd64.tar.gz"
  curl -fsSL -o "$DL/$tgz" "$base/$tgz"
  if curl -fsSL -o "$DL/llama-swap_checksums.txt" "$base/llama-swap_${ver}_checksums.txt" 2>/dev/null; then
    (cd "$DL" && grep " $tgz\$" llama-swap_checksums.txt | sha256sum -c -) || die "checksum de llama-swap incorrecto"
  else
    warn "no se pudo obtener el fichero de checksums de llama-swap; sin verificación"
  fi
  tar -xzf "$DL/$tgz" -C "$BIN" llama-swap
  chmod 755 "$BIN/llama-swap"; "$BIN/llama-swap" -version | head -n1
}

step_build() { need git; build_llama; build_sqlite_vec; install_llama_swap; install_ov_env; }

# =============================================================================
install_ov_env() {
  log "Entorno Python 3.12 para OpenVINO (NPU) + exportación"
  [ -x "$VENV/bin/python" ] || uv venv --python 3.12 "$VENV"
  # torch solo en CPU (hace falta únicamente para exportar a OpenVINO)
  uv pip install --python "$VENV/bin/python" torch --index-url https://download.pytorch.org/whl/cpu
  uv pip install --python "$VENV/bin/python" openvino openvino-genai openvino-tokenizers \
      "optimum-intel[openvino]" nncf "huggingface_hub[cli]" hf_transfer
}

hf_fetch() {  # repo patrón destino -> imprime la ruta del .gguf (el primer shard si está troceado)
  local repo="$1" pat="$2" dst="$3"
  HF_HUB_ENABLE_HF_TRANSFER=1 "$VENV/bin/hf" download "$repo" --include "$pat" --local-dir "$dst" >&2
  find "$dst" -type f -name '*.gguf' ! -name 'mmproj*' | sort | head -n1
}

export_embedding() {
  local out="$MODELS/openvino/Qwen3-Embedding-0.6B-int8"
  if [ -f "$out/openvino_model.xml" ]; then log "Embedding OpenVINO ya exportado"; else
    log "Exportando $EMB_HF_ID -> OpenVINO INT8 simétrico (la NPU exige cuantización simétrica)"
    "$VENV/bin/optimum-cli" export openvino --model "$EMB_HF_ID" --task feature-extraction \
        --weight-format int8 --sym --trust-remote-code "$out"
  fi
  EMB_DIR="$out"
}

step_models() {
  [ -x "$VENV/bin/hf" ] || die "falta el entorno OpenVINO: ejecuta primero el paso 'build'"
  log "Descargando modelos GGUF"
  QWEN_GGUF="$(hf_fetch "$QWEN_REPO" "$QWEN_PATTERN" "$MODELS/qwen3.6-35b-a3b")"
  GRANITE_GGUF="$(hf_fetch "$GRANITE_REPO" "$GRANITE_PATTERN" "$MODELS/granite-4.0-h-micro")"
  RERANK_GGUF="$(hf_fetch "$RERANK_REPO" "$RERANK_PATTERN" "$MODELS/qwen3-reranker-0.6b")"
  for f in "$QWEN_GGUF" "$GRANITE_GGUF" "$RERANK_GGUF"; do [ -s "$f" ] || die "descarga vacía: $f"; done
  export_embedding
  printf '%s\n' "QWEN_GGUF=$QWEN_GGUF" "GRANITE_GGUF=$GRANITE_GGUF" "RERANK_GGUF=$RERANK_GGUF" "EMB_DIR=$EMB_DIR" \
      > "$LARRY_HOME/models.env"
}

load_models_env() {
  [ -f "$LARRY_HOME/models.env" ] || die "no existe models.env: ejecuta el paso 'models'"
  # shellcheck disable=SC1091
  . "$LARRY_HOME/models.env"
}

# =============================================================================
write_embed_server() {
  cat > "$LIB/larry_embed_server.py" <<'PY'
#!/usr/bin/env python3
"""Servidor /v1/embeddings (formato OpenAI) sobre OpenVINO GenAI.
Qwen3-Embedding-0.6B INT8 con forma estática [1, MAXLEN] para la NPU.
Campo extra opcional en la petición: "input_type": "query" | "document" (def. document)."""
import argparse, json, os, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import openvino_genai as ov

MODEL_DIR = os.environ["LARRY_EMB_MODEL_DIR"]
DEVICE    = os.environ.get("LARRY_EMB_DEVICE", "NPU")
MAXLEN    = int(os.environ.get("LARRY_EMB_MAXLEN", "512"))
CACHE     = os.environ.get("LARRY_EMB_CACHE", "")
MODEL_ID  = "Qwen3-Embedding-0.6B"
QUERY_INSTRUCTION = os.environ.get(
    "LARRY_EMB_QUERY_INSTRUCTION",
    "Instruct: Given a search query, retrieve relevant passages that answer the query\nQuery:")

CFG = ov.TextEmbeddingPipeline.Config(
    pooling_type=ov.TextEmbeddingPipeline.PoolingType.LAST_TOKEN,  # Qwen3-Embedding: último token
    normalize=True,
    max_length=MAXLEN,
    pad_to_max_length=True,    # forma estática (requisito de la NPU)
    batch_size=1,
    padding_side="left",
    query_instruction=QUERY_INSTRUCTION,
)
PIPE = ov.TextEmbeddingPipeline(MODEL_DIR, DEVICE, config=CFG, **({"CACHE_DIR": CACHE} if CACHE else {}))
LOCK = threading.Lock()        # la pipeline no es reentrante

def embed(texts, kind):
    out = []
    with LOCK:
        for t in texts:        # batch_size=1 => una petición por texto
            out.append(list(PIPE.embed_query(t) if kind == "query" else PIPE.embed_documents([t])[0]))
    return out

class H(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path in ("/health", "/v1/health"): return self._send(200, {"status": "ok"})
        if self.path == "/v1/models":
            return self._send(200, {"object": "list", "data": [{"id": MODEL_ID, "object": "model"}]})
        self._send(404, {"error": "not found"})
    def do_POST(self):
        if self.path not in ("/v1/embeddings", "/embeddings"): return self._send(404, {"error": "not found"})
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
            inp = body["input"]; texts = [inp] if isinstance(inp, str) else list(inp)
            if not all(isinstance(t, str) for t in texts): raise ValueError("input debe ser str o list[str]")
            vecs = embed(texts, body.get("input_type", "document"))
        except Exception as e:                      # noqa: BLE001
            return self._send(400, {"error": {"message": str(e)}})
        self._send(200, {"object": "list", "model": MODEL_ID,
                         "data": [{"object": "embedding", "index": i, "embedding": v} for i, v in enumerate(vecs)],
                         "usage": {"prompt_tokens": 0, "total_tokens": 0}})
    def log_message(self, *a): pass

if __name__ == "__main__":
    ap = argparse.ArgumentParser(); ap.add_argument("--host", default="127.0.0.1"); ap.add_argument("--port", type=int, required=True)
    a = ap.parse_args()
    embed(["warmup"], "document")        # compila/carga el blob de la NPU antes de declarar /health
    ThreadingHTTPServer((a.host, a.port), H).serve_forever()
PY
}

write_memory_cli() {
  cat > "$LIB/larry_memory.py" <<'PY'
#!/usr/bin/env python3
"""Memoria de LarryOS: SQLite + FTS5 + sqlite-vec (vec0), búsqueda híbrida + rerank.
  larry-memory init | add "texto" [--kind K --source S] | search "consulta" [-k N] | stats
Se conecta a llama-swap (modelos 'embed' y 'rerank')."""
import argparse, json, os, sqlite3, struct, sys, time, urllib.request

HOME = os.environ.get("LARRY_HOME", os.path.expanduser("~/.local/share/larryos"))
DB   = os.environ.get("LARRY_DB", os.path.join(HOME, "db", "memory.db"))
VEC0 = os.environ.get("LARRY_VEC0", os.path.join(HOME, "lib", "vec0"))
API  = os.environ.get("LARRY_API", "http://127.0.0.1:8080")
DIM  = int(os.environ.get("LARRY_EMB_DIM", "1024"))

def connect(path=DB):
    c = sqlite3.connect(path, timeout=5)
    c.enable_load_extension(True); c.load_extension(VEC0); c.enable_load_extension(False)
    # PRAGMAs de bajo consumo (la mayoría son POR CONEXIÓN: por eso viven aquí y no en el esquema)
    for p in ("journal_mode=WAL",            # lectores no bloquean al escritor
              "synchronous=NORMAL",          # seguro con WAL; menos fsync
              "mmap_size=268435456",         # lecturas vía mmap (256 MiB de ventana, no se reserva RAM)
              "cache_size=-8192",            # caché de páginas de 8 MiB
              "temp_store=FILE",             # temporales a disco, no a RAM
              "wal_autocheckpoint=1000",
              "journal_size_limit=67108864",
              "foreign_keys=ON", "busy_timeout=5000"):
        c.execute(f"PRAGMA {p}")
    return c

def init(c):
    c.executescript(f"""
    CREATE TABLE IF NOT EXISTS memory(
      id INTEGER PRIMARY KEY, kind TEXT NOT NULL DEFAULT 'note', source TEXT,
      content TEXT NOT NULL, created_at INTEGER NOT NULL DEFAULT (unixepoch()), meta TEXT);
    CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
      content, content='memory', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
    CREATE TRIGGER IF NOT EXISTS memory_ai AFTER INSERT ON memory BEGIN
      INSERT INTO memory_fts(rowid, content) VALUES (new.id, new.content); END;
    CREATE TRIGGER IF NOT EXISTS memory_ad AFTER DELETE ON memory BEGIN
      INSERT INTO memory_fts(memory_fts, rowid, content) VALUES('delete', old.id, old.content); END;
    CREATE TRIGGER IF NOT EXISTS memory_au AFTER UPDATE OF content ON memory BEGIN
      INSERT INTO memory_fts(memory_fts, rowid, content) VALUES('delete', old.id, old.content);
      INSERT INTO memory_fts(rowid, content) VALUES (new.id, new.content); END;
    CREATE VIRTUAL TABLE IF NOT EXISTS memory_vec USING vec0(embedding float[{DIM}] distance_metric=cosine);
    """)
    c.commit()

def post(path, payload, timeout=300):
    r = urllib.request.Request(API + path, json.dumps(payload).encode(), {"Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=timeout) as f:
        return json.load(f)

def embed(text, kind="document"):
    v = post("/v1/embeddings", {"model": "embed", "input": text, "input_type": kind})["data"][0]["embedding"]
    if len(v) != DIM: sys.exit(f"dimensión {len(v)} != {DIM}")
    return struct.pack(f"{DIM}f", *v)

def add(c, text, kind="note", source=None):
    blob = embed(text, "document")
    with c:                                            # una transacción: fila + FTS (trigger) + vector
        cur = c.execute("INSERT INTO memory(kind, source, content) VALUES (?,?,?)", (kind, source, text))
        c.execute("INSERT INTO memory_vec(rowid, embedding) VALUES (?,?)", (cur.lastrowid, blob))
    return cur.lastrowid

def fts_query(q):
    toks = [t.replace('"', "") for t in q.split() if t.strip('"')]
    return " OR ".join(f'"{t}"' for t in toks)

def search(c, q, k=5, pool=30, rerank=True):
    vec = c.execute("SELECT rowid FROM memory_vec WHERE embedding MATCH ? AND k = ? ORDER BY distance",
                    (embed(q, "query"), pool)).fetchall()
    fq = fts_query(q)
    fts = c.execute("SELECT rowid FROM memory_fts WHERE memory_fts MATCH ? ORDER BY rank LIMIT ?", (fq, pool)).fetchall() if fq else []
    score = {}                                           # Reciprocal Rank Fusion
    for lst in (vec, fts):
        for r, (rid,) in enumerate(lst):
            score[rid] = score.get(rid, 0.0) + 1.0 / (60 + r)
    ids = sorted(score, key=score.get, reverse=True)[:pool]
    if not ids: return []
    rows = {r[0]: r for r in c.execute(
        f"SELECT id, kind, source, content FROM memory WHERE id IN ({','.join('?'*len(ids))})", ids)}
    docs = [rows[i][3] for i in ids]
    if rerank and len(docs) > 1:
        res = post("/v1/rerank", {"model": "rerank", "query": q, "documents": docs, "top_n": k})["results"]
        ids = [ids[x["index"]] for x in sorted(res, key=lambda x: -x["relevance_score"])][:k]
    return [rows[i] for i in ids[:k]]

def main():
    ap = argparse.ArgumentParser(prog="larry-memory"); sp = ap.add_subparsers(dest="cmd", required=True)
    sp.add_parser("init"); sp.add_parser("stats")
    a = sp.add_parser("add"); a.add_argument("text"); a.add_argument("--kind", default="note"); a.add_argument("--source")
    s = sp.add_parser("search"); s.add_argument("query"); s.add_argument("-k", type=int, default=5); s.add_argument("--no-rerank", action="store_true")
    ns = ap.parse_args()
    os.makedirs(os.path.dirname(DB), exist_ok=True)
    c = connect(); init(c)
    if ns.cmd == "init": print("ok:", DB)
    elif ns.cmd == "add": print(add(c, ns.text, ns.kind, ns.source))
    elif ns.cmd == "search":
        for rid, kind, src, content in search(c, ns.query, ns.k, rerank=not ns.no_rerank):
            print(f"[{rid}] ({kind}{', ' + src if src else ''}) {content}")
    elif ns.cmd == "stats":
        print("filas:", c.execute("SELECT count(*) FROM memory").fetchone()[0],
              "| vec_version:", c.execute("SELECT vec_version()").fetchone()[0],
              "| journal_mode:", c.execute("PRAGMA journal_mode").fetchone()[0],
              "| mmap_size:", c.execute("PRAGMA mmap_size").fetchone()[0])
    c.execute("PRAGMA optimize"); c.close()

if __name__ == "__main__":
    main()
PY
  cat > "$BIN/larry-memory" <<EOF
#!/usr/bin/env bash
export LARRY_HOME="$LARRY_HOME" LARRY_EMB_DIM="$EMB_DIM"
exec /usr/bin/python3 "$LIB/larry_memory.py" "\$@"
EOF
  chmod 755 "$BIN/larry-memory" "$LIB/larry_embed_server.py" "$LIB/larry_memory.py"
}

# =============================================================================
detect_vulkan_device() {
  VK_DEV="$("$LLAMA_SERVER" --list-devices 2>&1 | grep -oE '^ *Vulkan[0-9]+' | tr -d ' ' | head -n1 || true)"
  if [ -z "$VK_DEV" ]; then
    [ "${SKIP_CHECKS:-0}" = 1 ] || die "llama-server no lista ningún dispositivo Vulkan (--list-devices)"
    VK_DEV="Vulkan0"
  fi
}

write_llama_swap_config() {
  detect_topology; detect_vulkan_device; load_models_env
  local main_t="$P_N" aux_t=$(( P_N > 4 ? 4 : P_N )) rr_t=2
  log "Generando $CFG_DIR/llama-swap.yaml  (iGPU=$VK_DEV | P-cores=$P_CPUS ($P_N) | E-cores=$E_CPUS ($E_N))"
  # Nota: \${PORT} se escribe literal: lo sustituye llama-swap en tiempo de ejecución.
  cat > "$CFG_DIR/llama-swap.yaml" <<EOF
# Generado por setup-larryos.sh — editable. Validar: llama-swap -config <este> -validate
healthCheckTimeout: 900     # 1er arranque: compilación del blob de la NPU / carga de 18 GB
logLevel: info
startPort: ${PORT_BASE}
sendLoadingState: true

macros:
  "llama": "${LLAMA_SERVER} --host 127.0.0.1 --port \${PORT}"
  "kv": "-fa on -ctk q8_0 -ctv q4_0"
  "cache": "--cache-reuse 256 --no-context-shift --ctx-checkpoints 16 --cache-ram 2048"

models:
  # --- NPU: embeddings (OpenVINO, INT8 simétrico, forma estática) -------------
  "embed":
    name: "Qwen3-Embedding-0.6B INT8 (${EMB_DEVICE})"
    cmd: |
      ${VENV}/bin/python ${LIB}/larry_embed_server.py --host 127.0.0.1 --port \${PORT}
    env:
      - "LARRY_EMB_MODEL_DIR=${EMB_DIR}"
      - "LARRY_EMB_DEVICE=${EMB_DEVICE}"
      - "LARRY_EMB_MAXLEN=${EMB_MAXLEN}"
      - "LARRY_EMB_CACHE=${CACHE}/ov"
    checkEndpoint: /health

  # --- CPU (E-cores): reranker -------------------------------------------------
  "rerank":
    name: "Qwen3-Reranker-0.6B Q8_0 (CPU)"
    cmd: |
      \${llama}
      -m ${RERANK_GGUF}
      --reranking
      -ngl 0 -dev none
      -c 8192 -b 4096 -ub 4096 -np 2
      -t ${rr_t} -Cr ${E_CPUS} --cpu-strict 1
    checkEndpoint: /health

  # --- CPU (P-cores): modelo auxiliar / router ligero --------------------------
  "aux":
    name: "Granite-4.0-H-Micro ${GRANITE_QUANT} (CPU P-cores)"
    cmd: |
      \${llama}
      -m ${GRANITE_GGUF}
      -ngl 0 -dev none
      \${kv} \${cache}
      -c ${MAIN_CTX} -np 1 --jinja
      -t ${aux_t} -Cr ${P_CPUS} --cpu-strict 0
    checkEndpoint: /health

  # --- iGPU + CPU híbrido: modelo principal ------------------------------------
  # Atención, KV cache y capas densas en la iGPU; los expertos MoE (ffn_*_exps) en RAM de CPU.
  "main":
    name: "Qwen3.6-35B-A3B IQ4_XS (iGPU + CPU)"
    cmd: |
      \${llama}
      -m ${QWEN_GGUF}
      -dev ${VK_DEV} -ngl 99
      -ot ".ffn_.*_exps.=CPU"
      \${kv} \${cache}
      -c ${MAIN_CTX} -np 1 --jinja
      -t ${main_t} -Cr ${P_CPUS} --cpu-strict 0
    checkEndpoint: /health

routing:
  router:
    use: group
    settings:
      groups:
        # Los tres modelos de NPU/CPU: viven juntos y nadie los descarga.
        "cpu-npu":
          swap: false
          exclusive: false
          persistent: true
          members: ["embed", "rerank", "aux"]
        # El de iGPU: no descarga a los anteriores ni ellos a él.
        "igpu":
          swap: false
          exclusive: false
          persistent: true
          members: ["main"]

hooks:
  on_startup:
    preload: ["embed", "rerank", "aux"]    # 'main' se carga en la primera petición
EOF
}

write_units() {
  log "Escribiendo unidades systemd --user"
  cat > "$UNIT_DIR/llama-swap.service" <<EOF
[Unit]
Description=LarryOS llama-swap (orquestador de modelos locales)
After=default.target

[Service]
Type=simple
ExecStart=${BIN}/llama-swap -config ${CFG_DIR}/llama-swap.yaml -listen ${LISTEN} -watch-config
Environment=HOME=%h
Environment=LARRY_HOME=${LARRY_HOME}
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
NoNewPrivileges=yes
# Los modelos GGUF se cargan por mmap: dejar que el kernel gestione la caché de páginas.
OOMScoreAdjust=200

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable llama-swap.service
}

step_config() {
  load_models_env
  write_embed_server; write_memory_cli
  write_llama_swap_config
  if ! "$BIN/llama-swap" -config "$CFG_DIR/llama-swap.yaml" -validate; then die "llama-swap rechaza la configuración generada"; fi
  "$BIN/larry-memory" init
}

step_services() {
  write_units
  if [ "${LINGER:-1}" = 1 ]; then
    loginctl enable-linger "$USER" 2>/dev/null || warn "no se pudo activar linger (sudo loginctl enable-linger $USER) para arrancar sin sesión"
  fi
  systemctl --user restart llama-swap.service
  log "Servicio arrancado. Logs: journalctl --user -u llama-swap -f"
}

# =============================================================================
step_hermes() {
  [ "${SKIP_HERMES:-0}" = 1 ] && { log "Hermes omitido (SKIP_HERMES=1)"; return; }
  if ! command -v hermes >/dev/null 2>&1; then
    log "Instalando Hermes Agent (se descarga el instalador y se muestra su SHA-256 antes de ejecutarlo)"
    curl -fsSL -o "$DL/hermes-install.sh" "$HERMES_INSTALL_URL"
    sha256sum "$DL/hermes-install.sh"
    bash "$DL/hermes-install.sh"
    hash -r; export PATH="$HOME/.local/bin:$PATH"
  fi
  command -v hermes >/dev/null 2>&1 || { warn "hermes no está en el PATH tras instalar; abre una shell nueva y repite: ./setup-larryos.sh hermes"; return; }
  log "Apuntando Hermes a llama-swap (modelo principal + auxiliares)"
  hermes config set model.provider custom
  hermes config set model.base_url "http://${LISTEN}/v1"
  hermes config set model.default main
  hermes config set model.api_key local
  # Tareas auxiliares -> Granite en P-cores. El resumidor debe tener contexto >= al del principal (ambos ${MAIN_CTX}).
  for t in compression title_generation; do
    hermes config set "auxiliary.${t}.base_url" "http://${LISTEN}/v1"
    hermes config set "auxiliary.${t}.model" aux
    hermes config set "auxiliary.${t}.api_key" local
    hermes config set "auxiliary.${t}.timeout" 600
  done
}

step_verify() {
  log "Verificación sin modelos"
  "$LLAMA_SERVER" --version 2>&1 | head -n1
  "$BIN/larry-memory" stats
  [ -s "$CFG_DIR/llama-swap.yaml" ] && "$BIN/llama-swap" -config "$CFG_DIR/llama-swap.yaml" -validate && echo "llama-swap.yaml válido"
  cat <<EOF

Siguientes pasos:
  systemctl --user status llama-swap
  curl -s http://${LISTEN}/v1/models | jq '.data[].id'
  larry-memory add "primera nota" && larry-memory search "nota"     (añade ${BIN} a tu PATH)
  hermes
EOF
}

# =============================================================================
main() {
  make_dirs
  local steps=("$@"); [ ${#steps[@]} -gt 0 ] || steps=(check build models config services hermes verify)
  for s in "${steps[@]}"; do
    case "$s" in
      check) step_check ;; build) step_build ;; models) step_models ;; config) step_config ;;
      services) step_services ;; hermes) step_hermes ;; verify) step_verify ;;
      *) die "paso desconocido: $s" ;;
    esac
  done
}
main "$@"
