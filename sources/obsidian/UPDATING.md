# Updating obsidian to a new upstream release

Step-by-step instructions for bumping this package. Written so an AI
assistant (or a human in a hurry) can do the whole update without
re-deriving anything. Read the gotchas at the bottom before improvising.

## What this package is

- Upstream: https://github.com/obsidianmd/obsidian-releases (proprietary,
  freeware - we redistribute the official binaries unmodified).
- Upstream publishes `obsidian_<V>_amd64.deb` but for arm64 only
  `obsidian-<V>-arm64.tar.gz` and an AppImage. `build.sh` repacks the
  arm64 tarball into a .deb with the same layout as the amd64 one:
  `/opt/Obsidian/`, `/usr/bin/obsidian` via update-alternatives,
  desktop entry, hicolor icons, AppArmor profile.
- `debian/postinst`, `debian/postrm`, `debian/md.obsidian.Obsidian.desktop`
  and `debian/apparmor-profile` are byte-for-byte copies from the amd64
  .deb (taken from 1.13.7). `debian/control.in` mirrors its control
  fields with placeholders for version, maintainer and size.
- Version string is upstream's, unchanged (e.g. `1.13.7`), so if upstream
  ever ships an arm64 .deb the two compare equal rather than ours winning.
- There is no Debian source package here: the "source" is the upstream
  tarball, fetched and checksum-verified by `build.sh` at build time.

## Prerequisites

`dpkg-dev`, `fakeroot`, `curl`, `python3-pil` (Pillow, for icon resizing),
about 1 GB free in `sources/obsidian/build/`. No root, no network beyond
github.com.

## Step 1 - find the new version and tarball checksum

```sh
V=$(curl -sS https://api.github.com/repos/obsidianmd/obsidian-releases/releases/latest \
    | grep -o '"tag_name": *"v[^"]*"' | grep -o '[0-9][0-9.]*')
echo "$V"
curl -fL -o "sources/obsidian/dl/obsidian-$V-arm64.tar.gz" \
  "https://github.com/obsidianmd/obsidian-releases/releases/download/v$V/obsidian-$V-arm64.tar.gz"
sha256sum "sources/obsidian/dl/obsidian-$V-arm64.tar.gz"
```

Check that release actually lists `obsidian-<V>-arm64.tar.gz` and
`obsidian_<V>_amd64.deb` (early-access releases sometimes lag).

## Step 2 - bump build.sh

Edit the two constants at the top of `build.sh`:

```sh
VERSION=<V>
TARBALL_SHA256=<sha256 from step 1>
```

## Step 3 - check whether upstream changed the packaging scripts

Do this at least on minor version bumps (1.13 -> 1.14). Download the amd64
.deb and diff its maintainer scripts and desktop file against ours:

```sh
cd sources/obsidian/dl
curl -fLO "https://github.com/obsidianmd/obsidian-releases/releases/download/v$V/obsidian_${V}_amd64.deb"
mkdir -p amd64 && dpkg-deb -e "obsidian_${V}_amd64.deb" amd64/DEBIAN && dpkg-deb -x "obsidian_${V}_amd64.deb" amd64/root
diff amd64/DEBIAN/postinst ../debian/postinst
diff amd64/DEBIAN/postrm   ../debian/postrm
diff amd64/root/usr/share/applications/md.obsidian.Obsidian.desktop ../debian/md.obsidian.Obsidian.desktop
diff amd64/root/opt/Obsidian/resources/apparmor-profile ../debian/apparmor-profile
grep -E '^(Depends|Recommends):' amd64/DEBIAN/control   # compare with ../debian/control.in
```

Copy over anything that changed. Also compare the file list
(`dpkg-deb -c ... | awk '{print $6}'` vs `tar tzf` of the arm64 tarball)
for new top-level files; if upstream adds new executables to
`/opt/Obsidian/`, add them to the `chmod 755` list in `build.sh`.

## Step 4 - build and test

```sh
./sources/obsidian/build.sh
```

This verifies the checksum, assembles the tree, builds the .deb, checks
the binary is an aarch64 ELF whose shared libraries all resolve, verifies
md5sums, copies the .deb into `repo/` and reindexes.

Then install it for real and launch it:

```sh
sudo apt update && sudo apt install obsidian     # or: sudo apt install ./repo/obsidian_<V>_arm64.deb
obsidian
```

Check the window opens, `Settings > About` shows the new version, and
`/usr/bin/obsidian` points at `/etc/alternatives/obsidian`.

## Step 5 - commit

Commit `sources/obsidian/build.sh` (and anything changed in `debian/`),
plus `repo/Packages`, `repo/Packages.gz`, `repo/Release`. Update the
version in the README table. The .deb itself is gitignored (see gotchas).

## Gotchas

- **The .deb is not committed.** It is ~90 MB per version; GitHub refuses
  files over 100 MB and every bump would add another ~90 MB to history
  forever. `repo/obsidian_*.deb` is in `.gitignore`. On a fresh clone,
  run `./sources/obsidian/build.sh` before `apt install obsidian`,
  otherwise apt will 404 on the file the committed index references.
- **Native modules are x86-64 even in the arm64 tarball.** Upstream's
  arm64 tarball (1.13.7) ships
  `resources/app.asar.unpacked/node_modules/{btime,get-fonts}/binding.node`
  as x86-64 ELF objects. That is upstream's bug, shared with their arm64
  AppImage; the app runs without them (file birth-time and font-listing
  helpers fail to load and are skipped). Don't try to "fix" it in the
  repack - there is no arm64 build of those modules to substitute.
- **Dependency names are upstream's, not Ubuntu's.** `libgtk-3-0`,
  `libatspi2.0-0` and `libappindicator3-1` don't exist as real packages on
  Ubuntu 24.04+/Debian 13, but `libgtk-3-0t64`, `libatspi2.0-0t64` and
  `libayatana-appindicator3-1` all `Provides` them, so apt resolves fine.
  Keep upstream's names so the package also works on older releases.
- **Don't run the app from build.sh as a test.** `ELECTRON_RUN_AS_NODE`
  is fused off in Obsidian's Electron build; passing `--no-sandbox` just
  launches the full GUI. The ELF/ldd checks are the headless test.
- **chrome-sandbox mode.** postinst sets it to 4755 only on systems
  without user namespaces, 0755 otherwise. We ship it 0755 like upstream
  and let postinst decide.
- **File modes.** The tarball extracts with group-writable bits; build.sh
  normalises to 755/644 so the installed tree isn't group-writable.
