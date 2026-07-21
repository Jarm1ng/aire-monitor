import AppKit
import SwiftUI

/// Shared design tokens for the AIRE Monitor surfaces.
/// Internal so the menu bar and future surfaces can reuse the same language.
enum AIRETheme {
    static let pageBackground = Color(nsColor: .windowBackgroundColor)
    static let panelBackground = Color(nsColor: .controlBackgroundColor)
    static let border = Color.primary.opacity(0.08)
    static let mutedFill = Color.primary.opacity(0.035)
    static let cardShadow = Color.black.opacity(0.08)
    static let gpu = Color.cyan
    static let cpu = Color.teal

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
            AIRETheme.pageBackground
            LinearGradient(
                colors: [
                    Color.primary.opacity(0.035),
                    AIRETheme.gpu.opacity(0.035),
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
                                AIRETheme.glassSheen(for: colorScheme).opacity(isHovered ? 1 : 0.72),
                                AIRETheme.glassSheen(for: colorScheme).opacity(0.04)
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
                                AIRETheme.glassEdge(for: colorScheme, emphasized: isHovered),
                                AIRETheme.border,
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
            .shadow(color: AIRETheme.cardShadow.opacity(isHovered ? 1 : 0.68), radius: isHovered ? 14 : 9, x: 0, y: isHovered ? 7 : 4)
            .scaleEffect(isInteractive && isHovered ? 1.012 : 1)
            .onHover { hovering in
                guard isInteractive else { return }
                isHovered = hovering
            }
            .animation(AIRETheme.softSpring, value: isHovered)
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

struct AIRELogoMark: View {
    var cornerRadius: CGFloat = 8

    @Environment(\.colorScheme) private var colorScheme

    /// Loaded once; body no longer performs disk I/O on every render.
    @MainActor private static let cachedLogo: NSImage? = {
        if let url = Bundle.main.url(forResource: "AIRELogo", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        // Fallback that does not depend on the current working directory.
        if let root = ProcessInfo.processInfo.environment["AIRE_PROJECT_ROOT"] {
            return NSImage(contentsOfFile: "\(root)/assets/AIRELogo.png")
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
                    .foregroundStyle(AIRETheme.gpu)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AIRETheme.gpu.opacity(0.12))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(AIRETheme.chipStroke(for: colorScheme), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 8, x: 0, y: 3)
        .accessibilityLabel("AIRE logo")
    }
}
