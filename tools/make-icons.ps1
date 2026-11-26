# Generates assets/icon.png and the tray icons. Run from the project folder:
#   powershell -ExecutionPolicy Bypass -File tools\make-icons.ps1
Add-Type -AssemblyName System.Drawing
$assets = Join-Path $PSScriptRoot '..\assets'
New-Item -ItemType Directory -Force $assets | Out-Null

function New-RoundRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Save-Icon([int]$size, [string]$file) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)

    # Rounded square with a blue -> violet gradient
    $bg = New-RoundRect 0 0 ($size - 1) ($size - 1) ($size * 0.24)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.PointF 0, 0), (New-Object System.Drawing.PointF $size, $size),
        [System.Drawing.Color]::FromArgb(255, 94, 139, 255), [System.Drawing.Color]::FromArgb(255, 176, 92, 255))
    $g.FillPath($brush, $bg)

    # The black "island" pill near the top, with a green live dot
    $pw = $size * 0.66; $ph = $size * 0.24
    $px = ($size - $pw) / 2; $py = $size * 0.2
    $pill = New-RoundRect $px $py $pw $ph ($ph / 2)
    $g.FillPath([System.Drawing.Brushes]::Black, $pill)
    $dot = $ph * 0.36
    $g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 48, 209, 88))),
        $px + $pw - $ph * 0.5 - $dot / 2, $py + ($ph - $dot) / 2, $dot, $dot)

    # Two soft "content" bars under the pill (skipped at tiny sizes)
    if ($size -ge 32) {
        $white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(200, 255, 255, 255))
        $g.FillPath($white, (New-RoundRect ($size * 0.2) ($size * 0.56) ($size * 0.6) ($size * 0.08) ($size * 0.04)))
        $faint = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(120, 255, 255, 255))
        $g.FillPath($faint, (New-RoundRect ($size * 0.2) ($size * 0.7) ($size * 0.38) ($size * 0.08) ($size * 0.04)))
    }

    $bmp.Save((Join-Path $assets $file), [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
}

Save-Icon 256 'icon.png'
Save-Icon 16 'tray.png'
Save-Icon 32 'tray@2x.png'
Save-Icon 24 'tray@1.5x.png'
'icons written to ' + (Resolve-Path $assets)
