import AppKit
import Combine
import SwiftUI

public enum BubbleState: Equatable, Sendable {
    case hidden
    case listening
    case transcribing
    case polishing
    case error(String)
}

@MainActor
public final class BubbleOverlayController {
    private var panel: NSPanel?
    private let model = BubbleModel()

    public init() {}

    public func show(_ state: BubbleState) {
        model.state = state
        if state != .listening {
            model.level = 0
        }
        ensurePanel()
        guard let panel else { return }
        position(panel)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        let size: NSSize = {
            switch state {
            case .listening: return NSSize(width: 280, height: 78)
            default: return NSSize(width: 220, height: 48)
            }
        }()
        var frame = panel.frame
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    public func updateMeter(level: Float, micName: String) {
        model.level = level
        model.micName = micName
    }

    public func hide() {
        model.state = .hidden
        model.level = 0
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        if panel != nil { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 78),
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
    @Published var level: Float = 0
    @Published var micName: String = "Microphone"
}

struct BubbleView: View {
    @ObservedObject var model: BubbleModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            switch model.state {
            case .hidden:
                Color.clear.frame(width: 1, height: 1)
            case .listening:
                listeningCard
            case .transcribing:
                simpleCard(title: "Transcribing…")
            case .polishing:
                simpleCard(title: "Polishing…")
            case .error(let message):
                simpleCard(title: message)
            }
        }
    }

    private var listeningCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                LevelMeter(level: model.level)
                    .frame(width: 72, height: 18)
                Text(model.level < 0.02 ? "Listening (quiet)" : "Listening")
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            Text(model.micName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 268, alignment: .leading)
        .background(cardBackground)
    }

    private func simpleCard(title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(scheme == .dark ? Color(white: 0.16) : Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}

/// Simple level bars — no decorative wobble.
struct LevelMeter: View {
    var level: Float

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<8, id: \.self) { i in
                let threshold = Float(i) / 8.0
                Rectangle()
                    .fill(level > threshold ? Color.primary : Color.primary.opacity(0.15))
                    .frame(width: 6, height: 6 + CGFloat(i) * 1.5)
            }
        }
        .animation(.easeOut(duration: 0.06), value: level)
    }
}
