# Lists connected Bluetooth devices and their battery level as one JSON line:
#   [{"name":"soundcore R60i NC","battery":90,"kind":"earbuds"}, ...]
# Windows stores the battery level on one of the device's service nodes, so we
# read it from every Bluetooth node and match it back to the device by address.
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$KEY_BATTERY   = '{104EA319-6EE2-4701-BD47-8DDBF425BBE5} 2'
$KEY_CONNECTED = '{83DA6326-97A6-4088-9453-A1923F573B29} 15'
$KEY_CLASS     = '{2BD67D8B-8BEB-48D5-87E0-6CDA3428040A} 10'   # Bluetooth "class of device"
$KEY_CATEGORY  = '{78C34FC8-104A-4ACA-9EA4-524D52996E57} 90'   # Windows device category ("Communication.Phone", ...)
# Windows may report these keys by name instead of by number.
$CLASS_NAMES    = @($KEY_CLASS, 'DEVPKEY_Bluetooth_ClassOfDevice')
$CATEGORY_NAMES = @($KEY_CATEGORY, 'DEVPKEY_DeviceContainer_Category')

$nodes = @(Get-CimInstance Win32_PnPEntity -Filter "PNPDeviceID LIKE 'BTHENUM%' OR PNPDeviceID LIKE 'BTHLE%'")

$battery = @{}
$connected = @{}
$cod = @{}
$category = @{}
if ($nodes.Count) {
    $results = $nodes | Invoke-CimMethod -MethodName GetDeviceProperties -Arguments @{ devicePropertyKeys = @($KEY_BATTERY, $KEY_CONNECTED, $KEY_CLASS, $KEY_CATEGORY) }
    foreach ($r in $results) {
        foreach ($p in $r.deviceProperties) {
            if ($null -eq $p.Data) { continue }
            if ($p.deviceID -notmatch '([0-9A-F]{12})(_C[0-9A-F]+)?$') { continue }
            $addr = $Matches[1]
            if ($p.KeyName -eq $KEY_BATTERY) { $battery[$addr] = [int]$p.Data }
            elseif ($p.KeyName -eq $KEY_CONNECTED -and $p.deviceID -match '\\DEV_') { $connected[$addr] = [bool]$p.Data }
            elseif ($CLASS_NAMES -contains $p.KeyName) { $cod[$addr] = [uint32]$p.Data }
            elseif ($CATEGORY_NAMES -contains $p.KeyName) { $category[$addr] = (@($p.Data) -join ' ') }
        }
    }
}

function Get-Kind([string]$name, $class, [string]$cat) {
    $n = $name.ToLower()
    # Windows' own device category is the most reliable (it's what Settings uses for the icon).
    switch -regex ($cat) {
        'Communication\.Phone'            { return 'phone' }
        'Input\.Gaming|Gaming'            { return 'gamepad' }
        'Display\.Television|Television'  { return 'tv' }
        'Computer\.Tablet|Tablet'         { return 'tablet' }
        'Input\.Mouse'                    { return 'mouse' }
        'Input\.Keyboard'                 { return 'keyboard' }
        'Watch|Wearable'                  { return 'watch' }
        'Audio\.Speaker'                  { return 'speaker' }
    }
    if ($n -match 'controller|gamepad|xbox|dualsense|dualshock|joy-con|8bitdo') { return 'gamepad' }
    if ($n -match '\btv\b|television|bravia|fire ?tv|chromecast|roku|webos|tizen|smart ?view') { return 'tv' }
    if ($n -match 'ipad|\btab\b|tablet|galaxy tab|mediapad|matepad|\bpad\b') { return 'tablet' }
    if ($n -match 'phone|galaxy [asmz]\d|iphone|pixel|redmi|oneplus|xiaomi|oppo|vivo|realme|huawei|honor|nokia') { return 'phone' }
    # Bluetooth class of device: major 1 = computer (minor 7 = tablet), 2 = phone, 5 = peripheral.
    if ($null -ne $class) {
        $major = ($class -shr 8) -band 0x1F
        $minor = ($class -shr 2) -band 0x3F
        if ($major -eq 1 -and $minor -eq 7) { return 'tablet' }
        if ($major -eq 2) { return 'phone' }
        if ($major -eq 5 -and ($minor -band 0x0F) -in 1, 2) { return 'gamepad' }
    }
    if ($n -match 'mouse|mx master|trackpad') { return 'mouse' }
    if ($n -match 'keyboard|keys') { return 'keyboard' }
    if ($n -match 'watch|band|fit') { return 'watch' }
    if ($n -match 'speaker|soundlink|jbl flip|charge|boom') { return 'speaker' }
    if ($n -match 'headphone|headset|wh-1000|airpods max|\bq\d{2}\b|space one|life q') { return 'headphones' }
    return 'earbuds'
}

$out = @()
foreach ($d in $nodes) {
    if ($d.PNPDeviceID -notmatch '^(BTHENUM|BTHLE)\\DEV_([0-9A-F]{12})') { continue }
    $addr = $Matches[2]
    if (-not $connected[$addr]) { continue }
    $b = if ($battery.ContainsKey($addr)) { $battery[$addr] } else { $null }
    $c = if ($cod.ContainsKey($addr)) { $cod[$addr] } else { $null }
    $cat = if ($category.ContainsKey($addr)) { $category[$addr] } else { '' }
    # The same device can be listed twice (Bluetooth + Bluetooth LE): keep one, with a battery if any.
    $same = $out | Where-Object { $_.name -eq $d.Name } | Select-Object -First 1
    if ($same) { if ($null -eq $same.battery) { $same.battery = $b }; continue }
    $out += [ordered]@{ name = $d.Name; battery = $b; kind = (Get-Kind $d.Name $c $cat) }
}

# Phone battery from Phone Link: its Start-menu phone card has a "Battery 76%"-style label.
# Only used when Phone Link has updated it recently (the phone is connected).
try {
    $pl = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.YourPhone_8wekyb3d8bbwe'
    $card = Join-Path $pl 'LocalState\StartMenu\StartMenuCompanion.json'
    if ((Test-Path $card) -and ((Get-Date) - (Get-Item $card).LastWriteTime).TotalMinutes -lt 60) {
        $json = [IO.File]::ReadAllText($card)
        $level = $null; $charging = $false
        foreach ($m in [regex]::Matches($json, '"(?:tooltip|altText)"\s*:\s*"([^"]*[Bb]attery[^"]*)"')) {
            $label = $m.Groups[1].Value
            if ($label -match '(\d{1,3})\s*(%|percent)') { $level = [int]$Matches[1]; $charging = $label -match '(?i)charging' -and $label -notmatch '(?i)not charging'; break }
        }
        if ($null -ne $level -and $level -le 100) {
            # The phone's name: the one Phone Link shows on its card, else its most recently seen phone.
            $name = 'Phone'
            $cardName = [regex]::Matches($json, '"text"\s*:\s*"([^"]{1,40})"') | ForEach-Object { $_.Groups[1].Value } |
                Where-Object { $_ -notmatch '(?i)phone link|connected|disconnected|bluetooth|battery|messages|calls|files|recent|send|view|keep up|^\s*$' } | Select-Object -First 1
            if ($cardName) { $name = $cardName }
            else {
                $meta = Join-Path $pl 'LocalCache\DeviceMetadataStorage.json'
                if (Test-Path $meta) {
                    try {
                        $md = (Get-Content $meta -Raw | ConvertFrom-Json).DeviceMetadatas
                        $best = @($md) | ForEach-Object { $_.Metadata } | Where-Object { $_ -and $_.DisplayName -and $_.ModelName -ne 'Unknown' } |
                            Sort-Object { [datetime]$_.LastSeenTime } -Descending | Select-Object -First 1
                        if ($best) { $name = $best.DisplayName }
                    } catch {}
                }
            }
            # Same phone already listed over Bluetooth: fill in its battery; otherwise add it.
            $bt = $out | Where-Object { $_.kind -eq 'phone' } | Select-Object -First 1
            if ($bt) { if ($null -eq $bt.battery) { $bt.battery = $level }; $bt.charging = $charging }
            else { $out += [ordered]@{ name = $name; battery = $level; kind = 'phone'; charging = $charging; via = 'phonelink' } }
        }
    }
} catch {}

[Console]::Out.WriteLine((ConvertTo-Json -InputObject @($out) -Compress))
