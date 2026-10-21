[CmdletBinding()]
param(
    [ValidateSet('Validate', 'Admission', 'Package', 'Cleanup', 'Functions')][string]$Mode = 'Validate',
    [string]$RepoRoot = (Get-Location).Path,
    [string]$UnsignedZip,
    [string]$WorkRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$BaseCommit = 'df63daea50a1f53a348a6d4e241ca0f940804322'
$CoreHash = 'fc4114afbc9575d2f4e0760489730d74735bcb8d7fe366a165d15edfa4f5a1e0'
$UnsignedZipHash = 'fd2e60a7097069f28ce2716499845f6a10f826f95e535c057825e8affa285347'
$UmdHash = 'fa6d8ad88658b22b932c904fbf58a1d144c44a118b088a48e4c9bcbdf82f466e'
$KmdHash = '4e607d5b3282c4b7ac2ac116b408c1cc9c634b7c96e5e8300f5b6101ce942246'
$Provider = 'Microsoft Software Key Storage Provider'
$CoreMembers = @{
    'helios_kmd_render.inf' = '0df9d34ac9cf242e0ca9def4130e4190f8076918ff219a840c8130f3f91ba6d3'
    'helios_kmd_render.sys' = $KmdHash
    'original-public.cer' = '2668f0bcd0e1c9ba69480c5bedafcc51822940c97a778717a3922dd0a680451e'
    'provenance.json' = '689510a56e08cb8d0ec0e706a6bb736a929afd36e97693c108eca7f969237070'
}
$ToolSpecs = @{
    SignTool = @{ relativePath = '10.0.26100.0/x64/signtool.exe'; machine = 0x8664; distributor = 'Microsoft Windows SDK' }
    Inf2Cat = @{ relativePath = '10.0.26100.0/x86/Inf2Cat.exe'; machine = 0x14c; distributor = 'Microsoft Windows Driver Kit' }
}
function Require([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Save-Json($Value, [string]$Path) {
    $Value | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath "$Path.tmp" -Encoding utf8NoBOM
    Move-Item -LiteralPath "$Path.tmp" -Destination $Path -Force
}
function Source-Git([string[]]$Arguments) {
    $value = & git -C $RepoRoot @Arguments
    Require ($LASTEXITCODE -eq 0) 'Git source verification failed'
    $value
}
function Assert-Source {
    Require ((Source-Git @('rev-parse','HEAD^')) -ceq $BaseCommit) 'Wrong exact source parent'
    if ($env:GITHUB_SHA) { Require ((Source-Git @('rev-parse','HEAD')) -ceq $env:GITHUB_SHA) 'Wrong workflow source SHA' }
    $allowed = @('.github/workflows/windows-stack.yml','ci/windows/Package-SE2BDriver.ps1','ci/windows/inputs/se2-b-original-core.zip')
    $changed = @(Source-Git @('diff','--name-only','HEAD^','HEAD'))
    Require ($changed.Count -eq $allowed.Count -and (($allowed | Sort-Object) -join "`n") -ceq (($changed | Sort-Object) -join "`n")) 'Wrong candidate three-file scope'
    Source-Git (@('diff','--exit-code','HEAD','--') + $allowed) | Out-Null
    $expected = @{
        'ci/windows/Build-SE2UmdCandidate.ps1' = 'cdb34f59d584d0b2a4b6b0d853204885dda940d71dbfcc66bf484c8014e281b1'
        'umd/bridge/dxvk_bridge.cpp' = '859fda0bd105417c05fef74af7773937855c98ee59092dfb397e73da6f9e591e'
        'ci/windows/tests/queue-unwind-regression.py' = 'd111cef1f5a33bf8a1fb1adf12eeb75cb1c8459c9beb9b9508eaff6b5c7140c2'
        'ci/windows/patches/dxvk-queue-unwind.patch' = 'c8445d367110dd28fa4abdf24fa0db00e62e6688b1557a96deccae8d08e939ab'
    }
    foreach ($p in $expected.Keys) { Require ((Hash (Join-Path $RepoRoot $p)) -ceq $expected[$p]) "Source hash: $p" }
}
function Read-StrictZip([string]$Path, [string]$ExpectedHash, [string[]]$Names, [long]$MaxBytes) {
    Require ((Get-Item -LiteralPath $Path).Length -le $MaxBytes) 'Archive size bound'
    Require ((Hash $Path) -ceq $ExpectedHash) 'Archive hash mismatch'
    $z = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        Require ($z.Entries.Count -eq $Names.Count) 'Archive member count'
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $result = @{}; [long]$total = 0
        foreach ($e in $z.Entries) {
            Require ($Names -ccontains $e.FullName) 'Archive member allowlist'
            Require ($seen.Add($e.FullName)) 'Duplicate/case-colliding member'
            $type = ($e.ExternalAttributes -shr 16) -band 0xF000
            Require ($type -in @(0,0x8000)) 'Archive non-regular member'
            $total += $e.Length
            Require ($e.Length -gt 0 -and $total -le $MaxBytes) 'Expanded archive size bound'
            $s=$e.Open(); $m=[IO.MemoryStream]::new()
            try {
                $buffer=[byte[]]::new(16384)
                while (($count=$s.Read($buffer,0,$buffer.Length)) -gt 0) {
                    Require ($m.Length+$count -le $e.Length -and $m.Length+$count -le $MaxBytes) 'Stream expansion bound'
                    $m.Write($buffer,0,$count)
                }
                Require ($m.Length -eq $e.Length) 'Archive truncated member'
                $result[$e.FullName]=$m.ToArray()
            } finally { $s.Dispose();$m.Dispose() }
        }
        return ,$result
    } finally { $z.Dispose() }
}
function Bytes-Hash([byte[]]$Bytes) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant() }
function Read-Inputs {
    $core = Read-StrictZip (Join-Path $RepoRoot 'ci/windows/inputs/se2-b-original-core.zip') $CoreHash @($CoreMembers.Keys) 1048576
    foreach ($n in $CoreMembers.Keys) { Require ((Bytes-Hash $core[$n]) -ceq $CoreMembers[$n]) "Original core member hash: $n" }
    $provenance = [Text.Encoding]::UTF8.GetString($core['provenance.json']) | ConvertFrom-Json
    Require ($provenance.originalArchiveSha256 -ceq '0d973609f30f23694de03b74d0259f001458f93050f15e9d97d29b97f7528fe0') 'Original archive provenance'
    Require ($provenance.originalSourceCommit -ceq '7e0e6b73c140b919dde20679e65e3a23dae40764') 'Original source provenance'
    $umd = Read-StrictZip $UnsignedZip $UnsignedZipHash @('helios_umd.dll','proof.json','imports.txt','exports.txt') 16777216
    Require ((Bytes-Hash $umd['helios_umd.dll']) -ceq $UmdHash) 'Unsigned UMD hash'
    $inf = [Text.Encoding]::UTF8.GetString($core['helios_kmd_render.inf'])
    $old='DriverVer = 08/13/2026,22.22.259.0';$new='DriverVer = 10/21/2026,22.22.259.1'
    Require (($inf.Split($old).Count - 1) -eq 1) 'Exact original DriverVer occurrence'
    $updated=[Text.Encoding]::UTF8.GetBytes($inf.Replace($old,$new))
    Require ((Bytes-Hash $updated) -ceq '13b5c2c53ada61e906fbddba30a5b27809ff554b6f1ddb2471a29228185f2dbc') 'DriverVer-only INF hash'
    @{ core=$core; umd=$umd; inf=$updated }
}
function Assert-ToolVersion([string]$Raw) {
    Require ($Raw -cmatch '^(10\.0\.26100\.\d+)(?:\s.*)?$') 'STOP_TOOL_VERSION'
    $v=[version]$Matches[1]
    Require ($v.Major -eq 10 -and $v.Minor -eq 0 -and $v.Build -eq 26100 -and $v.Revision -ge 0) 'STOP_TOOL_VERSION'
}
function New-ToolChain { [Security.Cryptography.X509Certificates.X509Chain]::new() }
function Read-ToolSignature([string]$Path) {
    $sig=Get-AuthenticodeSignature -LiteralPath $Path
    Require ($sig.Status -eq 'Valid' -and $null -ne $sig.SignerCertificate) 'STOP_TOOL_SIGNATURE'
    $chain=New-ToolChain
    try {
        $chain.ChainPolicy.RevocationMode=[Security.Cryptography.X509Certificates.X509RevocationMode]::Online
        $chain.ChainPolicy.RevocationFlag=[Security.Cryptography.X509Certificates.X509RevocationFlag]::ExcludeRoot
        $chain.ChainPolicy.VerificationFlags=[Security.Cryptography.X509Certificates.X509VerificationFlags]::NoFlag
        [void]$chain.ChainPolicy.ApplicationPolicy.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3'))
        $valid=$chain.Build($sig.SignerCertificate)
        @{ status=[string]$sig.Status; signerSubject=$sig.SignerCertificate.Subject; signerThumbprint=$sig.SignerCertificate.Thumbprint; chainValid=$valid; chainSubjects=@($chain.ChainElements | ForEach-Object { $_.Certificate.Subject }); chainThumbprints=@($chain.ChainElements | ForEach-Object { $_.Certificate.Thumbprint }); chainStatus=@($chain.ChainStatus | ForEach-Object { [string]$_.Status }); signatureType=[string]$sig.SignatureType; timestampThumbprint=$(if($sig.TimeStamperCertificate){$sig.TimeStamperCertificate.Thumbprint}else{$null}); revocationMode='Authenticode platform policy; extra online chain is metadata, not timestamp policy'; distributorTrust='Windows Authenticode Valid is primary; current-time chain is not equivalent to timestamp-aware validation' }
    } finally { $chain.Dispose() }
}
function Read-ToolMachine([string]$Path) {
    $f=[IO.File]::OpenRead($Path);$reader=[IO.BinaryReader]::new($f)
    try {
        Require ($f.Length -ge 64 -and $reader.ReadUInt16() -eq 0x5A4D) 'STOP_TOOL_PE'
        $f.Position=60;$offset=$reader.ReadInt32()
        Require ($offset -ge 64 -and $offset+6 -le $f.Length) 'STOP_TOOL_PE'
        $f.Position=$offset;Require ($reader.ReadUInt32() -eq 0x4550) 'STOP_TOOL_PE'
        $reader.ReadUInt16()
    } finally { $reader.Dispose();$f.Dispose() }
}
function Read-ToolVersionInfo([string]$Path) { (Get-Item -LiteralPath $Path).VersionInfo }
function Assert-Tool([string]$Name, $Spec) {
    Require ($ToolSpecs.ContainsKey($Name) -and $Spec.relativePath -ceq $ToolSpecs[$Name].relativePath -and $Spec.machine -eq $ToolSpecs[$Name].machine) "STOP_TOOL_PATH:$Name"
    $root=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/bin'
    $p=[IO.Path]::GetFullPath((Join-Path $root $Spec.relativePath))
    Require (Test-Path -LiteralPath $p -PathType Leaf) "STOP_TOOL_ABSENT:$Name"
    $item=Get-Item -LiteralPath $p -Force
    $ancestor=$item
    while ($null -ne $ancestor) {
        Require (-not ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint)) "STOP_TOOL_REPARSE:$Name"
        $ancestor=$(if($ancestor -is [IO.FileInfo]){$ancestor.Directory}else{$ancestor.Parent})
    }
    Require ($item.FullName -ceq $p) "STOP_TOOL_PATH:$Name"
    $before=Hash $p
    $version=Read-ToolVersionInfo $p
    Assert-ToolVersion $version.FileVersion
    Assert-ToolVersion $version.ProductVersion
    Require ([IO.Path]::GetFileName($version.OriginalFilename) -ieq [IO.Path]::GetFileName($p)) "STOP_TOOL_FILENAME:$Name"
    Require ((Read-ToolMachine $p) -eq $Spec.machine) "STOP_TOOL_ARCHITECTURE:$Name"
    $trust=Read-ToolSignature $p
    Require ($trust.status -ceq 'Valid') "STOP_TOOL_SIGNATURE:$Name"
    $timeOnly=@($trust.chainStatus | Where-Object { $_ -notin @('NotTimeValid','NotTimeNested') }).Count -eq 0
    # Authenticode validates timestamps; generic current-time expiry cannot override a valid timestamped signature.
    $timestampedExpiry=$trust.timestampThumbprint -and $trust.chainStatus.Count -gt 0 -and $timeOnly
    Require (($trust.chainValid -eq $true -or $timestampedExpiry) -and $trust.chainSubjects.Count -ge 2) "STOP_TOOL_CHAIN_METADATA_UNVERIFIABLE:$Name"

    foreach ($subject in @($trust.signerSubject)+@($trust.chainSubjects)) {
        Require ($subject -cmatch '(^|,\s*)O=Microsoft Corporation(,|$)') "STOP_TOOL_PUBLISHER:$Name"
    }
    Require ((Hash $p) -ceq $before) "STOP_TOOL_CHANGED_DURING_ADMISSION:$Name"
    @{ name=$Name; path=$p; sha256=$before; bytes=$item.Length; fileVersion=$version.FileVersion; productVersion=$version.ProductVersion; machine=$Spec.machine; distributor=$Spec.distributor; officialSource=$(if($Name -eq 'SignTool'){'https://learn.microsoft.com/en-us/windows/win32/seccrypto/signtool'}else{'https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/inf2cat'}); trust=$trust; runnerImage=$env:ImageVersion; runnerOS=$env:RUNNER_OS }
}
function Recheck-Tool($Receipt) {
    $current=Assert-Tool $Receipt.name $ToolSpecs[$Receipt.name]
    foreach($field in @('path','sha256','fileVersion','productVersion','machine','bytes')) { Require ($current[$field] -ceq $Receipt[$field]) "STOP_TOOL_CHANGED:$field" }
    Require ($current.trust.signerThumbprint -ceq $Receipt.trust.signerThumbprint -and ($current.trust.chainThumbprints -join ',') -ceq ($Receipt.trust.chainThumbprints -join ',')) 'STOP_TOOL_CHANGED:trust'
}
function Assert-SpendAuthorization([string]$Value) {
    Require ($Value -ceq 'USD0.01') 'STOP_SPEND_AUTHORIZATION: exact future manual USD0.01 required'
    @{ futureManualAuthorization=$Value; currentTaskExecutionApproved=$false; accountHardCapVerified=$false; publicStandardComputeOnly=$true; maxArtifactBytes=104857600; retentionDays=1; incrementalStorageEstimateUsd=0.000872; estimateNotEnforcedAccountCap=$true }
}
function Assert-PublicEvent([string]$Path) {
    Require (Test-Path -LiteralPath $Path -PathType Leaf) 'STOP_PUBLIC_EVENT_MISSING'
    try { $event=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable } catch { throw 'STOP_PUBLIC_EVENT_MALFORMED' }
    Require ($event -is [Collections.IDictionary] -and $event.Contains('repository') -and $event.repository -is [Collections.IDictionary]) 'STOP_PUBLIC_EVENT_MISSING_REPOSITORY'
    $repo=$event.repository
    Require ($repo.Contains('private') -and $repo.private -is [bool] -and $repo.private -eq $false) 'STOP_PUBLIC_EVENT_PRIVATE_OR_TYPE'
    Require ($repo.Contains('full_name') -and $repo.full_name -is [string] -and $repo.full_name -ceq 'chandshy/helios') 'STOP_PUBLIC_EVENT_REPOSITORY'
}
function Assert-Admission {
    Require ($IsWindows) 'STOP_WINDOWS_ONLY'
    Require ($env:GITHUB_REPOSITORY -ceq 'chandshy/helios' -and $env:GITHUB_EVENT_NAME -ceq 'workflow_dispatch') 'STOP_REPOSITORY_OR_EVENT'
    Assert-PublicEvent $env:GITHUB_EVENT_PATH
    Require ($env:SE2_REPOSITORY_VISIBILITY -ceq 'public') 'STOP_PRIVATE_OR_UNKNOWN_REPOSITORY'
    Require ($env:RUNNER_ENVIRONMENT -ceq 'github-hosted' -and $env:RUNNER_OS -ceq 'Windows') 'STOP_RUNNER'
    Require ($env:GITHUB_RUN_ATTEMPT -ceq '1') 'STOP_RERUN'
    Assert-SpendAuthorization $env:SE2_SPEND_AUTHORIZATION
}
function Key-Exists([string]$Name) {
    [Security.Cryptography.CngKey]::Exists($Name,[Security.Cryptography.CngProvider]::new($Provider),[Security.Cryptography.CngKeyOpenOptions]::None)
}
function Cert-Exists([string]$Store,[string]$Thumb) { Test-Path -LiteralPath "Cert:\CurrentUser\$Store\$Thumb" }
function Cert-KeyName([string]$Thumb) {
    $cert=Get-Item -LiteralPath "Cert:\CurrentUser\My\$Thumb"
    $rsa=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
    try { Require ($rsa -is [Security.Cryptography.RSACng]) 'Owned key is not CNG';$rsa.Key.KeyName } finally { if ($rsa) { $rsa.Dispose() } }
}
function Remove-PublicTrust([string]$Store,[string]$Thumb) { Remove-Item -LiteralPath "Cert:\CurrentUser\$Store\$Thumb" -Force -ErrorAction Stop }
function Remove-CertAndKey([string]$Thumb) { Remove-Item -LiteralPath "Cert:\CurrentUser\My\$Thumb" -DeleteKey -Force -ErrorAction Stop }
function Remove-OwnedOrphan([string]$Name) {
    $key=[Security.Cryptography.CngKey]::Open($Name,[Security.Cryptography.CngProvider]::new($Provider),[Security.Cryptography.CngKeyOpenOptions]::None)
    try { $key.Delete() } finally { $key.Dispose() }
}
function Subject-CertThumbprints([string]$Subject) {
    @(Get-ChildItem -LiteralPath 'Cert:\CurrentUser\My' | Where-Object { $_.Subject -ceq $Subject } | ForEach-Object { $_.Thumbprint })
}
function Expected-KeyName {
    Require ($env:GITHUB_RUN_ID -cmatch '^[0-9]+$' -and $env:GITHUB_RUN_ATTEMPT -ceq '1') 'Invalid owned run/key identity'
    "SE2-WINDOCK-B-package-$($env:GITHUB_RUN_ID)-attempt-1"
}
function Cleanup-Owned($State) {
    $name=Expected-KeyName
    Require ($State.provider -ceq $Provider -and $State.keyName -ceq $name -and $State.preexistingKey -eq $false -and $State.creationStarted -eq $true) 'Unproved key ownership'
    $subject="CN=$name"
    Require ($State.ownedSubject -ceq $subject -and $State.preexistingOwnedCertificate -eq $false) 'Unproved certificate subject ownership'
    $thumb=$State.thumbprint
    if (-not $thumb) { Require ($State.publicStores.Count -eq 0) 'CLEANUP_UNVERIFIED: missing thumb after public trust started' }
    if ($thumb) {
        Require ($thumb -cmatch '^[0-9A-F]{40}$') 'Invalid owned thumbprint'
        foreach ($store in @('Root','TrustedPublisher')) {
            if (Cert-Exists $store $thumb) {
                Require ($State.publicStores -contains $store) 'Unowned public trust entry'
                Remove-PublicTrust $store $thumb
            }
        }
        if (Cert-Exists 'My' $thumb) {
            Require ((Cert-KeyName $thumb) -ceq $name) 'Certificate/key ownership mismatch'
            Remove-CertAndKey $thumb
        }
    }
    if (Key-Exists $name) { Remove-OwnedOrphan $name }
    Require (-not (Key-Exists $name)) 'Cleanup key remains'
    if ($thumb) { foreach ($store in @('My','Root','TrustedPublisher')) { Require (-not (Cert-Exists $store $thumb)) "Cleanup certificate remains:$store" } }
    Require (@(Subject-CertThumbprints $subject).Count -eq 0) 'CLEANUP_UNVERIFIED: owned subject certificate remains; missing/ambiguous thumb receipt requires exact recovery'
    @{ passed=$true; keyExists=$false; provider=$Provider; keyName=$name; thumbprint=$thumb; myOwnedSubjectAbsent=$true; storesAbsent=$(if($thumb){@('My','Root','TrustedPublisher')}else{@()}); publicTrustNeverStarted=(-not $thumb); nativePostconditions=$true }
}
function Native([string]$Tool,[string[]]$Arguments) {
    & $Tool @Arguments
    Require ($LASTEXITCODE -eq 0) "Native tool failed: $([IO.Path]::GetFileName($Tool))"
}
function Negative-Verification([string]$Tool,[string]$Out,[string]$NegativeRoot,[string]$OriginalRootSubject,[string]$Log) {
    $codes=@{}
    foreach ($case in @('altered-umd','changed-inf','missing-member','wrong-cert')) {
        $dir=Join-Path $NegativeRoot $case;New-Item -ItemType Directory -Path $dir -Force | Out-Null
        foreach ($name in @('helios_kmd_render.inf','helios_kmd_render.sys','helios_umd.dll','helios_kmd_render.cat')) { Copy-Item -LiteralPath (Join-Path $Out $name) -Destination $dir }
        $member=Join-Path $dir 'helios_umd.dll'
        switch ($case) {
            'altered-umd' { $b=[IO.File]::ReadAllBytes($member);$b[4096]=$b[4096] -bxor 1;[IO.File]::WriteAllBytes($member,$b) }
            'changed-inf' { $member=Join-Path $dir 'helios_kmd_render.inf';[IO.File]::AppendAllText($member,"`r`n; negative hash mutation`r`n") }
            'missing-member' { Remove-Item -LiteralPath $member -ErrorAction Stop }
        }
        $args=@('verify','/v','/pa','/c',(Join-Path $dir 'helios_kmd_render.cat'))
        if ($case -eq 'wrong-cert') { $args+=@('/r',$OriginalRootSubject) }
        $args+=,$member
        Recheck-Tool $script:AdmittedSignTool
        & $Tool @args *>> $Log
        $codes[$case]=$LASTEXITCODE
        Require ($LASTEXITCODE -ne 0) "SDK negative verifier falsely accepted:$case"
    }
    $codes
}
function Assert-UmdPayload([byte[]]$Before,[byte[]]$After) {
    # Signing may change only checksum, certificate directory, and trailing certificate/padding.
    $pe=[BitConverter]::ToInt32($Before,60); $opt=$pe+24
    Require ([BitConverter]::ToUInt16($Before,$opt) -eq 0x20B) 'Expected AMD64 PE32+ UMD'
    Require ([BitConverter]::ToInt32($Before,$opt+144) -eq 0) 'Input UMD already signed'
    $offset=[BitConverter]::ToInt32($After,$opt+144);$size=[BitConverter]::ToInt32($After,$opt+148)
    Require ($offset -ge $Before.Length -and $offset -le $Before.Length+7 -and $size -gt 0 -and $offset+$size -eq $After.Length) 'Unexpected certificate overlay'
    $left=[byte[]]$Before.Clone();$right=[byte[]]::new($Before.Length);[Array]::Copy($After,$right,$right.Length)
    foreach ($at in @(($opt+64),($opt+144),($opt+148))) { [Array]::Clear($left,$at,4);[Array]::Clear($right,$at,4) }
    Require ((Bytes-Hash $left) -ceq (Bytes-Hash $right)) 'UMD payload/import/export bytes changed'
    for ($i=$Before.Length;$i -lt $offset;$i++) { Require ($After[$i] -eq 0) 'Unexpected signing padding' }
}
function Assert-Output([string]$Dir) {
    $allowed=@('helios_kmd_render.inf','helios_kmd_render.sys','helios_umd.dll','helios_kmd_render.cat','public.cer','proof.json','verification.log','cleanup-proof.json')
    $files=@(Get-ChildItem -LiteralPath $Dir -Force)
    Require ($files.Count -eq $allowed.Count) 'Output member count'
    [long]$total=0
    foreach ($f in $files) {
        Require (-not $f.PSIsContainer -and -not ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $allowed -ccontains $f.Name) 'Output allowlist/type'
        $total+=$f.Length
    }
    Require ($total -le 104857600) 'Output 100MiB bound'
}
function Package {
    Assert-Source;$spend=Assert-Admission
    $tools=@{};foreach ($name in $ToolSpecs.Keys) { $tools[$name]=Assert-Tool $name $ToolSpecs[$name] }
    $inputs=Read-Inputs
    Require (-not (Test-Path -LiteralPath $WorkRoot)) 'Work root must be fresh'
    New-Item -ItemType Directory -Path $WorkRoot | Out-Null
    $out=Join-Path $WorkRoot 'public';New-Item -ItemType Directory -Path $out | Out-Null
    $statePath=Join-Path $WorkRoot 'owned-key.json';$cleanupPath=Join-Path $out 'cleanup-proof.json'
    foreach ($tool in $tools.Values) { Recheck-Tool $tool }
    $name=Expected-KeyName;Require (-not (Key-Exists $name)) 'Key name already exists'
    $subject="CN=$name"
    Require (@(Subject-CertThumbprints $subject).Count -eq 0) 'Owned certificate subject already exists'
    $state=@{provider=$Provider;keyName=$name;ownedSubject=$subject;preexistingOwnedCertificate=$false;preexistingKey=$false;creationStarted=$true;thumbprint=$null;publicStores=@()}
    Save-Json $state $statePath
    try {
        foreach ($tool in $tools.Values) { Recheck-Tool $tool }
        $cert=New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=$name" -CertStoreLocation 'Cert:\CurrentUser\My' -Provider $Provider -Container $name -KeyExportPolicy NonExportable -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 -KeyUsage DigitalSignature -NotAfter (Get-Date).AddDays(7)
        $state.thumbprint=$cert.Thumbprint;Save-Json $state $statePath
        Require ((Cert-KeyName $cert.Thumbprint) -ceq $name) 'Generated container mismatch'
        Require ($cert.EnhancedKeyUsageList.ObjectId.Value -contains '1.3.6.1.5.5.7.3.3') 'Code signing EKU absent'
        $cer=Join-Path $out 'public.cer';Export-Certificate -Cert $cert -FilePath $cer | Out-Null
        foreach ($store in @('Root','TrustedPublisher')) {
            Require (-not (Cert-Exists $store $cert.Thumbprint)) 'Public trust preexists'
            $state.publicStores+=,$store;Save-Json $state $statePath
            Import-Certificate -FilePath $cer -CertStoreLocation "Cert:\CurrentUser\$store" | Out-Null
        }
        [IO.File]::WriteAllBytes((Join-Path $out 'helios_kmd_render.sys'),$inputs.core['helios_kmd_render.sys'])
        [IO.File]::WriteAllBytes((Join-Path $out 'helios_kmd_render.inf'),$inputs.inf)
        $dll=Join-Path $out 'helios_umd.dll';[IO.File]::WriteAllBytes($dll,$inputs.umd['helios_umd.dll'])
        $log=Join-Path $out 'verification.log'
        Recheck-Tool $tools.SignTool
        Native $tools.SignTool.path @('sign','/fd','SHA256','/s','My','/sha1',$cert.Thumbprint,$dll) *> $log
        Assert-UmdPayload $inputs.umd['helios_umd.dll'] ([IO.File]::ReadAllBytes($dll))
        Recheck-Tool $tools.Inf2Cat
        Native $tools.Inf2Cat.path @("/driver:$out",'/os:10_X64') *>> $log
        $cat=Join-Path $out 'helios_kmd_render.cat'
        Recheck-Tool $tools.SignTool
        Native $tools.SignTool.path @('sign','/fd','SHA256','/s','My','/sha1',$cert.Thumbprint,$cat) *>> $log
        foreach ($file in @('helios_kmd_render.inf','helios_kmd_render.sys','helios_umd.dll')) {
            Recheck-Tool $tools.SignTool
        Native $tools.SignTool.path @('verify','/v','/pa','/c',$cat,(Join-Path $out $file)) *>> $log
        }
        Recheck-Tool $tools.SignTool
        Native $tools.SignTool.path @('verify','/v','/pa',$cat) *>> $log
        Require ((Hash (Join-Path $out 'helios_kmd_render.sys')) -ceq $KmdHash) 'Original signed KMD changed'
        foreach ($file in @($dll,$cat)) {
            $sig=Get-AuthenticodeSignature -LiteralPath $file
            Require ($sig.Status -eq 'Valid' -and $sig.SignerCertificate.Thumbprint -ceq $cert.Thumbprint) 'New package signer verification'
        }
        $originalCert=[Security.Cryptography.X509Certificates.X509Certificate2]::new([byte[]]$inputs.core['original-public.cer'])
        try { $script:AdmittedSignTool=$tools.SignTool;$negativeCodes=Negative-Verification $tools.SignTool.path $out (Join-Path $WorkRoot 'negative') $originalCert.Subject $log } finally { $originalCert.Dispose() }
        $hashes=@{};foreach ($file in @('helios_kmd_render.inf','helios_kmd_render.sys','helios_umd.dll','helios_kmd_render.cat','public.cer')) { $hashes[$file]=Hash (Join-Path $out $file) }
        Save-Json @{sourceCommit=(Source-Git @('rev-parse','HEAD'));baseCommit=$BaseCommit;originalArchiveSha256='0d973609f30f23694de03b74d0259f001458f93050f15e9d97d29b97f7528fe0';unsignedUmdSha256=$UmdHash;activeIcdSha256='b194046ba0df4bfdbf39c8253925c251ac795f37b0d935752ac2d01faddbe892';guestTouched=$false;signerThumbprint=$cert.Thumbprint;notBefore=$cert.NotBefore.ToUniversalTime().ToString('o');notAfter=$cert.NotAfter.ToUniversalTime().ToString('o');hashes=$hashes;tools=$tools;spendBoundary=$spend;negativeVerificationExitCodes=$negativeCodes;nativeDriverPolicyOrPnpAccepted=$false} (Join-Path $out 'proof.json')
    } finally {
        Save-Json (Cleanup-Owned $state) $cleanupPath
    }
    Assert-Output $out
}
if ($Mode -eq 'Functions') { return }
switch ($Mode) {
    'Admission' { Assert-Source;Assert-Admission | ConvertTo-Json }
    'Validate' { Assert-Source;$inputs=Read-Inputs;@{passed=$true;inputOnly=$true;coreSha256=$CoreHash;unsignedUmdSha256=$UmdHash;nativeExecution=$false} | ConvertTo-Json }
    'Package' { Package }
    'Cleanup' {
        $statePath=Join-Path $WorkRoot 'owned-key.json'
        if (Test-Path -LiteralPath $statePath) {
            $state=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
            Save-Json (Cleanup-Owned $state) (Join-Path $WorkRoot 'public/cleanup-proof.json')
        } else { Write-Output 'No owned creation receipt: no cleanup claimed; forced runner loss is unverified.' }
    }
}
