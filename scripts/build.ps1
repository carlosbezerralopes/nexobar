#Requires -Version 7
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$shortVersion = '0.4.0'
$bundleVersion = '11'
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
    @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NexoBar</string>
<key>CFBundleIdentifier</key><string>com.carlosbezerralopes.nexobar.preview</string>
<key>CFBundleName</key><string>NexoBar</string>
<key>CFBundleVersion</key><string>$bundleVersion</string>
<key>CFBundleShortVersionString</key><string>$shortVersion</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
"@ | Set-Content "$contents/Info.plist" -Encoding utf8NoBOM
    # Widget de mesa (WidgetKit): extensão sandbox que só lê a pasta do coletor dos workers.
    $appex = Join-Path $contents 'PlugIns/NexoBarWorkers.appex'
    Remove-Item -Recurse -Force $appex -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force "$appex/Contents/MacOS" | Out-Null
    # Compilado fora do SwiftPM para emitir os const values que o extrator de App Intents usa; sem
    # Metadata.appintents, o "Editar widget" não mostra a ordem e os apelidos.
    $widgetBuild = Join-Path $buildRoot 'widget'
    Remove-Item -Recurse -Force $widgetBuild -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $widgetBuild, "$appex/Contents/Resources" | Out-Null
    $widgetSources = @(Get-ChildItem 'Sources/NexoBarWorkersWidget' -Filter '*.swift' | ForEach-Object FullName)
    $constValues = Join-Path $widgetBuild 'NexoBarWorkersWidget.swiftconstvalues'
    $protocols = Join-Path $widgetBuild 'protocols.json'
    '["AppIntent","EntityQuery","AppEntity","TransientEntity","AppEnum","AppShortcutProviding","AppShortcutsProvider","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider","WidgetConfigurationIntent","_IntentValueRepresentable","_AssistantIntentsProvider","_GenerativeFunctionExtractable"]' | Set-Content $protocols -Encoding utf8NoBOM
    $target = "$(uname -m)-apple-macos14.0"
    swiftc -O -wmo -parse-as-library -application-extension -swift-version 5 -target $target -module-name NexoBarWorkersWidget `
        -I (Join-Path $binaryDirectory 'Modules') @widgetSources @(Get-ChildItem (Join-Path $binaryDirectory 'WorkersTelemetry.build') -Filter '*.o' | ForEach-Object FullName) `
        -emit-const-values-path $constValues -Xfrontend -const-gather-protocols-file -Xfrontend $protocols `
        -Xlinker -application_extension -Xlinker -e -Xlinker _NSExtensionMain -o "$appex/Contents/MacOS/NexoBarWorkersWidget"
    if ($LASTEXITCODE -ne 0) { throw 'Compilação do widget falhou.' }
    $widgetSources | Set-Content (Join-Path $widgetBuild 'sources.txt') -Encoding utf8NoBOM
    $constValues | Set-Content (Join-Path $widgetBuild 'constvals.txt') -Encoding utf8NoBOM
    '' | Set-Content (Join-Path $widgetBuild 'metadata.txt') -Encoding utf8NoBOM
    $toolchain = Split-Path (Split-Path (Split-Path (xcrun --find swiftc)))
    $xcodeBuild = ((xcodebuild -version | Select-Object -Last 1) -split ' ')[-1]
    xcrun appintentsmetadataprocessor --output "$appex/Contents/Resources" --toolchain-dir $toolchain --module-name NexoBarWorkersWidget `
        --sdk-root (xcrun --show-sdk-path) --xcode-version $xcodeBuild --platform-family macOS --deployment-target 14.0 --target-triple $target `
        --source-file-list (Join-Path $widgetBuild 'sources.txt') --swift-const-vals-list (Join-Path $widgetBuild 'constvals.txt') `
        --metadata-file-list (Join-Path $widgetBuild 'metadata.txt') --static-metadata-file-list (Join-Path $widgetBuild 'metadata.txt') `
        --deployment-aware-processing --no-app-shortcuts-localization --force
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$appex/Contents/Resources/Metadata.appintents/extract.actionsdata")) { throw 'Metadados App Intents do widget não foram gerados.' }
    @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NexoBarWorkersWidget</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
<key>CFBundleIdentifier</key><string>com.carlosbezerralopes.nexobar.preview.workers</string>
<key>CFBundleName</key><string>NexoBar Workers</string>
<key>CFBundleDisplayName</key><string>NexoBar Workers</string>
<key>CFBundleVersion</key><string>$bundleVersion</string>
<key>CFBundleShortVersionString</key><string>$shortVersion</string>
<key>CFBundlePackageType</key><string>XPC!</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSExtension</key><dict><key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string></dict>
</dict></plist>
"@ | Set-Content "$appex/Contents/Info.plist" -Encoding utf8NoBOM
    xattr -cr $appBundle
    codesign --force --sign - --entitlements 'scripts/macos/WorkersWidget.entitlements' $appex
    if ($LASTEXITCODE -ne 0) { throw 'Assinatura local do widget falhou.' }
    codesign --force --sign - $appBundle
    if ($LASTEXITCODE -ne 0) { throw 'Assinatura local falhou.' }
    codesign --verify --strict --deep $appBundle
    if ($LASTEXITCODE -ne 0) { throw 'Verificação da assinatura local falhou.' }
    New-Item -ItemType Directory -Force (Join-Path $projectRoot 'dist') | Out-Null
    $archive = Join-Path $projectRoot 'dist/NexoBar-macOS-preview.zip'
    ditto -c -k --keepParent $appBundle $archive
    if ($LASTEXITCODE -ne 0) { throw 'Falha no pacote ZIP.' }
    Write-Output "Bundle local: $appBundle"
    Write-Output "Pacote: $archive"
} finally { Pop-Location }
