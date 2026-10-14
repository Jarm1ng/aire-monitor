import AppKit
import HPCCore
import SwiftUI

struct WidgetIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 25, height: 25)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? WidgetPalette.fillStrong : WidgetPalette.fill)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(WidgetPalette.border, lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct StatusChip: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .fontWeight(.semibold)
            Text(value)
                .foregroundStyle(.secondary)
                .truncationMode(.middle)
        }
        .font(.caption2)
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: 200, alignment: .leading)
        .background(color.opacity(0.10), in: Capsule())
        .background(.thinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(color.opacity(0.15), lineWidth: 1)
        )
    }
}

struct RingMeter: View {
    let value: Double
    let color: Color
    let label: String
    var lineWidth: CGFloat = 8

    var body: some View {
        ZStack {
            Circle()
                .stroke(WidgetPalette.fillStrong, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(value, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.32), value: value)
            Text(label)
                .font(.caption.monospacedDigit().weight(.bold))
                .singleLine()
        }
        .padding(lineWidth / 2)
    }
}

/// One cluster's GPUs as a single bar, segment by segment from GPUFleet:
/// allocated in the usage colour, stranded (idle on a node whose CPUs are
/// full) in grey, unknown allocation in a fainter grey, idle on unavailable
/// nodes in red, and the free GPUs in green. Segments sit on a neutral track
/// rather than a green one, so nothing reads as free unless it is: without
/// any GPU data the bar is just the neutral track (unknown is not zero).
struct GPUUsageBar: View {
    let allocated: Int
    let stranded: Int
    let unknown: Int
    let unavailable: Int
    let free: Int
    let total: Int
    let color: Color

    init(fleet: GPUFleet, color: Color) {
        allocated = fleet.allocated
        stranded = fleet.stranded
        unknown = fleet.unknown
        unavailable = fleet.unavailable
        free = fleet.idle
        total = fleet.total
        self.color = color
    }

    private func fraction(_ value: Int) -> Double {
        guard total > 0 else {
            return 0
        }
        return min(max(Double(value) / Double(total), 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let segments: [(Int, Color)] = [
                (allocated, color.opacity(0.88)),
                (stranded, WidgetPalette.neutral.opacity(0.65)),
                (unknown, WidgetPalette.neutral.opacity(0.30)),
                (unavailable, WidgetPalette.red.opacity(0.62)),
                (free, WidgetPalette.green.opacity(0.30))
            ]
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(WidgetPalette.fillStrong)
                HStack(spacing: 0) {
                    ForEach(segments.indices, id: \.self) { index in
                        Rectangle()
                            .fill(segments[index].1)
                            .frame(width: width * fraction(segments[index].0))
                    }
                }
                .frame(width: width, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .animation(.easeInOut(duration: 0.32), value: allocated)
                .animation(.easeInOut(duration: 0.32), value: free)
                .animation(.easeInOut(duration: 0.32), value: unavailable)
            }
        }
        .frame(height: 8)
    }
}

struct JobCountPill: View {
    let title: String
    /// nil while the cluster has no snapshot yet.
    let value: Int?
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Text(value.map(String.init) ?? "–")
                .monospacedDigit()
                .fontWeight(.semibold)
        }
        .font(.caption2)
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
        .background(.thinMaterial, in: Capsule())
        .foregroundStyle(color)
        .overlay(
            Capsule()
                .stroke(color.opacity(0.14), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value.map(String.init) ?? "unknown")
    }
}

/// The cluster's headline job: name first (it is what the user recognises),
/// then partition and elapsed time.
struct TopJobRow: View {
    let job: Job
    let clusterName: String

    private var elapsed: String {
        job.elapsed.isEmpty ? missingValuePlaceholder : job.elapsed
    }

    private var title: String {
        job.name.isEmpty ? "Job \(job.displayJobID)" : job.name
    }

    var body: some View {
        let state = job.jobState
        HStack(spacing: 5) {
            Circle()
                .fill(WidgetPalette.jobStateColor(state))
                .frame(width: 6, height: 6)
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Text(job.partition)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(elapsed)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .help("\(clusterName) job \(job.displayJobID) · \(state.label) · \(job.partition) · \(elapsed)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(clusterName) top job \(title)")
        .accessibilityValue("\(state.label.lowercased()), partition \(job.partition), elapsed \(elapsed)")
    }
}

struct GPUHeatmapStrip: View {
    let nodes: [NodeSummary]
    let clusterName: String

    var body: some View {
        GeometryReader { proxy in
            let count = max(nodes.count, 1)
            // Tighter gaps for large pools so every node keeps a visible cell.
            let spacing: CGFloat = count > 24 ? 1.5 : 3
            let width = max((proxy.size.width - spacing * CGFloat(count - 1)) / CGFloat(count), 2)
            if nodes.isEmpty {
                RoundedRectangle(cornerRadius: 3)
                    .fill(WidgetPalette.fillStrong)
                    .frame(height: proxy.size.height)
            } else {
                // Node names are unique within one cluster, and each row
                // draws only its own cluster's nodes.
                HStack(spacing: spacing) {
                    ForEach(nodes, id: \.node) { node in
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(WidgetPalette.heatmapColor(for: node))
                            .frame(width: width, height: proxy.size.height)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2.5)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                            .help(help(for: node))
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            }
        }
    }

    private func help(for node: NodeSummary) -> String {
        let info = node.stateInfo
        let allocation = node.knownGPUAllocated.map { "\($0)/\(node.gpuCount) GPU allocated" }
            ?? "\(node.gpuCount) GPU, allocation unknown"
        var details = [info.displayLabel] + info.flagDescriptions
        if info.isAvailable && node.cpusFull {
            details.append("every CPU allocated, so no new job can start")
        }
        return "\(clusterName) \(node.node): \(allocation), " + details.joined(separator: ", ")
    }
}

struct WidgetVisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}
