# asahi-debian-packages

A small, self-contained apt repository of Debian packages built locally
for my Asahi Linux machine, plus everything needed to rebuild them.

All packages here are `Architecture: all`, so they work on arm64
(Asahi) and any other Debian architecture.

## Packages

| Package | Version | Source | Notes |
|---|---|---|---|
| `corepack` | 0.36.0+ds-1 | `sources/node-corepack/` | Debian-style repack of upstream [nodejs/corepack](https://github.com/nodejs/corepack); depends on `nodejs (>= 22)` |

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
sudo apt install corepack
```

### Without the HTTP server

apt can read the repo straight off the filesystem, no server needed:

```sh
echo "deb [trusted=yes] file:$(pwd)/repo ./" \
  | sudo tee /etc/apt/sources.list.d/asahi-local.list
sudo apt update
sudo apt install corepack
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
```

To update to a new upstream release, follow
`sources/node-corepack/UPDATING.md`, then commit the refreshed source
package, the new .deb and the regenerated index files.

Build requirements: `dpkg-dev`, `nodejs (>= 22)`, `npm`, and network
access to registry.npmjs.org. No debhelper needed - the packaging uses
standalone makefile rules on purpose, so it builds on minimal systems.
