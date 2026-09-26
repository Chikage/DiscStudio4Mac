import BRCore
import Charts
import SwiftUI

struct SpeedChartView: View {
    var store: BurnStore

    var body: some View {
        StudioPanel(title: "实时写入速度", symbol: "speedometer") {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let stale = store.lastStatusAt.map { context.date.timeIntervalSince($0) > 5 } ?? false
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(!stale ? store.snapshot.speedKB.map { String(format: "%.2f", $0 / 1000) } ?? "—" : "—")
                        .font(.largeTitle.weight(.semibold)).monospacedDigit()
                    Text("MB/s").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if let factor = store.snapshot.speedX, !stale {
                        Text(String(format: "%.1f×", factor)).font(.headline.monospaced()).foregroundStyle(
                            StudioStyle.accent)
                    }
                }
                Text(stale && store.isBusy ? "等待新的设备读数…" : store.isDemo ? "模拟读数" : "设备实时报告 · 1 MB = 1,000,000 字节")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Chart(store.samples) { sample in
                AreaMark(x: .value("已用秒数", sample.seconds), y: .value("MB/s", sample.megabytesPerSecond))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [StudioStyle.accent.opacity(0.22), StudioStyle.accent.opacity(0.01)],
                            startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("已用秒数", sample.seconds), y: .value("MB/s", sample.megabytesPerSecond))
                    .foregroundStyle(StudioStyle.accent).lineStyle(StrokeStyle(lineWidth: 2))
            }
            .chartYScale(domain: 0...max(16, (store.samples.map(\.megabytesPerSecond).max() ?? 0) * 1.2))
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
                    AxisGridLine().foregroundStyle(StudioStyle.border)
                    AxisValueLabel().foregroundStyle(.secondary)
                }
            }
            .frame(height: 72)
            .overlay {
                if store.samples.isEmpty {
                    Text("等待写入速度数据").font(.caption).foregroundStyle(.secondary)
                        .padding(8).background(StudioStyle.surface.opacity(0.9), in: Capsule())
                }
            }
            .accessibilityLabel("最近 180 次写入速度采样曲线")
        }
    }
}

struct BufferView: View {
    var store: BurnStore
    var body: some View {
        StudioPanel(title: "设备缓冲区", symbol: "memorychip") {
            VStack(alignment: .leading, spacing: 8) {
                Text(store.selectedDevice?.bufferCapacity.map(BurnFormat.bytes) ?? "—")
                    .font(.title.weight(.semibold)).monospacedDigit()
                Text("设备报告的缓冲区容量").font(.caption).foregroundStyle(.secondary)
            }
            KeyValueRow(label: "欠载保护", value: protection)
            KeyValueRow(label: "实时占用", value: "系统未提供")
            Text("macOS 公开接口不提供占用率。支持的设备会启用欠载保护。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var protection: String {
        guard let supported = store.selectedDevice?.underrunProtection else { return "未报告" }
        return supported ? store.isBusy ? "已请求启用" : "设备支持" : "设备不支持"
    }
}

#Preview {
    HStack {
        SpeedChartView(store: BurnStore())
        BufferView(store: BurnStore())
    }.padding().frame(width: 750)
}
