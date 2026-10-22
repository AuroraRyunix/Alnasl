# Erlang/OTP and Elixir on a Windows runner, straight from the two
# projects' GitHub releases. setup-beam finds the Windows OTP by reading
# erlang/otp's release list through the API, and on 2026-10-22 that list
# came back without 29.0.5 five times running while the release sat there
# in plain sight. A name we already know needs no list.
#
#   install-beam-windows.ps1 -Otp 29.0.5 -Elixir 1.20.4
param(
  [Parameter(Mandatory)] [string] $Otp,
  [Parameter(Mandatory)] [string] $Elixir
)
$ErrorActionPreference = "Stop"
$major = $Otp.Split(".")[0]
$root = Join-Path $env:RUNNER_TOOL_CACHE "beam"
$otpDir = Join-Path $root "otp-$Otp"
$exDir = Join-Path $root "elixir-$Elixir-otp-$major"
$tmp = Join-Path $env:RUNNER_TEMP "beam-download"
New-Item -ItemType Directory -Force $tmp, $otpDir, $exDir | Out-Null

# OTP's Windows zip is the portable build: unpacked, it runs.
gh release download "OTP-$Otp" -R erlang/otp -p "otp_win64_$Otp.zip" -D $tmp --clobber
if ($LASTEXITCODE -ne 0) { throw "OTP $Otp for Windows could not be downloaded" }
Expand-Archive (Join-Path $tmp "otp_win64_$Otp.zip") $otpDir -Force

gh release download "v$Elixir" -R elixir-lang/elixir -p "elixir-otp-$major.zip" -p "elixir-otp-$major.zip.sha256sum" -D $tmp --clobber
if ($LASTEXITCODE -ne 0) { throw "Elixir $Elixir for OTP $major could not be downloaded" }
$want = (Get-Content (Join-Path $tmp "elixir-otp-$major.zip.sha256sum")).Split(" ")[0].Trim().ToLower()
$have = (Get-FileHash (Join-Path $tmp "elixir-otp-$major.zip") -Algorithm SHA256).Hash.ToLower()
if ($want -ne $have) { throw "Elixir zip checksum mismatch: $have, expected $want" }
Expand-Archive (Join-Path $tmp "elixir-otp-$major.zip") $exDir -Force

$otpBin = Join-Path $otpDir "bin"
$exBin = Join-Path $exDir "bin"
$env:PATH = "$exBin;$otpBin;$env:PATH"
Add-Content $env:GITHUB_PATH $otpBin
Add-Content $env:GITHUB_PATH $exBin

& erl -noshell -eval 'io:format("OTP ~s~n", [erlang:system_info(otp_release)]), halt().'
if ($LASTEXITCODE -ne 0) { throw "erl does not start" }
& elixir --version
& mix local.hex --force
& mix local.rebar --force
