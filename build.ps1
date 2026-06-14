$keyFile = "$env:USERPROFILE\Desktop\api_keys.txt"
if (-not (Test-Path $keyFile)) {
    Write-Host "ERROR: api_keys.txt not found on Desktop" -ForegroundColor Red
    exit 1
}

$keys = @{}
Get-Content $keyFile | ForEach-Object {
    if ($_ -match '^([A-Z_]+)=(.+)$') {
        $keys[$matches[1]] = $matches[2].Trim()
    }
}

$placesKey = $keys['GOOGLE_PLACES_KEY']
$routesKey = $keys['GOOGLE_ROUTES_KEY']
$geocodingKey = $keys['GOOGLE_GEOCODING_KEY']

Write-Host "Keys loaded:" -ForegroundColor Green
Write-Host "  PLACES: $($placesKey.Substring(0, 10))... (length=$($placesKey.Length))"
Write-Host "  ROUTES: $($routesKey.Substring(0, 10))... (length=$($routesKey.Length))"
if ($geocodingKey) {
    Write-Host "  GEOCODING: $($geocodingKey.Substring(0, 10))... (length=$($geocodingKey.Length))"
}

Write-Host "Starting build..." -ForegroundColor Yellow

$buildArgs = @(
    "build", "apk", "--debug",
    "--dart-define=GOOGLE_PLACES_KEY=$placesKey",
    "--dart-define=GOOGLE_ROUTES_KEY=$routesKey"
)

if ($geocodingKey) {
    $buildArgs += "--dart-define=GOOGLE_GEOCODING_KEY=$geocodingKey"
}

& flutter @buildArgs