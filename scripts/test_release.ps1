#requires -Version 7.0
# Offline integration tests. Uses an isolated fixture and fake Git/Flutter/gh.
. (Join-Path $PSScriptRoot 'release_common.ps1')
$projectRoot = Get-ReleaseRoot
$testParent = [IO.Path]::GetFullPath((Join-Path $projectRoot 'dist'))
$fixtureRoot = Join-Path $testParent ('release-tests-' + [guid]::NewGuid().ToString('N'))
$global:FluxTestDirty = $false
$global:FluxTestRemote = 'https://github.com/private/flux.git'
$global:FluxTestCommit = '0123456789012345678901234567890123456789'
$global:FluxTestPublish = $false
$global:FluxTestUploadFails = $false
$global:FluxTestCalls = [Collections.Generic.List[string]]::new()
$script:passed = 0

function git {
    $global:LASTEXITCODE = 0
    $arguments = @($args)
    if ($arguments[0] -eq '-C') { $arguments = @($arguments | Select-Object -Skip 2) }
    if ($global:FluxTestPublish -and $arguments[0] -in @('tag', 'ls-remote', 'push')) {
        $global:FluxTestCalls.Add('git ' + ($arguments -join ' '))
        return
    }
    switch ($arguments -join ' ') {
        'remote get-url origin' { return $global:FluxTestRemote }
        'rev-parse HEAD' { return $global:FluxTestCommit }
        'status --porcelain --untracked-files=normal' { if ($global:FluxTestDirty) { return ' M pubspec.yaml' }; return }
        default { throw "Unexpected git command in offline test: $($arguments -join ' ')" }
    }
}
function flutter { throw 'Tests must never compile or download dependencies.' }
function gh {
    if (!$global:FluxTestPublish) { throw 'Unexpected GitHub invocation in offline test.' }
    $global:LASTEXITCODE = 0
    $global:FluxTestCalls.Add('gh ' + ($args -join ' '))
    if ($args[0] -eq 'repo') { return '{"nameWithOwner":"example/flux","isPrivate":false}' }
    if ($global:FluxTestUploadFails -and $args[0] -eq 'release' -and $args[1] -eq 'create') {
        $global:LASTEXITCODE = 1
    }
}
function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) { throw "$Message (expected '$Expected', got '$Actual')" }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        return
    }
    throw "Expected an error matching: $Pattern"
}
function Pass([string]$Name) { $script:passed++; Write-Host "OK $script:passed - $Name" }
function Reset-Fixture {
    Write-ReleaseText (Join-Path $fixtureRoot 'release.config.json') '{"repository":"example/flux"}'
    Write-ReleaseText (Join-Path $fixtureRoot 'pubspec.yaml') "name: flux`nversion: 1.2.3+8`n"
    $json = @'
[{"version":"1.2.3","date":"2026-09-27","title":"Release test","changes":[{"type":"fix","description":"A real test change"}]}]
'@
    Write-ReleaseText (Join-Path $fixtureRoot 'assets/changelog.json') $json
    & (Join-Path $fixtureRoot 'scripts/sync_version.ps1')
}

try {
    foreach ($directory in @('scripts', 'assets', 'lib/core')) {
        $null = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot $directory) -Force
    }
    Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $fixtureRoot 'scripts')
    }
    Reset-Fixture
    $version = Get-ReleaseVersion $fixtureRoot
    Assert-Equal $version.Full '1.2.3+8' 'Initial version'
    & (Join-Path $fixtureRoot 'scripts/sync_version.ps1') -Check
    Pass 'version parsing and generated Dart agree'

    foreach ($case in @(@('patch', '1.2.4+9'), @('minor', '1.3.0+9'), @('major', '2.0.0+9'), @('build', '1.2.3+9'))) {
        Reset-Fixture
        & (Join-Path $fixtureRoot 'scripts/bump_version.ps1') -Type $case[0]
        Assert-Equal (Get-ReleaseVersion $fixtureRoot).Full $case[1] 'Monotonic build number'
        & (Join-Path $fixtureRoot 'scripts/sync_version.ps1') -Check
        Pass "$($case[0]) increment keeps build monotonic"
    }
    Assert-Throws { & (Join-Path $fixtureRoot 'scripts/bump_version.ps1') -Set '1.0.0' } 'mayor'
    Pass 'explicit version cannot move backwards'

    Reset-Fixture
    $before = (Get-FileHash (Join-Path $fixtureRoot 'pubspec.yaml')).Hash
    & (Join-Path $fixtureRoot 'scripts/bump_version.ps1') -Type minor -DryRun
    & (Join-Path $fixtureRoot 'scripts/build_release.ps1') -Publish -DryRun
    Assert-Equal (Get-FileHash (Join-Path $fixtureRoot 'pubspec.yaml')).Hash $before 'Dry run mutated version'
    Assert-Equal (Test-Path (Join-Path $fixtureRoot 'dist')) $false 'Dry run created output'
    Pass 'dry run has no writes, builds or publication calls'

    Write-ReleaseText (Join-Path $fixtureRoot 'lib/core/app_version.dart') 'stale'
    Assert-Throws { & (Join-Path $fixtureRoot 'scripts/sync_version.ps1') -Check } 'desincronizada'
    Pass 'stale generated version is rejected'

    Reset-Fixture
    & (Join-Path $fixtureRoot 'scripts/bump_version.ps1') -Type patch
    Assert-Throws { Get-ReleaseChanges $fixtureRoot '1.2.4' } 'pendientes'
    Pass 'placeholder release notes block publication'

    Reset-Fixture
    $global:FluxTestDirty = $true
    Assert-Throws { & (Join-Path $fixtureRoot 'scripts/build_release.ps1') -Publish } 'sin commit'
    $global:FluxTestDirty = $false
    Pass 'dirty tree is rejected before building or publishing'

    $package = Join-Path $fixtureRoot 'package'
    $null = New-Item -ItemType Directory -Path $package
    $artifact = Join-Path $package 'flux-v1.2.3-universal.apk'
    Write-ReleaseText $artifact 'Synthetic APK bytes, never uploaded.'
    & (Join-Path $fixtureRoot 'scripts/generate_release_notes.ps1') -DistDir $package
    $version = Get-ReleaseVersion $fixtureRoot
    $metadata = Assert-ReleaseBundle $fixtureRoot $package $version $global:FluxTestCommit 'example/flux'
    Assert-Equal $metadata.artifacts.Count 1 'Expected exactly one APK'
    Assert-Equal $metadata.artifacts[0].sha256 (Get-FileHash $artifact).Hash.ToLowerInvariant() 'Hash mismatch'
    Pass 'notes, checksums and metadata describe the same artifact'

    Assert-Throws { Assert-ReleaseBundle $fixtureRoot $package $version ('f' * 40) 'example/flux' } 'commit'
    Pass 'a bundle from another commit is rejected'
    Write-ReleaseText $artifact 'modified'
    Assert-Throws { Assert-ReleaseBundle $fixtureRoot $package $version $global:FluxTestCommit 'example/flux' } 'modificado'
    Pass 'modified binaries are rejected'
    Write-ReleaseText $artifact 'Synthetic APK bytes, never uploaded.'
    Write-ReleaseText (Join-Path $package 'unrelated.txt') 'not a release asset'
    Assert-Throws { Assert-ReleaseBundle $fixtureRoot $package $version $global:FluxTestCommit 'example/flux' } 'ajenos'
    Pass 'unrelated files cannot be uploaded'

    $global:FluxTestRemote = 'git@github.com:private/flux.git'
    Assert-Equal (Get-SourceRepository $fixtureRoot) 'private/flux' 'SSH origin parsing'
    Pass 'repository resolved from both HTTPS and SSH origin'

    Write-ReleaseText (Join-Path $fixtureRoot 'release.config.json') ('{"repository":"' + (Get-SourceRepository $fixtureRoot) + '"}')
    Assert-Throws { Get-ReleaseRepository $fixtureRoot } 'distinto'
    Pass 'source repository cannot be the public distribution destination'
    Reset-Fixture
    # Exercise publication with fake commands only: no network or real Git tags.
    $publishPackage = Join-Path $fixtureRoot 'dist/v1.2.3+8'
    $null = New-Item -ItemType Directory -Path $publishPackage -Force
    foreach ($name in @('flux-v1.2.3-universal.apk', 'RELEASE_NOTES.md', 'SHA256SUMS.txt', 'release-meta.json')) {
        Copy-Item -LiteralPath (Join-Path $package $name) -Destination $publishPackage
    }
    $global:FluxTestPublish = $true
    & (Join-Path $fixtureRoot 'scripts/build_release.ps1') -SkipBuild -Publish -Draft
    Assert-Equal @($global:FluxTestCalls | Where-Object { $_ -like 'gh release create*--draft*' }).Count 1 'Create draft first'
    Assert-Equal @($global:FluxTestCalls | Where-Object { $_ -like 'gh release edit*' }).Count 0 'Draft must stay private'
    Pass 'draft publication never promotes the release'

    $global:FluxTestCalls.Clear()
    & (Join-Path $fixtureRoot 'scripts/build_release.ps1') -SkipBuild -Publish
    Assert-Equal @($global:FluxTestCalls | Where-Object { $_ -like 'git *' }).Count 0 'Never push private source history'
    Assert-Equal @($global:FluxTestCalls | Where-Object { $_ -like 'gh release edit*--draft=false*' }).Count 1 'Publish after upload'
    Pass 'public release uploads draft assets before promotion'

    $global:FluxTestCalls.Clear()
    $global:FluxTestUploadFails = $true
    Assert-Throws { & (Join-Path $fixtureRoot 'scripts/build_release.ps1') -SkipBuild -Publish } 'gh fallo'
    Assert-Equal @($global:FluxTestCalls | Where-Object { $_ -like 'gh release edit*' }).Count 0 'Never promote after a failed upload'
    Pass 'failed upload cannot publish a partial release'
    Write-Host "All $script:passed offline release tests passed."
} finally {
    Remove-Variable FluxTestDirty,FluxTestRemote,FluxTestCommit,FluxTestPublish,FluxTestUploadFails,FluxTestCalls -Scope Global -ErrorAction SilentlyContinue
    # Delete only this test's UUID directory beneath this repository's dist/.
    $resolved = [IO.Path]::GetFullPath($fixtureRoot)
    $prefix = $testParent + [IO.Path]::DirectorySeparatorChar
    if (!$resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notmatch '^release-tests-[a-f0-9]{32}$') {
        throw 'Refusing to clean an unexpected test directory.'
    }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
