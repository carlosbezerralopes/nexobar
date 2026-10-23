#Requires -Version 7
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
Push-Location $projectRoot
try {
    # Build outside cloud-backed Documents: File Provider FinderInfo breaks codesign.
    $buildRoot = Join-Path ([IO.Path]::GetTempPath()) 'nexobar/macos-preview'
    New-Item -ItemType Directory -Force $buildRoot | Out-Null
    $env:CLANG_MODULE_CACHE_PATH = Join-Path $buildRoot 'clang-cache'
    $env:SWIFTPM_MODULECACHE_OVERRIDE = Join-Path $buildRoot 'module-cache'
    $swiftArgs = @('--build-system', 'native', '--disable-sandbox', '--scratch-path', "$buildRoot/native-build", '--cache-path', "$buildRoot/cache", '--manifest-cache', 'local')
    swift test @swiftArgs
    if ($LASTEXITCODE -ne 0) { throw 'Testes falharam.' }
    swift build -c release @swiftArgs
    if ($LASTEXITCODE -ne 0) { throw 'Build falhou.' }
    $appBundle = Join-Path $buildRoot 'NexoBar.app'
    $contents = Join-Path $appBundle 'Contents'
    New-Item -ItemType Directory -Force "$contents/MacOS" | Out-Null
    New-Item -ItemType Directory -Force "$contents/Resources" | Out-Null
    Copy-Item 'THIRD_PARTY_NOTICES.md' "$contents/Resources/THIRD_PARTY_NOTICES.md" -Force
    Copy-Item 'LICENSE' "$contents/Resources/LICENSE" -Force
    Copy-Item 'docs/ATTRIBUTION.md' "$contents/Resources/ATTRIBUTION.md" -Force
    Copy-Item 'docs/HARDWARE-NOTICES.md' "$contents/Resources/HARDWARE-NOTICES.md" -Force
    $bridgeResources = Join-Path $contents 'Resources/claude-statusline'
    New-Item -ItemType Directory -Force $bridgeResources | Out-Null
    Copy-Item 'scripts/claude-statusline/producer.py' "$bridgeResources/producer.py" -Force
    Copy-Item 'scripts/claude-statusline/install.py' "$bridgeResources/install.py" -Force
    $binaryDirectory = (swift build -c release @swiftArgs --show-bin-path).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao localizar binário.' }
    Copy-Item (Join-Path $binaryDirectory 'NexoBar') "$contents/MacOS/NexoBar" -Force
    @'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NexoBar</string>
<key>CFBundleIdentifier</key><string>com.carlosbezerralopes.nexobar.preview</string>
<key>CFBundleName</key><string>NexoBar</string>
<key>CFBundleVersion</key><string>9</string>
<key>CFBundleShortVersionString</key><string>0.3.1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
'@ | Set-Content "$contents/Info.plist" -Encoding utf8NoBOM
    xattr -cr $appBundle
    codesign --force --sign - $appBundle
    if ($LASTEXITCODE -ne 0) { throw 'Assinatura local falhou.' }
    codesign --verify --strict $appBundle
    if ($LASTEXITCODE -ne 0) { throw 'Verificação da assinatura local falhou.' }
    New-Item -ItemType Directory -Force (Join-Path $projectRoot 'dist') | Out-Null
    $archive = Join-Path $projectRoot 'dist/NexoBar-macOS-preview.zip'
    ditto -c -k --keepParent $appBundle $archive
    if ($LASTEXITCODE -ne 0) { throw 'Falha no pacote ZIP.' }
    Write-Output "Bundle local: $appBundle"
    Write-Output "Pacote: $archive"
} finally { Pop-Location }
