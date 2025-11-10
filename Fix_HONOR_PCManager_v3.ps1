# === Fix_HONOR_PCManager_v3.ps1 (Windows PowerShell 5.1) ===
# Создаём рабочие папки и логирование
$proj = Join-Path $env:USERPROFILE 'Desktop\HONOR_PCManager'
if (-not (Test-Path $proj)) { New-Item -ItemType Directory -Force -Path $proj | Out-Null }
Set-Location $proj
$logs = Join-Path $proj 'Logs'
$inst = Join-Path $proj 'Installers'
$bak  = Join-Path $proj 'Backups'
foreach ($dir in @($logs, $inst, $bak)) {
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
}

function WL {
  param([string]$Message)
  $ts = (Get-Date).ToString('s')
  $line = "$ts $Message"
  Write-Host $line
  Add-Content -Encoding UTF8 -Path (Join-Path $logs 'toolbox.log') -Value $line
}

# === Службы ===
function Ensure-ServiceRunning {
  param([string]$Name)
  $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
  if (-not $service) { WL "Service not found: $Name"; return }

  try {
    Set-Service -Name $Name -StartupType Automatic -ErrorAction Stop
    WL "Startup=Automatic: $Name"
  } catch {
    WL "Ошибка StartupType $Name: $($_.Exception.Message)"
  }

  if ($service.Status -ne 'Running') {
    try {
      Start-Service -Name $Name -ErrorAction Stop
      WL "Started service: $Name"
    } catch {
      WL "Ошибка старта $Name: $($_.Exception.Message)"
    }
  }
}

# === WebView2 ===
function Get-WebView2Version {
  # Сначала ищем в реестре
  $registryRoots = @(
    'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients'
  )

  foreach ($root in $registryRoots) {
    if (Test-Path $root) {
      foreach ($key in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
        $prop = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
        if ($prop -and $prop.name -and ($prop.name -like '*WebView2 Runtime*') -and $prop.pv) {
          return $prop.pv
        }
      }
    }
  }

  # Фоллбэк: ищем каталоги с версией
  $dirRoots = @()
  $pf86 = ${env:ProgramFiles(x86)}
  if ($pf86) {
    $dirRoots += Join-Path $pf86 'Microsoft\EdgeWebView\Application'
  }
  $pf = $env:ProgramFiles
  if ($pf) {
    $dirRoots += Join-Path $pf 'Microsoft\EdgeWebView\Application'
  }
  $dirRoots = $dirRoots | Where-Object { Test-Path $_ }

  $versions = @()
  foreach ($root in $dirRoots) {
    foreach ($dir in (Get-ChildItem $root -Directory -ErrorAction SilentlyContinue)) {
      if ($dir.Name -match '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$') {
        $versions += $dir.Name
      }
    }
  }

  if ($versions.Count -gt 0) {
    return ($versions | Sort-Object {[version]$_} -Descending | Select-Object -First 1)
  }

  return $null
}

function SilentInstall {
  param([string]$FilePath)
  if (-not (Test-Path $FilePath)) { WL "Installer not found: $FilePath"; return $false }

  WL "Run installer: $FilePath /silent /install"
  try {
    $proc = Start-Process -FilePath $FilePath -ArgumentList '/silent','/install' -PassThru -Wait -ErrorAction Stop
    WL "Installer exit code: $($proc.ExitCode)"
    return $true
  } catch {
    WL "Ошибка запуска инсталлятора: $($_.Exception.Message)"
    return $false
  }
}

# === Поиск PC Manager ===
function Find-PCManager {
  $candidates = @()
  $pf = $env:ProgramFiles
  if ($pf) {
    $candidates += Join-Path $pf 'HONOR\PCManager'
    $candidates += Join-Path $pf 'HONOR\HONOR PC Manager'
  }
  $pf86 = ${env:ProgramFiles(x86)}
  if ($pf86) {
    $candidates += Join-Path $pf86 'HONOR\PCManager'
    $candidates += Join-Path $pf86 'HONOR\HONOR PC Manager'
  }

  $installDir = $null
  foreach ($path in $candidates) {
    if (-not $installDir -and (Test-Path $path)) {
      $installDir = $path
    }
  }

  if (-not $installDir) { return @($null, $null) }

  $exeMain = Join-Path $installDir 'PCManager.exe'
  if (Test-Path $exeMain) { return @($installDir, $exeMain) }

  $exeAny = Get-ChildItem -Path $installDir -Filter '*Manager*.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($exeAny) { return @($installDir, $exeAny.FullName) }

  return @($installDir, $null)
}

function TryStart {
  param([string]$Executable)
  WL "Start: $Executable"
  try {
    $proc = Start-Process -FilePath $Executable -PassThru -ErrorAction Stop
    Start-Sleep -Seconds 8
    $alive = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
    if ($alive) {
      WL 'Running OK'
      return $true
    }
    WL 'Exited early'
    return $false
  } catch {
    WL "Ошибка старта: $($_.Exception.Message)"
    return $false
  }
}

function Isolate {
  param([string]$Path)
  if (-not (Test-Path $Path)) { return $false }
  $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
  $destination = Join-Path $bak ((Split-Path $Path -Leaf) + ".$stamp.off")
  try {
    Move-Item -Path $Path -Destination $destination -Force
    WL "Isolated: $Path -> $destination"
    return $true
  } catch {
    WL "Ошибка изоляции: $($_.Exception.Message)"
    return $false
  }
}

function CollectEvents {
  $eventsTxt = Join-Path $logs 'pcmanager_events.txt'
  $from = (Get-Date).AddMinutes(-20)
  $lines = @()

  try {
    $events = Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=$from} -ErrorAction Stop
    foreach ($event in $events) {
      $matched = $false
      if ($event.ProviderName -match 'Application Error|\.NET Runtime|Windows Error Reporting') {
        $matched = $true
      } else {
        $message = ''
        try { $message = $event.Message } catch { $message = '<message unavailable>' }
        if ($message -match 'PC Manager|PCManager|MBAMainService|LCD_Service|EdgeWebView2') { $matched = $true }
      }

      if ($matched) {
        $message = ''
        try { $message = $event.Message } catch { $message = '<message unavailable>' }
        $lines += @(
          'TimeCreated      : ' + $event.TimeCreated.ToString('s'),
          'Id               : ' + $event.Id,
          'LevelDisplayName : ' + $event.LevelDisplayName,
          'ProviderName     : ' + $event.ProviderName,
          'Message          : ' + $message,
          ''
        )
      }
    }

    if ($lines.Count -gt 0) {
      $lines -join "`r`n" | Set-Content -Encoding UTF8 -Path $eventsTxt
      WL "Events saved (WinEvent): $eventsTxt"
      return
    }

    WL 'Events (WinEvent): nothing matched'
  } catch {
    WL "Get-WinEvent failed: $($_.Exception.Message)"
  }

  try {
    $eventsLegacy = Get-EventLog -LogName Application -After $from -ErrorAction Stop
    foreach ($event in $eventsLegacy) {
      $matched = $false
      if ($event.Source -match 'Application Error|\.NET Runtime|Windows Error Reporting') {
        $matched = $true
      } elseif ($event.Message -match 'PC Manager|PCManager|MBAMainService|LCD_Service|EdgeWebView2') {
        $matched = $true
      }

      if ($matched) {
        $lines += @(
          'TimeCreated      : ' + $event.TimeGenerated.ToString('s'),
          'Id               : ' + $event.EventID,
          'LevelDisplayName : ' + $event.EntryType,
          'ProviderName     : ' + $event.Source,
          'Message          : ' + $event.Message,
          ''
        )
      }
    }

    $lines -join "`r`n" | Set-Content -Encoding UTF8 -Path $eventsTxt
    WL "Events saved (EventLog): $eventsTxt"
  } catch {
    WL "Fallback Get-EventLog failed: $($_.Exception.Message)"
  }
}

WL '=== Step 1: services ==='
Ensure-ServiceRunning -Name 'seclogon'
Ensure-ServiceRunning -Name 'MBAMainService'
Ensure-ServiceRunning -Name 'LCD_Service'

WL '=== Step 2: WebView2 ==='
$wvBefore = Get-WebView2Version
if ($wvBefore) { WL "WebView2 present: $wvBefore" } else { WL 'WebView2 not found' }
$wvInstaller = Get-ChildItem -Path $inst -Filter 'MicrosoftEdgeWebView2*.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
if ($wvInstaller) {
  [void](SilentInstall -FilePath $wvInstaller.FullName)
} else {
  WL 'No WebView2 installer in Installers'
}
$wvAfter = Get-WebView2Version
if ($wvAfter) { WL "WebView2 after attempt: $wvAfter" } else { WL 'WebView2 after attempt: not installed' }

WL '=== Step 3: launch PCManager.exe ==='
$pcInfo = Find-PCManager
$installDir = $pcInfo[0]
$executable = $pcInfo[1]
$started = $false
if ($executable) { $started = TryStart -Executable $executable } else { WL 'PC Manager path not found' }

if (-not $started -and $installDir) {
  $oobe = Join-Path $installDir 'OobePCManager.exe'
  if (Test-Path $oobe) {
    if (Isolate -Path $oobe) {
      $started = TryStart -Executable (Join-Path $installDir 'PCManager.exe')
    }
  }
}

if (-not $started -and $installDir) {
  foreach ($name in @('SystemApi.dll','MonitorManageStart.exe')) {
    $candidate = Join-Path $installDir $name
    if (Test-Path $candidate) {
      if (Isolate -Path $candidate) {
        $started = TryStart -Executable (Join-Path $installDir 'PCManager.exe')
        if ($started) { break }
      }
    }
  }
}

CollectEvents

"Готово. Проверяй PC Manager. Логи: " + (Join-Path $logs 'toolbox.log')
