#requires -Version 7.0
param(
    [switch]$Publish,
    [switch]$Draft,
    [switch]$Split,
    [switch]$Windows,
    [switch]$SkipBuild,
    [switch]$DryRun
)
. (Join-Path $PSScriptRoot 'release_common.ps1')
$root = Get-ReleaseRoot
$version = Get-ReleaseVersion $root
$repo = Get-ReleaseRepository $root
$commit = Get-ReleaseCommit $root
$dist = Join-Path $root "dist/$($version.Tag)+$($version.Build)"
if ($Draft -and !$Publish) { throw '-Draft requiere -Publish.' }
& (Join-Path $PSScriptRoot 'sync_version.ps1') -Check
$null = Get-ReleaseChanges $root $version.Version
Write-Host "Flux $($version.Full) -> $repo ($commit)"
Write-Host "Salida: $dist"
if ($DryRun) {
    Write-Host 'SIMULACION: sin compilar, escribir archivos, crear tags o acceder a GitHub.'
    Write-Host "Artefactos: $(@(Get-ReleaseArtifactNames $version -Split:$Split -Windows:$Windows) -join ', ')"
    Write-Host "Reutilizar paquete: $SkipBuild | Publicar: $Publish | Borrador: $Draft"
    return
}
Assert-ReleaseClean $root
if ($Publish) {
    $null = Get-Command gh -ErrorAction Stop
    Invoke-ReleaseCommand gh @('auth', 'status', '--hostname', 'github.com') | Out-Host
}

Push-Location $root
try {
    if (!$SkipBuild) {
        if ($Windows -and ![OperatingSystem]::IsWindows()) { throw '-Windows requiere Windows.' }
        foreach ($relative in @('android/key.properties')) {
            if (!(Test-Path -LiteralPath (Join-Path $root $relative))) { throw "Falta $relative para compilar Android firmado." }
        }
        if (Test-Path -LiteralPath $dist) { throw 'Ya existe el paquete. Usa -SkipBuild o una version nueva; no se sobrescribira.' }
        $null = Get-Command flutter -ErrorAction Stop
        Invoke-ReleaseCommand flutter @('pub', 'get', '--enforce-lockfile') | Out-Host
        Assert-ReleaseClean $root
        $null = New-Item -ItemType Directory -Path $dist
        $oldReleaseFlag = $env:FLUX_RELEASE_BUILD
        try {
            $env:FLUX_RELEASE_BUILD = '1'
            $versionArgs = @('--build-name', $version.Version, '--build-number', "$($version.Build)", '--no-pub')
            Invoke-ReleaseCommand flutter (@('build', 'apk', '--release') + $versionArgs) | Out-Host
            Copy-Item -LiteralPath 'build/app/outputs/flutter-apk/app-release.apk' -Destination (Join-Path $dist "flux-$($version.Tag)-universal.apk")
            if ($Split) {
                Invoke-ReleaseCommand flutter (@('build', 'apk', '--release', '--split-per-abi') + $versionArgs) | Out-Host
                foreach ($pair in @(@('arm64-v8a', 'arm64'), @('armeabi-v7a', 'armv7'), @('x86_64', 'x86_64'))) {
                    Copy-Item -LiteralPath "build/app/outputs/flutter-apk/app-$($pair[0])-release.apk" -Destination (Join-Path $dist "flux-$($version.Tag)-$($pair[1]).apk")
                }
            }
            if ($Windows) {
                Invoke-ReleaseCommand flutter (@('build', 'windows', '--release') + $versionArgs) | Out-Host
                $bundle = Join-Path $root 'build/windows/x64/runner/Release'
                foreach ($required in @('flux.exe', 'flutter_windows.dll', 'data')) {
                    if (!(Test-Path -LiteralPath (Join-Path $bundle $required))) { throw "Bundle Windows incompleto: $required" }
                }
                Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath (Join-Path $dist "flux-$($version.Tag)-windows-x64.zip")
            }
        } finally {
            $env:FLUX_RELEASE_BUILD = $oldReleaseFlag
        }
        Assert-ReleaseClean $root
        & (Join-Path $PSScriptRoot 'generate_release_notes.ps1') -DistDir $dist -Split:$Split -Windows:$Windows
    }
    $meta = Assert-ReleaseBundle $root $dist $version $commit $repo
    if (!$Publish) {
        Write-Host 'Paquete listo. Revisa RELEASE_NOTES.md y usa -Publish -SkipBuild para publicarlo.'
        return
    }
    Assert-ReleaseClean $root
    # Never push source history to the public repository. GitHub creates the
    # release tag on the public site's default branch, not on the private code.
    $destination = (Invoke-ReleaseCommand gh @('repo', 'view', $repo, '--json', 'nameWithOwner,isPrivate') | Out-String) | ConvertFrom-Json
    if ($destination.isPrivate -or $destination.nameWithOwner -ine $repo) { throw 'El destino debe ser el repositorio publico configurado.' }
    $assets = @($meta.artifacts | ForEach-Object { Join-Path $dist $_.name })
    $assets += @((Join-Path $dist 'SHA256SUMS.txt'), (Join-Path $dist 'release-meta.json'))
    # First upload as a draft. A failed upload never exposes a partial release.
    Invoke-ReleaseCommand gh (@('release', 'create', $version.Tag) + $assets + @(
        '--repo', $repo, '--draft', '--title', "Flux $($version.Version)",
        '--notes-file', (Join-Path $dist 'RELEASE_NOTES.md')
    )) | Out-Host
    if (!$Draft) {
        Invoke-ReleaseCommand gh @('release', 'edit', $version.Tag, '--repo', $repo, '--draft=false') | Out-Host
    }
    Write-Host "Release preparada: https://github.com/$repo/releases/tag/$($version.Tag)"
} finally {
    Pop-Location
}
