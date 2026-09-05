# Bundle a portable windows Instant Client (or other native driver) for one arch.
# Reads the pinned (url, sha256) for <Namespace> + windows-<Arch> from
# config/<Namespace>.json, downloads + sha256-verifies, co-locates the DLLs (windows
# resolves siblings from the same dir - no rpath), and zips + sha256's.
# No secrets, no signing.
#
# Layout: <Out>\<Namespace>-<Major>-windows-<Arch>\  (DLLs co-located)
#
# Usage: scripts/bundle_windows.ps1 -Namespace <ns> -Major <m> -Arch <a> -Out <dir>
param(
  [Parameter(Mandatory)][string]$Namespace,
  [Parameter(Mandatory)][string]$Major,
  [Parameter(Mandatory)][string]$Arch,
  [Parameter(Mandatory)][string]$Out
)
$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent $PSScriptRoot
$target = "windows-$Arch"
$cfg    = Join-Path $root "config/$Namespace.json"
# Multi-major configs nest pinned targets under `majors.<major>.targets`; the original
# single-major shape kept a flat `targets`. Read BOTH so single-major namespaces need no migration.
$cfgObj = Get-Content $cfg -Raw | ConvertFrom-Json
$t      = if ($cfgObj.PSObject.Properties.Name -contains 'majors') { $cfgObj.majors.$Major.targets.$target } else { $cfgObj.targets.$target }
if (-not $t -or $t.url -like '*TODO*' -or $t.sha256 -like '*TODO*') {
  throw "ERROR: $target not pinned in $cfg (URL/sha are TODO)"
}

$name  = "$Namespace-$Major-windows-$Arch"
$stage = Join-Path $Out $name
$work  = New-Item -ItemType Directory -Force -Path (Join-Path $env:RUNNER_TEMP "icwork-$name")
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

Write-Host "==> download + verify $($t.url.Split('/')[-1])"
$pkg = Join-Path $work "pkg.zip"
Invoke-WebRequest -Uri $t.url -OutFile $pkg
$got = (Get-FileHash $pkg -Algorithm SHA256).Hash.ToLower()
if ($got -ne $t.sha256.ToLower()) { throw "SHA256 MISMATCH: expected $($t.sha256) got $got" }

Write-Host "==> extract + co-locate DLLs"
Expand-Archive -Path $pkg -DestinationPath (Join-Path $work "x") -Force
$icdir = Split-Path -Parent (Get-ChildItem -Recurse -Path (Join-Path $work "x") -Filter "oci.dll" | Select-Object -First 1).FullName
Get-ChildItem -Path $icdir -Filter *.dll | ForEach-Object { Copy-Item $_.FullName $stage }

# OTN condition: Oracle's notices must travel WITH the redistributed libraries. The Instant
# Client package carries them beside the libs as BASIC_LICENSE / BASIC_README. Fail loudly if
# none is found rather than shipping a bundle that silently drops the licence.
$notices = Get-ChildItem -Path $icdir | Where-Object { $_.Name -match 'LICENSE|README' }
if (-not $notices) { throw "ERROR: no Oracle LICENSE/README found in $icdir - refusing to ship without the notices" }
$notices | ForEach-Object { Copy-Item $_.FullName $stage }
Write-Host "    staged $($notices.Count) notice file(s)"

Write-Host "==> zip + sha256"
$zip = Join-Path $Out "$name.zip"
Compress-Archive -Path $stage -DestinationPath $zip -Force
(Get-FileHash $zip -Algorithm SHA256).Hash.ToLower() | Out-File -Encoding ascii "$zip.sha256"
Write-Host "OK: $zip"
