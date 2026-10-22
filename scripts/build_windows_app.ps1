param([switch]$SkipInstall)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$python = Join-Path $repo '.venv\Scripts\python.exe'
if (-not (Test-Path $python)) {
    & python -m venv (Join-Path $repo '.venv')
    if ($LASTEXITCODE -ne 0) { throw 'Python 3.11+ is required.' }
}
if (-not $SkipInstall) {
    & $python -m pip install -r (Join-Path $repo 'desktop\requirements-dev.txt')
    if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed.' }
}
Push-Location $repo
try {
    & $python -m PyInstaller --noconfirm --clean --windowed --noupx --onedir `
        --name LeedsHPCMonitor --paths desktop --paths scripts `
        --hidden-import keyring.backends.Windows --copy-metadata keyring `
        --collect-data tzdata `
        --distpath desktop/dist --workpath desktop/build --specpath desktop `
        --add-data "$(Join-Path $repo 'LICENSE');." `
        --add-data "$(Join-Path $repo 'desktop\THIRD_PARTY_NOTICES.md');." desktop/main.py
    if ($LASTEXITCODE -ne 0) { throw 'Packaging failed.' }
    $output = Join-Path $repo 'desktop\dist'
    Copy-Item (Join-Path $repo 'WINDOWS_APP.md') (Join-Path $output 'LeedsHPCMonitor\WINDOWS_APP.md')
    & $python (Join-Path $repo 'desktop\collect_licenses.py') (Join-Path $output 'LeedsHPCMonitor\licenses')
    if ($LASTEXITCODE -ne 0) { throw 'Could not collect dependency licences.' }
    $env:QT_QPA_PLATFORM = 'offscreen'
    try {
        $smoke = Start-Process -FilePath (Join-Path $output 'LeedsHPCMonitor\LeedsHPCMonitor.exe') -ArgumentList '--smoke-test' -PassThru
        if (-not $smoke.WaitForExit(30000)) {
            $smoke.Kill()
            throw 'Packaged startup timed out.'
        }
        if ($smoke.ExitCode -ne 0) { throw "Packaged startup failed with exit code $($smoke.ExitCode)." }
    } finally {
        Remove-Item Env:\QT_QPA_PLATFORM -ErrorAction SilentlyContinue
    }
    Compress-Archive -Path (Join-Path $output 'LeedsHPCMonitor') -DestinationPath (Join-Path $output 'LeedsHPCMonitor-Windows-x64.zip') -Force
    Get-FileHash (Join-Path $output 'LeedsHPCMonitor-Windows-x64.zip') -Algorithm SHA256
} finally {
    Pop-Location
}
