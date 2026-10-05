// whale-mac.swift —— 小鲸鱼余额挂件 macOS 版（v1.1.0）
// 功能对齐 Windows 版：无边框透明置顶 / 气泡余额+今日用量 / 摸头GIF / 双音效+音量档
// 拖拽边缘吸附 / 北京时间+峰谷时钟 / 60秒自动刷新 / 单实例锁 / 右键菜单
// 编译：swiftc -O whale-mac.swift -o whale-pet-mac

import AppKit
import Darwin

// ---------- 常量：台词库 ----------
let petLines = [
    "又来看我啦",
    "余额还行，放心花",
    "你今天花得不多，稳",
    "谷价时段，随便跑",
    "高峰时段，省着点用",
    "我记账记得清清楚楚",
    "点我一下就想看余额是吧",
    "这钱我盯着呢，跑不了",
    "凌晨了，还折腾呢",
    "要不要看看今天花了多少"
]

let winW: CGFloat = 200, winH: CGFloat = 262
let whaleW: CGFloat = 132, whaleH: CGFloat = 165

// ---------- 状态持久化 ----------
struct PetState: Codable {
    var x: Double? = nil
    var y: Double? = nil
    var day: String = ""
    var dayStart: Double? = nil
    var lastBalance: Double? = nil
    var todayUsage: Double = 0
    var bubble: Bool = true
    var sound: String = "duck"
    var volume: Double = 80
    var topmost: Bool = true
}

let fm = FileManager.default
let supportDir = NSHomeDirectory() + "/Library/Application Support/WhalePet"
let statePath  = supportDir + "/whale-pet-state.json"
let keyTxtPath = NSHomeDirectory() + "/.whale-pet/key.txt"
let dshCredPath = NSHomeDirectory() + "/.dsh/.credentials.yaml"

func loadState() -> PetState {
    if let data = fm.contents(atPath: statePath),
       let s = try? JSONDecoder().decode(PetState.self, from: data) { return s }
    return PetState()
}
func saveState(_ s: PetState) {
    try? fm.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(s) { try? data.write(to: URL(fileURLWithPath: statePath)) }
}

// ---------- API Key：优先 DSH 凭证，其次自有配置 ----------
func readApiKey() -> String? {
    if let txt = try? String(contentsOfFile: dshCredPath, encoding: .utf8) {
        for line in txt.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("DEEPSEEK_API_KEY:") {
                let v = t.dropFirst("DEEPSEEK_API_KEY:".count).trimmingCharacters(in: CharacterSet(charactersIn: " \t\"#"))
                if !v.isEmpty { return String(v) }
            }
        }
    }
    if let txt = try? String(contentsOfFile: keyTxtPath, encoding: .utf8) {
        let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.isEmpty { return v }
    }
    return nil
}

// ---------- 资源路径（bundle Resources，兜底脚本目录） ----------
func resURL(_ name: String, _ ext: String) -> String? {
    if let u = Bundle.main.url(forResource: name, withExtension: ext) { return u.path }
    let p = fm.currentDirectoryPath + "/" + name + "." + ext
    return fm.fileExists(atPath: p) ? p : nil
}

// ---------- 单实例锁：绝不出现两只鱼 ----------
try? fm.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
let lockFD = open(supportDir + "/.whale-pet.lock", O_CREAT | O_RDWR, 0o644)
if lockFD >= 0 { if flock(lockFD, LOCK_EX | LOCK_NB) != 0 { exit(0) } }

// ---------- 全局状态 ----------
var state = loadState()
var apiKey = readApiKey()

// ---------- 菜单动作中转（闭包挂到 NSMenuItem） ----------
final class MenuTarget: NSObject {
    static let shared = MenuTarget()
    var handlers: [ObjectIdentifier: () -> Void] = [:]
    @objc func fire(_ sender: NSMenuItem) {
        handlers[ObjectIdentifier(sender)]?()
    }
}

// ---------- 自定义内容视图：点击/拖拽/右键 ----------
final class PetRootView: NSView {
    weak var del: AppDelegate?
    override func mouseDown(with event: NSEvent) {
        guard let del = del else { return }
        del.downMouse = NSEvent.mouseLocation
        del.whaleView.layer?.removeAnimation(forKey: "bounce")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        del.whaleView.layer?.transform = CATransform3DMakeScale(0.93, 0.93, 1)
        CATransaction.commit()
        window?.performDrag(with: event)
        // performDrag 返回 = 鼠标已松开（含原地松开）
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        del.whaleView.layer?.transform = CATransform3DIdentity
        CATransaction.commit()
        let now = NSEvent.mouseLocation
        let dx = now.x - del.downMouse.x, dy = now.y - del.downMouse.y
        if abs(dx) < 3 && abs(dy) < 3 {
            del.clickEffect()
        } else {
            del.snapAndSave()
        }
    }
    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        del?.showMenu(at: p)
    }
}

// ---------- AppDelegate ----------
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var bubbleView: NSView!
    var balanceField: NSTextField!
    var sayField: NSTextField!
    var whaleView: NSImageView!
    var ruaView: NSImageView!
    var clockView: NSView!
    var clockField: NSTextField!
    var tagField: NSTextField!

    var sayTimer: Timer?
    var ruaTimer: Timer?
    var clockTimer: Timer?
    var refreshTimer: Timer?

    var downMouse: NSPoint = .zero

    let cnTZ = TimeZone(identifier: "Asia/Shanghai")!
    let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    let clockFmt: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildWindow()
        layoutViews()
        restorePosition()
        updateBubble()
        updateClock()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in self.updateClock() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { _ in self.refreshBalance() }
        refreshBalance()
    }
    func windowShouldClose(_ s: NSWindow) -> Bool { NSApp.terminate(nil); return false }

    // ---------- UI 构建 ----------
    func panelView(_ color: NSColor, radius: CGFloat) -> NSView {
        let v = NSView(frame: .zero)
        v.wantsLayer = true
        v.layer?.cornerRadius = radius
        v.layer?.masksToBounds = true
        v.layer?.backgroundColor = color.cgColor
        return v
    }
    func makeLabel(_ size: CGFloat, _ color: NSColor, mono: Bool = false) -> NSTextField {
        let t = NSTextField(labelWithString: "")
        t.font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
                       : NSFont.systemFont(ofSize: size)
        t.textColor = color
        t.alignment = .right
        return t
    }
    func buildWindow() {
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: winW, height: winH),
                             styleMask: [.borderless],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = state.topmost ? .floating : .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        panel.delegate = self

        let root = PetRootView(frame: NSRect(x: 0, y: 0, width: winW, height: winH))
        root.wantsLayer = true
        root.del = self

        // 气泡（深色圆角，右对齐）
        let lightText = NSColor(srgbRed: 0xED/255.0, green: 0xEF/255.0, blue: 0xF2/255.0, alpha: 1)
        bubbleView = panelView(NSColor(srgbRed: 0x15/255.0, green: 0x1A/255.0, blue: 0x21/255.0, alpha: 0xE6/255.0), radius: 11)
        balanceField = makeLabel(12, lightText)
        balanceField.maximumNumberOfLines = 2
        balanceField.lineBreakMode = .byWordWrapping
        sayField = makeLabel(11.5, NSColor(srgbRed: 0x7F/255.0, green: 0xB2/255.0, blue: 0xFF/255.0, alpha: 1))
        sayField.lineBreakMode = .byWordWrapping
        sayField.maximumNumberOfLines = 2
        sayField.isHidden = true
        bubbleView.addSubview(sayField)
        bubbleView.addSubview(balanceField)
        root.addSubview(bubbleView)

        // 鲸鱼 + 摸头动图（重叠同位置）
        whaleView = NSImageView(frame: NSRect(x: winW - 8 - whaleW, y: 0, width: whaleW, height: whaleH))
        whaleView.imageScaling = .scaleProportionallyUpOrDown
        whaleView.wantsLayer = true
        if let wp = resURL("whale", "png") { whaleView.image = NSImage(contentsOfFile: wp) }
        root.addSubview(whaleView)

        ruaView = NSImageView(frame: whaleView.frame)
        ruaView.imageScaling = .scaleProportionallyUpOrDown
        ruaView.isHidden = true
        if let rp = resURL("rua", "gif") { ruaView.image = NSImage(contentsOfFile: rp) }
        root.addSubview(ruaView)

        // 时间条
        clockView = panelView(NSColor(srgbRed: 0x11/255.0, green: 0x16/255.0, blue: 0x1F/255.0, alpha: 0xE0/255.0), radius: 9)
        clockField = makeLabel(12, NSColor(srgbRed: 0xC9/255.0, green: 0xD4/255.0, blue: 0xE0/255.0, alpha: 1), mono: true)
        tagField = makeLabel(11, NSColor(srgbRed: 0x8B/255.0, green: 0xE9/255.0, blue: 0xA8/255.0, alpha: 1))
        tagField.alignment = .left
        clockView.addSubview(clockField)
        clockView.addSubview(tagField)
        root.addSubview(clockView)

        panel.contentView = root
        window = panel
        panel.orderFrontRegardless()
    }

    // ---------- 布局（手算坐标，y 自下而上） ----------
    func layoutViews() {
        let hasSay = !sayField.stringValue.isEmpty && !sayField.isHidden
        let hasBal = !balanceField.stringValue.isEmpty
        let balH: CGFloat = hasBal ? 34.0 : 0
        let sayH: CGFloat = hasSay ? 17.0 : 0
        let bubbleH: CGFloat = hasBal ? (8 + balH + (hasSay ? 3 + sayH : 0) + 8) : 0
        let bubbleW: CGFloat = 172.0
        let pad: CGFloat = 11
        let textW: CGFloat = bubbleW - pad * 2

        bubbleView.frame = NSRect(x: winW - 8 - bubbleW, y: winH - bubbleH, width: bubbleW, height: bubbleH)
        bubbleView.isHidden = !hasBal
        // say 在下、余额在上（bubble 内坐标 y 自下而上）
        sayField.frame = NSRect(x: pad, y: 8, width: textW, height: sayH)
        balanceField.frame = NSRect(x: pad, y: 8 + (hasSay ? sayH + 3 : 0), width: textW, height: balH)

        whaleView.frame = NSRect(x: winW - 8 - whaleW, y: winH - bubbleH - 2 - whaleH, width: whaleW, height: whaleH)
        ruaView.frame = whaleView.frame

        let clockW: CGFloat = 132, clockH: CGFloat = 24
        clockView.frame = NSRect(x: (winW - clockW) / 2, y: 8, width: clockW, height: clockH)
        clockField.sizeToFit()
        let cw = min(max(clockField.frame.width, 44), clockW - 48)
        clockField.frame = NSRect(x: 10, y: (clockH - 15) / 2, width: cw, height: 15)
        tagField.sizeToFit()
        tagField.frame = NSRect(x: 10 + cw + 6, y: (clockH - 14) / 2, width: tagField.frame.width + 4, height: 14)
    }

    func restorePosition() {
        var f = window.frame
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var placed = false
        if let sx = state.x, let sy = state.y {
            let px = CGFloat(sx), py = CGFloat(sy)
            if px + 200 > vf.minX + 20 && px < vf.maxX - 20 && py + 60 > vf.minY + 20 && py < vf.maxY - 20 {
                f.origin = NSPoint(x: px, y: py); placed = true
            }
        }
        if !placed { f.origin = NSPoint(x: vf.maxX - winW, y: vf.minY) }
        window.setFrame(f, display: true)
        savePosition()
    }
    func savePosition() {
        let o = window.frame.origin
        state.x = Double(o.x); state.y = Double(o.y)
        saveState(state)
    }

    // ---------- 气泡 ----------
    func updateBubble() {
        let lightText = NSColor(srgbRed: 0xED/255.0, green: 0xEF/255.0, blue: 0xF2/255.0, alpha: 1)
        if let b = state.lastBalance {
            balanceField.stringValue = String(format: "余额 ¥%.2f\n今日 ¥%.2f", b, state.todayUsage)
            balanceField.textColor = b < 5 ? .orange : lightText
        } else if apiKey == nil {
            balanceField.stringValue = "未找到 API Key\n右键设置"
        } else {
            balanceField.stringValue = "余额 —\n今日 —"
        }
        layoutViews()
    }
    func sayLine() {
        sayField.stringValue = petLines.randomElement() ?? ""
        sayField.isHidden = false
        layoutViews()
        sayTimer?.invalidate()
        sayTimer = Timer.scheduledTimer(withTimeInterval: 4.2, repeats: false) { _ in
            self.sayField.isHidden = true
            self.layoutViews()
        }
    }

    // ---------- 时钟：北京时间 + 峰谷 ----------
    func updateClock() {
        let now = Date()
        clockField.stringValue = clockFmt.string(from: now) + " 北京"
        let comp = Calendar(identifier: .gregorian).dateComponents(in: cnTZ, from: now)
        let wd = comp.weekday ?? 1
        let mins = (comp.hour ?? 0) * 60 + (comp.minute ?? 0)
        let isWeekday = wd >= 2 && wd <= 6
        let peak = isWeekday && ((mins >= 540 && mins < 720) || (mins >= 840 && mins < 1080))
        if peak {
            tagField.stringValue = "高峰"
            tagField.textColor = NSColor(srgbRed: 1, green: 0xB8/255.0, blue: 0x6C/255.0, alpha: 1)
        } else {
            tagField.stringValue = "谷价"
            tagField.textColor = NSColor(srgbRed: 0x8B/255.0, green: 0xE9/255.0, blue: 0xA8/255.0, alpha: 1)
        }
        layoutViews()
    }

    // ---------- 音效 ----------
    var sounds: [String: NSSound] = [:]
    func playSnd(_ which: String) {
        guard state.sound != "off", state.volume > 0 else { return }
        let prefix = state.sound == "fx1" ? "D" : "Ya"
        let key = prefix + which
        guard let path = resURL(key, "wav") else { return }
        if sounds[key] == nil { sounds[key] = NSSound(contentsOfFile: path, byReference: true) }
        guard let snd = sounds[key] else { return }
        NSSound.volume = Float(min(1.0, state.volume / 100.0))
        snd.stop(); snd.play()
    }

    // ---------- 摸头 ----------
    func showRua() {
        guard ruaView.image != nil else { return }
        whaleView.isHidden = true
        ruaView.isHidden = false
        ruaTimer?.invalidate()
        ruaTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: false) { _ in
            self.ruaView.isHidden = true
            self.whaleView.isHidden = false
        }
    }

    // ---------- 回弹动画 ----------
    func bounce() {
        guard let layer = whaleView.layer else { return }
        let anim = CABasicAnimation(keyPath: "transform.scale")
        anim.fromValue = 1.22; anim.toValue = 1.0
        anim.duration = 0.54
        anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.4, 0.36, 1.0)
        layer.add(anim, forKey: "bounce")
    }

    func clickEffect() {
        playSnd("1")
        showRua()
        sayLine()
        bounce()
        refreshBalance()
    }

    // ---------- 余额（后台请求，UI 不阻塞） ----------
    func refreshBalance() {
        guard let key = apiKey else {
            if state.lastBalance == nil { updateBubble() }
            return
        }
        var req = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        req.timeoutInterval = 20
        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var bal: Double? = nil
            if let d = data,
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let infos = obj["balance_infos"] as? [[String: Any]],
               let first = infos.first,
               let tb = first["total_balance"] as? String {
                bal = Double(tb)
            }
            DispatchQueue.main.async { self.applyBalance(bal) }
        }.resume()
    }
    func applyBalance(_ bal: Double?) {
        guard let bal = bal else {
            if state.lastBalance == nil {
                balanceField.stringValue = "余额获取失败"
                layoutViews()
            }
            return
        }
        let today = dayFmt.string(from: Date())
        if state.day != today {
            state.day = today
            state.dayStart = bal
            state.todayUsage = 0
        }
        if state.dayStart == nil { state.dayStart = bal }
        if let last = state.lastBalance, bal < last {
            state.todayUsage = ((state.todayUsage * 1e6).rounded() + ((last - bal) * 1e6).rounded()) / 1e6
        }
        state.lastBalance = bal
        saveState(state)
        updateBubble()
    }

    // ---------- 右键菜单 ----------
    func showMenu(at p: NSPoint) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        func addItem(_ title: String, _ action: @escaping () -> Void) {
            let mi = NSMenuItem(title: title, action: #selector(MenuTarget.fire(_:)), keyEquivalent: "")
            mi.target = MenuTarget.shared
            MenuTarget.shared.handlers[ObjectIdentifier(mi)] = action
            menu.addItem(mi)
        }

        addItem("立即刷新", { self.refreshBalance() })
        addItem("显示 / 隐藏气泡", {
            self.state.bubble.toggle()
            if self.state.bubble { self.updateBubble() } else {
                self.bubbleView.isHidden = true
                self.layoutViews()
            }
            self.saveState(self.state)
        })

        let volItem = NSMenuItem(title: "音量", action: nil, keyEquivalent: "")
        let volMenu = NSMenu()
        volMenu.autoenablesItems = false
        for lv in [100.0, 80.0, 60.0, 40.0, 20.0] {
            let mi = volMenu.addItem(withTitle: "\(Int(lv))%", action: #selector(MenuTarget.fire(_:)), keyEquivalent: "")
            mi.target = MenuTarget.shared
            mi.state = state.volume == lv ? .on : .off
            let captured = lv
            MenuTarget.shared.handlers[ObjectIdentifier(mi)] = {
                self.state.volume = captured
                self.saveState(self.state)
                self.playSnd("2")
            }
        }
        menu.setSubmenu(volMenu, for: volItem)
        menu.addItem(volItem)
        menu.addItem(.separator())

        for (title, mode) in [("音效：小黄鸭", "duck"), ("音效：音效1", "fx1"), ("静音", "off")] {
            let mi = menu.addItem(withTitle: title, action: #selector(MenuTarget.fire(_:)), keyEquivalent: "")
            mi.target = MenuTarget.shared
            mi.state = state.sound == mode ? .on : .off
            let captured = mode
            MenuTarget.shared.handlers[ObjectIdentifier(mi)] = {
                self.state.sound = captured
                self.saveState(self.state)
                if captured != "off" { self.playSnd("2") }
            }
        }
        menu.addItem(.separator())

        addItem(state.topmost ? "取消置顶" : "设为置顶", {
            self.state.topmost.toggle()
            self.window.level = self.state.topmost ? .floating : .normal
            self.saveState(self.state)
        })
        addItem("回到右下角", {
            let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            var f = self.window.frame
            f.origin = NSPoint(x: vf.maxX - winW, y: vf.minY)
            self.window.setFrame(f, display: true)
            self.savePosition()
        })
        addItem("设置 API Key", { self.promptApiKey() })
        menu.addItem(.separator())
        addItem("退出挂件", { NSApp.terminate(nil) })

        menu.popUp(positioning: nil, at: p, in: window.contentView)
    }

    func promptApiKey() {
        let alert = NSAlert()
        alert.messageText = "填入 DeepSeek API Key"
        alert.informativeText = "platform.deepseek.com 获取，仅存本机 ~/.whale-pet/key.txt"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "sk-..."
        if let k = apiKey { input.stringValue = k }
        alert.accessoryView = input
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            let v = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty {
                try? fm.createDirectory(atPath: NSHomeDirectory() + "/.whale-pet", withIntermediateDirectories: true)
                try? v.write(toFile: keyTxtPath, atomically: true, encoding: .utf8)
                apiKey = v
                refreshBalance()
            }
        }
    }

    // ---------- 拖拽后边缘吸附 ----------
    func snapAndSave() {
        guard let win = window else { return }
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var f = win.frame
        if abs(f.minX - vf.minX) < 50 { f.origin.x = vf.minX }
        if abs(f.maxX - vf.maxX) < 50 { f.origin.x = vf.maxX - f.width }
        if abs(f.minY - vf.minY) < 50 { f.origin.y = vf.minY }
        if abs(f.maxY - vf.maxY) < 50 { f.origin.y = vf.maxY - f.height }
        win.setFrame(f, display: true)
        savePosition()
    }
}

// ---------- 启动 ----------
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
