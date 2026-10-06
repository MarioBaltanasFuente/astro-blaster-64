#!/data/data/com.termux/files/usr/bin/bash
# llm-diag.sh — Diagnóstico, compilación optimizada y benchmark de llama.cpp en Termux.
# Pensado para Pixel 9a (Tensor G4) con GrapheneOS y el modelo Qwen3.5-4B-Q4_K_M.
#
# Uso: bash llm-diag.sh [diag|build|bench|quick|apply|all]
#   diag   Revisa dispositivo, CPU, memoria, MTE y qué instrucciones usa llama.cpp
#   build  Compila llama.cpp optimizado para tu CPU (DOTPROD + MATMUL_INT8)
#   bench  Mide velocidad: paquete de Termux vs compilado, con varios hilos
#   quick  Medición rápida para comparar antes/después de cambiar un ajuste
#   apply  Actualiza ~/bin/qwen-start con el binario compilado y los mejores hilos
#   all    diag + build + bench + apply
#
# Variables opcionales: MODEL=ruta.gguf  ARCH=armv8.6-a+dotprod+i8mm  JOBS=4  THREADS=2,3,4,5,6,8

set -u
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
MODEL="${MODEL:-$HOME/models/Qwen3.5-4B-Q4_K_M.gguf}"
SRC="$HOME/llama.cpp"
BIN="$SRC/build/bin"
OUT="$HOME/llm-diag"
ARCH="${ARCH:-armv8.6-a+dotprod+i8mm}"
JOBS="${JOBS:-4}"
THREADS="${THREADS:-2,3,4,5,6,8}"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$OUT/report-$STAMP.txt"
mkdir -p "$OUT"

say()  { printf '\n=== %s ===\n' "$*"; }
ok()   { printf '  [OK] %s\n' "$*"; }
warn() { printf '  [!!] %s\n' "$*"; }
info() { printf '  %s\n' "$*"; }

mem_avail_mb() { awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo; }

stop_server() {
  if pkill -f llama-server 2>/dev/null; then
    info "Servidor llama-server detenido para liberar RAM."
    sleep 2
  fi
}

# Núcleos distintos del clúster de cpu0 (los lentos): en Tensor G4, A720 + X4.
big_cores() {
  awk -F: '/^processor/{p=$2+0}
           /^CPU part/{gsub(/ /,"",$2); if (p==0) l=$2; else if ($2!=l) c=c (c?",":"") p}
           END{print c}' /proc/cpuinfo
}

# Arranca llama-server un instante solo para leer su línea system_info.
sysinfo() {
  local b="$1" l="$OUT/sysinfo.log" s pid
  [ -x "$b" ] && [ -f "$MODEL" ] || return 0
  "$b" -m "$MODEL" -c 256 --port 8099 --host 127.0.0.1 > "$l" 2>&1 &
  pid=$!
  for _ in $(seq 1 30); do grep -q system_info "$l" && break; sleep 1; done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  s="$(grep -m1 system_info "$l" | sed 's/.*system_info: //')"
  info "$b"
  info "  ${s:-no se pudo leer system_info (ver $l)}"
  for x in DOTPROD MATMUL_INT8; do
    case "$s" in *"$x = 1"*) ok "$x activo" ;; *) warn "$x NO activo" ;; esac
  done
}

diag() {
  say "Dispositivo"
  info "Modelo:   $(getprop ro.product.model) ($(getprop ro.product.device))"
  info "Android:  $(getprop ro.build.version.release) (SDK $(getprop ro.build.version.sdk))"
  info "Build:    $(getprop ro.build.fingerprint)"
  info "Kernel:   $(uname -r)"

  say "CPU"
  awk -F: '/^processor/{p=$2+0} /^CPU part/{gsub(/ /,"",$2); part[p]=$2}
    END{ n["0xd80"]="Cortex-A520 (eficiencia)"; n["0xd81"]="Cortex-A720 (medio)"; n["0xd82"]="Cortex-X4 (rápido)"
         for (i=0; i in part; i++) printf "  cpu%d: %s %s\n", i, part[i], (part[i] in n ? n[part[i]] : "") }' /proc/cpuinfo
  for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/cpuinfo_max_freq; do
    [ -r "$f" ] && printf '  %s máx: %s MHz\n' "$(basename "$(dirname "$(dirname "$f")")")" "$(( $(cat "$f") / 1000 ))"
  done 2>/dev/null
  info "Núcleos rápidos detectados: $(big_cores)"

  say "Instrucciones que soporta el procesador"
  local feats
  feats=" $(grep -m1 '^Features' /proc/cpuinfo | cut -d: -f2) "
  for x in asimddp i8mm bf16 sve2; do
    case "$feats" in *" $x "*) ok "$x" ;; *) warn "$x no reportada" ;; esac
  done
  info "(asimddp = DOTPROD, i8mm = MATMUL_INT8)"

  say "Memoria"
  grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo | awk '{printf "  %-14s %6d MB\n", $1, $2/1024}'
  local a st sf
  a=$(mem_avail_mb)
  st=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo); sf=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
  if [ "$a" -lt 3500 ]; then warn "Poca RAM libre (${a} MB): reinicia el teléfono y cierra apps antes de medir."
  else ok "RAM libre suficiente (${a} MB)"; fi
  if [ "${st:-0}" -gt 0 ] && [ $(( sf * 100 / st )) -lt 30 ]; then warn "Swap casi llena: el sistema está bajo presión de memoria."; fi

  say "GrapheneOS: memory tagging (MTE) en un proceso de Termux"
  python - <<'PY'
import ctypes
try:
    r = ctypes.CDLL(None, use_errno=True).prctl(56, 0, 0, 0, 0)  # PR_GET_TAGGED_ADDR_CTRL
    if r < 0:
        print("  No se pudo consultar")
    else:
        mode = "sync" if r & 2 else "async" if r & 4 else "desactivado"
        print(f"  MTE: {mode} (0x{r:x})")
except Exception as e:
    print("  No se pudo consultar:", e)
PY

  say "llama.cpp y modelo"
  info "Paquete Termux llama-cpp: $(dpkg-query -W -f='${Version}' llama-cpp 2>/dev/null || echo 'no instalado')"
  if [ -x "$BIN/llama-server" ]; then ok "Versión compilada: $BIN/llama-server"
  else info "Versión compilada: aún no (bash llm-diag.sh build)"; fi
  info "qwen-start usa: $(grep -o '[^ ]*llama-server' ~/bin/qwen-start 2>/dev/null | head -1)"
  if [ -f "$MODEL" ]; then ok "Modelo: $MODEL ($(du -h "$MODEL" | cut -f1))"
  else warn "No encuentro el modelo en $MODEL"; fi
  stop_server
  sysinfo "$PREFIX/bin/llama-server"
  sysinfo "$BIN/llama-server"
}

build() {
  say "Compilando llama.cpp optimizado (-march=$ARCH)"
  stop_server
  pkg install -y git cmake clang ninja util-linux || { warn "Falló pkg install"; return 1; }
  if [ -d "$SRC/.git" ]; then git -C "$SRC" pull --ff-only
  else git clone --depth 1 https://github.com/ggml-org/llama.cpp "$SRC"; fi || { warn "Falló git"; return 1; }

  termux-wake-lock 2>/dev/null
  local flags=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_TESTS=OFF)
  rm -rf "$SRC/build"
  if ! cmake -S "$SRC" -B "$SRC/build" "${flags[@]}" -DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH="$ARCH"; then
    warn "La configuración con -march=$ARCH falló; probando GGML_NATIVE=ON"
    rm -rf "$SRC/build"
    cmake -S "$SRC" -B "$SRC/build" "${flags[@]}" -DGGML_NATIVE=ON || { termux-wake-unlock 2>/dev/null; return 1; }
  fi

  local t0=$SECONDS
  cmake --build "$SRC/build" -j "$JOBS" --target llama-server llama-bench \
    || { warn "Falló con -j $JOBS; reintentando con -j 2"; cmake --build "$SRC/build" -j 2 --target llama-server llama-bench; } \
    || { termux-wake-unlock 2>/dev/null; warn "La compilación falló. Pega el final del informe."; return 1; }
  termux-wake-unlock 2>/dev/null
  ok "Compilado en $(( (SECONDS - t0) / 60 )) min"
  info "Flags ARM: $(grep -oh -e '-march=[^ ]*' -e '-mcpu=[^ ]*' "$SRC/build/build.ninja" 2>/dev/null | sort -u | tr '\n' ' ')"
  sysinfo "$BIN/llama-server"
}

# Resume un CSV de llama-bench y guarda los mejores hilos en $OUT/best-<etiqueta>.env
summarize() {
  python - "$1" "$2" "$OUT" <<'PY'
import csv, sys
path, tag, out = sys.argv[1:4]
res = {}
for r in csv.DictReader(open(path)):
    k = "pp" if int(r["n_prompt"]) > 0 else "tg"
    res.setdefault(int(r["n_threads"]), {})[k] = float(r["avg_ts"])
if not res:
    sys.exit("  Sin resultados")
print(f"  {'hilos':>5} | {'lectura pp64':>14} | {'generación tg32':>16}")
for t in sorted(res):
    print(f"  {t:>5} | {res[t].get('pp', 0):>10.2f} t/s | {res[t].get('tg', 0):>12.2f} t/s")
bt = max(res, key=lambda t: res[t].get("tg", 0))
bp = max(res, key=lambda t: res[t].get("pp", 0))
print(f"  -> Mejor generación: {bt} hilos ({res[bt].get('tg', 0):.2f} t/s) | mejor lectura: {bp} hilos")
with open(f"{out}/best-{tag}.env", "w") as f:
    f.write(f"T={bt}\nTB={bp}\nTG={res[bt].get('tg', 0):.2f}\n")
PY
}

# run_bench <binario> <hilos> <etiqueta> [prefijo, p. ej. taskset -c 4,5,6,7]
run_bench() {
  local b="$1" t="$2" tag="$3" csv
  shift 3
  csv="$OUT/bench-$tag-$STAMP.csv"
  info "[$tag] hilos=$t ${*:+(con: $*)} — puede tardar unos minutos..."
  if ! "$@" "$b" -m "$MODEL" -t "$t" -p 64 -n 32 -r 2 -o csv > "$csv" 2>> "$OUT/bench-stderr.log"; then
    warn "Falló el benchmark [$tag] (ver $OUT/bench-stderr.log)"
    return 1
  fi
  summarize "$csv" "$tag"
}

bench() {
  say "Benchmark"
  [ -f "$MODEL" ] || { warn "No encuentro el modelo en $MODEL"; return 1; }
  stop_server
  local a big n
  a=$(mem_avail_mb)
  info "RAM libre: ${a} MB"
  [ "$a" -lt 3500 ] && warn "Poca RAM: los resultados saldrán peores de lo real."
  [ -x "$PREFIX/bin/llama-bench" ] && run_bench "$PREFIX/bin/llama-bench" 4 paquete
  if [ ! -x "$BIN/llama-bench" ]; then
    warn "No hay versión compilada. Ejecuta antes: bash llm-diag.sh build"
    return 1
  fi
  run_bench "$BIN/llama-bench" "$THREADS" compilado
  big="$(big_cores)"
  if [ -n "$big" ] && command -v taskset > /dev/null; then
    n=$(echo "$big" | tr ',' '\n' | wc -l)
    run_bench "$BIN/llama-bench" "$n" fijado taskset -c "$big"
  fi
}

quick() {
  say "Prueba rápida"
  stop_server
  local b="$BIN/llama-bench" T=4
  [ -x "$b" ] || b="$PREFIX/bin/llama-bench"
  [ -f "$OUT/best-compilado.env" ] && T=$(grep '^T=' "$OUT/best-compilado.env" | cut -d= -f2)
  run_bench "$b" "$T" "rapida-$(date +%H%M%S)"
}

apply() {
  say "Aplicando la mejor configuración a qwen-start"
  [ -x "$BIN/llama-server" ] || { warn "No hay versión compilada."; return 1; }
  [ -f "$OUT/best-compilado.env" ] || { warn "Ejecuta antes: bash llm-diag.sh bench"; return 1; }
  local T TB TG pre="" PT big
  T=$(grep '^T=' "$OUT/best-compilado.env" | cut -d= -f2)
  TB=$(grep '^TB=' "$OUT/best-compilado.env" | cut -d= -f2)
  TG=$(grep '^TG=' "$OUT/best-compilado.env" | cut -d= -f2)
  if [ -f "$OUT/best-fijado.env" ]; then
    PT=$(grep '^TG=' "$OUT/best-fijado.env" | cut -d= -f2)
    if python -c "import sys; sys.exit(0 if $PT > $TG * 1.05 else 1)"; then
      big="$(big_cores)"
      pre="taskset -c $big "
      T=$(echo "$big" | tr ',' '\n' | wc -l); TB=$T
      info "Fijar a núcleos rápidos es mejor ($PT vs $TG t/s): se usará taskset."
    fi
  fi
  [ -f ~/bin/qwen-start ] && cp ~/bin/qwen-start ~/bin/qwen-start.bak
  cat > ~/bin/qwen-start <<EOF
#!/data/data/com.termux/files/usr/bin/bash
# Generado por llm-diag.sh ($STAMP): $T hilos generación, $TB hilos lectura
pgrep -f llama-server > /dev/null && { echo "Ya está en marcha."; exit 0; }
termux-wake-lock
${pre}$BIN/llama-server -m $MODEL \\
  --jinja -c 8192 -t $T -tb $TB --port 8080 --host 127.0.0.1 \\
  > ~/llama.log 2>&1 &
echo "Cargando modelo... (log: ~/llama.log)"
until curl -s 127.0.0.1:8080/health | grep -q ok; do
  pgrep -f llama-server > /dev/null || { echo "Error al arrancar. Mira: tail -n 30 ~/llama.log"; exit 1; }
  sleep 1
done
echo "Listo."
EOF
  chmod +x ~/bin/qwen-start
  ok "qwen-start actualizado (copia anterior en ~/bin/qwen-start.bak)"
}

cmd="${1:-}"
case "$cmd" in
  diag|build|bench|quick|apply|all) ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

{
  echo "llm-diag $STAMP — modo: $cmd"
  if [ "$cmd" = all ]; then
    diag
    build && bench && apply
  else
    "$cmd"
  fi
  say "Fin"
  info "Informe guardado en: $LOG"
} 2>&1 | tee "$LOG"
