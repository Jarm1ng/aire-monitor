import SwiftUI

/// Monogram disc in the cluster's identity color. Used wherever data from
/// several clusters could otherwise be confused.
struct ClusterBadge: View {
    let profile: ClusterProfile
    var size: CGFloat = 22

    var body: some View {
        Text(profile.monogram)
            .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(profile.accent.color.gradient, in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
            // The cluster name is printed beside the badge almost everywhere;
            // labelling the badge too makes VoiceOver say it twice.
            .accessibilityHidden(true)
    }
}

/// Compact "● Live" style pill for a cluster's connection state.
struct ConnectionStatePill: View {
    let state: ClusterConnectionState

    var body: some View {
        HStack(spacing: 5) {
            if state.isBusy {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(state.color)
                    .frame(width: 7, height: 7)
            }
            Text(state.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(state == .live ? Color.primary : Color.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(state.color.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(state.color.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection: \(state.label)")
    }
}

/// "Calder" label with badge, for section headers that need cluster context.
struct ClusterTitle: View {
    let profile: ClusterProfile
    var font: Font = .headline

    var body: some View {
        HStack(spacing: 7) {
            ClusterBadge(profile: profile, size: 18)
            Text(profile.displayName)
                .font(font)
        }
        .accessibilityElement(children: .combine)
    }
}
