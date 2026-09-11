# Updating linear to a new upstream release

Step-by-step instructions for bumping this package. Written so an AI
assistant (or a human in a hurry) can do the whole update without
re-deriving anything. Read the gotchas at the bottom before improvising.

## What this package is

- Upstream: https://github.com/zacharyftw/linear-linux (Apache-2.0). A
  ~150-line Tauri v2 app that opens https://linear.app in a WebKitGTK
  window, remembers window geometry and adds Ctrl+Shift+N for a new
  window. Linear itself is a web service; nothing of Linear's is bundled.
- Upstream releases only `Linear_<V>_amd64.deb`. This is a **source
  build** for arm64 using upstream's own `cargo tauri build`, so the
  result is what upstream's CI would produce on an arm64 runner.
- Upstream source is not patched. `tauri.overlay.json` is passed to the
  Tauri CLI with `--config`, which deep-merges it into `tauri.conf.json`
  at build time to set maintainer, description, section and desktop
  category. Without it the .deb says `Maintainer: linear`,
  `Description: (none)` and has an empty `Categories=`.
- Binary package name is `linear` (Tauri derives it from the crate/
  product name). The executable is `/usr/bin/linear-linux`.
- `build.sh` pins both the tag and the commit it must resolve to.

## Prerequisites

- Rust via rustup in `~/.cargo` (any recent stable; 1.98 used for 0.2.3).
- `node` >= 20 and `corepack` (our `node-corepack` package provides it);
  used only to fetch the `@tauri-apps/cli` npm package upstream pins.
- `sudo apt install libwebkit2gtk-4.1-dev libgtk-3-dev librsvg2-dev
  libayatana-appindicator3-dev libssl-dev`
- `dpkg-dev`. About 2 GB free for `sources/linear/build/target`.

## Step 1 - find the new version

```sh
curl -sS https://api.github.com/repos/zacharyftw/linear-linux/releases/latest \
  | grep -o '"tag_name": *"v[^"]*"'
git ls-remote --tags https://github.com/zacharyftw/linear-linux.git 'v<V>^{}'
```

The second command prints the commit the tag points at. Call them `$V`
and `$COMMIT`.

## Step 2 - bump build.sh

Edit the constants at the top of `build.sh`:

```sh
VERSION=<V>
UPSTREAM_COMMIT=<COMMIT>
```

## Step 3 - check for upstream changes that affect packaging

```sh
git -C sources/linear/build/src fetch --tags origin   # or clone fresh
git -C sources/linear/build/src diff v<OLD>..v<V> -- src-tauri/tauri.conf.json src-tauri/Cargo.toml package.json .github/workflows/release.yml
```

Things to look for:
- New system build dependencies in `release.yml` -> add to the `dpkg -s`
  loop in `build.sh` and to the prerequisites above.
- Changes to `bundle.*` in `tauri.conf.json` that overlap with
  `tauri.overlay.json` (our overlay wins; drop keys upstream now sets).
- A renamed binary or product name -> update the smoke-test paths.

## Step 4 - build and test

```sh
./sources/linear/build.sh
```

Then install and launch for real:

```sh
sudo apt update && sudo apt install linear    # or: sudo apt install ./repo/linear_<V>_arm64.deb
linear-linux
```

Check the Linear login page renders in the window and that the app shows
up in the launcher under Office/Productivity with its icon.

## Step 5 - commit

Commit `sources/linear/build.sh`, `tauri.overlay.json` if changed,
`repo/linear_<V>_arm64.deb` (it is ~4 MB, so it lives in git), remove the
old .deb from `repo/`, and commit the regenerated `repo/Packages`,
`Packages.gz`, `Release`. Update the version in the README table.

## Gotchas

- **Tauri names the file after `productName`**, so the bundler writes
  `Linear_<V>_arm64.deb`. `build.sh` renames it to `linear_<V>_arm64.deb`
  to match the package name and Debian convention; the content is
  identical. Upstream's own `installer.sh` also expects the lowercase
  name, even though their release asset is capitalised.
- **Depends are just `libwebkit2gtk-4.1-0, libgtk-3-0`.** Tauri generates
  them; `libgtk-3-0` is a virtual name provided by `libgtk-3-0t64` on
  Ubuntu 24.04+ and resolves fine. Verify with
  `apt-get -s install ./repo/linear_*.deb`.
- **`--bundles deb` only.** Upstream's config also builds an AppImage,
  which needs `patchelf` and downloads linuxdeploy at build time. We
  don't want it, so it is skipped.
- **The Tauri CLI comes from npm, not cargo.** `cargo install tauri-cli`
  compiles for a long time on arm64; the npm package has a prebuilt
  arm64 binary and upstream pins `@tauri-apps/cli ^2` in package.json, so
  `corepack npm@11 install` inside the clone is the fast, upstream-
  faithful route. No `npm` on the system is needed - corepack fetches it.
- **`build/target` is kept across runs** (`CARGO_TARGET_DIR`) so a
  version bump only recompiles the app crate, not ~280 dependencies.
  Delete it if a build behaves oddly after a Rust toolchain upgrade.
  Never move a target dir from elsewhere: Tauri's build scripts bake
  absolute paths into `target/release/build/tauri-*/out`, and a moved
  cache fails with "failed to read plugin permissions ... No such file".
  Fix: `rm -rf build/target/release/build/tauri-* tauri-plugin-* linear-linux-*`.
- **Icon dir `256x256@2`.** Tauri maps `128x128@2x.png` to
  `hicolor/256x256@2/apps/`. Harmless, upstream's amd64 .deb has it too.
