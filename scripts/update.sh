#!/usr/bin/env bash
# Bump flake.nix to the latest upstream qbz release and recompute every hash.
#
# Requires: nix (flakes), jq, gh (or GH_TOKEN + curl), a writable flake.nix.
# Exits 0 with no-op if already on latest. Exits 1 on error.
# Prints "updated=true|false" and "version=<x.y.z>" to $GITHUB_OUTPUT if set.
set -euo pipefail

UPSTREAM="vicrodh/qbz"
FLAKE="${FLAKE:-flake.nix}"

log() { printf '[update] %s\n' "$*" >&2; }
emit() { [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s\n' "$1" >> "$GITHUB_OUTPUT" || true; }

latest_tag() {
  if command -v gh >/dev/null 2>&1; then
    gh api "repos/${UPSTREAM}/releases/latest" --jq .tag_name
  else
    curl -fsSL \
      ${GH_TOKEN:+-H "Authorization: Bearer ${GH_TOKEN}"} \
      "https://api.github.com/repos/${UPSTREAM}/releases/latest" | jq -r .tag_name
  fi
}

sri_from_json() { jq -r .hash; }

nix_prefetch_github() {
  local rev="$1"
  nix run --extra-experimental-features 'nix-command flakes' \
    nixpkgs#nix-prefetch-github -- vicrodh qbz --rev "$rev" | jq -r .hash
}

nix_prefetch_url() {
  local url="$1"
  nix store prefetch-file --hash-type sha256 --json "$url" | sri_from_json
}

nix_prefetch_npm_from_tarball() {
  local tarball="$1"
  local tmp
  tmp="$(mktemp -d)"
  tar -xzf "$tarball" -C "$tmp"
  local lockfile
  lockfile="$(find "$tmp" -maxdepth 2 -name package-lock.json | head -1)"
  [ -n "$lockfile" ] || { log "no package-lock.json in source"; exit 1; }
  nix run --extra-experimental-features 'nix-command flakes' \
    nixpkgs#prefetch-npm-deps -- "$lockfile"
  rm -rf "$tmp"
}

# Read the current pinned version directly from flake.nix so this script has
# no state outside the flake itself.
current_version() {
  awk -F'"' '/^\s*version = "/ { print $2; exit }' "$FLAKE"
}

replace_line() {
  # replace_line <key> <new-quoted-value>
  # rewrites lines matching `  <key> = "..."`; value passed must be pre-quoted.
  local key="$1" val="$2"
  python3 - "$FLAKE" "$key" "$val" <<'PY'
import re, sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
pat = re.compile(rf'^(\s*){re.escape(key)}\s*=\s*"[^"]*";', re.M)
new, n = pat.subn(lambda m: f'{m.group(1)}{key} = "{val}";', text, count=1)
if n == 0:
    sys.exit(f"no line for key {key!r} in {path}")
open(path, "w").write(new)
PY
}

replace_asset_hash() {
  # replace_asset_hash <dmg-arch-suffix> <new-hash>
  # Anchors on the DMG filename suffix in urlName (e.g. "_aarch64.dmg",
  # "_x64.dmg") to avoid regex trouble with `${version}` inside the block.
  local arch_suffix="$1" new_hash="$2"
  python3 - "$FLAKE" "$arch_suffix" "$new_hash" <<'PY'
import re, sys
path, arch_suffix, new_hash = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
pat = re.compile(
    rf'({re.escape(arch_suffix)}";[ \t\r\n]*hash\s*=\s*)"[^"]*"',
)
new, n = pat.subn(lambda m: f'{m.group(1)}"{new_hash}"', text, count=1)
if n == 0:
    sys.exit(f"no asset hash line with suffix {arch_suffix!r} in {path}")
open(path, "w").write(new)
PY
}

main() {
  local cur new_tag new_ver
  cur="$(current_version)"
  new_tag="$(latest_tag)"
  new_ver="${new_tag#v}"

  log "current pinned: v${cur}"
  log "latest upstream: ${new_tag}"

  emit "version=${new_ver}"

  if [ "$cur" = "$new_ver" ]; then
    log "already on latest"
    emit "updated=false"
    return 0
  fi

  log "computing new source hash"
  local src_hash
  src_hash="$(nix_prefetch_github "$new_tag")"

  log "computing npm deps hash"
  local tar_tmp npm_hash
  tar_tmp="$(mktemp)"
  if command -v gh >/dev/null 2>&1; then
    gh api "repos/${UPSTREAM}/tarball/${new_tag}" > "$tar_tmp"
  else
    curl -fsSL \
      ${GH_TOKEN:+-H "Authorization: Bearer ${GH_TOKEN}"} \
      -o "$tar_tmp" \
      "https://api.github.com/repos/${UPSTREAM}/tarball/${new_tag}"
  fi
  npm_hash="$(nix_prefetch_npm_from_tarball "$tar_tmp")"
  rm -f "$tar_tmp"

  log "computing darwin aarch64 dmg hash"
  local aarch64_hash
  aarch64_hash="$(nix_prefetch_url \
    "https://github.com/${UPSTREAM}/releases/download/${new_tag}/QBZ_${new_ver}_aarch64.dmg")"

  log "computing darwin x86_64 dmg hash"
  local x86_64_hash
  x86_64_hash="$(nix_prefetch_url \
    "https://github.com/${UPSTREAM}/releases/download/${new_tag}/QBZ_${new_ver}_x64.dmg")"

  log "rewriting ${FLAKE}"
  replace_line version "$new_ver"
  replace_line srcHash "$src_hash"
  replace_line npmHash "$npm_hash"
  replace_asset_hash "_aarch64.dmg" "$aarch64_hash"
  replace_asset_hash "_x64.dmg" "$x86_64_hash"

  emit "updated=true"
  log "done: bumped to v${new_ver}"
}

main "$@"
