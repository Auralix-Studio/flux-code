#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ReleaseRoot {
    return [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}

function Write-ReleaseText([string]$Path, [string]$Content) {
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Invoke-ReleaseCommand([string]$Command, [string[]]$Arguments) {
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command fallo (codigo $LASTEXITCODE)." }
}

function Get-ReleaseVersion([string]$Root = (Get-ReleaseRoot)) {
    $content = [IO.File]::ReadAllText((Join-Path $Root 'pubspec.yaml'))
    $matches = [regex]::Matches($content, '(?m)^version:\s*((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))\+([1-9]\d*)\s*$')
    if ($matches.Count -ne 1) { throw 'pubspec.yaml debe contener una version X.Y.Z+N unica (N positivo).' }
    $build = [int]$matches[0].Groups[2].Value
    if ($build -gt 2100000000) { throw 'El build supera el limite de Android.' }
    $version = $matches[0].Groups[1].Value
    return [pscustomobject]@{ Version = $version; Build = $build; Full = "$version+$build"; Tag = "v$version" }
}

function Get-ReleaseChanges([string]$Root, [string]$Version) {
    $entries = @(Get-Content -LiteralPath (Join-Path $Root 'assets/changelog.json') -Raw | ConvertFrom-Json)
    $entry = @($entries | Where-Object version -EQ $Version)
    if ($entry.Count -ne 1) { throw "Debe existir exactamente una entrada de changelog para $Version." }
    if ([string]::IsNullOrWhiteSpace($entry[0].title) -or @($entry[0].changes).Count -eq 0) {
        throw 'Completa el titulo y los cambios antes de preparar la publicacion.'
    }
    foreach ($change in $entry[0].changes) {
        if ($change.type -notin @('feature', 'fix', 'improvement') -or
            [string]::IsNullOrWhiteSpace($change.description) -or $change.description -match '^PENDIENTE:') {
            throw 'Completa las notas pendientes en assets/changelog.json.'
        }
    }
    return $entry[0]
}

function Get-SourceRepository([string]$Root) {
    $remote = (Invoke-ReleaseCommand git @('-C', $Root, 'remote', 'get-url', 'origin')).Trim()
    if ($remote -notmatch '^(?:https://github\.com/|git@github\.com:)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?/?$') {
        throw 'origin debe apuntar a un repositorio GitHub por HTTPS o SSH.'
    }
    return $Matches[1]
}

function Get-ReleaseCommit([string]$Root) {
    return (Invoke-ReleaseCommand git @('-C', $Root, 'rev-parse', 'HEAD')).Trim()
}

function Assert-ReleaseClean([string]$Root) {
    $changes = @(Invoke-ReleaseCommand git @('-C', $Root, 'status', '--porcelain', '--untracked-files=normal'))
    if ($changes.Count) { throw 'Hay cambios sin commit. Guarda los cambios antes de compilar/publicar una release.' }
}

function Get-ReleaseArtifactNames($Version, [switch]$Split, [switch]$Windows) {
    "flux-$($Version.Tag)-universal.apk"
    if ($Split) {
        foreach ($abi in @('arm64', 'armv7', 'x86_64')) { "flux-$($Version.Tag)-$abi.apk" }
    }
    if ($Windows) { "flux-$($Version.Tag)-windows-x64.zip" }
}

function Assert-ReleaseBundle([string]$Root, [string]$DistDir, $Version, [string]$Commit, [string]$Repository) {
    $meta = Get-Content -LiteralPath (Join-Path $DistDir 'release-meta.json') -Raw | ConvertFrom-Json
    if ($meta.version -ne $Version.Version -or $meta.build -ne $Version.Build -or $meta.tag -ne $Version.Tag -or
        $meta.commit -ne $Commit -or $meta.repository -ne $Repository) {
        throw 'El paquete no corresponde a esta version, commit o repositorio. No se publicara.'
    }
    $allowed = @(Get-ReleaseArtifactNames $Version -Split -Windows)
    $names = @($meta.artifacts | ForEach-Object name)
    if ($names.Count -eq 0 -or @($names | Select-Object -Unique).Count -ne $names.Count -or
        $names -notcontains "flux-$($Version.Tag)-universal.apk") { throw 'Paquete incompleto o duplicado.' }
    foreach ($artifact in $meta.artifacts) {
        if ($artifact.name -notin $allowed) { throw 'Artefacto no permitido en el paquete.' }
        $path = Join-Path $DistDir $artifact.name
        if (!(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -eq 0 -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $artifact.sha256) {
            throw "Artefacto ausente o modificado: $($artifact.name)."
        }
    }
    foreach ($name in @('RELEASE_NOTES.md', 'SHA256SUMS.txt')) {
        $expected = if ($name -eq 'RELEASE_NOTES.md') { $meta.notesSha256 } else { $meta.sumsSha256 }
        if ((Get-FileHash -LiteralPath (Join-Path $DistDir $name) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) {
            throw "$name fue modificado despues de preparar la release."
        }
    }
    $actual = @(Get-ChildItem -LiteralPath $DistDir -File | ForEach-Object Name)
    if (@(Compare-Object ($names + @('RELEASE_NOTES.md', 'SHA256SUMS.txt', 'release-meta.json')) $actual).Count) {
        throw 'El directorio contiene archivos ajenos al paquete.'
    }
    return $meta
}

function Get-ReleaseRepository([string]$Root) {
    $config = Get-Content -LiteralPath (Join-Path $Root 'release.config.json') -Raw | ConvertFrom-Json
    $repository = [string]$config.repository
    if ($repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Configura repository como propietario/repositorio en release.config.json.' }
    if ($repository -ieq (Get-SourceRepository $Root)) { throw 'El repositorio publico debe ser distinto del repositorio de codigo.' }
    return $repository
}