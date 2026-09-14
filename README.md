# asahi-debian-packages

A small, self-contained apt repository of Debian packages built locally
for my Asahi Linux machine, plus everything needed to rebuild them.

Packages are either `Architecture: all` (work anywhere) or `arm64`
repacks of upstream binaries that only ship a .deb for amd64.

## Packages

| Package | Version | Source | Notes |
|---|---|---|---|
| `node-corepack` | 0.36.0+ds-2 | `sources/node-corepack/` | `all`. Debian-style repack of upstream [nodejs/corepack](https://github.com/nodejs/corepack); depends on `nodejs (>= 22)` |
| `obsidian` | 1.13.7 | `sources/obsidian/` | `arm64`. Upstream [Obsidian](https://github.com/obsidianmd/obsidian-releases) only ships an amd64 .deb; this repacks their official arm64 tarball into a .deb with the same layout and scripts. **Not in git** (~90 MB) - run `./sources/obsidian/build.sh` after cloning |
| `linear` | 0.2.3 | `sources/linear/` | `arm64`. [Linear for Linux](https://github.com/zacharyftw/linear-linux), a Tauri wrapper around linear.app. Upstream only releases amd64; this is the same source built for arm64. Needs Rust and the WebKitGTK dev libs to rebuild |
| `obn` | 2.1.0 | `sources/obn/` | `arm64`. [open-bamboo-networking](https://github.com/ClusterM/open-bamboo-networking), open-source replacement for Bambu Studio's / Orca Slicer's proprietary network plugin. Upstream ships only a tarball with a per-user `install.sh`; this stages it in `/usr/lib/obn` and adds `obn-install` to run that installer as your user. Committed (~1.5 MB) |
| `librepods` | 0.1.0 | `sources/librepods/` | `arm64`. [LibrePods](https://github.com/librepods-org/librepods) Linux client (the Rust/iced rewrite in `linux-rust/`, tag `linux-v0.1.0`): AirPods battery, noise control, ear detection from a tray app. Upstream only ships an x86_64 AppImage; this is the same source built for arm64. Needs Rust plus `libdbus-1-dev`. Committed (~4 MB) |

## Using the repo on your machine

Clone it, start the server, add it as an apt source:

```sh
git clone https://github.com/antony/asahi-debian-packages.git
cd asahi-debian-packages
./serve.sh          # serves http://127.0.0.1:8321
```

In another terminal:

```sh
echo 'deb [trusted=yes] http://127.0.0.1:8321 ./' \
  | sudo tee /etc/apt/sources.list.d/asahi-local.list
sudo apt update
sudo apt install node-corepack
```

### Without the HTTP server

apt can read the repo straight off the filesystem, no server needed:

```sh
echo "deb [trusted=yes] file:$(pwd)/repo ./" \
  | sudo tee /etc/apt/sources.list.d/asahi-local.list
sudo apt update
sudo apt install node-corepack
```

### A note on `[trusted=yes]`

The repo is unsigned; `[trusted=yes]` tells apt to accept it without a
signature. That is fine for a repo you built yourself and serve from
localhost. Keep `serve.sh` bound to 127.0.0.1 (its default) and don't
point the sources.list line at a repo you don't control.

## Repository layout

```
repo/               the apt repo itself: *.deb + Packages(.gz) + Release
serve.sh            tiny HTTP server for repo/ (python3 http.server)
update-index.sh     regenerates repo/Packages, Packages.gz and Release
sources/<name>/     per-package: debian/ packaging, the Debian source
                    package (.dsc + tarballs), build.sh, UPDATING.md
```

## Rebuilding and updating packages

Each package directory under `sources/` contains:

- `build.sh` - rebuilds the current version from the source package,
  runs its smoke tests, copies the .deb into `repo/` and reindexes.
- `UPDATING.md` - exact step-by-step instructions (written for an AI
  assistant or a human) for bumping the package to a new upstream
  version, including known gotchas and the verification checklist.

To rebuild what's already here:

```sh
./sources/node-corepack/build.sh
./sources/obsidian/build.sh        # required after a fresh clone, see below
```

Large binary repacks (currently `obsidian`) are gitignored under
`repo/` because GitHub rejects files over 100 MB and each version would
bloat history. Their `build.sh` downloads the upstream release,
checksum-verifies it, builds the .deb, and reindexes.

To update to a new upstream release, follow the package's
`UPDATING.md`, then commit the refreshed sources and the regenerated
index files (plus the .deb, for the small `all` packages).

## Adding a new package

In Claude Code, type `add <package or URL>` - the `add` skill in
`.claude/skills/add/` walks through the same steps used for the existing
packages: pick the cheapest route (upstream arm64 .deb, upstream arm64
binary repack, `Architecture: all` repack, or build from source), create
`sources/<name>/` with `build.sh` and `UPDATING.md`, build, smoke test,
reindex, update this table.

Build requirements: `dpkg-dev`, `nodejs (>= 22)`, `npm`, and network
access to registry.npmjs.org. No debhelper needed - the packaging uses
standalone makefile rules on purpose, so it builds on minimal systems.
