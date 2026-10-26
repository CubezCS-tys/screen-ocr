<#
  ScreenOCR - press a hotkey, drag a box over anything on screen, and Claude copies
  the text inside it to the clipboard. Claude reads it via `claude -p` in WSL, so it
  uses your Claude Code subscription (no API key). The grab is sent to Anthropic.

  Run:   double-click ScreenOCR.vbs   (or: powershell -STA -ExecutionPolicy Bypass -File ScreenOCR.ps1)
  Use:   Ctrl+Alt+L (or left-click the tray icon), drag a box. Esc / right-click cancels.
  Test:  powershell -File ScreenOCR.ps1 -OcrFile some.png   (prints the text, no UI)
#>
param(
    [string]$OcrFile,
    [string]$Hotkey = 'Ctrl+Alt+L',
    [string]$ClaudeModel = 'sonnet',
    [string]$SelfTest           # run the tray app and do one Claude grab of this image file
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class OcrNative {
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

    // Without this, screenshots on scaled displays (125%, 150%...) come out cropped/blurry.
    public static void MakeDpiAware() {
        try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; } catch { }
        try { SetProcessDPIAware(); } catch { }
    }

}

public class HotkeyWindow : NativeWindow, IDisposable {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    const int WM_HOTKEY = 0x0312;
    const uint MOD_NOREPEAT = 0x4000;

    public event EventHandler Pressed;

    public HotkeyWindow(uint mods, uint vk) {
        CreateHandle(new CreateParams());
        if (!RegisterHotKey(Handle, 1, mods | MOD_NOREPEAT, vk))
            throw new InvalidOperationException("Hotkey is already in use by another program.");
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_HOTKEY && Pressed != null) Pressed(this, EventArgs.Empty);
        base.WndProc(ref m);
    }

    public void Dispose() { UnregisterHotKey(Handle, 1); DestroyHandle(); }
}

// Full-screen frozen screenshot; the user drags a rectangle, Result holds the crop.
public class RegionSelector : Form {
    readonly Bitmap shot, dimmed;
    readonly Rectangle screen;
    Point start;
    Rectangle sel = Rectangle.Empty;
    bool dragging;
    public Bitmap Result;

    public RegionSelector() {
        screen = SystemInformation.VirtualScreen;
        shot = new Bitmap(screen.Width, screen.Height, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(shot))
            g.CopyFromScreen(screen.Left, screen.Top, 0, 0, screen.Size, CopyPixelOperation.SourceCopy);
        dimmed = new Bitmap(shot);
        using (var g = Graphics.FromImage(dimmed))
        using (var b = new SolidBrush(Color.FromArgb(120, 0, 0, 0)))
            g.FillRectangle(b, 0, 0, screen.Width, screen.Height);

        AutoScaleMode = AutoScaleMode.None;
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        Bounds = screen;
        TopMost = true;
        ShowInTaskbar = false;
        Cursor = Cursors.Cross;
        DoubleBuffered = true;
        KeyPreview = true;
    }

    protected override void OnShown(EventArgs e) { base.OnShown(e); Bounds = screen; Activate(); }

    protected override void OnKeyDown(KeyEventArgs e) { if (e.KeyCode == Keys.Escape) Cancel(); }

    protected override void OnMouseDown(MouseEventArgs e) {
        if (e.Button == MouseButtons.Right) { Cancel(); return; }
        if (e.Button != MouseButtons.Left) return;
        dragging = true;
        start = e.Location;
        sel = new Rectangle(start, Size.Empty);
    }

    protected override void OnMouseMove(MouseEventArgs e) {
        if (!dragging) return;
        Rectangle old = sel;
        sel = Rectangle.FromLTRB(Math.Min(start.X, e.X), Math.Min(start.Y, e.Y),
                                 Math.Max(start.X, e.X), Math.Max(start.Y, e.Y));
        Rectangle dirty = Rectangle.Union(old, sel);
        dirty.Inflate(3, 3);
        Invalidate(dirty);
    }

    protected override void OnMouseUp(MouseEventArgs e) {
        if (!dragging || e.Button != MouseButtons.Left) return;
        dragging = false;
        sel.Intersect(new Rectangle(Point.Empty, shot.Size));
        if (sel.Width < 4 || sel.Height < 4) { Cancel(); return; }
        Result = shot.Clone(sel, PixelFormat.Format32bppArgb);
        DialogResult = DialogResult.OK;
        Close();
    }

    protected override void OnPaintBackground(PaintEventArgs e) { }

    protected override void OnPaint(PaintEventArgs e) {
        Rectangle clip = e.ClipRectangle;
        e.Graphics.DrawImage(dimmed, clip, clip, GraphicsUnit.Pixel);
        if (sel.Width > 0 && sel.Height > 0) {
            Rectangle r = Rectangle.Intersect(sel, clip);
            if (r.Width > 0 && r.Height > 0) e.Graphics.DrawImage(shot, r, r, GraphicsUnit.Pixel);
            using (var pen = new Pen(Color.FromArgb(0, 170, 255), 2))
                e.Graphics.DrawRectangle(pen, sel.X, sel.Y, sel.Width - 1, sel.Height - 1);
        }
    }

    void Cancel() { DialogResult = DialogResult.Cancel; Close(); }

    protected override void Dispose(bool disposing) {
        if (disposing) { shot.Dispose(); dimmed.Dispose(); }
        base.Dispose(disposing);
    }
}
'@

# ---------------------------------------------------------------- Claude

# Runs Claude Code headless inside WSL, so it uses the subscription login; no API key.
# Each instance answers exactly one grab, sent as a stream-json message with the image
# inline. The app keeps one instance started ahead of time ("spare"), so Claude Code
# and WSL start-up are already done when a grab comes in.
$script:claudeDir = Join-Path $env:LOCALAPPDATA 'ScreenOCR'
$script:claudePrompt = 'Transcribe the text in this image exactly, character for character, preserving line breaks, ' +
    'indentation and layout, including table borders and box-drawing characters. It is usually terminal output or ' +
    'shell commands. Output only the transcribed text, with no commentary and no code fences. If there is no text, output nothing.'

# Troubleshooting log: %LOCALAPPDATA%\ScreenOCR\screenocr.log (trimmed when it passes 256 KB).
function Write-Log([string]$message) {
    try {
        $log = Join-Path $script:claudeDir 'screenocr.log'
        if ((Test-Path $log) -and (Get-Item $log).Length -gt 256KB) { Remove-Item $log }
        Add-Content $log ('{0:yyyy-MM-dd HH:mm:ss.fff}  {1}' -f (Get-Date), $message) -Encoding UTF8
    } catch { }
}

function ConvertTo-WslPath([string]$path) {
    '/mnt/' + $path.Substring(0, 1).ToLower() + ($path.Substring(2) -replace '\\', '/')
}

function Start-ClaudeInstance {
    $null = New-Item -ItemType Directory -Force $script:claudeDir
    # A script file sidesteps quoting through wsl.exe -> bash -> claude.
    $runner = @(
        'export PATH="$HOME/.local/bin:$PATH"'
        'cd "$(dirname "$1")"'
        "exec claude -p --input-format stream-json --output-format stream-json --verbose --model $ClaudeModel " +
            "--strict-mcp-config --mcp-config '{`"mcpServers`":{}}' --no-session-persistence --disable-slash-commands " +
            '> "$1" 2> "$1.err"'
    ) -join "`n"
    $runnerPath = Join-Path $script:claudeDir 'run.sh'
    [System.IO.File]::WriteAllText($runnerPath, $runner + "`n")

    $out = Join-Path $script:claudeDir ('claude-{0}.jsonl' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    $psi = New-Object System.Diagnostics.ProcessStartInfo 'wsl.exe'
    $psi.Arguments = '-e bash -l "{0}" "{1}"' -f (ConvertTo-WslPath $runnerPath), (ConvertTo-WslPath $out)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $instance = @{ Process = [System.Diagnostics.Process]::Start($psi); Out = $out; Started = [DateTime]::Now; SendTask = $null; InputClosed = $false }
    Write-Log "claude instance started: $(Split-Path $out -Leaf)"
    $instance
}

# Closing stdin without a message makes an idle instance exit cleanly.
function Stop-ClaudeInstance($instance) {
    if ($instance) { try { $instance.Process.StandardInput.Close() } catch { } }
}

# Writes the grab asynchronously (an instance still starting up may not be reading yet);
# Complete-ClaudeSend closes stdin once the write is done, which tells Claude Code to answer and exit.
function Send-ClaudeGrab($instance, [System.Drawing.Bitmap]$bitmap) {
    $mem = New-Object System.IO.MemoryStream
    $bitmap.Save($mem, [System.Drawing.Imaging.ImageFormat]::Png)
    # The API caps images at 5 MB; only huge full-screen grabs get near that.
    if ($mem.Length -gt 3.5MB) {
        $f = [Math]::Sqrt(3.5MB / $mem.Length) * 0.9
        $small = New-Object System.Drawing.Bitmap $bitmap, ([int]($bitmap.Width * $f)), ([int]($bitmap.Height * $f))
        $mem = New-Object System.IO.MemoryStream
        $small.Save($mem, [System.Drawing.Imaging.ImageFormat]::Png)
        $small.Dispose()
    }
    # Built by hand: ConvertTo-Json in PowerShell 5.1 is slow on multi-megabyte strings.
    $json = '{"type":"user","message":{"role":"user","content":[' +
        '{"type":"image","source":{"type":"base64","media_type":"image/png","data":"' + [Convert]::ToBase64String($mem.ToArray()) + '"}},' +
        '{"type":"text","text":' + ($script:claudePrompt | ConvertTo-Json) + '}]}}' + "`n"
    Send-ClaudePayload $instance ([System.Text.Encoding]::UTF8.GetBytes($json))
}

function Send-ClaudePayload($instance, [byte[]]$bytes) {
    $instance.Payload = $bytes
    $instance.SentAt = [DateTime]::Now
    $instance.SendTask = $instance.Process.StandardInput.BaseStream.WriteAsync($bytes, 0, $bytes.Length)
    Write-Log "grab sent to $(Split-Path $instance.Out -Leaf): $($bytes.Length) bytes"
}

function Complete-ClaudeSend($instance) {
    if ($instance.InputClosed -or -not $instance.SendTask.IsCompleted) { return }
    Stop-ClaudeInstance $instance
    $instance.InputClosed = $true
    Write-Log "input closed: $(Split-Path $instance.Out -Leaf) (send $($instance.SendTask.Status))"
}

# Returns the transcribed text, or throws with whatever Claude Code reported on failure.
function Receive-ClaudeResult($instance) {
    $lines = @(Get-Content $instance.Out -Encoding UTF8 -ErrorAction SilentlyContinue)
    $err = Get-Content "$($instance.Out).err" -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    Remove-Item $instance.Out, "$($instance.Out).err" -ErrorAction SilentlyContinue

    $resultLine = $lines | Where-Object { $_ -like '*"type":"result"*' } | Select-Object -Last 1
    if (-not $resultLine) {
        $msg = @($err, ($lines -join "`n")) | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1
        if (-not $msg) { $msg = "Claude Code exited without an answer (code $($instance.Process.ExitCode)). Is it installed and logged in inside WSL?" }
        throw $msg.Trim()
    }
    $result = $resultLine | ConvertFrom-Json
    if ($result.is_error -or $result.subtype -ne 'success') { throw ("Claude Code: {0} {1}" -f $result.result, $result.subtype).Trim() }
    ([string]$result.result).Trim("`r", "`n") -replace '\r?\n', "`r`n"
}

# Dot-sourced: load the functions only.
if ($MyInvocation.InvocationName -eq '.') { return }

if ($OcrFile) {
    $bmp = New-Object System.Drawing.Bitmap (Resolve-Path $OcrFile).Path
    $instance = Start-ClaudeInstance
    Send-ClaudeGrab $instance $bmp
    $null = $instance.SendTask.Wait(60000)
    Complete-ClaudeSend $instance
    $instance.Process.WaitForExit()
    Receive-ClaudeResult $instance
    $bmp.Dispose()
    return
}

# ---------------------------------------------------------------- tray app

$mutex = New-Object System.Threading.Mutex($false, 'Local\ScreenOCR')
if (-not $mutex.WaitOne(0)) {
    [System.Windows.Forms.MessageBox]::Show('ScreenOCR is already running - look for it in the system tray.', 'ScreenOCR') | Out-Null
    return
}

[OcrNative]::MakeDpiAware()
[System.Windows.Forms.Application]::EnableVisualStyles()

function ConvertTo-HotkeyCode([string]$text) {
    $mods = 0; $key = $null
    foreach ($part in $text -split '\+') {
        switch ($part.Trim().ToLower()) {
            'ctrl'  { $mods = $mods -bor 2 }
            'alt'   { $mods = $mods -bor 1 }
            'shift' { $mods = $mods -bor 4 }
            'win'   { $mods = $mods -bor 8 }
            default { $key = [System.Windows.Forms.Keys]$part.Trim() }
        }
    }
    , @([uint32]$mods, [uint32]$key)
}

function New-TrayIcon {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(0, 120, 215))), 2, 2, 28, 28)
    $font = New-Object System.Drawing.Font 'Segoe UI', 13, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $g.DrawString('Aa', $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, 0, 32, 32), $fmt)
    $g.Dispose()
    [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

function Set-ClipboardText([string]$text) {
    for ($i = 0; $i -lt 5; $i++) {
        try { [System.Windows.Forms.Clipboard]::SetText($text); return } catch { Start-Sleep -Milliseconds 100 }
    }
    throw 'Could not open the clipboard.'
}

$startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'ScreenOCR.lnk'
$launcher = Join-Path $PSScriptRoot 'ScreenOCR.vbs'

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = New-TrayIcon
$tray.Text = "ScreenOCR - $Hotkey to grab text"
$tray.Visible = $true

function Show-Copied([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) {
        $tray.ShowBalloonTip(2000, 'ScreenOCR', 'No text found in that area.', 'Warning')
        return
    }
    Set-ClipboardText $text
    Write-Log "copied $($text.Length) chars"
    $preview = if ($text.Length -gt 120) { $text.Substring(0, 120) + '...' } else { $text }
    $tray.ShowBalloonTip(2000, 'Copied to clipboard', $preview, 'Info')
}

# A warm Claude Code instance waiting for the next grab; replaced after every grab
# and every 30 minutes, so its login and settings never go stale.
$script:spare = $null
function Get-ClaudeInstance {
    $instance = $script:spare
    $script:spare = $null
    if (-not $instance -or $instance.Process.HasExited) { $instance = Start-ClaudeInstance }
    $instance
}
function Reset-ClaudeSpare {
    Stop-ClaudeInstance $script:spare
    $script:spare = Start-ClaudeInstance
}

# Claude takes a couple of seconds, so poll for it from a timer instead of blocking the UI.
$script:claudeJob = $null
$claudeTimer = New-Object System.Windows.Forms.Timer
$claudeTimer.Interval = 100
$claudeTimer.add_Tick({
  try {
    $job = $script:claudeJob
    Complete-ClaudeSend $job
    if (-not $job.Process.HasExited) {
        $waited = ([DateTime]::Now - $job.SentAt).TotalSeconds
        # Claude starts streaming within a few seconds. If nothing has arrived after 15 s the
        # instance is stuck (seen once in the wild), so resend the grab to a fresh one, once.
        if ($waited -gt 15 -and -not $job.Retried -and (Get-Item $job.Out -ErrorAction SilentlyContinue).Length -lt 16) {
            Write-Log "no answer after 15 s from $(Split-Path $job.Out -Leaf) (input closed: $($job.InputClosed), send $($job.SendTask.Status)); retrying with a fresh instance"
            try { $job.Process.Kill() } catch { }
            $retry = Start-ClaudeInstance
            $retry.Retried = $true
            Send-ClaudePayload $retry $job.Payload
            $script:claudeJob = $retry
            return
        }
        if ($waited -lt 90) { return }
        try { $job.Process.Kill() } catch { }
        $claudeTimer.Stop(); $script:claudeJob = $null; $script:busy = $false
        $tray.ShowBalloonTip(4000, 'ScreenOCR error', 'Claude took longer than 90 seconds; gave up.', 'Error')
        return
    }
    $claudeTimer.Stop(); $script:claudeJob = $null
    try { Show-Copied (Receive-ClaudeResult $job) }
    catch {
        Write-Log "claude error: $($_.Exception.Message)"
        $tray.ShowBalloonTip(6000, 'ScreenOCR (Claude) error', $_.Exception.Message, 'Error')
    }
    finally {
        $script:busy = $false
        try { Reset-ClaudeSpare } catch { }
    }
  } catch {
    Write-Log "timer error: $($_ | Out-String)"
    $claudeTimer.Stop(); $script:claudeJob = $null; $script:busy = $false
    $tray.ShowBalloonTip(6000, 'ScreenOCR error', $_.Exception.Message, 'Error')
  }
})

$recycleTimer = New-Object System.Windows.Forms.Timer
$recycleTimer.Interval = 60000
$recycleTimer.add_Tick({
    if (-not $script:busy -and $script:spare -and ([DateTime]::Now - $script:spare.Started).TotalMinutes -gt 30) {
        try { Reset-ClaudeSpare } catch { }
    }
})

$script:busy = $false
function Start-Capture([System.Drawing.Bitmap]$Image) {
    if ($script:busy) {
        $tray.ShowBalloonTip(1500, 'ScreenOCR', 'Still reading the last grab...', 'Info')
        return
    }
    $script:busy = $true
    $async = $false
    try {
        $selector = New-Object RegionSelector
        try {
            if ($Image) { $selector.Result = $Image }
            elseif ($selector.ShowDialog() -ne 'OK') { return }
            $job = Get-ClaudeInstance
            Send-ClaudeGrab $job $selector.Result
            $script:claudeJob = $job
            $async = $true
            $claudeTimer.Start()
            $tray.ShowBalloonTip(2000, 'ScreenOCR', 'Reading with Claude...', 'Info')
            $selector.Result.Dispose()
        } finally { $selector.Dispose() }
    } catch {
        $async = $false
        Write-Log "capture error: $($_ | Out-String)"
        $tray.ShowBalloonTip(4000, 'ScreenOCR error', $_.Exception.Message, 'Error')
    } finally {
        if (-not $async) { $script:busy = $false }
    }
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$captureItem = $menu.Items.Add("Grab text   ($Hotkey)")
$captureItem.add_Click({ Start-Capture })
$startupItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Start with Windows'
$startupItem.Checked = Test-Path $startupLink
$startupItem.add_Click({
    if (Test-Path $startupLink) {
        Remove-Item $startupLink
    } else {
        $link = (New-Object -ComObject WScript.Shell).CreateShortcut($startupLink)
        $link.TargetPath = 'wscript.exe'
        $link.Arguments = '"' + $launcher + '"'
        $link.WorkingDirectory = $PSScriptRoot
        $link.Save()
    }
    $startupItem.Checked = Test-Path $startupLink
})
$null = $menu.Items.Add($startupItem)
$null = $menu.Items.Add('-')
$exitItem = $menu.Items.Add('Exit')
$exitItem.add_Click({
    $tray.Visible = $false
    if ($script:hotkeyWindow) { $script:hotkeyWindow.Dispose() }
    Stop-ClaudeInstance $script:spare
    [System.Windows.Forms.Application]::Exit()
})
$tray.ContextMenuStrip = $menu
$tray.add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Start-Capture } })

try {
    $code = ConvertTo-HotkeyCode $Hotkey
    $script:hotkeyWindow = New-Object HotkeyWindow $code[0], $code[1]
    $script:hotkeyWindow.add_Pressed({ Start-Capture })
    $tray.ShowBalloonTip(3000, 'ScreenOCR is running', "Press $Hotkey and drag a box to copy text.", 'Info')
} catch {
    $tray.ShowBalloonTip(5000, 'ScreenOCR', "Couldn't register $Hotkey ($($_.Exception.Message)). Click the tray icon instead.", 'Warning')
}

Remove-Item (Join-Path $script:claudeDir 'claude-*') -ErrorAction SilentlyContinue
try { Reset-ClaudeSpare } catch { }
$recycleTimer.Start()
Write-Log "ScreenOCR started"

if ($SelfTest) {
    $selfTestTimer = New-Object System.Windows.Forms.Timer
    $selfTestTimer.Interval = 8000
    $selfTestTimer.add_Tick({
        $selfTestTimer.Stop()
        Write-Log "self-test grab: $SelfTest"
        Start-Capture -Image (New-Object System.Drawing.Bitmap (Resolve-Path $SelfTest).Path)
    })
    $selfTestTimer.Start()
}

[System.Windows.Forms.Application]::Run()
$tray.Dispose()
$mutex.ReleaseMutex()
