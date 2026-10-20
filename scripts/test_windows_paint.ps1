param([Parameter(Mandatory = $true)][int]$ProcessId)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class HearPortPaintCheck {
    delegate bool EnumProc(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr window, EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder name, int length);
    [DllImport("user32.dll", EntryPoint="GetWindowLongW")] static extern int GetWindowLong(IntPtr window, int index);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr window, StringBuilder text, int length);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] static extern bool UpdateWindow(IntPtr window);
    [DllImport("user32.dll")] static extern int GetUpdateRgn(IntPtr window, IntPtr region, bool erase);
    [DllImport("gdi32.dll")] static extern IntPtr CreateRectRgn(int l, int t, int r, int b);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wp, IntPtr lp);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
    [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left, Top, Right, Bottom; }
    public static void Verify(int processId) {
        IntPtr root = IntPtr.Zero;
        EnumWindows((w,d) => { uint pid; GetWindowThreadProcessId(w,out pid); var name=new StringBuilder(128); GetClassName(w,name,128); if(pid==processId && name.ToString()=="HearPortSenderGui") root=w; return true; },IntPtr.Zero);
        if(root==IntPtr.Zero) throw new Exception("HearPort main window not found");
        var errors=new List<string>();
        if((GetWindowLong(root,-16)&0x02000000)==0) errors.Add("Parent background can overwrite child controls");
        var order=new List<IntPtr>();
        for(var w=GetWindow(root,5);w!=IntPtr.Zero;w=GetWindow(w,2)) order.Add(w);
        IntPtr tabs=IntPtr.Zero;
        foreach(var w in order) { var name=new StringBuilder(64); GetClassName(w,name,64); if(name.ToString()=="SysTabControl32") tabs=w; }
        if(tabs==IntPtr.Zero || order.IndexOf(tabs)!=order.Count-1) errors.Add("Tab background is not behind page content");
        int groups=0;
        IntPtr heading=IntPtr.Zero; int headingY=Int32.MaxValue;
        EnumChildWindows(root,(w,d) => {
            var name=new StringBuilder(64); GetClassName(w,name,64);
            if(GetParent(w)==root && name.ToString()=="Static") {
                Rect position; GetWindowRect(w,out position);
                if(position.Top<headingY) { headingY=position.Top; heading=w; }
            }
            if(GetParent(w)!=root || name.ToString()!="Button" || (GetWindowLong(w,-16)&15)!=7) return true;
            groups++;
            if((GetWindowLong(w,-16)&0x04000000)==0) errors.Add("Group paint can overwrite sibling controls");
            foreach(var sibling in order) {
                var siblingName=new StringBuilder(64); GetClassName(sibling,siblingName,64);
                if(siblingName.ToString()=="Static" && GetParent(sibling)==root && order.IndexOf(sibling)>order.IndexOf(w))
                    errors.Add("Group background is above foreground content");
            }
            return true;
        },IntPtr.Zero);
        if(heading!=IntPtr.Zero) {
            UpdateWindow(heading);
            var before=new StringBuilder(512); GetWindowText(heading,before,512);
            SendMessage(root,0x0113,new IntPtr(1),IntPtr.Zero);
            var after=new StringBuilder(512); GetWindowText(heading,after,512);
            IntPtr region=CreateRectRgn(0,0,0,0);
            try { if(before.ToString()==after.ToString() && GetUpdateRgn(heading,region,false)>1)
                errors.Add("Unchanged status timer invalidates heading"); }
            finally { DeleteObject(region); }
        }
        if(groups!=7) errors.Add("Expected seven page groups");
        if(errors.Count>0) throw new Exception(String.Join("; ",errors));
    }
}
"@
[HearPortPaintCheck]::Verify($ProcessId)
Write-Output 'HearPort clipping, background order and unchanged-status invalidation checks passed'
