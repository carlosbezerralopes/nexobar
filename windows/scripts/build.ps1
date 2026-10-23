#Requires -Version 7
[CmdletBinding()]
param(
    [string]$ArtifactsDirectory,
    [string]$PackagesDirectory,
    [string]$OutputZip
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$projectRoot = Split-Path $root -Parent
if (!$ArtifactsDirectory) { $ArtifactsDirectory = Join-Path ([IO.Path]::GetTempPath()) 'NexoBar/windows-build' }
if (!$PackagesDirectory) { $PackagesDirectory = Join-Path $ArtifactsDirectory 'nuget' }
if (!$OutputZip) { $OutputZip = Join-Path $projectRoot 'dist/NexoBar-Windows-x64-preview.zip' }
foreach ($path in @($ArtifactsDirectory, $PackagesDirectory, (Split-Path $OutputZip -Parent))) { New-Item -ItemType Directory -Force $path | Out-Null }
$ArtifactsDirectory = [IO.Path]::GetFullPath($ArtifactsDirectory)
$PackagesDirectory = [IO.Path]::GetFullPath($PackagesDirectory)
$env:NUGET_PACKAGES = $PackagesDirectory
$env:DOTNET_CLI_HOME = Join-Path $ArtifactsDirectory 'dotnet-home'
$env:NUGET_HTTP_CACHE_PATH = Join-Path $ArtifactsDirectory 'nuget-http'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
$sdk = & dotnet --version
if ($LASTEXITCODE -ne 0 -or $sdk -notmatch '^10\.') { throw '.NET SDK 10 é obrigatório.' }
$testProject = Join-Path $root 'tests/NexoBar.Core.Tests.csproj'
& dotnet run --project $testProject -c Release --artifacts-path $ArtifactsDirectory -- (Join-Path $ArtifactsDirectory 'fixture-state')
if ($LASTEXITCODE -ne 0) { throw 'Fixtures do core falharam.' }
$bridgeTests = Join-Path $root 'widbar/tests/Bridge.Tests.csproj'
& dotnet run --project $bridgeTests -c Release --artifacts-path $ArtifactsDirectory
if ($LASTEXITCODE -ne 0) { throw 'Testes da ponte WidBar falharam.' }
$nativeTests = Join-Path $root 'native-tests/NexoBar.ConPty.Tests.csproj'
& dotnet build $nativeTests -c Release --artifacts-path $ArtifactsDirectory
if ($LASTEXITCODE -ne 0) { throw 'Compilação do harness ConPTY falhou.' }
if ($IsWindows) {
    & dotnet run --no-build --project $nativeTests -c Release --artifacts-path $ArtifactsDirectory -- (Join-Path $ArtifactsDirectory 'conpty-lifecycle')
    if ($LASTEXITCODE -ne 0) { throw 'Lifecycle ConPTY nativo falhou.' }
}
$publish = Join-Path $ArtifactsDirectory 'publish'
if (Test-Path $publish) { Remove-Item $publish -Recurse -Force }
& dotnet publish (Join-Path $root 'app/NexoBar.Windows.csproj') -c Release -r win-x64 --self-contained true -p:EnableWindowsTargeting=true --artifacts-path $ArtifactsDirectory -o $publish
if ($LASTEXITCODE -ne 0) { throw 'Compilação Windows falhou.' }
if (!(Test-Path (Join-Path $publish 'NexoBar.exe'))) { throw 'Executável não foi produzido.' }
Copy-Item (Join-Path $root 'README.md') (Join-Path $publish 'LEIA-ME-WINDOWS.md') -Force
Copy-Item (Join-Path $projectRoot 'LICENSE') $publish -Force
Copy-Item (Join-Path $projectRoot 'THIRD_PARTY_NOTICES.md') $publish -Force
Copy-Item (Join-Path $root 'docs') (Join-Path $publish 'docs') -Recurse -Force
Copy-Item (Join-Path $projectRoot 'docs/ATTRIBUTION.md') (Join-Path $publish 'docs/ATTRIBUTION.md') -Force
Copy-Item (Join-Path $root 'scripts/smoke-windows.ps1') $publish -Force
$nativePublish = Join-Path $publish 'native-tests'
& dotnet publish $nativeTests -c Release -r win-x64 --self-contained true --artifacts-path $ArtifactsDirectory -o $nativePublish
if ($LASTEXITCODE -ne 0) { throw 'Publicação do harness ConPTY falhou.' }
# The portable app is runnable; this separately labelled source kit still requires
# Windows WinUI/MakeAppx tooling to produce the companion MSIX.
$widgetSource = Join-Path $publish 'widbar-source/windows'
New-Item -ItemType Directory -Force $widgetSource | Out-Null
Copy-Item (Join-Path $root 'Directory.Build.props') $widgetSource -Force
foreach ($directory in @('core','widbar')) {
    $origin = Join-Path $root $directory
    Get-ChildItem $origin -Recurse -File | Where-Object {
        $relative = [IO.Path]::GetRelativePath($origin, $_.FullName)
        $relative -notmatch '(^|[/\\])(obj|bin)([/\\]|$)' -and
        ($_.Extension -in @('.cs','.csproj','.ps1','.md','.txt','.xaml','.manifest','.appxmanifest') -or $_.Name -eq 'packages.lock.json')
    } | ForEach-Object {
        $destination = Join-Path (Join-Path $widgetSource $directory) ([IO.Path]::GetRelativePath($origin, $_.FullName))
        New-Item -ItemType Directory -Force (Split-Path $destination -Parent) | Out-Null
        Copy-Item $_.FullName $destination -Force
    }
}
$notices = Join-Path $publish 'licenses'
New-Item -ItemType Directory -Force $notices | Out-Null
Get-ChildItem $PackagesDirectory -Recurse -File | Where-Object { $_.Name -match '^(LICENSE|LICENCE|COPYING|THIRD.PARTY)' -and $_.Extension -notin '.dll','.xml' } | ForEach-Object {
    $relative = [IO.Path]::GetRelativePath($PackagesDirectory, $_.FullName).Replace([IO.Path]::DirectorySeparatorChar, '_')
    Copy-Item $_.FullName (Join-Path $notices $relative) -Force
}
$lhmLicense = Join-Path $root 'docs/LICENSE-LibreHardwareMonitor-MPL-2.0.txt'
if (!(Test-Path $lhmLicense)) { throw 'Licença MPL não encontrada.' }
Copy-Item $lhmLicense $notices -Force
Get-ChildItem $publish -Recurse -Filter '*.pdb' | Remove-Item -Force
$manifest = Get-ChildItem $publish -Recurse -File | ForEach-Object {
    [ordered]@{ path = [IO.Path]::GetRelativePath($publish, $_.FullName); bytes = $_.Length; sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $publish 'package-manifest.json') -Encoding utf8
Compress-Archive -Path (Join-Path $publish '*') -DestinationPath $OutputZip -Force -CompressionLevel Optimal
[ordered]@{ zip = $OutputZip; sha256 = (Get-FileHash $OutputZip -Algorithm SHA256).Hash.ToLowerInvariant(); sdk = $sdk; target = 'win-x64'; selfContained = $true; nativeWindowsExecution = 'GUI/sensores não executados por este build'; nativeConPtyLifecycle = $(if ($IsWindows) { 'executado com processos sintéticos' } else { 'pendente: exige Windows nativo' }) } | ConvertTo-Json
