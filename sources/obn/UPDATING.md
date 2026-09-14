# Updating obn to a new upstream release

Step-by-step instructions for bumping this package. Written so an AI
assistant (or a human in a hurry) can do the whole update without
re-deriving anything. Read the gotchas at the bottom before improvising.

## What this package is

- Upstream: https://github.com/ClusterM/open-bamboo-networking, AGPL-3.0
  or later. Open-source drop-in replacement for the proprietary
  `bambu_networking` plugin that Bambu Studio / Orca Slicer download on
  first start. We redistribute upstream's binaries unmodified.
- Upstream ships no .deb, only `obn-linux-aarch64.tar.gz` (and x64, macOS,
  Windows archives). The tarball holds `install.sh`, `VERSION`, `README.txt`
  and `lib/vXX.XX.XX/` directories, one per supported slicer ABI, each with
  `libbambu_networking.so`, `libBambuSource.so`, `liblive555.so` and
  `network_plugins.json`.
- The plugin is loaded from the *user's* slicer config directory
  (`~/.config/BambuStudio/plugins`, the Flatpak equivalent, or
  `~/.config/OrcaSlicer/plugins`), so a .deb can't put it in place as
  root. `build.sh` stages the tarball verbatim in `/usr/lib/obn/` and adds
  `/usr/bin/obn-install` (`debian/obn-install`), a wrapper that runs
  `/usr/lib/obn/install.sh` as the current user. That is exactly the
  README's `chmod +x install.sh && ./install.sh` step.
- `debian/control.in` Depends are the direct `DT_NEEDED` libraries of the
  .so files (`readelf -d`): libssl/libcrypto 3, libcurl4, libstdc++,
  libgcc, libc. `python3` is only Recommends: install.sh uses it to patch
  the slicer conf and skips that step with a warning if it's missing.
- Version string is upstream's (`2.1.0` for tag `v2.1.0`).
- `.deb` is ~1.5 MB (xz squashes the 15 near-identical ABI dirs), so it is
  committed to `repo/` like the small packages.

## Prerequisites

`dpkg-dev`, `fakeroot`, `curl`, `python3`. No root, no network beyond
github.com.

## Step 1 - find the new version and checksums

```sh
V=$(curl -sS https://api.github.com/repos/ClusterM/open-bamboo-networking/releases/latest \
    | grep -o '"tag_name": *"v[^"]*"' | grep -o '[0-9][0-9.]*')
echo "$V"
curl -fL -o "sources/obn/dl/obn-$V-linux-aarch64.tar.gz" \
  "https://github.com/ClusterM/open-bamboo-networking/releases/download/v$V/obn-linux-aarch64.tar.gz"
curl -fL -o "sources/obn/dl/LICENSE-v$V" \
  "https://raw.githubusercontent.com/ClusterM/open-bamboo-networking/v$V/LICENSE"
sha256sum "sources/obn/dl/obn-$V-linux-aarch64.tar.gz" "sources/obn/dl/LICENSE-v$V"
```

## Step 2 - bump build.sh

Edit the three constants at the top of `build.sh`:

```sh
VERSION=<V>
TARBALL_SHA256=<tarball sha256>
LICENSE_SHA256=<LICENSE sha256>
```

## Step 3 - check whether upstream changed the tarball layout or installer

```sh
tar tzf sources/obn/dl/obn-$V-linux-aarch64.tar.gz | grep -v '/lib/v'
tar xzf sources/obn/dl/obn-$V-linux-aarch64.tar.gz -C sources/obn/dl
diff sources/obn/build/pkg/usr/lib/obn/install.sh sources/obn/dl/obn-linux-aarch64/install.sh
readelf -d sources/obn/dl/obn-linux-aarch64/lib/v*/libbambu_networking.so | grep NEEDED | sort -u
```

- New `DT_NEEDED` library: add it to `Depends` in `debian/control.in`.
- Installer prompts changed (client menu, extra questions): update the
  `printf '1\n\n'` / `printf '2\n\n'` answer strings and the expected
  files in the smoke test at the bottom of `build.sh`.
- Installer now writes something new to the config dir: add it to the
  smoke test's `for f in ...` list.
- Newest `lib/vXX.XX.XX/`: the Bambu Studio smoke test pins
  `02.08.03` in the fake `BambuStudio.conf` and the `cmp` line. It only
  needs changing if upstream drops that directory; bump both to a
  version that exists.

## Step 4 - build and test

```sh
./sources/obn/build.sh
apt-get -s install ./repo/obn_<V>_arm64.deb
```

`build.sh` verifies checksums, checks the tarball's `VERSION` file matches,
builds the .deb, checks every .so is an aarch64 ELF that resolves, verifies
md5sums, then runs the packaged `obn-install` against throwaway Bambu Studio
and Orca Slicer config dirs in a fake `$HOME` and checks the files land and
the confs get patched. It copies the .deb into `repo/` and reindexes.

Then for real:

```sh
sudo apt update && sudo apt install obn
# close Bambu Studio first
obn-install
```

Start the slicer; Device tab should connect to the printer over LAN and
`<config>/obn.log` should appear. `obn-install` must be re-run after every
package upgrade because the live copy is in the user's config dir.

## Step 5 - commit

Commit `sources/obn/build.sh` (and anything changed in `debian/`), the new
`repo/obn_<V>_arm64.deb`, remove the old one, plus `repo/Packages`,
`repo/Packages.gz`, `repo/Release`. Update the version in the README table.

## Gotchas

- **Upstream reuses the asset name across releases.** Every release is
  `obn-linux-aarch64.tar.gz`; `build.sh` caches it as
  `dl/obn-<V>-linux-aarch64.tar.gz` so old and new don't collide.
- **Slicer ABI must be in the tarball.** `install.sh` reads
  `"version"` from `BambuStudio.conf`, takes `major.minor.patch` and needs
  `lib/v<that>/` to exist. When Bambu Studio updates past the newest
  directory, users get "No compatible ABI version" until upstream ships a
  new archive. `build.sh` prints the shipped ABI list; check it against the
  installed slicer (Flatpak: `flatpak list | grep -i bambu`).
- **Orca is pinned to 02.03.00** by upstream's installer, with a versioned
  file name `libbambu_networking_02.03.00.99.so`. Not a bug.
- **Flatpak Bambu Studio loads the .so inside its sandbox**, so the host
  `Depends` don't matter for that case; the Freedesktop runtime provides
  libcurl and OpenSSL 3. Upstream lists Flatpak as supported and the
  installer knows the `~/.var/app/com.bambulab.BambuStudio/config/BambuStudio`
  path. Untested here beyond the installer's path detection.
- **`liblive555.so` is kept if the existing one is big.** The installer
  leaves a vendor `liblive555.so` over 64 KB in place (the stock plugin's
  real live555 build) and only drops in its 69 KB stub otherwise. Expected.
- **Don't run obn-install as root.** The wrapper refuses, because the
  installer would write into `/root/.config`. `OBN_ALLOW_ROOT=1` overrides;
  `OBN_DIR` points it at a different staging tree (the smoke test uses this).
- **The package can't uninstall the plugin from user config dirs.**
  `apt remove obn` only removes `/usr/lib/obn` and the wrapper. Reverting a
  user is manual: see `/usr/share/doc/obn/README.Debian`.
