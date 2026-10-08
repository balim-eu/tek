param([string]$Version = $env:TEK_VERSION)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Repository = 'balim-eu/tek'
$ReleasesUrl = if ($env:TEK_RELEASES_URL) { $env:TEK_RELEASES_URL } else { "https://github.com/$Repository/releases" }
$ApiUrl = if ($env:TEK_API_URL) { $env:TEK_API_URL } else { "https://api.github.com/repos/$Repository" }
$InstallDir = if ($env:TEK_INSTALL_DIR) { $env:TEK_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'tek\bin' }
$Asset = 'tek-windows-x64.zip'

Remove-Item Env:TEK_VERSION -ErrorAction SilentlyContinue
if (-not $Version) { $Version = 'latest' }
if ($Version -eq 'pre-release') {
  $Version = @(Invoke-RestMethod -Uri "$ApiUrl/releases?per_page=1" -UseBasicParsing)[0].tag_name
  if (-not $Version) { throw "No release found at $ReleasesUrl" }
}
$Base = if ($Version -eq 'latest') { "$ReleasesUrl/latest/download" } else { "$ReleasesUrl/download/$Version" }

$Temp = Join-Path ([IO.Path]::GetTempPath()) ("tek-" + [Guid]::NewGuid())
New-Item -ItemType Directory -Path $Temp | Out-Null
try {
  Write-Host "Downloading tek $Version for windows-x64..."
  Invoke-WebRequest -Uri "$Base/$Asset" -OutFile (Join-Path $Temp $Asset) -UseBasicParsing
  Invoke-WebRequest -Uri "$Base/SHA256SUMS" -OutFile (Join-Path $Temp 'SHA256SUMS') -UseBasicParsing

  $Expected = Get-Content (Join-Path $Temp 'SHA256SUMS') |
    ForEach-Object { , ($_ -split '\s+') } |
    Where-Object { $_[1] -eq $Asset -or $_[1] -eq "*$Asset" } |
    ForEach-Object { $_[0] } |
    Select-Object -First 1
  if (-not $Expected) { throw "SHA256SUMS does not list $Asset" }
  $Actual = (Get-FileHash -Path (Join-Path $Temp $Asset) -Algorithm SHA256).Hash.ToLower()
  if ($Actual -ne $Expected.ToLower()) { throw "Checksum mismatch for $Asset (expected $Expected, got $Actual)" }

  Expand-Archive -Path (Join-Path $Temp $Asset) -DestinationPath $Temp -Force
  if (-not (Test-Path (Join-Path $Temp 'tek.exe'))) { throw "$Asset does not contain tek.exe" }

  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  $Target = Join-Path $InstallDir 'tek.exe'
  Copy-Item -Path (Join-Path $Temp 'tek.exe') -Destination $Target -Force
  $Installed = & $Target --version
  Write-Host "Installed $Installed to $Target"

  $UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if (($UserPath -split ';') -notcontains $InstallDir) {
    $NewPath = if ($UserPath) { "$UserPath;$InstallDir" } else { $InstallDir }
    [Environment]::SetEnvironmentVariable('Path', $NewPath, 'User')
    Write-Host "Added $InstallDir to your PATH. Open a new terminal, then run 'tek --help' to get started."
  } else {
    Write-Host "Run 'tek --help' to get started."
  }
} finally {
  Remove-Item -Path $Temp -Recurse -Force -ErrorAction SilentlyContinue
}
