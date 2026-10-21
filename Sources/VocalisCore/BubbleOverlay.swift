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
        if state != .listening {
            model.level = 0
        }
        ensurePanel()
        guard let panel else { return }
        position(panel)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        let size: NSSize
        switch state {
        case .listening:
            size = NSSize(width: 300, height: 92)
        case .error:
            size = NSSize(width: 280, height: 64)
        default:
            size = NSSize(width: 260, height: 64)
        }
        var frame = panel.frame
        frame.size = size
        panel.setFrame(frame, display: true)
        panel.contentView?.needsDisplay = true
    }

    public func updateMeter(level: Float, micName: String) {
        model.level = level
        model.micName = micName
        if let panel, model.state == .listening {
            position(panel)
        }
    }

    public func hide() {
        model.state = .hidden
        model.level = 0
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        if panel != nil { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 92),
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

    var body: some View {
        Group {
            switch model.state {
            case .hidden:
                Color.clear.frame(width: 1, height: 1)
            case .listening:
                listeningPill
            case .fixing:
                pill(label: "Cleaning…", kind: .fixing)
            case .error(let message):
                pill(label: message, kind: .error)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: model.state)
    }

    private var listeningPill: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                LiveWaveform(level: model.level)
                    .frame(width: 88, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.level < 0.04 ? "Listening… (quiet)" : "Listening…")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(model.micName)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 288, alignment: .leading)
        .background(bubbleChrome)
        .padding(4)
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }

    private enum Kind { case listening, fixing, error }

    private func pill(label: String, kind: Kind) -> some View {
        HStack(spacing: 12) {
            switch kind {
            case .listening:
                EmptyView()
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
        .background(bubbleChrome)
        .padding(4)
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }

    private var bubbleChrome: some View {
        Capsule(style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
    }
}

/// Live mic level bars — height follows input so silence vs speech is obvious.
struct LiveWaveform: View {
    var level: Float

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            WaveformBars(level: level, time: timeline.date.timeIntervalSinceReferenceDate)
        }
    }
}

private struct WaveformBars: View {
    var level: Float
    var time: TimeInterval

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<9, id: \.self) { i in
                Capsule()
                    .fill(barColor)
                    .frame(width: 4, height: barHeight(index: i))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .animation(.easeOut(duration: 0.08), value: level)
    }

    private var barColor: Color {
        level < 0.04 ? Color.orange.opacity(0.7) : Color.red.opacity(0.85)
    }

    private func barHeight(index: Int) -> CGFloat {
        let wobble = 0.55 + 0.45 * abs(sin(time * 6.0 + Double(index) * 0.7))
        let base = CGFloat(level) * 26 * CGFloat(wobble)
        return max(4, base + (level < 0.04 ? 3 : 0))
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
