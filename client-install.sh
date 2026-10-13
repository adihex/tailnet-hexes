#!/bin/sh
# Install the hexes client into this account. Run on a tailnet machine, not on the hexes host.
# The repo must already be at $HEX_CLIENT_ROOT (default ~/tailnet-hexes), or a bundle at
# $HEX_BUNDLE (default /sdcard/hexes-client.tgz on Android).
set -eu

ROOT="${HEX_CLIENT_ROOT:-$HOME/tailnet-hexes}"
BUNDLE="${HEX_BUNDLE:-}"
TOKEN_SRC="${HEX_TOKEN_SRC:-}"
STATUS="${HEX_STATUS:-}"
HOST_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJkUBl8OvejoYgCj5BRM1rBCnTkE1UTWNhs9JVycHx3I adihex@adi-linux'
SSH_HOST="${HEX_SSH_HOST:-adihex@adi-linux}"

log() { printf 'hex-client: %s\n' "$*"; }

if [ -n "${PREFIX:-}" ] && [ -x "$PREFIX/bin/pkg" ]; then
  pkg install -y nodejs git openssh
fi

if [ -n "$BUNDLE" ] && [ -f "$BUNDLE" ]; then
  mkdir -p "$ROOT"
  tar -xzf "$BUNDLE" -C "$ROOT"
fi

if [ ! -f "$ROOT/hex.mjs" ]; then
  log "missing $ROOT/hex.mjs"
  exit 1
fi

mkdir -p "$HOME/.hexes" "$HOME/.local/bin" "$HOME/.ssh"
chmod 700 "$HOME/.ssh" "$HOME/.hexes"

if [ -n "$TOKEN_SRC" ] && [ -f "$TOKEN_SRC" ]; then
  umask 077
  cp "$TOKEN_SRC" "$HOME/.hexes/token"
  chmod 600 "$HOME/.hexes/token"
  rm -f "$TOKEN_SRC"
fi
if [ ! -s "$HOME/.hexes/token" ]; then
  log "no owner token at ~/.hexes/token"
  exit 1
fi

umask 077
cat > "$HOME/.hexes/client.json" <<EOF
{
  "ssh": "$SSH_HOST",
  "url": "http://100.109.83.57:8787",
  "publicUrl": "http://adi-linux.tail6c6fd6.ts.net:8787"
}
EOF
chmod 600 "$HOME/.hexes/client.json"
if [ -n "${HEX_PROJECTS:-}" ] && [ -f "$HEX_PROJECTS" ]; then
  cp "$HEX_PROJECTS" "$HOME/.hexes/projects.json"
fi

touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
grep -q 'AAAAC3NzaC1lZDI1NTE5AAAAIJkUBl8OvejoYgCj5BRM1rBCnTkE1UTWNhs9JVycHx3I' "$HOME/.ssh/authorized_keys" || printf '%s\n' "$HOST_KEY" >> "$HOME/.ssh/authorized_keys"

if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
  ssh-keygen -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -C "$(uname -n)-hexes"
fi
if [ -n "$STATUS" ]; then
  cp "$HOME/.ssh/id_ed25519.pub" "${STATUS}.pub"
fi

ln -sfn "$ROOT/hex.mjs" "$HOME/.local/bin/hex"
[ -d "$HOME/bin" ] && ln -sfn "$ROOT/hex.mjs" "$HOME/bin/hex"
if [ -n "${PREFIX:-}" ]; then
  ln -sfn "$ROOT/hex.mjs" "$PREFIX/bin/hex"
fi
chmod +x "$ROOT/hex.mjs" "$ROOT/client-install.sh" 2>/dev/null || chmod +x "$ROOT/hex.mjs"

if [ -d "$HOME/.omp/agent/extensions" ]; then
  printf 'export { default } from "%s/omp-hexes.ts";\n' "$ROOT" > "$HOME/.omp/agent/extensions/hexes.ts"
fi

if [ ! -x "$HOME/.bun/bin/bun" ] && ! command -v bun >/dev/null 2>&1; then
  curl -fsSL https://bun.sh/install | bash
fi
if [ -x "$HOME/.bun/bin/bun" ]; then
  BUN_BIN="$HOME/.bun/bin/bun"
elif [ -n "${PREFIX:-}" ] && [ -x "$PREFIX/bin/bun" ]; then
  BUN_BIN="$PREFIX/bin/bun"
else
  BUN_BIN="$(command -v bun || true)"
fi
if [ -n "$BUN_BIN" ] && [ -x "$BUN_BIN" ]; then
  mkdir -p "$HOME/.local/bin"
  ln -sfn "$BUN_BIN" "$HOME/.local/bin/bun"
  if [ -d "$HOME/bin" ]; then ln -sfn "$BUN_BIN" "$HOME/bin/bun"; fi
  export PATH="$HOME/.local/bin:$HOME/bin:$PATH"
  (cd "$ROOT" && "$BUN_BIN" install --frozen-lockfile) || (cd "$ROOT" && "$BUN_BIN" install)
elif [ "$(uname -s)" = "Darwin" ]; then
  log "bun missing; hex attach cannot run"
  exit 1
else
  log "bun missing; hex attach will not work on this machine"
fi

log "waiting for SSH hop $SSH_HOST"
ok=0
i=0
while [ "$i" -lt 60 ]; do
  if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$SSH_HOST" true; then
    ok=1
    break
  fi
  i=$((i + 1))
  sleep 2
done
if [ "$ok" -ne 1 ]; then
  log "SSH hop not ready; HTTP commands still work. Pubkey:"
  cat "$HOME/.ssh/id_ed25519.pub"
  [ -n "$STATUS" ] && printf 'ssh-hop-pending\n' > "$STATUS"
  exit 1
fi

node "$ROOT/hex.mjs" list
log "ready as $(id -un) on $(uname -s)"
if [ -n "$STATUS" ]; then printf 'ok %s\n' "$(id -un)" > "$STATUS"; fi
