import AppKit
import SwiftUI

private struct AppLanguageEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppLanguage = .system
}

extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageEnvironmentKey.self] }
        set { self[AppLanguageEnvironmentKey.self] = newValue }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    init(
        material: NSVisualEffectView.Material = .sidebar,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.material = material
        self.blendingMode = blendingMode
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .followsWindowActiveState
    }
}

/// Lightweight pure-SwiftUI segmented control. Native `NSSegmentedControl` re-measures its
/// segments on every width change, which made the sidebar collapse animation stutter.
struct PilotSegmentedControl<Value: Hashable>: View {
    @Environment(\.colorScheme) private var colorScheme
    let options: [(label: String, value: Value)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isSelected = option.value == selection
                Button {
                    if !isSelected {
                        withAnimation(.easeOut(duration: 0.12)) {
                            selection = option.value
                        }
                    }
                } label: {
                    Text(option.label)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isSelected ? selectedFill : Color.clear)
                                .shadow(
                                    color: Color.black.opacity(isSelected ? 0.14 : 0),
                                    radius: 0.6,
                                    x: 0,
                                    y: 0.5
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.07))
        )
        .accessibilityElement(children: .contain)
    }

    private var selectedFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.2) : Color.white
    }
}

/// Pre-renders (scales + rounds + shadows) an app icon once so SwiftUI only blits a
/// small bitmap per frame instead of re-scaling a 1024px icns and re-running offscreen shadow passes.
enum PilotIconCache {
    static let margin: CGFloat = 8
    private static var cache: [String: NSImage] = [:]

    /// Returned image has logical size `side + 2 * margin`; display it with `.padding(-margin)` to keep layout at `side`.
    static func baked(
        _ image: NSImage,
        key: String,
        side: CGFloat,
        cornerRadius: CGFloat,
        shadowBlur: CGFloat,
        shadowYOffset: CGFloat,
        shadowAlpha: CGFloat
    ) -> NSImage {
        let cacheKey = "\(key)-\(Int(side))"
        if let hit = cache[cacheKey] { return hit }

        let total = side + margin * 2
        let size = NSSize(width: total, height: total)
        let scale: CGFloat = 2
        let px = Int(total * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: px,
            pixelsHigh: px,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            return image
        }
        rep.size = size

        let iconRect = NSRect(x: margin, y: margin, width: side, height: side)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let cg = ctx.cgContext
        // Bitmap contexts are addressed in pixels; scale so we can keep drawing in points.
        cg.scaleBy(x: scale, y: scale)

        let path = CGPath(
            roundedRect: iconRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        cg.saveGState()
        // CG shadow parameters are not affected by the CTM, so pre-multiply by scale.
        cg.setShadow(
            offset: CGSize(width: 0, height: -shadowYOffset * scale),
            blur: shadowBlur * scale,
            color: NSColor.black.withAlphaComponent(shadowAlpha).cgColor
        )
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        cg.saveGState()
        cg.addPath(path)
        cg.clip()
        image.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
        cg.restoreGState()          // drop the clip before closing the layer so the shadow is not clipped
        cg.endTransparencyLayer()
        cg.restoreGState()
        NSGraphicsContext.restoreGraphicsState()

        let out = NSImage(size: size)
        out.addRepresentation(rep)
        cache[cacheKey] = out
        return out
    }
}

struct PilotCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private let padding: CGFloat
    private let accentTint: Color?
    private let fillHeight: Bool
    @ViewBuilder private let content: () -> Content

    init(
        padding: CGFloat = 14,
        accentTint: Color? = nil,
        fillHeight: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.padding = padding
        self.accentTint = accentTint
        self.fillHeight = fillHeight
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .frame(
                maxWidth: .infinity,
                maxHeight: fillHeight ? .infinity : nil,
                alignment: fillHeight ? .topLeading : .leading
            )
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(surfaceFill)
                    .shadow(
                        color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.05),
                        radius: 8,
                        x: 0,
                        y: 2
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(borderStroke, lineWidth: 1)
            )
    }

    private var surfaceFill: some ShapeStyle {
        let base = colorScheme == .dark
            ? Color(NSColor.controlBackgroundColor).opacity(0.92)
            : Color(NSColor.windowBackgroundColor).opacity(0.96)
        if let accentTint {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        accentTint.opacity(colorScheme == .dark ? 0.12 : 0.06),
                        base
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(base)
    }

    private var borderStroke: Color {
        if let accentTint {
            return accentTint.opacity(colorScheme == .dark ? 0.28 : 0.22)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08)
    }
}

struct PilotRecessedBox<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private let padding: CGFloat
    @ViewBuilder private let content: () -> Content

    init(padding: CGFloat = 10, @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.035)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.06), lineWidth: 1)
            )
    }
}

struct PilotStatusPill: View {
    let text: String
    let color: Color
    var showDot: Bool = true
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
            } else if showDot {
                Circle()
                    .fill(color)
                    .frame(width: 6.5, height: 6.5)
            }
            Text(text)
                .font(.caption.weight(.medium))
                .fontDesign(.rounded)
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.12))
        .overlay(
            Capsule()
                .strokeBorder(color.opacity(0.24), lineWidth: 1)
        )
        .clipShape(Capsule())
    }
}

struct PilotMetricTile: View {
    let title: String
    let value: String
    let subtitle: String
    var icon: String? = nil
    var tint: Color = .accentColor
    var compact: Bool = false

    var body: some View {
        PilotCard(padding: compact ? 9 : 12) {
            VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                HStack(spacing: compact ? 5 : 6) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: compact ? 9.5 : 10, weight: .semibold))
                            .foregroundStyle(tint)
                            .frame(width: compact ? 16 : 18, height: compact ? 16 : 18)
                            .background(tint.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: compact ? 4.5 : 5, style: .continuous))
                    }
                    Text(title)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(value)
                    .font(.system(compact ? .headline : .title3, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

struct PilotRingGauge: View {
    let fraction: Double
    let tint: Color
    var size: CGFloat = 68
    var lineWidth: CGFloat = 6.5

    private var clamped: Double {
        min(max(fraction, 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: clamped)
                .stroke(
                    AngularGradient(
                        colors: [tint.opacity(0.75), tint],
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(270)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.35), value: clamped)

            Text("\(Int((clamped * 100).rounded()))%")
                .font(.system(size: size * 0.23, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(width: size, height: size)
    }
}

struct PilotLinearBar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 7

    private var clamped: Double {
        min(max(fraction, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.8), tint],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: clamped > 0 ? max(height, geo.size.width * clamped) : 0)
                    .animation(.easeOut(duration: 0.25), value: clamped)
            }
        }
        .frame(height: height)
    }
}

struct PilotHealthChainView: View {
    @Environment(\.appLanguage) private var lang
    let report: ProxyHealthReport
    let config: ProxyConfig

    var body: some View {
        HStack(spacing: 6) {
            stepNode(
                label: "1. TCP",
                detail: ":\(config.hookPort)",
                passed: report.level == .checking ? nil : report.tcpReachable
            )
            arrowSeparator
            stepNode(
                label: "2. SOCKS5",
                detail: "05 01 00",
                passed: report.level == .checking ? nil : report.socks5HandshakeOK
            )
            arrowSeparator
            stepNode(
                label: L10n.t("3. 外网", "3. Net", lang),
                detail: report.latencyMs.map { "\($0) ms" } ?? "204",
                passed: report.level == .checking ? nil : report.internetReachable
            )
            arrowSeparator
            stepNode(
                label: "ENV",
                detail: "\(config.envScheme):\(config.envPort)",
                passed: report.level == .checking ? nil : report.envPortReachable
            )
        }
    }

    private var arrowSeparator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    private func stepNode(label: String, detail: String, passed: Bool?) -> some View {
        let color: Color = {
            guard let passed else { return .secondary }
            return passed ? .green : .red
        }()
        let icon: String = {
            guard let passed else { return "circle.dotted" }
            return passed ? "checkmark.circle.fill" : "xmark.circle.fill"
        }()

        return HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(passed == nil ? 0.06 : 0.09))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(color.opacity(passed == nil ? 0.14 : 0.22), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct PilotAmbientBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    var tint: Color = .accentColor

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(NSColor.windowBackgroundColor)

            RadialGradient(
                colors: [
                    tint.opacity(colorScheme == .dark ? 0.10 : 0.06),
                    Color.clear
                ],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 420
            )
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}
