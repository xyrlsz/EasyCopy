param(
    [switch]$Obfuscate,
    [string]$SymbolsDir = "",
    [switch]$AllowDebugSigning
)

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $projectRoot

Write-Host "Starting arm64-v8a release build..." -ForegroundColor Green

$androidDir = Join-Path $projectRoot "android"
$keyPropertiesPath = Join-Path $androidDir "key.properties"
$storePassword = if (-not [string]::IsNullOrWhiteSpace($env:ANDROID_STORE_PASSWORD)) {
    $env:ANDROID_STORE_PASSWORD
} else {
    $env:ANDROID_KEYSTORE_PASSWORD
}
$keystorePath = if (-not [string]::IsNullOrWhiteSpace($env:ANDROID_KEYSTORE_PATH)) {
    $env:ANDROID_KEYSTORE_PATH
} else {
    $env:ANDROID_KEYSTORE_FILE
}
$hasKeyProperties = Test-Path $keyPropertiesPath
$hasEnvSigning = `
    (-not [string]::IsNullOrWhiteSpace($keystorePath)) -and `
    (-not [string]::IsNullOrWhiteSpace($storePassword)) -and `
    (-not [string]::IsNullOrWhiteSpace($env:ANDROID_KEY_ALIAS)) -and `
    (-not [string]::IsNullOrWhiteSpace($env:ANDROID_KEY_PASSWORD))

if ((-not $hasKeyProperties) -and (-not $hasEnvSigning) -and (-not $AllowDebugSigning)) {
    Write-Error "Release signing is not configured. Provide android/key.properties or ANDROID_KEYSTORE_PATH / ANDROID_STORE_PASSWORD / ANDROID_KEY_ALIAS / ANDROID_KEY_PASSWORD. Use -AllowDebugSigning only for temporary local builds."
    exit 1
}

if ($AllowDebugSigning) {
    $env:EASY_COPY_ALLOW_DEBUG_SIGNING = "true"
    Write-Warning "Building a debug-signed release APK. Future public versions must keep using the same signing key, otherwise Android cannot upgrade in place."
}

$pubspec = Get-Content pubspec.yaml
$versionLine = $pubspec | Select-String "version:"
if ($versionLine -match "version: (.*)") {
    $versionRaw = $matches[1].Trim()
}
else {
    $versionRaw = "unknown"
}

if ([string]::IsNullOrWhiteSpace($SymbolsDir)) {
    $SymbolsDir = Join-Path "release_symbols" $versionRaw
}
$androidSymbolsDir = Join-Path $SymbolsDir "android-arm64-v8a"
New-Item -ItemType Directory -Path $androidSymbolsDir -Force | Out-Null

$outputDir = Join-Path $projectRoot "build\app\outputs\flutter-apk"
$apkName = "app-arm64-v8a-release.apk"
$apkPath = Join-Path $outputDir $apkName

$buildCmd = "flutter build apk --release --target-platform=android-arm64 --split-per-abi --tree-shake-icons --split-debug-info=`"$androidSymbolsDir`""
if ($Obfuscate) {
    $buildCmd += " --obfuscate"
}

Write-Host "Building standalone arm64-v8a release APK..." -ForegroundColor Cyan
cmd /c $buildCmd

if ($LASTEXITCODE -ne 0) {
    Write-Error "Build failed."
    exit 1
}

if (-not (Test-Path $apkPath)) {
    Write-Error "Build finished but expected APK was not found: $apkPath"
    exit 1
}

$apkFile = Get-Item $apkPath
$apkSizeMb = [math]::Round($apkFile.Length / 1MB, 2)

Write-Host "Build Success!" -ForegroundColor Green
Write-Host "APK Location: $apkPath" -ForegroundColor Yellow
Write-Host "APK Size: ${apkSizeMb}MB" -ForegroundColor Yellow
Write-Host "Symbols Location: $androidSymbolsDir" -ForegroundColor Gray
