import AppKit
import SwiftUI

/// The floating strip at the top of the screen with one pill per terminal.
@MainActor
final class TopBarPanel: NSPanel {
    private let hostingView: NSHostingView<BarView>

    init(store: SessionStore) {
        hostingView = NSHostingView(rootView: BarView(store: store))
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
        contentView = hostingView
        relayout()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Resize to fit the pills and stay centered just below the menu bar.
    func relayout() {
        guard let screen = NSScreen.screens.first else { return }
        let size = hostingView.fittingSize
        let visible = screen.visibleFrame
        let width = min(size.width, visible.width - 20)
        let frame = NSRect(
            x: visible.midX - width / 2,
            y: visible.maxY - size.height - 4,
            width: width,
            height: size.height
        ).integral
        if frame != self.frame { setFrame(frame, display: true) }
    }
}

struct BarView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        HStack(spacing: 6) {
            ForEach(store.sessions) { session in
                SessionPill(session: session, store: store)
            }
            Button {
                store.newSession()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New terminal")
            .contextMenu {
                Button("New Terminal") { store.newSession() }
                Button("New Terminal in Folder…") { store.newSessionInFolder() }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1))
        )
        .fixedSize()
    }
}

struct SessionPill: View {
    @ObservedObject var session: TerminalSession
    let store: SessionStore
    @State private var pulse = false

    var body: some View {
        Button {
            store.toggle(session)
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(session.state.color)
                    .frame(width: 9, height: 9)
                    .shadow(color: session.state.wantsAttention ? session.state.color : .clear, radius: 4)
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(session.detail)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: 150, alignment: .leading)
                if session.keepOpen {
                    Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(session.state.color.opacity(session.state.wantsAttention ? (pulse ? 0.45 : 0.2) : 0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(session.state.color.opacity(session.state.wantsAttention ? 0.8 : 0.25))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(session.name) — \(session.state.label)\n\(session.directory)")
        .onAppear { updatePulse() }
        .onChange(of: session.state) { _, _ in updatePulse() }
        .contextMenu {
            Button(session.isFrontmost ? "Hide" : "Show") { store.toggle(session) }
            Button("Rename…") { store.rename(session) }
            Toggle("Keep Open (no auto-hide)", isOn: $session.keepOpen)
            Divider()
            Button("Close Terminal") { store.confirmAndClose(session) }
        }
    }

    private func updatePulse() {
        if session.state == .needsInput {
            pulse = false
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        } else {
            withAnimation(.default) { pulse = false }
        }
    }
}
