#Requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PortableDirectory,
    [Parameter(Mandatory)][string]$SignedCompanion,
    [string]$PublicCertificate,
    [string]$ArtifactsDirectory,
    [string]$PackagesDirectory
)
$ErrorActionPreference = 'Stop'
if (!$IsWindows -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') { throw 'Build do instalador exige Windows x64.' }
if (!$ArtifactsDirectory) { $ArtifactsDirectory = Join-Path ([IO.Path]::GetTempPath()) 'NexoBar/setup-build' }
$ArtifactsDirectory = [IO.Path]::GetFullPath($ArtifactsDirectory)
if (!$PackagesDirectory) { $PackagesDirectory = Join-Path $ArtifactsDirectory 'nuget' }
$env:NUGET_PACKAGES = [IO.Path]::GetFullPath($PackagesDirectory)
$env:DOTNET_CLI_HOME = Join-Path $ArtifactsDirectory 'dotnet-home'
$env:NUGET_HTTP_CACHE_PATH = Join-Path $ArtifactsDirectory 'nuget-http'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
New-Item -ItemType Directory -Force $ArtifactsDirectory | Out-Null
if ((& dotnet --version) -notmatch '^10\.') { throw '.NET SDK 10 é obrigatório somente para compilar.' }
$PortableDirectory = (Resolve-Path -LiteralPath $PortableDirectory).Path
$SignedCompanion = (Resolve-Path -LiteralPath $SignedCompanion).Path
Write-Host 'Conferindo versão, identidade e assinatura das entradas…'
if (!(Test-Path -LiteralPath (Join-Path $PortableDirectory 'NexoBar.exe'))) { throw 'Portátil não contém NexoBar.exe.' }
$version = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $PortableDirectory 'NexoBar.exe')).ProductVersion
if ($version -notmatch '^0\.6\.0([+.-]|$)') { throw "Versão portátil incompatível: $version" }
if ((Get-Item -LiteralPath $SignedCompanion).Extension -ne '.msix') { throw 'Companion deve ser MSIX.' }
$signature = Get-AuthenticodeSignature -LiteralPath $SignedCompanion
if ($signature.Status -ne 'Valid' -or !$signature.SignerCertificate) { throw "Companion sem assinatura válida/confiável no ambiente de build: $($signature.Status). Não aceitar erro de cadeia como prova de integridade." }
if ($signature.SignerCertificate.Subject -ne 'CN=NexoBar') { throw 'Publisher inesperado.' }
if ($PublicCertificate) {
    $PublicCertificate = (Resolve-Path -LiteralPath $PublicCertificate).Path
    $certBytes = [IO.File]::ReadAllBytes($PublicCertificate)
    if ([Security.Cryptography.X509Certificates.X509Certificate2]::GetCertContentType($certBytes) -ne 'Cert') { throw 'Somente certificado público DER .cer é permitido; PFX/chaves são recusados.' }
    $cert = [Security.Cryptography.X509Certificates.X509CertificateLoader]::LoadCertificate($certBytes)
    if ($cert.HasPrivateKey -or $cert.Subject -ne 'CN=NexoBar' -or [Convert]::ToHexString($cert.RawData) -ne [Convert]::ToHexString($signature.SignerCertificate.RawData)) { throw 'Certificado não corresponde ao signatário público.' }
    $cert.Dispose()
}
$archive = [IO.Compression.ZipFile]::OpenRead($SignedCompanion)
try {
    if (!$archive.GetEntry('AppxSignature.p7x')) { throw 'MSIX não assinado.' }
    $reader = [IO.StreamReader]::new($archive.GetEntry('AppxManifest.xml').Open())
    try { [xml]$appx = $reader.ReadToEnd() } finally { $reader.Dispose() }
    $identity = $appx.Package.Identity
    if ($identity.Name -ne 'NexoBar.Widget' -or $identity.Publisher -ne 'CN=NexoBar' -or $identity.Version -ne '0.6.0.0' -or $identity.ProcessorArchitecture -ne 'x64') { throw 'Identidade/versão/arquitetura do companion incompatível.' }
} finally { $archive.Dispose() }
$context = Join-Path $ArtifactsDirectory ('payload-' + [Guid]::NewGuid().ToString('N'))
Write-Host 'Preparando payload interno com documentação/licenças e hashes…'
$stage = Join-Path $context 'files'
New-Item -ItemType Directory -Force (Join-Path $stage 'app'),(Join-Path $stage 'companion') | Out-Null
$files = @(Get-ChildItem -LiteralPath $PortableDirectory -Recurse -File | Where-Object {
    $relative = [IO.Path]::GetRelativePath($PortableDirectory, $_.FullName).Replace('\','/')
    $relative -notmatch '(^|/)(native-tests|widbar-source|bin|obj|cache|caches|logs|reports|\.git)(/|$)' -and
    $_.Extension -notin @('.pdb','.pfx','.p12','.key','.pem','.ps1','.cs','.csproj','.nupkg','.log') -and $_.Name -ne 'package-manifest.json' -and
    ($_.Extension -in @('.exe','.dll','.md','.txt','.xml','.dat','.bin') -or $_.Name -in @('NexoBar.deps.json','NexoBar.runtimeconfig.json') -or $relative -match '^(licenses|docs)/' -or $_.Name -match '^(LICENSE|LICENCE|COPYING)')
})
foreach ($file in $files) {
    if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Link no portátil: $($file.Name)" }
    $relative = [IO.Path]::GetRelativePath($PortableDirectory, $file.FullName)
    $destination = Join-Path (Join-Path $stage 'app') $relative
    New-Item -ItemType Directory -Force (Split-Path $destination -Parent) | Out-Null
    Copy-Item -LiteralPath $file.FullName -Destination $destination
}
# Reject private material anywhere in the input tree rather than accidentally shipping it.
if (Get-ChildItem -LiteralPath $PortableDirectory -Recurse -File | Where-Object { $_.Extension -in @('.pfx','.p12','.key','.pem') }) { throw 'Material privado no portátil: remova-o da entrada do build.' }
Copy-Item -LiteralPath $SignedCompanion -Destination (Join-Path $stage 'companion/NexoBar.Widget.msix')
if ($PublicCertificate) { Copy-Item -LiteralPath $PublicCertificate -Destination (Join-Path $stage 'companion/publisher.cer') }
$entries = @(Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object FullName | ForEach-Object {
    [ordered]@{ Path = [IO.Path]::GetRelativePath($stage, $_.FullName).Replace('\','/'); Bytes = $_.Length; Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
})
$manifest = [ordered]@{ SchemaVersion=1; Version='0.6.0'; Architecture='x64'; CompanionName='NexoBar.Widget'; CompanionPublisher='CN=NexoBar'; CompanionVersion='0.6.0.0'; Files=$entries }
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $context 'manifest.json') -Encoding utf8NoBOM
$output = [IO.Compression.ZipFile]::Open((Join-Path $context 'payload.zip'), [IO.Compression.ZipArchiveMode]::Create)
try { foreach ($file in Get-ChildItem -LiteralPath $stage -Recurse -File) { [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($output, $file.FullName, [IO.Path]::GetRelativePath($stage,$file.FullName).Replace('\','/'), [IO.Compression.CompressionLevel]::Optimal) | Out-Null } }
finally { $output.Dispose() }
& dotnet run --project (Join-Path $PSScriptRoot 'tests/NexoBar.Setup.Tests.csproj') -c Release --artifacts-path $ArtifactsDirectory -- (Join-Path $ArtifactsDirectory 'tests')
if ($LASTEXITCODE -ne 0) { throw 'Fixtures de instalação falharam.' }
$publish = Join-Path $ArtifactsDirectory 'publish'
Write-Host 'Publicando instalador WPF autocontido…'
& dotnet publish (Join-Path $PSScriptRoot 'NexoBar.Setup.csproj') -c Release -r win-x64 --self-contained true --artifacts-path $ArtifactsDirectory -p:SetupPayloadDirectory=$context -o $publish
if ($LASTEXITCODE -ne 0) { throw 'Build self-contained falhou.' }
$exe = Join-Path $publish 'NexoBar-Setup-x64.exe'
if (!(Test-Path -LiteralPath $exe)) { throw 'Executável não produzido.' }
$env:DOTNET_BUNDLE_EXTRACT_BASE_DIR = Join-Path $ArtifactsDirectory 'runtime-extract'
Write-Host 'Verificando payload e assinatura MSIX incorporados (sem instalação)…'
$verification = Start-Process -FilePath $exe -ArgumentList '--verify-embedded-payload' -WindowStyle Hidden -PassThru -Wait -RedirectStandardOutput (Join-Path $ArtifactsDirectory 'embedded-verification.json') -RedirectStandardError (Join-Path $ArtifactsDirectory 'embedded-verification-error.txt')
if ($verification.ExitCode -ne 0) { throw "Payload incorporado recusado: $($verification.ExitCode). Leia embedded-verification-error.txt." }
[ordered]@{ exe=$exe; bytes=(Get-Item -LiteralPath $exe).Length; sha256=(Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant(); version='0.6.0'; selfContained=$true; singleFile=$true; signedExe=$false; payloadContext=$context; embeddedVerification=(Get-Content -Raw (Join-Path $ArtifactsDirectory 'embedded-verification.json')); deployment='não executado; Store/MSIX/trust simulados no harness' } | ConvertTo-Json -Depth 6 | Tee-Object -FilePath (Join-Path $ArtifactsDirectory 'build-result.json')
