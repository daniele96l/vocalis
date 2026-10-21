import AppKit
import Combine
import SwiftUI

public enum BubbleState: Equatable, Sendable {
    case hidden
    case listening
    case fixing
    case error(String)
}

@MainActor
public final class BubbleOverlayController {
    private var panel: NSPanel?
    private let model = BubbleModel()

    public init() {}

    public func show(_ state: BubbleState) {
        model.state = state
        ensurePanel()
        guard let panel else { return }
        position(panel)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        panel.contentView?.needsDisplay = true
    }

    public func hide() {
        model.state = .hidden
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        if panel != nil { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true

        let view = NSHostingView(rootView: BubbleView(model: model))
        view.frame = panel.contentView?.bounds ?? .zero
        panel.contentView = view
        self.panel = panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let size = panel.frame.size
        // Prefer near cursor; fall back toward bottom-center of active screen
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y + 24)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.y + size.height > visible.maxY {
                origin.y = mouse.y - size.height - 24
            }
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            if origin.y < visible.minY + 8 {
                origin = NSPoint(
                    x: visible.midX - size.width / 2,
                    y: visible.minY + 48
                )
            }
        }
        panel.setFrameOrigin(origin)
    }
}

@MainActor
final class BubbleModel: ObservableObject {
    @Published var state: BubbleState = .hidden
}

struct BubbleView: View {
    @ObservedObject var model: BubbleModel

    var body: some View {
        Group {
            switch model.state {
            case .hidden:
                EmptyView()
            case .listening:
                pill(label: "Listening…", tint: Color.red.opacity(0.85), pulsing: true)
            case .fixing:
                pill(label: "Fixing…", tint: Color.orange.opacity(0.9), pulsing: false)
            case .error(let message):
                pill(label: message, tint: Color.black.opacity(0.75), pulsing: false)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: model.state)
    }

    private func pill(label: String, tint: Color, pulsing: Bool) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(pulsing ? Color.red : Color.white.opacity(0.9))
                .frame(width: 8, height: 8)
                .opacity(pulsing ? 1 : 0.85)
                .scaleEffect(pulsing ? 1.15 : 1)
                .animation(pulsing ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default, value: pulsing)
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(tint.opacity(0.35)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
        )
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .padding(4)
    }
}
