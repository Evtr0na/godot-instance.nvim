param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    [string]$Line = "1",
    [string]$Column = "1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Normalize-ProjectPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $full = [System.IO.Path]::GetFullPath($Path)
    $normalized = $full.Replace('\', '/')

    if ($normalized -notmatch '^[A-Za-z]:/$' -and $normalized -ne '/') {
        $normalized = $normalized.TrimEnd('/')
    }

    return $normalized.ToLowerInvariant()
}

function Find-GodotProjectRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullFile = [System.IO.Path]::GetFullPath($Path)
    $directory = [System.IO.Path]::GetDirectoryName($fullFile)

    while (-not [string]::IsNullOrEmpty($directory)) {
        $projectFile = Join-Path $directory "project.godot"

        if (Test-Path -LiteralPath $projectFile -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($directory)
        }

        $parent = [System.IO.Directory]::GetParent($directory)
        if ($null -eq $parent) {
            break
        }

        $directory = $parent.FullName
    }

    return $null
}

function Get-Sha256Hex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return (($hash | ForEach-Object { $_.ToString("x2") }) -join "")
    }
    finally {
        $sha.Dispose()
    }
}

[int]$lineNumber = 1
[int]$columnNumber = 1

if (-not [int]::TryParse($Line, [ref]$lineNumber) -or $lineNumber -lt 1) {
    $lineNumber = 1
}

if (-not [int]::TryParse($Column, [ref]$columnNumber) -or $columnNumber -lt 1) {
    $columnNumber = 1
}

$resolvedFile = [System.IO.Path]::GetFullPath($FilePath)
if (-not (Test-Path -LiteralPath $resolvedFile -PathType Leaf)) {
    exit 10
}

$root = Find-GodotProjectRoot -Path $resolvedFile
if ([string]::IsNullOrEmpty($root)) {
    exit 11
}

$rootKey = Normalize-ProjectPath -Path $root
$hash = Get-Sha256Hex -Text $rootKey
$server = "//./pipe/nvim-godot-project-$hash"

# Base64 keeps spaces, Unicode, quotes and backslashes out of the VimL
# expression. The Lua side decodes it inside the already-running Nvim.
$pathBytes = [System.Text.Encoding]::UTF8.GetBytes($resolvedFile)
$encodedFile = [Convert]::ToBase64String($pathBytes)
$expr = "v:lua.godot_remote_open('$encodedFile',$lineNumber,$columnNumber)"

# One nvim client process, one RPC. If the project pipe does not exist, this
# fails closed and never guesses another Nvim instance.
& nvim `
    --server $server `
    --remote-expr $expr `
    *> $null

if ($LASTEXITCODE -ne 0) {
    exit 20
}

exit 0
