#Requires -Version 7
# Generates windows/app/NexoBar.ico (app, tray, Start menu shortcut and installer) from the vector drawing below.
# Each size is drawn natively, not downscaled, so 16 px stays crisp.
[CmdletBinding()]
param([string]$Output = (Join-Path $PSScriptRoot '../app/NexoBar.ico'), [string]$PreviewDirectory)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
function Draw([int]$size) {
    $bitmap = [Drawing.Bitmap]::new($size, $size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bitmap)
    $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'; $g.Clear([Drawing.Color]::Transparent)
    $s = $size / 256.0
    $path = [Drawing.Drawing2D.GraphicsPath]::new(); $r = 56 * $s; $w = $size - 1
    $path.AddArc(0, 0, 2 * $r, 2 * $r, 180, 90); $path.AddArc($w - 2 * $r, 0, 2 * $r, 2 * $r, 270, 90)
    $path.AddArc($w - 2 * $r, $w - 2 * $r, 2 * $r, 2 * $r, 0, 90); $path.AddArc(0, $w - 2 * $r, 2 * $r, 2 * $r, 90, 90); $path.CloseFigure()
    $background = [Drawing.Drawing2D.LinearGradientBrush]::new([Drawing.PointF]::new(0, 0), [Drawing.PointF]::new(0, $size),
        [Drawing.Color]::FromArgb(255, 0x1E, 0x29, 0x3B), [Drawing.Color]::FromArgb(255, 0x0B, 0x12, 0x20))
    $g.FillPath($background, $path)
    # Three indicator bars (CPU, RAM, cotas) on a common baseline.
    $bars = @(@(52, 96, 0x38BDF8), @(110, 156, 0x34D399), @(168, 118, 0xFBBF24))
    $base = 204; $barWidth = 40
    foreach ($bar in $bars) {
        $x = $bar[0] * $s; $h = $bar[1] * $s; $y = ($base - $bar[1]) * $s
        $brush = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(255, ($bar[2] -shr 16) -band 255, ($bar[2] -shr 8) -band 255, $bar[2] -band 255))
        $rect = [Drawing.Drawing2D.GraphicsPath]::new(); $br = [Math]::Max(1, 8 * $s); $bw = $barWidth * $s
        $rect.AddArc($x, $y, 2 * $br, 2 * $br, 180, 90); $rect.AddArc($x + $bw - 2 * $br, $y, 2 * $br, 2 * $br, 270, 90)
        $rect.AddLine($x + $bw, $y + $h, $x, $y + $h); $rect.CloseFigure()
        $g.FillPath($brush, $rect); $brush.Dispose(); $rect.Dispose()
    }
    $g.Dispose(); $background.Dispose(); $path.Dispose()
    return $bitmap
}
$images = foreach ($size in $sizes) {
    $bitmap = Draw $size; $stream = [IO.MemoryStream]::new()
    $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
    if ($PreviewDirectory) { New-Item -ItemType Directory -Force $PreviewDirectory | Out-Null; $bitmap.Save((Join-Path $PreviewDirectory "NexoBar-$size.png"), [Drawing.Imaging.ImageFormat]::Png) }
    $bitmap.Dispose(); , $stream.ToArray()
}
# ICO container with PNG-compressed entries (supported since Windows Vista).
$file = [IO.MemoryStream]::new(); $writer = [IO.BinaryWriter]::new($file)
$writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $size = $sizes[$i]; $data = $images[$i]
    $writer.Write([byte]($size % 256)); $writer.Write([byte]($size % 256)); $writer.Write([byte]0); $writer.Write([byte]0)
    $writer.Write([uint16]1); $writer.Write([uint16]32); $writer.Write([uint32]$data.Length); $writer.Write([uint32]$offset)
    $offset += $data.Length
}
foreach ($data in $images) { $writer.Write($data) }
$writer.Flush(); [IO.File]::WriteAllBytes([IO.Path]::GetFullPath($Output), $file.ToArray()); $writer.Dispose()
Write-Host "Ícone gerado: $Output ($($sizes -join ', ') px)"
