@echo off
title PC Optimizer
setlocal

REM --- Verifica permisos de administrador; si el usuario cancela el UAC, avisa y no abre nada ---
net session >nul 2>&1
if %errorLevel% NEQ 0 (
    powershell -NoProfile -Command "try { Start-Process -FilePath '%~f0' -Verb RunAs -ErrorAction Stop } catch { Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show('PC Optimizer necesita permisos de Administrador para abrirse. No se otorgaron los permisos, asi que no se va a iniciar.', 'PC Optimizer - Permisos requeridos', 'OK', 'Warning') | Out-Null }"
    exit /b
)

REM --- Este mismo archivo .bat trae el codigo de PowerShell incrustado despues del ---
REM --- marcador de mas abajo. Lo extraemos a un .ps1 temporal (forzando UTF-8 con  ---
REM --- BOM para que los emojis/acentos se vean bien) y lo ejecutamos.              ---
set "PSTEMP=%TEMP%\PCOptimizer_%RANDOM%.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$raw = [IO.File]::ReadAllText('%~f0'); $idx = $raw.LastIndexOf('#---PCOPTIMIZER-PS1-CODE-BELOW---#'); $code = $raw.Substring($idx + '#---PCOPTIMIZER-PS1-CODE-BELOW---#'.Length).TrimStart([char]0xFEFF); [IO.File]::WriteAllText('%PSTEMP%', $code, [System.Text.Encoding]::UTF8)"

REM --- Ejecuta el script extraido con la interfaz grafica ---
powershell -NoProfile -ExecutionPolicy Bypass -File "%PSTEMP%"
set "RC=%errorLevel%"

REM --- Limpieza del archivo temporal ---
del "%PSTEMP%" >nul 2>&1

if %RC% NEQ 0 (
    echo.
    echo ============================================
    echo  Ocurrio un error. Revisa el mensaje de arriba.
    echo ============================================
    pause
)
exit /b

#---PCOPTIMIZER-PS1-CODE-BELOW---#
#Requires -Version 5.1
<#
.SYNOPSIS
    PC Optimizer v3.5.4 [VERSION PERSONAL SIN PIN] - Debloat, Tweaks & App Installer (estilo Chris Titus WinUtil)
.DESCRIPTION
    Herramienta con interfaz grafica (WPF) para:
      - Eliminar aplicaciones preinstaladas (bloatware)
      - Aplicar tweaks de rendimiento y privacidad (Estandar y Avanzados)
      - Revertir tweaks aplicados
      - Instalar apps comunes via winget
      - Monitorear y liberar RAM (working sets, standby list, pagefile)
    Crea un punto de restauracion antes de aplicar cambios.
.NOTES
    Ejecutar como Administrador. Los tweaks "Avanzados" estan marcados como
    tal a proposito: no son para todo el mundo, leelos antes de aplicarlos.
#>

# Version de la app (se usa en el titulo de la ventana, el encabezado y el log)
$AppVersion = "3.5.4"

# ---------------------------------------------------------------
# 0. Verificar que se ejecuta como Administrador (obligatorio)
# ---------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    [System.Windows.Forms.MessageBox]::Show(
        "PC Optimizer necesita permisos de Administrador para funcionar.`n`nAl aceptar este aviso, Windows te va a pedir confirmacion (UAC) para reabrirlo con esos permisos. Si la cancelas, el programa no va a abrirse.",
        "PC Optimizer - Permisos requeridos",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null

    try {
        Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs -ErrorAction Stop
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "No se otorgaron permisos de Administrador. PC Optimizer no puede abrirse sin ellos.",
            "PC Optimizer - Acceso denegado",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    exit
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# ---------------------------------------------------------------
# 0a1. Marcar el proceso como DPI-aware para que Windows no escale
#      la ventana como si fuera una imagen (eso es lo que se ve borroso
#      en resoluciones como 1280x960). Con esto WPF dibuja nitido siempre.
# ---------------------------------------------------------------
try {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class DpiHelper {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("shcore.dll")]
    public static extern int SetProcessDpiAwareness(int value);
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
}
"@ -ErrorAction Stop

    # Intenta primero el metodo mas moderno (Windows 10 1703+), despues va bajando
    $DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = [IntPtr]::new(-4)
    if (-not [DpiHelper]::SetProcessDpiAwarenessContext($DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)) {
        try { [DpiHelper]::SetProcessDpiAwareness(2) | Out-Null } # Windows 8.1+
        catch { [DpiHelper]::SetProcessDPIAware() | Out-Null }    # Windows Vista+
    }
} catch {
    # Si algo de esto falla no es grave, el programa sigue funcionando igual
}

# ---------------------------------------------------------------
# 0a. VERSION PERSONAL: sin pantalla de PIN (uso propio, no distribuir)
# ---------------------------------------------------------------

# ---------------------------------------------------------------
# 0b. API nativa de Windows para el optimizador de RAM
#     (las mismas funciones que usan herramientas como RAMMap)
# ---------------------------------------------------------------
$memApiSource = @"
using System;
using System.Runtime.InteropServices;

public static class MemOptimizer
{
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetProcessWorkingSetSize(IntPtr hProcess, int dwMinimumWorkingSetSize, int dwMaximumWorkingSetSize);

    [DllImport("ntdll.dll")]
    public static extern int NtSetSystemInformation(int SystemInformationClass, IntPtr SystemInformation, int SystemInformationLength);

    // Vacia la Standby List del sistema (equivalente a "Empty Standby List")
    public static int PurgeStandbyList()
    {
        // SystemMemoryListInformation = 80, MemoryPurgeStandbyList = 4
        int command = 4;
        IntPtr ptr = Marshal.AllocHGlobal(4);
        Marshal.WriteInt32(ptr, command);
        int result = NtSetSystemInformation(80, ptr, 4);
        Marshal.FreeHGlobal(ptr);
        return result;
    }
}
"@
try {
    Add-Type -TypeDefinition $memApiSource -Language CSharp -ErrorAction Stop
} catch {
    [System.Windows.Forms.MessageBox]::Show(
        "No se pudo preparar el modulo de RAM (esto no afecta Debloat/Tweaks/Disco):`n`n$($_.Exception.Message)",
        "PC Optimizer - Aviso",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
}

function Get-RamInfo {
    $os = Get-CimInstance Win32_OperatingSystem
    $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
    $freeGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
    $usedGB  = [math]::Round($totalGB - $freeGB, 2)
    $percent = [math]::Round((($totalGB - $freeGB) / $totalGB) * 100, 0)
    [PSCustomObject]@{ TotalGB = $totalGB; UsedGB = $usedGB; FreeGB = $freeGB; PercentUsed = $percent }
}

$script:CpuName = $null
function Get-CpuUsage {
    try {
        $v = (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop).PercentProcessorTime
        return [math]::Round($v, 0)
    } catch {
        return $null
    }
}

$script:GpuName = $null
function Get-GpuUsage {
    try {
        $samples = (Get-Counter '\GPU Engine(*engtype_3D)\Utilization Percentage' -ErrorAction Stop).CounterSamples
        $total = ($samples | Measure-Object -Property CookedValue -Sum).Sum
        if ($total -gt 100) { $total = 100 }
        return [math]::Round($total, 0)
    } catch {
        return $null
    }
}

function Invoke-EmptyWorkingSets {
    param([switch]$Aggressive)
    $freed = 0
    $skip = @("Idle","System","Registry","MemCompression","csrss","wininit","winlogon","smss")
    foreach ($proc in Get-Process -ErrorAction SilentlyContinue) {
        if ($skip -contains $proc.ProcessName) { continue }
        if (-not $Aggressive -and $proc.Id -eq $PID) { continue }
        try {
            [void][MemOptimizer]::SetProcessWorkingSetSize($proc.Handle, -1, -1)
            $freed++
        } catch { }
    }
    return $freed
}

function Get-DrivesInfo {
    Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
        $totalGB = [math]::Round($_.Size / 1GB, 1)
        $freeGB  = [math]::Round($_.FreeSpace / 1GB, 1)
        $usedGB  = [math]::Round($totalGB - $freeGB, 1)
        $percent = if ($totalGB -gt 0) { [math]::Round(($usedGB / $totalGB) * 100, 0) } else { 0 }
        [PSCustomObject]@{
            Letter = $_.DeviceID; TotalGB = $totalGB; UsedGB = $usedGB; FreeGB = $freeGB; PercentUsed = $percent
        }
    }
}

function Get-FolderSizeGB {
    param([string]$Path, [string]$FilePattern = $null)
    if (-not (Test-Path $Path)) { return 0 }
    try {
        if ($FilePattern) {
            $items = Get-ChildItem -Path $Path -Filter $FilePattern -Force -File -Recurse -ErrorAction SilentlyContinue
        } else {
            $items = Get-ChildItem -Path $Path -Force -File -Recurse -ErrorAction SilentlyContinue
        }
        $sum = ($items | Measure-Object -Property Length -Sum).Sum
        if (-not $sum) { return 0 }
        return [math]::Round($sum / 1GB, 3)
    } catch { return 0 }
}

function Wait-ProcWithLog {
    # Espera a que termine un proceso y avisa en el registro que sigue trabajando, para que no parezca colgado.
    param($Proc, [string]$Label, [int]$MaxMinutes = 180)
    $first = if ($script:BeatFirst) { $script:BeatFirst } else { 30 }
    $every = if ($script:BeatEvery) { $script:BeatEvery } else { 60 }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $next = $first
    while (-not $Proc.HasExited) {
        Start-Sleep -Milliseconds 500
        if ($sw.Elapsed.TotalSeconds -ge $next) {
            Write-Log ("    ... {0} sigue trabajando ({1} min {2} s). Es normal: Windows.old tiene muchisimos archivos." -f $Label, [math]::Floor($sw.Elapsed.TotalMinutes), ($sw.Elapsed.Seconds))
            $next += $every
        }
        if ($sw.Elapsed.TotalMinutes -ge $MaxMinutes) {
            Write-Log "    ... demasiado tiempo, se corta $Label."
            try { $Proc.Kill() } catch { }
            return $false
        }
    }
    return $true
}

function Get-WindowsOldSizeGB {
    # Mide Windows.old con robocopy en modo lista (/L): no copia nada y recorre mucho mas rapido que Get-ChildItem.
    $path = "C:\Windows.old"
    if (-not (Test-Path $path)) { return 0 }
    $log = Join-Path $env:TEMP "pcopt_winold_scan.log"
    try {
        Remove-Item $log -Force -ErrorAction SilentlyContinue
        $args = @("`"$path`"", "`"$env:TEMP\pcopt_vacio`"", "/L", "/E", "/B", "/XJ", "/R:0", "/W:0", "/NFL", "/NDL", "/NJH", "/NP", "/BYTES", "/LOG:`"$log`"")
        $p = Start-Process -FilePath "robocopy.exe" -ArgumentList $args -WindowStyle Hidden -PassThru
        if (-not (Wait-ProcWithLog -Proc $p -Label "la medicion" -MaxMinutes 30)) { throw "tiempo agotado" }
        $txt = Get-Content -Path $log -Raw -ErrorAction Stop
        if ($txt -match '(?im)^\s*Bytes\s*:\s*(\d+)') { return [math]::Round([double]$Matches[1] / 1GB, 3) }
    } catch { }
    finally { Remove-Item $log -Force -ErrorAction SilentlyContinue }
    return (Get-FolderSizeGB -Path $path)   # plan B si robocopy no esta o no se pudo leer
}

function Get-OldGpuDriverPackages {
    # Devuelve los paquetes de driver de video de NVIDIA/AMD guardados en Windows que NO son
    # los que usa la placa ahora ni la version mas nueva de cada fabricante.
    $displayGuid = "{4d36e968-e325-11cf-bfc1-08002be10318}"
    $all = @(Get-WindowsDriver -Online -ErrorAction Stop | Where-Object {
        $_.ClassGuid -eq $displayGuid -and -not $_.Inbox -and ($_.ProviderName -match "NVIDIA|Advanced Micro Devices|AMD")
    })
    if ($all.Count -eq 0) { return @() }
    $inUse = @(Get-CimInstance Win32_PnPSignedDriver -Filter "DeviceClass='DISPLAY'" -ErrorAction SilentlyContinue |
        ForEach-Object { $_.InfName } | Where-Object { $_ })
    $keep = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
    foreach ($inf in $inUse) { [void]$keep.Add($inf) }
    # De cada fabricante tambien se conserva la version mas nueva
    foreach ($g in ($all | Group-Object { if ($_.ProviderName -match "NVIDIA") { "NVIDIA" } else { "AMD" } })) {
        $newest = $g.Group | Sort-Object @{ Expression = { $_.Date } }, @{ Expression = { $_.Version } } -Descending | Select-Object -First 1
        [void]$keep.Add($newest.Driver)
    }
    $result = New-Object System.Collections.ArrayList
    foreach ($d in $all) {
        if ($keep.Contains($d.Driver)) { continue }
        $folder = Split-Path $d.OriginalFileName -Parent
        [void]$result.Add([pscustomobject]@{
            Inf = $d.Driver; Provider = $d.ProviderName; Version = "$($d.Version)"; Date = $d.Date
            Folder = $folder; SizeGB = (Get-FolderSizeGB -Path $folder)
        })
    }
    return @($result)
}

function Remove-CleanupCategory {
    param([string]$Name, [hashtable]$Def, [string[]]$Packages)
    # Los errores de borrado (archivos en uso o protegidos) NO deben mostrarse como
    # carteles: se ignoran y solo se informa el resultado en el log.
    $ErrorActionPreference = "SilentlyContinue"
    $ProgressPreference    = "SilentlyContinue"
    if ($Def.Special -eq "WindowsOld") {
        if (-not (Test-Path "C:\Windows.old")) { Write-Log "  (no existe C:\Windows.old, se salta)"; return }
        Write-Log "  Windows.old puede tardar MUCHOS minutos (tiene cientos de miles de archivos). No esta trabado: te aviso cada tanto."
        # Metodo 1 (el mas rapido y seguro): la limpieza propia de Windows, la misma de "Liberador de espacio"
        $vc = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Previous Installations"
        if (Test-Path $vc) {
            Write-Log "  Usando la limpieza de Windows (Liberador de espacio, instalaciones anteriores). Puede abrirse una ventana de progreso."
            try {
                Set-ItemProperty -Path $vc -Name "StateFlags7741" -Value 2 -Type DWord -Force
                $p = Start-Process -FilePath "cleanmgr.exe" -ArgumentList "/sagerun:7741" -PassThru
                [void](Wait-ProcWithLog -Proc $p -Label "el Liberador de espacio")
                # Si dejo procesos hijos, se espera un poco a que terminen antes de seguir
                $t = [System.Diagnostics.Stopwatch]::StartNew()
                while ((Get-Process -Name "cleanmgr" -ErrorAction SilentlyContinue) -and $t.Elapsed.TotalMinutes -lt 10) { Start-Sleep -Seconds 2 }
            } catch { Write-Log "  No se pudo usar el Liberador de espacio: $($_.Exception.Message)" }
            finally { Remove-ItemProperty -Path $vc -Name "StateFlags7741" -ErrorAction SilentlyContinue }
            if (-not (Test-Path "C:\Windows.old")) { Write-Log "  Windows.old eliminado."; return }
            Write-Log "  El Liberador no pudo quitarlo todo; sigo con el metodo manual..."
        }
        # Metodo 2 (manual): tomar propiedad, dar permisos y borrar con rd (mucho mas rapido que Remove-Item)
        try {
            Write-Log "  Manual 1/3: tomando propiedad de los archivos (es la parte mas lenta)..."
            $p = Start-Process -FilePath "takeown.exe" -ArgumentList "/F","C:\Windows.old","/R","/A","/D","Y" -WindowStyle Hidden -PassThru
            if (-not (Wait-ProcWithLog -Proc $p -Label "takeown")) { return }
            Write-Log "  Manual 2/3: dando permisos de administrador..."
            $p = Start-Process -FilePath "icacls.exe" -ArgumentList "C:\Windows.old","/grant","*S-1-5-32-544:(OI)(CI)F","/T","/C","/Q" -WindowStyle Hidden -PassThru
            if (-not (Wait-ProcWithLog -Proc $p -Label "icacls")) { return }
            Write-Log "  Manual 3/3: borrando archivos..."
            $p = Start-Process -FilePath "cmd.exe" -ArgumentList "/c","rd /s /q C:\Windows.old" -WindowStyle Hidden -PassThru
            if (-not (Wait-ProcWithLog -Proc $p -Label "el borrado")) { return }
        } catch { Write-Log "  Error en el metodo manual: $($_.Exception.Message)" }
        if (Test-Path "C:\Windows.old") {
            Write-Log "  No se pudo quitar todo Windows.old (algunos archivos estan protegidos). Probalo desde Configuracion > Sistema > Almacenamiento > Archivos temporales."
        } else { Write-Log "  Windows.old eliminado." }
        return
    }
    if ($Def.Special -eq "OldGpuDrivers") {
        if (-not $Packages -or $Packages.Count -eq 0) { Write-Log "  No hay versiones viejas de drivers para quitar."; return }
        # Se vuelve a comprobar que ninguno este en uso justo antes de borrar
        $inUse = @(Get-CimInstance Win32_PnPSignedDriver -Filter "DeviceClass='DISPLAY'" -ErrorAction SilentlyContinue | ForEach-Object { $_.InfName })
        foreach ($inf in $Packages) {
            if ($inf -notmatch '^oem\d+\.inf$') { Write-Log "  Se omite un nombre no valido: $inf"; continue }
            if ($inUse -contains $inf) { Write-Log "  $inf lo esta usando la placa, se omite."; continue }
            Write-Log "  Quitando $inf del almacen de drivers..."
            # Sin /force: si Windows considera que el paquete esta en uso, lo rechaza y no se toca
            [void](& pnputil.exe /delete-driver $inf 2>&1)
            if ($LASTEXITCODE -eq 0) { Write-Log "    -> quitado." }
            else { Write-Log "    -> Windows no lo quito (en uso o protegido); queda como esta." }
        }
        return
    }
    foreach ($path in $Def.Paths) {
        if (-not (Test-Path $path)) { Write-Log "  (no existe: $path, se salta)"; continue }
        Write-Log "  Borrando contenido de: $path"
        try {
            if ($Def.FilePattern) {
                $items = Get-ChildItem -Path $path -Filter $Def.FilePattern -Force -File -Recurse -ErrorAction SilentlyContinue 2>$null
                $count = ($items | Measure-Object).Count
                $items | Remove-Item -Force -ErrorAction SilentlyContinue 2>$null
                Write-Log "    -> $count archivo(s) procesados."
            } else {
                $items = Get-ChildItem -Path $path -Force -Recurse -ErrorAction SilentlyContinue 2>$null
                $count = ($items | Measure-Object).Count
                $items | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue 2>$null
                Write-Log "    -> $count elemento(s) procesados (los que estaban en uso se omiten)."
            }
        } catch { Write-Log "    Error borrando $path : $($_.Exception.Message)" }
    }
    if ($Def.RestartExplorer) {
        Write-Log "  Reiniciando Explorer.exe para liberar el cache..."
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 800
        Start-Process explorer.exe
    }
}

# ---------------------------------------------------------------
# 1. BLOATWARE - paquetes AppX agrupados por categoria
# ---------------------------------------------------------------
$BloatwareList = [ordered]@{
    "Xbox (App, Game Bar, Overlay)" = @(
        "Microsoft.XboxApp","Microsoft.XboxGameOverlay","Microsoft.XboxGamingOverlay",
        "Microsoft.XboxIdentityProvider","Microsoft.XboxSpeechToTextOverlay","Microsoft.Xbox.TCUI",
        "Microsoft.GamingApp"
    )
    "Bing (Noticias, Clima, Finanzas, Deportes)" = @(
        "Microsoft.BingNews","Microsoft.BingWeather","Microsoft.BingFinance","Microsoft.BingSports","Microsoft.BingTranslator"
    )
    "Juegos preinstalados" = @(
        "Microsoft.MicrosoftSolitaireCollection","Microsoft.CandyCrushSaga","king.com.CandyCrushSaga",
        "king.com.*","Microsoft.MahjongforWindows"
    )
    "Apps de terceros (patrocinadas)" = @(
        "Facebook.Facebook","*Disney*","*Spotify*","*TikTok*","*Instagram*","*Twitter*","*AmazonVideo*"
    )
    "Skype / Teams (consumer)" = @( "Microsoft.SkypeApp","MicrosoftTeams" )
    "Office Hub / OneNote UWP" = @( "Microsoft.MicrosoftOfficeHub","Microsoft.Office.OneNote" )
    "Correo y Calendario (UWP)" = @( "microsoft.windowscommunicationsapps" )
    "3D Builder / Paint 3D / Mixed Reality" = @(
        "Microsoft.3DBuilder","Microsoft.MSPaint","Microsoft.Print3D","Microsoft.MixedReality.Portal"
    )
    "Utilidades poco usadas" = @(
        "Microsoft.GetHelp","Microsoft.Getstarted","Microsoft.Messaging","Microsoft.Microsoft3DViewer",
        "Microsoft.MicrosoftStickyNotes","Microsoft.People","Microsoft.WindowsAlarms",
        "Microsoft.WindowsFeedbackHub","Microsoft.WindowsMaps","Microsoft.YourPhone",
        "Microsoft.ZuneMusic","Microsoft.ZuneVideo","Microsoft.Todos","Clipchamp.Clipchamp",
        "Microsoft.PowerAutomateDesktop","MicrosoftCorporationII.MicrosoftFamily"
    )
    "Cortana" = @( "Microsoft.549981C3F5F10" )
    "Widgets / News and Interests" = @( "MicrosoftWindows.Client.WebExperience" )
    "OneDrive (desinstalar completo)" = @()
}

# ---------------------------------------------------------------
# 2. TWEAKS ESTANDAR - seguros y reversibles (con Invoke + Undo)
# ---------------------------------------------------------------
$StandardTweaks = [ordered]@{

    "Deshabilitar Telemetria" = @{
        Status = { (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowTelemetry" -ErrorAction SilentlyContinue).AllowTelemetry -eq 0 }
        Invoke = {
            New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Force | Out-Null
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowTelemetry" -Value 0 -Type DWord -Force
            Stop-Service -Name "DiagTrack" -Force -ErrorAction SilentlyContinue
            Set-Service -Name "DiagTrack" -StartupType Disabled -ErrorAction SilentlyContinue
        }
        Undo = {
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowTelemetry" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-Service -Name "DiagTrack" -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service -Name "DiagTrack" -ErrorAction SilentlyContinue
        }
    }

    "Deshabilitar Cortana" = @{
        Status = { (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "AllowCortana" -ErrorAction SilentlyContinue).AllowCortana -eq 0 }
        Invoke = {
            New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Force | Out-Null
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "AllowCortana" -Value 0 -Type DWord -Force
        }
        Undo = {
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "AllowCortana" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        }
    }

    "Quitar Bing del buscador de Inicio" = @{
        Status = { (Get-ItemProperty -Path "HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer" -Name "DisableSearchBoxSuggestions" -ErrorAction SilentlyContinue).DisableSearchBoxSuggestions -eq 1 }
        Invoke = {
            New-Item -Path "HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer" -Force | Out-Null
            Set-ItemProperty -Path "HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer" -Name "DisableSearchBoxSuggestions" -Value 1 -Type DWord -Force
        }
        Undo = {
            Set-ItemProperty -Path "HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer" -Name "DisableSearchBoxSuggestions" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        }
    }

    "Quitar sugerencias y anuncios del menu Inicio" = @{
        Status = { (Get-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "SubscribedContent-338388Enabled" -ErrorAction SilentlyContinue).'SubscribedContent-338388Enabled' -eq 0 }
        Invoke = {
            $path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
            Set-ItemProperty -Path $path -Name "SubscribedContent-338388Enabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $path -Name "SilentInstalledAppsEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $path -Name "SystemPaneSuggestionsEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $path -Name "OemPreInstalledAppsEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        }
        Undo = {
            $path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
            Set-ItemProperty -Path $path -Name "SubscribedContent-338388Enabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $path -Name "SilentInstalledAppsEnabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $path -Name "SystemPaneSuggestionsEnabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        }
    }

    "Desactivar instalacion automatica de apps (Consumer Features)" = @{
        Status = { (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableWindowsConsumerFeatures" -ErrorAction SilentlyContinue).DisableWindowsConsumerFeatures -eq 1 }
        Invoke = {
            New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Force | Out-Null
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableWindowsConsumerFeatures" -Value 1 -Type DWord -Force
        }
        Undo = {
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableWindowsConsumerFeatures" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        }
    }

    "Desactivar apps en segundo plano" = @{
        Status = { (Get-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" -Name "GlobalUserDisabled" -ErrorAction SilentlyContinue).GlobalUserDisabled -eq 1 }
        Invoke = {
            Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" -Name "GlobalUserDisabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        }
        Undo = {
            Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" -Name "GlobalUserDisabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        }
    }

    "Desactivar historial de actividades (Activity History)" = @{
        Status = { (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "EnableActivityFeed" -ErrorAction SilentlyContinue).EnableActivityFeed -eq 0 }
        Invoke = {
            New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Force | Out-Null
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "EnableActivityFeed" -Value 0 -Type DWord -Force
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "PublishUserActivities" -Value 0 -Type DWord -Force
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "UploadUserActivities" -Value 0 -Type DWord -Force
        }
        Undo = {
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "EnableActivityFeed" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "PublishUserActivities" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "UploadUserActivities" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        }
    }

    "Desactivar ID de publicidad" = @{
        Status = { (Get-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Name "Enabled" -ErrorAction SilentlyContinue).Enabled -eq 0 }
        Invoke = {
            New-Item -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Force | Out-Null
            Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Name "Enabled" -Value 0 -Type DWord -Force
        }
        Undo = {
            Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Name "Enabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        }
    }

    "Ocultar Widgets de la barra de tareas" = @{
        Status = { (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -Name "AllowNewsAndInterests" -ErrorAction SilentlyContinue).AllowNewsAndInterests -eq 0 }
        Invoke = {
            New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -Force | Out-Null
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -Name "AllowNewsAndInterests" -Value 0 -Type DWord -Force
        }
        Undo = {
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -Name "AllowNewsAndInterests" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        }
    }

    "Deshabilitar Game DVR / Xbox Game Bar (mas FPS)" = @{
        Status = { (Get-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -ErrorAction SilentlyContinue).GameDVR_Enabled -eq 0 }
        Invoke = {
            Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Force | Out-Null
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Name "AllowGameDVR" -Value 0 -Type DWord -Force
        }
        Undo = {
            Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Name "AllowGameDVR" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        }
    }

    "Deshabilitar hibernacion (libera espacio en disco)" = @{
        Status = { (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -Name "HibernateEnabled" -ErrorAction SilentlyContinue).HibernateEnabled -eq 0 }
        Invoke = { powercfg -h off }
        Undo   = { powercfg -h on }
    }

    "Efectos visuales: priorizar rendimiento" = @{
        Status = { (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name "VisualFXSetting" -ErrorAction SilentlyContinue).VisualFXSetting -eq 2 }
        Invoke = {
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name "VisualFXSetting" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
        }
        Undo = {
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name "VisualFXSetting" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        }
    }

    "Desactivar reporte de errores de Windows" = @{
        Status = { (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" -Name "Disabled" -ErrorAction SilentlyContinue).Disabled -eq 1 }
        Invoke = {
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" -Name "Disabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            Stop-Service -Name "WerSvc" -Force -ErrorAction SilentlyContinue
            Set-Service -Name "WerSvc" -StartupType Disabled -ErrorAction SilentlyContinue
        }
        Undo = {
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" -Name "Disabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-Service -Name "WerSvc" -StartupType Manual -ErrorAction SilentlyContinue
        }
    }

    "Bloquear funciones de IA de Windows (Copilot/Recall)" = @{
        Status = { (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" -Name "TurnOffWindowsCopilot" -ErrorAction SilentlyContinue).TurnOffWindowsCopilot -eq 1 }
        Invoke = {
            New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" -Force | Out-Null
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" -Name "TurnOffWindowsCopilot" -Value 1 -Type DWord -Force
            New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" -Force | Out-Null
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" -Name "DisableAIDataAnalysis" -Value 1 -Type DWord -Force
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" -Name "AllowRecallEnablement" -Value 0 -Type DWord -Force
        }
        Undo = {
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" -Name "TurnOffWindowsCopilot" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" -Name "DisableAIDataAnalysis" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" -Name "AllowRecallEnablement" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        }
    }

    "Limpiar archivos temporales" = @{
        Status = $null
        Invoke = {
            Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path "C:\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
        }
        Undo = { <# accion no reversible - solo limpieza #> }
    }
}

# ---------------------------------------------------------------
# 3. TWEAKS AVANZADOS - mas agresivos, leer bien antes de aplicar
# ---------------------------------------------------------------
$AdvancedTweaks = [ordered]@{

    "Restaurar menu contextual clasico (Windows 11)" = @{
        Warning = "Vuelve al clic derecho estilo Windows 10, sin el menu compacto de Win11."
        Status  = { Test-Path "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" }
        Invoke  = {
            New-Item -Path "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" -Force -Value "" | Out-Null
        }
        Undo = {
            Remove-Item -Path "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    "Deshabilitar Fast Startup (arranque rapido)" = @{
        Warning = "Util si tienes problemas de doble arranque con Linux o discos externos que no se liberan bien."
        Status  = { (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -ErrorAction SilentlyContinue).HiberbootEnabled -eq 0 }
        Invoke  = { powercfg /h off; Start-Sleep -Seconds 1; powercfg /h on; Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue }
        Undo    = { Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue }
    }

    "Desactivar indexado de busqueda (Windows Search)" = @{
        Warning = "La busqueda de archivos sera mas lenta, pero libera CPU/disco en equipos modestos."
        Status  = { (Get-Service -Name "WSearch" -ErrorAction SilentlyContinue).StartType -eq "Disabled" }
        Invoke  = { Stop-Service -Name "WSearch" -Force -ErrorAction SilentlyContinue; Set-Service -Name "WSearch" -StartupType Disabled -ErrorAction SilentlyContinue }
        Undo    = { Set-Service -Name "WSearch" -StartupType Automatic -ErrorAction SilentlyContinue; Start-Service -Name "WSearch" -ErrorAction SilentlyContinue }
    }

    "Deshabilitar SMBv1 (proteccion, ya obsoleto)" = @{
        Warning = "Recomendado en casi todos los casos: SMBv1 es inseguro y ya no lo usa casi nadie."
        Status  = { (Get-WindowsOptionalFeature -Online -FeatureName "SMB1Protocol" -ErrorAction SilentlyContinue).State -eq "Disabled" }
        Invoke  = { Disable-WindowsOptionalFeature -Online -FeatureName "SMB1Protocol" -NoRestart -ErrorAction SilentlyContinue | Out-Null }
        Undo    = { Enable-WindowsOptionalFeature -Online -FeatureName "SMB1Protocol" -NoRestart -ErrorAction SilentlyContinue | Out-Null }
    }

    "Deshabilitar Nagle's Algorithm (menor latencia de red)" = @{
        Warning = "Pensado para gaming/online. Puede aumentar ligeramente el uso de ancho de banda."
        Status  = {
            $found = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" -ErrorAction SilentlyContinue | Where-Object {
                (Get-ItemProperty -Path $_.PsPath -Name "TcpAckFrequency" -ErrorAction SilentlyContinue).TcpAckFrequency -eq 1
            }
            [bool]$found
        }
        Invoke  = {
            Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" | ForEach-Object {
                Set-ItemProperty -Path $_.PsPath -Name "TcpAckFrequency" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $_.PsPath -Name "TCPNoDelay" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            }
        }
        Undo = {
            Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" | ForEach-Object {
                Remove-ItemProperty -Path $_.PsPath -Name "TcpAckFrequency" -ErrorAction SilentlyContinue
                Remove-ItemProperty -Path $_.PsPath -Name "TCPNoDelay" -ErrorAction SilentlyContinue
            }
        }
    }

    "Deshabilitar asistencia remota" = @{
        Warning = "Nadie podra tomar control remoto de este equipo via Asistencia Remota de Windows."
        Status  = { (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance" -Name "fAllowToGetHelp" -ErrorAction SilentlyContinue).fAllowToGetHelp -eq 0 }
        Invoke  = { Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance" -Name "fAllowToGetHelp" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue }
        Undo    = { Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance" -Name "fAllowToGetHelp" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue }
    }

    "Desactivar SysMain y Prefetcher (solo recomendado en SSD)" = @{
        Warning = "Apaga el servicio que precarga programas en memoria. En SSD/NVMe casi no se nota la diferencia; en HDD empeora los tiempos de carga, por eso se omite si tu disco del sistema es HDD."
        Status  = { (Get-Service -Name "SysMain" -ErrorAction SilentlyContinue).StartType -eq "Disabled" }
        Invoke  = {
            $isHdd = $false
            try {
                $disk = Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(":")) -ErrorAction Stop | Get-Disk | Get-PhysicalDisk
                if ($disk.MediaType -eq "HDD") { $isHdd = $true }
            } catch { }
            if ($isHdd) { Write-Log "  SysMain: tu disco del sistema es HDD, se omite (en HDD si ayuda tener SysMain)."; return }
            Stop-Service -Name "SysMain" -Force -ErrorAction SilentlyContinue
            Set-Service -Name "SysMain" -StartupType Disabled -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters" -Name "EnablePrefetcher" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        }
        Undo    = {
            Set-Service -Name "SysMain" -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service -Name "SysMain" -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters" -Name "EnablePrefetcher" -Value 3 -Type DWord -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------
# 3b. TWEAKS DE GAMING / RENDIMIENTO EXTREMO
#     Pensados para exprimir el maximo de FPS y minimo input-lag
#     sin tocar hardware. Basado en practicas documentadas de
#     Game Mode, HAGS, prioridad multimedia, MSI mode, etc.
# ---------------------------------------------------------------
$GamingTweaks = [ordered]@{

    "Activar plan de energia 'Ultimate Performance'" = @{
        Warning = "Plan de energia oculto de Windows, sin limites de ahorro de energia. En laptop consume mas bateria."
        Status  = { (powercfg /getactivescheme) -match "e9a42b02-d5df-448d-aa00-03f14749eb61|Ultimate Performance" }
        Invoke  = {
            $src  = "e9a42b02-d5df-448d-aa00-03f14749eb61"
            $rx   = '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'
            $guid = $null
            # Si el plan ya existe (por su codigo o por el nombre que le pone esta app) se reutiliza,
            # asi no se crean copias repetidas cada vez que se aplica.
            foreach ($line in @(powercfg -list)) {
                if (("$line" -match "Ultimate Performance") -or ("$line" -match $src)) {
                    if ("$line" -match $rx) { $guid = $Matches[1]; break }
                }
            }
            if (-not $guid) {
                $out = powercfg -duplicatescheme $src
                if ("$out" -match $rx) {
                    $guid = $Matches[1]
                    # Nombre fijo en ingles: asi el estado "Activo" lo reconoce en cualquier idioma de Windows
                    powercfg -changename $guid "Ultimate Performance" | Out-Null
                }
            }
            if ($guid) { powercfg -setactive $guid }
        }
        Undo = { powercfg -setactive SCHEME_BALANCED }
    }

    "Activar Game Mode de Windows" = @{
        Warning = "Prioriza CPU/GPU para el juego en primer plano y evita que Windows Update instale durante la partida."
        Status  = { (Get-ItemProperty -Path "HKCU:\Software\Microsoft\GameBar" -Name "AutoGameModeEnabled" -ErrorAction SilentlyContinue).AutoGameModeEnabled -eq 1 }
        Invoke  = {
            New-Item -Path "HKCU:\Software\Microsoft\GameBar" -Force | Out-Null
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\GameBar" -Name "AutoGameModeEnabled" -Value 1 -Type DWord -Force
        }
        Undo = { Set-ItemProperty -Path "HKCU:\Software\Microsoft\GameBar" -Name "AutoGameModeEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue }
    }

    "Activar Hardware-Accelerated GPU Scheduling (HAGS)" = @{
        Warning = "Deja que la GPU administre su propia cola de memoria en vez de Windows. Requiere reiniciar. En algunas GPU/driver antiguos no aporta nada."
        Status  = { (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "HwSchMode" -ErrorAction SilentlyContinue).HwSchMode -eq 2 }
        Invoke  = { Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "HwSchMode" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue }
        Undo    = { Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "HwSchMode" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue }
    }

    "Desactivar Fullscreen Optimizations (global)" = @{
        Warning = "Fuerza pantalla completa exclusiva en juegos que la soporten: menos input-lag, aunque el Alt+Tab puede tardar un poco mas."
        Status  = { (Get-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_FSEBehaviorMode" -ErrorAction SilentlyContinue).GameDVR_FSEBehaviorMode -eq 2 }
        Invoke  = {
            New-Item -Path "HKCU:\System\GameConfigStore" -Force | Out-Null
            Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_FSEBehaviorMode" -Value 2 -Type DWord -Force
            Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_HonorUserFSEBehaviorMode" -Value 1 -Type DWord -Force
        }
        Undo = {
            Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_FSEBehaviorMode" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_HonorUserFSEBehaviorMode" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        }
    }

    "Priorizar juegos en el planificador multimedia" = @{
        Warning = "Le dice a Windows que reserve menos CPU para tareas de fondo y priorice audio/juegos en primer plano (tweak clasico usado por editores de video/streamers tambien)."
        Status  = { (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "SystemResponsiveness" -ErrorAction SilentlyContinue).SystemResponsiveness -eq 0 }
        Invoke  = {
            $base = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
            Set-ItemProperty -Path $base -Name "SystemResponsiveness" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            $gamesPath = "$base\Tasks\Games"
            New-Item -Path $gamesPath -Force | Out-Null
            Set-ItemProperty -Path $gamesPath -Name "GPU Priority" -Value 8 -Type DWord -Force
            Set-ItemProperty -Path $gamesPath -Name "Priority" -Value 6 -Type DWord -Force
            Set-ItemProperty -Path $gamesPath -Name "Scheduling Category" -Value "High" -Type String -Force
            Set-ItemProperty -Path $gamesPath -Name "SFIO Priority" -Value "High" -Type String -Force
        }
        Undo = {
            $base = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
            Set-ItemProperty -Path $base -Name "SystemResponsiveness" -Value 20 -Type DWord -Force -ErrorAction SilentlyContinue
            $gamesPath = "$base\Tasks\Games"
            Set-ItemProperty -Path $gamesPath -Name "Priority" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $gamesPath -Name "Scheduling Category" -Value "Medium" -Type String -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $gamesPath -Name "SFIO Priority" -Value "Normal" -Type String -Force -ErrorAction SilentlyContinue
        }
    }

    "Desactivar Network Throttling (multimedia/red)" = @{
        Warning = "Quita el limite que Windows pone al procesamiento de red para tareas multimedia. Ayuda en juegos online."
        Status  = { (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "NetworkThrottlingIndex" -ErrorAction SilentlyContinue).NetworkThrottlingIndex -eq 0xffffffff }
        Invoke  = { Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "NetworkThrottlingIndex" -Value 0xffffffff -Type DWord -Force -ErrorAction SilentlyContinue }
        Undo    = { Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "NetworkThrottlingIndex" -Value 10 -Type DWord -Force -ErrorAction SilentlyContinue }
    }

    "Reducir descargas P2P de Windows Update (Delivery Optimization)" = @{
        Warning = "Evita que tu PC use tu red/subida para compartir actualizaciones con otros equipos mientras juegas."
        Status  = { (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Name "DODownloadMode" -ErrorAction SilentlyContinue).DODownloadMode -eq 0 }
        Invoke  = {
            New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Force | Out-Null
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Name "DODownloadMode" -Value 0 -Type DWord -Force
        }
        Undo = { Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Name "DODownloadMode" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue }
    }

    "Desactivar Core Parking (mantener todos los nucleos activos)" = @{
        Warning = "Evita que Windows 'apague' nucleos de CPU para ahorrar energia. Sube el consumo/calor un poco, pero elimina micro-stutters en CPUs de muchos nucleos."
        Status  = $null
        Invoke  = { powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR CPMINCORES 100; powercfg /setactive SCHEME_CURRENT }
        Undo    = { powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR CPMINCORES 0; powercfg /setactive SCHEME_CURRENT }
    }

    "Desactivar aceleracion del mouse (precision de puntero)" = @{
        Warning = "Hace que el mouse se mueva 1:1 con tu mano, sin que Windows acelere/suavice el movimiento. Es EL tweak clasico contra el input lag percibido en juegos de puntaria. Puede sentirse raro los primeros minutos si estabas acostumbrado a la aceleracion."
        Status  = {
            $m = Get-ItemProperty -Path "HKCU:\Control Panel\Mouse" -ErrorAction SilentlyContinue
            $m.MouseSpeed -eq "0" -and $m.MouseThreshold1 -eq "0" -and $m.MouseThreshold2 -eq "0"
        }
        Invoke  = {
            Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseSpeed" -Value "0" -Type String -Force
            Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold1" -Value "0" -Type String -Force
            Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold2" -Value "0" -Type String -Force
        }
        Undo = {
            Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseSpeed" -Value "1" -Type String -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold1" -Value "6" -Type String -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold2" -Value "10" -Type String -Force -ErrorAction SilentlyContinue
        }
    }

    "Desactivar USB Selective Suspend" = @{
        Warning = "Evita que Windows 'duerma' los puertos USB (mouse, teclado, receptores wireless) para ahorrar energia. Elimina micro-cortes/lag al reactivarse. En laptop consume un poco mas de bateria."
        Status  = $null
        Invoke  = {
            powercfg /setacvalueindex SCHEME_CURRENT SUB_USB USBSELECTIVESUSPEND 0
            powercfg /setdcvalueindex SCHEME_CURRENT SUB_USB USBSELECTIVESUSPEND 0
            powercfg /setactive SCHEME_CURRENT
        }
        Undo = {
            powercfg /setacvalueindex SCHEME_CURRENT SUB_USB USBSELECTIVESUSPEND 1
            powercfg /setdcvalueindex SCHEME_CURRENT SUB_USB USBSELECTIVESUSPEND 1
            powercfg /setactive SCHEME_CURRENT
        }
    }

    "Habilitar MSI Mode en la GPU (menos latencia de interrupciones)" = @{
        Warning = "Cambia el modo de interrupciones de la tarjeta grafica de 'line-based' a 'message-signaled'. Mejora pequena pero consistente, sin riesgo real."
        Status  = {
            $gpu = Get-PnpDevice -Class Display -Status OK -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $gpu) { return $false }
            $path = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($gpu.InstanceId)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
            (Get-ItemProperty -Path $path -Name "MSISupported" -ErrorAction SilentlyContinue).MSISupported -eq 1
        }
        Invoke  = {
            $gpu = Get-PnpDevice -Class Display -Status OK -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($gpu) {
                $path = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($gpu.InstanceId)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
                New-Item -Path $path -Force | Out-Null
                Set-ItemProperty -Path $path -Name "MSISupported" -Value 1 -Type DWord -Force
            }
        }
        Undo = {
            $gpu = Get-PnpDevice -Class Display -Status OK -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($gpu) {
                $path = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($gpu.InstanceId)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
                Set-ItemProperty -Path $path -Name "MSISupported" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            }
        }
    }

    "[RIESGO] Desactivar Memory Integrity (Core Isolation)" = @{
        Danger  = $true
        Warning = "Puede dar entre 2 y 15% mas FPS, pero apaga una capa de seguridad del kernel contra malware. Usalo SOLO en un PC dedicado a gaming, nunca en uno que uses para banca/trabajo. Requiere reiniciar."
        Status  = { (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" -Name "Enabled" -ErrorAction SilentlyContinue).Enabled -eq 0 }
        Invoke  = {
            New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" -Force | Out-Null
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" -Name "Enabled" -Value 0 -Type DWord -Force
        }
        Undo = { Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" -Name "Enabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue }
    }
}

# Optimizaciones para juegos en ventana: Microsoft las agrego en Windows 11 (build 22557).
# Mejoran la latencia en juegos DX10/DX11 en ventana o sin bordes y habilitan Auto HDR y VRR.
$script:WinBuildNumber = 0
try { $script:WinBuildNumber = [int](Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction Stop).CurrentBuild } catch { }
if ($script:WinBuildNumber -ge 22557) {
    $GamingTweaks["Activar optimizaciones para juegos en ventana (Windows 11)"] = @{
        Warning = "Windows presenta los frames de juegos DX10/DX11 en ventana o sin bordes con un modo mas rapido (menos latencia). Hay que reiniciar el juego. En casos raros puede chocar con overlays o capturas."
        Status  = { ((Get-ItemProperty -Path "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences" -Name "DirectXUserGlobalSettings" -ErrorAction SilentlyContinue).DirectXUserGlobalSettings) -match "SwapEffectUpgradeEnable=1" }
        Invoke  = {
            $path = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"
            if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
            # Se conservan las otras opciones de la misma cadena (Auto HDR, VRR, etc.) y solo se cambia esta
            $cur = (Get-ItemProperty -Path $path -Name "DirectXUserGlobalSettings" -ErrorAction SilentlyContinue).DirectXUserGlobalSettings
            $parts = @()
            if ($cur) { $parts = @($cur -split ";" | Where-Object { $_ -and ($_ -notmatch "^SwapEffectUpgradeEnable=") }) }
            $parts += "SwapEffectUpgradeEnable=1"
            Set-ItemProperty -Path $path -Name "DirectXUserGlobalSettings" -Value (($parts -join ";") + ";") -Type String -Force
        }
        Undo    = {
            $path = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"
            if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
            $cur = (Get-ItemProperty -Path $path -Name "DirectXUserGlobalSettings" -ErrorAction SilentlyContinue).DirectXUserGlobalSettings
            $parts = @()
            if ($cur) { $parts = @($cur -split ";" | Where-Object { $_ -and ($_ -notmatch "^SwapEffectUpgradeEnable=") }) }
            $parts += "SwapEffectUpgradeEnable=0"
            Set-ItemProperty -Path $path -Name "DirectXUserGlobalSettings" -Value (($parts -join ";") + ";") -Type String -Force
        }
    }
}

# ---------------------------------------------------------------
# 4b. LIMPIEZA DE DISCO - categorias de "basura" del sistema
# ---------------------------------------------------------------
$BiosGuide = [ordered]@{
    "Activar XMP / DOCP / EXPO" = @{
        Impact = "Sin esto tu RAM corre mas lenta de lo que dice la caja (una RAM de 6000MHz puede estar andando a 2133MHz sin que lo sepas). Es el cambio de BIOS con mas impacto real en FPS, y es gratis."
        Risk = "Bajo"
    }
    "Activar Resizable BAR + Above 4G Decoding" = @{
        Impact = "Deja que la CPU acceda a toda la memoria de la placa de video de una sola vez en vez de a pedacitos. En varios juegos da un salto notorio de FPS. Necesita CPU/GPU/placa relativamente recientes (2020 en adelante)."
        Risk = "Bajo"
    }
    "Desactivar CSM (Compatibility Support Module)" = @{
        Impact = "Es requisito para que Resizable BAR funcione. Fuerza el arranque 100% en modo UEFI. Windows 10/11 modernos ya arrancan asi por defecto, no deberia romper nada."
        Risk = "Medio"
    }
    "Fast Boot" = @{
        Impact = "Acelera el arranque salteando chequeos de hardware. No afecta FPS in-game, pero si necesitas entrar seguido al BIOS puede complicar el timing de la tecla - desactivalo temporalmente si te pasa eso."
        Risk = "Bajo"
    }
    "Desactivar dispositivos onboard que no usas" = @{
        Impact = "Audio, LAN, controladoras extra, Bluetooth: si no los usas, apagarlos libera recursos e interrupciones del sistema. Impacto chico pero real en placas con muchos controladores de mas."
        Risk = "Bajo"
    }
    "PCIe Slot Configuration (generacion del slot de la GPU)" = @{
        Impact = "Verifica que el slot principal este en Auto o en la generacion maxima que soporta tu placa (Gen4/Gen5). A veces, sobre todo tras un reset de BIOS, queda forzado en una generacion mas vieja sin que te des cuenta."
        Risk = "Bajo"
    }
    "Overclock/PBO de CPU (Precision Boost Overdrive en AMD, multiplicador en Intel)" = @{
        Impact = "Deja que el procesador se acelere mas alla de sus limites de fabrica cuando hay margen termico. Subilo de a poco (o activa PBO) probando estabilidad con Prime95/Cinebench entre cada paso, igual que hicimos con el OC de GPU en Afterburner."
        Risk = "Medio"
    }
    "Curva de ventiladores (Fan Curve)" = @{
        Impact = "Una curva mas agresiva a partir de los 60-70 grados evita que el sistema baje sus clocks por temperatura (throttling) durante sesiones largas."
        Risk = "Bajo"
    }
    "Actualizar la version del BIOS" = @{
        Impact = "Los fabricantes sacan actualizaciones que mejoran compatibilidad de RAM, arreglan bugs de rendimiento y suman soporte para CPUs nuevas. Se revisa en la pagina de soporte de tu placa madre, por modelo exacto."
        Risk = "Medio"
    }
    "TPM 2.0 y Secure Boot" = @{
        Impact = "No afectan FPS, pero son obligatorios para Windows 11. Si tu placa los tiene apagados y pensas actualizar desde Windows 10, activalos antes de instalar."
        Risk = "Bajo"
    }
}

$RecommendedTools = [ordered]@{
    "CPU-Z"    = @{ Url = "https://www.cpuid.com/softwares/cpu-z.html"; Desc = "Info detallada de CPU, placa madre y memoria RAM." }
    "GPU-Z"    = @{ Url = "https://www.techpowerup.com/gpuz/"; Desc = "Info detallada de la placa de video (clocks, memoria, sensores)." }
    "HWiNFO"   = @{ Url = "https://www.hwinfo.com/download/"; Desc = "Monitoreo completo de sensores de todo el equipo en tiempo real." }
    "MSI Afterburner" = @{ Url = "https://www.msi.com/Landing/afterburner/graphics-cards"; Desc = "Overclock, undervolt y monitoreo de GPU (el que ya estas usando)." }
    "NVIDIA Profile Inspector" = @{ Url = "https://github.com/Orbmu2k/nvidiaProfileInspector/releases"; Desc = "Ajustes avanzados de NVIDIA que no aparecen en el panel de control normal." }
    "DDU (Display Driver Uninstaller)" = @{ Url = "https://www.wagnardsoft.com/"; Desc = "Desinstala por completo drivers de GPU antes de instalar una version nueva, evita conflictos." }
    "CRU (Custom Resolution Utility)" = @{ Url = "https://www.monitortests.com/forum/Thread-Custom-Resolution-Utility-CRU"; Desc = "Crea resoluciones y frecuencias de refresco personalizadas para el monitor." }
    "FurMark" = @{ Url = "https://geeks3d.com/furmark/"; Desc = "Stress test de GPU, util para probar estabilidad despues de un overclock." }
    "Prime95" = @{ Url = "https://www.mersenne.org/download/"; Desc = "Stress test de CPU, el clasico para probar estabilidad." }
    "Polling.exe" = @{ Url = "https://github.com/cakama3a/Polling"; Desc = "Mide la tasa de polling real de tu mouse (Hz)." }
    "HidUsbFilter" = @{ Url = "https://www.overclock.net/posts/24849597"; Desc = "Permite forzar una tasa de polling mas alta en mouses USB (uso avanzado)." }
    "MoreClockTool" = @{ Url = "https://www.igorslab.de/das-moreclocktool-mct-zum-kostenlosen-download-der-praktische-oc-aufsatz-zum-morepowertool-ersetzt-den-wattman/3/"; Desc = "Overclock avanzado de memoria de GPU AMD, mas alla del limite del driver." }
    "TestMem5 (TM5)" = @{ Url = "https://www.overclock.net/threads/memory-testing-with-testmem5-tm5-with-custom-configs.1751608"; Desc = "Test de estabilidad de RAM, el estandar para probar overclock de memoria." }
}

$CleanupCategories = [ordered]@{
    "Archivos temporales del usuario" = @{
        Paths = @("$env:TEMP")
    }
    "Archivos temporales de Windows" = @{
        Paths = @("C:\Windows\Temp")
    }
    "Cache de descargas de Windows Update" = @{
        Paths = @("C:\Windows\SoftwareDistribution\Download")
    }
    "Entrega optimizada (Delivery Optimization)" = @{
        Paths = @("C:\Windows\SoftwareDistribution\DeliveryOptimization","C:\ProgramData\Microsoft\Network\Downloader")
    }
    "Reportes de errores de Windows (WER)" = @{
        Paths = @("C:\ProgramData\Microsoft\Windows\WER")
    }
    "Volcados de memoria (crash dumps)" = @{
        Paths = @("C:\Windows\Minidump","C:\Windows\MEMORY.DMP")
    }
    "Registros de instalacion (CBS / Panther)" = @{
        Paths = @("C:\Windows\Logs\CBS","C:\Windows\Panther")
    }
    "Cache de miniaturas (thumbnails)" = @{
        Paths = @("$env:LOCALAPPDATA\Microsoft\Windows\Explorer")
        FilePattern = "thumbcache_*.db"
        RestartExplorer = $true
    }
    "Cache de shaders DirectX" = @{
        Paths = @("$env:LOCALAPPDATA\D3DSCache")
    }
    "Cache de navegadores (Chrome / Edge / Firefox)" = @{
        Paths = @(
            "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache",
            "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache",
            "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles\*\cache2"
        )
    }
    "Restos de instaladores de drivers (NVIDIA / AMD)" = @{
        Paths = @("C:\NVIDIA", "C:\AMD", "$env:ProgramData\NVIDIA Corporation\Downloader")
    }
    "Versiones viejas de drivers de video (NVIDIA / AMD)" = @{
        Paths = @()
        Special = "OldGpuDrivers"
    }
    "Windows.old (instalacion anterior de Windows)" = @{
        Paths = @("C:\Windows.old")
        Special = "WindowsOld"
    }
}

# ---------------------------------------------------------------
# 5. XAML de la interfaz
# ---------------------------------------------------------------
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PC Optimizer v$AppVersion" Height="780" Width="1040"
        WindowStartupLocation="CenterScreen" Background="#090909"
        FontFamily="Segoe UI" UseLayoutRounding="True" SnapsToDevicePixels="True">
    <Window.Resources>
        <SolidColorBrush x:Key="BgPanel" Color="#121212"/>
        <SolidColorBrush x:Key="BgHover" Color="#1d1d1d"/>
        <SolidColorBrush x:Key="BorderSubtle" Color="#272727"/>
        <SolidColorBrush x:Key="TextPrimary" Color="#f2f2f2"/>
        <SolidColorBrush x:Key="TextMuted" Color="#9a9a9a"/>
        <SolidColorBrush x:Key="Accent" Color="#ff1a1a"/>
        <SolidColorBrush x:Key="Accent2" Color="#525252"/>
        <LinearGradientBrush x:Key="AccentGradient" StartPoint="0,0" EndPoint="1,0">
            <GradientStop Color="#ff1a1a" Offset="0"/>
            <GradientStop Color="#7a0d0d" Offset="1"/>
        </LinearGradientBrush>
        <LinearGradientBrush x:Key="AccentGradientV" StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#ff1a1a" Offset="0"/>
            <GradientStop Color="#7a0d0d" Offset="1"/>
        </LinearGradientBrush>

        <Style TargetType="TabControl">
            <Setter Property="Background" Value="#090909"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="0"/>
        </Style>

        <Style TargetType="TabItem">
            <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="12,11"/>
            <Setter Property="Width" Value="192"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TabItem">
                        <Grid Margin="0,2,10,0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="4"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <Border Name="AccentBar" Grid.Column="0" Background="Transparent" CornerRadius="3" Margin="0,3,0,3"/>
                            <Border Name="Bd" Grid.Column="1" CornerRadius="8" Padding="{TemplateBinding Padding}" Background="Transparent" Margin="6,0,0,0">
                                <ContentPresenter ContentSource="Header" HorizontalAlignment="Left" VerticalAlignment="Center"/>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#161616"/>
                                <Setter TargetName="AccentBar" Property="Background" Value="{StaticResource AccentGradient}"/>
                                <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>


        <Style TargetType="Button">
            <Setter Property="Background" Value="{StaticResource BgHover}"/>
            <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="Bd" Background="{TemplateBinding Background}" CornerRadius="7" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Opacity" Value="0.85"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Opacity" Value="0.7"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="Bd" Property="Opacity" Value="0.4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="ToolTip">
            <Setter Property="Background" Value="#1d1d1d"/>
            <Setter Property="Foreground" Value="#f2f2f2"/>
            <Setter Property="BorderBrush" Value="#3a3a3a"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="FontSize" Value="12"/>
        </Style>

        <Style x:Key="BarGhostBtn" TargetType="Button">
            <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="14,8"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="Bd" Background="Transparent" BorderBrush="{StaticResource BorderSubtle}" BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="{StaticResource BgHover}"/>
                                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource Accent2}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Opacity" Value="0.7"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="Bd" Property="Opacity" Value="0.4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="BarOutlineBtn" TargetType="Button">
            <Setter Property="Foreground" Value="{StaticResource Accent}"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="14,8"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="Bd" Background="Transparent" BorderBrush="#88ff1a1a" BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#26ff1a1a"/>
                                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource Accent}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Opacity" Value="0.7"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="Bd" Property="Opacity" Value="0.4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="BarPrimaryBtn" TargetType="Button">
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Padding" Value="26,8"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="Bd" Background="{StaticResource AccentGradient}" CornerRadius="8" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Opacity" Value="0.88"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Opacity" Value="0.7"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="Bd" Property="Opacity" Value="0.4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="CheckBox">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                            <Border Name="Box" Width="17" Height="17" CornerRadius="4" BorderBrush="{StaticResource BorderSubtle}" BorderThickness="1.5" Background="Transparent" Margin="0,0,8,0">
                                <Path Name="Check" Data="M 3,8 L 7,12 L 14,4" Stroke="White" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Visibility="Collapsed"/>
                            </Border>
                            <ContentPresenter VerticalAlignment="Center"/>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="Box" Property="Background" Value="{StaticResource AccentGradient}"/>
                                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Accent}"/>
                                <Setter TargetName="Check" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Accent2}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="ProgressBar">
            <Setter Property="Background" Value="{StaticResource BgHover}"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ProgressBar">
                        <Border CornerRadius="6" Background="{TemplateBinding Background}">
                            <Grid ClipToBounds="True">
                                <Border Name="PART_Track"/>
                                <Border Name="PART_Indicator" HorizontalAlignment="Left" Background="{StaticResource AccentGradient}" CornerRadius="6"/>
                            </Grid>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ModernScrollThumb" TargetType="Thumb">
            <Setter Property="MinHeight" Value="30"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Thumb">
                        <Border Name="ThumbBorder" Background="{StaticResource AccentGradientV}" CornerRadius="5" Opacity="0.75" Margin="3,0,3,0"/>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ThumbBorder" Property="Opacity" Value="0.95"/>
                            </Trigger>
                            <Trigger Property="IsDragging" Value="True">
                                <Setter TargetName="ThumbBorder" Property="Opacity" Value="1"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="ScrollBar">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Width" Value="13"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                        <Grid Background="{TemplateBinding Background}">
                            <Border Background="#161616" CornerRadius="6" Margin="3,0,3,0"/>
                            <Track Name="PART_Track" IsDirectionReversed="True">
                                <Track.DecreaseRepeatButton>
                                    <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/>
                                </Track.DecreaseRepeatButton>
                                <Track.IncreaseRepeatButton>
                                    <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/>
                                </Track.IncreaseRepeatButton>
                                <Track.Thumb>
                                    <Thumb Style="{StaticResource ModernScrollThumb}"/>
                                </Track.Thumb>
                            </Track>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="ScrollViewer">
            <Setter Property="Background" Value="Transparent"/>
        </Style>
    </Window.Resources>

    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="155"/>
        </Grid.RowDefinitions>

        <Canvas Grid.RowSpan="3" IsHitTestVisible="False">
            <Ellipse Width="260" Height="260" Canvas.Left="-90" Canvas.Top="-110" Opacity="0.30">
                <Ellipse.Fill>
                    <RadialGradientBrush>
                        <GradientStop Color="#ff1a1a" Offset="0"/>
                        <GradientStop Color="Transparent" Offset="1"/>
                    </RadialGradientBrush>
                </Ellipse.Fill>
                <Ellipse.Effect><BlurEffect Radius="55"/></Ellipse.Effect>
            </Ellipse>
        </Canvas>

        <StackPanel Grid.Row="0" Margin="0,0,0,12">
            <StackPanel Orientation="Horizontal" VerticalAlignment="Bottom">
                <TextBlock FontSize="30" FontWeight="ExtraBold" FontFamily="Segoe UI">
                    <Run Text="PC " Foreground="{StaticResource TextPrimary}"/>
                    <Run Text="OPTIMIZER" Foreground="{StaticResource Accent}"/>
                </TextBlock>
                <Border Background="{StaticResource Accent}" CornerRadius="4" Padding="6,1" Margin="8,0,0,5" VerticalAlignment="Bottom">
                    <TextBlock Text="PRO" FontSize="11" FontWeight="Bold" Foreground="White"/>
                </Border>
                <TextBlock Text="by Urizen  ·  v$AppVersion" FontSize="11" FontStyle="Italic" Foreground="{StaticResource TextMuted}" Margin="8,0,0,4" VerticalAlignment="Bottom"/>
            </StackPanel>
            <TextBlock Text="Debloat · Tweaks · Gaming · RAM · Disco - todo en un solo lugar" FontSize="12" Foreground="{StaticResource TextMuted}" Margin="0,3,0,0"/>
        </StackPanel>

        <TabControl Grid.Row="1" Name="MainTabs" TabStripPlacement="Left">
            <TabItem Header="🏠  Inicio">
                <StackPanel Name="InicioRoot" Margin="20">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>

                        <StackPanel Grid.Column="0" Margin="0,0,14,0">
                            <Border Background="{StaticResource BgPanel}" CornerRadius="10" Padding="16,14">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <StackPanel Grid.Column="0" VerticalAlignment="Center" Margin="0,0,14,0">
                                        <TextBlock Name="GreetingText" Text="Hola" FontSize="19" FontWeight="Bold" Foreground="{StaticResource TextPrimary}"/>
                                        <TextBlock Name="ScoreTitle" Text="Calculando nivel de optimizacion..." FontSize="13" FontWeight="SemiBold" Foreground="{StaticResource TextPrimary}" Margin="0,5,0,0" TextWrapping="Wrap"/>
                                        <TextBlock Name="ScoreDetail" Text="" FontSize="11.5" Foreground="{StaticResource TextMuted}" Margin="0,3,0,0" TextWrapping="Wrap"/>
                                        <TextBlock Name="HardwareLine" Text="" FontSize="11" Foreground="{StaticResource TextMuted}" Margin="0,8,0,0" TextWrapping="Wrap"/>
                                    </StackPanel>
                                    <StackPanel Grid.Column="1" Width="140" VerticalAlignment="Center" Margin="6,0,0,0">
                                        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                                            <TextBlock Name="ScoreValue" Text="--" FontSize="40" FontWeight="Bold" Foreground="{StaticResource TextPrimary}" VerticalAlignment="Bottom"/>
                                            <TextBlock Name="ScoreTotal" Text="" FontSize="19" FontWeight="SemiBold" Foreground="{StaticResource TextMuted}" VerticalAlignment="Bottom" Margin="4,0,0,6"/>
                                        </StackPanel>
                                        <TextBlock Text="AJUSTES ACTIVOS" FontSize="8.5" FontWeight="SemiBold" Foreground="{StaticResource TextMuted}" HorizontalAlignment="Center" TextAlignment="Center" TextWrapping="Wrap" Margin="0,0,0,9"/>
                                        <Border Height="5" CornerRadius="3" Background="#272727">
                                            <Border Name="ScoreBar" CornerRadius="3" HorizontalAlignment="Left" Width="0" Background="#4ade80"/>
                                        </Border>
                                    </StackPanel>
                                </Grid>
                            </Border>

                    <Border Background="{StaticResource BgPanel}" CornerRadius="10" Padding="14" Margin="0,14,0,0">
                        <StackPanel>
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <StackPanel Grid.Column="0" Orientation="Horizontal">
                                    <Button Name="BtnMetricCpu" Content="CPU" Width="58" Height="26" Padding="0" Margin="0,0,6,0" FontSize="11.5" Background="{StaticResource AccentGradient}" Foreground="White"/>
                                    <Button Name="BtnMetricGpu" Content="GPU" Width="58" Height="26" Padding="0" Margin="0,0,6,0" FontSize="11.5" Background="#1d1d1d" Foreground="{StaticResource TextMuted}"/>
                                    <Button Name="BtnMetricRam" Content="RAM" Width="58" Height="26" Padding="0" FontSize="11.5" Background="#1d1d1d" Foreground="{StaticResource TextMuted}"/>
                                </StackPanel>
                                <TextBlock Grid.Column="1" Name="CpuPercentText" Text="0%" Foreground="#4ade80" FontWeight="Bold" FontSize="18"/>
                            </Grid>
                            <TextBlock Name="CpuNameText" Text="Procesador" Foreground="{StaticResource TextMuted}" FontSize="12" Margin="0,9,0,0"/>
                            <TextBlock Name="CpuDetailText" Text="" Foreground="{StaticResource TextMuted}" FontSize="11" Margin="0,2,0,0"/>
                            <Grid Height="120" Margin="0,10,0,4" ClipToBounds="True">
                                <Canvas Name="MetricBarsCanvas"/>
                            </Grid>
                        </StackPanel>
                    </Border>
                        </StackPanel>

                        <StackPanel Grid.Column="1" Width="236">
                            <TextBlock Text="PERFILES" FontFamily="Consolas" FontSize="10.5" FontWeight="Bold" Foreground="{StaticResource TextMuted}" Margin="2,0,0,8"/>
                        <Border Background="{StaticResource BgPanel}" CornerRadius="10" Padding="14,12" Margin="0,0,0,10">
                            <StackPanel>
                                <TextBlock Text="✅  Equilibrado" FontSize="14" FontWeight="Bold" Foreground="{StaticResource TextPrimary}"/>
                                <TextBlock Text="Lo recomendado y seguro" FontSize="11.5" Foreground="{StaticResource TextMuted}" Margin="0,3,0,8" TextWrapping="Wrap"/>
                                <Button Name="BtnProfileBalanced" Style="{StaticResource BarGhostBtn}" Content="Cargar perfil" HorizontalAlignment="Left" Padding="14,6"/>
                            </StackPanel>
                        </Border>
                        <Border Background="{StaticResource BgPanel}" CornerRadius="10" Padding="14,12" Margin="0,0,0,10">
                            <StackPanel>
                                <TextBlock Text="🎮  Gaming" FontSize="14" FontWeight="Bold" Foreground="{StaticResource TextPrimary}"/>
                                <TextBlock Text="Mas FPS y menos input lag" FontSize="11.5" Foreground="{StaticResource TextMuted}" Margin="0,3,0,8" TextWrapping="Wrap"/>
                                <Button Name="BtnProfileGaming" Style="{StaticResource BarGhostBtn}" Content="Cargar perfil" HorizontalAlignment="Left" Padding="14,6"/>
                            </StackPanel>
                        </Border>
                        <Border Background="{StaticResource BgPanel}" CornerRadius="10" Padding="14,12" Margin="0,0,0,0">
                            <StackPanel>
                                <TextBlock Text="🔒  Privacidad" FontSize="14" FontWeight="Bold" Foreground="{StaticResource TextPrimary}"/>
                                <TextBlock Text="Menos telemetria y rastreo" FontSize="11.5" Foreground="{StaticResource TextMuted}" Margin="0,3,0,8" TextWrapping="Wrap"/>
                                <Button Name="BtnProfilePrivacy" Style="{StaticResource BarGhostBtn}" Content="Cargar perfil" HorizontalAlignment="Left" Padding="14,6"/>
                            </StackPanel>
                        </Border>
                        </StackPanel>
                    </Grid>
                </StackPanel>
            </TabItem>
            <TabItem Header="🧹  Debloat">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel Margin="14">
                        <Border Background="{StaticResource BgPanel}" CornerRadius="10" Padding="14,10" Margin="0,0,0,12">
                            <StackPanel>
                                <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                                    <Ellipse Width="6" Height="6" Fill="{StaticResource Accent}" VerticalAlignment="Center" Margin="0,0,6,0"/>
                                    <TextBlock Text="DEBLOAT · APPS PREINSTALADAS" FontFamily="Consolas" FontSize="10" Foreground="{StaticResource TextMuted}"/>
                                </StackPanel>
                                <TextBlock FontSize="19" FontWeight="Black">
                                    <Run Text="Menos apps, mas " Foreground="{StaticResource TextPrimary}"/>
                                    <Run Text="rendimiento" Foreground="{StaticResource Accent}"/>
                                </TextBlock>
                            </StackPanel>
                        </Border>
                        <WrapPanel Margin="0,0,0,4">
                            <Button Name="BtnBloatPending" Style="{StaticResource BarGhostBtn}" Content="Marcar solo lo pendiente" Margin="0,0,8,6"/>
                            <Button Name="BtnBloatRec" Style="{StaticResource BarGhostBtn}" Content="Marcar recomendados pendientes" Margin="0,0,8,6"/>
                            <Button Name="BtnBloatRefresh" Style="{StaticResource BarGhostBtn}" Content="↻  Actualizar estado" Margin="0,0,8,6"/>
                        </WrapPanel>
                        <TextBlock Text="Verde = ya esta quitado.  Amarillo = todavia tenes esas apps instaladas: pasa el mouse sobre el estado para ver cuales son." Foreground="{StaticResource TextMuted}" FontSize="11" Margin="2,0,0,10" TextWrapping="Wrap"/>
                        <StackPanel Name="BloatPanel"/>
                    </StackPanel>
                </ScrollViewer>
            </TabItem>
            <TabItem Header="⚙️  Tweaks Estandar">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel Margin="14">
                        <Border Background="{StaticResource BgPanel}" CornerRadius="10" Padding="14,10" Margin="0,0,0,12">
                            <StackPanel>
                                <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                                    <Ellipse Width="6" Height="6" Fill="{StaticResource Accent}" VerticalAlignment="Center" Margin="0,0,6,0"/>
                                    <TextBlock Text="TWEAKS · WINDOWS ESTANDAR" FontFamily="Consolas" FontSize="10" Foreground="{StaticResource TextMuted}"/>
                                </StackPanel>
                                <TextBlock FontSize="19" FontWeight="Black">
                                    <Run Text="Configuralo a tu " Foreground="{StaticResource TextPrimary}"/>
                                    <Run Text="manera" Foreground="{StaticResource Accent}"/>
                                </TextBlock>
                            </StackPanel>
                        </Border>
                        <StackPanel Name="StdTweaksPanel"/>
                    </StackPanel>
                </ScrollViewer>
            </TabItem>
            <TabItem Header="🛠️  Tweaks Avanzados">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel Margin="14">
                        <Border Background="{StaticResource BgPanel}" CornerRadius="10" Padding="14,10" Margin="0,0,0,12">
                            <StackPanel>
                                <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                                    <Ellipse Width="6" Height="6" Fill="{StaticResource Accent}" VerticalAlignment="Center" Margin="0,0,6,0"/>
                                    <TextBlock Text="TWEAKS · AVANZADO" FontFamily="Consolas" FontSize="10" Foreground="{StaticResource TextMuted}"/>
                                </StackPanel>
                                <TextBlock FontSize="19" FontWeight="Black">
                                    <Run Text="Mas control, mas " Foreground="{StaticResource TextPrimary}"/>
                                    <Run Text="cuidado" Foreground="{StaticResource Accent}"/>
                                </TextBlock>
                            </StackPanel>
                        </Border>
                        <StackPanel Name="AdvTweaksPanel"/>
                    </StackPanel>
                </ScrollViewer>
            </TabItem>
            <TabItem Header="🎮  Gaming / Rendimiento">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel Margin="14">
                        <Border Background="{StaticResource BgPanel}" CornerRadius="10" Padding="14,10" Margin="0,0,0,12">
                            <StackPanel>
                                <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                                    <Ellipse Width="6" Height="6" Fill="{StaticResource Accent}" VerticalAlignment="Center" Margin="0,0,6,0"/>
                                    <TextBlock Text="GAMING · RENDIMIENTO" FontFamily="Consolas" FontSize="10" Foreground="{StaticResource TextMuted}"/>
                                </StackPanel>
                                <TextBlock FontSize="19" FontWeight="Black">
                                    <Run Text="Sacale cada " Foreground="{StaticResource TextPrimary}"/>
                                    <Run Text="FPS" Foreground="{StaticResource Accent}"/>
                                    <Run Text=" a tu PC" Foreground="{StaticResource TextPrimary}"/>
                                </TextBlock>
                            </StackPanel>
                        </Border>
                        <StackPanel Name="GamingPanel"/>
                    </StackPanel>
                </ScrollViewer>
            </TabItem>
            <TabItem Header="💾  Espacio en Disco">
                <Grid Margin="14">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <Border Grid.Row="0" Background="{StaticResource BgPanel}" CornerRadius="10" Padding="14,10" Margin="0,0,0,12">
                        <StackPanel>
                            <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                                <Ellipse Width="6" Height="6" Fill="{StaticResource Accent}" VerticalAlignment="Center" Margin="0,0,6,0"/>
                                <TextBlock Text="DISCO · ESPACIO" FontFamily="Consolas" FontSize="10" Foreground="{StaticResource TextMuted}"/>
                            </StackPanel>
                            <TextBlock FontSize="19" FontWeight="Black">
                                <Run Text="Recupera tu espacio " Foreground="{StaticResource TextPrimary}"/>
                                <Run Text="perdido" Foreground="{StaticResource Accent}"/>
                            </TextBlock>
                        </StackPanel>
                    </Border>

                    <StackPanel Grid.Row="1" Name="DrivesPanel" Margin="0,0,0,12"/>

                    <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,0,0,12">
                        <Button Name="BtnDiskScan" Content="🔍 Analizar" Width="130" Padding="8" Margin="0,0,6,0"/>
                        <Button Name="BtnEmptyRecycleBin" Content="🗑 Papelera" Width="120" Padding="8" Margin="0,0,6,0"/>
                        <Button Name="BtnOpenDiskMgmt" Content="💽 Discos" Width="120" Padding="8" Margin="0,0,6,0"/>
                        <Button Name="BtnOpenCleanmgr" Content="🧹 Liberador Win" Width="140" Padding="8" Margin="0,0,6,0"/>
                        <Button Name="BtnDiskClean" Content="⚡ Liberar seleccionado" Width="180" Padding="8" Background="#2e7d32" Foreground="White" FontWeight="Bold"/>
                    </StackPanel>

                    <ScrollViewer Grid.Row="3" VerticalScrollBarVisibility="Auto">

                        <StackPanel Name="CleanupPanel" Margin="0,0,0,10"/>
                    </ScrollViewer>
                </Grid>
            </TabItem>
            <TabItem Header="🧠  RAM">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel Margin="18">
                        <Border Background="{StaticResource BgPanel}" CornerRadius="10" Padding="14,10" Margin="0,0,0,14">
                            <StackPanel>
                                <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                                    <Ellipse Width="6" Height="6" Fill="{StaticResource Accent}" VerticalAlignment="Center" Margin="0,0,6,0"/>
                                    <TextBlock Text="MEMORIA · EN VIVO" FontFamily="Consolas" FontSize="10" Foreground="{StaticResource TextMuted}"/>
                                </StackPanel>
                                <TextBlock FontSize="19" FontWeight="Black">
                                    <Run Text="Mira que esta usando tu " Foreground="{StaticResource TextPrimary}"/>
                                    <Run Text="RAM" Foreground="{StaticResource Accent}"/>
                                </TextBlock>
                            </StackPanel>
                        </Border>
                        <TextBlock Name="RamStatsText" Text="Cargando..." FontSize="14" Foreground="{StaticResource TextPrimary}" Margin="0,0,0,8" FontFamily="Consolas"/>
                        <ProgressBar Name="RamBar" Height="20" Minimum="0" Maximum="100" Value="0" Margin="0,0,0,18"/>

                        <TextBlock Text="Acciones" FontSize="15" FontWeight="Bold" Foreground="{StaticResource TextPrimary}" Margin="0,0,0,8"/>

                        <Button Name="BtnRamRefresh" Content="🔄 Actualizar ahora" Width="240" Padding="9" HorizontalAlignment="Left" Margin="0,0,0,10"/>

                        <Button Name="BtnRamFree" Content="🧠 Liberar RAM" Width="240" Padding="9" HorizontalAlignment="Left" Margin="0,0,0,4" Background="#2e7d32" Foreground="White"/>
                        <TextBlock Text="Le pide a cada proceso que devuelva memoria no usada activamente. Seguro, es lo mismo que hacen apps tipo 'RAM cleaner'." Foreground="{StaticResource TextMuted}" FontStyle="Italic" TextWrapping="Wrap" Margin="0,0,0,12" MaxWidth="480" HorizontalAlignment="Left"/>

                        <Button Name="BtnRamStandby" Content="🗑 Vaciar Standby List" Width="240" Padding="9" HorizontalAlignment="Left" Margin="0,0,0,4" Background="#8d6e00" Foreground="White"/>
                        <TextBlock Text="Vacia el cache de archivos que Windows guarda en RAM 'por si acaso'. Se libera mas RAM 'disponible', pero el sistema puede tardar un poco mas en volver a cachear esos archivos." Foreground="{StaticResource TextMuted}" FontStyle="Italic" TextWrapping="Wrap" Margin="0,0,0,12" MaxWidth="480" HorizontalAlignment="Left"/>

                        <Button Name="BtnRamExplorer" Content="🖥 Reiniciar Explorer.exe" Width="240" Padding="9" HorizontalAlignment="Left" Margin="0,0,0,4"/>
                        <TextBlock Text="Reinicia el escritorio y la barra de tareas. Utilizalo si notas el sistema lento o el explorador con fugas de memoria." Foreground="{StaticResource TextMuted}" FontStyle="Italic" TextWrapping="Wrap" Margin="0,0,0,10" MaxWidth="480" HorizontalAlignment="Left"/>
                    </StackPanel>
                </ScrollViewer>
            </TabItem>
            <TabItem Header="🔧  BIOS">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel Margin="18">
                        <Border Background="{StaticResource BgPanel}" CornerRadius="10" Padding="20" Margin="0,0,0,16">
                            <StackPanel>
                                <Border Background="#161616" CornerRadius="20" Padding="10,4" HorizontalAlignment="Left" Margin="0,0,0,12">
                                    <StackPanel Orientation="Horizontal">
                                        <Ellipse Width="6" Height="6" Fill="#ff1a1a" VerticalAlignment="Center" Margin="0,0,6,0"/>
                                        <TextBlock Text="GUIA DE BIOS · SOLO INFORMATIVO" FontFamily="Consolas" FontSize="10.5" Foreground="{StaticResource TextMuted}"/>
                                    </StackPanel>
                                </Border>
                                <TextBlock FontSize="28" FontWeight="Black">
                                    <Run Text="Ajustes de " Foreground="{StaticResource TextPrimary}"/>
                                    <Run Text="BIOS" Foreground="#ff1a1a"/>
                                    <Run Text=" que si importan" Foreground="{StaticResource TextPrimary}"/>
                                </TextBlock>
                                <TextBlock TextWrapping="Wrap" Foreground="{StaticResource TextMuted}" FontSize="12.5" Margin="0,8,0,0" MaxWidth="640">
                                    PC Optimizer no puede tocar tu BIOS desde Windows (cada placa madre tiene el suyo, distinto entre marcas). Esto es una guia: entras vos, apretando Supr/F2 al prender la PC, y buscas cada opcion en el menu de tu placa.
                                </TextBlock>
                            </StackPanel>
                        </Border>
                        <StackPanel Name="BiosPanel"/>
                    </StackPanel>
                </ScrollViewer>
            </TabItem>
            <TabItem Header="🔗  Herramientas">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel Margin="18">
                        <Border Background="{StaticResource BgPanel}" CornerRadius="10" Padding="14,10" Margin="0,0,0,12">
                            <StackPanel>
                                <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                                    <Ellipse Width="6" Height="6" Fill="{StaticResource Accent}" VerticalAlignment="Center" Margin="0,0,6,0"/>
                                    <TextBlock Text="HERRAMIENTAS · EXTERNAS" FontFamily="Consolas" FontSize="10" Foreground="{StaticResource TextMuted}"/>
                                </StackPanel>
                                <TextBlock FontSize="19" FontWeight="Black">
                                    <Run Text="Lo que yo mismo " Foreground="{StaticResource TextPrimary}"/>
                                    <Run Text="uso" Foreground="{StaticResource Accent}"/>
                                </TextBlock>
                            </StackPanel>
                        </Border>
                        <TextBlock Text="Solo son links a las paginas oficiales de cada programa. No se descarga ni se instala nada automaticamente - las abris vos y decidis si las usas." Foreground="{StaticResource TextMuted}" FontStyle="Italic" TextWrapping="Wrap" Margin="0,0,0,14"/>
                        <StackPanel Name="ToolsPanel"/>
                    </StackPanel>
                </ScrollViewer>
            </TabItem>
            <TabItem Header="🔬  Mantenimiento">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel Margin="18">
                        <Border Background="{StaticResource BgPanel}" CornerRadius="10" Padding="14,10" Margin="0,0,0,12">
                            <StackPanel>
                                <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                                    <Ellipse Width="6" Height="6" Fill="{StaticResource Accent}" VerticalAlignment="Center" Margin="0,0,6,0"/>
                                    <TextBlock Text="MANTENIMIENTO · DIAGNOSTICO" FontFamily="Consolas" FontSize="10" Foreground="{StaticResource TextMuted}"/>
                                </StackPanel>
                                <TextBlock FontSize="19" FontWeight="Black">
                                    <Run Text="Cuida y repara tu " Foreground="{StaticResource TextPrimary}"/>
                                    <Run Text="Windows" Foreground="{StaticResource Accent}"/>
                                </TextBlock>
                            </StackPanel>
                        </Border>
                        <TextBlock Text="Usan los comandos oficiales de Windows y no instalan nada. Lo que tarda corre en segundo plano y el avance se ve en el registro de abajo." Foreground="{StaticResource TextMuted}" FontSize="11.5" TextWrapping="Wrap" Margin="2,0,0,12"/>
                        <Border Background="{StaticResource BgPanel}" CornerRadius="10" Padding="14,12" Margin="0,0,0,10">
                            <StackPanel>
                                <TextBlock Text="Punto de restauracion" FontSize="14" FontWeight="Bold" Foreground="{StaticResource TextPrimary}"/>
                                <TextBlock Text="Guarda el estado de Windows ahora, por si despues queres volver atras. Windows permite crear uno cada 24 horas. Antes de aplicar cambios se crea solo si dejas tildado el casillero de la barra de abajo." FontSize="11.5" Foreground="{StaticResource TextMuted}" TextWrapping="Wrap" Margin="0,4,0,8"/>
                                <WrapPanel>
                                <Button Name="BtnRestorePoint" Style="{StaticResource BarGhostBtn}" Content="🛡  Crear punto ahora" Margin="0,0,8,6"/>
                                <Button Name="BtnRestoreOpen" Style="{StaticResource BarGhostBtn}" Content="Abrir Restauracion del sistema" Margin="0,0,8,6"/>
                                </WrapPanel>
                            </StackPanel>
                        </Border>
                        <Border Background="{StaticResource BgPanel}" CornerRadius="10" Padding="14,12" Margin="0,0,0,10">
                            <StackPanel>
                                <TextBlock Text="Reparar archivos de Windows" FontSize="14" FontWeight="Bold" Foreground="{StaticResource TextPrimary}"/>
                                <TextBlock Text="DISM repara la imagen de Windows y despues SFC revisa y repara los archivos del sistema. Puede tardar entre 10 y 30 minutos y necesita internet. Podes seguir usando la app mientras corre." FontSize="11.5" Foreground="{StaticResource TextMuted}" TextWrapping="Wrap" Margin="0,4,0,8"/>
                                <WrapPanel>
                                <Button Name="BtnMaintRepair" Style="{StaticResource BarGhostBtn}" Content="🔧  Reparar (DISM + SFC)" Margin="0,0,8,6"/>
                                <Button Name="BtnMaintSfcOnly" Style="{StaticResource BarGhostBtn}" Content="Solo comprobar (SFC)" Margin="0,0,8,6"/>
                                </WrapPanel>
                            </StackPanel>
                        </Border>
                        <Border Background="{StaticResource BgPanel}" CornerRadius="10" Padding="14,12" Margin="0,0,0,10">
                            <StackPanel>
                                <TextBlock Text="Salud del disco" FontSize="14" FontWeight="Bold" Foreground="{StaticResource TextPrimary}"/>
                                <TextBlock Text="Muestra el estado de salud de tus discos y comprueba errores del sistema de archivos en modo solo lectura: no modifica nada." FontSize="11.5" Foreground="{StaticResource TextMuted}" TextWrapping="Wrap" Margin="0,4,0,8"/>
                                <WrapPanel>
                                <Button Name="BtnMaintHealth" Style="{StaticResource BarGhostBtn}" Content="💾  Estado de salud" Margin="0,0,8,6"/>
                                <Button Name="BtnMaintChkdsk" Style="{StaticResource BarGhostBtn}" Content="Comprobar errores (solo lectura)" Margin="0,0,8,6"/>
                                </WrapPanel>
                            </StackPanel>
                        </Border>
                        <Border Background="{StaticResource BgPanel}" CornerRadius="10" Padding="14,12" Margin="0,0,0,10">
                            <StackPanel>
                                <TextBlock Text="Copia automatica del registro" FontSize="14" FontWeight="Bold" Foreground="{StaticResource TextPrimary}"/>
                                <TextBlock Text="Desde Windows 10 1803 el sistema ya no guarda copias del registro. Activandola, Windows copia el registro en la carpeta RegBack al reiniciar y luego una vez cada 10 dias, por si algo se rompe. Ocupa poco espacio." FontSize="11.5" Foreground="{StaticResource TextMuted}" TextWrapping="Wrap" Margin="0,4,0,8"/>
                                <TextBlock Name="RegBackStatus" Text="Estado: ..." FontSize="11.5" FontWeight="SemiBold" Foreground="{StaticResource TextPrimary}" Margin="0,0,0,8"/>
                                <WrapPanel>
                                <Button Name="BtnRegBackOn" Style="{StaticResource BarGhostBtn}" Content="Activar" Margin="0,0,8,6"/>
                                <Button Name="BtnRegBackOff" Style="{StaticResource BarGhostBtn}" Content="Desactivar" Margin="0,0,8,6"/>
                                <Button Name="BtnRegBackNow" Style="{StaticResource BarGhostBtn}" Content="Crear copia ahora" Margin="0,0,8,6"/>
                                </WrapPanel>
                            </StackPanel>
                        </Border>
                        <Border Background="{StaticResource BgPanel}" CornerRadius="10" Padding="14,12" Margin="0,0,0,10">
                            <StackPanel>
                                <TextBlock Text="Red" FontSize="14" FontWeight="Bold" Foreground="{StaticResource TextPrimary}"/>
                                <TextBlock Text="Vaciar la cache DNS es inmediato y soluciona paginas que no cargan. Restablecer la red (Winsock + IP) arregla fallas mas profundas, puede cortar la conexion un momento y requiere reiniciar la PC." FontSize="11.5" Foreground="{StaticResource TextMuted}" TextWrapping="Wrap" Margin="0,4,0,8"/>
                                <WrapPanel>
                                <Button Name="BtnNetDns" Style="{StaticResource BarGhostBtn}" Content="🌐  Vaciar DNS" Margin="0,0,8,6"/>
                                <Button Name="BtnNetReset" Style="{StaticResource BarGhostBtn}" Content="Restablecer red" Margin="0,0,8,6"/>
                                </WrapPanel>
                            </StackPanel>
                        </Border>
                        <Border Background="{StaticResource BgPanel}" CornerRadius="10" Padding="14,12" Margin="0,0,0,10">
                            <StackPanel>
                                <TextBlock Text="Diagnostico de Windows" FontSize="14" FontWeight="Bold" Foreground="{StaticResource TextPrimary}"/>
                                <TextBlock Text="Herramientas que ya trae Windows. El informe de rendimiento tarda unos 60 segundos en armarse y despues se abre solo. La prueba de memoria te pide reiniciar la PC." FontSize="11.5" Foreground="{StaticResource TextMuted}" TextWrapping="Wrap" Margin="0,4,0,8"/>
                                <WrapPanel>
                                <Button Name="BtnDiagReport" Style="{StaticResource BarGhostBtn}" Content="📊  Informe de rendimiento" Margin="0,0,8,6"/>
                                <Button Name="BtnDiagMem" Style="{StaticResource BarGhostBtn}" Content="Probar la RAM" Margin="0,0,8,6"/>
                                <Button Name="BtnDiagRes" Style="{StaticResource BarGhostBtn}" Content="Monitor de recursos" Margin="0,0,8,6"/>
                                </WrapPanel>
                            </StackPanel>
                        </Border>
                    </StackPanel>
                </ScrollViewer>
            </TabItem>
        </TabControl>

        <Grid Grid.Row="2" Margin="0,12,0,0">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Border Grid.Row="0" Background="{StaticResource BgPanel}" BorderBrush="{StaticResource BorderSubtle}" BorderThickness="1" CornerRadius="10" Padding="8" Margin="0,0,0,8">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" Orientation="Horizontal">
                        <Button Name="BtnSelectAll" Style="{StaticResource BarGhostBtn}" Content="☑  Marcar todo" Margin="0,0,8,0"/>
                        <Button Name="BtnSelectNone" Style="{StaticResource BarGhostBtn}" Content="☐  Desmarcar todo"/>
                    </StackPanel>
                    <Grid Grid.Column="1" Margin="14,0,14,0" VerticalAlignment="Center">
                        <CheckBox Name="ChkAutoRestore" IsChecked="True" Content="Crear punto de restauracion antes de aplicar" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="{StaticResource TextMuted}" FontSize="11.5" ToolTip="Crea un punto de restauracion de Windows antes de aplicar los cambios, para poder volver atras si algo no te gusta."/>
                        <StackPanel Name="ApplyProgressHost" Visibility="Collapsed" VerticalAlignment="Center">
                            <TextBlock Name="ApplyProgressText" Foreground="{StaticResource TextMuted}" FontSize="11" Margin="0,0,0,4" TextTrimming="CharacterEllipsis"/>
                            <ProgressBar Name="ApplyProgress" Height="6" Minimum="0" Maximum="100" Value="0"/>
                        </StackPanel>
                    </Grid>
                    <StackPanel Grid.Column="2" Orientation="Horizontal">
                        <Button Name="BtnQuick" Style="{StaticResource BarOutlineBtn}" Content="⚡" FontSize="16" Padding="13,5" Margin="0,0,8,0" ToolTip="Optimizacion rapida: aplica de una vez los tweaks y el debloat recomendados que todavia no tengas (te muestra la lista y pide confirmar)."/>
                        <Button Name="BtnUndo" Style="{StaticResource BarOutlineBtn}" Content="↺  Revertir" Margin="0,0,8,0"/>
                        <Button Name="BtnApply" Style="{StaticResource BarPrimaryBtn}" Content="⚡  Aplicar cambios"/>
                    </StackPanel>
                </Grid>
            </Border>
            <Border Grid.Row="1" Background="Black" CornerRadius="8" BorderBrush="{StaticResource BorderSubtle}" BorderThickness="1">
                <TextBox Name="LogBox" Background="Transparent" Foreground="#7CFC9A" FontFamily="Consolas" BorderThickness="0" Padding="8"
                          IsReadOnly="True" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"/>
            </Border>
        </Grid>
    </Grid>
</Window>
"@

$reader = (New-Object System.Xml.XmlNodeReader $xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$BloatPanel     = $window.FindName("BloatPanel")
$StdTweaksPanel = $window.FindName("StdTweaksPanel")
$AdvTweaksPanel = $window.FindName("AdvTweaksPanel")
$GamingPanel    = $window.FindName("GamingPanel")
$LogBox         = $window.FindName("LogBox")
$MainTabs       = $window.FindName("MainTabs")

# El contenido del Inicio no se estira solo al ancho de la pestana (queda del
# tamano de su contenido), asi que le fijamos el ancho a mano: ancho del
# TabControl menos la columna de la barra lateral (192) y los margenes (40).
$InicioRoot = $window.FindName("InicioRoot")
$MainTabs.Add_SizeChanged({
    $w = $MainTabs.ActualWidth - 192 - 40
    if ($w -gt 300) { $InicioRoot.Width = $w }
})
$RamStatsText   = $window.FindName("RamStatsText")
$RamBar         = $window.FindName("RamBar")
$DrivesPanel    = $window.FindName("DrivesPanel")
$CleanupPanel   = $window.FindName("CleanupPanel")
$ToolsPanel     = $window.FindName("ToolsPanel")
$BiosPanel      = $window.FindName("BiosPanel")
$GreetingText    = $window.FindName("GreetingText")
$CpuNameText     = $window.FindName("CpuNameText")
$CpuDetailText   = $window.FindName("CpuDetailText")
$CpuPercentText  = $window.FindName("CpuPercentText")
$MetricBarsCanvas = $window.FindName("MetricBarsCanvas")

function Update-UI {
    # Deja que la ventana se repinte (log, barra de progreso) mientras corre un proceso largo
    # en el hilo de la interfaz. Solo repinta: no procesa clics del usuario.
    try { $window.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Render) } catch { }
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "HH:mm:ss"
    $window.Dispatcher.Invoke([action]{
        $LogBox.AppendText("[$timestamp] $Message`r`n")
        $LogBox.ScrollToEnd()
    })
    if ($window.Dispatcher.CheckAccess()) { Update-UI }
}

# ---------------------------------------------------------------
# 5b. Riesgo y recomendacion de cada tweak (se muestran como insignias)
# ---------------------------------------------------------------
$TweakMeta = @{
    # Estandar
    "Deshabilitar Telemetria"                                         = @{ Risk = "Bajo";  Rec = $true  }
    "Deshabilitar Cortana"                                            = @{ Risk = "Bajo";  Rec = $true  }
    "Quitar Bing del buscador de Inicio"                              = @{ Risk = "Bajo";  Rec = $true  }
    "Quitar sugerencias y anuncios del menu Inicio"                   = @{ Risk = "Bajo";  Rec = $true  }
    "Desactivar instalacion automatica de apps (Consumer Features)"   = @{ Risk = "Bajo";  Rec = $true  }
    "Desactivar apps en segundo plano"                                = @{ Risk = "Medio"; Rec = $false }
    "Desactivar historial de actividades (Activity History)"          = @{ Risk = "Bajo";  Rec = $true  }
    "Desactivar ID de publicidad"                                     = @{ Risk = "Bajo";  Rec = $true  }
    "Ocultar Widgets de la barra de tareas"                           = @{ Risk = "Bajo";  Rec = $false }
    "Deshabilitar Game DVR / Xbox Game Bar (mas FPS)"                 = @{ Risk = "Bajo";  Rec = $false }
    "Deshabilitar hibernacion (libera espacio en disco)"              = @{ Risk = "Medio"; Rec = $false }
    "Efectos visuales: priorizar rendimiento"                         = @{ Risk = "Bajo";  Rec = $false }
    "Desactivar reporte de errores de Windows"                        = @{ Risk = "Bajo";  Rec = $true  }
    "Bloquear funciones de IA de Windows (Copilot/Recall)"            = @{ Risk = "Bajo";  Rec = $false }
    "Limpiar archivos temporales"                                     = @{ Risk = "Bajo";  Rec = $true  }
    # Avanzados
    "Restaurar menu contextual clasico (Windows 11)"                  = @{ Risk = "Bajo";  Rec = $false }
    "Deshabilitar Fast Startup (arranque rapido)"                     = @{ Risk = "Bajo";  Rec = $false }
    "Desactivar indexado de busqueda (Windows Search)"                = @{ Risk = "Medio"; Rec = $false }
    "Deshabilitar SMBv1 (proteccion, ya obsoleto)"                    = @{ Risk = "Bajo";  Rec = $true  }
    "Deshabilitar Nagle's Algorithm (menor latencia de red)"          = @{ Risk = "Medio"; Rec = $false }
    "Deshabilitar asistencia remota"                                  = @{ Risk = "Bajo";  Rec = $false }
    "Desactivar SysMain y Prefetcher (solo recomendado en SSD)"       = @{ Risk = "Medio"; Rec = $false }
    # Gaming / rendimiento
    "Activar plan de energia 'Ultimate Performance'"                  = @{ Risk = "Bajo";  Rec = $false }
    "Activar Game Mode de Windows"                                    = @{ Risk = "Bajo";  Rec = $true  }
    "Activar Hardware-Accelerated GPU Scheduling (HAGS)"              = @{ Risk = "Medio"; Rec = $false }
    "Desactivar Fullscreen Optimizations (global)"                    = @{ Risk = "Medio"; Rec = $false }
    "Priorizar juegos en el planificador multimedia"                  = @{ Risk = "Bajo";  Rec = $false }
    "Desactivar Network Throttling (multimedia/red)"                  = @{ Risk = "Bajo";  Rec = $false }
    "Reducir descargas P2P de Windows Update (Delivery Optimization)" = @{ Risk = "Bajo";  Rec = $true  }
    "Desactivar Core Parking (mantener todos los nucleos activos)"    = @{ Risk = "Medio"; Rec = $false }
    "Desactivar aceleracion del mouse (precision de puntero)"         = @{ Risk = "Bajo";  Rec = $false }
    "Desactivar USB Selective Suspend"                                = @{ Risk = "Bajo";  Rec = $false }
    "Activar optimizaciones para juegos en ventana (Windows 11)"      = @{ Risk = "Bajo";  Rec = $false }
    "Habilitar MSI Mode en la GPU (menos latencia de interrupciones)" = @{ Risk = "Medio"; Rec = $false }
    "[RIESGO] Desactivar Memory Integrity (Core Isolation)"           = @{ Risk = "Alto";  Rec = $false }
}

# Riesgo y recomendacion de cada categoria de Debloat (apps que se quitan)
$BloatMeta = @{
    "Xbox (App, Game Bar, Overlay)"                 = @{ Risk = "Medio"; Rec = $false }
    "Bing (Noticias, Clima, Finanzas, Deportes)"    = @{ Risk = "Bajo";  Rec = $true  }
    "Juegos preinstalados"                          = @{ Risk = "Bajo";  Rec = $true  }
    "Apps de terceros (patrocinadas)"               = @{ Risk = "Bajo";  Rec = $true  }
    "Skype / Teams (consumer)"                      = @{ Risk = "Bajo";  Rec = $true  }
    "Office Hub / OneNote UWP"                      = @{ Risk = "Bajo";  Rec = $true  }
    "Correo y Calendario (UWP)"                     = @{ Risk = "Medio"; Rec = $false }
    "3D Builder / Paint 3D / Mixed Reality"         = @{ Risk = "Bajo";  Rec = $true  }
    "Utilidades poco usadas"                        = @{ Risk = "Medio"; Rec = $false }
    "Cortana"                                       = @{ Risk = "Bajo";  Rec = $true  }
    "Widgets / News and Interests"                  = @{ Risk = "Bajo";  Rec = $false }
    "OneDrive (desinstalar completo)"               = @{ Risk = "Alto";  Rec = $false }
}

function New-Pill {
    param([string]$Text, [string]$Fg, [string]$Bg)
    $border = New-Object System.Windows.Controls.Border
    $border.CornerRadius = New-Object System.Windows.CornerRadius(9)
    $border.Padding = "7,1,7,1"; $border.Margin = "8,0,0,0"
    $border.VerticalAlignment = "Center"
    $border.Background = $Bg
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $Text; $label.FontSize = 10; $label.FontWeight = "Bold"
    $label.Foreground = $Fg
    $border.Child = $label
    return $border
}

function New-TweakBadges {
    param([string]$Name, [hashtable]$Table = $script:TweakMeta)
    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Orientation = "Horizontal"; $panel.VerticalAlignment = "Center"
    $meta = $Table[$Name]
    if ($meta) {
        switch ($meta.Risk) {
            "Bajo"  { [void]$panel.Children.Add((New-Pill "RIESGO BAJO"  "#4ade80" "#204ade80")) }
            "Medio" { [void]$panel.Children.Add((New-Pill "RIESGO MEDIO" "#facc15" "#20facc15")) }
            "Alto"  { [void]$panel.Children.Add((New-Pill "RIESGO ALTO"  "#ff5a5a" "#28ff5a5a")) }
        }
        if ($meta.Rec) { [void]$panel.Children.Add((New-Pill "★ RECOMENDADO" "#ffffff" "#99ff1a1a")) }
    }
    return $panel
}

# ---------------------------------------------------------------
# 5c. Perfiles de un clic (solo MARCAN opciones; aplicar sigue siendo manual)
# ---------------------------------------------------------------
$ProfileDefs = [ordered]@{}
$ProfileDefs["Equilibrado"] = @($TweakMeta.Keys | Where-Object { $TweakMeta[$_].Rec })
$ProfileDefs["Gaming"] = @($ProfileDefs["Equilibrado"]) + @(
    "Deshabilitar Game DVR / Xbox Game Bar (mas FPS)",
    "Efectos visuales: priorizar rendimiento",
    "Activar plan de energia 'Ultimate Performance'",
    "Priorizar juegos en el planificador multimedia",
    "Desactivar Network Throttling (multimedia/red)",
    "Desactivar aceleracion del mouse (precision de puntero)",
    "Activar optimizaciones para juegos en ventana (Windows 11)"
)
$ProfileDefs["Privacidad"] = @(
    "Deshabilitar Telemetria",
    "Deshabilitar Cortana",
    "Quitar Bing del buscador de Inicio",
    "Quitar sugerencias y anuncios del menu Inicio",
    "Desactivar instalacion automatica de apps (Consumer Features)",
    "Desactivar historial de actividades (Activity History)",
    "Desactivar ID de publicidad",
    "Desactivar reporte de errores de Windows",
    "Bloquear funciones de IA de Windows (Copilot/Recall)",
    "Deshabilitar asistencia remota"
)

function Set-TweakProfile {
    param([string]$ProfileName)
    # Primero se limpia lo marcado antes (debloat y tweaks) para que el perfil sea exactamente lo que se ve
    foreach ($dict in @($BloatCheckboxes, $StdCheckboxes, $AdvCheckboxes, $GamingCheckboxes)) {
        foreach ($cb in $dict.Values) { $cb.IsChecked = $false }
    }
    $count = 0
    foreach ($n in $ProfileDefs[$ProfileName]) {
        foreach ($dict in @($StdCheckboxes, $AdvCheckboxes, $GamingCheckboxes)) {
            if ($dict.ContainsKey($n)) { $dict[$n].IsChecked = $true; $count++; break }
        }
    }
    Write-Log "Perfil '$ProfileName' cargado: $count cambio(s) marcado(s) (se desmarco lo anterior)."
    Write-Log "  Revisalos en las pestanas de Tweaks y presiona 'Aplicar cambios' cuando quieras."
}

$window.FindName("BtnProfileBalanced").Add_Click({ Set-TweakProfile -ProfileName "Equilibrado" })
$window.FindName("BtnProfileGaming").Add_Click({ Set-TweakProfile -ProfileName "Gaming" })
$window.FindName("BtnProfilePrivacy").Add_Click({ Set-TweakProfile -ProfileName "Privacidad" })

# ---------------------------------------------------------------
# 5d. Punto de restauracion (en hilo aparte) y barra de progreso al aplicar
# ---------------------------------------------------------------
function New-RestorePointSafe {
    # Crear el punto puede tardar: se hace en otro hilo mientras la ventana sigue repintando
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        $ErrorActionPreference = "Stop"
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "Antes de PC Optimizer" -RestorePointType "MODIFY_SETTINGS" -WarningAction Continue
    })
    $handle = $ps.BeginInvoke()
    while (-not $handle.IsCompleted) { Update-UI; Start-Sleep -Milliseconds 120 }
    $result = [pscustomobject]@{ Ok = $true; Warning = ""; Error = "" }
    try { [void]$ps.EndInvoke($handle) } catch {
        $result.Ok = $false
        $result.Error = $_.Exception.Message
        if ($_.Exception.InnerException) { $result.Error = $_.Exception.InnerException.Message }
    }
    if ($result.Ok) {
        $warn = @($ps.Streams.Warning | ForEach-Object { $_.Message }) -join " "
        if ($warn) { $result.Warning = $warn }
    }
    $ps.Dispose()
    return $result
}

$ApplyProgressHost = $window.FindName("ApplyProgressHost")
$ApplyProgressText = $window.FindName("ApplyProgressText")
$ApplyProgress     = $window.FindName("ApplyProgress")
$ChkAutoRestore    = $window.FindName("ChkAutoRestore")
$script:ApplyDone  = 0
$script:ApplyTotal = 0

function Start-ApplyProgress {
    param([int]$Total)
    $script:ApplyDone = 0; $script:ApplyTotal = $Total
    $ApplyProgress.Maximum = [Math]::Max(1, $Total); $ApplyProgress.Value = 0
    $ApplyProgressText.Text = "Preparando..."
    $ChkAutoRestore.Visibility = "Collapsed"; $ApplyProgressHost.Visibility = "Visible"
    Update-UI
}

function Step-ApplyProgress {
    param([string]$Label)
    $script:ApplyDone++
    $ApplyProgress.Value = [Math]::Max(0, $script:ApplyDone - 1)
    $ApplyProgressText.Text = "$($script:ApplyDone) de $($script:ApplyTotal)  -  $Label"
    Update-UI
}

function Stop-ApplyProgress {
    param([switch]$Completed)
    if ($Completed) { $ApplyProgress.Value = $ApplyProgress.Maximum; Update-UI; Start-Sleep -Milliseconds 400 }
    $ApplyProgressHost.Visibility = "Collapsed"; $ChkAutoRestore.Visibility = "Visible"
}

# ---------------------------------------------------------------
# 6. Generar checkboxes dinamicamente
# ---------------------------------------------------------------
$BloatCheckboxes = @{}
$BloatStatusLabels = @{}
foreach ($category in $BloatwareList.Keys) {
    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = "Horizontal"; $row.Margin = "0,4,0,4"
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $category
    $cb.Foreground = "White"; $cb.FontSize = 14; $cb.VerticalAlignment = "Center"
    $row.Children.Add($cb) | Out-Null
    $row.Children.Add((New-TweakBadges -Name $category -Table $BloatMeta)) | Out-Null
    $status = New-Object System.Windows.Controls.TextBlock
    $status.Text = "consultando..."; $status.Foreground = "#9a9a9a"
    $status.FontSize = 12; $status.FontWeight = "SemiBold"
    $status.Margin = "10,0,0,0"; $status.VerticalAlignment = "Center"
    $status.Background = "Transparent"
    $row.Children.Add($status) | Out-Null
    $BloatPanel.Children.Add($row) | Out-Null
    $BloatCheckboxes[$category] = $cb
    $BloatStatusLabels[$category] = $status
}

$StdCheckboxes = @{}
$StdStatusLabels = @{}
foreach ($name in $StandardTweaks.Keys) {
    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = "Horizontal"; $row.Margin = "0,4,0,4"
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $name
    $cb.Foreground = "White"; $cb.FontSize = 14; $cb.VerticalAlignment = "Center"
    $status = New-Object System.Windows.Controls.TextBlock
    $status.Text = ""; $status.Margin = "10,0,0,0"; $status.FontSize = 12; $status.FontWeight = "SemiBold"; $status.VerticalAlignment = "Center"
    $row.Children.Add($cb) | Out-Null
    $row.Children.Add((New-TweakBadges -Name $name)) | Out-Null
    $row.Children.Add($status) | Out-Null
    $StdTweaksPanel.Children.Add($row) | Out-Null
    $StdCheckboxes[$name] = $cb
    $StdStatusLabels[$name] = $status
}

$AdvCheckboxes = @{}
$AdvStatusLabels = @{}
foreach ($name in $AdvancedTweaks.Keys) {
    $stack = New-Object System.Windows.Controls.StackPanel
    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = "Horizontal"; $row.Margin = "0,4,0,0"
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $name
    $cb.Foreground = "Orange"; $cb.FontWeight = "Bold"; $cb.FontSize = 14; $cb.VerticalAlignment = "Center"
    $status = New-Object System.Windows.Controls.TextBlock
    $status.Text = ""; $status.Margin = "10,0,0,0"; $status.FontSize = 12; $status.FontWeight = "SemiBold"; $status.VerticalAlignment = "Center"
    $row.Children.Add($cb) | Out-Null
    $row.Children.Add((New-TweakBadges -Name $name)) | Out-Null
    $row.Children.Add($status) | Out-Null
    $warn = New-Object System.Windows.Controls.TextBlock
    $warn.Text = "  " + $AdvancedTweaks[$name].Warning
    $warn.Foreground = "Gray"; $warn.Margin = "20,0,0,6"; $warn.FontStyle = "Italic"; $warn.TextWrapping = "Wrap"
    $stack.Children.Add($row) | Out-Null
    $stack.Children.Add($warn) | Out-Null
    $AdvTweaksPanel.Children.Add($stack) | Out-Null
    $AdvCheckboxes[$name] = $cb
    $AdvStatusLabels[$name] = $status
}

$GamingCheckboxes = @{}
$GamingStatusLabels = @{}
foreach ($name in $GamingTweaks.Keys) {
    $stack = New-Object System.Windows.Controls.StackPanel
    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = "Horizontal"; $row.Margin = "0,4,0,0"
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $name
    if ($GamingTweaks[$name].Danger) { $cb.Foreground = "Red" } else { $cb.Foreground = "#d4d4d8" }
    $cb.FontWeight = "Bold"; $cb.FontSize = 14; $cb.VerticalAlignment = "Center"
    $status = New-Object System.Windows.Controls.TextBlock
    $status.Text = ""; $status.Margin = "10,0,0,0"; $status.FontSize = 12; $status.FontWeight = "SemiBold"; $status.VerticalAlignment = "Center"
    $row.Children.Add($cb) | Out-Null
    $row.Children.Add((New-TweakBadges -Name $name)) | Out-Null
    $row.Children.Add($status) | Out-Null
    $warn = New-Object System.Windows.Controls.TextBlock
    $warn.Text = "  " + $GamingTweaks[$name].Warning
    $warn.Foreground = "Gray"; $warn.Margin = "20,0,0,6"; $warn.FontStyle = "Italic"; $warn.TextWrapping = "Wrap"
    $stack.Children.Add($row) | Out-Null
    $stack.Children.Add($warn) | Out-Null
    $GamingPanel.Children.Add($stack) | Out-Null
    $GamingCheckboxes[$name] = $cb
    $GamingStatusLabels[$name] = $status
}

$CleanupCheckboxes = @{}
$CleanupSizeLabels = @{}
foreach ($name in $CleanupCategories.Keys) {
    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = "Horizontal"; $row.Margin = "0,4,0,4"
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $name; $cb.Foreground = "White"; $cb.FontSize = 14; $cb.Width = 400
    $sizeLbl = New-Object System.Windows.Controls.TextBlock
    $sizeLbl.Text = "sin analizar"; $sizeLbl.Foreground = "Gray"; $sizeLbl.FontFamily = "Consolas"; $sizeLbl.VerticalAlignment = "Center"
    $row.Children.Add($cb) | Out-Null
    $row.Children.Add($sizeLbl) | Out-Null
    $CleanupPanel.Children.Add($row) | Out-Null
    $CleanupCheckboxes[$name] = $cb
    $CleanupSizeLabels[$name] = $sizeLbl
}

foreach ($name in $BiosGuide.Keys) {
    $item = $BiosGuide[$name]
    $card = New-Object System.Windows.Controls.Border
    $card.Background = "#141414"; $card.CornerRadius = 8; $card.Padding = "14"; $card.Margin = "0,0,0,8"
    $grid = New-Object System.Windows.Controls.Grid
    $col1 = New-Object System.Windows.Controls.ColumnDefinition; $col1.Width = "Auto"
    $col2 = New-Object System.Windows.Controls.ColumnDefinition; $col2.Width = "*"
    $col3 = New-Object System.Windows.Controls.ColumnDefinition; $col3.Width = "Auto"
    $grid.ColumnDefinitions.Add($col1) | Out-Null
    $grid.ColumnDefinitions.Add($col2) | Out-Null
    $grid.ColumnDefinitions.Add($col3) | Out-Null

    $check = New-Object System.Windows.Controls.Border
    $check.Width = 20; $check.Height = 20; $check.CornerRadius = 10; $check.Background = "#ff1a1a"
    $check.VerticalAlignment = "Top"; $check.Margin = "0,2,10,0"
    $checkTxt = New-Object System.Windows.Controls.TextBlock
    $checkTxt.Text = [char]0x2713; $checkTxt.Foreground = "White"; $checkTxt.FontSize = 11; $checkTxt.FontWeight = "Bold"
    $checkTxt.HorizontalAlignment = "Center"; $checkTxt.VerticalAlignment = "Center"
    $check.Child = $checkTxt
    [System.Windows.Controls.Grid]::SetColumn($check, 0)

    $textStack = New-Object System.Windows.Controls.StackPanel
    $nameLbl = New-Object System.Windows.Controls.TextBlock
    $nameLbl.Text = $name; $nameLbl.Foreground = "White"; $nameLbl.FontWeight = "Bold"; $nameLbl.FontSize = 13.5; $nameLbl.TextWrapping = "Wrap"
    $descLbl = New-Object System.Windows.Controls.TextBlock
    $descLbl.Text = $item.Impact; $descLbl.Foreground = "Gray"; $descLbl.TextWrapping = "Wrap"; $descLbl.Margin = "0,4,0,0"; $descLbl.MaxWidth = 620; $descLbl.FontSize = 12
    $textStack.Children.Add($nameLbl) | Out-Null
    $textStack.Children.Add($descLbl) | Out-Null
    [System.Windows.Controls.Grid]::SetColumn($textStack, 1)

    $riskColor = switch ($item.Risk) { "Bajo" { "#166534" } "Medio" { "#854d0e" } default { "#7f1d1d" } }
    $riskFg    = switch ($item.Risk) { "Bajo" { "#4ade80" } "Medio" { "#facc15" } default { "#f87171" } }
    $riskBadge = New-Object System.Windows.Controls.Border
    $riskBadge.Background = $riskColor; $riskBadge.CornerRadius = 10; $riskBadge.Padding = "8,3"; $riskBadge.VerticalAlignment = "Top"; $riskBadge.Margin = "10,2,0,0"
    $riskTxt = New-Object System.Windows.Controls.TextBlock
    $riskTxt.Text = "Riesgo: $($item.Risk)"; $riskTxt.Foreground = $riskFg; $riskTxt.FontSize = 10.5; $riskTxt.FontWeight = "Bold"
    $riskBadge.Child = $riskTxt
    [System.Windows.Controls.Grid]::SetColumn($riskBadge, 2)

    $grid.Children.Add($check) | Out-Null
    $grid.Children.Add($textStack) | Out-Null
    $grid.Children.Add($riskBadge) | Out-Null
    $card.Child = $grid
    $BiosPanel.Children.Add($card) | Out-Null
}

foreach ($name in $RecommendedTools.Keys) {
    $tool = $RecommendedTools[$name]
    $card = New-Object System.Windows.Controls.Border
    $card.Background = "#141414"; $card.CornerRadius = 8; $card.Padding = "12"; $card.Margin = "0,0,0,8"
    $grid = New-Object System.Windows.Controls.Grid
    $col1 = New-Object System.Windows.Controls.ColumnDefinition; $col1.Width = "*"
    $col2 = New-Object System.Windows.Controls.ColumnDefinition; $col2.Width = "Auto"
    $grid.ColumnDefinitions.Add($col1) | Out-Null
    $grid.ColumnDefinitions.Add($col2) | Out-Null
    $textStack = New-Object System.Windows.Controls.StackPanel
    $nameLbl = New-Object System.Windows.Controls.TextBlock
    $nameLbl.Text = $name; $nameLbl.Foreground = "#f87171"; $nameLbl.FontWeight = "Bold"; $nameLbl.FontSize = 14
    $descLbl = New-Object System.Windows.Controls.TextBlock
    $descLbl.Text = $tool.Desc; $descLbl.Foreground = "Gray"; $descLbl.TextWrapping = "Wrap"; $descLbl.Margin = "0,3,0,0"; $descLbl.MaxWidth = 460
    $textStack.Children.Add($nameLbl) | Out-Null
    $textStack.Children.Add($descLbl) | Out-Null
    [System.Windows.Controls.Grid]::SetColumn($textStack, 0)
    $openBtn = New-Object System.Windows.Controls.Button
    $openBtn.Content = "Abrir sitio"; $openBtn.Width = 110; $openBtn.Padding = "6"; $openBtn.VerticalAlignment = "Center"
    [System.Windows.Controls.Grid]::SetColumn($openBtn, 1)
    $url = $tool.Url
    $openBtn.Add_Click({ Start-Process $url }.GetNewClosure())
    $grid.Children.Add($textStack) | Out-Null
    $grid.Children.Add($openBtn) | Out-Null
    $card.Child = $grid
    $ToolsPanel.Children.Add($card) | Out-Null
}

# ---------------------------------------------------------------
# 7. Logica de botones
# ---------------------------------------------------------------

# Estado de los tweaks (Activo/Inactivo). Se consulta en un hilo aparte para que la
# interfaz no se trabe al cambiar de pestana (algunos chequeos, como SMB1, son lentos).
$script:StatusJobs = New-Object System.Collections.ArrayList
$script:StatusGen  = @{}
$script:StatusLast = @{}

$script:StatusTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:StatusTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$script:TweakState = @{}
$script:StatusTimer.Add_Tick({
    $applied = $false
    foreach ($job in @($script:StatusJobs)) {
        if (-not $job.Handle.IsCompleted) { continue }
        $script:StatusJobs.Remove($job)
        $map = @{}
        try {
            $res = $job.PS.EndInvoke($job.Handle)
            if ($res -and $res.Count -gt 0) { $map = [hashtable]$res[0] }
        } catch { }
        try { $job.PS.Dispose() } catch { }
        # Si mientras tanto se pidio una consulta mas nueva, este resultado ya esta viejo
        if ($script:StatusGen[$job.Key] -ne $job.Gen) { continue }
        foreach ($name in @($job.Labels.Keys)) {
            $lbl = $job.Labels[$name]
            if (-not $lbl) { continue }
            $state = $map[$name]
            $script:TweakState[$name] = $state
            $applied = $true
            if ($state -eq $true)      { $lbl.Text = "● Activo";   $lbl.Foreground = "#4ade80" }
            elseif ($state -eq $false) { $lbl.Text = "○ Inactivo"; $lbl.Foreground = "#6b7280" }
            else                       { $lbl.Text = "" }
        }
    }
    if ($applied) { Update-ScoreCard }
    if ($script:StatusJobs.Count -eq 0) { $script:StatusTimer.Stop() }
})

function Update-TweakStatuses {
    param([hashtable]$TweaksDict, [hashtable]$StatusLabelsDict)
    $key = [string]$TweaksDict.GetHashCode()
    $gen = 1 + [int]$script:StatusGen[$key]
    $script:StatusGen[$key]  = $gen
    $script:StatusLast[$key] = [DateTime]::UtcNow
    $checks = @{}
    foreach ($name in $TweaksDict.Keys) {
        $sb = $TweaksDict[$name].Status
        if ($sb) { $checks[$name] = $sb.ToString() }
    }
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        param($checks)
        $out = @{}
        foreach ($n in @($checks.Keys)) {
            try { $out[$n] = & ([scriptblock]::Create($checks[$n])) } catch { $out[$n] = $null }
        }
        $out
    }).AddArgument($checks)
    $handle = $ps.BeginInvoke()
    [void]$script:StatusJobs.Add([pscustomobject]@{ PS = $ps; Handle = $handle; Key = $key; Gen = $gen; Labels = $StatusLabelsDict })
    $script:StatusTimer.Start()
}

# Al entrar a una pestana solo se vuelve a consultar si pasaron mas de 20 segundos
function Request-TweakStatuses {
    param([hashtable]$TweaksDict, [hashtable]$StatusLabelsDict)
    $last = $script:StatusLast[[string]$TweaksDict.GetHashCode()]
    if ($last -and (([DateTime]::UtcNow - $last).TotalSeconds -lt 20)) { return }
    Update-TweakStatuses -TweaksDict $TweaksDict -StatusLabelsDict $StatusLabelsDict
}

$MainTabs.Add_SelectionChanged({
    switch ($MainTabs.SelectedIndex) {
        0 {
            Request-TweakStatuses -TweaksDict $StandardTweaks -StatusLabelsDict $StdStatusLabels
            Request-TweakStatuses -TweaksDict $AdvancedTweaks -StatusLabelsDict $AdvStatusLabels
            Request-TweakStatuses -TweaksDict $GamingTweaks -StatusLabelsDict $GamingStatusLabels
        }
        1 { Request-BloatStatuses }
        2 { Request-TweakStatuses -TweaksDict $StandardTweaks -StatusLabelsDict $StdStatusLabels }
        3 { Request-TweakStatuses -TweaksDict $AdvancedTweaks -StatusLabelsDict $AdvStatusLabels }
        4 { Request-TweakStatuses -TweaksDict $GamingTweaks -StatusLabelsDict $GamingStatusLabels }
        6 { Update-RamDisplay | Out-Null }
        9 { Update-RegBackStatus }
    }
})

$window.FindName("BtnSelectAll").Add_Click({
    switch ($MainTabs.SelectedIndex) {
        1 { foreach ($cb in $BloatCheckboxes.Values) { $cb.IsChecked = $true } }
        2 { foreach ($cb in $StdCheckboxes.Values)   { $cb.IsChecked = $true } }
        3 { foreach ($cb in $AdvCheckboxes.Values)   { $cb.IsChecked = $true } }
        4 { foreach ($cb in $GamingCheckboxes.Values) { $cb.IsChecked = $true } }
        5 { foreach ($cb in $CleanupCheckboxes.Values) { $cb.IsChecked = $true } }
    }
})

$window.FindName("BtnSelectNone").Add_Click({
    switch ($MainTabs.SelectedIndex) {
        1 { foreach ($cb in $BloatCheckboxes.Values) { $cb.IsChecked = $false } }
        2 { foreach ($cb in $StdCheckboxes.Values)   { $cb.IsChecked = $false } }
        3 { foreach ($cb in $AdvCheckboxes.Values)   { $cb.IsChecked = $false } }
        4 { foreach ($cb in $GamingCheckboxes.Values) { $cb.IsChecked = $false } }
        5 { foreach ($cb in $CleanupCheckboxes.Values) { $cb.IsChecked = $false } }
    }
})



$window.FindName("BtnRestorePoint").Add_Click({
    $b = $window.FindName("BtnRestorePoint"); $b.IsEnabled = $false
    Write-Log "Creando punto de restauracion del sistema (puede tardar unos segundos)..."
    $rp = New-RestorePointSafe
    if (-not $rp.Ok)         { Write-Log "No se pudo crear el punto de restauracion: $($rp.Error)" }
    elseif ($rp.Warning)     { Write-Log "Windows no creo un punto nuevo: ya existe uno reciente (limite de uno cada 24 h)." }
    else                     { Write-Log "Punto de restauracion creado correctamente." }
    $b.IsEnabled = $true
})

$window.FindName("BtnApply").Add_Click({
    $btn = $window.FindName("BtnApply"); $btn.IsEnabled = $false

    $allBoxes = @($BloatCheckboxes.Values) + @($StdCheckboxes.Values) + @($AdvCheckboxes.Values) + @($GamingCheckboxes.Values)
    $total = @($allBoxes | Where-Object { $_.IsChecked }).Count
    if ($total -eq 0) {
        Write-Log "No hay nada marcado para aplicar. Marca opciones en las pestanas o carga un perfil desde Inicio."
        $btn.IsEnabled = $true
        return
    }

    $autoRestore = [bool]$ChkAutoRestore.IsChecked
    Start-ApplyProgress -Total ($total + [int]$autoRestore)
    if ($autoRestore) {
        Step-ApplyProgress "Punto de restauracion"
        Write-Log "Creando punto de restauracion antes de aplicar (puede tardar unos segundos)..."
        $rp = New-RestorePointSafe
        if (-not $rp.Ok) {
            Write-Log "No se pudo crear el punto de restauracion: $($rp.Error)"
            $ans = [System.Windows.MessageBox]::Show("No se pudo crear el punto de restauracion.`n`nDetalle: $($rp.Error)`n`nAplicar los cambios igual?", "PC Optimizer", "YesNo", "Warning")
            if ($ans -ne "Yes") {
                Write-Log "Aplicacion cancelada."
                Stop-ApplyProgress
                $btn.IsEnabled = $true
                return
            }
        }
        elseif ($rp.Warning) { Write-Log "Windows no creo un punto nuevo (ya existe uno reciente, limite de uno cada 24 h). Se continua igual." }
        else { Write-Log "Punto de restauracion creado." }
    }

    # Debloat
    foreach ($category in $BloatCheckboxes.Keys) {
        if ($BloatCheckboxes[$category].IsChecked) {
            Write-Log "Quitando: $category"
            Step-ApplyProgress "Quitando: $category"

            if ($category -eq "OneDrive (desinstalar completo)") {
                try {
                    Write-Log "  - Cerrando OneDrive..."
                    Stop-Process -Name "OneDrive" -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Milliseconds 500

                    $setupPaths = @(
                        "$env:SystemRoot\SysWOW64\OneDriveSetup.exe",
                        "$env:SystemRoot\System32\OneDriveSetup.exe",
                        "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDriveSetup.exe"
                    )
                    $ranUninstall = $false
                    foreach ($setupPath in $setupPaths) {
                        if (Test-Path $setupPath) {
                            Write-Log "  - Ejecutando desinstalador ($setupPath)..."
                            Start-Process $setupPath -ArgumentList "/uninstall" -Wait -ErrorAction SilentlyContinue
                            $ranUninstall = $true
                        }
                    }
                    if (-not $ranUninstall) { Write-Log "  (no se encontro OneDriveSetup.exe, puede que ya este desinstalado)" }

                    # Saca el icono de "OneDrive" del panel izquierdo del Explorador
                    Remove-Item "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{018D5C66-4533-4307-9B53-224DE2ED1FE6}" -Recurse -Force -ErrorAction SilentlyContinue
                    Remove-Item "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{018D5C66-4533-4307-9B53-224DE2ED1FE6}" -Recurse -Force -ErrorAction SilentlyContinue

                    # Limpia carpetas de la instalacion (NO borra tu carpeta de archivos OneDrive con tus documentos)
                    Remove-Item "$env:LOCALAPPDATA\Microsoft\OneDrive" -Recurse -Force -ErrorAction SilentlyContinue
                    Remove-Item "$env:PROGRAMDATA\Microsoft OneDrive" -Recurse -Force -ErrorAction SilentlyContinue

                    # Bloquea por politica que se vuelva a instalar solo (recomendado oficialmente por Microsoft)
                    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive" -Force | Out-Null
                    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive" -Name "DisableFileSyncNGSC" -Value 1 -Type DWord -Force

                    Write-Log "  -> OneDrive desinstalado y bloqueado para que no vuelva a aparecer solo."
                    Write-Log "  (Tu carpeta de archivos, si tenias, sigue intacta en tu perfil de usuario por si necesitas mover algo de ahi)."
                } catch {
                    Write-Log "  Error desinstalando OneDrive: $($_.Exception.Message)"
                }
                continue
            }

            $removedCount = 0
            foreach ($pkgPattern in $BloatwareList[$category]) {
                try {
                    $installed = Get-AppxPackage -Name $pkgPattern -AllUsers -ErrorAction SilentlyContinue
                    if ($installed) {
                        foreach ($p in $installed) {
                            Write-Log "  - Desinstalando $($p.Name)..."
                            $p | Remove-AppxPackage -ErrorAction SilentlyContinue
                            $removedCount++
                        }
                    }
                    $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $pkgPattern }
                    if ($provisioned) {
                        foreach ($pp in $provisioned) {
                            Write-Log "  - Quitando paquete aprovisionado $($pp.DisplayName)..."
                            Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -ErrorAction SilentlyContinue | Out-Null
                        }
                    }
                } catch { Write-Log "  Error con $pkgPattern : $($_.Exception.Message)" }
            }
            if ($removedCount -eq 0) { Write-Log "  (nada que quitar en '$category', no estaba instalado)" }
            else { Write-Log "  -> $removedCount app(s) removidas de '$category'." }
        }
    }

    # Tweaks estandar
    foreach ($name in $StdCheckboxes.Keys) {
        if ($StdCheckboxes[$name].IsChecked) {
            Write-Log "Aplicando tweak: $name"
            Step-ApplyProgress $name
            try { & $StandardTweaks[$name].Invoke; Write-Log "  OK: $name" }
            catch { Write-Log "  Error en '$name': $($_.Exception.Message)" }
        }
    }

    # Tweaks avanzados
    foreach ($name in $AdvCheckboxes.Keys) {
        if ($AdvCheckboxes[$name].IsChecked) {
            Write-Log "Aplicando tweak avanzado: $name"
            Step-ApplyProgress $name
            try { & $AdvancedTweaks[$name].Invoke; Write-Log "  OK: $name" }
            catch { Write-Log "  Error en '$name': $($_.Exception.Message)" }
        }
    }

    # Tweaks de gaming / rendimiento
    foreach ($name in $GamingCheckboxes.Keys) {
        if ($GamingCheckboxes[$name].IsChecked) {
            Write-Log "Aplicando tweak de gaming: $name"
            Step-ApplyProgress $name
            try { & $GamingTweaks[$name].Invoke; Write-Log "  OK: $name" }
            catch { Write-Log "  Error en '$name': $($_.Exception.Message)" }
        }
    }

    Stop-ApplyProgress -Completed
    Write-Log "Proceso finalizado. Algunos cambios requieren reiniciar el equipo."
    Update-TweakStatuses -TweaksDict $StandardTweaks -StatusLabelsDict $StdStatusLabels
    Update-TweakStatuses -TweaksDict $AdvancedTweaks -StatusLabelsDict $AdvStatusLabels
    Update-TweakStatuses -TweaksDict $GamingTweaks -StatusLabelsDict $GamingStatusLabels
    Update-BloatStatuses
    $btn.IsEnabled = $true
})

$window.FindName("BtnUndo").Add_Click({
    $btn = $window.FindName("BtnUndo"); $btn.IsEnabled = $false

    foreach ($name in $StdCheckboxes.Keys) {
        if ($StdCheckboxes[$name].IsChecked) {
            Write-Log "Revirtiendo tweak: $name"
            try { & $StandardTweaks[$name].Undo; Write-Log "  Revertido: $name" }
            catch { Write-Log "  Error al revertir '$name': $($_.Exception.Message)" }
        }
    }
    foreach ($name in $AdvCheckboxes.Keys) {
        if ($AdvCheckboxes[$name].IsChecked) {
            Write-Log "Revirtiendo tweak avanzado: $name"
            try { & $AdvancedTweaks[$name].Undo; Write-Log "  Revertido: $name" }
            catch { Write-Log "  Error al revertir '$name': $($_.Exception.Message)" }
        }
    }
    foreach ($name in $GamingCheckboxes.Keys) {
        if ($GamingCheckboxes[$name].IsChecked) {
            Write-Log "Revirtiendo tweak de gaming: $name"
            try { & $GamingTweaks[$name].Undo; Write-Log "  Revertido: $name" }
            catch { Write-Log "  Error al revertir '$name': $($_.Exception.Message)" }
        }
    }
    Write-Log "Reversion finalizada (nota: el debloat de apps no se puede revertir automaticamente)."
    Update-TweakStatuses -TweaksDict $StandardTweaks -StatusLabelsDict $StdStatusLabels
    Update-TweakStatuses -TweaksDict $AdvancedTweaks -StatusLabelsDict $AdvStatusLabels
    Update-TweakStatuses -TweaksDict $GamingTweaks -StatusLabelsDict $GamingStatusLabels
    $btn.IsEnabled = $true
})

function Update-DrivesPanel {
    $window.Dispatcher.Invoke([action]{
        $DrivesPanel.Children.Clear()
        foreach ($d in (Get-DrivesInfo)) {
            $title = New-Object System.Windows.Controls.TextBlock
            $title.Text = "Unidad $($d.Letter)   $($d.UsedGB) GB usados de $($d.TotalGB) GB  (libres: $($d.FreeGB) GB)"
            $title.Foreground = "White"; $title.FontFamily = "Consolas"; $title.Margin = "0,4,0,2"
            $bar = New-Object System.Windows.Controls.ProgressBar
            $bar.Minimum = 0; $bar.Maximum = 100; $bar.Value = $d.PercentUsed; $bar.Height = 16; $bar.Margin = "0,0,0,6"
            $DrivesPanel.Children.Add($title) | Out-Null
            $DrivesPanel.Children.Add($bar) | Out-Null
        }
    })
}

# ---------------------------------------------------------------
# Tareas de disco en segundo plano (analisis y limpieza) para no congelar la ventana.
# El trabajo corre en otro hilo y manda mensajes por una cola; un timer los vuelca al log.
# ---------------------------------------------------------------
$script:BgJob = $null
$script:OldGpuPackages = @()

$script:BgTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:BgTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$script:BgTimer.Add_Tick({
    $job = $script:BgJob
    if (-not $job) { $script:BgTimer.Stop(); return }
    $finished = $job.Handle.IsCompleted
    $item = $null
    while ($job.Queue.TryDequeue([ref]$item)) {
        try {
            switch ($item.T) {
                "log"   { Write-Log $item.M }
                "label" { $CleanupSizeLabels[$item.Name].Text = $item.Text }
                "drivers" { $script:OldGpuPackages = @($item.List) }
            }
        } catch { }
    }
    if ($finished) {
        try { [void]$job.PS.EndInvoke($job.Handle) } catch { Write-Log "Error en la tarea: $($_.Exception.Message)" }
        try { $job.PS.Dispose() } catch { }
        $script:BgJob = $null
        $script:BgTimer.Stop()
        try { & $job.OnDone } catch { }
    }
})

function Get-FunctionText {
    param([string[]]$Names)
    return (($Names | ForEach-Object { "function $_ {`n" + (Get-Command $_ -CommandType Function).ScriptBlock.ToString() + "`n}" }) -join "`n")
}

function Start-BgJob {
    param([scriptblock]$Work, [object[]]$ArgList, [scriptblock]$OnDone)
    $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $ps = [powershell]::Create()
    [void]$ps.AddScript($Work.ToString()).AddArgument($queue)
    foreach ($a in $ArgList) { [void]$ps.AddArgument($a) }
    $handle = $ps.BeginInvoke()
    $script:BgJob = [pscustomobject]@{ PS = $ps; Handle = $handle; Queue = $queue; OnDone = $OnDone }
    $script:BgTimer.Start()
}

$script:ScanWork = {
    param($q, $cats, $funcText)
    Invoke-Expression $funcText
    function Write-Log { param([string]$Message) $q.Enqueue(@{ T = "log"; M = $Message }) }
    Write-Log "Analizando espacio recuperable (puede tardar un poco)..."
    foreach ($name in @($cats.Keys)) {
        Write-Log "  Analizando: $name..."
        $def = $cats[$name]
        $totalGB = 0
        if ($def.Special -eq "WindowsOld") {
            Write-Log "    (Windows.old tiene muchos archivos: medirlo puede tardar unos minutos, no esta trabado)"
            $totalGB = Get-WindowsOldSizeGB
        } elseif ($def.Special -eq "OldGpuDrivers") {
            $pkgs = @()
            try { $pkgs = @(Get-OldGpuDriverPackages) } catch { Write-Log "    No se pudo leer el almacen de drivers: $($_.Exception.Message)" }
            foreach ($p in $pkgs) {
                $totalGB += $p.SizeGB
                Write-Log ("    - {0}  {1}  v{2}  ({3:N0} MB)" -f $p.Inf, $p.Provider, $p.Version, ($p.SizeGB * 1024))
            }
            if ($pkgs.Count -eq 0) { Write-Log "    (no hay versiones viejas: solo queda la actual)" }
            $q.Enqueue(@{ T = "drivers"; List = $pkgs })
        } else {
            foreach ($p in $def.Paths) { $totalGB += Get-FolderSizeGB -Path $p -FilePattern $def.FilePattern }
        }
        $totalGB = [math]::Round($totalGB, 2)
        Write-Log "    -> ~$totalGB GB recuperables."
        $q.Enqueue(@{ T = "label"; Name = $name; Text = "~ $totalGB GB" })
    }
    Write-Log "Analisis completado."
}

$script:CleanWork = {
    param($q, $cats, $selected, $funcText, $driverInfs)
    Invoke-Expression $funcText
    function Write-Log { param([string]$Message) $q.Enqueue(@{ T = "log"; M = $Message }) }
    foreach ($name in @($selected)) {
        Write-Log "Limpiando: $name"
        Remove-CleanupCategory -Name $name -Def $cats[$name] -Packages $driverInfs
        $q.Enqueue(@{ T = "label"; Name = $name; Text = "liberado" })
    }
    Write-Log "Limpieza de disco finalizada."
}

$window.FindName("BtnDiskScan").Add_Click({
    if ($script:BgJob) { Write-Log "Ya hay una tarea de disco en curso, espera a que termine."; return }
    $window.FindName("BtnDiskScan").IsEnabled = $false
    Start-BgJob -Work $script:ScanWork `
        -ArgList @($CleanupCategories, (Get-FunctionText "Get-FolderSizeGB","Get-OldGpuDriverPackages","Get-WindowsOldSizeGB","Wait-ProcWithLog")) `
        -OnDone { $window.FindName("BtnDiskScan").IsEnabled = $true }
})

$window.FindName("BtnEmptyRecycleBin").Add_Click({
    Write-Log "Vaciando la Papelera de Reciclaje..."
    try { Clear-RecycleBin -Force -ErrorAction Stop; Write-Log "  Papelera vaciada." }
    catch { Write-Log "  No se pudo vaciar la papelera (puede que ya este vacia): $($_.Exception.Message)" }
    Update-DrivesPanel
})

$window.FindName("BtnDiskClean").Add_Click({
    if ($script:BgJob) { Write-Log "Ya hay una tarea de disco en curso, espera a que termine."; return }
    $selected = @($CleanupCheckboxes.Keys | Where-Object { $CleanupCheckboxes[$_].IsChecked })

    # Windows.old: es la instalacion anterior de Windows, al borrarla no se puede volver a esa version
    $woldCat = "Windows.old (instalacion anterior de Windows)"
    if (($selected -contains $woldCat) -and (Test-Path "C:\Windows.old")) {
        $ans = [System.Windows.MessageBox]::Show("Windows.old guarda tu instalacion anterior de Windows. Si la borras ya no vas a poder volver a esa version.`n`nPuede tardar muchos minutos (la app sigue funcionando y te avisa el avance en el registro).`n`nContinuar?", "PC Optimizer", "YesNo", "Warning")
        if ($ans -ne "Yes") {
            Write-Log "Windows.old: cancelado, no se borro nada de esa categoria."
            $selected = @($selected | Where-Object { $_ -ne $woldCat })
        }
    }

    # Drivers de video viejos: solo se borra lo que el analisis mostro Y el usuario confirma
    $driverCat  = "Versiones viejas de drivers de video (NVIDIA / AMD)"
    $driverInfs = @()
    if ($selected -contains $driverCat) {
        $pkgs = @($script:OldGpuPackages)
        if ($pkgs.Count -eq 0) {
            Write-Log "Drivers de video: primero presiona 'Analizar' para ver que versiones viejas se pueden quitar. Se omite esta categoria."
            $selected = @($selected | Where-Object { $_ -ne $driverCat })
        } else {
            $lista = ($pkgs | ForEach-Object { "  - $($_.Provider)  v$($_.Version)  ($([math]::Round($_.SizeGB * 1024)) MB)" }) -join "`n"
            $msg = "Se van a quitar estas versiones viejas de drivers de video del almacen de Windows:`n`n$lista`n`nSe conserva la version mas nueva y la que usa tu placa ahora. Despues no vas a poder volver a una version vieja con 'Revertir controlador'.`n`nContinuar?"
            $ans = [System.Windows.MessageBox]::Show($msg, "PC Optimizer", "YesNo", "Warning")
            if ($ans -eq "Yes") {
                $driverInfs = @($pkgs | ForEach-Object { $_.Inf })
            } else {
                Write-Log "Drivers de video: cancelado, no se borro nada de esa categoria."
                $selected = @($selected | Where-Object { $_ -ne $driverCat })
            }
        }
    }

    if ($selected.Count -eq 0) { Write-Log "No hay nada para limpiar."; return }
    $window.FindName("BtnDiskClean").IsEnabled = $false
    Start-BgJob -Work $script:CleanWork `
        -ArgList @($CleanupCategories, $selected, (Get-FunctionText "Remove-CleanupCategory","Get-OldGpuDriverPackages","Get-FolderSizeGB","Wait-ProcWithLog"), $driverInfs) `
        -OnDone { Update-DrivesPanel; $window.FindName("BtnDiskClean").IsEnabled = $true }
})

$window.FindName("BtnOpenDiskMgmt").Add_Click({
    Write-Log "Abriendo Administracion de Discos (para redimensionar/mover particiones)..."
    Start-Process "diskmgmt.msc"
})

$window.FindName("BtnOpenCleanmgr").Add_Click({
    Write-Log "Abriendo el Liberador de espacio en disco de Windows..."
    Start-Process "cleanmgr.exe"
})

Update-DrivesPanel

function Update-RamDisplay {
    $info = Get-RamInfo
    $window.Dispatcher.Invoke([action]{
        $RamStatsText.Text = "Usada: $($info.UsedGB) GB   |   Libre: $($info.FreeGB) GB   |   Total: $($info.TotalGB) GB   |   $($info.PercentUsed)% en uso"
        $RamBar.Value = $info.PercentUsed
    })
    return $info
}

$window.FindName("BtnRamRefresh").Add_Click({ Update-RamDisplay | Out-Null; Write-Log "RAM actualizada." })

$window.FindName("BtnRamFree").Add_Click({
    $btn = $window.FindName("BtnRamFree"); $btn.IsEnabled = $false
    $before = Update-RamDisplay
    Write-Log "Liberando RAM (vaciando working sets de procesos)..."
    $count = Invoke-EmptyWorkingSets
    [System.GC]::Collect()
    Start-Sleep -Milliseconds 500
    $after = Update-RamDisplay
    $liberado = [math]::Round($before.UsedGB - $after.UsedGB, 2)
    Write-Log "Procesos procesados: $count. RAM usada antes: $($before.UsedGB) GB -> despues: $($after.UsedGB) GB (liberado aprox. $liberado GB)."
    $btn.IsEnabled = $true
})

$window.FindName("BtnRamStandby").Add_Click({
    $btn = $window.FindName("BtnRamStandby"); $btn.IsEnabled = $false
    $before = Update-RamDisplay
    Write-Log "Vaciando Standby List..."
    try {
        [MemOptimizer]::PurgeStandbyList() | Out-Null
        Start-Sleep -Milliseconds 500
        $after = Update-RamDisplay
        Write-Log "Standby List vaciada. RAM libre antes: $($before.FreeGB) GB -> despues: $($after.FreeGB) GB."
    } catch {
        Write-Log "No se pudo vaciar la Standby List: $($_.Exception.Message)"
    }
    $btn.IsEnabled = $true
})

$window.FindName("BtnRamExplorer").Add_Click({
    Write-Log "Reiniciando Explorer.exe..."
    try {
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 800
        Start-Process explorer.exe
        Write-Log "Explorer reiniciado."
    } catch { Write-Log "Error al reiniciar Explorer: $($_.Exception.Message)" }
})

# Auto-refresco del monitor de RAM cada 2 segundos mientras la ventana este abierta
$ramTimer = New-Object System.Windows.Threading.DispatcherTimer
$ramTimer.Interval = [TimeSpan]::FromSeconds(2)
$ramTimer.Add_Tick({ if ($MainTabs.SelectedIndex -eq 6) { Update-RamDisplay | Out-Null } })
$ramTimer.Start()
Update-RamDisplay | Out-Null

# ---------------------------------------------------------------
# Dashboard "Inicio": saludo + monitor en vivo de CPU / GPU / RAM
# ---------------------------------------------------------------
$hora = (Get-Date).Hour
$saludo = if ($hora -lt 6) { "Buenas noches" } elseif ($hora -lt 12) { "Buenos dias" } elseif ($hora -lt 19) { "Buenas tardes" } else { "Buenas noches" }
$GreetingText.Text = $saludo

try { $script:CpuName = (Get-CimInstance Win32_Processor).Name } catch { $script:CpuName = "Procesador" }
try { $script:GpuName = (Get-CimInstance Win32_VideoController | Select-Object -First 1 -ExpandProperty Name) } catch { $script:GpuName = "Placa de video" }
$script:RamNameLabel = "Memoria RAM"

# ---------------------------------------------------------------
# Tarjeta "Nivel de optimizacion" del Inicio
# ---------------------------------------------------------------
$ScoreValue   = $window.FindName("ScoreValue")
$ScoreTotal   = $window.FindName("ScoreTotal")
$ScoreBar     = $window.FindName("ScoreBar")
$ScoreTitle   = $window.FindName("ScoreTitle")
$ScoreDetail  = $window.FindName("ScoreDetail")
$HardwareLine = $window.FindName("HardwareLine")

function Get-ShortName {
    # Acorta nombres largos de hardware: "AMD Ryzen 7 5800X 8-Core Processor" -> "AMD Ryzen 7 5800X"
    param([string]$Text)
    $t = $Text -replace '\(R\)|\(TM\)|\(r\)|\(tm\)', ''
    $t = $t -replace '\d+-Core Processor', '' -replace 'with Radeon Graphics', '' -replace '\s+CPU\b.*$', ''
    return (($t -replace '\s+', ' ').Trim())
}

function Get-ShortHardwareLine {
    $parts = New-Object System.Collections.ArrayList
    if ($script:CpuName) { [void]$parts.Add((Get-ShortName $script:CpuName)) }
    if ($script:GpuName) { [void]$parts.Add((Get-ShortName $script:GpuName)) }
    try { [void]$parts.Add(("{0:N0} GB RAM" -f [Math]::Round((Get-RamInfo).TotalGB))) } catch { }
    try {
        $build = [int](Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction Stop).CurrentBuild
        [void]$parts.Add($(if ($build -ge 22000) { "Windows 11" } else { "Windows 10" }))
    } catch { }
    try {
        $drive = New-Object System.IO.DriveInfo($env:SystemDrive)
        [void]$parts.Add(("{0:N0} GB libres" -f ($drive.AvailableFreeSpace / 1GB)))
    } catch { }
    return ($parts -join "  ·  ")
}

function Update-ScoreCard {
    # Contador principal: TODOS los ajustes con estado medible (activos / disponibles).
    # El nivel (Excelente, Buena...) y el color de la barra se calculan solo con los RECOMENDADOS,
    # para que nadie tenga que aplicar ajustes riesgosos para llegar al maximo.
    # Las acciones sin estado (como "Limpiar archivos temporales") no cuentan.
    $scored = New-Object System.Collections.ArrayList
    $allCount = 0
    foreach ($dict in @($StandardTweaks, $AdvancedTweaks, $GamingTweaks)) {
        foreach ($n in $dict.Keys) {
            if (-not $dict[$n].Status) { continue }
            $allCount++
            if ($TweakMeta[$n] -and $TweakMeta[$n].Rec) { [void]$scored.Add($n) }
        }
    }
    if ($allCount -eq 0 -or $scored.Count -eq 0) { return }
    foreach ($n in $scored) { if (-not $script:TweakState.ContainsKey($n)) { return } }   # faltan resultados todavia

    $allActive = 0
    foreach ($dict in @($StandardTweaks, $AdvancedTweaks, $GamingTweaks)) {
        foreach ($n in $dict.Keys) {
            if ($dict[$n].Status -and $script:TweakState[$n] -eq $true) { $allActive++ }
        }
    }
    $recActive = 0
    foreach ($n in $scored) { if ($script:TweakState[$n] -eq $true) { $recActive++ } }
    $pct = [int][Math]::Round(100.0 * $recActive / $scored.Count)

    if     ($pct -ge 90) { $level = "Excelente"; $color = "#4ade80" }
    elseif ($pct -ge 60) { $level = "Buena";     $color = "#4ade80" }
    elseif ($pct -ge 30) { $level = "Mejorable"; $color = "#facc15" }
    else                 { $level = "Baja";      $color = "#ff4d4d" }

    $ScoreValue.Text = "$allActive"
    $ScoreTotal.Text = "/ $allCount"
    $ScoreTitle.Text = "Nivel de optimizacion: $level"
    if ($recActive -ge $scored.Count) {
        $ScoreDetail.Text = "Todo lo recomendado esta activo ($recActive de $($scored.Count)). Los demas ajustes son opcionales: aplicalos segun lo que necesites."
    } else {
        $ScoreDetail.Text = "Recomendados activos: $recActive de $($scored.Count). Carga el perfil Equilibrado para sumar el resto. Los demas ajustes son opcionales."
    }

    # Barra fina (ancho total 140): muestra la fraccion de arriba; el color sale del nivel de los recomendados
    $ScoreBar.Width = 140.0 * $allActive / $allCount
    $ScoreBar.Background = $color
}

$HardwareLine.Text = Get-ShortHardwareLine

$script:MetricHistory = @{
    CPU = (New-Object System.Collections.Generic.List[double])
    GPU = (New-Object System.Collections.Generic.List[double])
    RAM = (New-Object System.Collections.Generic.List[double])
}
$script:ActiveMetric = "CPU"
$SparkWidth = 480
$SparkHeight = 120
$SparkMaxPoints = 30

$BtnMetricCpu = $window.FindName("BtnMetricCpu")
$BtnMetricGpu = $window.FindName("BtnMetricGpu")
$BtnMetricRam = $window.FindName("BtnMetricRam")
$MetricButtons = @{ CPU = $BtnMetricCpu; GPU = $BtnMetricGpu; RAM = $BtnMetricRam }

function Set-ActiveMetric {
    param([string]$Metric)
    $script:ActiveMetric = $Metric
    foreach ($key in $MetricButtons.Keys) {
        if ($key -eq $Metric) {
            $MetricButtons[$key].Background = $window.Resources["AccentGradient"]
            $MetricButtons[$key].Foreground = "White"
        } else {
            $MetricButtons[$key].Background = "#1d1d1d"
            $MetricButtons[$key].Foreground = $window.Resources["TextMuted"]
        }
    }
    Render-MetricGraph
}

function Render-MetricGraph {
    $hist = $script:MetricHistory[$script:ActiveMetric]
    $n = $hist.Count

    $MetricBarsCanvas.Children.Clear()
    $gap = 4
    # Ancho real del lienzo (si todavia no se midio, se usa el valor base)
    $canvasW = $MetricBarsCanvas.ActualWidth
    if ($canvasW -lt 100) { $canvasW = $SparkWidth }
    $barWidth = [Math]::Max(4, ($canvasW / $SparkMaxPoints) - $gap)
    $startOffset = if ($n -lt $SparkMaxPoints) { ($SparkMaxPoints - $n) * ($barWidth + $gap) } else { 0 }

    for ($i = 0; $i -lt $n; $i++) {
        $val = [double]$hist[$i]
        $barHeight = [Math]::Max(2, ($val / 100.0) * $SparkHeight)
        $barColor = if ($val -ge 85) { "#f87171" } elseif ($val -ge 60) { "#facc15" } else { "#4ade80" }

        $rect = New-Object System.Windows.Shapes.Rectangle
        $rect.Width = $barWidth
        $rect.Height = $barHeight
        $rect.Fill = $barColor
        $rect.RadiusX = 2
        $rect.RadiusY = 2
        [System.Windows.Controls.Canvas]::SetLeft($rect, $startOffset + ($i * ($barWidth + $gap)))
        [System.Windows.Controls.Canvas]::SetTop($rect, $SparkHeight - $barHeight)
        $MetricBarsCanvas.Children.Add($rect) | Out-Null
    }

    $lastVal = if ($n -gt 0) { $hist[$n - 1] } else { 0 }
    $color = if ($lastVal -ge 85) { "#f87171" } elseif ($lastVal -ge 60) { "#facc15" } else { "#4ade80" }
    $name = switch ($script:ActiveMetric) {
        "CPU" { $script:CpuName }
        "GPU" { $script:GpuName }
        "RAM" { $script:RamNameLabel }
    }
    $CpuPercentText.Text = "$lastVal%"
    $CpuPercentText.Foreground = $color
    $CpuNameText.Text = $name
    $CpuDetailText.Text = if ($script:ActiveMetric -eq "RAM") { $script:RamDetail } else { "" }
}

# El chequeo de CPU/GPU/RAM se hace en un runspace de fondo aparte para no
# congelar la interfaz mientras esas consultas (sobre todo la de GPU) tardan.
$script:RamDetail = ""
$script:MonitorPS = $null
$script:MonitorHandle = $null
$script:MonitorBusy = $false

$MonitorScriptText = {
    $cpu = $null; $gpu = $null; $ramUsed = 0; $ramTotal = 0; $ramPercent = 0
    try {
        $cpu = [math]::Round((Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop).PercentProcessorTime, 0)
    } catch {}
    try {
        $samples = (Get-Counter '\GPU Engine(*engtype_3D)\Utilization Percentage' -ErrorAction Stop).CounterSamples
        $total = ($samples | Measure-Object -Property CookedValue -Sum).Sum
        if ($total -gt 100) { $total = 100 }
        $gpu = [math]::Round($total, 0)
    } catch {}
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $ramTotal = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
        $freeGB = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
        $ramUsed = [math]::Round($ramTotal - $freeGB, 2)
        $ramPercent = [math]::Round((($ramTotal - $freeGB) / $ramTotal) * 100, 0)
    } catch {}
    [PSCustomObject]@{ Cpu = $cpu; Gpu = $gpu; RamUsed = $ramUsed; RamTotal = $ramTotal; RamPercent = $ramPercent }
}

function Start-MonitorPoll {
    if ($script:MonitorBusy) { return }
    $script:MonitorBusy = $true
    $script:MonitorPS = [powershell]::Create()
    $script:MonitorPS.AddScript($MonitorScriptText) | Out-Null
    $script:MonitorHandle = $script:MonitorPS.BeginInvoke()
}

function Process-MonitorResult {
    if (-not $script:MonitorBusy -or -not $script:MonitorHandle.IsCompleted) { return }
    try {
        $data = ($script:MonitorPS.EndInvoke($script:MonitorHandle))[0]
        if ($null -ne $data) {
            if ($null -ne $data.Cpu) {
                $script:MetricHistory.CPU.Add($data.Cpu)
                if ($script:MetricHistory.CPU.Count -gt $SparkMaxPoints) { $script:MetricHistory.CPU.RemoveAt(0) }
            }
            if ($null -ne $data.Gpu) {
                $script:MetricHistory.GPU.Add($data.Gpu)
                if ($script:MetricHistory.GPU.Count -gt $SparkMaxPoints) { $script:MetricHistory.GPU.RemoveAt(0) }
            }
            $script:MetricHistory.RAM.Add($data.RamPercent)
            if ($script:MetricHistory.RAM.Count -gt $SparkMaxPoints) { $script:MetricHistory.RAM.RemoveAt(0) }
            $script:RamDetail = "$($data.RamUsed) GB de $($data.RamTotal) GB usados"
            Render-MetricGraph
        }
    } catch {
    } finally {
        $script:MonitorPS.Dispose()
        $script:MonitorPS = $null
        $script:MonitorHandle = $null
        $script:MonitorBusy = $false
    }
}

$BtnMetricCpu.Add_Click({ Set-ActiveMetric -Metric "CPU" })
$BtnMetricGpu.Add_Click({ Set-ActiveMetric -Metric "GPU" })
$BtnMetricRam.Add_Click({ Set-ActiveMetric -Metric "RAM" })

$sysMonitorTimer = New-Object System.Windows.Threading.DispatcherTimer
$sysMonitorTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$sysMonitorTimer.Add_Tick({
    if ($script:MonitorBusy) { Process-MonitorResult } else { Start-MonitorPoll }
})
$sysMonitorTimer.Start()

Write-Log "PC Optimizer v$AppVersion listo."
Write-Log "Pestanas: Debloat | Tweaks Estandar | Tweaks Avanzados | Gaming | Espacio en Disco | RAM | Mantenimiento."
Write-Log "Recomendado: crea un punto de restauracion antes de aplicar cambios."

# ---------------------------------------------------------------
# Pestana Mantenimiento: tareas largas en segundo plano (misma cola que la limpieza de disco)
# ---------------------------------------------------------------
function Get-MaintLine {
    # Limpia una linea de salida de DISM/SFC/CHKDSK: saca caracteres nulos (SFC escribe en UTF-16)
    # y deja pasar los porcentajes solo de a 10 % para no llenar el registro de lineas.
    param([string]$Line, [hashtable]$State)
    $l = ($Line -replace "`0", "").Trim()
    if (-not $l) { return $null }
    if ($l -match '(\d{1,3})(?:[.,]\d)?\s*%') {
        $pct = [int]$Matches[1]
        if ($pct -lt ($State.Last + 10) -and $pct -lt 100) { return $null }
        $State.Last = $pct
    }
    return $l
}

$script:MaintWork = {
    param($q, $steps, $funcText)
    Invoke-Expression $funcText
    function Say([string]$m) { $q.Enqueue(@{ T = "log"; M = $m }) }
    # Un proceso de 32 bits en Windows de 64 bits ve otra carpeta System32: Sysnative evita el problema
    $sysDir = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { "$env:windir\Sysnative" } else { "$env:windir\System32" }
    foreach ($st in @($steps)) {
        Say $st.Title
        if ($st.Kind -eq "ps") {
            try {
                $out = & ([scriptblock]::Create($st.Code)) 2>&1 | Out-String -Stream
                foreach ($l in $out) { if ($l.Trim()) { Say "  $l" } }
            } catch { Say "  Error: $($_.Exception.Message)" }
            continue
        }
        $exe = Join-Path $sysDir $st.Exe
        if (-not (Test-Path $exe)) { Say "  No se encontro $($st.Exe) en este equipo."; continue }
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $env:ComSpec
            $psi.Arguments = '/c ""' + $exe + '" ' + $st.Args + ' 2>&1"'
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true
            $enc = if ($st.Unicode) { [Text.Encoding]::Unicode } else { [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) }
            $psi.StandardOutputEncoding = $enc
            $p = [System.Diagnostics.Process]::Start($psi)
            $state = @{ Last = -10 }
            while ($null -ne ($raw = $p.StandardOutput.ReadLine())) {
                $l = Get-MaintLine -Line $raw -State $state
                if ($l) { Say "  $l" }
            }
            $p.WaitForExit()
            $note = ""
            if ($st.Exe -eq "chkdsk.exe") {
                $note = switch ($p.ExitCode) { 0 { " - sin errores" } 1 { " - se encontraron errores (no se corrigieron: modo solo lectura)" } default { "" } }
            } elseif ($st.Exe -eq "dism.exe" -and $p.ExitCode -eq 0) { $note = " - correcto" }
            Say "  -> termino (codigo $($p.ExitCode))$note."
        } catch { Say "  Error al ejecutar $($st.Exe): $($_.Exception.Message)" }
    }
    Say "Mantenimiento: tarea terminada."
}

function Start-Maintenance {
    param([object[]]$Steps)
    if ($script:BgJob) { Write-Log "Ya hay una tarea en curso, espera a que termine."; return }
    Start-BgJob -Work $script:MaintWork -ArgList @($Steps, (Get-FunctionText "Get-MaintLine")) -OnDone { }
}

$RegBackStatus = $window.FindName("RegBackStatus")
$script:RegBackKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Configuration Manager"
function Update-RegBackStatus {
    $v = (Get-ItemProperty -Path $script:RegBackKey -Name "EnablePeriodicBackup" -ErrorAction SilentlyContinue).EnablePeriodicBackup
    if ($v -eq 1) { $RegBackStatus.Text = "Estado: ACTIVADA"; $RegBackStatus.Foreground = "#4ade80" }
    else          { $RegBackStatus.Text = "Estado: desactivada (valor por defecto de Windows)"; $RegBackStatus.Foreground = "#9a9a9a" }
}
Update-RegBackStatus

$window.FindName("BtnRestoreOpen").Add_Click({
    Write-Log "Abriendo la Restauracion del sistema de Windows..."
    Start-Process -FilePath "rstrui.exe"
})
$window.FindName("BtnMaintRepair").Add_Click({
    $ans = [System.Windows.MessageBox]::Show("Se va a reparar la imagen de Windows (DISM) y despues los archivos del sistema (SFC).`n`nPuede tardar entre 10 y 30 minutos y necesita conexion a internet. Podes seguir usando la app: el avance aparece en el registro.`n`nContinuar?", "PC Optimizer", "YesNo", "Question")
    if ($ans -ne "Yes") { return }
    Start-Maintenance -Steps @(
        @{ Title = "[1/2] DISM: reparando la imagen de Windows (puede tardar bastante)..."; Exe = "dism.exe"; Args = "/Online /Cleanup-Image /RestoreHealth" },
        @{ Title = "[2/2] SFC: revisando y reparando archivos del sistema..."; Exe = "sfc.exe"; Args = "/scannow"; Unicode = $true }
    )
})
$window.FindName("BtnMaintSfcOnly").Add_Click({
    Start-Maintenance -Steps @(
        @{ Title = "SFC: comprobando archivos del sistema (no repara nada)..."; Exe = "sfc.exe"; Args = "/verifyonly"; Unicode = $true }
    )
})
$window.FindName("BtnMaintHealth").Add_Click({
    Start-Maintenance -Steps @(
        @{ Kind = "ps"; Title = "Estado de salud de los discos:"; Code = 'Get-PhysicalDisk | Select-Object FriendlyName, MediaType, HealthStatus, OperationalStatus, @{ n = "GB"; e = { [math]::Round($_.Size / 1GB) } } | Format-Table -AutoSize | Out-String' }
    )
})
$window.FindName("BtnMaintChkdsk").Add_Click({
    Start-Maintenance -Steps @(
        @{ Title = "CHKDSK: comprobando $($env:SystemDrive) en modo solo lectura..."; Exe = "chkdsk.exe"; Args = "$($env:SystemDrive)" }
    )
})

$window.FindName("BtnRegBackOn").Add_Click({
    try {
        Set-ItemProperty -Path $script:RegBackKey -Name "EnablePeriodicBackup" -Value 1 -Type DWord -Force -ErrorAction Stop
        Write-Log "Copia automatica del registro ACTIVADA. Windows copia el registro en C:\Windows\System32\config\RegBack al reiniciar y luego cada 10 dias."
        Write-Log "  Si queres una copia ya mismo, usa 'Crear copia ahora'."
    } catch { Write-Log "No se pudo activar: $($_.Exception.Message)" }
    Update-RegBackStatus
})
$window.FindName("BtnRegBackOff").Add_Click({
    try {
        Remove-ItemProperty -Path $script:RegBackKey -Name "EnablePeriodicBackup" -ErrorAction SilentlyContinue
        Write-Log "Copia automatica del registro desactivada (valor por defecto de Windows). Las copias que ya existan en RegBack no se borran."
    } catch { Write-Log "No se pudo desactivar: $($_.Exception.Message)" }
    Update-RegBackStatus
})
$window.FindName("BtnRegBackNow").Add_Click({
    $v = (Get-ItemProperty -Path $script:RegBackKey -Name "EnablePeriodicBackup" -ErrorAction SilentlyContinue).EnablePeriodicBackup
    if ($v -ne 1) { Write-Log "Primero activa la copia automatica (boton 'Activar'); puede hacer falta reiniciar para que Windows cree la tarea."; return }
    Start-Maintenance -Steps @(
        @{ Title = "Pidiendo a Windows que copie el registro ahora (tarea RegIdleBackup)..."; Exe = "schtasks.exe"; Args = '/run /tn "\Microsoft\Windows\Registry\RegIdleBackup"' },
        @{ Kind = "ps"; Title = "Contenido de la carpeta RegBack (puede tardar unos segundos en llenarse):"; Code = 'Start-Sleep -Seconds 10; Get-ChildItem "$env:windir\System32\config\RegBack" -ErrorAction SilentlyContinue | Select-Object Name, @{ n = "MB"; e = { [math]::Round($_.Length / 1MB, 1) } }, LastWriteTime | Format-Table -AutoSize | Out-String' }
    )
})

$window.FindName("BtnNetDns").Add_Click({
    Start-Maintenance -Steps @( @{ Title = "Vaciando la cache DNS..."; Exe = "ipconfig.exe"; Args = "/flushdns" } )
})
$window.FindName("BtnNetReset").Add_Click({
    $ans = [System.Windows.MessageBox]::Show("Se van a restablecer Winsock y la configuracion IP.`n`nPuede cortar la conexion un momento y despues hay que reiniciar la PC para que tome efecto.`n`nContinuar?", "PC Optimizer", "YesNo", "Warning")
    if ($ans -ne "Yes") { return }
    Start-Maintenance -Steps @(
        @{ Title = "Restableciendo Winsock..."; Exe = "netsh.exe"; Args = "winsock reset" },
        @{ Title = "Restableciendo la configuracion IP..."; Exe = "netsh.exe"; Args = "int ip reset" },
        @{ Title = "Vaciando la cache DNS..."; Exe = "ipconfig.exe"; Args = "/flushdns" },
        @{ Kind = "ps"; Title = "Listo: reinicia la PC para terminar de aplicar el restablecimiento de red."; Code = '"-"' }
    )
})

$window.FindName("BtnDiagReport").Add_Click({
    Write-Log "Informe de rendimiento: Windows va a recolectar datos unos 60 segundos y despues abre el informe solo."
    Start-Process -FilePath "perfmon.exe" -ArgumentList "/report"
})
$window.FindName("BtnDiagMem").Add_Click({
    Write-Log "Abriendo el Diagnostico de memoria de Windows (te va a pedir reiniciar la PC para probar la RAM)."
    Start-Process -FilePath "mdsched.exe"
})
$window.FindName("BtnDiagRes").Add_Click({
    Start-Process -FilePath "resmon.exe"
})

# ---------------------------------------------------------------
# Debloat: saber que ya esta quitado (consulta en segundo plano)
# ---------------------------------------------------------------
$script:BloatState = @{}
$script:BloatJob   = $null
$script:BloatLast  = $null

$script:BloatStatusWork = {
    param($list)
    $names = @()
    try { $names = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object -Unique) } catch { }
    $counts = @{}; $apps = @{}
    foreach ($cat in @($list.Keys)) {
        if ($cat -eq "OneDrive (desinstalar completo)") {
            # Se mira el programa en si; OneDriveSetup.exe queda siempre en Windows y no sirve para saber si esta instalado
            $paths = @("$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe", "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe", "${env:ProgramFiles(x86)}\Microsoft OneDrive\OneDrive.exe")
            $found = @($paths | Where-Object { $_ -and (Test-Path $_) })
            $counts[$cat] = $found.Count; $apps[$cat] = $found
            continue
        }
        if ($names.Count -eq 0) { $counts[$cat] = $null; $apps[$cat] = @(); continue }   # no se pudo leer la lista: desconocido
        $matched = New-Object System.Collections.ArrayList
        foreach ($pat in $list[$cat]) {
            foreach ($n in $names) { if (($n -like $pat) -and -not $matched.Contains($n)) { [void]$matched.Add($n) } }
        }
        $counts[$cat] = $matched.Count
        $apps[$cat] = @($matched)
    }
    @{ Counts = $counts; Apps = $apps }
}

function Format-AppName {
    # "Microsoft.BingWeather" -> "Bing Weather   (Microsoft.BingWeather)": nombre legible + nombre tecnico exacto
    param([string]$Pkg)
    $known = @{
        "Microsoft.XboxApp" = "Xbox (app antigua)"; "Microsoft.GamingApp" = "Xbox (app de Windows)"
        "Microsoft.XboxGamingOverlay" = "Xbox Game Bar"; "Microsoft.XboxGameOverlay" = "Xbox Game Overlay"
        "Microsoft.XboxIdentityProvider" = "Xbox (inicio de sesion)"; "Microsoft.XboxSpeechToTextOverlay" = "Xbox (voz a texto)"
        "Microsoft.Xbox.TCUI" = "Xbox (interfaz TCUI)"
        "Microsoft.BingNews" = "Noticias"; "Microsoft.BingWeather" = "El Tiempo"; "Microsoft.BingFinance" = "Finanzas"
        "Microsoft.BingSports" = "Deportes"; "Microsoft.BingTranslator" = "Traductor"
        "Microsoft.MahjongforWindows" = "Mahjong"; "Microsoft.SkypeApp" = "Skype"; "MicrosoftTeams" = "Microsoft Teams (personal)"
        "Microsoft.MicrosoftOfficeHub" = "Office (Microsoft 365)"; "Microsoft.Office.OneNote" = "OneNote"
        "microsoft.windowscommunicationsapps" = "Correo y Calendario"
        "Microsoft.3DBuilder" = "3D Builder"; "Microsoft.MSPaint" = "Paint 3D"; "Microsoft.Print3D" = "Print 3D"
        "Microsoft.MixedReality.Portal" = "Portal de realidad mixta"; "Microsoft.Microsoft3DViewer" = "Visor 3D"
        "Microsoft.GetHelp" = "Obtener ayuda"; "Microsoft.Getstarted" = "Consejos"; "Microsoft.Messaging" = "Mensajes"
        "Microsoft.MicrosoftStickyNotes" = "Notas rapidas"; "Microsoft.People" = "Contactos"
        "Microsoft.WindowsAlarms" = "Alarmas y reloj"; "Microsoft.WindowsFeedbackHub" = "Centro de opiniones"
        "Microsoft.WindowsMaps" = "Mapas"; "Microsoft.YourPhone" = "Phone Link (Vincular con el movil)"
        "Microsoft.ZuneMusic" = "Groove Musica / Media Player"; "Microsoft.ZuneVideo" = "Peliculas y TV"
        "Microsoft.Todos" = "Microsoft To Do"; "Clipchamp.Clipchamp" = "Clipchamp (editor de video)"
        "Microsoft.PowerAutomateDesktop" = "Power Automate"; "MicrosoftCorporationII.MicrosoftFamily" = "Microsoft Family"
        "Microsoft.549981C3F5F10" = "Cortana"; "MicrosoftWindows.Client.WebExperience" = "Widgets"
    }
    if ($known.ContainsKey($Pkg)) { $nice = $known[$Pkg] }
    else {
        $parts = @($Pkg -split '\.')
        $base = $parts[-1]
        if (($base -match '^[0-9A-Fa-f]{8,}$') -and $parts.Count -gt 1) { $base = $parts[0] }   # id raro: se usa el nombre del editor
        $nice = $base -creplace '([a-z])([A-Z])', '$1 $2'
        $nice = $nice -creplace '([a-z])(\d)', '$1 $2'
        $nice = $nice -creplace '(\d)([A-Z][a-z])', '$1 $2'
        $nice = $nice -replace '^Tik Tok$', 'TikTok'
    }
    return "$nice   ($Pkg)"
}

function Get-BloatTip {
    param([string]$Category, $Count, $Apps)
    if ($null -eq $Count) { return "No pude leer la lista de apps de Windows.`nProba con el boton 'Actualizar estado'." }
    if ($Count -eq 0)     { return "No queda ninguna app de esta categoria instalada." }
    if ($Category -like "OneDrive*") {
        return "OneDrive esta instalado en:`n" + ((@($Apps) | ForEach-Object { "  - $_" }) -join "`n") + "`n`nMarca la casilla y aplica para desinstalarlo."
    }
    return "Apps instaladas de esta categoria ($Count):`n" + ((@($Apps) | Sort-Object | ForEach-Object { "  - " + (Format-AppName $_) }) -join "`n") + "`n`nMarca la casilla y aplica para quitarlas."
}

$script:BloatTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:BloatTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:BloatTimer.Add_Tick({
    $job = $script:BloatJob
    if (-not $job) { $script:BloatTimer.Stop(); return }
    if (-not $job.Handle.IsCompleted) { return }
    $script:BloatJob = $null
    $script:BloatTimer.Stop()
    $counts = @{}; $apps = @{}
    try {
        $res = $job.PS.EndInvoke($job.Handle)
        if ($res -and $res.Count -gt 0) { $map = [hashtable]$res[0]; $counts = [hashtable]$map.Counts; $apps = [hashtable]$map.Apps }
    } catch { }
    try { $job.PS.Dispose() } catch { }
    foreach ($cat in @($BloatStatusLabels.Keys)) {
        $lbl = $BloatStatusLabels[$cat]
        $count = $counts[$cat]
        $script:BloatState[$cat] = $count
        $lbl.ToolTip = Get-BloatTip -Category $cat -Count $count -Apps $apps[$cat]
        [System.Windows.Controls.ToolTipService]::SetInitialShowDelay($lbl, 150)
        [System.Windows.Controls.ToolTipService]::SetShowDuration($lbl, 60000)
        if ($null -eq $count)  { $lbl.Text = "no se pudo comprobar"; $lbl.Foreground = "#9a9a9a" }
        elseif ($count -eq 0)  { $lbl.Text = "● Ya quitado"; $lbl.Foreground = "#4ade80" }
        else                   { $lbl.Text = "○ $count instalada(s)"; $lbl.Foreground = "#facc15" }
    }
})

function Update-BloatStatuses {
    if ($script:BloatJob) { return }
    $script:BloatLast = [DateTime]::UtcNow
    $ps = [powershell]::Create()
    [void]$ps.AddScript($script:BloatStatusWork.ToString()).AddArgument($BloatwareList)
    $script:BloatJob = [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
    $script:BloatTimer.Start()
}

function Request-BloatStatuses {
    if ($script:BloatLast -and (([DateTime]::UtcNow - $script:BloatLast).TotalSeconds -lt 20)) { return }
    Update-BloatStatuses
}

$window.FindName("BtnBloatRefresh").Add_Click({
    Write-Log "Debloat: consultando que apps siguen instaladas..."
    $script:BloatLast = $null
    Update-BloatStatuses
})
$window.FindName("BtnBloatPending").Add_Click({
    if ($script:BloatState.Count -eq 0) { Write-Log "Todavia estoy consultando el estado del debloat, proba en unos segundos."; return }
    $n = 0
    foreach ($cat in @($BloatCheckboxes.Keys)) {
        $c = $script:BloatState[$cat]
        $pending = (($c -is [int]) -and ($c -gt 0))
        $BloatCheckboxes[$cat].IsChecked = $pending
        if ($pending) { $n++ }
    }
    Write-Log "Debloat: marcadas $n categoria(s) que todavia tienen apps instaladas."
})
$window.FindName("BtnBloatRec").Add_Click({
    if ($script:BloatState.Count -eq 0) { Write-Log "Todavia estoy consultando el estado del debloat, proba en unos segundos."; return }
    $n = 0
    foreach ($cat in @($BloatCheckboxes.Keys)) {
        $c = $script:BloatState[$cat]
        $mark = ($BloatMeta[$cat] -and $BloatMeta[$cat].Rec -and ($c -is [int]) -and ($c -gt 0))
        $BloatCheckboxes[$cat].IsChecked = [bool]$mark
        if ($mark) { $n++ }
    }
    Write-Log "Debloat: marcadas $n categoria(s) recomendadas que todavia tienen apps instaladas."
})

# ---------------------------------------------------------------
# Boton rayito: optimizacion rapida (solo lo RECOMENDADO que falta)
# ---------------------------------------------------------------
function Get-QuickPlan {
    # Tweaks recomendados que todavia no estan activos. Las acciones sin estado (como "Limpiar archivos temporales")
    # no entran: no se puede saber si ya se hicieron.
    $tweaks = New-Object System.Collections.ArrayList
    foreach ($pair in @(@($StandardTweaks, $StdCheckboxes), @($AdvancedTweaks, $AdvCheckboxes), @($GamingTweaks, $GamingCheckboxes))) {
        $dict = $pair[0]; $boxes = $pair[1]
        foreach ($n in $dict.Keys) {
            if (-not ($TweakMeta[$n] -and $TweakMeta[$n].Rec)) { continue }
            if (-not $dict[$n].Status) { continue }
            if ($script:TweakState[$n] -eq $true) { continue }
            [void]$tweaks.Add([pscustomobject]@{ Name = $n; Box = $boxes[$n] })
        }
    }
    # Categorias de debloat recomendadas que todavia tienen apps instaladas
    $cats = New-Object System.Collections.ArrayList
    foreach ($c in $BloatwareList.Keys) {
        $count = $script:BloatState[$c]
        if ($BloatMeta[$c] -and $BloatMeta[$c].Rec -and ($count -is [int]) -and ($count -gt 0)) {
            [void]$cats.Add([pscustomobject]@{ Name = $c; Box = $BloatCheckboxes[$c]; Count = $count })
        }
    }
    return [pscustomobject]@{ Tweaks = @($tweaks); Cats = @($cats) }
}

$window.FindName("BtnQuick").Add_Click({
    if (-not $window.FindName("BtnApply").IsEnabled) { Write-Log "Ya se esta aplicando algo, espera a que termine."; return }
    if ($script:TweakState.Count -eq 0 -or $script:BloatState.Count -eq 0) {
        Write-Log "Optimizacion rapida: todavia estoy leyendo el estado de tu PC. Proba de nuevo en unos segundos."
        return
    }
    $plan = Get-QuickPlan
    if (($plan.Tweaks.Count + $plan.Cats.Count) -eq 0) {
        Write-Log "Optimizacion rapida: ya tenes aplicado todo lo recomendado, no hay nada pendiente."
        return
    }
    $txt = "Optimizacion rapida: se aplica SOLO lo recomendado (riesgo bajo) que todavia no tenes.`n"
    if ($plan.Tweaks.Count -gt 0) {
        $txt += "`nTweaks ($($plan.Tweaks.Count)):`n" + (($plan.Tweaks | ForEach-Object { "  - $($_.Name)" }) -join "`n") + "`n"
    }
    if ($plan.Cats.Count -gt 0) {
        $txt += "`nApps a quitar ($($plan.Cats.Count) categorias):`n" + (($plan.Cats | ForEach-Object { "  - $($_.Name)" }) -join "`n") + "`n"
        if ($plan.Cats | Where-Object { $_.Name -like "Apps de terceros*" }) {
            $txt += "`nOjo: 'Apps de terceros' quita por nombre apps como Spotify, Disney+ o TikTok si las tenes instaladas desde la Microsoft Store.`n"
        }
    }
    $txt += "`nSi esta tildado, antes se crea un punto de restauracion. Los tweaks se revierten; las apps quitadas se reinstalan desde la Microsoft Store.`n`nContinuar?"
    $ans = [System.Windows.MessageBox]::Show($txt, "PC Optimizer - Optimizacion rapida", "YesNo", "Question")
    if ($ans -ne "Yes") { Write-Log "Optimizacion rapida: cancelada."; return }

    foreach ($dict in @($BloatCheckboxes, $StdCheckboxes, $AdvCheckboxes, $GamingCheckboxes)) {
        foreach ($cb in $dict.Values) { $cb.IsChecked = $false }
    }
    foreach ($t in $plan.Tweaks) { $t.Box.IsChecked = $true }
    foreach ($c in $plan.Cats)   { $c.Box.IsChecked = $true }
    Write-Log "Optimizacion rapida: $($plan.Tweaks.Count) tweak(s) y $($plan.Cats.Count) categoria(s) de debloat marcados. Aplicando..."
    $window.FindName("BtnApply").RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
})

# Primera medicion de estados (en segundo plano): llena el nivel de optimizacion del Inicio
Update-TweakStatuses -TweaksDict $StandardTweaks -StatusLabelsDict $StdStatusLabels
Update-TweakStatuses -TweaksDict $AdvancedTweaks -StatusLabelsDict $AdvStatusLabels
Update-TweakStatuses -TweaksDict $GamingTweaks -StatusLabelsDict $GamingStatusLabels
Update-BloatStatuses

# Red de seguridad: un error inesperado en cualquier boton se muestra en el log en vez de cerrar la app
$window.Dispatcher.add_UnhandledException({
    param($sender, $e)
    try { Write-Log "Error inesperado (la app sigue abierta): $($e.Exception.Message)" } catch { }
    $e.Handled = $true
})

$window.ShowDialog() | Out-Null
