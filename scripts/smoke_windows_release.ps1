param([Parameter(Mandatory = $true)][string]$Executable)
$ErrorActionPreference = 'Stop'
$program = (Resolve-Path -LiteralPath $Executable).Path
$process = Start-Process -FilePath $program -WorkingDirectory (Split-Path $program) -WindowStyle Hidden -PassThru
try {
    if ($process.WaitForExit(4000)) {
        throw "HearPort exited during startup with code $($process.ExitCode)"
    }
    $loaded = @($process.Modules)
    foreach ($dll in Get-ChildItem -LiteralPath (Split-Path $program) -Filter '*.dll') {
        $module = $loaded | Where-Object { $_.ModuleName -ieq $dll.Name } | Select-Object -First 1
        if (!$module -or [IO.Path]::GetFullPath($module.FileName) -ine $dll.FullName) {
            throw "Packaged DLL was not loaded from the application directory: $($dll.Name)"
        }
    }
    Write-Output 'Application-local DLL loading verified'
    & "$PSScriptRoot/test_windows_paint.ps1" -ProcessId $process.Id
    Write-Output 'HearPort GUI startup smoke check passed'
} finally {
    if (!$process.HasExited) {
        Stop-Process -Id $process.Id
        $process.WaitForExit()
    }
}
