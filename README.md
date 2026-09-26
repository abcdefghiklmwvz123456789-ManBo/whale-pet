# whale-pet 🐋

> 一只住在 Windows 桌面右下角的 DeepSeek 鲸鱼娘挂件

## 来源说明 / Credits

本项目基于 **DeepSeek 官方 Agent 框架 [DSH](https://github.com/deepseek-ai/DSH)** 内置的网页鲸鱼挂件插件（`dsh-whale-widget`）**改造而成**：

- 鲸鱼娘形象与音效素材均来自原挂件项目，版权归原项目（DeepSeek）所有
- 桌面版逻辑（窗口、托盘交互、余额轮询、峰谷时段时钟等）为独立重写的 PowerShell/WPF 实现
- 由网页悬浮层改造成可独立运行的 Windows 桌面常驻挂件

## 功能

- 🐋 桌面右下角悬浮鲸鱼，可拖拽、可摸头（会摇尾巴）
- 💰 自动轮询 DeepSeek API 余额，余额变动时气泡提醒
- 🕐 实时北京时间时钟 + **峰谷时段标签**：
  - 🟠 高峰（橙色）：工作日 9:00–12:00、14:00–18:00（北京时间）
  - 🟢 谷价（绿色）：其余时间，**周末全天谷价**
  - 与 DeepSeek API 错峰定价规则一致，谷价时段随便跑
- 🔊 摸头/点击音效（MCI 播放，支持 WAV/MP3）
- 右键菜单：刷新余额、重置位置、自检、退出

## 运行要求

- Windows 10/11
- Windows PowerShell 5.1（系统自带，无需安装任何东西）

## 使用方法

双击 `restart-whale.bat` 即可启动/重启。

或手动：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File .\whale-pet.ps1
```

首次运行请在右键菜单里填入你的 DeepSeek API Key。

## 文件说明

| 文件 | 作用 |
|---|---|
| `whale-pet.ps1` | 主程序（单文件，无依赖） |
| `restart-whale.bat` | 一键启动/重启 |
| `Ya1.wav` `Ya2.wav` `D1.wav` `D2.wav` | 音效 |
| `whale.png` / `whale.gif` | 鲸鱼娘素材（来自原挂件） |

## License

代码部分 MIT。鲸鱼娘形象及音效素材版权归 DSH 鲸鱼挂件原项目所有，仅作学习交流使用。
