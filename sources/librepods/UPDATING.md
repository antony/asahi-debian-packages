# Updating librepods to a new upstream release

Step-by-step instructions for bumping this package. Written so an AI
assistant (or a human in a hurry) can do the whole update without
re-deriving anything. Read the gotchas at the bottom before improvising.

## What this package is

- Upstream: https://github.com/librepods-org/librepods (AGPL-3.0). One
  monorepo holding the Android app (`android/`), the old Qt/QML Linux
  client (`linux/`, unmaintained) and the **Rust/iced rewrite of the Linux
  client in `linux-rust/`**, which is what this package builds. Upstream
  recommends the rewrite; its README calls the Qt version "the old
  version".
- Linux releases use their own tag series, `linux-v<V>`, separate from the
  Android `v<V>` tags. The Linux tags are cut from the `linux/rust` branch
  (PR #241, still open) and its CI (`.github/workflows/ci-linux-rust.yml`)
  only publishes an x86_64 AppImage, a bare x86_64 binary and a vendored
  source tarball. So this is a **source build** for arm64 with upstream's
  own `cargo build --release`.
- Upstream is not patched. The installed layout (`/usr/bin/librepods`,
  desktop file, 256x256 icon, metainfo) is exactly what upstream's
  `Justfile prepare` and `flatpak/me.kavishdevar.librepods.yaml` install.
- `debian/control.in` gets its library Depends from `dpkg-shlibdeps` at
  build time (`@SHLIBS_DEPENDS@`), plus `bluez` because the app talks to
  `org.bluez` over D-Bus. Wayland/X11/Vulkan libraries are `Recommends`
  because iced/winit/wgpu dlopen them; they never appear in `ldd`.
- Version string is upstream's crate version (`0.1.0` for tag
  `linux-v0.1.0`). `build.sh` pins the tag AND the commit it resolves to,
  and checks `Cargo.toml`'s version agrees.
- The .deb is small enough to live in git (see the README table for the
  current size); no `.gitignore` entry.

## Prerequisites

- Rust via rustup in `~/.cargo` (1.98 used for 0.1.0; the crate uses
  edition 2024 so anything older than 1.85 will not work).
- `sudo apt install pkg-config libdbus-1-dev` plus the `libpulse0` runtime
  library (already present on any desktop). `libpulse-dev` is optional:
  the `libpulse-sys` crate's build.rs falls back to linking
  `libpulse.so.0` by soname when `pkg-config libpulse` fails, and the
  result is identical (`ldd` shows `libpulse.so.0` either way).
- `dpkg-dev`, `fakeroot`, `git`. About 3 GB free for
  `sources/librepods/build/target` on a first build.

## Step 1 - find the new version

```sh
git ls-remote --tags https://github.com/librepods-org/librepods.git 'linux-v*'
```

Linux tags are annotated, so you will see both `refs/tags/linux-v<V>` (the
tag object) and `refs/tags/linux-v<V>^{}` (the commit). Use the `^{}`
line's sha as `$COMMIT` and `<V>` as `$V`. Ignore `v<V>` and `nightly-*`
tags; those are Android.

Confirm the tag actually contains the Rust app and what version it says:

```sh
curl -sL https://raw.githubusercontent.com/librepods-org/librepods/linux-v$V/linux-rust/Cargo.toml | grep '^version'
```

## Step 2 - bump build.sh

Edit the constants at the top of `build.sh`:

```sh
VERSION=<V>
UPSTREAM_COMMIT=<COMMIT>
```

`TAG` is derived from `VERSION`.

## Step 3 - check for upstream changes that affect packaging

```sh
git -C sources/librepods/build/src fetch --depth 1 origin tag linux-v$V
git -C sources/librepods/build/src diff linux-v<OLD>..linux-v$V -- \
    linux-rust/Cargo.toml linux-rust/Justfile linux-rust/flatpak linux-rust/assets \
    .github/workflows/ci-linux-rust.yml
```

Things to look for:
- New `apt-get install` lines in `ci-linux-rust.yml` or new `*-sys`
  crates in `Cargo.toml` -> add the `-dev` package to the `dpkg -s` loop
  in `build.sh` and to the prerequisites above. (Upstream CI installs
  `libpulse-dev`; we get away without it, see Prerequisites.) Runtime Depends update
  themselves via `dpkg-shlibdeps`.
- Changes to what the Justfile `prepare` recipe or the flatpak manifest
  installs (renamed app id, extra icon sizes, a new data file) -> mirror
  them in the "assemble" section of `build.sh` and the smoke-test file
  list.
- Changes to the clap `Args` struct in `src/main.rs` -> the smoke test
  greps `--help` for `--no-tray`; update if that flag goes away, and
  update `debian/README.Debian`.
- `linux-rust/` moving or being merged into `linux/` (PR #241 is meant to
  replace the Qt client) -> update `SRC=` in `build.sh`.

## Step 4 - build and test

```sh
./sources/librepods/build.sh
apt-get -s install ./repo/librepods_<V>_arm64.deb
```

`build.sh` clones the tag, checks the commit and Cargo version, runs
`cargo build --release --locked`, assembles the tree, generates Depends,
builds the .deb, checks the binary is an aarch64 ELF whose libraries all
resolve, checks the expected files and md5sums, runs the packaged
`librepods --help` (safe: clap exits before Bluetooth or the GUI start),
copies the .deb into `repo/` and reindexes.

Then for real, with AirPods paired:

```sh
sudo apt update && sudo apt install librepods
librepods --debug
```

A tray icon should appear (GNOME needs an AppIndicator extension) and the
window should show battery levels once the AirPods connect.

## Step 5 - commit

Commit `sources/librepods/build.sh` (and anything changed in `debian/` or
`UPDATING.md`), the new `repo/librepods_<V>_arm64.deb`, remove the old
one, plus `repo/Packages`, `Packages.gz`, `Release`. Update the version in
the README table.

## Gotchas

- **Two Linux clients, two tag series.** `linux/` (Qt) and `linux-rust/`
  (iced). Only the Rust one has ever had a Linux release tag, and the
  `latest` GitHub release is always an Android build with only APKs in
  it. Do not package from `/releases/latest`.
- **The tag lags the branch.** `linux/rust` kept moving after
  `linux-v0.1.0` (Nov 2025) with no new tag for months. We pin the tag,
  not the branch head, so the package matches what upstream actually
  released. If a much newer tag never appears and the user wants branch
  HEAD, that is a deliberate decision: set `TAG` to the branch, pin the
  commit, and use a version like `0.1.0+git<date>.<sha7>`.
- **`--locked` is intentional.** Upstream commits `Cargo.lock`; building
  with it gives the same crate versions as upstream's CI and AppImage.
  If `cargo` complains the lockfile needs updating, upstream's lock is
  stale for that tag; report it rather than dropping `--locked`.
- **Window icon path is relative to the source tree** (`../../assets/
  icon.png` in `src/ui/window.rs`), so the installed app's window has no
  icon. Harmless, upstream's AppImage has the same problem. Noted in
  `debian/README.Debian`; check whether a new version fixes it.
- **The DejaVu font is embedded** with `include_bytes!` for the tray
  battery icon, so nothing needs to be installed under `/usr/share`
  beyond what `build.sh` puts there.
- **`build/target` is kept across runs** (`CARGO_TARGET_DIR`) so a bump
  only recompiles changed crates. Delete it if a build behaves oddly
  after a Rust toolchain upgrade. `build/src` is reused when it is
  already at the pinned commit, otherwise re-cloned.
- **Depends come from dpkg-shlibdeps**, which needs a `debian/control`
  in its cwd; `build.sh` fakes one under `build/shlibdeps/`. If it prints
  nothing the build fails on purpose rather than shipping an empty
  Depends. Ubuntu `t64` names (`libssl3t64`, etc.) come out correctly
  because shlibdeps reads the installed packages' `symbols`/`shlibs`.
