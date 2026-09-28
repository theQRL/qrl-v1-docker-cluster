#!/usr/bin/env bash
#
# qrl-cluster.sh — run a private multi-node QRL testnet on one machine.
#
# Starts several containers from the published qrl-docker images, joins them into
# one private chain, then checks the things that actually matter: that every node
# survives startup, that the wallet lands inside the volume rather than the
# container layer, that all nodes agree on one chain, and that mining works.
#
# Results, logs and a report are written to ./qrl-cluster-<timestamp>/ in the
# directory you run it from (override with --out).
#
#   ./qrl-cluster.sh              interactive
#   ./qrl-cluster.sh --help       options for unattended use
#
# Requires: docker, and permission to use it. `binutils` enables an extra check.

set -uo pipefail

REPO=qrledger/qrl-docker
RUN_ID="$(date +%Y%m%d-%H%M%S)"
# Results land in the directory the script was invoked from, unless --out or the
# prompt says otherwise. OUT is resolved after argument parsing.
OUTDIR_BASE="$PWD"
OUT=""
NET=""
PREFIX="qrlc"

# defaults, overridable by flags or the prompts
NODES=0
VERSIONS=()
DIFFICULTY=10000
WATCH_MINS=10
KEEP=0
ASSUME_YES=0

C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_OK=$'\033[32m'; C_BAD=$'\033[31m'
C_WARN=$'\033[33m'; C_HEAD=$'\033[1m'

die()  { printf '%sERROR%s %s\n' "$C_BAD" "$C_RESET" "$*" >&2; exit 1; }
ok()   { printf '%sok%s   %s\n' "$C_OK" "$C_RESET" "$*"; }
bad()  { printf '%sFAIL%s %s\n' "$C_BAD" "$C_RESET" "$*"; }
warn() { printf '%snote%s %s\n' "$C_WARN" "$C_RESET" "$*"; }
head_() { printf '\n%s%s%s\n' "$C_HEAD" "$*" "$C_RESET"; }

usage() {
  cat <<EOF
qrl-cluster.sh — private multi-node QRL testnet on a single machine

  --nodes N            number of nodes (default: asked)
  --versions a,b,c     images to use, e.g. noble,jammy (default: asked)
  --difficulty N       genesis_difficulty; lower mines faster (default $DIFFICULTY)
  --watch N            minutes to let the cluster run before checking (default $WATCH_MINS)
  --out DIR            where to write results (default: the current directory)
  --keep               leave the cluster running at the end
  --yes                do not prompt
  --help

Results go to <out>/qrl-cluster-<timestamp>/ — by default alongside wherever you
ran this from.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --nodes) NODES="${2:-}"; shift 2 ;;
    --versions) IFS=, read -r -a VERSIONS <<<"${2:-}"; shift 2 ;;
    --difficulty) DIFFICULTY="${2:-}"; shift 2 ;;
    --watch) WATCH_MINS="${2:-}"; shift 2 ;;
    --out) OUTDIR_BASE="${2:-}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

# ----------------------------------------------------------------- preflight ---
command -v docker >/dev/null || die "docker is not installed"
docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon (is it running, and are you in the docker group?)"

ARCH="$(docker version --format '{{.Server.Arch}}' 2>/dev/null || uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
esac

# bionic and focal publish amd64 only: their PyPI dependencies have never built
# for arm64.
ALL_AMD64=(bionic focal jammy noble resolute)
ALL_ARM64=(jammy noble resolute)
if [ "$ARCH" = arm64 ]; then AVAILABLE=("${ALL_ARM64[@]}"); else AVAILABLE=("${ALL_AMD64[@]}"); fi

HAVE_OBJDUMP=0; command -v objdump >/dev/null && HAVE_OBJDUMP=1

# ----------------------------------------------------------------------- TUI ---
choose_interactively() {
  if command -v whiptail >/dev/null; then
    local items=() sel
    for v in "${AVAILABLE[@]}"; do items+=("$v" "Ubuntu $v image" ON); done
    sel="$(whiptail --title "qrl-cluster" \
      --checklist "Which images should the cluster use?\n(detected architecture: $ARCH)" \
      16 60 "${#AVAILABLE[@]}" "${items[@]}" 3>&1 1>&2 2>&3)" || exit 1
    # whiptail returns space-separated, quoted
    eval "VERSIONS=($sel)"
    [ "${#VERSIONS[@]}" -eq 0 ] && die "no images selected"

    NODES="$(whiptail --title "qrl-cluster" --inputbox \
      "How many nodes in total?\n\nThey are spread across the images you chose.\nMore than about 6 gets heavy on a laptop." \
      12 60 "${#VERSIONS[@]}" 3>&1 1>&2 2>&3)" || exit 1

    DIFFICULTY="$(whiptail --title "qrl-cluster" --inputbox \
      "genesis_difficulty\n\nLower mines faster. 10000 gives a block every few seconds on a modern machine." \
      12 60 "$DIFFICULTY" 3>&1 1>&2 2>&3)" || exit 1

    WATCH_MINS="$(whiptail --title "qrl-cluster" --inputbox \
      "How many minutes should the cluster run before the checks?" \
      10 60 "$WATCH_MINS" 3>&1 1>&2 2>&3)" || exit 1

    OUTDIR_BASE="$(whiptail --title "qrl-cluster" --inputbox \
      "Where should the report, logs and configs be written?\n\nA timestamped folder is created inside this directory." \
      11 68 "$OUTDIR_BASE" 3>&1 1>&2 2>&3)" || exit 1
  else
    warn "whiptail not found — using plain prompts"
    printf 'Available images for %s: %s\n' "$ARCH" "${AVAILABLE[*]}"
    read -rp "Images (comma separated, blank = all): " reply
    if [ -z "$reply" ]; then VERSIONS=("${AVAILABLE[@]}"); else IFS=, read -r -a VERSIONS <<<"$reply"; fi
    read -rp "Number of nodes [${#VERSIONS[@]}]: " reply; NODES="${reply:-${#VERSIONS[@]}}"
    read -rp "genesis_difficulty [$DIFFICULTY]: " reply; DIFFICULTY="${reply:-$DIFFICULTY}"
    read -rp "Minutes to run before checking [$WATCH_MINS]: " reply; WATCH_MINS="${reply:-$WATCH_MINS}"
    read -rp "Results directory [$OUTDIR_BASE]: " reply; OUTDIR_BASE="${reply:-$OUTDIR_BASE}"
  fi
}

[ "${#VERSIONS[@]}" -eq 0 ] && { [ "$ASSUME_YES" = 1 ] && VERSIONS=("${AVAILABLE[@]}") || choose_interactively; }
[ "$NODES" -gt 0 ] 2>/dev/null || NODES="${#VERSIONS[@]}"

for v in "${VERSIONS[@]}"; do
  found=0; for a in "${AVAILABLE[@]}"; do [ "$v" = "$a" ] && found=1; done
  [ "$found" = 1 ] || die "image '$v' is not published for $ARCH (available: ${AVAILABLE[*]})"
done
[ "$NODES" -ge 2 ] || die "need at least 2 nodes to test convergence"

# assign images round-robin across the requested node count
NODE_IMAGE=(); NODE_NAME=()
for ((i=0; i<NODES; i++)); do
  v="${VERSIONS[$((i % ${#VERSIONS[@]}))]}"
  NODE_IMAGE+=("$v"); NODE_NAME+=("$PREFIX-$((i+1))-$v")
done

OUT="${OUTDIR_BASE%/}/qrl-cluster-$RUN_ID"
mkdir -p "$OUT/logs" || die "cannot create $OUT"

# --------------------------------------------------------- subnet selection ---
# Pick a subnet that collides with neither the host's routes nor another docker
# network. Picking blind is how you take your own SSH session down.
pick_subnet() {
  local inuse; inuse="$( { ip route 2>/dev/null | awk '{print $1}'; \
      docker network ls -q | xargs -r docker network inspect \
        --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null; } | tr ' ' '\n' | sort -u)"
  local o
  for o in 80 81 82 83 84 85 90 91 92 93 94 95; do
    if ! grep -q "^10\.$o\." <<<"$inuse"; then printf '10.%d.0.0/16' "$o"; return 0; fi
  done
  return 1
}
SUBNET="$(pick_subnet)" || die "could not find a free 10.x.0.0/16 subnet"
BASE_IP="${SUBNET%.0.0/16}"

cleanup() {
  [ "$KEEP" = 1 ] && return
  printf '\n'; head_ "Tearing down"
  for n in "${NODE_NAME[@]}"; do docker rm -f "$n" >/dev/null 2>&1; done
  for n in "${NODE_NAME[@]}"; do docker volume rm -f "vol-$n" >/dev/null 2>&1; done
  [ -n "$NET" ] && docker network rm "$NET" >/dev/null 2>&1
  ok "cluster removed (results kept in $OUT)"
}

# ------------------------------------------------------------------- startup ---
head_ "qrl-cluster $RUN_ID"
printf '  architecture : %s\n  images       : %s\n  nodes        : %s\n  difficulty   : %s\n  subnet       : %s\n  results      : %s\n' \
  "$ARCH" "${VERSIONS[*]}" "$NODES" "$DIFFICULTY" "$SUBNET" "$OUT"

if [ "$ASSUME_YES" != 1 ]; then
  read -rp $'\nStart? [Y/n] ' reply; case "${reply:-y}" in [Nn]*) exit 0 ;; esac
fi
trap cleanup EXIT INT TERM

head_ "Pulling images"
for v in "${VERSIONS[@]}"; do
  printf '  %-9s ' "$v"
  if docker pull -q "$REPO:$v" >/dev/null 2>&1; then
    printf 'ok  (%s)\n' "$(docker image inspect --format '{{.Created}}' "$REPO:$v" | cut -c1-10)"
  else printf '%sfailed%s\n' "$C_BAD" "$C_RESET"; die "could not pull $REPO:$v"; fi
done

NET="$PREFIX-net-$RUN_ID"
docker network create --subnet "$SUBNET" "$NET" >/dev/null || die "could not create network"
ok "network $NET on $SUBNET"

head_ "Creating wallets and starting nodes"
declare -a NODE_IP NODE_ADDR
for ((i=0; i<NODES; i++)); do
  n="${NODE_NAME[$i]}"; v="${NODE_IMAGE[$i]}"; ip="$BASE_IP.0.$((11+i))"
  NODE_IP+=("$ip")
  docker volume create "vol-$n" >/dev/null
  # one address per node so blocks can be attributed to a specific image
  addr="$(docker run --rm -v "vol-$n":/home/qrl/.qrl --entrypoint sh "$REPO:$v" -c \
    'qrl --wallet_dir /home/qrl/.qrl wallet_gen >/dev/null 2>&1
     qrl --wallet_dir /home/qrl/.qrl wallet_ls 2>/dev/null | awk "\$1==\"0\"{print \$2}"' 2>/dev/null)"
  [ -n "$addr" ] || die "$n: wallet generation failed"
  NODE_ADDR+=("$addr")
  printf '  %-22s %-14s %s\n' "$n" "$ip" "${addr:0:22}..."
done

for ((i=0; i<NODES; i++)); do
  n="${NODE_NAME[$i]}"; v="${NODE_IMAGE[$i]}"
  {
    # mining_enabled is required: --miningAddress alone is ignored and the node
    # logs "Mining is not enabled but you sent some mining configuration".
    echo "mining_enabled: True"
    echo "mining_thread_count: 1"
    echo "genesis_difficulty: $DIFFICULTY"
    echo "peer_list:"
    for ((j=0; j<NODES; j++)); do [ "$j" != "$i" ] && echo "  - '${NODE_IP[$j]}:19000'"; done
  } > "$OUT/$n.yml"
  # --network-type testnet is not optional: it sets hard_fork_heights [0,0,0].
  # A node without it computes different consensus rules and forks.
  docker run -d --name "$n" --network "$NET" --ip "${NODE_IP[$i]}" \
    -v "vol-$n":/home/qrl/.qrl -v "$OUT/$n.yml":/etc/qrl/config.yml:ro \
    --entrypoint sh "$REPO:$v" -c \
    "cp /etc/qrl/config.yml \$HOME/.qrl/config.yml
     ln -sfn \$HOME/.qrl \$HOME/.qrl-testnet
     exec start_qrl --network-type testnet --miningAddress ${NODE_ADDR[$i]}" >/dev/null \
    || die "$n: failed to start"
done
ok "$NODES nodes started"

# -------------------------------------------------------------- live display ---
probe() {  # $1 = container; prints "height peers state" or nothing
  docker exec "$1" python3 -c "
import grpc
from qrl.generated import qrl_pb2_grpc, qrl_pb2
s=qrl_pb2_grpc.PublicAPIStub(grpc.insecure_channel('127.0.0.1:19009'))
i=s.GetNodeState(qrl_pb2.GetNodeStateReq(), timeout=8).info
print(i.block_height, i.num_connections, i.state)" 2>/dev/null
}

if [ "$WATCH_MINS" -lt 6 ]; then
  warn "RandomX needs ~2-3 minutes to build its dataset before the first block; $WATCH_MINS minutes may not be enough to see mining"
fi
head_ "Running for $WATCH_MINS minutes"
printf '%s  ctrl-c stops and tears down; results are kept either way%s\n\n' "$C_DIM" "$C_RESET"
END=$(( $(date +%s) + WATCH_MINS*60 ))
LINES_DRAWN=0
while :; do
  out=""
  for ((i=0; i<NODES; i++)); do
    n="${NODE_NAME[$i]}"
    st="$(docker inspect -f '{{.State.Status}}:{{.State.ExitCode}}' "$n" 2>/dev/null || echo 'gone:?')"
    code="${st##*:}"; cstate="${st%%:*}"
    if [ "$cstate" != running ]; then
      mark="$C_BAD$cstate (exit $code)$C_RESET"
      [ "$code" = 132 ] && mark="$C_BAD""SIGILL — illegal instruction$C_RESET"
      out+="$(printf '  %-22s %-10s %s\033[K' "$n" "${NODE_IMAGE[$i]}" "$mark")"$'\n'
    else
      read -r h p s <<<"$(probe "$n")"
      out+="$(printf '  %-22s %-10s height %-7s peers %-4s %-8s\033[K' \
        "$n" "${NODE_IMAGE[$i]}" "${h:-–}" "${p:-–}" "$( [ "${s:-}" = 3 ] && echo synced || echo starting )")"$'\n'
    fi
  done
  remain=$(( END - $(date +%s) ))
  [ "$LINES_DRAWN" -gt 0 ] && printf '\033[%dA' "$LINES_DRAWN"
  printf '%s' "$out"
  printf '  %s%s remaining%s\033[K\n' "$C_DIM" "$( [ $remain -gt 0 ] && printf '%dm%02ds' $((remain/60)) $((remain%60)) || echo '0s' )" "$C_RESET"
  LINES_DRAWN=$(( NODES + 1 ))
  [ "$remain" -le 0 ] && break
  sleep 5
done

# ------------------------------------------------------------------- checks ---
PASS=0; FAIL=0
pass() { ok "$*"; PASS=$((PASS+1)); }
fail() { bad "$*"; FAIL=$((FAIL+1)); }

head_ "Checks"

# 1. every node survived. exit 132 is the signature of a CPU-portability defect.
alive=0; sigill=0
for n in "${NODE_NAME[@]}"; do
  st="$(docker inspect -f '{{.State.Status}}:{{.State.ExitCode}}' "$n" 2>/dev/null)"
  [ "${st%%:*}" = running ] && alive=$((alive+1))
  [ "${st##*:}" = 132 ] && { sigill=$((sigill+1)); bad "$n died with SIGILL — this image is not built for this CPU"; }
done
[ "$alive" = "$NODES" ] && pass "all $NODES nodes still running" || fail "$((NODES-alive)) of $NODES nodes died"
[ "$sigill" = 0 ] && pass "no illegal-instruction crashes" || fail "$sigill node(s) hit an illegal instruction"

# 2. the wallet must be inside the volume, or `docker rm` destroys it
wok=0
for n in "${NODE_NAME[@]}"; do
  docker exec "$n" test -f /home/qrl/.qrl/wallet.json 2>/dev/null && wok=$((wok+1))
done
[ "$wok" = "$NODES" ] && pass "wallet.json inside the volume on every node" \
  || fail "wallet.json missing from the volume on $((NODES-wok)) node(s) — it would be lost on container removal"

# 3. one chain, not several. identical hashes at a sampled depth, not similar heights.
hmin=""
for n in "${NODE_NAME[@]}"; do
  read -r h _ _ <<<"$(probe "$n")"
  [ -n "${h:-}" ] || continue
  { [ -z "$hmin" ] || [ "$h" -lt "$hmin" ]; } && hmin="$h"
done
if [ -n "${hmin:-}" ] && [ "$hmin" -ge 2 ]; then
  # sample one below the lowest tip: tips legitimately differ while a block
  # propagates, so comparing tips would report a fork that is not there
  depth=$(( hmin - 1 ))
  hashes="$(for n in "${NODE_NAME[@]}"; do
      docker exec "$n" python3 -c "
import grpc
from qrl.generated import qrl_pb2_grpc, qrl_pb2
s=qrl_pb2_grpc.PublicAPIStub(grpc.insecure_channel('127.0.0.1:19009'))
b=s.GetBlockByNumber(qrl_pb2.GetBlockByNumberReq(block_number=$depth), timeout=10).block
print(b.header.hash_header.hex())" 2>/dev/null
    done | sort -u)"
  n_distinct="$(grep -c . <<<"$hashes")"
  if [ "$n_distinct" = 1 ]; then pass "all nodes agree on one chain at height $depth ($(cut -c1-12 <<<"$hashes"))"
  else fail "$n_distinct different chains at height $depth — the cluster has forked"; fi
  printf '%s  (tips may differ by a block or two; that is propagation, not a fork)%s\n' "$C_DIM" "$C_RESET"
else
  fail "cluster did not produce enough blocks to compare — try a lower difficulty or a longer run"
fi

# 4. mining actually works, and by more than one node
miners="$(docker exec "${NODE_NAME[0]}" python3 -c "
import grpc
from qrl.generated import qrl_pb2_grpc, qrl_pb2
s=qrl_pb2_grpc.PublicAPIStub(grpc.insecure_channel('127.0.0.1:19009'))
i=s.GetNodeState(qrl_pb2.GetNodeStateReq(), timeout=8).info
seen=set()
for h in range(max(1,i.block_height-40), i.block_height+1):
    try:
        b=s.GetBlockByNumber(qrl_pb2.GetBlockByNumberReq(block_number=h), timeout=8).block
        for t in b.transactions:
            if t.WhichOneof('transactionType')=='coinbase':
                seen.add(t.coinbase.addr_to.hex())
    except Exception: pass
print(len(seen))" 2>/dev/null)"
if [ -n "${miners:-}" ] && [ "$miners" -ge 1 ]; then
  pass "$miners distinct miner(s) produced blocks in the last 40"
  [ "$miners" = 1 ] && warn "only one node won blocks — normal at low difficulty, the fastest node tends to win every race"
else fail "no blocks were mined"; fi

# 5. optional: is the image actually built for a portable CPU baseline?
if [ "$HAVE_OBJDUMP" = 1 ] && [ "$ARCH" = amd64 ]; then
  head_ "CPU portability of the images"
  printf '%s  Counting AVX-512 (EVEX-prefixed) instructions. Any real ones mean the\n  image needs a CPU with AVX-512, which most consumer machines lack.%s\n' "$C_DIM" "$C_RESET"
  for v in "${VERSIONS[@]}"; do
    cid="$(docker create "$REPO:$v" 2>/dev/null)"
    tot=0
    for m in _pyqrandomx _pyqryptonight; do
      p="$(docker run --rm --entrypoint sh "$REPO:$v" -c "find / -name '${m}*.so' 2>/dev/null | head -1")"
      [ -n "$p" ] || continue
      docker cp "$cid:$p" "$OUT/$v$m.so" >/dev/null 2>&1 || continue
      # Exclude by SYMBOL, not by decode text: the byte at r4_add is a RandomX
      # JIT code template (data, not an instruction) and different objdump
      # builds render it as <unknown>, .byte 0x62 or (bad).
      c="$(objdump -d "$OUT/$v$m.so" 2>/dev/null | awk '
        /^[0-9a-f]+ <.*>:/ { sym=$2; gsub(/[<>:]/,"",sym) }
        /^[[:space:]]+[0-9a-f]+:[[:space:]]+62 / { if (sym !~ /^r[0-9]+_add$/) n++ }
        END { print n+0 }')"
      tot=$((tot + c))
      rm -f "$OUT/$v$m.so"
    done
    docker rm -f "$cid" >/dev/null 2>&1
    [ "$tot" = 0 ] && pass "$v: portable (no AVX-512 required)" || fail "$v: $tot AVX-512 instructions — requires an AVX-512 CPU"
  done
elif [ "$ARCH" = amd64 ]; then
  warn "install binutils to also check whether the images require AVX-512"
fi

# ------------------------------------------------------------------- report ---
for n in "${NODE_NAME[@]}"; do docker logs "$n" >"$OUT/logs/$n.log" 2>&1; done

{
  echo "# qrl-cluster report — $RUN_ID"
  echo
  echo "host architecture : $ARCH"
  echo "images            : ${VERSIONS[*]}"
  echo "nodes             : $NODES"
  echo "genesis_difficulty: $DIFFICULTY"
  echo "ran for           : $WATCH_MINS minutes"
  echo
  echo "checks passed: $PASS"
  echo "checks failed: $FAIL"
  echo
  echo "| node | image | status | height | peers |"
  echo "|---|---|---|---|---|"
  for ((i=0; i<NODES; i++)); do
    n="${NODE_NAME[$i]}"
    st="$(docker inspect -f '{{.State.Status}} (exit {{.State.ExitCode}})' "$n" 2>/dev/null || echo gone)"
    read -r h p _ <<<"$(probe "$n")"
    echo "| $n | ${NODE_IMAGE[$i]} | $st | ${h:-–} | ${p:-–} |"
  done
  echo
  echo "Per-node logs are in logs/. Node configs are the *.yml files beside this report."
} > "$OUT/report.md"

head_ "Result"
if [ "$FAIL" = 0 ]; then
  printf '  %sall %d checks passed%s\n' "$C_OK" "$PASS" "$C_RESET"
else
  printf '  %s%d of %d checks failed%s\n' "$C_BAD" "$FAIL" "$((PASS+FAIL))" "$C_RESET"
fi
printf '  report : %s/report.md\n  logs   : %s/logs/\n' "$OUT" "$OUT"

if [ "$KEEP" = 1 ]; then
  trap - EXIT
  printf '\n  cluster left running (--keep). Remove it with:\n'
  printf '    for n in %s; do docker rm -f "$n"; docker volume rm -f "vol-$n"; done\n    docker network rm %s\n' "${NODE_NAME[*]}" "$NET"
fi
exit $(( FAIL > 0 ))
