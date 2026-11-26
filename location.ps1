# Prints the PC's location from Windows Location services as one JSON line:
#   {"ok":true,"lat":..,"lon":..,"acc":..}  or  {"ok":false,"why":"denied|off|error"}
# Nothing is sent anywhere; this only asks Windows.
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]
function Wait-WinRt($op, [Type]$type, [int]$ms = 8000) {
    $task = $asTaskGeneric.MakeGenericMethod($type).Invoke($null, @($op))
    if (-not $task.Wait($ms)) { return $null }
    $task.Result
}

$null = [Windows.Devices.Geolocation.Geolocator, Windows.Devices.Geolocation, ContentType = WindowsRuntime]
$accessType = [Windows.Devices.Geolocation.GeolocationAccessStatus]
$posType = [Windows.Devices.Geolocation.Geoposition]

try {
    $access = Wait-WinRt ([Windows.Devices.Geolocation.Geolocator]::RequestAccessAsync()) $accessType
    if ("$access" -ne 'Allowed') {
        [Console]::Out.WriteLine((@{ ok = $false; why = "denied:$access" } | ConvertTo-Json -Compress))
        exit
    }
    $geo = New-Object Windows.Devices.Geolocation.Geolocator
    $geo.DesiredAccuracyInMeters = 3000
    $pos = Wait-WinRt ($geo.GetGeopositionAsync()) $posType 10000
    if (-not $pos) {
        [Console]::Out.WriteLine((@{ ok = $false; why = 'timeout' } | ConvertTo-Json -Compress))
        exit
    }
    $p = $pos.Coordinate.Point.Position
    $out = [ordered]@{
        ok  = $true
        lat = [Math]::Round($p.Latitude, 4)
        lon = [Math]::Round($p.Longitude, 4)
        acc = [int]$pos.Coordinate.Accuracy
    }
    [Console]::Out.WriteLine(($out | ConvertTo-Json -Compress))
} catch {
    [Console]::Out.WriteLine((@{ ok = $false; why = 'error' } | ConvertTo-Json -Compress))
}
