<#
.SYNOPSIS
    Compila Flux en modo Release para Windows y genera el instalador ejecutable (.exe) con Inno Setup.
.DESCRIPTION
    1. Ejecuta 'flutter build windows --release'
    2. Localiza el compilador de Inno Setup (ISCC.exe)
    3. Compila el instalador a traves del script flux_installer.iss
    4. Guarda el instalador final en build\installer\
#>

param (
    [switch]$SkipFlutterBuild = $false
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'release_common.ps1')
$releaseVersion = Get-ReleaseVersion

$ProjectRoot = Resolve-Path "$PSScriptRoot\.."
Set-Location $ProjectRoot

Write-Host "===============================================" -ForegroundColor Cyan
Write-Host "     Generador de Instalador Windows - Flux    " -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan

# 1. Compilar Flutter en modo Release
if (-not $SkipFlutterBuild) {
    Write-Host "`n[1/3] Compilando Flutter para Windows (Release)..." -ForegroundColor Yellow
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Fallo la compilacion de Flutter para Windows."
        exit $LASTEXITCODE
    }
} else {
    Write-Host "`n[1/3] Omitiendo compilacion de Flutter (-SkipFlutterBuild activado)..." -ForegroundColor DarkGray
}

$ReleaseDir = Join-Path $ProjectRoot "build\windows\x64\runner\Release"
if (-not (Test-Path $ReleaseDir)) {
    Write-Error "No se encontro la carpeta Release en: $ReleaseDir. Ejecute una compilacion primero."
    exit 1
}

# 2. Localizar Inno Setup Compiler (ISCC.exe)
Write-Host "`n[2/3] Localizando Inno Setup..." -ForegroundColor Yellow

$IsccPath = $null
$PossiblePaths = @(
    "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
    "C:\Program Files\Inno Setup 6\ISCC.exe",
    (Get-Command iscc.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
)

foreach ($path in $PossiblePaths) {
    if ($path -and (Test-Path $path)) {
        $IsccPath = $path
        break
    }
}

if (-not $IsccPath) {
    Write-Error "No se encontro Inno Setup (ISCC.exe). Puedes instalarlo con: winget install JRSoftware.InnoSetup"
    exit 1
}

Write-Host "Inno Setup encontrado en: $IsccPath" -ForegroundColor Green

# 3. Compilar instalador
Write-Host "`n[3/3] Compilando el instalador con Inno Setup..." -ForegroundColor Yellow

$IssScript = Join-Path $ProjectRoot "windows\installer\flux_installer.iss"
$InstallerOutDir = Join-Path $ProjectRoot "build\installer"

if (-not (Test-Path $InstallerOutDir)) {
    New-Item -ItemType Directory -Path $InstallerOutDir -Force | Out-Null
}

& "$IsccPath" "/DMyAppVersion=$($releaseVersion.Version)" "$IssScript"

if ($LASTEXITCODE -ne 0) {
    Write-Error "Error al compilar el instalador con Inno Setup."
    exit $LASTEXITCODE
}

Write-Host "`n===============================================" -ForegroundColor Green
Write-Host "     INSTALADOR GENERADO EXITOSAMENTE!         " -ForegroundColor Green
Write-Host "===============================================" -ForegroundColor Green

$Installers = Get-ChildItem -Path $InstallerOutDir -Filter "*.exe" | Sort-Object LastWriteTime -Descending
if ($Installers.Count -gt 0) {
    $Latest = $Installers[0]
    $SizeMB = [math]::Round($Latest.Length / 1MB, 2)
    Write-Host "Archivo: $($Latest.FullName)" -ForegroundColor Cyan
    Write-Host "Tamano : $SizeMB MB" -ForegroundColor Cyan
} else {
    Write-Host "Carpeta de instaladores: $InstallerOutDir" -ForegroundColor Cyan
}
