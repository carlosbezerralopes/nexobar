#Requires -Version 7
[CmdletBinding()]
param(
    [ValidateSet('x64','arm64')][string]$Architecture = 'x64',
    [string]$ArtifactsDirectory,
    [string]$Publisher = 'CN=NexoBar',
    [string]$MakeAppxPath,
    [switch]$ContractOnly
)
$ErrorActionPreference = 'Stop'
if (!$ArtifactsDirectory) { $ArtifactsDirectory = Join-Path ([IO.Path]::GetTempPath()) 'NexoBar/widbar-build' }
$ArtifactsDirectory = [IO.Path]::GetFullPath($ArtifactsDirectory)
New-Item -ItemType Directory -Force $ArtifactsDirectory | Out-Null
$env:DOTNET_CLI_HOME = Join-Path $ArtifactsDirectory 'dotnet-home'
$env:NUGET_PACKAGES = Join-Path $ArtifactsDirectory 'nuget'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
$sdk = & dotnet --version
if ($LASTEXITCODE -ne 0 -or $sdk -notmatch '^10\.') { throw '.NET SDK 10 é obrigatório.' }
& dotnet run --project (Join-Path $PSScriptRoot 'tests/Bridge.Tests.csproj') -c Release --artifacts-path (Join-Path $ArtifactsDirectory 'tests')
if ($LASTEXITCODE -ne 0) { throw 'Contratos da bridge falharam.' }
$project = Join-Path $PSScriptRoot 'NexoBar.Widget.csproj'
if ($ContractOnly) {
    & dotnet build $project -c Release -p:ContractBuild=true "-p:RuntimeIdentifier=win-$Architecture" --artifacts-path (Join-Path $ArtifactsDirectory 'contracts')
    if ($LASTEXITCODE -ne 0) { throw 'Compilação C# contra SDK real falhou.' }
    Write-Output 'Contrato C# compilado. Não é um executável WinUI/MSIX; XAML, ativação e UI exigem Windows.'
    exit 0
}
if (!$IsWindows) { throw 'WinUI/XAML e MakeAppx exigem Windows nativo. Use -ContractOnly para conferir C# no macOS/Linux.' }
& dotnet restore $project "-p:RuntimeIdentifier=win-$Architecture" --artifacts-path (Join-Path $ArtifactsDirectory 'build')
if ($LASTEXITCODE -ne 0) { throw 'Restore do companion falhou.' }
if (!$MakeAppxPath) {
    $lock = Get-Content (Join-Path $PSScriptRoot 'packages.lock.json') -Raw | ConvertFrom-Json
    $sdkToolsVersion = ($lock.dependencies.PSObject.Properties | Select-Object -First 1).Value.'Microsoft.Windows.SDK.BuildTools'.resolved
    $sdkTools = Join-Path $env:NUGET_PACKAGES "microsoft.windows.sdk.buildtools/$sdkToolsVersion/bin"
    if (Test-Path $sdkTools) {
        $MakeAppxPath = Get-ChildItem $sdkTools -Filter makeappx.exe -Recurse | Where-Object { $_.Directory.Name -eq 'x64' } | Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if (!$MakeAppxPath) {
        $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/bin'
        if (Test-Path $kits) {
            $MakeAppxPath = Get-ChildItem $kits -Filter makeappx.exe -Recurse | Where-Object { $_.Directory.Name -eq 'x64' } | Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
        }
    }
}
if (!$MakeAppxPath -or !(Test-Path $MakeAppxPath)) { throw 'MakeAppx.exe ausente no pacote SDK restaurado e no Windows SDK. Informe -MakeAppxPath.' }
$stage = [IO.Path]::GetFullPath((Join-Path $ArtifactsDirectory "stage-$Architecture"))
if (![IO.Path]::GetRelativePath($ArtifactsDirectory, $stage).Equals("stage-$Architecture", [StringComparison]::OrdinalIgnoreCase)) { throw 'Stage fora do diretório de artefatos.' }
if (Test-Path $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
$payload = $stage
New-Item -ItemType Directory -Force $payload,(Join-Path $stage 'Public'),(Join-Path $stage 'Assets') | Out-Null
& dotnet publish $project -c Release "-p:RuntimeIdentifier=win-$Architecture" --self-contained true -p:WindowsAppSDKSelfContained=true --artifacts-path (Join-Path $ArtifactsDirectory 'build') -o $payload
if ($LASTEXITCODE -ne 0) { throw 'Compilação WinUI falhou.' }
Get-ChildItem $payload -Recurse -Filter '*.pdb' -File | Remove-Item -Force
$licenses = Join-Path $payload 'licenses'
New-Item -ItemType Directory -Force $licenses | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'LICENSE-WidBar-SDK.txt') $licenses
Get-ChildItem $env:NUGET_PACKAGES -Recurse -File | Where-Object { $_.Name -match '^(LICENSE|LICENCE|COPYING|THIRD.PARTY)' -and $_.Extension -notin '.dll','.xml' } | ForEach-Object {
    $name = [IO.Path]::GetRelativePath($env:NUGET_PACKAGES, $_.FullName).Replace([IO.Path]::DirectorySeparatorChar, '_')
    Copy-Item $_.FullName (Join-Path $licenses $name)
}
$catalog = Join-Path $PSScriptRoot 'obj/widbar/plugin.json'
if (!(Test-Path $catalog)) { throw 'SDK não gerou plugin.json.' }
Copy-Item $catalog (Join-Path $stage 'Public/plugin.json')
[xml]$manifest = Get-Content (Join-Path $PSScriptRoot 'Package.appxmanifest')
$manifest.Package.Identity.Publisher = $Publisher
$manifest.Package.Identity.ProcessorArchitecture = $Architecture
$manifest.Save((Join-Path $stage 'AppxManifest.xml'))
# Reproducible package marks, rendered locally; no generated or remote artwork dependencies.
Add-Type -AssemblyName System.Drawing.Common
foreach ($entry in @(@('StoreLogo',50),@('Square150x150Logo',150),@('Square44x44Logo',44))) {
    $size = [int]$entry[1]
    $bitmap = [Drawing.Bitmap]::new($size,$size)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear([Drawing.Color]::FromArgb(25,74,110))
    $font = [Drawing.Font]::new('Segoe UI',([single]($size*.55)),[Drawing.FontStyle]::Bold,[Drawing.GraphicsUnit]::Pixel)
    $format = [Drawing.StringFormat]::new(); $format.Alignment = 'Center'; $format.LineAlignment = 'Center'
    $graphics.DrawString('N',$font,[Drawing.Brushes]::White,[Drawing.RectangleF]::new(0,0,$size,$size),$format)
    $bitmap.Save((Join-Path $stage "Assets/$($entry[0]).png"),[Drawing.Imaging.ImageFormat]::Png)
    $format.Dispose(); $font.Dispose(); $graphics.Dispose(); $bitmap.Dispose()
}
$output = Join-Path $ArtifactsDirectory "NexoBar-WidBar-$Architecture-unsigned.msix"
& $MakeAppxPath pack /d $stage /p $output /o
if ($LASTEXITCODE -ne 0 -or !(Test-Path $output)) { throw 'Empacotamento MSIX falhou.' }
[ordered]@{ path=$output; sha256=(Get-FileHash $output -Algorithm SHA256).Hash.ToLowerInvariant(); sdk=$sdk; widBarSdk='2.1.0'; windowsAppSdk='2.3.1'; signed=$false; installed=$false; nativeUiVerified=$false } | ConvertTo-Json
