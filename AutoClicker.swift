import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - Settings

enum MouseButtonChoice: String, CaseIterable, Identifiable {
    case left = "Left", right = "Right", middle = "Middle"
    var id: String { rawValue }
}

enum ClickKind: String, CaseIterable, Identifiable {
    case single = "Single", double = "Double"
    var id: String { rawValue }
}

enum StopMode: String, CaseIterable, Identifiable {
    case never = "Until stopped", afterClicks = "After N clicks", afterSeconds = "After N seconds"
    var id: String { rawValue }
}

struct ClickConfig {
    var intervalMs: Double
    var jitterMs: Double
    var burstCount: Int
    var burstGapMs: Double
    var button: MouseButtonChoice
    var kind: ClickKind
    var stopMode: StopMode
    var stopValue: Int
    var useFixedPoint: Bool
    var fixedPoint: CGPoint
}

// MARK: - Click engine

final class ClickEngine {
    private let lock = NSLock()
    private var _running = false
    var running: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _running }
        set { lock.lock(); _running = newValue; lock.unlock() }
    }

    /// Runs on a background thread. `onClick` reports total clicks; `onFinish` fires when the loop exits.
    func start(_ cfg: ClickConfig, startDelay: Double,
               onClick: @escaping (Int) -> Void, onFinish: @escaping () -> Void) {
        guard !running else { return }
        running = true
        Thread.detachNewThread { [self] in
            if startDelay > 0 { sleepInterruptible(startDelay) }
            let began = Date()
            var total = 0
            outer: while running {
                for i in 0..<max(1, cfg.burstCount) {
                    guard running else { break outer }
                    click(cfg)
                    total += 1
                    onClick(total)
                    if cfg.stopMode == .afterClicks && total >= cfg.stopValue { break outer }
                    if i < cfg.burstCount - 1 { sleepInterruptible(cfg.burstGapMs / 1000) }
                }
                if cfg.stopMode == .afterSeconds && Date().timeIntervalSince(began) >= Double(cfg.stopValue) { break }
                let jitter = cfg.jitterMs > 0 ? Double.random(in: -cfg.jitterMs...cfg.jitterMs) : 0
                sleepInterruptible(max(1, cfg.intervalMs + jitter) / 1000)
                if cfg.stopMode == .afterSeconds && Date().timeIntervalSince(began) >= Double(cfg.stopValue) { break }
            }
            running = false
            onFinish()
        }
    }

    func stop() { running = false }

    /// Sleeps in small slices so Stop feels instant even with long intervals.
    private func sleepInterruptible(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while running {
            let left = end.timeIntervalSinceNow
            if left <= 0 { return }
            Thread.sleep(forTimeInterval: min(left, 0.02))
        }
    }

    private func click(_ cfg: ClickConfig) {
        let pos: CGPoint
        if cfg.useFixedPoint {
            pos = cfg.fixedPoint
            CGWarpMouseCursorPosition(pos)
        } else {
            pos = CGEvent(source: nil)?.location ?? .zero
        }

        let (down, up, btn): (CGEventType, CGEventType, CGMouseButton) = {
            switch cfg.button {
            case .left: return (.leftMouseDown, .leftMouseUp, .left)
            case .right: return (.rightMouseDown, .rightMouseUp, .right)
            case .middle: return (.otherMouseDown, .otherMouseUp, .center)
            }
        }()

        let src = CGEventSource(stateID: .hidSystemState)
        let presses = cfg.kind == .double ? 2 : 1
        for n in 1...presses {
            for type in [down, up] {
                guard let ev = CGEvent(mouseEventSource: src, mouseType: type,
                                       mouseCursorPosition: pos, mouseButton: btn) else { continue }
                ev.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                ev.post(tap: .cghidEventTap)
            }
        }
    }
}

// MARK: - Global hotkey (F6), no Accessibility needed for this part

final class HotKey {
    private var ref: EventHotKeyRef?
    private static var handler: (() -> Void)?

    init(keyCode: Int, handler: @escaping () -> Void) {
        HotKey.handler = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.handler?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x41434C4B), id: 1) // 'ACLK'
        RegisterEventHotKey(UInt32(keyCode), 0, id, GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: - View model

final class ClickerModel: ObservableObject {
    @AppStorage("intervalMs") var intervalMs: Double = 100
    @AppStorage("jitterMs") var jitterMs: Double = 0
    @AppStorage("burstCount") var burstCount: Int = 1
    @AppStorage("burstGapMs") var burstGapMs: Double = 20
    @AppStorage("button") var button: MouseButtonChoice = .left
    @AppStorage("kind") var kind: ClickKind = .single
    @AppStorage("stopMode") var stopMode: StopMode = .never
    @AppStorage("stopValue") var stopValue: Int = 100
    @AppStorage("startDelay") var startDelay: Double = 0
    @AppStorage("useFixedPoint") var useFixedPoint: Bool = false
    @AppStorage("fixedX") var fixedX: Double = 0
    @AppStorage("fixedY") var fixedY: Double = 0

    @Published var isRunning = false
    @Published var clickCount = 0
    @Published var pickCountdown = 0
    @Published var trusted = AXIsProcessTrusted()

    private let engine = ClickEngine()
    private var hotKey: HotKey?
    private var trustTimer: Timer?

    init() {
        hotKey = HotKey(keyCode: kVK_F6) { [weak self] in self?.toggle() }
        // Poll so the warning banner clears once the user grants access.
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            let t = AXIsProcessTrusted()
            if self?.trusted != t { self?.trusted = t }
        }
    }

    func requestAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(opts)
    }

    func toggle() { isRunning ? stop() : start() }

    func start() {
        guard !isRunning else { return }
        guard AXIsProcessTrusted() else { requestAccess(); return }
        let cfg = ClickConfig(intervalMs: intervalMs, jitterMs: jitterMs, burstCount: burstCount,
                              burstGapMs: burstGapMs, button: button, kind: kind,
                              stopMode: stopMode, stopValue: max(1, stopValue),
                              useFixedPoint: useFixedPoint, fixedPoint: CGPoint(x: fixedX, y: fixedY))
        clickCount = 0
        isRunning = true
        engine.start(cfg, startDelay: startDelay,
                     onClick: { n in DispatchQueue.main.async { self.clickCount = n } },
                     onFinish: { DispatchQueue.main.async { self.isRunning = false } })
    }

    func stop() { engine.stop() }

    /// Gives the user 3 seconds to move the mouse to the target, then records it.
    func pickPoint() {
        pickCountdown = 3
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.pickCountdown -= 1
            if self.pickCountdown <= 0 {
                t.invalidate()
                let p = CGEvent(source: nil)?.location ?? .zero
                self.fixedX = p.x.rounded()
                self.fixedY = p.y.rounded()
                self.useFixedPoint = true
            }
        }
    }
}

// MARK: - Classic 1-bit look

private let ink = Color.black
private let paper = Color.white

extension Font {
    /// ChicagoFLF is bundled in Resources (public domain, see Fonts/README.ChicagoFLF).
    static func chicago(_ size: CGFloat = 12) -> Font { .custom("ChicagoFLF", size: size) }
    static func geneva(_ size: CGFloat = 12) -> Font { .custom("Geneva", size: size) }
}

struct ClassicButtonStyle: ButtonStyle {
    var isDefault = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.chicago())
            .padding(.horizontal, 12)
            .frame(minWidth: 58, minHeight: 20)
            .foregroundStyle(pressed ? paper : ink)
            .background(RoundedRectangle(cornerRadius: 6).fill(pressed ? ink : paper))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ink, lineWidth: 1))
            .padding(isDefault ? 4 : 0)
            .overlay {
                if isDefault { RoundedRectangle(cornerRadius: 9).strokeBorder(ink, lineWidth: 3) }
            }
            .opacity(enabled ? 1 : 0.35)
            .contentShape(Rectangle())
    }
}

struct ClassicRadio<T: Hashable>: View {
    let label: String
    let value: T
    @Binding var selection: T

    var body: some View {
        Button { selection = value } label: {
            HStack(spacing: 5) {
                ZStack {
                    Circle().fill(paper)
                    Circle().strokeBorder(ink, lineWidth: 1)
                    if selection == value { Circle().fill(ink).padding(3) }
                }
                .frame(width: 12, height: 12)
                Text(label).font(.chicago())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(ink)
    }
}

struct ClassicCheckbox: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 5) {
                ZStack {
                    Rectangle().fill(paper)
                    Rectangle().strokeBorder(ink, lineWidth: 1)
                    if isOn {
                        Path { p in
                            p.move(to: .init(x: 0, y: 0)); p.addLine(to: .init(x: 12, y: 12))
                            p.move(to: .init(x: 12, y: 0)); p.addLine(to: .init(x: 0, y: 12))
                        }
                        .stroke(ink, lineWidth: 1)
                    }
                }
                .frame(width: 12, height: 12)
                Text(label).font(.chicago())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(ink)
    }
}

struct ClassicField<F: ParseableFormatStyle>: View where F.FormatOutput == String {
    @Binding var value: F.FormatInput
    let format: F
    var width: CGFloat = 70

    var body: some View {
        TextField("", value: $value, format: format)
            .textFieldStyle(.plain)
            .font(.geneva())
            .foregroundStyle(ink)
            .tint(ink)
            .focusEffectDisabled()
            .padding(.horizontal, 3)
            .frame(width: width, height: 18)
            .background(paper)
            .overlay(Rectangle().strokeBorder(ink, lineWidth: 1))
    }
}

/// Up/down arrow pair, like the little-arrows control.
struct ClassicStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        VStack(spacing: 0) {
            arrow("arrowtriangle.up.fill") { value = min(range.upperBound, value + 1) }
            Rectangle().fill(ink).frame(height: 1)
            arrow("arrowtriangle.down.fill") { value = max(range.lowerBound, value - 1) }
        }
        .frame(width: 13, height: 20)
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(ink, lineWidth: 1))
    }

    private func arrow(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 5)).frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(ink)
    }
}

struct ClassicGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 10)
            .padding(.top, 13)
            .padding(.bottom, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(Rectangle().strokeBorder(ink, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                Text(title).font(.chicago()).foregroundStyle(ink)
                    .padding(.horizontal, 3)
                    .background(paper)
                    .offset(x: 8, y: -8)
            }
    }
}

/// Lets the striped title bar drag a borderless window.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct TitleBar: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        ZStack {
            WindowDragArea()
            Canvas { ctx, size in
                for i in 0..<6 {
                    let y = CGFloat(4 + i * 2)
                    ctx.fill(Path(CGRect(x: 1, y: y, width: size.width - 2, height: 1)), with: .color(ink))
                }
            }
            .allowsHitTesting(false)
            Text(title).font(.chicago()).foregroundStyle(ink)
                .padding(.horizontal, 8)
                .background(paper)
                .allowsHitTesting(false)
            HStack {
                Button(action: onClose) {
                    Rectangle().strokeBorder(ink, lineWidth: 1).background(paper)
                        .frame(width: 11, height: 11)
                }
                .buttonStyle(CloseBoxStyle())
                .padding(.horizontal, 2)
                .background(paper)
                .padding(.leading, 7)
                Spacer()
            }
        }
        .frame(height: 19)
        .overlay(alignment: .bottom) { Rectangle().fill(ink).frame(height: 1) }
    }
}

struct CloseBoxStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.overlay {
            if configuration.isPressed {
                // The little starburst a pressed close box shows.
                Path { p in
                    let c = CGPoint(x: 5.5, y: 5.5)
                    for a in stride(from: 0.0, to: .pi * 2, by: .pi / 4) {
                        p.move(to: CGPoint(x: c.x + cos(a) * 1.5, y: c.y + sin(a) * 1.5))
                        p.addLine(to: CGPoint(x: c.x + cos(a) * 4.5, y: c.y + sin(a) * 4.5))
                    }
                }
                .stroke(ink, lineWidth: 1)
            }
        }
    }
}

// MARK: - UI

struct ContentView: View {
    @StateObject private var m = ClickerModel()

    private var cps: String {
        let perCycle = Double(max(1, m.burstCount))
        let cycleMs = m.intervalMs + Double(max(0, m.burstCount - 1)) * m.burstGapMs
        guard cycleMs > 0 else { return "—" }
        return String(format: "≈ %.1f clicks/sec", perCycle * 1000 / cycleMs)
    }

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(title: "AutoClicker") { NSApp.terminate(nil) }

            VStack(alignment: .leading, spacing: 16) {
                if !m.trusted {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 18))
                        Text("Needs Accessibility access.").font(.geneva())
                        Spacer()
                        Button("Grant…") { m.requestAccess() }.buttonStyle(ClassicButtonStyle())
                    }
                    .foregroundStyle(ink)
                    .padding(8)
                    .overlay(Rectangle().strokeBorder(ink, lineWidth: 2))
                }

                ClassicGroup(title: "Timing") {
                    Grid(alignment: .leading, verticalSpacing: 8) {
                        row("Interval", $m.intervalMs, "ms")
                        row("Random ±", $m.jitterMs, "ms")
                        row("Start delay", $m.startDelay, "sec")
                    }
                }

                ClassicGroup(title: "Burst") {
                    Grid(alignment: .leading, verticalSpacing: 8) {
                        GridRow {
                            label("Clicks per burst")
                            HStack(spacing: 4) {
                                ClassicField(value: $m.burstCount, format: .number, width: 50)
                                ClassicStepper(value: $m.burstCount, range: 1...100)
                            }
                        }
                        row("Gap in burst", $m.burstGapMs, "ms")
                            .opacity(m.burstCount <= 1 ? 0.35 : 1)
                            .disabled(m.burstCount <= 1)
                    }
                }

                ClassicGroup(title: "Click") {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 14) {
                            label("Button").frame(width: 50, alignment: .leading)
                            ForEach(MouseButtonChoice.allCases) {
                                ClassicRadio(label: $0.rawValue, value: $0, selection: $m.button)
                            }
                        }
                        HStack(spacing: 14) {
                            label("Type").frame(width: 50, alignment: .leading)
                            ForEach(ClickKind.allCases) {
                                ClassicRadio(label: $0.rawValue, value: $0, selection: $m.kind)
                            }
                        }
                        HStack(spacing: 8) {
                            ClassicCheckbox(label: "Fixed position", isOn: $m.useFixedPoint)
                            Spacer()
                            if m.useFixedPoint {
                                Text("\(Int(m.fixedX)), \(Int(m.fixedY))").font(.geneva()).monospacedDigit()
                            }
                            Button(m.pickCountdown > 0 ? "Move… \(m.pickCountdown)" : "Pick") { m.pickPoint() }
                                .buttonStyle(ClassicButtonStyle())
                                .disabled(m.pickCountdown > 0)
                        }
                    }
                }

                ClassicGroup(title: "Stop") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(StopMode.allCases) {
                            ClassicRadio(label: $0.rawValue, value: $0, selection: $m.stopMode)
                        }
                        HStack(spacing: 5) {
                            label("N =")
                            ClassicField(value: $m.stopValue, format: .number, width: 70)
                            label(m.stopMode == .afterSeconds ? "sec" : "clicks")
                        }
                        .padding(.leading, 17)
                        .opacity(m.stopMode == .never ? 0.35 : 1)
                        .disabled(m.stopMode == .never)
                    }
                }

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clicks: \(m.clickCount)").font(.chicago()).monospacedDigit()
                        Text(cps).font(.geneva(10))
                    }
                    Spacer()
                    Button(m.isRunning ? "Stop (F6)" : "Start (F6)") { m.toggle() }
                        .buttonStyle(ClassicButtonStyle(isDefault: true))
                        .keyboardShortcut(.return, modifiers: [])
                }
            }
            .foregroundStyle(ink)
            .padding(16)
        }
        .frame(width: 380)
        .background(paper)
        .overlay(Rectangle().strokeBorder(ink, lineWidth: 1))
        // 1px drop shadow on the right and bottom edges.
        .background(Rectangle().fill(ink).offset(x: 1, y: 1))
        .padding([.trailing, .bottom], 1)
        .environment(\.colorScheme, .light)
    }

    private func label(_ s: String) -> some View { Text(s).font(.chicago()) }

    private func row(_ title: String, _ value: Binding<Double>, _ unit: String) -> some View {
        GridRow {
            label(title)
            HStack(spacing: 5) {
                ClassicField(value: value, format: .number.grouping(.never), width: 80)
                Text(unit).font(.geneva())
            }
        }
    }
}

// MARK: - App

/// Borderless windows refuse key status by default, which would block typing in the fields.
final class ClassicWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingView(rootView: ContentView())
        host.sizingOptions = [.minSize, .maxSize]
        let w = ClassicWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window = w
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct AutoClickerApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}
