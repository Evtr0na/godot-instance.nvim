param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class GodotNvimWindowCloser
{
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool PostMessage(
        IntPtr hWnd,
        uint Msg,
        IntPtr wParam,
        IntPtr lParam
    );
}
"@

$process = Get-Process -Id $ProcessId -ErrorAction Stop
$handle = $process.MainWindowHandle

if ($handle -eq [IntPtr]::Zero) {
    Write-Error "Process $ProcessId has no main window handle."
    exit 3
}

# WM_CLOSE: lets Godot run its normal close flow and show save confirmation.
$ok = [GodotNvimWindowCloser]::PostMessage(
    $handle,
    0x0010,
    [IntPtr]::Zero,
    [IntPtr]::Zero
)

if (-not $ok) {
    Write-Error "Failed to post WM_CLOSE to Godot process $ProcessId."
    exit 4
}

exit 0
