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
        // Grow slightly for animated content
        let size = NSSize(width: 260, height: 64)
        var frame = panel.frame
        frame.size = size
        panel.setFrame(frame, display: true)
        panel.contentView?.needsDisplay = true
    }

    public func hide() {
        model.state = .hidden
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        if panel != nil { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 64),
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
                Color.clear.frame(width: 1, height: 1)
            case .listening:
                pill(label: "Listening…", kind: .listening)
            case .fixing:
                pill(label: "Cleaning…", kind: .fixing)
            case .error(let message):
                pill(label: message, kind: .error)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: model.state)
    }

    private enum Kind { case listening, fixing, error }

    private func pill(label: String, kind: Kind) -> some View {
        HStack(spacing: 12) {
            switch kind {
            case .listening:
                BreathingOrb()
                    .frame(width: 22, height: 22)
            case .fixing:
                CleaningDots()
                    .frame(width: 28, height: 14)
            case .error:
                ErrorGlyph()
            }

            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
        .padding(4)
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }
}

/// Soft breathing orb while recording — calm pulse, no frantic bars.
struct BreathingOrb: View {
    @State private var breathe = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.red.opacity(0.18))
                .scaleEffect(breathe ? 1.35 : 0.9)
            Circle()
                .fill(Color.red.opacity(0.85))
                .frame(width: 10, height: 10)
                .scaleEffect(breathe ? 1.08 : 0.92)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }
}

/// Gentle shimmering dots while Whisper + cleanup run.
struct CleaningDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.28, paused: false)) { context in
            let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.28) % 3
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 5, height: 5)
                        .offset(y: phase == i ? -3 : 0)
                        .opacity(phase == i ? 1 : 0.35)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: phase)
        }
    }
}

struct ErrorGlyph: View {
    @State private var dim = false

    var body: some View {
        Image(systemName: "exclamationmark.circle.fill")
            .foregroundStyle(.orange)
            .opacity(dim ? 0.45 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}
