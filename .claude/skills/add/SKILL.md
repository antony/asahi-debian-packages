---
name: add
description: Add a new Debian package to this apt repo for Asahi Linux (arm64). Use whenever the user says "add <name>", "add <URL>", "package <name>", "can we provide <deb URL> for arm64", or pastes a link to a .deb, GitHub release, AppImage or tarball and wants it installable via apt here. Covers picking the cheapest packaging route, creating sources/<name>/ with build.sh and UPDATING.md, building, smoke testing and reindexing.
---

# Add a package to this repo

The user typed something like `add obsidian` or `add https://.../foo_1.2_amd64.deb`.
The goal is always the same: an installable .deb for arm64 in `repo/`, a
reproducible `sources/<name>/build.sh`, an `UPDATING.md`, a README table
row, and a regenerated index. Work autonomously; only ask if the package
name is ambiguous or the licence forbids redistribution.

## 1. Research before building (do not skip)

- Find the upstream release page. For GitHub, list the assets:
  `curl -s https://api.github.com/repos/<owner>/<repo>/releases/latest`
  (or `/releases/tags/<tag>`). Note every Linux asset and its size.
- Check whether the package already exists in Ubuntu/Debian for arm64:
  `apt-cache policy <name>`. If it does and is current enough, tell the
  user and stop - we don't duplicate the archive.
- Check the licence allows redistribution of binaries. Proprietary
  freeware (e.g. Obsidian) is fine to repack unmodified; say so in
  UPDATING.md. If unclear, ask.

## 2. Pick the cheapest route, in this order

1. **Upstream ships an arm64 .deb** - just fetch it, verify checksum,
   drop into `repo/`, write a tiny `build.sh` that does that. Done.
2. **Upstream ships an arm64 tarball/binary but only an amd64 .deb**
   (Electron apps, Go/Rust CLIs) - repack the arm64 tarball into a .deb
   mirroring the amd64 one. Template: `sources/obsidian/`. Download the
   amd64 .deb too and copy its `DEBIAN/postinst`, `postrm`, desktop file,
   control fields (Depends/Recommends) verbatim into `sources/<name>/debian/`.
3. **Pure script / JS / arch-independent** - `Architecture: all`
   Debian-style source package. Template: `sources/node-corepack/`.
4. **Only source available** - build it. Prefer upstream's own build
   instructions over inventing debhelper rules. Template: `sources/linear/`
   (Tauri v2 app). Pin the tag AND the commit it resolves to. If it needs
   `sudo apt install` of dev libraries, the user must run that in their
   own terminal (sudo has no tty here); Rust lives in `~/.cargo/bin`.

If the only arm64 artefact is an AppImage, extract it
(`./Foo.AppImage --appimage-extract`) and treat `squashfs-root/` as the
tarball in route 2.

## 3. Layout and conventions

```
sources/<name>/
  build.sh        fetch (cached in dl/), verify sha256, assemble, build,
                  smoke test, cp into ../../repo/, run ../../update-index.sh
  UPDATING.md     step-by-step bump instructions + gotchas (see existing ones)
  debian/         control(.in), maintainer scripts, desktop file, etc.
  dl/             download cache   (gitignored)
  build/          scratch          (gitignored)
```

- `set -eu`, POSIX sh, `cd "$(dirname "$0")"`, `ROOT=$(cd ../.. && pwd)`.
- Pin `VERSION=` and `*_SHA256=` at the top of build.sh; nothing else
  should need editing for a bump.
- Build with `fakeroot dpkg-deb --root-owner-group -Zxz -b`. Normalise
  modes (dirs 755, files 644, executables 755) - upstream tarballs are
  often group-writable.
- Keep upstream's version string unless we modify content; use
  `+ds`/`-N` suffixes only for real repacks of source.
- Maintainer: use `git config user.name`/`user.email` or the existing
  `antony <antony@beyonk.com>`.
- Generate `usr/share/doc/<name>/changelog.gz` and `DEBIAN/md5sums`.
- Keep upstream's Depends names even if Ubuntu renamed them (`libgtk-3-0`
  -> `libgtk-3-0t64`); the `t64` packages `Provides` the old names.
  Verify with `apt-get -s install ./repo/<name>_*.deb`.

## 4. Smoke tests that must be in build.sh

- `dpkg-deb -f` Architecture is `arm64` or `all` as intended.
- For binaries: `file` says `ARM aarch64`; `ldd` shows no `not found`.
- Expected files exist in the extracted tree; `md5sums` verify.
- For CLIs: run `--version` from the extracted tree and compare.
- Never launch a GUI from build.sh. Electron apps fuse off
  `ELECTRON_RUN_AS_NODE`, and `--no-sandbox` launches the full app.

## 5. Size rule

`.deb` under ~20 MB: commit it into `repo/`. Larger: add
`repo/<name>_*.deb` to `.gitignore`, say so in README and UPDATING.md,
and make sure `build.sh` is the way to regenerate it. GitHub hard-fails
at 100 MB and every version bump adds the full size to history.

## 6. Finish

1. `./sources/<name>/build.sh` passes end to end and reindexes.
2. `apt-get -s install ./repo/<name>_*.deb` resolves.
3. README table row added (arch, source dir, one-line note, git status).
4. Report to the user: what route was taken, what was verified (paste the
   smoke-test output), anything upstream got wrong (e.g. wrong-arch native
   modules), and that nothing was committed unless they asked.

## Known upstream quirks (add to this list as you find them)

- Obsidian arm64 tarball 1.13.7 ships x86-64 `binding.node` files in
  `resources/app.asar.unpacked/`; app works anyway. Not fixable in a repack.
- Obsidian's tarball lacks `resources/apparmor-profile`; the amd64 .deb has
  it and postinst expects it - copy it in.
- Tauri apps: get the CLI with `corepack npm@11 install` inside the clone
  (prebuilt arm64, seconds) rather than `cargo install tauri-cli` (long
  compile). Build with `--bundles deb` only (AppImage needs patchelf +
  downloads). Fix thin .deb metadata (Maintainer/Description/Categories)
  with a `--config overlay.json`, never by patching upstream. Keep
  `CARGO_TARGET_DIR` under `build/target`, and never move a target dir
  in from elsewhere - Tauri bakes absolute paths into build-script outputs.
- Tauri names the .deb after `productName` (`Linear_...`); rename to the
  lowercase package name for the repo.
