# ollama-cookie-brave.ps1 -- refresh ~/.claude/ollama-cookie.local from Brave.
#
# ollama-usage.py needs the ollama.com session cookie (__Secure-session). Brave
# encrypts its cookie store with app-bound encryption (v20) that is bound to the
# profile path, so neither reading the SQLite file nor copying the profile works.
# The only user-level way in is Brave's own DevTools protocol:
#   1. close Brave cleanly (WM_CLOSE, the session is saved),
#   2. relaunch it on its real profile with a debug port. Chromium >= 136 refuses
#      that on the default profile unless the DevToolsDebuggingRestrictions
#      feature is switched off (command-line kill switch),
#   3. ask CDP Network.getCookies for ollama.com and write the Cookie header,
#   4. relaunch Brave normally so the debug port does not stay open.
# Open tabs come back through --restore-last-session. Requires node (>= 22, for
# the built-in WebSocket) on PATH. Windows only.
#
# Usage:  pwsh -File ollama-cookie-brave.ps1
# Then:   python3 ~/.claude/ollama-usage.py   (should print a monthly/session line)

$ErrorActionPreference = 'Stop'
$Port = 9333
$Brave = Get-Command brave.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($Brave) { $Brave = $Brave.Source }
else {
    $Brave = Join-Path $env:ProgramFiles 'BraveSoftware\Brave-Browser\Application\brave.exe'
    if (-not (Test-Path -LiteralPath $Brave)) {
        $Brave = Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\Application\brave.exe'
    }
}
if (-not (Test-Path -LiteralPath $Brave)) { throw 'brave.exe not found' }
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw 'node not found on PATH' }
$Out = Join-Path $env:USERPROFILE '.claude\ollama-cookie.local'

function Close-Brave {
    Get-Process brave -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } |
        ForEach-Object { $null = $_.CloseMainWindow() }
    $t0 = Get-Date
    while ((Get-Process brave -ErrorAction SilentlyContinue) -and ((Get-Date) - $t0).TotalSeconds -lt 20) {
        Start-Sleep -Milliseconds 300
    }
    if (Get-Process brave -ErrorAction SilentlyContinue) {
        Start-Sleep 3
        Stop-Process -Name brave -Force -ErrorAction SilentlyContinue
        Start-Sleep 1
    }
}

$Cdp = @'
const OUT = process.argv[2], PORT = process.argv[3];
// The debug port answers before session restore has opened a tab: poll for a page.
let page;
for (let i = 0; i < 60 && !page; i++) {
  try { page = (await (await fetch(`http://127.0.0.1:${PORT}/json`)).json()).find((t) => t.type === "page"); } catch {}
  if (!page) await new Promise((r) => setTimeout(r, 500));
}
if (!page) throw new Error("no page target after 30 s");
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
const call = (method, params = {}) => new Promise((res, rej) => {
  const id = Math.floor(Math.random() * 1e9);
  const h = (ev) => { const m = JSON.parse(ev.data); if (m.id !== id) return;
    ws.removeEventListener("message", h); m.error ? rej(new Error(m.error.message)) : res(m.result); };
  ws.addEventListener("message", h);
  ws.send(JSON.stringify({ id, method, params }));
});
const { cookies } = await call("Network.getCookies", { urls: ["https://ollama.com/settings"] });
ws.close();
if (!cookies.find((c) => c.name === "__Secure-session")?.value) {
  throw new Error("__Secure-session missing: sign in to ollama.com in Brave first");
}
require("node:fs").writeFileSync(OUT, cookies.map((c) => `${c.name}=${c.value}`).join("; "), "utf-8");
console.log(`wrote ${OUT} (${cookies.map((c) => c.name).join(", ")})`);
'@
$Script = Join-Path ([System.IO.Path]::GetTempPath()) 'ollama-cookie-cdp.mjs'
# Top-level await needs an ES module; `require` is not available there, so
# rewrite that one line to an import.
$Cdp = 'import { writeFileSync } from "node:fs";' + "`n" + $Cdp.Replace('require("node:fs").writeFileSync', 'writeFileSync')
Set-Content -LiteralPath $Script -Value $Cdp -Encoding utf8

Write-Host '==> Closing Brave...'
Close-Brave
Write-Host "==> Relaunching Brave with the debug port ($Port)..."
Start-Process $Brave -ArgumentList "--remote-debugging-port=$Port", '--disable-features=DevToolsDebuggingRestrictions', '--restore-last-session'
$ready = $false
for ($i = 0; $i -lt 40 -and -not $ready; $i++) {
    Start-Sleep -Milliseconds 500
    try { $null = Invoke-RestMethod "http://127.0.0.1:$Port/json/version" -TimeoutSec 2; $ready = $true } catch {}
}
try {
    if (-not $ready) { throw "debug port $Port never answered" }
    & node $Script $Out $Port
    if ($LASTEXITCODE -ne 0) { throw 'cookie extraction failed' }
} finally {
    Write-Host '==> Relaunching Brave without the debug port...'
    Close-Brave
    Start-Process $Brave -ArgumentList '--restore-last-session'
    Remove-Item -LiteralPath $Script -Force -ErrorAction SilentlyContinue
}
Write-Host "==> Done. Test with: python3 $env:USERPROFILE\.claude\ollama-usage.py"
