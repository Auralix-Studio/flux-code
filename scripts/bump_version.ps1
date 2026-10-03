#requires -Version 7.0
[CmdletBinding(DefaultParameterSetName = 'Type')]
param(
    [Parameter(ParameterSetName = 'Type')][ValidateSet('major', 'minor', 'patch', 'build')][string]$Type = 'patch',
    [Parameter(Mandatory, ParameterSetName = 'Set')][string]$Set,
    [switch]$DryRun
)
. (Join-Path $PSScriptRoot 'release_common.ps1')
$root = Get-ReleaseRoot
$old = Get-ReleaseVersion $root
$parts = $old.Version.Split('.') | ForEach-Object { [int]$_ }
if ($PSCmdlet.ParameterSetName -eq 'Set') {
    if ($Set -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$' -or [version]$Set -le [version]$old.Version) {
        throw '-Set debe ser X.Y.Z y mayor que la version actual.'
    }
    $next = $Set
} else {
    switch ($Type) {
        major { $parts[0]++; $parts[1] = 0; $parts[2] = 0 }
        minor { $parts[1]++; $parts[2] = 0 }
        patch { $parts[2]++ }
    }
    $next = $parts -join '.'
}
$build = $old.Build + 1
if ($build -gt 2100000000) { throw 'El build supera el limite de Android.' }
$changelogPath = Join-Path $root 'assets/changelog.json'
$entries = @(Get-Content -LiteralPath $changelogPath -Raw | ConvertFrom-Json)
if ($next -ne $old.Version -and @($entries | Where-Object version -EQ $next).Count) {
    throw "El changelog ya contiene $next. Elige una version nueva con -Set."
}
Write-Host "$($old.Full) -> $next+$build (tag v$next)"
if ($DryRun) { return }
$pubspec = Join-Path $root 'pubspec.yaml'
$content = [IO.File]::ReadAllText($pubspec)
$content = [regex]::Replace($content, '(?m)^version:[^\r\n]*', "version: $next+$build")
Write-ReleaseText $pubspec $content
if ($next -ne $old.Version) {
    $entry = [ordered]@{
        version = $next; date = (Get-Date -Format 'yyyy-MM-dd'); title = "Flux $next"
        changes = @([ordered]@{ type = 'improvement'; description = 'PENDIENTE: describe los cambios de esta version.' })
    }
    Write-ReleaseText $changelogPath ((ConvertTo-Json -InputObject (@($entry) + $entries) -Depth 10) + "`n")
}
& (Join-Path $PSScriptRoot 'sync_version.ps1')
Write-Host 'Completa assets/changelog.json y guarda los cambios en Git antes de publicar.'
