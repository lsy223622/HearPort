param(
    [Parameter(Mandatory = $true)][string]$OutputDir,
    [Parameter(Mandatory = $true)][string]$WebViewMetadata
)
$ErrorActionPreference = 'Stop'
$framework = Get-AppxPackage -Name Microsoft.WindowsAppRuntime.2 |
    Where-Object { $_.Architecture -eq 'X64' -and $_.Version -ge [version]'2.6.5.0' } |
    Sort-Object Version -Descending | Select-Object -First 1
if (!$framework) { throw 'Install Windows App Runtime 2.6.5 (x64) first.' }
$sdk = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10'
$tools = Get-ChildItem "$sdk/bin" -Directory | Where-Object {
    (Test-Path "$($_.FullName)/x64/cppwinrt.exe") -and
    (Test-Path "$sdk/UnionMetadata/$($_.Name)/Windows.winmd")
} | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
if (!$tools) { throw 'The Windows SDK C++/WinRT tool and platform metadata are required.' }
$metadata = @(Get-ChildItem -LiteralPath $framework.InstallLocation -Filter '*.winmd' |
    Select-Object -ExpandProperty FullName)
if (!$metadata) { throw 'Windows App Runtime metadata was not found.' }
$webView = (Resolve-Path -LiteralPath $WebViewMetadata).Path
& "$($tools.FullName)/x64/cppwinrt.exe" -input "$sdk/UnionMetadata/$($tools.Name)/Windows.winmd" @metadata $webView -output $OutputDir
if ($LASTEXITCODE -ne 0) { throw 'C++/WinRT projection generation failed.' }
