#requires -Version 7.0
param([Parameter(Mandatory)][string]$DistDir, [switch]$Split, [switch]$Windows)
. (Join-Path $PSScriptRoot 'release_common.ps1')
$root = Get-ReleaseRoot
$version = Get-ReleaseVersion $root
$entry = Get-ReleaseChanges $root $version.Version
$repo = Get-ReleaseRepository $root
$commit = Get-ReleaseCommit $root
$artifacts = @()
$sums = @()
foreach ($name in @(Get-ReleaseArtifactNames $version -Split:$Split -Windows:$Windows)) {
    $path = Join-Path $DistDir $name
    $file = Get-Item -LiteralPath $path
    if ($file.Length -eq 0) { throw "Archivo vacio: $name" }
    $sha = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    $artifacts += [ordered]@{
        name = $name; size = $file.Length; sha256 = $sha
        url = "https://github.com/$repo/releases/download/$($version.Tag)/$name"
    }
    $sums += "$sha  $name"
}
$lines = @("# Flux $($version.Version)", '', $entry.title, '', "Build: $($version.Build) | Commit: $commit", '')
$labels = @{ feature = 'Nuevo'; fix = 'Correccion'; improvement = 'Mejora' }
foreach ($change in $entry.changes) { $lines += "- $($labels[$change.type]): $($change.description)" }
$lines += @('', '## Archivos', '', '| Archivo | MB |', '| --- | ---: |')
foreach ($artifact in $artifacts) {
    $size = [math]::Round($artifact.size / 1MB, 2)
    $lines += "| [$($artifact.name)]($($artifact.url)) | $size |"
}
$lines += @('', '## Verificacion', '',
    'Compara el SHA-256 del archivo con SHA256SUMS.txt antes de instalar.', '',
    'PowerShell: `Get-FileHash -Algorithm SHA256 ./archivo.apk`', '',
    'Android: instala el APK universal. Para actualizar, debe estar firmado con la misma clave que tu instalacion actual.',
    'Windows: extrae el ZIP completo antes de abrir flux.exe; conserva las DLL y la carpeta data.', '')
Write-ReleaseText (Join-Path $DistDir 'RELEASE_NOTES.md') ($lines -join "`n")
Write-ReleaseText (Join-Path $DistDir 'SHA256SUMS.txt') (($sums -join "`n") + "`n")
$meta = [ordered]@{
    version = $version.Version; build = $version.Build; tag = $version.Tag
    repository = $repo; commit = $commit; date = $entry.date
    artifacts = $artifacts
    notesSha256 = (Get-FileHash -LiteralPath (Join-Path $DistDir 'RELEASE_NOTES.md') -Algorithm SHA256).Hash.ToLowerInvariant()
    sumsSha256 = (Get-FileHash -LiteralPath (Join-Path $DistDir 'SHA256SUMS.txt') -Algorithm SHA256).Hash.ToLowerInvariant()
}
Write-ReleaseText (Join-Path $DistDir 'release-meta.json') ((ConvertTo-Json $meta -Depth 8) + "`n")
Write-Host "Notas, hashes y metadata preparados en $DistDir"
