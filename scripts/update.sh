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

nix_prefetch_url() {
  local url="$1"
  nix store prefetch-file --hash-type sha256 --json "$url" | sri_from_json
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
  # replace_asset_hash <filename-suffix> <new-hash>
  # Anchors on the asset's filename suffix in urlName (e.g. "_aarch64.dmg",
  # "_x64.dmg", "_amd64.tar.gz", "_aarch64.tar.gz") to avoid regex trouble
  # with `${version}` inside the block.
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

  log "computing linux amd64 tarball hash"
  local linux_amd64_hash
  linux_amd64_hash="$(nix_prefetch_url \
    "https://github.com/${UPSTREAM}/releases/download/${new_tag}/qbz_${new_ver}_amd64.tar.gz")"

  log "computing linux aarch64 tarball hash"
  local linux_aarch64_hash
  linux_aarch64_hash="$(nix_prefetch_url \
    "https://github.com/${UPSTREAM}/releases/download/${new_tag}/qbz_${new_ver}_aarch64.tar.gz")"

  log "computing darwin aarch64 dmg hash"
  local darwin_aarch64_hash
  darwin_aarch64_hash="$(nix_prefetch_url \
    "https://github.com/${UPSTREAM}/releases/download/${new_tag}/QBZ_${new_ver}_aarch64.dmg")"

  log "computing darwin x86_64 dmg hash"
  local darwin_x86_64_hash
  darwin_x86_64_hash="$(nix_prefetch_url \
    "https://github.com/${UPSTREAM}/releases/download/${new_tag}/QBZ_${new_ver}_x64.dmg")"

  log "rewriting ${FLAKE}"
  replace_line version "$new_ver"
  replace_asset_hash "_amd64.tar.gz" "$linux_amd64_hash"
  replace_asset_hash "_aarch64.tar.gz" "$linux_aarch64_hash"
  replace_asset_hash "_aarch64.dmg" "$darwin_aarch64_hash"
  replace_asset_hash "_x64.dmg" "$darwin_x86_64_hash"

  emit "updated=true"
  log "done: bumped to v${new_ver}"
}

main "$@"
