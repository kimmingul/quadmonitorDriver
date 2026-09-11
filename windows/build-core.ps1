# Run in Windows PowerShell with Visual Studio C++ ARM64 tools and CMake installed.
# Builds/tests codec only. Does not install drivers or open USB interfaces.
param([string]$Generator = '')
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run this script on Windows.' }
$root = Split-Path $PSScriptRoot -Parent
$build = Join-Path $root 'build/windows-arm64'
$configure = @('-S', $PSScriptRoot, '-B', $build, '-A', 'ARM64')
if ($Generator) { $configure += @('-G', $Generator) }
& cmake @configure
if ($LASTEXITCODE -ne 0) { throw 'CMake configuration failed; check ARM64 C++ tools and Windows SDK.' }
& cmake --build $build --config Release
if ($LASTEXITCODE -ne 0) { throw 'Native ARM64 build failed.' }
& ctest --test-dir $build -C Release --output-on-failure
if ($LASTEXITCODE -ne 0) { throw 'Codec tests failed; do not proceed to USB transmission.' }
Write-Host 'ARM64 codec tests passed. No monitor driver has been installed.'
