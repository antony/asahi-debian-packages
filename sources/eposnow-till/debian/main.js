// Same behaviour as Epos Now's own Mac wrapper (EposNow_Till_Mac 1.0.1,
// app.js): open the web till in Electron 25 / Chromium 114, which still
// has WebSQL. Rewritten rather than copied so no Epos Now code is shipped.
const {app, BrowserWindow} = require('electron')

app.once('ready', () => {
  const window = new BrowserWindow({
    width: 800,
    height: 600,
    show: false,
    icon: '/usr/share/icons/hicolor/512x512/apps/eposnow-till.png',
    webPreferences: {nodeIntegration: false}
  })
  window.loadURL('https://www.eposnowhq.com')
  window.once('ready-to-show', () => {
    window.maximize()
    window.show()
  })
})
