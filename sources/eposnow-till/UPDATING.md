# Updating eposnow-till

## What this package is

- Epos Now's Mac till (`EposNow_Till_Mac_1.0.1.dmg`) is an Electron 25.9.8
  app whose whole `app.js` is `loadURL("https://www.eposnowhq.com")` in a
  maximised window. Its readme says Electron 25 / Chromium 114 is pinned
  on purpose: the web till uses WebSQL, which Chrome removed in 119.
- This package is the official Electron arm64 Linux zip plus our own
  `debian/main.js` doing the same thing. No Epos Now code is shipped. The
  icon (`debian/icon.png`) was taken from the dmg's `icon.icns`.
- Layout mirrors `sources/obsidian/`: `/opt/eposnow-till/`, the binary
  renamed `eposnow-till`, `/usr/bin/eposnow-till` via update-alternatives,
  and an AppArmor `userns` profile (Ubuntu restricts unprivileged user
  namespaces, which the Chromium sandbox needs). `postinst`/`postrm` are
  obsidian's with paths swapped.
- `VERSION` tracks the Mac app's version; `ELECTRON_VERSION` is separate.
- The Windows `POSInstall_*.exe` is a different, native .NET till (WiX
  bundle, x86). Not usable here.

## Bumping

1. If Epos Now ship a new Mac dmg, extract it (`7z x`, the `7zip` package
   works when unpacked locally with `apt-get download`), then extract
   `Contents/Resources/app.asar` (`npx @electron/asar e`) and read
   `app.js` and `Contents/Frameworks/Electron Framework.framework/Resources/Info.plist`.
   Copy any behaviour change into `debian/main.js`, set `VERSION`.
2. Set `ELECTRON_VERSION` to the Electron version they ship, and
   `ELECTRON_SHA256` from that release's `SHASUMS256.txt`
   (`electron-v<V>-linux-arm64.zip`).
3. `./build.sh`. Then launch `eposnow-till` once and log in.

## Gotchas

- Don't move to Electron >= 28 (Chromium 119+) or Tauri: Chromium 119+
  dropped WebSQL, and WebKitGTK 2.52 (what Tauri uses here) has
  `typeof openDatabase === 'undefined'` (tested 2026-10-06).
- Electron 25 works on Asahi's 16K pages (tested, loads the login page).
- `--version` with our app in place launches the full app (only Electron's
  removed `default_app.asar` handles it). build.sh uses
  `ELECTRON_RUN_AS_NODE=1 ... -p process.versions.electron` instead.
- `package.json` has no `productName` so WM_CLASS and the desktop file's
  `StartupWMClass` are both `eposnow-till`. User data lives in
  `~/.config/eposnow-till` (including the WebSQL databases - don't delete
  it on a live till).
