#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$dist = Join-Path $root 'dist'
[void](New-Item -ItemType Directory -Path $dist -Force)
$stage = Join-Path ([IO.Path]::GetTempPath()) ('TL-Function-build-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $stage)
try {
    Copy-Item -Path (Join-Path $PSScriptRoot 'function\*') -Destination $stage -Recurse -Force
    foreach ($name in @('Transportlogg.Core.ps1','Transportlogg.Graph.ps1')) {
        Copy-Item -LiteralPath (Join-Path $root $name) -Destination (Join-Path $stage 'shared')
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = Join-Path $dist 'Transportlogg-Function.zip'
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    [IO.Compression.ZipFile]::CreateFromDirectory($stage,$zip)
    $zip
} finally {
    $resolved = [IO.Path]::GetFullPath($stage)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'TL-Function-build-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
