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
    public static void DoubleClickTray(int processId) {
        if (!PostMessage(MainWindow(processId), 0x8001, IntPtr.Zero, new IntPtr(0x0203))) {
            throw new Exception("Could not send tray double-click");
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
function Find-NamedElement($window, [string[]]$Names, $Type) {
    foreach ($text in $Names) {
        $name = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $text)
        if ($Type) {
            $control = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, $Type)
            $name = [System.Windows.Automation.AndCondition]::new($name, $control)
        }
        $match = $window.FindFirst($tree, $name)
        if ($match) { return $match }
    }
}
function Wait-NamedElement($window, [string[]]$Names, $Type) {
    for ($i = 0; $i -lt 30; ++$i) {
        $element = Find-NamedElement $window $Names $Type
        if ($element) { return $element }
        Start-Sleep -Milliseconds 100
    }
    throw "Missing UI element: $($Names -join ' / ')"
}
function Select-Page($window, [string]$Id) {
    $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Id)
    $item = $window.FindFirst($tree, $condition)
    if (!$item) { throw "Missing page tab: $Id" }
    $selection = $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    if (!$selection.Current.IsSelected) { $selection.Select() }
}
function Invoke-NamedElement($window, [string[]]$Names) {
    $item = Wait-NamedElement $window $Names ([System.Windows.Automation.ControlType]::Button)
    $item.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}
$main = [HearPortPaintCheck]::MainWindow($ProcessId)
if ($main -eq [IntPtr]::Zero) { throw 'HearPort main window not found' }
$root = [System.Windows.Automation.AutomationElement]::FromHandle($main)
$null = Wait-NamedElement $root @('Overview', '概览')
Select-Page $root 'DiagnosticsPage'
$null = Wait-NamedElement $root @('Open sender log', '打开运行日志')
Invoke-NamedElement $root @('Network test', '网络测试')
$null = Wait-NamedElement $root @('Test type', '测试类型')
Invoke-NamedElement $root @('Cancel', '取消')
Select-Page $root 'SettingsPage'
$null = Wait-NamedElement $root @('Run when I sign in to Windows', '登录 Windows 后自动运行')
$capture = Wait-NamedElement $root @('Audio capture', '音频采集') ([System.Windows.Automation.ControlType]::ComboBox)
$dropdown = $capture.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
$dropdown.Expand()
$null = Wait-NamedElement $root @('Process loopback', '进程回环')
$null = Wait-NamedElement $root @('Default output device', '默认输出设备')
$dropdown.Collapse()
Invoke-NamedElement $root @('Edit', '修改')
$port = Wait-NamedElement $root @('UDP port', 'UDP 端口') ([System.Windows.Automation.ControlType]::Edit)
$field = $port.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
$field.SetValue('65536')
Invoke-NamedElement $root @('Apply', '应用')
$null = Wait-NamedElement $root @('Enter a UDP port from 1 to 65535.', '请输入 1 至 65535 之间的 UDP 端口。')
Invoke-NamedElement $root @('Cancel', '取消')
Select-Page $root 'OverviewPage'
$null = Wait-NamedElement $root @('Pair new iPad', '配对新 iPad', 'Unpair iPad', '取消配对')
Write-Output 'WinUI navigation, audio source options, network dialog and UDP validation verified'
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
    foreach ($text in @('HearPort not connected', 'HearPort 未连接')) {
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
[HearPortPaintCheck]::ToggleTrayPopup($ProcessId)
for ($attempt = 0; $attempt -lt 60 -and $popup -eq [IntPtr]::Zero; ++$attempt) {
    Start-Sleep -Milliseconds 100
    $popup = [HearPortPaintCheck]::TrayPopup($ProcessId)
}
if ($popup -eq [IntPtr]::Zero) { throw 'WinUI tray popup did not reopen' }
$window = [System.Windows.Automation.AutomationElement]::FromHandle($popup)
$null = Wait-NamedElement $window @('Adjust iPad volume', '调节 iPad 音量')
$null = Wait-NamedElement $window @('Stop', '停止') ([System.Windows.Automation.ControlType]::Button)
Invoke-NamedElement $window @('Settings', '设置')
$null = Wait-NamedElement $root @('Run when I sign in to Windows', '登录 Windows 后自动运行')
[HearPortPaintCheck]::ToggleTrayPopup($ProcessId)
$popup = [IntPtr]::Zero
for ($attempt = 0; $attempt -lt 60 -and $popup -eq [IntPtr]::Zero; ++$attempt) {
    Start-Sleep -Milliseconds 100
    $popup = [HearPortPaintCheck]::TrayPopup($ProcessId)
}
if ($popup -eq [IntPtr]::Zero) { throw 'WinUI tray popup did not open from settings' }
$window = [System.Windows.Automation.AutomationElement]::FromHandle($popup)
Invoke-NamedElement $window @('Overview', '概览')
$null = Wait-NamedElement $root @('Pair new iPad', '配对新 iPad', 'Unpair iPad', '取消配对')
Select-Page $root 'SettingsPage'
[HearPortPaintCheck]::DoubleClickTray($ProcessId)
$null = Wait-NamedElement $root @('Pair new iPad', '配对新 iPad', 'Unpair iPad', '取消配对')
Write-Output 'Tray power control, settings and double-click overview navigation verified'
