import AppKit
import ApplicationServices
import Foundation

// Answering a pop-up by saying its button: "Do you want to terminate running processes in this
// window?" -> "terminate". Any app's alert, sheet or dialog, and system ones (they come to the
// front as their own process). The button words settle most answers; Jev settles the rest
// ("yeah kill it" -> Terminate, "leave it" -> Cancel).

@MainActor
enum Popups {
    struct Button { let title: String; let element: AXUIElement; let isDefault: Bool; let isCancel: Bool }
    struct Popup { let app: NSRunningApplication; let message: String; let buttons: [Button] }

    private static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
        return v as? T
    }

    private static func same(_ a: AXUIElement?, _ b: AXUIElement) -> Bool { a.map { CFEqual($0, b) } ?? false }

    /// The pop-up in front, if there is one: a sheet on the front window, or the front window
    /// itself when it is a dialog or alert.
    static func current() -> Popup? {
        guard let app = FrontTracker.shared.last else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        let wins: [AXUIElement] = attr(ax, kAXWindowsAttribute) ?? []
        let focused: AXUIElement? = attr(ax, kAXFocusedWindowAttribute)
        for w in [focused].compactMap({ $0 }) + wins.prefix(4) {
            let sheets = ((attr(w, kAXChildrenAttribute) as [AXUIElement]?) ?? [])
                .filter { (attr($0, kAXRoleAttribute) as String?) == "AXSheet" }
            let sub: String = attr(w, kAXSubroleAttribute) ?? ""
            let candidates = sheets + (["AXDialog", "AXSystemDialog"].contains(sub) ? [w] : [])
            for box in candidates {
                let def: AXUIElement? = attr(box, kAXDefaultButtonAttribute) ?? attr(w, kAXDefaultButtonAttribute)
                let cancel: AXUIElement? = attr(box, kAXCancelButtonAttribute) ?? attr(w, kAXCancelButtonAttribute)
                var buttons: [Button] = [], texts: [String] = []
                func walk(_ el: AXUIElement, _ depth: Int) {
                    guard depth < 8 else { return }
                    let role: String = attr(el, kAXRoleAttribute) ?? ""
                    if role == "AXButton", (attr(el, kAXSubroleAttribute) as String?) == nil || !["AXCloseButton",
                        "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"].contains(attr(el, kAXSubroleAttribute) ?? "") {
                        let t = [attr(el, kAXTitleAttribute) as String?, attr(el, kAXDescriptionAttribute) as String?]
                            .compactMap { $0 }.first { !$0.isEmpty } ?? ""
                        if !t.isEmpty { buttons.append(Button(title: t, element: el, isDefault: same(def, el), isCancel: same(cancel, el))) }
                    }
                    if role == "AXStaticText", let v: String = attr(el, kAXValueAttribute), !v.isEmpty { texts.append(v) }
                    for k in (attr(el, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(k, depth + 1) }
                }
                walk(box, 0)
                // A dialog with one button or dozens is a window, not a question.
                if (2 ... 6).contains(buttons.count) {
                    return Popup(app: app, message: texts.joined(separator: " "), buttons: buttons)
                }
            }
        }
        return nil
    }

    /// The button the words name, without an engine: the button's own words, or yes/no.
    static func match(_ said: String, _ p: Popup) -> Button? {
        let fill: Set<String> = ["click", "press", "hit", "tap", "choose", "select", "say", "the", "button", "please",
                                 "just", "ok", "okay", "go", "with", "on", "it", "do", "yes"]
        let s = normalise(said)
        let words = s.split(separator: " ").map(String.init)
        // Longest title first: "Don't Save" before "Save".
        for b in p.buttons.sorted(by: { $0.title.count > $1.title.count }) {
            let t = normalise(b.title.replacingOccurrences(of: "\u{2019}", with: "'"))
            if !t.isEmpty, (" " + s + " ").contains(" " + t + " ") { return b }
        }
        let content = words.filter { !fill.contains($0) }
        if content.isEmpty || s.range(of: #"^(yes|yeah|yep|sure|ok|okay|confirm|do it|go ahead|haan)\b"#, options: .regularExpression) != nil {
            if let d = p.buttons.first(where: \.isDefault) { return d }
        }
        if s.range(of: #"^(no|nope|nah|never ?mind|nahi|don t|dont|leave it|stop)\b"#, options: .regularExpression) != nil {
            if let c = p.buttons.first(where: \.isCancel) ?? p.buttons.first(where: { normalise($0.title) == "cancel" }) { return c }
        }
        return nil
    }

    static func press(_ b: Button) -> Bool {
        AXUIElementPerformAction(b.element, kAXPressAction as CFString) == .success
    }
}
