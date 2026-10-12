param(
    [ValidateSet("all", "x64", "arm64")]
    [string]$Architecture = "all"
)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
function Run-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
}
$Targets = @{ x64 = "x86_64-pc-windows-msvc"; arm64 = "aarch64-pc-windows-msvc" }
$Architectures = if ($Architecture -eq "all") { @("x64", "arm64") } else { @($Architecture) }
Run-Checked "npm.cmd" @("ci")
Run-Checked "npm.cmd" @("run", "build")
Run-Checked "npm.cmd" @("test")
Run-Checked "cargo" @("test", "--locked", "--manifest-path", "usage-core/Cargo.toml")
Run-Checked "cargo" @("test", "--locked", "--lib", "--manifest-path", "src-tauri/Cargo.toml")
foreach ($Arch in $Architectures) {
    $Target = $Targets[$Arch]
    Run-Checked "rustup" @("target", "add", $Target)
    Run-Checked "npm.cmd" @("run", "tauri", "build", "--", "--target", $Target, "--bundles", "nsis")
    $Executable = Join-Path $PSScriptRoot "src-tauri/target/$Target/release/codex-health-windows.exe"
    $Bytes = [System.IO.File]::ReadAllBytes($Executable)
    $Offset = [BitConverter]::ToInt32($Bytes, 0x3c)
    $Machine = [BitConverter]::ToUInt16($Bytes, $Offset + 4)
    $Expected = if ($Arch -eq "x64") { 0x8664 } else { 0xaa64 }
    if ($Machine -ne $Expected) { throw "Unexpected application architecture: $Machine" }
    Get-ChildItem "src-tauri/target/$Target/release/bundle/nsis/*-setup.exe" | ForEach-Object {
        Write-Host "Installer: $($_.FullName)"
        Get-FileHash -Algorithm SHA256 $_.FullName
    }
}
