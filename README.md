# qbz-flake

A cross-platform Nix flake for [vicrodh/qbz](https://github.com/vicrodh/qbz), the native hi-fi Qobuz desktop player.

## Supported systems

| System            | Source                                                    |
|-------------------|-----------------------------------------------------------|
| `x86_64-linux`    | built from source via `cargo-tauri.hook`                  |
| `aarch64-linux`   | built from source via `cargo-tauri.hook`                  |
| `x86_64-darwin`   | prebuilt, upstream-signed `.dmg` from the GitHub release  |
| `aarch64-darwin`  | prebuilt, upstream-signed `.dmg` from the GitHub release  |

Tauri's WebKit/Cocoa graph is impractical to build from source on darwin under nix, so darwin installs the upstream-signed bundle instead. The CLI shim at `$out/bin/qbz` execs the binary inside `QBZ.app`, and the bundle itself is exposed at `$out/Applications/QBZ.app` for nix-darwin's `system.applications`.

## Usage

```sh
# one-shot
nix run github:winter-08/qbz-flake

# install into profile
nix profile install github:winter-08/qbz-flake

# dev shell (Linux only — darwin uses the prebuilt bundle)
nix develop github:winter-08/qbz-flake
```

As a flake input:

```nix
{
  inputs.qbz.url = "github:winter-08/qbz-flake";
  # on nix-darwin:
  # environment.systemPackages = [ inputs.qbz.packages.${system}.default ];
  # or, to expose the .app to Spotlight / Launchpad:
  # system.activationScripts.qbz.text = ''
  #   cp -R ${inputs.qbz.packages.${system}.default}/Applications/QBZ.app /Applications/
  # '';
}
```

## Updating

Version, source hash, npm deps hash, and both darwin DMG hashes are pinned in `flake.nix`. They're bumped automatically by `.github/workflows/update-check.yml`, which runs daily and opens a PR whenever upstream cuts a new tag.

To bump locally:

```sh
./scripts/update.sh
```

Requires `nix` with flakes enabled, `jq`, and either `gh` or `GH_TOKEN`.
