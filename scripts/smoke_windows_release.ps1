param([Parameter(Mandatory = $true)][string]$Executable)
$ErrorActionPreference = 'Stop'
$program = (Resolve-Path -LiteralPath $Executable).Path
$process = Start-Process -FilePath $program -WorkingDirectory (Split-Path $program) -WindowStyle Hidden -PassThru
try {
    if ($process.WaitForExit(4000)) {
        throw "HearPort exited during startup with code $($process.ExitCode)"
    }
    & "$PSScriptRoot/test_windows_paint.ps1" -ProcessId $process.Id
    Write-Output 'HearPort GUI startup smoke check passed'
} finally {
    if (!$process.HasExited) {
        Stop-Process -Id $process.Id
        $process.WaitForExit()
    }
}
