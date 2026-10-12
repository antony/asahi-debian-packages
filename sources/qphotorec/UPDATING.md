# Updating qphotorec to a new upstream release

## What this package is

- Upstream: TestDisk & PhotoRec by Christophe Grenier, GPL-2.0-or-later,
  https://www.cgsecurity.org/wiki/TestDisk_Download. Release tarballs only
  (`testdisk-<V>.tar.bz2`); the git repo is https://github.com/cgsecurity/testdisk.
- Ubuntu's `testdisk` package ships testdisk, photorec and fidentify but is
  built without Qt, so there is no `qphotorec` in the archive. This package
  is a source build of upstream's tarball with its own
  `./configure && make`, packaging **only** qphotorec (binary, man page,
  desktop file, icons). It `Recommends: testdisk` for the CLI tools and
  does not conflict with it (no shared files).
- Upstream is not patched. Library Depends come from `dpkg-shlibdeps`.
- Version string is upstream's (`7.2`). The .deb is small; committed to git.

## Prerequisites

```sh
sudo apt install build-essential dpkg-dev fakeroot pkg-config \
  qtbase5-dev qttools5-dev-tools libjpeg-dev libext2fs-dev ntfs-3g-dev \
  libewf-dev libncurses-dev uuid-dev zlib1g-dev
```

## Bumping

1. Check https://www.cgsecurity.org/wiki/TestDisk_Download for a new
   stable `testdisk-<V>.tar.bz2`. Ignore `-WIP` tarballs (moving targets).
2. `curl -sLO https://www.cgsecurity.org/testdisk-<V>.tar.bz2 && sha256sum testdisk-<V>.tar.bz2`
3. Set `VERSION=` and `TARBALL_SHA256=` in `build.sh`.
4. `./build.sh`. It checks configure enabled Qt, and that
   `qphotorec --version` reports the version with ext2fs, ntfs, ewf and
   libjpeg all linked.
5. Update the README table row.

## Gotchas

- 7.2's configure only knows Qt5 (`Qt5Gui`/`Qt5Widgets` via pkg-config).
  If Qt is missing it silently builds without qphotorec; build.sh fails
  loudly instead by grepping `QPHOTOREC = qphotorec` in `src/Makefile`.
  If a future release moves to Qt6, swap the build deps to
  `qt6-base-dev qt6-tools-dev-tools` and re-check configure.ac.
- `qphotorec --version` (also `/version`, `-v`) prints and exits before
  QApplication starts, so it is safe in build.sh. Plain `qphotorec` opens
  the GUI; without `DISPLAY` it execs `photorec` instead.
- Needs root to see block devices: `sudo -E qphotorec` (or pkexec).
