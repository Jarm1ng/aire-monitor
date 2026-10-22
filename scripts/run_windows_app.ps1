param([switch]$Demo)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$python = Join-Path $repo '.venv\Scripts\python.exe'
if (-not (Test-Path $python)) {
    throw 'Create the environment first: python -m venv .venv; .\.venv\Scripts\python.exe -m pip install -r desktop\requirements.txt'
}
$arguments = @((Join-Path $repo 'desktop\main.py'))
if ($Demo) { $arguments += '--demo' }
& $python @arguments
exit $LASTEXITCODE
