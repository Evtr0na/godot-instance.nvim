param(
    # Arguments are interpreted by this script (see below), so no named
    # parameters here: the two supported "Exec Flags" forms put them in
    # different orders.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# NOTE: keep this file pure ASCII.
#
# Windows PowerShell 5.1 reads a BOM-less .ps1 using the system ANSI code page.
# UTF-8 comments would be decoded as garbage. It happens to survive today, but
# a mis-decoded byte pair could contain an ASCII quote and break parsing, so
# this file stays ASCII-only. The Chinese rationale lives in the README.
#
# ---------------------------------------------------------------------------
# This script turns "double-click a file / click an error in Godot" into one
# Nvim RPC call.
#
# It must accept BOTH Godot "Exec Flags" forms, otherwise it fails quietly
# (double-click does nothing):
#
#   1) recommended (godot-instance style):
#        Exec Flags = "{file}" {line} {col}
#        -> args:  file  line  col
#
#   2) Godot's built-in Vim preset:
#        Exec Flags = "\"+call cursor({line}, {col})\" {file}"
#        -> args:  "+call cursor(5, 3)"  file
#
# Earlier it only understood form 1, so form 2 made it treat
# "+call cursor(5, 3)" as the file path, Test-Path failed and it exited 10 --
# which is exactly "double-click does nothing".
#
# Exit codes:
#   0   success
#   10  no existing file found among the arguments
#   11  project.godot not found
#   20  Nvim RPC call failed (usually: no Nvim running for that project)
#
# Debugging: set GODOT_INSTANCE_ROUTER_LOG=<path> to append each step.
# ---------------------------------------------------------------------------

function Write-RouterLog {
    param([string]$Message)

    $logPath = $env:GODOT_INSTANCE_ROUTER_LOG
    if ([string]::IsNullOrEmpty($logPath)) {
        return
    }

    try {
        $stamp = (Get-Date).ToString("HH:mm:ss.fff")
        Add-Content -LiteralPath $logPath -Value "[$stamp] $Message" -Encoding UTF8
    }
    catch {
        # logging must never break the main path
    }
}

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

# ------------------------------------------------------------ parse arguments

$fileArg = $null
$lineArg = $null
$columnArg = $null

foreach ($arg in $Arguments) {
    if ($null -eq $arg -or $arg -eq "") {
        continue
    }

    # File: the first argument that resolves to an existing file. Numbers and
    # "+call cursor(...)" never match, because GetFullPath + Test-Path filters
    # them out.
    if ($null -eq $fileArg) {
        $candidate = $null
        try {
            $candidate = [System.IO.Path]::GetFullPath($arg)
        }
        catch {
            $candidate = $null
        }

        if ($null -ne $candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $fileArg = $candidate
            continue
        }
    }

    # Vim preset: cursor(N, M)
    if ($arg -match 'cursor\(\s*(\d+)\s*,\s*(\d+)\s*\)') {
        if ($null -eq $lineArg) { $lineArg = $Matches[1] }
        if ($null -eq $columnArg) { $columnArg = $Matches[2] }
        continue
    }

    # Bare numbers: line first, then column
    if ($arg -match '^\d+$') {
        if ($null -eq $lineArg) {
            $lineArg = $arg
        }
        elseif ($null -eq $columnArg) {
            $columnArg = $arg
        }
        continue
    }
}

Write-RouterLog "args = $($Arguments -join ' | ')"
Write-RouterLog "file=$fileArg line=$lineArg col=$columnArg"

if ($null -eq $fileArg) {
    Write-RouterLog "no existing file in args -> exit 10"
    exit 10
}

[int]$lineNumber = 1
[int]$columnNumber = 1

if ($null -ne $lineArg -and -not [int]::TryParse($lineArg, [ref]$lineNumber)) {
    $lineNumber = 1
}

if ($null -ne $columnArg -and -not [int]::TryParse($columnArg, [ref]$columnNumber)) {
    $columnNumber = 1
}

if ($lineNumber -lt 1) { $lineNumber = 1 }
if ($columnNumber -lt 1) { $columnNumber = 1 }

$resolvedFile = [System.IO.Path]::GetFullPath($fileArg)

$root = Find-GodotProjectRoot -Path $resolvedFile
if ([string]::IsNullOrEmpty($root)) {
    Write-RouterLog "project.godot not found -> exit 11"
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

Write-RouterLog "server = $server"

# One nvim client process, one RPC. If the project pipe does not exist, this
# fails closed and never guesses another Nvim instance.
& nvim `
    --server $server `
    --remote-expr $expr `
    *> $null

$code = $LASTEXITCODE
Write-RouterLog "nvim --remote-expr exit = $code"

if ($code -ne 0) {
    exit 20
}

exit 0
