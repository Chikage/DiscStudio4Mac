import BRCore
import SwiftUI

enum StudioStyle {
    static let accent = Color(
        nsColor: NSColor(name: "BRAccent") { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return .systemOrange
            }
            return NSColor(srgbRed: 0.64, green: 0.29, blue: 0.02, alpha: 1)
        })
    static let background = Color(nsColor: .underPageBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let border = Color.primary.opacity(0.08)
}

struct StudioPanel<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol)
                .font(.headline).foregroundStyle(.secondary)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(StudioStyle.border))
    }
}

struct StatusPill: View {
    let title: String
    var color: Color = .secondary
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(title).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(color.opacity(0.10), in: Capsule())
    }
}

struct MetricView: View {
    let title: String
    let value: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct KeyValueRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing)
        }.font(.subheadline)
    }
}

#Preview {
    StudioPanel(title: "实时监控", symbol: "waveform.path") {
        MetricView(title: "写入速度", value: "10.8 MB/s", detail: "设备报告值")
    }.padding().frame(width: 360)
}
