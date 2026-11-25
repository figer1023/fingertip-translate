import Cocoa
import ApplicationServices
import ScreenCaptureKit
import Vision

private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
}
private func parameter(_ element: AXUIElement, _ key: String, _ arg: CFTypeRef) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyParameterizedAttributeValue(element, key as CFString, arg, &result) == .success ? result : nil
}
private func element(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }; return (value as! AXUIElement)
}
private func range(_ value: CFTypeRef?) -> CFRange? {
    var r = CFRange(); guard let value, CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cfRange, &r) else { return nil }; return r
}
private func frame(_ value: CFTypeRef?) -> CGRect? {
    var rect = CGRect.zero; guard let value, CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }; return rect
}
private func secure(_ el: AXUIElement) -> Bool { attribute(el, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole }
private func textAt(_ el: AXUIElement, _ point: CGPoint, _ lexicon: Lexicon) -> String? {
    var point = point
    guard let arg = AXValueCreate(.cgPoint, &point), var hit = range(parameter(el, kAXRangeForPositionParameterizedAttribute, arg)), hit.location >= 0 else { return nil }
    if hit.length == 0 { hit.length = 1 }
    if let h = AXValueCreate(.cfRange, &hit), let bounds = frame(parameter(el, kAXBoundsForRangeParameterizedAttribute, h)), !bounds.isEmpty, !bounds.insetBy(dx: -2, dy: -2).contains(point) { return nil }
    let start = max(0, hit.location - 96)
    if let count = attribute(el, kAXNumberOfCharactersAttribute) as? Int, hit.location < count {
        var context = CFRange(location: start, length: min(count-start, hit.location-start+100))
        if let c = AXValueCreate(.cfRange, &context), let text = parameter(el, kAXStringForRangeParameterizedAttribute, c) as? String { return lexicon.token(text, at: hit.location-start) }
    }
    if let text = attribute(el, kAXValueAttribute) as? String {
        let value = text as NSString
        if hit.location < value.length { let span = NSRange(location: start, length: min(value.length-start,hit.location-start+100)); return lexicon.token(value.substring(with: span), at:hit.location-start) }
    }
    return nil
}

// Some web views expose geometry for text ranges but return an empty range for a point.
// Search the element's actual glyph bounds, including when the text wraps across lines.
private func webLabelToken(_ label: String, element: AXUIElement, point: CGPoint, lexicon: Lexicon) -> String? {
    let value = label as NSString
    guard value.length > 0, value.length <= 65_536 else { return nil }
    var pending = [NSRange(location: 0, length: value.length)]
    var probes = 0
    while let span = pending.popLast(), probes < 100 {
        probes += 1
        var range = CFRange(location: span.location, length: span.length)
        guard let arg = AXValueCreate(.cfRange, &range),
              let bounds = frame(parameter(element, kAXBoundsForRangeParameterizedAttribute, arg)),
              !bounds.isEmpty, bounds.contains(point) else { continue }
        let first = value.rangeOfComposedCharacterSequence(at: span.location)
        if first == span {
            return lexicon.token(label, at: span.location)
        }
        let middle = value.rangeOfComposedCharacterSequence(at: span.location + span.length / 2).location
        let split = middle > span.location ? middle : NSMaxRange(first)
        pending.append(NSRange(location: split, length: NSMaxRange(span) - split))
        pending.append(NSRange(location: span.location, length: split - span.location))
    }
    return nil
}

// Electron can expose an option as static text directly under an AXList. Its
// bounds cover the whole row, even when a nested label or the list wins the hit test.
private func rowBounds(_ item: AXUIElement) -> CGRect? {
    var origin = CGPoint.zero, size = CGSize.zero
    guard let p = attribute(item, kAXPositionAttribute), let s = attribute(item, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID(),
          AXValueGetValue(p as! AXValue, .cgPoint, &origin),
          AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: origin, size: size)
}

private func rowLabel(_ item: AXUIElement) -> String? {
    func label(_ node: AXUIElement) -> String? {
        for key in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            guard let raw = attribute(node, key) as? String else { continue }
            let clean = String(raw.unicodeScalars.filter { $0.properties.generalCategory != .privateUse })
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { return clean }
        }
        return nil
    }
    var parts = [String]()
    var remaining = 36
    func collect(_ node: AXUIElement, depth: Int) {
        guard remaining > 0, depth <= 5, !secure(node) else { return }
        remaining -= 1
        let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
        let count = parts.count
        for child in children.prefix(remaining) { collect(child, depth: depth + 1) }
        if parts.count == count, let text = label(node), !parts.contains(text) { parts.append(text) }
    }
    collect(item, depth: 0)
    let joined = parts.joined(separator: "\n")
    // Some renderers expose the description only on the option itself.
    let own = label(item) ?? ""
    let useOwn = !joined.isEmpty && own.count > joined.count && parts.allSatisfy { own.contains($0) }
    let result = useOwn ? own : joined
    guard result.utf16.count <= 4000, result.range(of: "[A-Za-z]", options: .regularExpression) != nil else { return nil }
    return result
}

private func menuRegion(at point: CGPoint, startingAt target: AXUIElement) -> ReadResult {
    var node: AXUIElement? = target
    for _ in 0..<10 {
        guard let item = node else { break }
        if secure(item) { return .protected }
        let role = attribute(item, kAXRoleAttribute) as? String
        if [kAXTextFieldRole, kAXTextAreaRole, kAXWindowRole, "AXWebArea", kAXApplicationRole].contains(role ?? "") { break }
        let parent = element(attribute(item, kAXParentAttribute))
        let containerRole = parent.flatMap { attribute($0, kAXRoleAttribute) as? String }
        if role == kAXMenuItemRole || (containerRole == kAXListRole && [kAXStaticTextRole, kAXRowRole, kAXGroupRole, kAXRadioButtonRole, "AXCell"].contains(role ?? "")) {
            if rowBounds(item)?.contains(point) == true, let text = rowLabel(item) { return .text(text) }
        }
        if role == kAXListRole || role == kAXMenuRole {
            let rows = attribute(item, kAXChildrenAttribute) as? [AXUIElement] ?? []
            for row in rows.prefix(128) where rowBounds(row)?.contains(point) == true {
                if secure(row) { return .protected }
                if let text = rowLabel(row) { return .text(text) }
            }
            break
        }
        node = parent
    }
    return .empty
}

enum ReadResult { case text(String), empty, protected }
func readAt(_ point: CGPoint, selection: Bool, lexicon: Lexicon) -> ReadResult {
    let system = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(system, 0.18)
    var target: AXUIElement?
    AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &target)
    if !selection, let target {
        let region = menuRegion(at: point, startingAt: target)
        switch region {
        case .protected, .text: return region
        case .empty: break
        }
        // A web popover may sit above the element returned by the system hit test.
        // The same app's focused option still exposes the live list and its row bounds.
        var pid: pid_t = 0
        if AXUIElementGetPid(target, &pid) == .success,
           let focused = element(attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute)),
           !CFEqual(focused, target) {
            let focusedRegion = menuRegion(at: point, startingAt: focused)
            if case .text = focusedRegion { return focusedRegion }
        }
    }
    let focused = selection ? element(attribute(system, kAXFocusedUIElementAttribute)) : nil
    for initial in [target, focused].compactMap({ $0 }) {
        var current: AXUIElement? = initial
        for _ in 0..<5 {
            guard let el = current else { break }; AXUIElementSetMessagingTimeout(el, 0.18)
            if secure(el) { return .protected }
            if selection {
                if let text = attribute(el, kAXSelectedTextAttribute) as? String, !text.isEmpty { return .text(text) }
            } else {
                if let text = textAt(el, point, lexicon) { return .text(text) }
                // A label without range geometry is safe only when it names exactly one token.
                if attribute(el,kAXRoleAttribute) as? String == kAXStaticTextRole,
                   let label = attribute(el,kAXValueAttribute) as? String {
                    if label.utf16.count < 100, lexicon.token(label,at:0) == label { return .text(label) }
                    if let token = webLabelToken(label, element: el, point: point, lexicon: lexicon) { return .text(token) }
                }
            }
            current = element(attribute(el,kAXParentAttribute))
        }
    }
    return .empty
}

func imageWord(at point: CGPoint, displayBounds: CGRect) async -> String? {
    let rect = CGRect(x: point.x-220,y: point.y-55,width:440,height:110).intersection(displayBounds)
    guard !rect.isEmpty, let image = try? await SCScreenshotManager.captureImage(in: rect) else { return nil }
    let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]; request.usesLanguageCorrection = false
    guard (try? VNImageRequestHandler(cgImage:image).perform([request])) != nil else { return nil }
    let target = CGPoint(x:(point.x-rect.minX)/rect.width, y:1-(point.y-rect.minY)/rect.height)
    for observation in request.results ?? [] where observation.boundingBox.insetBy(dx: -0.003,dy:-0.015).contains(target) {
        guard let line = observation.topCandidates(1).first else { continue }
        let text = line.string
        for match in wordRegex.matches(in:text,range:NSRange(text.startIndex...,in:text)) {
            guard let part = Range(match.range,in:text), let box = try? line.boundingBox(for:part) else { continue }
            if box.boundingBox.insetBy(dx:-0.002,dy:-0.01).contains(target) { return String(text[part]) }
        }
    }
    return nil
}
