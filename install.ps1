param(
  [Parameter(Mandatory = $true)]
  [string]$Server,

  [Alias("JoinToken")]
  [string]$EnrollToken = "",

  [ValidateSet("workstation", "server", "subnet-router")]
  [string]$Mode = "workstation",

  [string]$MsiUrl = $env:ENDLESSNET_MSI_URL,
  [string]$MsiSHA256Url = $env:ENDLESSNET_MSI_SHA256_URL,
  [string]$DownloadUrl = $env:ENDLESSNET_DOWNLOAD_URL,
  [string]$TrayDownloadUrl = $env:ENDLESSNET_TRAY_DOWNLOAD_URL,
  [string]$InstallDir = "$env:ProgramFiles\EndlessNet",
  [string]$StateDir = "$env:ProgramData\EndlessNet",
  [switch]$NoTray,
  [switch]$NoStart
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0

if ($MsiUrl.Trim() -eq "" -and $DownloadUrl.Trim() -eq "") {
  $MsiUrl = "https://endlessnet.ru/downloads/EndlessNet.Client.msi"
}
if ($MsiUrl.Trim() -ne "" -and $MsiSHA256Url.Trim() -eq "") {
  $MsiSHA256Url = "$MsiUrl.sha256"
}

function Assert-Admin {
  $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Administrator privileges are required to install EndlessNet Client"
  }
}

function New-RestrictedDirectory {
  param([Parameter(Mandatory = $true)][string]$Path)
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
  icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-32-544:(OI)(CI)(F)' | Out-Null
}

function Get-EndlessNetClient {
  param([Parameter(Mandatory = $true)][string]$InstallDir)
  $candidate = Join-Path $InstallDir "endlessnet-client.exe"
  if (Test-Path -LiteralPath $candidate) {
    return $candidate
  }
  $fromPath = Get-Command "endlessnet-client.exe" -ErrorAction SilentlyContinue
  if ($fromPath) {
    return $fromPath.Source
  }
  return $candidate
}

function Get-EndlessNetTray {
  param([Parameter(Mandatory = $true)][string]$InstallDir)
  $candidate = Join-Path $InstallDir "endlessnet-tray.exe"
  if (Test-Path -LiteralPath $candidate) {
    return $candidate
  }
  $fromPath = Get-Command "endlessnet-tray.exe" -ErrorAction SilentlyContinue
  if ($fromPath) {
    return $fromPath.Source
  }
  return $candidate
}

function Install-EndlessNetClient {
  param(
    [Parameter(Mandatory = $true)][string]$InstallDir,
    [string]$MsiUrl,
    [string]$MsiSHA256Url,
    [string]$DownloadUrl
  )
  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  $client = Get-EndlessNetClient -InstallDir $InstallDir
  $installMSI = $MsiUrl.Trim() -ne ""
  if (-not $installMSI -and (Test-Path -LiteralPath $client)) {
    return $client
  }

  $tmp = Join-Path $env:TEMP ("endlessnet-install-" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  try {
    if ($installMSI) {
      $msi = Join-Path $tmp "EndlessNet.Client.msi"
      $checksum = Join-Path $tmp "EndlessNet.Client.msi.sha256"
      Invoke-WebRequest -Uri $MsiUrl -OutFile $msi -UseBasicParsing
      Invoke-WebRequest -Uri $MsiSHA256Url -OutFile $checksum -UseBasicParsing
      $expectedHash = ((Get-Content -LiteralPath $checksum -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
      if ($expectedHash -notmatch '^[0-9a-f]{64}$') {
        throw "MSI checksum file does not contain a SHA-256 hash"
      }
      $actualHash = (Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash.ToLowerInvariant()
      if ($actualHash -ne $expectedHash) {
        throw "MSI checksum mismatch"
      }
      $process = Start-Process -FilePath "msiexec.exe" -ArgumentList @("/i", $msi, "/qn", "/norestart") -Wait -PassThru
      if ($process.ExitCode -ne 0) {
        throw "MSI install failed with exit code $($process.ExitCode)"
      }
    } elseif ($DownloadUrl.Trim() -ne "") {
      $download = Join-Path $tmp "endlessnet-client.exe"
      Invoke-WebRequest -Uri $DownloadUrl -OutFile $download -UseBasicParsing
      Copy-Item -LiteralPath $download -Destination $client -Force
    } else {
      $winget = Get-Command "winget.exe" -ErrorAction SilentlyContinue
      if (-not $winget) {
        throw "winget.exe is required when ENDLESSNET_MSI_URL or ENDLESSNET_DOWNLOAD_URL is not set"
      }
      & $winget.Source install --id EndlessNet.Client --exact --silent --accept-package-agreements --accept-source-agreements
      if ($LASTEXITCODE -ne 0) {
        throw "winget install EndlessNet.Client failed with exit code $LASTEXITCODE"
      }
    }
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }

  $client = Get-EndlessNetClient -InstallDir $InstallDir
  if (-not (Test-Path -LiteralPath $client)) {
    throw "endlessnet-client.exe was not installed at $client"
  }
  return $client
}

function Install-EndlessNetTray {
  param(
    [Parameter(Mandatory = $true)][string]$InstallDir,
    [string]$TrayDownloadUrl,
    [bool]$AllowPackageProvided
  )
  $tray = Get-EndlessNetTray -InstallDir $InstallDir
  if (Test-Path -LiteralPath $tray) {
    return $tray
  }
  if ($TrayDownloadUrl.Trim() -ne "") {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $tmp = Join-Path $env:TEMP ("endlessnet-tray-" + [Guid]::NewGuid().ToString("N") + ".exe")
    try {
      Invoke-WebRequest -Uri $TrayDownloadUrl -OutFile $tmp -UseBasicParsing
      Copy-Item -LiteralPath $tmp -Destination $tray -Force
    } finally {
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
  } elseif (-not $AllowPackageProvided) {
    throw "ENDLESSNET_TRAY_DOWNLOAD_URL is required when ENDLESSNET_DOWNLOAD_URL is used for a workstation install"
  }
  $tray = Get-EndlessNetTray -InstallDir $InstallDir
  if (-not (Test-Path -LiteralPath $tray)) {
    throw "endlessnet-tray.exe was not installed at $tray"
  }
  return $tray
}

function Install-VerifiedWintun {
  param([Parameter(Mandatory = $true)][string]$ClientPath)
  $target = Join-Path (Split-Path -Parent $ClientPath) "wintun.dll"
  if (-not (Test-Path -LiteralPath $target)) {
    $version = "0.14.1"
    $expectedHash = "07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51"
    $tmp = Join-Path $env:TEMP ("endlessnet-wintun-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
      $archive = Join-Path $tmp "wintun.zip"
      Invoke-WebRequest -Uri "https://www.wintun.net/builds/wintun-$version.zip" -OutFile $archive -UseBasicParsing
      $actualHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
      if ($actualHash -ne $expectedHash) {
        throw "Official Wintun archive SHA-256 mismatch"
      }
      Expand-Archive -LiteralPath $archive -DestinationPath $tmp -Force
      Copy-Item -LiteralPath (Join-Path $tmp "wintun\bin\amd64\wintun.dll") -Destination $target -Force
    } finally {
      Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  $signature = Get-AuthenticodeSignature -LiteralPath $target
  if ($signature.Status -ne "Valid") {
    throw "Official Wintun Authenticode verification failed: $($signature.Status)"
  }
  return $target
}

Assert-Admin

$Server = $Server.TrimEnd("/")
$config = Join-Path $StateDir "client.json"
$wgConfig = Join-Path $StateDir "endlessnet.conf"
$agentState = Join-Path $StateDir "agent-state.json"
$diagnostics = Join-Path $StateDir "Diagnostics"
$artifacts = Join-Path $StateDir "Service"
$ipcPipe = "\\.\pipe\endlessnet-service"
$installTray = -not $NoTray -and $Mode -eq "workstation"
$client = Install-EndlessNetClient -InstallDir $InstallDir -MsiUrl $MsiUrl -MsiSHA256Url $MsiSHA256Url -DownloadUrl $DownloadUrl
$null = Install-VerifiedWintun -ClientPath $client
$tray = Get-EndlessNetTray -InstallDir $InstallDir
if ($installTray) {
  $packageInstall = $MsiUrl.Trim() -ne "" -or $DownloadUrl.Trim() -eq ""
  $tray = Install-EndlessNetTray -InstallDir $InstallDir -TrayDownloadUrl $TrayDownloadUrl -AllowPackageProvided $packageInstall
}

New-RestrictedDirectory -Path $StateDir
New-RestrictedDirectory -Path $diagnostics
New-Item -ItemType Directory -Force -Path $artifacts | Out-Null

$start = -not $NoStart
$hasEnrollToken = $EnrollToken.Trim() -ne ""
if ($hasEnrollToken -and -not $start) {
  throw "NoStart cannot be used with EnrollToken because service IPC enrollment requires the service to run"
}
$installStart = $start

& $client service render-windows `
  --output-dir $artifacts `
  --binary $client `
  --tray $tray `
  --config $config `
  --wg-config $wgConfig `
  --state $agentState `
  --diagnostics-dir $diagnostics `
  --ipc-pipe $ipcPipe `
  --install-tray=$installTray `
  --start=$installStart
if ($LASTEXITCODE -ne 0) {
  throw "failed to render EndlessNet Windows service artifacts"
}

$serviceInstall = Join-Path $artifacts "endlessnet-client-install.ps1"
& $serviceInstall

if ($hasEnrollToken) {
  try {
    $idempotencyKey = [Guid]::NewGuid().ToString("N")
    $EnrollToken | & $client service enroll `
      --ipc-pipe $ipcPipe `
      --server $Server `
      --join-token-file - `
      --mode $Mode `
      --idempotency-key $idempotencyKey | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "EndlessNet enrollment failed"
    }
  } finally {
    $EnrollToken = ""
  }
}

if ($start -and -not $hasEnrollToken) {
  $service = Get-Service -Name "endlessnet-client" -ErrorAction Stop
  if ($service.Status -eq "Running") {
    Restart-Service -Name "endlessnet-client" -ErrorAction Stop
  } else {
    Start-Service -Name "endlessnet-client" -ErrorAction Stop
  }
}

Write-Host "EndlessNet Client installed"
