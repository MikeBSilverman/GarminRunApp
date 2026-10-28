param([string]$out)
Add-Type @"
using System; using System.Runtime.InteropServices;
public class W {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  public struct RECT { public int L,T,R,B; }
}
"@
Add-Type -AssemblyName System.Drawing
[W]::SetProcessDPIAware() | Out-Null
$h = [IntPtr]::Zero
for ($i = 0; $i -lt 20 -and $h -eq [IntPtr]::Zero; $i++) {
  $p = Get-Process simulator -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -like "CIQ Simulator*" } | Select-Object -First 1
  if ($p) { $h = $p.MainWindowHandle } else { Start-Sleep -Milliseconds 500 }
}
if ($h -eq [IntPtr]::Zero) { "no simulator window"; exit 1 }
[W]::ShowWindow($h, 9) | Out-Null                       # SW_RESTORE
# Move to 0,0, keep size, show, and make topmost: SetForegroundWindow alone
# is refused when another app has focus, and covering windows end up in the copy.
[W]::SetWindowPos($h, [IntPtr]-1, 0, 0, 0, 0, 0x0001 -bor 0x0040) | Out-Null
[W]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 1200
$r = New-Object W+RECT; [W]::GetWindowRect($h, [ref]$r) | Out-Null
$bmp = New-Object System.Drawing.Bitmap ($r.R-$r.L), ($r.B-$r.T)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
[W]::SetWindowPos($h, [IntPtr]-2, 0, 0, 0, 0, 0x0001 -bor 0x0002 -bor 0x0040) | Out-Null  # not topmost again
$bmp.Save($out)
"saved $out $($r.R-$r.L)x$($r.B-$r.T) at $($r.L),$($r.T)"
