import Cocoa
import SwiftUI
import Translation

@MainActor final class Agent: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let lexicon: Lexicon
    let bubble = Bubble()
    var status: NSStatusItem!, timer: Timer?, setup: NSWindow?, language: NSWindow?, demo: NSWindow?
    var worker: Task<Void,Never>?, revision = 0
    var paused = false, menuOpen = false, didRead = false, wasDown = false, dragged = false
    var anchor = CGPoint(x:-9999,y:-9999), downPoint = CGPoint.zero, stillSince = 0.0, lastRelease = -10.0
    var eventMonitors: [Any] = []
    var previousPID: pid_t = 0
    let queue = DispatchQueue(label:"local.figer.fingertip.reader",qos:.userInitiated)
    var translations: [String:String] = [:]
    init(_ lexicon: Lexicon) { self.lexicon = lexicon }
    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName:"character.bubble",accessibilityDescription:"指尖译"); status.button?.toolTip = "指尖译"
        let menu = NSMenu(); menu.delegate = self; status.menu = menu
        add(menu,"暂停取词",#selector(toggle)); add(menu,"使用说明与权限…",#selector(showSetup)); add(menu,"准备整句翻译…",#selector(showLanguage)); add(menu,"识别图片里的英文",#selector(toggleOCR)); add(menu,"试用取词…",#selector(showDemo)); menu.addItem(.separator()); add(menu,"退出指尖译",#selector(quit))
        let t = Timer(timeInterval:0.075,repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }; timer = t; RunLoop.main.add(t,forMode:.common)
        // Capture short drags that can start and finish between two hover timer ticks.
        let events: NSEvent.EventTypeMask = [.leftMouseDown,.leftMouseDragged,.leftMouseUp,.scrollWheel]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching:events,handler:{ [weak self] event in self?.mouseEvent(event) }) { eventMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching:events,handler:{ [weak self] event in self?.mouseEvent(event); return event }) { eventMonitors.append(monitor) }
        if !AXIsProcessTrusted() { showSetup() }
    }
    func add(_ menu:NSMenu,_ name:String,_ selector:Selector) { let item = menu.addItem(withTitle:name,action:selector,keyEquivalent:""); item.target = self }
    func menuWillOpen(_ menu:NSMenu) { menuOpen = true; reset(); menu.items[0].title = paused ? "恢复取词" : "暂停取词"; menu.items[3].state = UserDefaults.standard.bool(forKey:"imageOCR") ? .on : .off }
    func menuDidClose(_ menu:NSMenu) { menuOpen = false }
    @objc func toggle() { paused.toggle(); reset() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func toggleOCR() {
        let enabled = !UserDefaults.standard.bool(forKey:"imageOCR"); UserDefaults.standard.set(enabled,forKey:"imageOCR")
        if enabled && !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }; reset()
    }
    func window(_ name:String,_ controller:NSViewController) -> NSWindow {
        let w = NSWindow(contentViewController:controller); w.styleMask = [.titled,.closable]; w.title = name; w.isReleasedWhenClosed = false; w.center(); return w
    }
    func open(_ w:NSWindow?) { NSApp.activate(ignoringOtherApps:true); w?.makeKeyAndOrderFront(nil) }
    @objc func showSetup() {
        let v = VStack(alignment:.leading,spacing:16) {
            Text("指尖译").font(.title.bold())
            Text("鼠标停在英文单词或表情上约半秒，即可查看中文。停在菜单选项上，可一起翻译标题和说明。划选英文，松开鼠标即可翻译。")
            Text(AXIsProcessTrusted() ? "辅助功能已开启。" : "首次使用，请在“隐私与安全性 → 辅助功能”中打开“指尖译”。如果列表中没有它，点击 ＋ 添加。")
            HStack { Button("打开辅助功能设置") { self.permissions() }; Button("准备整句翻译…") { self.showLanguage() } }
            Button("试一试 apple 和 🍊") { self.showDemo() }
        }.padding(24).frame(width:430,alignment:.leading).fixedSize(horizontal:false,vertical:true)
        let controller = NSHostingController(rootView:v); if let setup { setup.contentViewController = controller } else { setup = window("指尖译 · 使用说明",controller) }; open(setup)
    }
    @objc func permissions() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt:true] as CFDictionary)
        if let url = URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    @objc func showLanguage() { if language == nil { language = window("指尖译 · 语言包",NSHostingController(rootView:LanguageSetup())) }; open(language) }
    @objc func showDemo() {
        if demo == nil {
            let text = NSTextView(frame:NSRect(x:0,y:0,width:460,height:205)); text.string = "鼠标停在单词或表情上\napple     bank     🍊     🎉\n\n用鼠标划选下面这句英文\nI like oranges."; text.isEditable = false; text.isSelectable = true; text.font = .systemFont(ofSize:20); text.textContainerInset = .init(width:20,height:16)
            let controller = NSViewController(); controller.view = text; demo = window("指尖译 · 试用取词",controller)
        }; open(demo)
    }
    func reset() { revision &+= 1; worker?.cancel(); didRead = false; stillSince = ProcessInfo.processInfo.systemUptime; bubble.hide() }
    func mouseEvent(_ event:NSEvent) {
        guard !paused, !menuOpen else { return }
        let p = NSEvent.mouseLocation
        switch event.type {
        case .scrollWheel: reset()
        case .leftMouseDown: downPoint = p; dragged = false; wasDown = true; reset()
        case .leftMouseDragged: if hypot(p.x-downPoint.x,p.y-downPoint.y)>3 { dragged = true }
        case .leftMouseUp:
            let wantsSelection = dragged || event.clickCount >= 2
            wasDown = false; dragged = false; anchor = p
            if wantsSelection { reset(); request(p,selection:true) }
        default: break
        }
    }
    func tick() {
        guard !paused, !menuOpen else { return }
        let now = ProcessInfo.processInfo.systemUptime, p = NSEvent.mouseLocation
        let down = NSEvent.pressedMouseButtons & 1 != 0, pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        if pid != previousPID { previousPID = pid; reset() }
        if hypot(anchor.x-p.x,anchor.y-p.y)>3 { anchor = p; reset() }
        if down { if !wasDown { downPoint = p; dragged = false; reset() }; dragged = dragged || hypot(p.x-downPoint.x,p.y-downPoint.y)>3; wasDown = true; return }
        if wasDown {
            wasDown = false; let selection = dragged || now-lastRelease < NSEvent.doubleClickInterval; lastRelease = now
            if selection { request(p, selection:true); return }
        }
        if !didRead && now-stillSince >= 0.5 { request(p,selection:false) }
    }
    func request(_ p:CGPoint,selection:Bool) {
        guard let screen = NSScreen.screens.first(where:{$0.frame.contains(p)}),let main = NSScreen.screens.first else { return }
        didRead = true; let generation = revision, point = CGPoint(x:p.x,y:main.frame.maxY-p.y)
        let bounds = CGRect(x:screen.frame.minX,y:main.frame.maxY-screen.frame.maxY,width:screen.frame.width,height:screen.frame.height)
        let useImage = UserDefaults.standard.bool(forKey:"imageOCR") && CGPreflightScreenCaptureAccess()
        guard AXIsProcessTrusted() || useImage else { didRead = false; stillSince = ProcessInfo.processInfo.systemUptime; return }
        worker = Task {
            // Give the foreground app its mouse-up event before asking for selected text.
            if selection { try? await Task.sleep(nanoseconds:90_000_000) }
            guard !Task.isCancelled else { return }
            let result: ReadResult = AXIsProcessTrusted() ? await withCheckedContinuation { cont in queue.async { [lexicon] in cont.resume(returning: readAt(point,selection:selection,lexicon:lexicon)) } } : .empty
            guard revision == generation, !Task.isCancelled else { return }
            var text: String?
            switch result { case .text(let value): text = value; case .protected: return; case .empty: if !selection && useImage { text = await imageWord(at:point,displayBounds:bounds) } }
            guard revision == generation, !Task.isCancelled else { return }
            guard let text = text?.trimmingCharacters(in:.whitespacesAndNewlines), !text.isEmpty else { if selection { didRead = false }; return }
            guard text.utf16.count <= 4000 else { bubble.show("划词翻译","请分段划选，每次最多 4000 个字符。",at:p); return }
            if let meaning = knownMenuTranslation(text) ?? lexicon.meaning(text) { bubble.show(text,meaning,at:p); return }
            guard text.range(of:"[A-Za-z]",options:.regularExpression) != nil else { return }
            if let cached = translations[text] { bubble.show(text,cached,at:p); return }
            let availability = await LanguageAvailability().status(from:english,to:chinese)
            guard revision == generation, !Task.isCancelled else { return }
            guard availability == .installed else { bubble.show(text,"请在指尖译菜单中点“准备整句翻译…”，下载英译中语言包。",at:p); return }
            do {
                let session = TranslationSession(installedSource:english,target:chinese); let response = try await session.translate(text)
                guard revision == generation, !Task.isCancelled else { return }
                if translations.count >= 100 { translations.removeAll() }; translations[text] = response.targetText; bubble.show(text,response.targetText,at:p)
            } catch { if revision == generation && !Task.isCancelled { bubble.show(text,"翻译暂时不可用，可从菜单检查语言包。",at:p) } }
        }
    }
}
