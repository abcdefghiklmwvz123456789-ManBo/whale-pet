# 小鲸鱼余额挂件 —— 独立桌面版（无边框 / 透明 / 置顶 / 拖拽吸附 / 可调音量 / 音画同步）
# 直接轮询 DeepSeek 余额接口，追踪今日已用；不依赖 DSH Web
# 调试：powershell -File whale-pet.ps1 -SelfTest  → 启动 3 秒后自动演示一次点击效果
$ErrorActionPreference = 'Stop'

$selfTest = $args -contains '-SelfTest'

# ---------- 单实例锁：绝不出现两只鱼 ----------
$mtxName = if ($selfTest) { 'Global\WhalePetWidget_selftest' } else { 'Global\WhalePetWidget' }
$mtx = New-Object System.Threading.Mutex($false, $mtxName)
if (-not $mtx.WaitOne(0)) { exit }

$root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$whalePath = Join-Path $root 'whale.png'
$ruaPath   = Join-Path $root 'rua.gif'
$statePath = Join-Path $root 'whale-pet-state.json'
$errPath   = Join-Path $root 'pet-error.log'
$credPath  = Join-Path $env:USERPROFILE '.dsh\.credentials.yaml'
$dshwPath  = Join-Path $env:USERPROFILE '.dsh\.dshw-usage.json'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

Add-Type -Namespace Pet -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
Add-Type -Namespace Pet -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hAfter, int x, int y, int cx, int cy, uint flags);
'@
try { [void][Pet.Dpi]::SetProcessDPIAware() } catch { }

$script:lines = @(
  '又来看我啦',
  '余额还行，放心花',
  '你今天花得不多，稳',
  '谷价时段，随便跑',
  '高峰时段，省着点用',
  '我记账记得清清楚楚',
  '点我一下就想看余额是吧',
  '这钱我盯着呢，跑不了',
  '凌晨了，还折腾呢',
  '要不要看看今天花了多少'
)

function Get-ApiKey {
  if (-not (Test-Path $credPath)) { return $null }
  $m = Select-String -Path $credPath -Pattern 'DEEPSEEK_API_KEY:\s*([^\s#]+)' -ErrorAction SilentlyContinue
  if ($m) { return $m.Matches[0].Groups[1].Value.Trim() }
  return $null
}

function Load-State {
  $s = [ordered]@{
    x = $null; y = $null; day = ''; dayStart = $null
    lastBalance = $null; todayUsage = 0.0; bubble = $true
    sound = 'duck'; volume = 80; topmost = $true
  }
  if (Test-Path $statePath) {
    try {
      $o = (Get-Content $statePath -Raw) | ConvertFrom-Json
      foreach ($k in @($s.Keys)) { if ($o.PSObject.Properties.Name -contains $k) { $s[$k] = $o.$k } }
    } catch { }
  }
  if ($s.day -ne (Get-Date -Format 'yyyy-MM-dd') -and (Test-Path $dshwPath)) {
    try {
      $w = (Get-Content $dshwPath -Raw) | ConvertFrom-Json
      if ($w.date -eq (Get-Date -Format 'yyyy-MM-dd') -and $null -ne $w.dayStart) {
        $s.day = $w.date; $s.dayStart = [double]$w.dayStart
        $s.todayUsage = [double]$w.todayUsage; $s.lastBalance = [double]$w.lastBalance
      }
    } catch { }
  }
  return $s
}

function Save-State($s) {
  try { ($s | ConvertTo-Json -Depth 4) | Set-Content -Path $statePath -Encoding UTF8 } catch { }
}

# ---------- 界面（固定 200x232，尺寸恒定不抖动） ----------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        Width="200" Height="262" Title="小鲸鱼余额挂件">
  <StackPanel Background="Transparent" VerticalAlignment="Top">
    <Border x:Name="Bubble" CornerRadius="11" Background="#E6151A21" Padding="11,8"
            HorizontalAlignment="Right" Margin="0,0,8,2">
      <StackPanel>
        <TextBlock x:Name="BubbleText" Foreground="#FFEDEFF2" FontSize="12"
                   FontFamily="Microsoft YaHei UI" TextAlignment="Right"/>
        <TextBlock x:Name="SayText" Foreground="#FF7FB2FF" FontSize="11.5" Margin="0,3,0,0"
                   FontFamily="Microsoft YaHei UI" TextAlignment="Right" MaxWidth="172"
                   TextWrapping="Wrap" Visibility="Collapsed"/>
      </StackPanel>
    </Border>
    <Grid HorizontalAlignment="Right" Margin="0,0,8,0">
      <Image x:Name="Whale" Width="132" Stretch="Uniform" RenderTransformOrigin="0.5,1">
        <Image.RenderTransform>
          <ScaleTransform x:Name="WhaleScale" ScaleX="1" ScaleY="1"/>
        </Image.RenderTransform>
      </Image>
      <Image x:Name="Rua" Width="132" Stretch="Uniform" Opacity="0" Visibility="Collapsed" IsHitTestVisible="False"/>
    </Grid>
    <Border CornerRadius="9" Background="#E011161F" Padding="10,5" HorizontalAlignment="Center" Margin="0,6,0,0">
      <StackPanel Orientation="Horizontal">
        <TextBlock x:Name="ClockText" Foreground="#FFC9D4E0" FontSize="12" FontFamily="Consolas"/>
        <TextBlock x:Name="ClockTag" Foreground="#FF8BE9A8" FontSize="11" FontFamily="Microsoft YaHei UI" Margin="7,1,0,0" VerticalAlignment="Center"/>
      </StackPanel>
    </Border>  </StackPanel>
</Window>
'@

$win        = [System.Windows.Markup.XamlReader]::Parse($xaml)
$bubble     = $win.FindName('Bubble')
$bubbleText = $win.FindName('BubbleText')
$sayText    = $win.FindName('SayText')
$whale      = $win.FindName('Whale')
$rua        = $win.FindName('Rua')
$scale      = $win.FindName('WhaleScale')
$clockText  = $win.FindName('ClockText')
$clockTag   = $win.FindName('ClockTag')

function Set-Img($ctrl, $path) {
  if (-not (Test-Path $path)) { return }
  $bi = New-Object System.Windows.Media.Imaging.BitmapImage
  $bi.BeginInit()
  $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
  $bi.UriSource   = New-Object System.Uri($path)
  $bi.EndInit()
  $bi.Freeze()
  $ctrl.Source = $bi
  [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($ctrl, [System.Windows.Media.BitmapScalingMode]::Linear)
}
Set-Img $whale $whalePath

# 鲸鱼缩放动画走位图缓存，Q 弹更顺
try {
  $cache = New-Object System.Windows.Media.BitmapCache
  $cache.RenderAtScale = 1.2
  $whale.CacheMode = $cache
} catch { }

# ---------- 摸头动图：逐帧解码，真正播放 ----------
$script:ruaFrames = New-Object System.Collections.ArrayList
$script:ruaDelays = New-Object System.Collections.ArrayList
$script:ruaIdx    = 0
if (Test-Path $ruaPath) {
  try {
    $dec = New-Object System.Windows.Media.Imaging.GifBitmapDecoder(
      (New-Object System.Uri($ruaPath)),
      [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
      [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
    for ($i = 0; $i -lt $dec.Frames.Count; $i++) {
      $fr = $dec.Frames[$i]
      $fr.Freeze()
      [void]$script:ruaFrames.Add($fr)
      $d = 80
      foreach ($q in @('/grctlext/Delay', '/gfx/Delay')) {
        try { $v = $fr.Metadata.GetQuery($q); if ($v) { $d = [int]$v * 10; break } } catch { }
      }
      [void]$script:ruaDelays.Add([Math]::Max(40, $d))
    }
  } catch { }
}

$script:state   = Load-State
$script:key     = Get-ApiKey
$script:dragFrom = $null

# ---------- 音效：MCI直播（绕开WPF媒体栈）+本地副本 ----------
$script:sndDir = Join-Path $env:LOCALAPPDATA 'whale-pet-snd'
function Snd-Log([string]$msg) { try { [IO.File]::AppendAllText($script:errPath, ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $msg) + "`r`n") } catch { } }
try { [void][IO.Directory]::CreateDirectory($script:sndDir) } catch { }
foreach ($n in @('Ya1','Ya2','D1','D2')) {
  try {
    foreach ($ext in @('wav','mp3')) {
      $srcF = Join-Path $root "$n.$ext"; $dstF = Join-Path $script:sndDir "$n.$ext"
      if ((Test-Path $srcF) -and ((-not (Test-Path $dstF)) -or ((Get-Item $srcF).Length -ne (Get-Item $dstF).Length))) { Copy-Item $srcF $dstF -Force -ErrorAction Stop }
    }
  } catch { }
}
if (-not ('Native.Mci' -as [type])) {
  Add-Type -Namespace Native -Name Mci -MemberDefinition '[DllImport("winmm.dll", CharSet = CharSet.Auto)] public static extern int mciSendString(string cmd, System.Text.StringBuilder ret, int cch, IntPtr hwnd); [DllImport("winmm.dll")] public static extern int waveOutSetVolume(IntPtr uDeviceID, uint dwVolume);'
}
$script:sndOpen = @{}
function Play-Snd([string]$which) {
  if ($script:state.sound -eq 'off') { return }
  $v = [double]$script:state.volume
  if ($v -le 0) { return }
  $prefix = if ($script:state.sound -eq 'fx1') { 'D' } else { 'Ya' }
  $key = $prefix + $which
  $pW = Join-Path $script:sndDir "$key.wav"; $pM = Join-Path $script:sndDir "$key.mp3"
  if (Test-Path $pW) { $p = $pW; $t = 'waveaudio' } elseif (Test-Path $pM) { $p = $pM; $t = 'mpegvideo' } else { Snd-Log "mci $key file-missing"; return }
  $alias = "snd_$key"
  if (-not $script:sndOpen.ContainsKey($key)) {
    $e = [Native.Mci]::mciSendString("open `"$p`" type $t alias $alias", $null, 0, [IntPtr]::Zero)
    if ($e -ne 0) { Snd-Log "mci open $key type=$t err=$e"; return }
    $script:sndOpen[$key] = $true
    Snd-Log "mci open $key type=$t ok"
  }
  $vol = [int][math]::Round(([math]::Min(1.0, $v / 100.0)) * 1000)
  [void][Native.Mci]::mciSendString("stop $alias", $null, 0, [IntPtr]::Zero)
  [void][Native.Mci]::mciSendString("seek $alias to start", $null, 0, [IntPtr]::Zero)
  if ($t -eq 'waveaudio') {
    $wv = [uint32][math]::Round($vol * 65535.0 / 1000.0)
    [void][Native.Mci]::waveOutSetVolume([IntPtr]::Zero, ($wv -bor ($wv -shl 16)))
    $e2 = 0
  } else {
    $e2 = [Native.Mci]::mciSendString("setaudio $alias volume to $vol", $null, 0, [IntPtr]::Zero)
  }
  $e3 = [Native.Mci]::mciSendString("play $alias", $null, 0, [IntPtr]::Zero)
  Snd-Log "mci play $key type=$t err=$e3 vol-err=$e2 vol=$vol"
}

# ---------- 全局异常保险丝：任何后台异常只记日志，绝不崩进程 ----------
try {
  [System.Windows.Threading.Dispatcher]::CurrentDispatcher.add_UnhandledException({ param($s, $e) try { [IO.File]::AppendAllText($script:errPath, ("[{0}] dispatcher-ex: {1}" -f (Get-Date -Format 'HH:mm:ss'), $e.Exception.Message) + "`r`n") } catch { }; $e.Handled = $true })
} catch { }
# ---------- 气泡 ----------
function Update-Bubble {
  $b = $script:state
  if ($null -eq $b.lastBalance) { $bubbleText.Text = "余额 —`n今日 —"; return }
  $bubbleText.Text = ("余额 ¥{0:N2}`n今日 ¥{1:N2}" -f [double]$b.lastBalance, [double]$b.todayUsage)
  if ([double]$b.lastBalance -lt 5) {
    $bubbleText.Foreground = [System.Windows.Media.Brushes]::Orange
  } else {
    $bubbleText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#EDEFF2')
  }
}

function Say-Line {
  $sayText.Text = $script:lines[(Get-Random -Minimum 0 -Maximum $script:lines.Count)]
  $sayText.Visibility = 'Visible'
  $script:sayTimer.Stop()
  $script:sayTimer.Start()
}

# 摸头：收起静态鲸鱼，单独播放动图
function Show-Rua {
  if ($script:ruaFrames.Count -eq 0) { return }
  $whale.Visibility = 'Hidden'
  $rua.Visibility   = 'Visible'
  $rua.Opacity      = 1
  $script:ruaIdx = 0
  $rua.Source = $script:ruaFrames[0]
  $script:ruaPlayTimer.Interval = New-Object TimeSpan (0,0,0,0,[int]$script:ruaDelays[0])
  $script:ruaPlayTimer.Start()
  $script:ruaTimer.Stop()
  $script:ruaTimer.Start()
}

function Hide-Rua {
  $script:ruaPlayTimer.Stop()
  $rua.Opacity      = 0
  $rua.Visibility   = 'Collapsed'
  $whale.Visibility = 'Visible'
}

function Bounce {
  try {
    $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $null)
    $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $null)
    $ease = New-Object System.Windows.Media.Animation.BackEase
    $ease.Amplitude  = 0.6
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    foreach ($prop in @([System.Windows.Media.ScaleTransform]::ScaleXProperty, [System.Windows.Media.ScaleTransform]::ScaleYProperty)) {
      $kf = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
      $kf.BeginTime = [TimeSpan]::FromMilliseconds(60)
      $k1 = New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame
      $k1.KeyTime = [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(100))
      $k1.Value   = 1.22
      $k2 = New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame
      $k2.KeyTime = [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(540))
      $k2.Value   = 1.0
      $k2.EasingFunction = $ease
      [void]$kf.KeyFrames.Add($k1)
      [void]$kf.KeyFrames.Add($k2)
      [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($kf, 120)
      $scale.BeginAnimation($prop, $kf)
    }
  } catch { }
}

$script:ruaPlayTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ruaPlayTimer.Add_Tick({
  if ($script:ruaFrames.Count -eq 0) { $script:ruaPlayTimer.Stop(); return }
  $rua.Source = $script:ruaFrames[$script:ruaIdx]
  $script:ruaPlayTimer.Interval = New-Object TimeSpan (0,0,0,0,[int]$script:ruaDelays[$script:ruaIdx])
  $script:ruaIdx++
  if ($script:ruaIdx -ge $script:ruaFrames.Count) { $script:ruaIdx = 0 }
})

$script:ruaTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ruaTimer.Interval = [TimeSpan]::FromMilliseconds(1800)
$script:ruaTimer.Add_Tick({ Hide-Rua; $script:ruaTimer.Stop() })

$script:sayTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:sayTimer.Interval = [TimeSpan]::FromMilliseconds(4200)
$script:sayTimer.Add_Tick({ $sayText.Visibility = 'Collapsed'; $script:sayTimer.Stop() })
# ---------- 时间条：北京时间 + 峰谷时段（高峰=工作日9-12/14-18，其余谷价，周末全天谷价） ----------
$script:cnTz = [System.TimeZoneInfo]::FindSystemTimeZoneById('China Standard Time')
function Update-Clock {
  try {
    $cn = [System.TimeZoneInfo]::ConvertTime([DateTime]::UtcNow, $script:cnTz)
    $clockText.Text = $cn.ToString('HH:mm:ss') + ' 北京'
    $peak = $false
    if ($cn.DayOfWeek -ge [DayOfWeek]::Monday -and $cn.DayOfWeek -le [DayOfWeek]::Friday) {
      $t = $cn.TimeOfDay
      if (($t -ge [TimeSpan]'09:00:00' -and $t -lt [TimeSpan]'12:00:00') -or ($t -ge [TimeSpan]'14:00:00' -and $t -lt [TimeSpan]'18:00:00')) { $peak = $true }
    }
    if ($peak) { $clockTag.Text = '高峰'; $clockTag.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFFFB86C') }
    else { $clockTag.Text = '谷价'; $clockTag.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF8BE9A8') }
  } catch { }
}
$script:clockTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:clockTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:clockTimer.Add_Tick({ Update-Clock })
Update-Clock
$script:clockTimer.Start()



function Invoke-ClickEffect {
  Play-Snd '1'
  Show-Rua
  Say-Line
  Refresh-Balance
}

# ---------- 取余额：后台请求，UI 永不阻塞（网络慢时动画声音也不卡） ----------
$script:bg       = [hashtable]::Synchronized(@{ err = $null; result = $null })
$script:bgBusy   = $false
$script:bgPs     = $null
$script:bgHandle = $null
$script:bgRunspace = [runspacefactory]::CreateRunspace()
$script:bgRunspace.Open()

$script:bgPollTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:bgPollTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:bgPollTimer.Add_Tick({
  if (-not $script:bgBusy) { return }
  try {
    if ($script:bgPs.InvocationStateInfo.State -ne 'Completed') { return }
    try { $script:bgPs.EndInvoke($script:bgHandle) } catch { }
    $script:bgBusy = $false
    $bal = $null
    if (-not [string]::IsNullOrEmpty([string]$script:bg.result)) { $bal = [double]$script:bg.result }
    if ($null -ne $bal) {
      $today = Get-Date -Format 'yyyy-MM-dd'
      $b = $script:state
      if ($b.day -ne $today) { $b.day = $today; $b.dayStart = $bal; $b.todayUsage = 0.0 }
      if ($null -eq $b.dayStart) { $b.dayStart = $bal }
      if ($null -ne $b.lastBalance -and $bal -lt [double]$b.lastBalance) {
        $b.todayUsage = [math]::Round([double]$b.todayUsage + ([double]$b.lastBalance - $bal), 6)
      }
      $b.lastBalance = $bal
      Save-State $b
      Update-Bubble
    } else {
      if ($null -eq $script:state.lastBalance) { $bubbleText.Text = '余额获取失败' }
    }
  } catch { }
})

function Start-BalanceJob {
  if ($script:bgBusy) { return }
  if (-not $script:key) { $bubbleText.Text = '未找到 API Key'; return }
  $script:bg.err = $null; $script:bg.result = $null
  $script:bgPs = [powershell]::Create()
  $script:bgPs.Runspace = $script:bgRunspace
  [void]$script:bgPs.AddScript({
    param($box, $apiKey)
    try {
      $r = Invoke-RestMethod -Uri 'https://api.deepseek.com/user/balance' -Headers @{ Authorization = ("Bearer " + $apiKey) } -TimeoutSec 20
      $info = $r.balance_infos | Select-Object -First 1
      $box.result = [string]$info.total_balance
    } catch { $box.err = $_.Exception.Message }
  })
  [void]$script:bgPs.AddArgument($script:bg)
  [void]$script:bgPs.AddArgument($script:key)
  $script:bgHandle = $script:bgPs.BeginInvoke()
  $script:bgBusy = $true
  $script:bgPollTimer.Start()
}

function Refresh-Balance {
  if ($null -ne $script:dragFrom) { return }
  Start-BalanceJob
}
# ---------- 初始位置（越界自动回右下角） ----------
$wa = [System.Windows.SystemParameters]::WorkArea
$win.WindowStartupLocation = 'Manual'
$sx = $script:state.x; $sy = $script:state.y
$okPos = ($null -ne $sx -and $null -ne $sy -and
          (([double]$sx) + 200) -gt ($wa.Left + 20) -and ([double]$sx) -lt ($wa.Right - 20) -and
          (([double]$sy) + 60)  -gt ($wa.Top + 20)  -and ([double]$sy) -lt ($wa.Bottom - 20))
if ($okPos) {
  $win.Left = [double]$sx
  $win.Top  = [double]$sy
} else {
  $win.Left = $wa.Right - 200
  $win.Top  = $wa.Bottom - 262
  $script:state.x = $win.Left; $script:state.y = $win.Top
}
if (-not $script:state.bubble) { $bubble.Visibility = 'Hidden' }
$win.Topmost = [bool]$script:state.topmost

# ---------- 右键菜单 ----------
$menu      = New-Object System.Windows.Controls.ContextMenu
$miRefresh = New-Object System.Windows.Controls.MenuItem; $miRefresh.Header = '立即刷新'
$miBubble  = New-Object System.Windows.Controls.MenuItem; $miBubble.Header  = '显示 / 隐藏气泡'
$miVol     = New-Object System.Windows.Controls.MenuItem; $miVol.Header     = '音量'
$miDuck    = New-Object System.Windows.Controls.MenuItem; $miDuck.Header    = '音效：小黄鸭'; $miDuck.IsCheckable = $true
$miFx1     = New-Object System.Windows.Controls.MenuItem; $miFx1.Header     = '音效：音效1';  $miFx1.IsCheckable = $true
$miMute    = New-Object System.Windows.Controls.MenuItem; $miMute.Header    = '静音';         $miMute.IsCheckable = $true
$miTop     = New-Object System.Windows.Controls.MenuItem; $miTop.Header     = '取消置顶'
$miReset   = New-Object System.Windows.Controls.MenuItem; $miReset.Header   = '回到右下角'
$miExit    = New-Object System.Windows.Controls.MenuItem; $miExit.Header    = '退出挂件'

$miDuck.IsChecked = ($script:state.sound -eq 'duck')
$miFx1.IsChecked  = ($script:state.sound -eq 'fx1')
$miMute.IsChecked = ($script:state.sound -eq 'off')

$script:volItems = @{}
foreach ($lv in @(100, 80, 60, 40, 20)) {
  $mi = New-Object System.Windows.Controls.MenuItem
  $mi.Header      = "$lv%"
  $mi.IsCheckable = $true
  $mi.Tag         = $lv
  $mi.Add_Click({
    $script:state.volume = [int]$this.Tag
    foreach ($k in $script:volItems.Keys) { $script:volItems[$k].IsChecked = ([int]$k -eq [int]$script:state.volume) }
    Save-State $script:state
    Play-Snd '2'
  })
  $miVol.Items.Add($mi) | Out-Null
  $script:volItems[$lv] = $mi
}
$curVol = [int]$script:state.volume
if (-not $script:volItems.ContainsKey($curVol)) { $curVol = 80; $script:state.volume = 80 }
$script:volItems[$curVol].IsChecked = $true

$miRefresh.Add_Click({ Refresh-Balance })
$miBubble.Add_Click({
  if ($bubble.Visibility -eq 'Visible') { $bubble.Visibility = 'Hidden'; $script:state.bubble = $false }
  else { $bubble.Visibility = 'Visible'; $script:state.bubble = $true }
  Save-State $script:state
})
$miDuck.Add_Click({ $script:state.sound = 'duck'; $miDuck.IsChecked = $true; $miFx1.IsChecked = $false; $miMute.IsChecked = $false; Save-State $script:state; Play-Snd '2' })
$miFx1.Add_Click({  $script:state.sound = 'fx1';  $miDuck.IsChecked = $false; $miFx1.IsChecked = $true; $miMute.IsChecked = $false; Save-State $script:state; Play-Snd '2' })
$miMute.Add_Click({ $script:state.sound = 'off';  $miDuck.IsChecked = $false; $miFx1.IsChecked = $false; $miMute.IsChecked = $true; Save-State $script:state })
$miTop.Add_Click({
  if ($win.Topmost) { $win.Topmost = $false; $miTop.Header = '设为置顶'; $script:state.topmost = $false }
  else { $win.Topmost = $true; $miTop.Header = '取消置顶'; $script:state.topmost = $true }
  Save-State $script:state
})
$miReset.Add_Click({
  $win.Left = $wa.Right - 200
  $win.Top  = $wa.Bottom - 262
  $script:state.x = $win.Left; $script:state.y = $win.Top
  Save-State $script:state
})
$miExit.Add_Click({ $win.Close() })

$menu.Items.Add($miRefresh) | Out-Null
$menu.Items.Add($miBubble)  | Out-Null
$menu.Items.Add($miVol)     | Out-Null
$menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
$menu.Items.Add($miDuck)    | Out-Null
$menu.Items.Add($miFx1)     | Out-Null
$menu.Items.Add($miMute)    | Out-Null
$menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
$menu.Items.Add($miTop)     | Out-Null
$menu.Items.Add($miReset)   | Out-Null
$menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
$menu.Items.Add($miExit)    | Out-Null
$win.ContextMenu = $menu

# ---------- 按压 / 点击 / 拖拽 ----------
$script:dragWin   = $null
$script:dragMoved = $false
$script:dpiScale  = 1.0

$press = {
  try { [void]$win.CaptureMouse() } catch { }
  $script:dragMoved = $false
  $script:dragFrom  = [System.Windows.Forms.Cursor]::Position
  $script:dragWin   = @{ L = $win.Left; T = $win.Top }
  $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $null)
  $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $null)
  $scale.ScaleX = 0.93
  $scale.ScaleY = 0.93
}

$move = {
  if ($null -eq $script:dragFrom) { return }
  $cur = [System.Windows.Forms.Cursor]::Position
  $dx = ($cur.X - $script:dragFrom.X) / $script:dpiScale
  $dy = ($cur.Y - $script:dragFrom.Y) / $script:dpiScale
  if (-not $script:dragMoved -and ([math]::Abs($dx) -gt 3 -or [math]::Abs($dy) -gt 3)) { $script:dragMoved = $true }
  if ($script:dragMoved) {
    $win.Left = $script:dragWin.L + $dx
    $win.Top  = $script:dragWin.T + $dy
  }
}

$release = {
  if ($null -eq $script:dragFrom) { return }
  $script:dragFrom = $null
  try { $win.ReleaseMouseCapture() } catch { }
  $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $null)
  $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $null)
  $scale.ScaleX = 1.0
  $scale.ScaleY = 1.0
  if ($script:dragMoved) {
    if ([math]::Abs($win.Left - $wa.Left)  -lt 50) { $win.Left = $wa.Left }
    if ([math]::Abs($win.Left + $win.ActualWidth - $wa.Right) -lt 50) { $win.Left = $wa.Right - $win.ActualWidth }
    if ([math]::Abs($win.Top  - $wa.Top)   -lt 50) { $win.Top  = $wa.Top }
    if ([math]::Abs($win.Top + $win.ActualHeight - $wa.Bottom) -lt 50) { $win.Top = $wa.Bottom - $win.ActualHeight }
    $script:state.x = $win.Left; $script:state.y = $win.Top
    Save-State $script:state
  } else {
    Invoke-ClickEffect
  }
}
$win.Add_MouseLeftButtonDown($press)
$win.Add_MouseMove($move)
$win.Add_MouseLeftButtonUp($release)
# 兜底：鼠标捕获丢失时清掉拖拽态，防止卡在"半按"状态
$win.Add_LostMouseCapture({
  if ($null -ne $script:dragFrom -and -not $script:dragMoved) { $script:dragFrom = $null }
})

# ---------- 每 60 秒自动刷新 ----------
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(60)
$timer.Add_Tick({ Refresh-Balance })
$timer.Start()

# ---------- 显示 ----------
Update-Bubble
$win.Add_Closed({ foreach ($tm in @($timer, $script:sayTimer, $script:ruaTimer, $script:ruaPlayTimer, $script:bgPollTimer, $script:clockTimer)) { try { $tm.Stop() } catch { } }; try { if ($script:bgPs) { $script:bgPs.Dispose() } } catch { }; try { if ($script:bgRunspace) { $script:bgRunspace.Dispose() } } catch { }; [System.Windows.Threading.Dispatcher]::Current.Dispatcher.InvokeShutdown() })
$win.Show()
$h = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
[void][Pet.Win]::ShowWindow($h, 4)
[void][Pet.Win]::SetWindowPos($h, ([IntPtr](-1)), 0, 0, 0, 0, 0x0053)
try { $script:dpiScale = [System.Windows.Media.VisualTreeHelper]::GetDpi($win).DpiScaleX } catch { }
Refresh-Balance

if ($selfTest) {
  $st = New-Object System.Windows.Threading.DispatcherTimer
  $st.Interval = [TimeSpan]::FromSeconds(3)
  $st.Add_Tick({ Invoke-ClickEffect; $st.Stop() })
  $st.Start()
  $quit = New-Object System.Windows.Threading.DispatcherTimer
  $quit.Interval = [TimeSpan]::FromSeconds(30)
  $quit.Add_Tick({ $win.Close(); $quit.Stop() })
  $quit.Start()
}

[System.Windows.Threading.Dispatcher]::CurrentDispatcher.add_UnhandledException({
  param($s, $e)
  Add-Content -Path $errPath -Value ((Get-Date -Format 'HH:mm:ss') + "  " + $e.Exception.GetType().FullName + " :: " + $e.Exception.Message)
})
[System.Windows.Threading.Dispatcher]::Run()
