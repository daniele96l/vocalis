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
        withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
            model.state = state
            if state != .listening {
                model.level = 0
                model.showingQuiet = true
            }
        }
        ensurePanel()
        guard let panel else { return }
        position(panel)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        let size: NSSize = {
            switch state {
            case .listening: return NSSize(width: 292, height: 86)
            default: return NSSize(width: 228, height: 52)
            }
        }()
        var frame = panel.frame
        frame.size = size
        panel.setFrame(frame, display: true, animate: true)
    }

    public func updateMeter(level: Float, micName: String) {
        model.level = level
        if model.micName != micName {
            model.micName = micName
        }
        if model.showingQuiet {
            if level >= 0.03 { model.showingQuiet = false }
        } else if level < 0.008 {
            model.showingQuiet = true
        }
    }

    public func hide() {
        withAnimation(.easeOut(duration: 0.18)) {
            model.state = .hidden
            model.level = 0
            model.showingQuiet = true
        }
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        if panel != nil { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 292, height: 86),
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
    /// Hysteresis so the label does not flicker Listening ↔ quiet on soft speech.
    var showingQuiet = true
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
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.94).combined(with: .opacity),
                        removal: .opacity
                    ))
            case .transcribing:
                simpleCard(title: "Transcribing…", spinning: true)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            case .polishing:
                simpleCard(title: "Polishing…", spinning: true)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            case .error(let message):
                simpleCard(title: message, spinning: false)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: model.state)
    }

    private var listeningCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                LiveWaveform(level: model.level, barCount: 12)
                    .frame(width: 96, height: 22)
                HStack(spacing: 0) {
                    Text("Listening")
                        .font(.system(size: 13, weight: .medium))
                    if model.showingQuiet {
                        Text(" · quiet")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            Text(model.micName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 280, alignment: .leading)
        .background(cardBackground)
    }

    private func simpleCard(title: String, spinning: Bool) -> some View {
        HStack(spacing: 10) {
            if spinning {
                SoftSpinner()
                    .frame(width: 14, height: 14)
            }
            Text(title)
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(scheme == .dark ? Color(white: 0.14) : Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.10), radius: 16, y: 6)
    }
}

/// Always-wiggling bars: idle motion + mic level. Monochrome, Notion-quiet.
struct LiveWaveform: View {
    var level: Float
    var barCount: Int = 12

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<barCount, id: \.self) { i in
                    let phase = Double(i) * 0.55
                    let wiggle = 0.35 + 0.65 * abs(sin(t * 4.2 + phase))
                    let energy = Double(max(0.08, min(1, level)))
                    let quietFloor = 0.22 + 0.12 * abs(sin(t * 2.1 + phase * 0.7))
                    let amp = quietFloor + (1.0 - quietFloor) * energy * wiggle
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.22 + 0.78 * energy))
                        .frame(width: 4, height: max(4, 22 * amp))
                }
            }
            .frame(maxHeight: 22)
        }
    }
}

struct SoftSpinner: View {
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 0.88)
            .stroke(Color.primary.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    spin = true
                }
            }
    }
}
