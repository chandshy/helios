param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$BuildRoot,
    [Parameter(Mandatory)][string]$OutputDir
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if ((Test-Path -LiteralPath $BuildRoot) -or (Test-Path -LiteralPath $OutputDir)) { throw 'Build and output roots must be fresh.' }
function Invoke-Checked([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed: $LASTEXITCODE" }
}
function Require-Hash([string]$Path, [string]$Expected) {
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Expected) { throw "Source hash mismatch: $Path" }
}
function Read-Checked([string]$Executable, [string[]]$Arguments) {
    $text = @(& $Executable @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed: $LASTEXITCODE" }
    return $text -join "`n"
}
$dxvk = Join-Path $RepoRoot 'dxvk-helios'
$pin = (Read-Checked 'git.exe' @('-C', $dxvk, 'rev-parse', 'HEAD')).Trim()
if ($pin -ne '316a457fb247ca1f9d99aa5a47963eadb06f693c') { throw 'Unexpected DXVK baseline.' }
$queue = Join-Path $dxvk 'src\dxvk\dxvk_queue.cpp'
Require-Hash $queue '05227608fc5963992b67f3bfd645fb194a181778a5c10fcccdcbfe3d62bb5396'
$patch = Join-Path $RepoRoot 'ci\windows\patches\dxvk-queue-unwind.patch'
Require-Hash $patch 'c8445d367110dd28fa4abdf24fa0db00e62e6688b1557a96deccae8d08e939ab'
Invoke-Checked 'git.exe' @('-C', $dxvk, 'apply', '--check', $patch)
Invoke-Checked 'git.exe' @('-C', $dxvk, 'apply', $patch)
Require-Hash $queue '574b4b898ba6c492da326879e74fd3e9fd13196d7320cd85a54e2c6c598dcd52'
. (Join-Path $RepoRoot 'ci\windows\Initialize-HeliosBuild.ps1')
Import-VisualStudioEnvironment
$llvm = Join-Path $env:VCINSTALLDIR 'Tools\Llvm\x64\bin'
$clang = Join-Path $llvm 'clang-cl.exe'
$archiver = Join-Path $llvm 'llvm-lib.exe'
$readobj = Join-Path $llvm 'llvm-readobj.exe'
foreach ($tool in @($clang, $archiver, $readobj)) { if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "Missing coherent VS LLVM tool: $tool" } }
$env:PATH = "$llvm;$env:PATH"
$wdk = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Include\10.0.26100.0'
foreach ($header in @('km\ntddk.h', 'um\d3d10umddi.h')) { if (-not (Test-Path -LiteralPath (Join-Path $wdk $header))) { throw "Missing WDK header: $header" } }
$msvc = Join-Path $env:VCToolsInstallDir 'include'
if (-not (Test-Path -LiteralPath (Join-Path $msvc 'vector'))) { throw 'MSVC STL missing.' }
$env:LIBCLANG_PATH = $llvm
$env:HELIOS_CLANG_CL = $clang
$env:HELIOS_MSVC_LIB = $archiver
$env:HELIOS_WDK_INCLUDE = $wdk
$env:HELIOS_MSVC_INCLUDE = $msvc
$env:HELIOS_DXVK_SRC = $dxvk
$env:HELIOS_DXVK_BUILD = Join-Path $BuildRoot 'dxvk'
$env:CARGO_TARGET_DIR = Join-Path $BuildRoot 'cargo-umd'
$env:RUSTFLAGS = '-C target-feature=+crt-static'
foreach ($tool in @('meson.exe', 'ninja.exe', 'cargo.exe')) { Assert-Command $tool | Out-Null }
$glslang = Assert-Command 'glslang.exe'
Require-Hash $glslang '9643709c02c83e26773f96b6a87f197ab2e84f78be0879ad8fb3619418b5d9ad'
$glslangVersion = Read-Checked $glslang @('--version')
$rust = Read-Checked 'rustc.exe' @('-vV')
if ($rust -notmatch 'host: x86_64-pc-windows-msvc') { throw 'Rust host must use x64 MSVC ABI.' }
New-Item -ItemType Directory -Path $BuildRoot | Out-Null
$compat = Join-Path $RepoRoot 'umd\build-support\dxvk_c_compat.h'
$cppArgs = '/D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH -Wno-deprecated-declarations -Wno-delete-non-abstract-non-virtual-dtor -Wno-unused-private-field -Wno-unused-lambda-capture -Wno-c++20-extensions -Wno-unused-const-variable'
Invoke-Checked 'meson.exe' @('setup', $env:HELIOS_DXVK_BUILD, $dxvk, '--native-file', (Join-Path $RepoRoot 'ci\windows\clang-cl-native.ini'), '--buildtype', 'release', '-Db_vscrt=mt', "-Dcpp_args=$cppArgs", "-Dc_args=/FI$compat", '-Denable_d3d8=false', '-Denable_d3d9=false', '-Denable_d3d10=false', '-Denable_d3d11=true', '-Denable_dxgi=true')
Invoke-Checked 'meson.exe' @('compile', '-C', $env:HELIOS_DXVK_BUILD, '-j', '4')
$options = Get-Content -LiteralPath (Join-Path $env:HELIOS_DXVK_BUILD 'meson-info\intro-buildoptions.json') -Raw | ConvertFrom-Json
if (@($options | Where-Object { $_.name -eq 'b_vscrt' })[0].value -ne 'mt') { throw 'DXVK CRT option drift.' }
$archiveNames = @('src/d3d11/libhelios_d3d11_static.a', 'src/dxvk/libdxvk.a', 'subprojects/dxbc-spirv/libdxbc_spv.a', 'src/spirv/libspirv.a', 'src/util/libutil.a', 'src/wsi/libwsi.a', 'src/vulkan/libvkcommon.a', 'subprojects/libdisplay-info/libdisplay-info.a')
$archives = @(foreach ($name in $archiveNames) {
    $file = Join-Path $env:HELIOS_DXVK_BUILD $name
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing native archive: $name" }
    @{ name = $name; sha256 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash }
})
Push-Location (Join-Path $RepoRoot 'umd')
try { Invoke-Checked 'cargo.exe' @('build', '--release', '--locked', '--manifest-path', (Join-Path $RepoRoot 'umd\Cargo.toml')) }
finally { Pop-Location }
$dll = Join-Path $env:CARGO_TARGET_DIR 'release\helios_umd.dll'
if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) { throw 'UMD output missing.' }
$headers = Read-Checked $readobj @('--file-headers', $dll)
if ($headers -notmatch 'IMAGE_FILE_MACHINE_AMD64') { throw 'UMD is not x64 PE.' }
$imports = Read-Checked $readobj @('--coff-imports', $dll)
if ($imports -match '(?i)(MSVCP\d+|VCRUNTIME\d+(?:_\d+)?|UCRTBASE|api-ms-win-crt-[^\s]+)\.dll') { throw 'Dynamic CRT import violates static CRT contract.' }
$exports = Read-Checked $readobj @('--coff-exports', $dll)
foreach ($name in @('OpenAdapter10', 'OpenAdapter10_2', 'OpenAdapter12')) {
    if ($exports -notmatch "(?m)^\s*Name:\s*$name\s*$") { throw "Missing UMD export: $name" }
}
$signature = Get-AuthenticodeSignature -LiteralPath $dll
if ($signature.Status.ToString() -ne 'NotSigned') { throw 'Expected an unsigned compile-only DLL.' }
New-Item -ItemType Directory -Path $OutputDir | Out-Null
Copy-Item -LiteralPath $dll -Destination (Join-Path $OutputDir 'helios_umd.dll')
$imports | Set-Content -LiteralPath (Join-Path $OutputDir 'imports.txt') -Encoding utf8
$exports | Set-Content -LiteralPath (Join-Path $OutputDir 'exports.txt') -Encoding utf8
$proof = [ordered]@{
    schema = 'umd-compile-proof.v1'; unsigned = ($signature.Status.ToString() -eq 'NotSigned'); signatureStatus = $signature.Status.ToString(); executed = $false
    publicationCommit = $env:GITHUB_SHA; baseline = '7e0e6b73c140b919dde20679e65e3a23dae40764'
    baselineTree = (Read-Checked 'git.exe' @('-C', $RepoRoot, 'rev-parse', '7e0e6b73c140b919dde20679e65e3a23dae40764^{tree}')).Trim()
    publicationTree = (Read-Checked 'git.exe' @('-C', $RepoRoot, 'rev-parse', 'HEAD^{tree}')).Trim()
    recipeSha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
    dxvkBaseline = $pin; queueSha256 = (Get-FileHash -LiteralPath $queue -Algorithm SHA256).Hash
    patchSha256 = (Get-FileHash -LiteralPath $patch -Algorithm SHA256).Hash
    binarySha256 = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
    clang = (Read-Checked $clang @('--version')); rust = $rust
    glslang = $glslangVersion; glslangSha256 = (Get-FileHash -LiteralPath $glslang -Algorithm SHA256).Hash
    clangSha256 = (Get-FileHash -LiteralPath $clang -Algorithm SHA256).Hash
    archiverSha256 = (Get-FileHash -LiteralPath $archiver -Algorithm SHA256).Hash
    headers = @(foreach ($header in @((Join-Path $wdk 'km\ntddk.h'), (Join-Path $wdk 'um\d3d10umddi.h'), (Join-Path $msvc 'vector'), (Join-Path $msvc 'vcruntime.h'))) { @{ name = (Split-Path $header -Leaf); sha256 = (Get-FileHash -LiteralPath $header -Algorithm SHA256).Hash } })
    msvc = $env:VCToolsVersion; wdk = '10.0.26100.0'; staticCrt = $true; archives = $archives
    cargoLockSha256 = (Get-FileHash -LiteralPath (Join-Path $RepoRoot 'umd\Cargo.lock') -Algorithm SHA256).Hash
    meson = (Read-Checked 'meson.exe' @('--version')); ninja = (Read-Checked 'ninja.exe' @('--version'))
}
$proof | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDir 'proof.json') -Encoding utf8
$allowed = @('exports.txt', 'helios_umd.dll', 'imports.txt', 'proof.json')
$files = @(Get-ChildItem -LiteralPath $OutputDir -File)
if (@(Get-ChildItem -LiteralPath $OutputDir -Directory).Count -or (@($files.Name | Sort-Object) -join '|') -ne ($allowed -join '|')) { throw 'Unexpected proof output.' }
if (($files | Measure-Object -Property Length -Sum).Sum -gt 100MB) { throw 'Proof artifact exceeds 100 MiB.' }
