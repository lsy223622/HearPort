param([Parameter(Mandatory = $true)][int]$ProcessId)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class HearPortPaintCheck {
    delegate bool EnumProc(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr window, StringBuilder text, int length);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder text, int length);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr window, uint message, IntPtr wp, IntPtr lp);
    public static IntPtr MainWindow(int processId) { return Find(processId, "HearPort"); }
    public static IntPtr TrayPopup(int processId) { return Find(processId, "HearPort Tray"); }
    static IntPtr Find(int processId, string name) {
        IntPtr root = IntPtr.Zero;
        EnumWindows((w,d) => {
            uint pid; GetWindowThreadProcessId(w,out pid);
            if(pid != processId || !IsWindowVisible(w)) return true;
            var title = new StringBuilder(128);
            GetWindowText(w,title,128);
            var kind = new StringBuilder(128);
            GetClassName(w,kind,128);
            if(title.ToString() == name && kind.ToString() != "#32770") root = w;
            return true;
        }, IntPtr.Zero);
        return root;
    }
    public static void DeactivateTrayPopup(IntPtr popup, int processId) {
        if (!PostMessage(popup, 0x0006, IntPtr.Zero, MainWindow(processId))) {
            throw new Exception("Could not send the tray popup deactivation");
        }
    }
    public static void ToggleTrayPopup(int processId) {
        if (!PostMessage(MainWindow(processId), 0x8001, IntPtr.Zero, new IntPtr(0x0400))) {
            throw new Exception("Could not send tray activation");
        }
    }
}
"@
$tree = [System.Windows.Automation.TreeScope]::Descendants
function Find-NamedElement($window, [string[]]$Names) {
    foreach ($text in $Names) {
        $name = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $text)
        $match = $window.FindFirst($tree, $name)
        if ($match) { return $match }
    }
}
function Wait-NamedElement($window, [string[]]$Names) {
    for ($i = 0; $i -lt 30; ++$i) {
        $element = Find-NamedElement $window $Names
        if ($element) { return $element }
        Start-Sleep -Milliseconds 100
    }
    throw "Missing UI element: $($Names -join ' / ')"
}
function Select-Page($window, [string]$Id) {
    $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Id)
    $item = $window.FindFirst($tree, $condition)
    if (!$item) { throw "Missing page tab: $Id" }
    $toggle = $item.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    if ($toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) { $toggle.Toggle() }
}
$main = [HearPortPaintCheck]::MainWindow($ProcessId)
if ($main -eq [IntPtr]::Zero) { throw 'HearPort main window not found' }
$root = [System.Windows.Automation.AutomationElement]::FromHandle($main)
$null = Wait-NamedElement $root @('Overview', '概览')
Select-Page $root 'DiagnosticsPage'
$null = Wait-NamedElement $root @('Open sender log', '打开运行日志')
Select-Page $root 'SettingsPage'
$null = Wait-NamedElement $root @('Run when I sign in to Windows', '登录 Windows 后自动运行')
$null = Wait-NamedElement $root @('Process loopback', '进程回环')
$null = Wait-NamedElement $root @('Default output device', '默认输出设备')
Select-Page $root 'OverviewPage'
$null = Wait-NamedElement $root @('Pair new iPad', '配对新 iPad', 'Unpair iPad', '取消配对')
Write-Output 'WinUI main window opened and all three pages navigated'
[HearPortPaintCheck]::ToggleTrayPopup($ProcessId)
$popup = [IntPtr]::Zero
for ($attempt = 0; $attempt -lt 60 -and $popup -eq [IntPtr]::Zero; ++$attempt) {
    Start-Sleep -Milliseconds 100
    $popup = [HearPortPaintCheck]::TrayPopup($ProcessId)
}
if ($popup -eq [IntPtr]::Zero) { throw 'WinUI tray popup did not open' }
$window = [System.Windows.Automation.AutomationElement]::FromHandle($popup)
$tree = [System.Windows.Automation.TreeScope]::Descendants
$types = [System.Windows.Automation.AutomationElement]::ControlTypeProperty
$slider = [System.Windows.Automation.PropertyCondition]::new($types, [System.Windows.Automation.ControlType]::Slider)
$button = [System.Windows.Automation.PropertyCondition]::new($types, [System.Windows.Automation.ControlType]::Button)
$label = $null
for ($attempt = 0; $attempt -lt 20 -and !$label; ++$attempt) {
    foreach ($text in @('iPad not connected', 'iPad 未连接')) {
        $name = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $text)
        $label = $window.FindFirst($tree, $name)
        if ($label) { break }
    }
    if (!$label) { Start-Sleep -Milliseconds 100 }
}
if (!$label -or !$window.FindFirst($tree, $button)) { throw 'Missing disconnected state or open button' }
if ($window.FindFirst($tree, $slider)) { throw 'The disconnected flyout exposes a volume slider' }
[HearPortPaintCheck]::DeactivateTrayPopup($popup, $ProcessId)
for ($attempt = 0; $attempt -lt 20 -and $popup -ne [IntPtr]::Zero; ++$attempt) {
    Start-Sleep -Milliseconds 100
    $popup = [HearPortPaintCheck]::TrayPopup($ProcessId)
}
if ($popup -ne [IntPtr]::Zero) { throw 'Changing focus did not dismiss the popup' }
Write-Output 'WinUI tray popup opened without a slider and dismissed when focus changed'
