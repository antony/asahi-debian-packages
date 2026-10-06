# Updating bambustudio-beta to a new upstream pre-release

Step-by-step instructions for bumping this package. Written so an AI
assistant (or a human in a hurry) can do the whole update without
re-deriving anything. Read the gotchas at the bottom before improvising.

## What this package is

- Upstream: https://github.com/bambulab/BambuStudio (AGPL-3.0). Bambu
  Lab's slicer and printer front end.
- This package tracks upstream **pre-release** tags (GitHub marks them
  "Pre-release"; version.inc is what the app reports). Stable is
  installed separately on this machine as the Flathub build
  `com.bambulab.BambuStudio`; both can be installed at once. The .deb
  renames the desktop entry to "Bambu Studio (beta)" so the two are
  distinguishable in the launcher.
- Upstream Linux release assets are x86_64-only AppImages (checked by
  reading the ELF header, not the file name). Flathub builds aarch64 but
  only for stable, so this is a **source build**: upstream's own CMake
  for `deps/` then the app, exactly as `./BuildLinux.sh -d -s` would do
  it, installed with `-DSLIC3R_FHS=ON` into a staging root and wrapped
  with `dpkg-deb`. No debhelper.
- Upstream source is patched only by the files in `patches/`, which are
  upstream fixes (see Step 3). `build.sh` pins both the tag and the
  commit it must resolve to.
- The .deb is ~200 MB (resources/ alone is 420 MB) and is **gitignored**;
  `build.sh` is the way to regenerate it.

## Prerequisites

- The apt packages in the `DEPS` list at the top of `build.sh`. This is
  upstream's `linux.d/debian` list minus `libfuse2` (AppImage only) plus
  `dpkg-dev` and `fakeroot`. `build.sh` prints the exact `sudo apt
  install` line for anything missing.
- ~15 GB free under `sources/bambustudio-beta/build/`. About 2 hours on
  a 12-core M-series Mac under Asahi for a clean build; `build/src` is
  kept so a version bump only rebuilds what changed.

## Step 1 - find the new version

```sh
curl -s "https://api.github.com/repos/bambulab/BambuStudio/releases?per_page=10" \
  | python3 -c 'import json,sys; [print(r["tag_name"], "pre" if r["prerelease"] else "stable") for r in json.load(sys.stdin)]'
git ls-remote --tags https://github.com/bambulab/BambuStudio.git 'v<V>^{}'
```

Pick the newest tag marked `pre`. If the newest tag is stable, there is
no newer beta; stop. The second command prints the commit the tag points
at. Call them `$V` (without the leading `v`, e.g. `02.08.03.66`) and
`$COMMIT`.

## Step 2 - bump build.sh

```sh
VERSION=<V>
UPSTREAM_COMMIT=<COMMIT>
```

## Step 3 - re-check the patches

Each file in `patches/` is an upstream PR. For each, check whether the
tag already contains it; drop the patch if so, and expect `git apply`
to fail loudly if a patch no longer fits.

| patch | upstream | why |
|---|---|---|
| `0001-missing-includes-pr11895.patch` | PR 11895, merged 2026-09-09 (after the 02.08.03.66 tag) | three missing `#include`s that GCC 15 rejects |
| `0002-boost-format-include-pr11754.patch` | PR 11754, open | `boost/format.hpp` include in DevUtil.h |
| `0003-deps-c11-for-gcc15.patch` | ours, not upstream | adds `-DCMAKE_C_STANDARD=11` to every CMake dep; GCC 15 defaults to C23 where c-blosc's `typedef _Bool bool` is an error (Flathub patches blosc itself instead) |
| `0004-openmeshcraft-no-x86-simd-on-arm64.patch` | ours, not upstream | upstream's `deps/OpenMeshCraft/OpenMeshCraft.cmake` only turns OMC's SSE2/AVX/AVX2/FMA options off on Apple, so on Linux arm64 GCC gets `-mavx2 -mfma` and dies. Extends the condition to any non-x86 host |

Quick test: `grep -c '#include <map>' build/src/src/libslic3r/FilamentMixer.hpp`
and `grep -c boost/format.hpp build/src/src/slic3r/GUI/DeviceCore/DevUtil.h`
after the clone; `1` means the fix landed upstream.

The Flathub manifest (https://github.com/flathub/com.bambulab.BambuStudio,
maintained by hadess) is the best source of new build fixes: its
`patches/` directory and the `wip/hadess/v<V>` branch usually carry
exactly what a new tag needs on a modern GCC. Their `system-*`,
`offline-npm` and `no-boost-system` patches are Flatpak-specific and not
needed here.

## Step 4 - build and test

```sh
./sources/bambustudio-beta/build.sh 2>&1 | tee sources/bambustudio-beta/build/build.log
```

Then install and launch for real:

```sh
sudo apt update && sudo apt install bambustudio-beta   # or: sudo apt install ./repo/bambustudio-beta_<V>_arm64.deb
bambu-studio
```

Check Help > About shows `$V`, a printer page loads (the embedded
WebKit view), and the camera stream plays if you have a printer on the
network (GStreamer via the Recommends).

## Step 5 - commit

Commit `sources/bambustudio-beta/build.sh`, `patches/` and `UPDATING.md`
if changed, and the regenerated `repo/Packages`, `Packages.gz`,
`Release`. The .deb itself is gitignored. Update the version in the
README table.

## Gotchas

- **Version string keeps upstream's leading zeros** (`02.08.03.66`).
  dpkg compares version components numerically so `02.08.03.66` <
  `02.08.04.50` as expected. Don't strip them; it would make the
  package version disagree with what the app reports.
- **wxWidgets is not pinned by upstream.** `deps/wxWidgets/wxWidgets.cmake`
  fetches `bambulab/wxWidgets` at `master`. That is what upstream's own
  CI does, so it is left alone, but it means two builds of the same tag
  can differ in wx. If wx breaks, look at that fork's recent commits.
- **Node and pnpm are downloaded at configure time** by
  `src/slic3r/GUI/DeviceWeb/CMakeLists.txt` (pinned versions with
  sha256, arm64 aware) into `build/node-cache/` next to the source. The
  device web pages are built with pnpm during the app build, so the
  first build needs network access beyond the initial clone.
- **`cmake --install` needs `-DSLIC3R_FHS=ON` at configure time**, which
  also forces `SLIC3R_DESKTOP_INTEGRATION` off (correct for a .deb: the
  package owns the desktop file and icons). Without FHS the install
  rules dump everything into a bundle-style layout.
- **Depends come from `dpkg-shlibdeps`**, run in a scratch dir with a
  three-line `debian/control` because the tool insists one exists. Boost,
  TBB, wx, OpenCV etc. are static (`SLIC3R_STATIC=1`), so the list is
  GTK, WebKitGTK, GStreamer, OpenGL, curl, ssl and friends.
- **Never launch the GUI from build.sh.** `bambu-studio --help` runs in
  CLI mode and exits; that is the version check.
- **Flathub's TBB LTO patch is not applied.** It no longer matches
  upstream's `deps/TBB/TBB.cmake` and the 02.08.03.66 build did not need
  it. If the final link fails with TBB symbol errors, port it.
