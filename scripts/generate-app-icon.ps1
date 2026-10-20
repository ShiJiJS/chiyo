# Windows build helper for the vector geometry in assets/branding/app-icon.svg.
# Generates application assets only; does not open a window or install an icon.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$iconProject = Split-Path -Parent $PSScriptRoot

function Get-IconPng([int]$Size) {
    $bitmap = [Drawing.Bitmap]::new($Size, $Size)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $path = [Drawing.Drawing2D.GraphicsPath]::new()
    $brush = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#28695f'))
    $pen = [Drawing.Pen]::new([Drawing.Color]::White, [single]1.6)
    $stream = [IO.MemoryStream]::new()
    try {
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.ScaleTransform([single]($Size / 32), [single]($Size / 32))
        $path.AddArc(2, 2, 14, 14, 180, 90)
        $path.AddArc(16, 2, 14, 14, 270, 90)
        $path.AddArc(16, 16, 14, 14, 0, 90)
        $path.AddArc(2, 16, 14, 14, 90, 90)
        $path.CloseFigure()
        $graphics.FillPath($brush, $path)
        $pen.LineJoin = [Drawing.Drawing2D.LineJoin]::Round
        $pen.StartCap = [Drawing.Drawing2D.LineCap]::Round
        $pen.EndCap = [Drawing.Drawing2D.LineCap]::Round
        $top = [Drawing.PointF[]]@([Drawing.PointF]::new(9,12), [Drawing.PointF]::new(16,8), [Drawing.PointF]::new(23,12), [Drawing.PointF]::new(16,16))
        $graphics.DrawPolygon($pen, $top)
        foreach ($row in @(17, 21)) {
            $points = [Drawing.PointF[]]@([Drawing.PointF]::new(9,$row), [Drawing.PointF]::new(16,($row+4)), [Drawing.PointF]::new(23,$row))
            $graphics.DrawLines($pen, $points)
        }
        $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
        return ,$stream.ToArray()
    } finally {
        $stream.Dispose(); $pen.Dispose(); $brush.Dispose()
        $path.Dispose(); $graphics.Dispose(); $bitmap.Dispose()
    }
}

$iconSizes = @(16, 24, 32, 48, 64, 128, 256)
$iconPayloads = @($iconSizes | ForEach-Object { ,(Get-IconPng $_) })
$iconOutput = Join-Path $iconProject 'apps/desktop/windows/runner/resources/app_icon.ico'
$iconStream = [IO.File]::Create($iconOutput)
$writer = [IO.BinaryWriter]::new($iconStream)
try {
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$iconSizes.Count)
    $offset = 6 + 16 * $iconSizes.Count
    for ($index = 0; $index -lt $iconSizes.Count; $index++) {
        $dimension = if ($iconSizes[$index] -eq 256) { 0 } else { $iconSizes[$index] }
        $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
        $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([uint16]1); $writer.Write([uint16]32)
        $writer.Write([uint32]$iconPayloads[$index].Length); $writer.Write([uint32]$offset)
        $offset += $iconPayloads[$index].Length
    }
    foreach ($payload in $iconPayloads) { $writer.Write([byte[]]$payload) }
} finally { $writer.Dispose(); $iconStream.Dispose() }

foreach ($macSize in @(16, 32, 64, 128, 256, 512, 1024)) {
    $macOutput = Join-Path $iconProject "apps/desktop/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$macSize.png"
    [IO.File]::WriteAllBytes($macOutput, (Get-IconPng $macSize))
}
Write-Output 'Generated Windows and macOS application icon assets.'
