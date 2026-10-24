import AVFoundation
import AppKit
import Carbon
import Combine
import ServiceManagement
import Speech
import SwiftUI

// MARK: - Notch

/// Where the notch is. Screens without one get a pill of the same height as the menu bar.
struct NotchGeometry {
    let screen: NSScreen
    let width: CGFloat
    let height: CGFloat
    let real: Bool

    static func current() -> NotchGeometry {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        if screen.safeAreaInsets.top > 0,
           let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            return NotchGeometry(screen: screen, width: screen.frame.width - l.width - r.width,
                                 height: screen.safeAreaInsets.top, real: true)
        }
        return NotchGeometry(screen: screen, width: 150, height: NSStatusBar.system.thickness, real: false)
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// A black island grown out of the notch. It sits above everything, including full-screen
/// apps, and lets clicks fall through except where it is actually drawn.
@MainActor
final class NotchController {
    private let panel: NotchPanel
    private let brain: Brain
    private var geo = NotchGeometry.current()
    private var timer: Timer?
    private let canvas = CGSize(width: 560, height: 300)

    init(brain: Brain, openSettings: @escaping () -> Void) {
        self.brain = brain
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: NotchView(brain: brain, geo: geo, openSettings: openSettings))
        place()
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.geo = NotchGeometry.current()
                self.panel.contentView = NSHostingView(rootView: NotchView(brain: brain, geo: self.geo,
                                                                            openSettings: openSettings))
                self.place()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func place() {
        let f = geo.screen.frame
        panel.setFrame(NSRect(x: f.midX - canvas.width / 2, y: f.maxY - canvas.height,
                              width: canvas.width, height: canvas.height), display: true)
    }

    /// Picks the state from what just happened, and makes the island clickable only under the cursor.
    private func tick() {
        let t = AXIsProcessTrusted()
        if t != brain.trusted { brain.trusted = t }
        let now = Date()
        let size = NotchView.size(for: brain.notch, geo: geo, rows: brain.history.count)
        let f = geo.screen.frame
        let drawn = NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height)
        let hovering = drawn.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)

        let next: NotchState
        if (brain.typing || brain.wisprOn) && !(hovering && brain.notch == .expanded) {
            next = .typing
        } else if hovering && (brain.notch == .expanded || brain.notch == .idle) {
            next = .expanded
        } else if now.timeIntervalSince(brain.lastOpenedAt) < 3 {
            next = .opened
        } else if !brain.heard.isEmpty && now.timeIntervalSince(brain.lastSpokeAt) < 2 {
            next = .talking
        } else if hovering && brain.notch != .expanded {
            next = brain.notch               // hovering the transcript does not yank it open
        } else {
            next = .idle
        }
        if next != brain.notch { brain.notch = next }
        panel.ignoresMouseEvents = !(hovering && next == .expanded)
    }
}

struct NotchShape: Shape {
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let ear: CGFloat = 6                 // the little outward flare where it meets the bezel
        p.move(to: CGPoint(x: r.minX - ear, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + ear), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: r.minX + radius, y: r.maxY), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - radius), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + ear))
        p.addQuadCurve(to: CGPoint(x: r.maxX + ear, y: r.minY), control: CGPoint(x: r.maxX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct Bars: View {
    var level: Float
    var on: Bool
    private let shape: [CGFloat] = [0.45, 0.8, 1.0, 0.7, 0.4]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0 ..< shape.count, id: \.self) { i in
                Capsule()
                    .fill(on ? Color(red: 0.55, green: 0.95, blue: 0.7) : Color.white.opacity(0.35))
                    .frame(width: 3, height: on ? max(3, 16 * shape[i] * CGFloat(0.15 + level)) : 3)
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

struct AppIcon: View {
    let path: String
    var size: CGFloat = 18
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable().frame(width: size, height: size)
    }
}

struct NotchView: View {
    @ObservedObject var brain: Brain
    let geo: NotchGeometry
    let openSettings: () -> Void

    static func size(for state: NotchState, geo: NotchGeometry, rows: Int) -> CGSize {
        let idleWidth = geo.width + 76
        switch state {
        case .idle: return CGSize(width: idleWidth, height: geo.height)
        case .talking: return CGSize(width: max(idleWidth, 460), height: geo.height + 96)
        case .typing: return CGSize(width: max(idleWidth, 460), height: geo.height + 72)
        case .opened: return CGSize(width: max(idleWidth, 400), height: geo.height + 58)
        case .expanded:
            let shown = min(max(rows, 1), 5)
            return CGSize(width: max(idleWidth, 460), height: geo.height + 44 + CGFloat(shown) * 30 + 48)
        }
    }

    var body: some View {
        let size = Self.size(for: brain.notch, geo: geo, rows: brain.history.count)
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(radius: brain.notch == .idle ? 9 : 20).fill(Color.black)
                VStack(spacing: 0) {
                    topRow.frame(height: geo.height)
                    below.padding(.horizontal, 18).transition(.opacity)
                    Spacer(minLength: 0)
                }
                .frame(width: size.width)
                .clipped()
            }
            .frame(width: size.width, height: size.height)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: brain.notch)
        .preferredColorScheme(.dark)
    }

    // The strip beside the camera: live mic bars left, last app or status dot right.
    private var topRow: some View {
        HStack(spacing: 0) {
            Bars(level: brain.level, on: brain.listening && (brain.awake || !brain.needsWake || brain.typing))
                .padding(.leading, 14)
            Spacer(minLength: geo.real ? geo.width : 8)
            Group {
                if let last = brain.history.first, brain.notch == .opened {
                    AppIcon(path: last.path, size: 16)
                } else {
                    Circle().fill(dotColor).frame(width: 7, height: 7)
                }
            }
            .frame(width: 20).padding(.trailing, 14)
        }
    }

    private func verdict(_ who: String, _ says: String, acting: Bool) -> some View {
        HStack(spacing: 8) {
            Text(who).font(.system(size: 9, weight: .bold)).tracking(0.8)
                .foregroundStyle(acting ? Color.black : .white.opacity(0.6))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(acting ? Color(red: 0.55, green: 0.95, blue: 0.7) : .white.opacity(0.12)))
                .frame(width: 58, alignment: .leading)
            Text(says.isEmpty ? "\u{2026}" : says).font(.system(size: 12, weight: acting ? .semibold : .regular))
                .foregroundStyle(.white.opacity(acting ? 0.95 : 0.55)).lineLimit(1)
            Spacer()
        }
    }

    private var dotColor: Color {
        if !brain.problem.isEmpty || !brain.hasKey || !brain.trusted { return .orange }
        if brain.needsWake && !brain.awake { return .gray }
        return brain.listening ? Color(red: 0.55, green: 0.95, blue: 0.7) : .gray
    }

    @ViewBuilder private var below: some View {
        switch brain.notch {
        case .idle:
            EmptyView()
        case .talking:
            VStack(spacing: 6) {
                Text(brain.heard)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1).truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .center)
                verdict("JEV", brain.jevSays, acting: brain.engine == .jev)
                verdict("RULES", brain.rulesSays, acting: brain.engine == .rules)
            }
            .padding(.top, 8)
        case .typing:
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "keyboard").foregroundStyle(Color(red: 0.55, green: 0.95, blue: 0.7))
                    Text(brain.typing ? "Typing with Wispr Flow" : "Wispr is listening")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text("say \u{201C}close Wispr Flow\u{201D} to finish")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
                Text(brain.typing ? (brain.heard.isEmpty ? "speak now\u{2026}" : brain.heard)
                                  : "SayOpen ignores dictation until Wispr stops")
                    .font(.system(size: 13, design: .rounded)).foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1).truncationMode(.head)
            }
            .padding(.top, 8)
        case .opened:
            if let o = brain.history.first {
                HStack(spacing: 12) {
                    AppIcon(path: o.path, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(o.app).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        Text("\(clock.string(from: o.at))  ·  \(took(o.ms))  ·  \(o.how)")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                }
                .padding(.top, 10)
            }
        case .expanded:
            VStack(spacing: 0) {
                if brain.needsWake && brain.listening {
                    Text(brain.awake ? "Listening: say a command, or \u{201C}stop Mac\u{201D}"
                                     : "Asleep: say \u{201C}OK Jev\u{201D} or \u{201C}Hey Mac\u{201D}, or press \u{2303}\u{2325}Space")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .leading).frame(height: 22)
                }
                if brain.history.isEmpty {
                    Text(brain.hasKey ? "Say \u{201C}open \u{2026}\u{201D}. What it did shows up here with the time."
                                      : "Add your TypeSafe key in Settings to start.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                        .frame(height: 30)
                }
                ForEach(brain.history.prefix(5)) { o in
                    HStack(spacing: 10) {
                        AppIcon(path: o.path, size: 18)
                        Text(o.app).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                        Spacer()
                        Text(o.how).font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                        Text(took(o.ms))
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.45))
                        Text(dayClock.string(from: o.at))
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                            .frame(width: 128, alignment: .trailing)
                    }
                    .frame(height: 30)
                }
                if !brain.trusted {
                    Button {
                        brain.askAccessibility()
                    } label: {
                        Text("Tabs, keys and voice typing need Accessibility: click, then switch SayOpen on")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain).frame(height: 26)
                }
                HStack(spacing: 14) {
                    Button(brain.listening ? "Pause" : "Listen") { brain.toggle() }
                    Button("Log") { brain.showLog() }
                    Spacer()
                    Button(brain.engine == .jev ? "Acting: Jev" : "Acting: Rules") {
                        brain.engine = brain.engine == .jev ? .rules : .jev
                    }
                    Button { openSettings() } label: { Image(systemName: "gearshape") }
                }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
                .padding(.top, 8)
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Settings window

struct Panel: View {
    @ObservedObject var brain: Brain
    @State private var keyField = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SayOpen").font(.headline)
                Spacer()
                if brain.hasKey {
                    Toggle("", isOn: Binding(get: { brain.listening }, set: { $0 ? brain.start() : brain.stop() }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }

            if !brain.hasKey {
                Text("Paste your TypeSafe API key. It is saved privately on this Mac and only sent to api.typesafe.ai.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                SecureField("sk-...", text: $keyField).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save") { brain.saveKey(keyField); keyField = "" }
                        .keyboardShortcut(.defaultAction).disabled(keyField.isEmpty)
                    Spacer()
                    Link("Get a key", destination: URL(string: "https://console.typesafe.ai/")!).font(.caption)
                }
            } else {
                Text(brain.listening ? "Listening. Try \u{201C}open Terminal and add a new tab\u{201D}."
                                     : "Paused. Control+Option+Space or the switch turns it back on.")
                    .font(.callout)
            }

            Picker("Who acts", selection: Binding(get: { brain.engine }, set: { brain.engine = $0 })) {
                Text("Jev").tag(EngineKind.jev)
                Text("Rules (no Jev)").tag(EngineKind.rules)
            }
            .pickerStyle(.segmented)
            Toggle("Wake phrase: ignore everything until \u{201C}OK Jev\u{201D} or \u{201C}Hey Mac\u{201D}", isOn: Binding(get: { brain.needsWake },
                                                                                        set: { brain.needsWake = $0 }))
                .font(.caption)
            Text("Both judge everything you say and the notch shows both verdicts. Only the one picked here acts.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if !brain.trusted {
                HStack {
                    Text("Tabs, keys and Wispr need Accessibility.").font(.caption)
                    Spacer()
                    Button("Allow") { brain.askAccessibility() }.font(.caption)
                }
            }

            Text("SayOpen lives in your notch. Hover it to see what opened and when. You can close this "
                + "window: it keeps listening. Open SayOpen again to bring it back.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if !brain.problem.isEmpty {
                Text(brain.problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Text("\(brain.appCount) apps  ·  \(brain.calls) Jev calls").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Rescan") { brain.rescan() }.buttonStyle(.link).font(.caption)
                Button("Open log") { brain.showLog() }.buttonStyle(.link).font(.caption)
            }
            Toggle("Start at login", isOn: Binding(get: { brain.launchAtLogin }, set: { brain.setLaunchAtLogin($0) }))
                .font(.caption)
            HStack {
                if brain.hasKey { Button("Change key") { brain.forgetKey() }.buttonStyle(.link).font(.caption) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.font(.caption)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

