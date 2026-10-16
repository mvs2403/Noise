$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$version = (Get-Content VERSION -Raw).Trim()
$stage = Join-Path $root '.cache/windows-package'
$dist = Join-Path $root 'dist/desktop'
New-Item -ItemType Directory -Force $stage, $dist | Out-Null
dotnet restore Desktop/Noise.Desktop.csproj --locked-mode
if ($LASTEXITCODE) { throw 'Restore failed' }
dotnet publish Desktop/Noise.Desktop.csproj -c Release -r win-x64 --self-contained true -o $stage /p:Version=$version /p:PublishReadyToRun=true
if ($LASTEXITCODE) { throw 'Publish failed' }
python script/bootstrap_desktop.py --output $stage
if ($LASTEXITCODE) { throw 'Native build failed' }
dotnet (Join-Path $stage 'Noise.dll') --self-test
if ($LASTEXITCODE) { throw 'DSP self-test failed' }
$smoke = Start-Process -FilePath (Join-Path $stage 'Noise.exe') -ArgumentList '--smoke-ui' -PassThru -Wait
if ($smoke.ExitCode -ne 0 -or !(Test-Path (Join-Path $stage 'windows-controls.png'))) { throw 'Windows GUI smoke test failed' }
Copy-Item (Join-Path $stage 'windows-controls.png') $dist
Remove-Item (Join-Path $stage 'windows-controls.png')
Copy-Item docs/WINDOWS.md (Join-Path $stage 'START-HERE.md')
Copy-Item README.md, VERSION $stage
Compress-Archive -Path "$stage/*" -DestinationPath (Join-Path $dist "Noise-$version-windows-x64.zip") -Force
if (!(Get-Command makensis -ErrorAction SilentlyContinue)) {
    choco install nsis --no-progress -y
    if ($LASTEXITCODE) { throw 'Installer tool installation failed' }
    $env:Path += ';C:\Program Files (x86)\NSIS'
}
makensis /DVERSION=$version /DSTAGE=$stage /DOUTPUT="$dist\Noise-$version-windows-x64-setup.exe" script/windows-installer.nsi
if ($LASTEXITCODE) { throw 'Installer build failed' }
# Inspect the unsigned installer without installing drivers or changing audio defaults.
Get-ChildItem $dist -File | Get-FileHash -Algorithm SHA256 | ForEach-Object { "$($_.Hash.ToLower())  $([IO.Path]::GetFileName($_.Path))" } | Set-Content (Join-Path $dist 'SHA256SUMS.txt')
