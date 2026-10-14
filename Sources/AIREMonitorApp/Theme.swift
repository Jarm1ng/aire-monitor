import HPCCore
import AppKit
import SwiftUI

/// Shared design tokens for the Leeds HPC Monitor surfaces.
/// Internal so the menu bar and future surfaces can reuse the same language.
enum AppTheme {
    static let pageBackground = Color(nsColor: .windowBackgroundColor)
    static let panelBackground = Color(nsColor: .controlBackgroundColor)
    static let border = Color.primary.opacity(0.08)
    static let mutedFill = Color.primary.opacity(0.035)
    static let cardShadow = Color.black.opacity(0.08)
    /// Identity colours for the two resource kinds. They mark what a figure
    /// is about (GPU or CPU, and the "in use" share of a meter) and never
    /// encode health; health uses `StatusTone.color`.
    static let gpu = Color.cyan
    static let cpu = Color.teal

    /// Capacity meter segments, shared by every GPU/CPU meter so "idle",
    /// "stranded" and "unavailable" look the same on each screen.
    /// Idle is the free share a new job could use.
    static let idle = Color.green
    /// Idle GPUs on nodes whose CPUs are all taken: idle-looking but
    /// unusable, so a muted grey rather than green.
    static let stranded = Color.gray.opacity(0.55)
    /// Resources on nodes that accept no work. Grey (`StatusTone.unavailable`),
    /// never red: red would read as "busy" next to a pressure-tinted meter.
    static let unavailable = StatusTone.unavailable.color

    static let softSpring = Animation.spring(response: 0.32, dampingFraction: 0.86)
    static let smoothEase = Animation.easeInOut(duration: 0.22)

    /// Top sheen used on glass cards; adapts so it stays visible on light backdrops.
    static func glassSheen(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.18) : Color.white.opacity(0.55)
    }

    /// Leading edge of the card hairline; dark hairline in light mode, light in dark mode.
    static func glassEdge(for scheme: ColorScheme, emphasized: Bool) -> Color {
        if scheme == .dark {
            return Color.white.opacity(emphasized ? 0.34 : 0.20)
        }
        return Color.black.opacity(emphasized ? 0.18 : 0.10)
    }

    /// Hairline used around chips and small controls.
    static func chipStroke(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.09)
    }
}

struct DashboardBackdrop: View {
    var body: some View {
        ZStack {
            AppTheme.pageBackground
            LinearGradient(
                colors: [
                    Color.primary.opacity(0.035),
                    AppTheme.gpu.opacity(0.035),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .allowsHitTesting(false)
        }
    }
}

struct GlassCardModifier: ViewModifier {
    let padding: CGFloat
    let cornerRadius: CGFloat
    let accent: Color
    let isInteractive: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content
            .padding(padding)
            .background {
                shape
                    .fill(.regularMaterial)
                    .overlay {
                        shape
                            .fill(accent.opacity(isHovered ? 0.095 : 0.045))
                    }
                    .overlay(alignment: .top) {
                        LinearGradient(
                            colors: [
                                AppTheme.glassSheen(for: colorScheme).opacity(isHovered ? 1 : 0.72),
                                AppTheme.glassSheen(for: colorScheme).opacity(0.04)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .clipShape(shape)
                    }
            }
            .overlay {
                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                AppTheme.glassEdge(for: colorScheme, emphasized: isHovered),
                                AppTheme.border,
                                accent.opacity(isHovered ? 0.24 : 0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .clipShape(shape)
            .contentShape(shape)
            .shadow(color: AppTheme.cardShadow.opacity(isHovered ? 1 : 0.68), radius: isHovered ? 14 : 9, x: 0, y: isHovered ? 7 : 4)
            .scaleEffect(isInteractive && isHovered ? 1.012 : 1)
            .onHover { hovering in
                guard isInteractive else { return }
                isHovered = hovering
            }
            .animation(AppTheme.softSpring, value: isHovered)
    }
}

extension View {
    func dashboardCard(padding: CGFloat = 12, accent: Color = .primary, isInteractive: Bool = false) -> some View {
        modifier(
            GlassCardModifier(
                padding: padding,
                cornerRadius: 10,
                accent: accent,
                isInteractive: isInteractive
            )
        )
    }
}

struct AppLogoMark: View {
    var cornerRadius: CGFloat = 8

    @Environment(\.colorScheme) private var colorScheme

    /// Loaded once; body no longer performs disk I/O on every render. The
    /// build scripts bundle only the cluster-neutral emblem (and rebuild the
    /// bundle from scratch each time), so there is no older artwork to fall
    /// back to.
    @MainActor private static let cachedLogo: NSImage? = {
        if let url = Bundle.main.url(forResource: "LeedsHPCMark", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        // Fallback that does not depend on the current working directory.
        let environment = ProcessInfo.processInfo.environment
        for key in ["HPC_PROJECT_ROOT", "AIRE_PROJECT_ROOT"] {
            if let root = environment[key],
               let image = NSImage(contentsOfFile: "\(root)/assets/LeedsHPCMark.png") {
                return image
            }
        }
        return nil
    }()

    var body: some View {
        Group {
            if let image = Self.cachedLogo {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "server.rack")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AppTheme.gpu)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppTheme.gpu.opacity(0.12))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(AppTheme.chipStroke(for: colorScheme), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 8, x: 0, y: 3)
        .accessibilityLabel("Leeds HPC Monitor logo")
    }
}

// MARK: - Legible tinted text

extension Color {
    /// The colour to use for TEXT drawn in this tint. System tints (green,
    /// orange, cyan…) are bright enough on dark backgrounds, but on light
    /// ones they measure about 2:1, far below the 4.5:1 WCAG minimum — so in
    /// light mode the tint is darkened until text in it reads at roughly
    /// 6:1 even on a tint-washed chip, keeping its hue. Fills, strokes, meters and icons keep the plain
    /// tint; only text needs this.
    func legibleText(in scheme: ColorScheme) -> Color {
        guard scheme == .light else {
            return self
        }
        if self == .secondary {
            return Color.primary.opacity(0.72)
        }
        if self == .primary {
            return self
        }
        var resolved = NSColor(self)
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            resolved = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        }
        guard let darker = resolved.blended(withFraction: 0.55, of: .black) else {
            return self
        }
        return Color(nsColor: darker)
    }
}

// MARK: - Status tones

extension StatusTone {
    /// Status colours, distinct from identity colours (cluster accents,
    /// storage kinds, GPU/CPU), which never encode health.
    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        case .unavailable: return .gray
        }
    }
}

// MARK: - GPU pools

/// How a pool's idle-GPU count is coloured on the overview tile, the
/// cluster header chip and the menu bar row.
extension GPUPool {
    /// Colour of the idle count: HPCCore's `idleTone`, the one rule every
    /// surface shares — green with idle GPUs, orange (never red) when the
    /// pool is known to be full, grey when nothing can start there (every
    /// node out of service) or while `idleIsUnknown`.
    var idleTint: Color {
        idleTone.color
    }
}
