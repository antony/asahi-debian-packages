# Updating comfyui to a new upstream release

Step-by-step instructions for bumping this package. Written so an AI
assistant (or a human in a hurry) can do the whole update without
re-deriving anything. Read the gotchas at the bottom before improvising.

## What this package is

- Upstream: https://github.com/comfyanonymous/ComfyUI, GPL-3.0. Node-based
  UI for Stable Diffusion and other generative models. Releases are tags
  `v<V>`; the only release assets are Windows portable 7z bundles. There
  is no Linux binary and the Electron desktop app (Comfy-Org/desktop) has
  no Linux arm64 build, so this is a repack of the **source tarball**
  (`archive/refs/tags/v<V>.tar.gz`), `Architecture: all`.
- Upstream's install is "clone, make a venv, pip install torch, pip
  install -r requirements.txt, python main.py". PyTorch and most of
  requirements.txt are not in the Ubuntu archive and weigh ~2.5 GB, so
  they cannot go in the .deb. `build.sh` stages the tree verbatim in
  `/usr/lib/comfyui` and installs `debian/comfyui` as `/usr/bin/comfyui`,
  which does the venv + pip steps per user in `~/.local/share/comfyui/venv`
  on first run, seeds `models/`, `custom_nodes/`, `input/` from the tree,
  then runs `main.py --base-directory ~/.local/share/comfyui --cpu`.
- The venv carries a `.comfyui-version` stamp. When the package version
  changes, the launcher re-runs pip against the new `requirements.txt`
  (pinned `comfyui-frontend-package` etc. move every release).
- `postinst` byte-compiles `/usr/lib/comfyui` with the system python3
  (the venv uses the same interpreter); `prerm` removes the `__pycache__`.
- Dev-only files (`tests/`, `tests-unit/`, `.github/`, `.ci/`, lint
  configs, `AGENTS.md`, `CONTRIBUTING.md`) are not shipped. Nothing
  shipped is modified, so the version string stays upstream's.
- The .deb is ~8 MB, committed to `repo/`.

## Prerequisites

`dpkg-dev`, `fakeroot`, `curl`, `python3 (>= 3.12)`, network access to
github.com. `COMFYUI_E2E=1` also needs pypi.org and download.pytorch.org
and ~3 GB under `sources/comfyui/dl/e2e/`.

## Step 1 - find the new version and checksum

```sh
git ls-remote --tags https://github.com/comfyanonymous/ComfyUI.git 'v0.*' \
  | grep -v '\^{}' | sed 's|.*refs/tags/||' | sort -V | tail -1
V=<that without the v>
git ls-remote https://github.com/comfyanonymous/ComfyUI.git refs/tags/v$V   # -> COMMIT
curl -fL -o sources/comfyui/dl/ComfyUI-$V.tar.gz \
  https://github.com/comfyanonymous/ComfyUI/archive/refs/tags/v$V.tar.gz
sha256sum sources/comfyui/dl/ComfyUI-$V.tar.gz
```

Tags are lightweight, so `ls-remote` prints one line per tag. Ignore
`latest`-style or `v0.x.y-rc` tags if any appear.

## Step 2 - bump build.sh

```sh
VERSION=<V>
COMMIT=<sha>
TARBALL_SHA256=<sha256>
```

## Step 3 - check whether upstream changed anything the launcher relies on

```sh
tar tzf sources/comfyui/dl/ComfyUI-$V.tar.gz | sed "s|^ComfyUI-$V/||" | grep -v / 
curl -sL https://raw.githubusercontent.com/comfyanonymous/ComfyUI/v$V/README.md | grep -iE 'python 3\.1[0-9]'
grep -n 'base-directory\|"--cpu"' <(tar xzf sources/comfyui/dl/ComfyUI-$V.tar.gz -O ComfyUI-$V/comfy/cli_args.py)
```

- `comfyui_version.py` gone or renamed: `build.sh` and the launcher both
  read `__version__` from it; point them at the new location.
- `--base-directory` or `--cpu` renamed: fix `debian/comfyui`.
- New top-level dir that a fresh checkout is expected to have (like
  `models/`, `custom_nodes/`, `input/`): add it to the seed loop in
  `debian/comfyui` and the `for f in` list in `build.sh`.
- Minimum Python raised past what Ubuntu ships: bump `Depends` in
  `debian/control.in`. Check the README's supported-versions note; 3.14
  is "works" for 0.36.0, 3.13 "very well supported".
- New dev-only clutter at the top level: add it to the `rm -rf` in
  `build.sh` if it is clearly not runtime (tests, CI, lint configs).

## Step 4 - build and test

```sh
COMFYUI_E2E=1 ./sources/comfyui/build.sh
apt-get -s install ./repo/comfyui_<V>_all.deb
```

`build.sh` verifies the checksum and that the tag still points at
`$COMMIT`, checks `comfyui_version.py` agrees with `$VERSION`, builds the
.deb, checks expected files and md5sums, byte-compiles every `.py` with
the system python3 (catches syntax the installed Python can't run),
checks the launcher refuses root, then (with `COMFYUI_E2E=1`) runs the
packaged launcher for real against `dl/e2e/`: creates the venv, installs
CPU torch and requirements, starts ComfyUI with `--quick-test-for-ci` and
checks the base dir got seeded and the sqlite db was created. Copies the
.deb into `repo/` and reindexes.

Then for real:

```sh
sudo apt update && sudo apt install comfyui
comfyui --auto-launch
```

First launch installs the venv (minutes); the browser should open on
http://127.0.0.1:8188 with the frontend. Existing users get a pip run
against the new requirements on their next launch.

## Step 5 - commit

Commit `sources/comfyui/build.sh` (and anything changed in `debian/`), the
new `repo/comfyui_<V>_all.deb`, remove the old one, plus `repo/Packages`,
`repo/Packages.gz`, `repo/Release`. Update the version in the README table.

## Gotchas

- **`--cpu` is mandatory with the CPU torch build.** ComfyUI's
  `model_management` assumes CUDA unless `--cpu` (or an XPU/MPS/DirectML
  build) is present and dies with "Torch not compiled with CUDA enabled".
  The launcher adds `--cpu` whenever `COMFYUI_TORCH_INDEX` is the default
  CPU index. Asahi has no PyTorch GPU backend, so CPU is all there is.
- **`custom_nodes/` must exist in the base directory** or
  `execute_prestartup_script` crashes on `os.listdir`. That's why the
  launcher seeds it (and it carries upstream's built-in
  `websocket_image_save.py`). Only `--base-directory`'s `custom_nodes` is
  scanned, never `/usr/lib/comfyui/custom_nodes`.
- **`extra_model_paths.yaml` is read from the source dir**
  (`/usr/lib/comfyui`), which users can't write. README.Debian tells them
  to use `--extra-model-paths-config`. Don't "fix" this by making the
  tree writable.
- **Python 3.14 + torch prints a `torch.jit.script` FutureWarning** at
  startup. Harmless; upstream says 3.14 works but some custom nodes may
  not. If a release starts failing on 3.14, Ubuntu 26.04 has no 3.13 in
  main; that would mean a bigger change (deadsnakes or a bundled
  interpreter), so check upstream's README note first.
- **pip's torch install must come before requirements.txt.**
  `requirements.txt` lists bare `torch`, which pip would resolve from PyPI
  to the CUDA build (~2 GB of nvidia wheels that can't load here). The
  launcher installs torch/torchvision/torchaudio from the CPU index first
  so the bare names are already satisfied.
- **`quick-test-for-ci` exits before the temp dir is created**, so the
  E2E check looks for `user/comfyui.db`, not `temp/`.
- **GitHub source tarballs are stable per tag** (GitHub committed to that
  in 2023) but the sha256 is still pinned; a mismatch means either a
  moved tag (the `COMMIT` check will also fail) or tampering.
- **Nothing is written into `/usr/lib/comfyui` at runtime** except the
  `__pycache__` that postinst pre-creates; the launcher `cd`s into the
  base dir so any relative-path writes land there. Verified by running
  with the tree read-only under `dl/`.
