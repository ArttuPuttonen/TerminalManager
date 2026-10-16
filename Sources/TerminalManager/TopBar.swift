import AppKit
import Combine
import SwiftUI

/// Motion constants shared across the UI.
enum Design {
    /// Strong ease-out, cubic-bezier(0.23, 1, 0.32, 1): starts fast, settles softly.
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    static let swiftUIEaseOut = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// Geometry of the bar, computed up front so the panel size always matches what SwiftUI draws.
struct BarLayout {
    static let padding: CGFloat = 5
    static let spacing: CGFloat = 4
    static let pillHeight: CGFloat = 34
    static let outerRadius: CGFloat = 14
    /// Concentric corners: inner radius = outer radius - padding.
    static let innerRadius: CGFloat = outerRadius - padding
    static let maxPillWidth: CGFloat = 176
    static let minPillWidth: CGFloat = 92
    static let noticeWidth: CGFloat = 250
    static let addButtonWidth: CGFloat = 34

    let count: Int
    let pillWidth: CGFloat

    init(count: Int, availableWidth: CGFloat) {
        self.count = count
        let room = availableWidth - Self.padding * 2 - Self.addButtonWidth - Self.spacing * CGFloat(count)
        let fit = count > 0 ? room / CGFloat(count) : Self.maxPillWidth
        pillWidth = floor(min(Self.maxPillWidth, max(Self.minPillWidth, fit)))
    }

    var size: CGSize {
        // Pills, then the + button (only shown while at least one window is open).
        let content = count > 0
            ? CGFloat(count) * (pillWidth + Self.spacing) + Self.addButtonWidth
            : Self.noticeWidth
        return CGSize(width: Self.padding * 2 + content, height: Self.padding * 2 + Self.pillHeight)
    }

    // Collapsed: one status dot per window in a small capsule under the notch.
    static let dotSize: CGFloat = 18
    static let dotSpacing: CGFloat = 3
    static let collapsedPadding = EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
    static var collapsedHeight: CGFloat { dotSize + collapsedPadding.top + collapsedPadding.bottom }

    var collapsedSize: CGSize {
        let dots = CGFloat(count) * Self.dotSize + CGFloat(max(count - 1, 0)) * Self.dotSpacing
        return CGSize(width: dots + Self.collapsedPadding.leading + Self.collapsedPadding.trailing,
                      height: Self.collapsedHeight)
    }

    /// Narrow pills drop the second line rather than squeezing it into "…".
    var showsDetail: Bool { pillWidth >= 120 }

    static func current(count: Int) -> BarLayout {
        let width = NSScreen.screens.first?.visibleFrame.width ?? 1440
        return BarLayout(count: count, availableWidth: width - 40)
    }
}

/// The floating strip at the top of the screen with one pill per Terminal window.
/// It only exists while there is something to show.
@MainActor
final class TopBarPanel: NSPanel {
    private let store: SessionStore
    let barState = BarState()
    private var targetFrame: NSRect = .zero
    private var observers: Set<AnyCancellable> = []
    /// You can hide the bar from the menu bar menu; then it stays hidden.
    var userHidden = false {
        didSet { updateVisibility() }
    }

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
        let hosting = NSHostingView(rootView: BarView(store: store, barState: barState))
        let container = HoverTrackingView { [weak self] inside in self?.barState.hover(inside) }
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        contentView = container
        relayout(animated: false)

        barState.$expanded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    // Opening is instant (you're reaching for it); closing gets a short, soft shrink.
                    guard let self else { return }
                    self.relayout(animated: !self.barState.expanded)
                }
            }
            .store(in: &observers)

        // React right away when windows come and go (not on the next poll).
        // @Published fires before the change lands, so hop to the next main-queue turn.
        store.$windows.combineLatest(store.$accessDenied)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.relayout()
                    self?.updateVisibility()
                }
            }
            .store(in: &observers)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private var hasContent: Bool { !store.windows.isEmpty || store.accessDenied }

    /// The access notice has nothing to collapse into, so it always shows in full.
    private var showsExpanded: Bool { barState.expanded || store.windows.isEmpty }

    /// Resize to fit the pills and stay centered just below the menu bar.
    /// Called on every poll, so it only does work when the target changes.
    func relayout(animated: Bool = true) {
        guard let screen = NSScreen.screens.first else { return }
        let layout = BarLayout.current(count: store.windows.count)
        let size = showsExpanded ? layout.size : layout.collapsedSize
        let visible = screen.visibleFrame
        let frame = NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 4,
                           width: size.width, height: size.height).integral
        guard frame != targetFrame else { return }
        targetFrame = frame
        if animated, isVisible, alphaValue > 0, !Design.reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = Design.easeOut
                animator().setFrame(frame, display: true)
            }
        } else {
            setFrame(frame, display: true)
        }
    }

    private var showing = false

    /// Fades in when your first Terminal window opens; fades out (faster) when the last one closes.
    private func updateVisibility() {
        let shouldShow = hasContent && !userHidden
        guard shouldShow != showing else { return }
        showing = shouldShow
        if shouldShow {
            setFrame(targetFrame, display: false)
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = Design.easeOut
                animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = Design.easeOut
                animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.showing else { return }
                    self.orderOut(nil)
                }
            }
        }
    }

    var isShowing: Bool { showing }
}

// MARK: - Views

/// Whether the bar is collapsed to dots or expanded to pills. Hovering expands it
/// immediately, leaving collapses it after a moment, and it stays open while one
/// of its menus is showing.
@MainActor
final class BarState: ObservableObject {
    @Published private(set) var expanded = false
    private var pending: DispatchWorkItem?
    private var hovering = false
    private var menuOpen = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpen = true }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.menuOpen = false
                self?.schedule()
            }
        })
    }

    func hover(_ inside: Bool) {
        hovering = inside
        schedule()
    }

    /// Expand right away (e.g. on click).
    func expand() {
        pending?.cancel()
        expanded = true
    }

    private func schedule() {
        pending?.cancel()
        let target = hovering || menuOpen
        guard target != expanded else { return }
        if target {
            // Expand the moment the mouse arrives.
            expanded = true
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let target = self.hovering || self.menuOpen
                if target != self.expanded { self.expanded = target }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}

/// Reports the mouse entering and leaving, even while another app is active
/// (SwiftUI's hover tracking only works in the active app).
final class HoverTrackingView: NSView {
    private let onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseEntered(with event: NSEvent) { onChange(true) }
    override func mouseExited(with event: NSEvent) { onChange(false) }
}

struct BarView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var barState: BarState

    var body: some View {
        let expanded = barState.expanded || store.windows.isEmpty
        let radius = expanded ? BarLayout.outerRadius : BarLayout.collapsedHeight / 2
        ZStack {
            if expanded {
                pills.transition(.asymmetric(insertion: .identity, removal: .opacity.animation(.easeOut(duration: 0.1))))
            } else {
                dots.transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.12)), removal: .identity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            // A light edge where the material catches the light, instead of a solid border.
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.5
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Collapsed: just the status dots. A click expands right away.
    private var dots: some View {
        Button {
            barState.expand()
        } label: {
            HStack(spacing: BarLayout.dotSpacing) {
                ForEach(store.windows) { window in
                    WindowDot(window: window)
                }
            }
            .padding(BarLayout.collapsedPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(store.windows.map { "\($0.name) — \($0.state.label)" }.joined(separator: "\n"))
    }

    private var pills: some View {
        let layout = BarLayout.current(count: store.windows.count)
        return HStack(spacing: BarLayout.spacing) {
            if store.windows.isEmpty && store.accessDenied {
                AccessNotice()
            }
            ForEach(store.windows) { window in
                WindowPill(window: window, store: store, width: layout.pillWidth, showsDetail: layout.showsDetail)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.95)).animation(Design.swiftUIEaseOut),
                        removal: .opacity.animation(.easeOut(duration: 0.12))
                    ))
            }
            if !store.windows.isEmpty {
                AddButton(store: store)
                    .frame(width: BarLayout.addButtonWidth, height: BarLayout.pillHeight)
            }
        }
        .padding(BarLayout.padding)
    }
}

/// One window's dot in the collapsed bar.
struct WindowDot: View {
    @ObservedObject var window: ManagedWindow

    var body: some View {
        StatusDot(state: window.state)
            .frame(width: BarLayout.dotSize, height: BarLayout.dotSize)
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

/// Opens a new window in Terminal. Right-click to pick a folder first.
struct AddButton: View {
    let store: SessionStore

    var body: some View {
        Button {
            store.newWindow()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help("New Terminal window")
        .contextMenu {
            Button("New Terminal Window") { store.newWindow() }
            Button("New Terminal Window in Folder…") { store.newWindowInFolder() }
        }
    }
}

/// Shown instead of pills when macOS hasn't let us see Terminal's windows yet.
struct AccessNotice: View {
    var body: some View {
        Button {
            Permissions.openAutomationSettings()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Allow access to Terminal").font(.system(size: 12, weight: .semibold))
                    Text("Privacy & Security → Automation").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(width: BarLayout.noticeWidth, height: BarLayout.pillHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

struct WindowPill: View {
    @ObservedObject var window: ManagedWindow
    let store: SessionStore
    let width: CGFloat
    let showsDetail: Bool

    private var state: ActivityState { window.state }

    var body: some View {
        Button {
            store.toggle(window)
        } label: {
            HStack(spacing: 8) {
                StatusDot(state: state)
                VStack(alignment: .leading, spacing: 1) {
                    Text(window.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(state == .idle ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
                    if showsDetail {
                        Text(window.detail)
                            .font(.system(size: 10))
                            .foregroundStyle(state == .needsInput ? AnyShapeStyle(state.color) : AnyShapeStyle(.secondary))
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer(minLength: 0)
                if window.keepOpen {
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
            // The window you're looking at gets a quiet outline, so you know which pill it is.
            .overlay(
                RoundedRectangle(cornerRadius: BarLayout.innerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(window.isViewed && !state.wantsAttention ? 0.18 : 0), lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.2), value: state)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help("\(window.name) — \(state.label)\n\((window.directory as NSString).abbreviatingWithTildeInPath)")
        .contextMenu {
            Button(window.isViewed ? "Hide" : "Show") { store.toggle(window) }
            Button("Rename…") { store.rename(window) }
            Toggle("Keep Open (No Auto-Hide)", isOn: $window.keepOpen)
            Divider()
            Button("Close Window") { store.close(window) }
        }
    }

    /// Only states that want you get a colored fill; a working terminal stays calm.
    private var tintOpacity: Double {
        switch state {
        case .needsInput: return 0.2
        case .done: return 0.14
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
