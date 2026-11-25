import Cocoa
import SwiftUI
import Translation

final class LanguageState: ObservableObject {
    @Published var config: TranslationSession.Configuration?
    @Published var status = "整句翻译使用 Apple 的英语与简体中文语言包。"
}
struct LanguageSetup: View {
    @ObservedObject var model = LanguageState()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("整句翻译").font(.title2.bold()); Text(model.status).fixedSize(horizontal: false, vertical: true)
            Button("准备英译中语言包") { model.config = .init(source: english, target: chinese) }
        }.padding(24).frame(width: 390, alignment: .leading).translationTask(model.config) { session in
            do { try await session.prepareTranslation(); model.status = "语言包已就绪，可以划选英文句子。" }
            catch { model.status = "语言包尚未就绪。请检查网络，再点一次准备。" }; model.config = nil
        }
    }
}

@MainActor final class Bubble {
    private let panel = NSPanel(contentRect:.zero, styleMask:[.borderless,.nonactivatingPanel], backing:.buffered, defer:false)
    init() {
        panel.isFloatingPanel = true; panel.level = .popUpMenu; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]; panel.isOpaque = false
        panel.backgroundColor = .clear; panel.hasShadow = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
    }
    func hide() { panel.orderOut(nil) }
    func show(_ source: String, _ meaning: String, at p: CGPoint) {
        guard let screen = NSScreen.screens.first(where:{ $0.frame.contains(p) }) else { return }
        let view = NSVisualEffectView(); view.material = .popover; view.state = .active; view.wantsLayer = true; view.layer?.cornerRadius = 10
        let frame = screen.visibleFrame
        let sourceFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        let meaningFont = NSFont.systemFont(ofSize: 16)
        func longestLine(_ text: String, font: NSFont) -> CGFloat {
            text.components(separatedBy: .newlines).map {
                ($0 as NSString).size(withAttributes: [.font: font]).width
            }.max() ?? 0
        }
        let width = min(max(90, ceil(max(longestLine(source, font: sourceFont),
                                         longestLine(meaning, font: meaningFont))) + 3),
                        440, frame.width - 40)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.paragraphSpacing = 2
        let content = NSMutableAttributedString(string: source + "\n", attributes: [
            .font: sourceFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph
        ])
        content.append(NSAttributedString(string: meaning, attributes: [
            .font: meaningFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ]))
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        text.isEditable = false
        text.isSelectable = false
        text.drawsBackground = false
        text.textContainerInset = .zero
        guard let container = text.textContainer, let layout = text.layoutManager else { return }
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        text.textStorage?.setAttributedString(content)
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height) + 2
        let size = NSSize(width: width + 26, height: min(height + 19, frame.height - 8))
        text.frame = NSRect(x: 13, y: size.height - 9 - height, width: width, height: height)
        view.addSubview(text)
        let x = max(frame.minX+4,min(p.x+14,frame.maxX-size.width-4)); let below = p.y-size.height-12
        let y = below >= frame.minY+4 ? below : min(p.y+20,frame.maxY-size.height-4)
        panel.contentView = view; panel.setFrame(NSRect(origin:.init(x:x,y:y),size:size),display:true); panel.orderFrontRegardless()
    }
}
