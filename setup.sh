#!/usr/bin/env bash
# eMondrian Lex: install, start, update.  ./setup.sh --help
set -euo pipefail

cd "$(dirname "$0")"
HERE="$(pwd)"

PORT="" GIT_REMOTE="" DOMAIN="" VERSION="" INTERACTIVE=0 UPDATE=0 WAIT=120

usage() {
  cat <<'EOF'
Usage: ./setup.sh [options]

Installs and starts eMondrian Lex with Docker: the web UI and, for agents, MCP at /mcp.
Run it again at any time: it keeps ./base (your knowledge base) and .env (your settings),
and applies what you pass it.

  --port N            the port Lex answers on (default 8770)
  --git-remote URL    push every change of the knowledge base to this git remote
  --domain NAME       serve https://NAME/ with a certificate (Caddy, ports 80 and 443)
  --version TAG       run this image version instead of the one this repository names
  --update            update: pull this repository and the image, then restart
  --interactive       ask for the settings instead of taking the defaults
  --wait SECONDS      how long to wait for Lex to answer (default 120)
  -h, --help          this text

Settings live in .env (made from .env.example on the first run).
EOF
}

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die()  { printf '\nsetup.sh: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --port)        PORT="${2:?--port needs a number}"; shift 2 ;;
    --git-remote)  GIT_REMOTE="${2:?--git-remote needs a URL}"; shift 2 ;;
    --domain)      DOMAIN="${2:?--domain needs a name}"; shift 2 ;;
    --version)     VERSION="${2:?--version needs a tag}"; shift 2 ;;
    --wait)        WAIT="${2:?--wait needs seconds}"; shift 2 ;;
    --update)      UPDATE=1; shift ;;
    --interactive) INTERACTIVE=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             usage >&2; die "unknown option: $1" ;;
  esac
done

# ---- where we are
case "$(uname -s)" in
  Linux|Darwin) ;;
  MINGW*|MSYS*|CYGWIN*)
    die "on Windows, run this inside WSL2 (wsl --install), with Docker Desktop's WSL2 backend: https://docs.docker.com/desktop/features/wsl/" ;;
  *) say "warning: $(uname -s) is not tested; going on" ;;
esac

# ---- 1. Docker
step "Checking Docker"
command -v docker >/dev/null 2>&1 || die "Docker is not installed.
  Linux: https://docs.docker.com/engine/install/   macOS: https://docs.docker.com/desktop/setup/install/mac-install/"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is missing (the 'docker compose' command).
  https://docs.docker.com/compose/install/"
docker info >/dev/null 2>&1 || die "Docker is installed but not running, or this user may not use it.
  Start Docker (Docker Desktop, or: sudo systemctl start docker); on Linux, add yourself to the
  docker group (sudo usermod -aG docker \$USER, then log in again)."
say "$(docker --version); $(docker compose version | head -1)"

# ---- 2. the update, first: the repository's own files
if [ "$UPDATE" = 1 ]; then
  step "Updating this repository"
  if [ -d .git ] && git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    git pull --ff-only || die "git pull failed: commit or stash your changes to this repository's files, then run again"
  elif [ -d .git ]; then
    say "this clone follows no remote branch: skipping (git pull by hand)"
  else
    say "not a git clone: skipping (download the new release by hand)"
  fi
fi

# ---- 3. .env: made once, then only the keys you pass change
setenv() {    # setenv KEY VALUE: set KEY in .env, adding it when it is not there
  local k="$1" v="$2" tmp
  tmp="$(mktemp)"
  if grep -q "^${k}=" .env; then
    awk -v k="$k" -v v="$v" 'BEGIN{FS=OFS="="} $1==k{print k"="v; next} {print}' .env > "$tmp"
  elif grep -q "^#${k}=" .env; then
    awk -v k="$k" -v v="$v" 'BEGIN{FS=OFS="="} $1=="#"k{print k"="v; next} {print}' .env > "$tmp"
  else
    cp .env "$tmp"; printf '%s=%s\n' "$k" "$v" >> "$tmp"
  fi
  cat "$tmp" > .env; rm -f "$tmp"
}
getenv() { grep "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- || true; }

step "Settings (.env)"
if [ ! -f .env ]; then
  cp .env.example .env
  chmod 600 .env
  setenv LEX_UID "$(id -u)"
  setenv LEX_GID "$(id -g)"
  say "made .env from .env.example"
else
  say "keeping .env"
fi

if [ "$INTERACTIVE" = 1 ]; then
  ask() { local q="$1" def="$2" a; read -r -p "$q [$def]: " a; printf '%s' "${a:-$def}"; }
  PORT="$(ask "Port" "${PORT:-$(getenv LEX_PORT)}")"
  GIT_REMOTE="$(ask "Git remote to push the knowledge base to (empty: none)" "${GIT_REMOTE:-$(getenv LEX_GIT_REMOTE)}")"
  DOMAIN="$(ask "Public name for https (empty: plain http)" "${DOMAIN:-$(getenv LEX_DOMAIN)}")"
fi
[ -n "$PORT" ] && { case "$PORT" in *[!0-9]*) die "--port: not a number: $PORT";; esac; setenv LEX_PORT "$PORT"; }
[ -n "$GIT_REMOTE" ] && setenv LEX_GIT_REMOTE "$GIT_REMOTE"
[ -n "$DOMAIN" ] && setenv LEX_DOMAIN "$DOMAIN"
[ -n "$VERSION" ] && setenv LEX_VERSION "$VERSION"

mkdir -p base deploy/no-ssh
if [ "$(getenv LEX_UID)" = "$(id -u)" ] && [ ! -w base ]; then
  die "./base is not writable by you ($(id -un)); fix its owner: sudo chown -R $(id -u):$(id -g) base"
fi

PROFILE=()
[ -n "$(getenv LEX_DOMAIN)" ] && PROFILE=(--profile tls)

# ---- 4. the image
step "Getting the image"
IMAGE="$(docker compose config --images 2>/dev/null | grep -m1 'emondrian/lex' || true)"
if ! docker compose ${PROFILE[@]+"${PROFILE[@]}"} pull; then
  if [ -n "$IMAGE" ] && docker image inspect "$IMAGE" >/dev/null 2>&1; then
    say "warning: could not pull $IMAGE; using the copy already on this machine"
  else
    die "could not pull ${IMAGE:-the image}: check the network, or the version (--version)"
  fi
fi

# ---- 5. start
step "Starting Lex"
docker compose ${PROFILE[@]+"${PROFILE[@]}"} up -d --remove-orphans

# ---- 6. wait until it answers
PORT_NOW="$(getenv LEX_PORT)"; PORT_NOW="${PORT_NOW:-8770}"
URL="http://127.0.0.1:${PORT_NOW}/healthz"
step "Waiting for Lex to answer ($URL)"
ok=0
for _ in $(seq 1 "$WAIT"); do
  if curl -fsS -o /dev/null "$URL" 2>/dev/null || wget -q -O /dev/null "$URL" 2>/dev/null; then ok=1; break; fi
  sleep 1
done
if [ "$ok" != 1 ]; then
  docker compose logs --tail 40 lex >&2 || true
  die "Lex did not answer within ${WAIT} s; the log is above (docker compose logs lex)"
fi

# ---- 7. where it is
host_ip() {
  if command -v hostname >/dev/null 2>&1 && hostname -I >/dev/null 2>&1; then hostname -I | awk '{print $1}'
  elif command -v ipconfig >/dev/null 2>&1; then ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true
  fi
}
IP="$(host_ip)"; IP="${IP:-localhost}"
DOMAIN_NOW="$(getenv LEX_DOMAIN)"
step "Lex is running"
if [ -n "$DOMAIN_NOW" ]; then
  say "  Web:   https://${DOMAIN_NOW}/"
  say "  MCP:   https://${DOMAIN_NOW}/mcp"
fi
say "  Web:   http://${IP}:${PORT_NOW}/"
say "  MCP:   http://${IP}:${PORT_NOW}/mcp     (for an agent: a Streamable HTTP MCP server)"
say "  Base:  ${HERE}/base   (a git repository: every change is a commit)"
REMOTE_NOW="$(getenv LEX_GIT_REMOTE)"
# a token in an https remote is never printed
[ -n "$REMOTE_NOW" ] && say "  Push:  $(printf '%s' "$REMOTE_NOW" | sed -E 's#(https?://)[^@/]*@#\1#')  (state: http://127.0.0.1:${PORT_NOW}/healthz, \"git\")" || true
say ""
say "  Stop: docker compose down    Logs: docker compose logs -f lex    Update: ./setup.sh --update"
