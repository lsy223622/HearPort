param([Parameter(Mandatory = $true)][string]$Executable)
$ErrorActionPreference = 'Stop'
$program = (Resolve-Path -LiteralPath $Executable).Path
$process = Start-Process -FilePath $program -WorkingDirectory (Split-Path $program) -PassThru
try {
    $packaged = @(Get-ChildItem -LiteralPath (Split-Path $program) -Filter '*.dll')
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        if ($process.WaitForExit(250)) {
            throw "HearPort exited during startup with code $($process.ExitCode)"
        }
        $process.Refresh()
        $loaded = @($process.Modules)
        $missing = @(foreach ($dll in $packaged) {
            $module = $loaded | Where-Object { $_.ModuleName -ieq $dll.Name } | Select-Object -First 1
            if (!$module) {
                $dll.Name
            } elseif ([IO.Path]::GetFullPath($module.FileName) -ine $dll.FullName) {
                throw "Expected $($dll.FullName), loaded $($module.FileName)"
            }
        })
        if ($missing.Count -eq 0) { break }
        if ($timer.Elapsed.TotalSeconds -ge 45) {
            throw "Timed out waiting for packaged DLLs: $($missing -join ', '); window: $($process.MainWindowTitle)"
        }
    } while ($true)
    Write-Output 'Application-local DLL loading verified'
    & "$PSScriptRoot/test_windows_paint.ps1" -ProcessId $process.Id
    Write-Output 'HearPort GUI startup smoke check passed'
} finally {
    if (!$process.HasExited) {
        Stop-Process -Id $process.Id
        $process.WaitForExit()
    }
}
