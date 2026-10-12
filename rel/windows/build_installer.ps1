<#
.SYNOPSIS
    Packs the Windows release into Alnasl-Setup.exe and its update feed.

.DESCRIPTION
    Velopack (`vpk`) wraps the release `mix release` assembled into a
    one-click, per-user installer, and writes beside it the files an
    installed copy later updates from:

        Alnasl-Setup.exe               the installer (no version in the name:
                                       the download page links to it for good)
        AlnaslApp-<version>-full.nupkg the whole program, as Velopack fetches it
        AlnaslApp-<version>-delta.nupkg the difference from the version before,
                                       when that version's package was at hand
        releases.win.json              the feed: which versions exist

    All of them go on the GitHub release. The names of the .nupkg files and
    of the feed are Velopack's and must stay as they are: installed copies
    look for them by name.

    Normally the release workflow runs this. By hand:

        mix release alnasl --overwrite          (MIX_ENV=prod, on Windows, with zig)
        .\rel\windows\build_installer.ps1 -PayloadDir _build\prod\rel\alnasl -OutputDir installer_out

    BUILDING an installer is harmless. RUNNING one installs the program for
    the user who runs it. Do that on a machine, or in a Windows Sandbox,
    kept for it - see docs/releasing.md.

.NOTES
    WHY THE PACK ID IS NOT "Alnasl", AND WHY THERE IS NO .msi

    Velopack installs to %LOCALAPPDATA%\<pack id>, and uninstalling removes
    that folder whole - everything in it, not only what the installer put
    there. OpenPairings, next door, was once packed under an id that was
    also the name of its data folder; an uninstall took every tournament on
    the machine with it. And the .msi Velopack can build has a clean-up of
    its own that removes %LOCALAPPDATA%\<pack title> besides.

    So, for Alnasl, before a single release exists:

      * the pack id is AlnaslApp: the install folder, and nothing else's name;
      * the data lives in %LOCALAPPDATA%\AlnaslData, which is neither the
        pack id nor the pack title, nor inside either
        (lib/alnasl/data_home.ex; rel/windows/launcher.c sets it);
      * no .msi is built, so nothing ever removes a folder named after the
        title - and the data is not there anyway;
      * this script refuses to pack when any of that stops being true, and
        test/alnasl/data_home_test.exs reads the names below out of this
        file and compares them with the program's own.

    The pack id is also the name of the update feed's packages. It cannot
    be changed once a release is out without stranding every installed
    copy on its last version.

    WHAT IS NOT SIGNED

    Nothing is. There is no code-signing certificate. Windows SmartScreen
    says "Windows protected your PC" the first time Alnasl-Setup.exe is
    run; "More info", then "Run anyway", installs it. The README says so
    where people download it.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PayloadDir,

    [string]$OutputDir = 'installer_out',

    [string]$Version
)

$ErrorActionPreference = 'Stop'

$packId = 'AlnaslApp'
$packTitle = 'Alnasl'
$packAuthors = 'Alnasl'

# Every folder name the program keeps data under, on any system, now or
# before. A pack id or title that is one of these is an installer that
# deletes data.
$dataFolderNames = @('AlnaslData', '.alnasl', 'alnasl-data')

function Assert-DataDirectorySafe {
    param([hashtable]$Removed)

    foreach ($label in $Removed.Keys) {
        $name = $Removed[$label]
        foreach ($data in $dataFolderNames) {
            if ($name -ieq $data -or $data -ilike "$name\*" -or $name -ilike "$data\*") {
                throw @"
Refusing to pack: $label is '$name', and that is where the program keeps its
data ($($dataFolderNames -join ', ')). Uninstalling would delete it.
See .NOTES in this script and lib/alnasl/data_home.ex.
"@
            }
        }
    }
}

Assert-DataDirectorySafe -Removed @{
    'the pack id (the folder an uninstall removes)' = $packId
    'the pack title (the folder an .msi clean-up would remove)' = $packTitle
}

if (-not (Get-Command vpk -ErrorAction SilentlyContinue)) {
    throw "vpk not found. Install it with: dotnet tool install -g vpk --version 1.2.0"
}

if (-not $Version) {
    $match = Select-String -Path (Join-Path $PSScriptRoot '..\..\mix.exs') `
        -Pattern 'version:\s*"([0-9]+\.[0-9]+\.[0-9]+)"' | Select-Object -First 1
    if (-not $match) { throw "Could not read the version from mix.exs; pass -Version." }
    $Version = $match.Matches[0].Groups[1].Value
}

$PayloadDir = (Resolve-Path $PayloadDir).Path

# Velopack packs a --mainExe that does not exist without a word, and the
# result installs a program nothing can start.
foreach ($needed in @('Alnasl.exe', 'bin\alnasl.bat', 'releases\start_erl.data')) {
    if (-not (Test-Path (Join-Path $PayloadDir $needed))) {
        throw "The payload at $PayloadDir has no $needed. Build it with ``mix release alnasl`` on Windows, with zig on the PATH."
    }
}

# The payload must be the release that was asked for.
$built = (Get-Content (Join-Path $PayloadDir 'releases\start_erl.data') -Raw).Trim().Split(' ')[1]
if ($built -ne $Version) {
    throw "The payload is version $built, not $Version."
}

# A release that somebody started with its data inside it would ship that
# data - a database, the cookie secret, relay keys - to everybody.
$leaks = Get-ChildItem -Path $PayloadDir -Recurse -File -Include 'alnasl.db', 'alnasl.db-wal', 'secret_key_base', 'listen' -ErrorAction SilentlyContinue
if ($leaks) {
    throw "The payload holds data, which must never be packed: $($leaks.FullName -join ', ')"
}

# A release that has been started keeps the configuration it started with
# in its tmp folder, the cookie secret included. Pack a release that was
# only ever built (the workflow's smoke test sets RELEASE_TMP elsewhere).
$started = Join-Path $PayloadDir 'tmp'
if ((Test-Path $started) -and (Get-ChildItem $started -Recurse -File)) {
    throw "The payload has been started from: $started is not empty. Build it again with ``mix release alnasl --overwrite``."
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$OutputDir = (Resolve-Path $OutputDir).Path

if (Get-ChildItem $OutputDir -Filter "$packId-$Version-*.nupkg" -ErrorAction SilentlyContinue) {
    throw "$OutputDir already holds a $Version package. Pack into an empty folder, or one holding only the previous version's package (for the delta)."
}

Write-Host "Packing Alnasl $Version from $PayloadDir" -ForegroundColor Cyan

# No --msi, on purpose (.NOTES). Shortcuts: the Start menu entry "Alnasl"
# and one on the desktop, as OpenPairings has.
& vpk pack `
    --packId $packId `
    --packVersion $Version `
    --packDir $PayloadDir `
    --mainExe Alnasl.exe `
    --packTitle $packTitle `
    --packAuthors $packAuthors `
    --icon (Join-Path $PSScriptRoot 'Alnasl.ico') `
    --shortcuts 'Desktop,StartMenu' `
    --outputDir $OutputDir

if ($LASTEXITCODE -ne 0) { throw "vpk pack failed with exit code $LASTEXITCODE" }

# The installer gets the name the download page links to. The packages and
# the feed keep Velopack's names: installed copies ask for them by name.
$setup = Join-Path $OutputDir "$packId-win-Setup.exe"
if (-not (Test-Path $setup)) { throw "vpk pack did not write $setup." }
Move-Item -Force $setup (Join-Path $OutputDir 'Alnasl-Setup.exe')

# Velopack's own "portable" zip carries its updater without an installation
# for it to update. The portable download is the plain release, zipped by
# the workflow; this one would only be a second file with the same claim.
Remove-Item -Force (Join-Path $OutputDir "$packId-win-Portable.zip") -ErrorAction SilentlyContinue

foreach ($needed in @('Alnasl-Setup.exe', "$packId-$Version-full.nupkg", 'releases.win.json')) {
    if (-not (Test-Path (Join-Path $OutputDir $needed))) {
        throw "vpk pack did not leave $needed in $OutputDir."
    }
}

# What the feed says must be what was packed, under the id installed copies
# will ask for.
$feed = Get-Content (Join-Path $OutputDir 'releases.win.json') -Raw | ConvertFrom-Json
$mine = $feed.Assets | Where-Object { $_.Version -eq $Version -and $_.Type -eq 'Full' }
if (-not $mine -or $mine.PackageId -ne $packId) {
    throw "releases.win.json does not list a Full package $packId $Version."
}

Get-ChildItem $OutputDir |
    Select-Object Name, @{n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } } |
    Format-Table -AutoSize
