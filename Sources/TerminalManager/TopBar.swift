import AppKit
import Combine
import SwiftUI

/// Motion and layout constants shared by the bar and the terminal windows.
enum Design {
    /// Strong ease-out, cubic-bezier(0.23, 1, 0.32, 1): starts fast, settles softly.
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    static let swiftUIEaseOut = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static let terminalBackground = NSColor(calibratedRed: 0.105, green: 0.107, blue: 0.125, alpha: 1)
}

/// Geometry of the bar, computed up front so the panel size and the pill
/// positions (where windows open from) always agree with what SwiftUI draws.
struct BarLayout {
    static let padding: CGFloat = 5
    static let spacing: CGFloat = 4
    static let pillHeight: CGFloat = 34
    static let outerRadius: CGFloat = 14
    /// Concentric corners: inner radius = outer radius - padding.
    static let innerRadius: CGFloat = outerRadius - padding
    static let addButtonWidth: CGFloat = 34
    static let emptyAddButtonWidth: CGFloat = 132
    static let maxPillWidth: CGFloat = 176
    static let minPillWidth: CGFloat = 92

    let count: Int
    let pillWidth: CGFloat

    init(count: Int, availableWidth: CGFloat) {
        self.count = count
        let room = availableWidth - Self.padding * 2 - Self.addButtonWidth - Self.spacing * CGFloat(count)
        let fit = count > 0 ? room / CGFloat(count) : Self.maxPillWidth
        pillWidth = floor(min(Self.maxPillWidth, max(Self.minPillWidth, fit)))
    }

    var addWidth: CGFloat { count == 0 ? Self.emptyAddButtonWidth : Self.addButtonWidth }

    var size: CGSize {
        let pills = CGFloat(count) * (pillWidth + Self.spacing)
        return CGSize(width: Self.padding * 2 + pills + addWidth, height: Self.padding * 2 + Self.pillHeight)
    }

    /// Pill frame in the bar's coordinates (origin bottom-left, like AppKit).
    func pillFrame(at index: Int) -> CGRect {
        CGRect(x: Self.padding + CGFloat(index) * (pillWidth + Self.spacing),
               y: Self.padding, width: pillWidth, height: Self.pillHeight)
    }

    /// Narrow pills drop the second line rather than squeezing it into "…".
    var showsDetail: Bool { pillWidth >= 120 }

    static func current(count: Int) -> BarLayout {
        let width = NSScreen.screens.first?.visibleFrame.width ?? 1440
        return BarLayout(count: count, availableWidth: width - 40)
    }
}

/// The floating strip at the top of the screen with one pill per terminal.
@MainActor
final class TopBarPanel: NSPanel {
    private let store: SessionStore
    private var targetFrame: NSRect = .zero
    private var sessionsObserver: AnyCancellable?

    init(store: SessionStore) {
        self.store = store
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        contentView = NSHostingView(rootView: BarView(store: store))
        relayout(animated: false)
        // Resize right away when a terminal is added or closed (not on the next poll).
        // @Published fires before the change lands, so hop to the next main-queue turn.
        sessionsObserver = store.$sessions.receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var layout: BarLayout { BarLayout.current(count: store.sessions.count) }

    /// Resize to fit the pills and stay centered just below the menu bar.
    /// Called on every poll, so it only does work when the target changes.
    func relayout(animated: Bool = true) {
        guard let screen = NSScreen.screens.first else { return }
        let size = layout.size
        let visible = screen.visibleFrame
        let frame = NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 6,
                           width: size.width, height: size.height).integral
        guard frame != targetFrame else { return }
        targetFrame = frame
        if animated, isVisible, !Design.reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = Design.easeOut
                animator().setFrame(frame, display: true)
            }
        } else {
            setFrame(frame, display: true)
        }
    }

    /// Screen rect of a session's pill, so its window can open right underneath it.
    func pillFrameOnScreen(for session: TerminalSession) -> NSRect? {
        guard let index = store.sessions.firstIndex(where: { $0 === session }) else { return nil }
        let local = layout.pillFrame(at: index)
        return local.offsetBy(dx: targetFrame.minX, dy: targetFrame.minY)
    }
}

// MARK: - Views

struct BarView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        let layout = BarLayout.current(count: store.sessions.count)
        HStack(spacing: BarLayout.spacing) {
            ForEach(store.sessions) { session in
                SessionPill(session: session, store: store, width: layout.pillWidth, showsDetail: layout.showsDetail)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.95)).animation(Design.swiftUIEaseOut),
                        removal: .opacity.animation(.easeOut(duration: 0.12))
                    ))
            }
            AddButton(store: store, isEmpty: store.sessions.isEmpty)
                .frame(width: layout.addWidth, height: BarLayout.pillHeight)
        }
        .padding(BarLayout.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: BarLayout.outerRadius, style: .continuous))
        .overlay(
            // A light edge where the material catches the light, instead of a solid border.
            RoundedRectangle(cornerRadius: BarLayout.outerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.5
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: BarLayout.outerRadius, style: .continuous))
    }
}

/// Scales down slightly on press and lifts on hover, so every click feels heard.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration)
    }

    private struct PressableBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: BarLayout.innerRadius, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : hovering ? 0.06 : 0))
                )
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

struct AddButton: View {
    let store: SessionStore
    let isEmpty: Bool

    var body: some View {
        Button {
            store.newSession()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                if isEmpty {
                    Text("New Terminal").font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help("New terminal (⌘T)")
        .contextMenu {
            Button("New Terminal") { store.newSession() }
            Button("New Terminal in Folder…") { store.newSessionInFolder() }
        }
    }
}

struct SessionPill: View {
    @ObservedObject var session: TerminalSession
    let store: SessionStore
    let width: CGFloat
    let showsDetail: Bool

    private var state: ActivityState { session.state }

    var body: some View {
        Button {
            store.toggle(session)
        } label: {
            HStack(spacing: 8) {
                StatusDot(state: state)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(state == .idle ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
                    if showsDetail {
                        Text(session.detail)
                            .font(.system(size: 10))
                            .foregroundStyle(state == .needsInput ? AnyShapeStyle(state.color) : AnyShapeStyle(.secondary))
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer(minLength: 0)
                if session.keepOpen {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: width, height: BarLayout.pillHeight)
            .background(
                RoundedRectangle(cornerRadius: BarLayout.innerRadius, style: .continuous)
                    .fill(state.color.opacity(tintOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: BarLayout.innerRadius, style: .continuous)
                    .strokeBorder(state.color.opacity(state.wantsAttention ? 0.45 : 0), lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.2), value: state)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help("\(session.name) — \(state.label)\n\((session.directory as NSString).abbreviatingWithTildeInPath)")
        .contextMenu {
            Button(session.isFrontmost ? "Hide" : "Show") { store.toggle(session) }
            Button("Rename…") { store.rename(session) }
            Toggle("Keep Open (No Auto-Hide)", isOn: $session.keepOpen)
            Divider()
            Button("Close Terminal…") { store.confirmAndClose(session) }
        }
    }

    /// Only states that want you get a colored fill; a working terminal stays calm.
    private var tintOpacity: Double {
        switch state {
        case .needsInput: return 0.2
        case .done: return 0.14
        case .exited: return 0.1
        case .working, .idle: return 0
        }
    }
}

/// The state dot. When a terminal needs you, a ring pings outward from it, like sonar.
struct StatusDot: View {
    let state: ActivityState

    var body: some View {
        ZStack {
            if state == .needsInput {
                if Design.reduceMotion {
                    Circle().strokeBorder(state.color.opacity(0.5), lineWidth: 1.5).frame(width: 15, height: 15)
                } else {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                        let period = 1.4
                        let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                        let eased = 1 - pow(1 - t, 3) // ease-out
                        Circle()
                            .stroke(state.color, lineWidth: 1.5)
                            .frame(width: 8, height: 8)
                            .scaleEffect(1 + eased * 1.4)
                            .opacity(0.7 * (1 - eased))
                    }
                }
            }
            if state == .idle {
                Circle().strokeBorder(state.color, lineWidth: 1.5).frame(width: 8, height: 8)
            } else {
                Circle().fill(state.color).frame(width: 8, height: 8)
            }
        }
        .frame(width: 18, height: 18)
        .animation(.easeOut(duration: 0.2), value: state)
    }
}

/// Shown in the terminal window's title bar: current state and the Keep Open pin.
struct WindowStatusView: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Circle().fill(session.state.color).frame(width: 7, height: 7)
                Text(session.state.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    // Fixed width: the title bar accessory doesn't resize when the label changes.
                    .frame(width: 62, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(session.state.color.opacity(0.14), in: Capsule())
            .animation(.easeOut(duration: 0.2), value: session.state)

            Button {
                session.keepOpen.toggle()
            } label: {
                Image(systemName: session.keepOpen ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(session.keepOpen ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .help(session.keepOpen ? "Keep Open is on: this window won't hide itself" : "Keep this window open (no auto-hide)")
        }
        .padding(.trailing, 8)
        .frame(height: 28)
    }
}
