# Apply the XP-compatibility std patch to the locally installed Rust source.
#
# The patch replaces the win7-target std backends (mutex/condvar use SRWLOCK &
# CONDITION_VARIABLE, thread_local uses FLS, time uses GetSystemTimePreciseAsFileTime)
# with XP-native equivalents so the resulting binary loads on Windows XP.
#
# Usage (CI / local):  pwsh legacy/apply_std_patch.ps1
# Requires: `rustup component add rust-src` for the pinned toolchain.

$ErrorActionPreference = "Stop"

if (-not (Get-Command rustc -ErrorAction SilentlyContinue)) {
    Write-Error "rustc not found on PATH; install the pinned Rust toolchain first."
    exit 1
}

$sysroot = (rustc --print sysroot).Trim()
# rust-src lives at <sysroot>/lib/rustlib/src/rust/library
$lib = Join-Path $sysroot "lib\rustlib\src\rust\library"
if (-not (Test-Path (Join-Path $lib "std\src\lib.rs"))) {
    Write-Error "rust-src not found at '$lib'. Run: rustup component add rust-src --toolchain <pinned>"
    exit 1
}

$patchRoot = Join-Path $PSScriptRoot "std-patch"
if (-not (Test-Path $patchRoot)) {
    Write-Error "std-patch directory not found at '$patchRoot'."
    exit 1
}

$count = 0
Get-ChildItem -Path $patchRoot -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($patchRoot.Length).TrimStart('\', '/')
    $dest = Join-Path $lib $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    Copy-Item -Path $_.FullName -Destination $dest -Force
    Write-Host "patched: $rel"
    $count++
}

Write-Host ""
Write-Host "Applied $count std source file(s) from std-patch/ onto $lib"
Write-Host "Next: build with '-Zbuild-std=std --target i686-win7-windows-gnu'"
