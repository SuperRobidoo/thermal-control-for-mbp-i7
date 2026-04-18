//
//  HistoricalGraphView.swift
//  Thermal Control
//

import SwiftUI
import Charts

struct HistoricalGraphView: View {
    @EnvironmentObject private var monitor: ThermalMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var windowHours: Double = 0.5

    // Cached, downsampled data — only recomputed when source changes or window changes
    @State private var displayedReadings: [TemperatureReading] = []
    @State private var throttleRanges:    [ClosedRange<Date>]  = []
    @State private var stats: TempStats = .empty

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {

                // ── Time window picker ──
                HStack {
                    Text("Window").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    Picker("", selection: $windowHours) {
                        Text("15 min").tag(0.25)
                        Text("30 min").tag(0.5)
                        Text("1 hour").tag(1.0)
                        Text("2 hours").tag(2.0)
                        Text("3 hours").tag(3.0)
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

                if displayedReadings.isEmpty {
                    emptyState
                } else {
                    // ── Stats row ──
                    statsRow
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)

                    // ── Chart ──
                    chartView
                        .padding(.horizontal, 16)

                    // ── Legend ──
                    legendRow
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                }
            }
            .navigationTitle("Temperature History")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .status) {
                    if !displayedReadings.isEmpty {
                        Text(verbatim: "\(displayedReadings.count) pts · \(windowLabel)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear { refresh() }
        .onChange(of: monitor.recentReadings.count) { _ in refresh() }
        .onChange(of: windowHours) { _ in refresh() }
    }

    // MARK: - Sub-views

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 48)).foregroundStyle(.secondary)
            Text("No Data Yet").font(.headline)
            Text("Temperature history will appear here once monitoring starts.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var statsRow: some View {
        HStack(spacing: 0) {
            statCell(label: "Min", value: String(format: "%.1f°C", stats.min), color: .green)
            Divider().frame(height: 32)
            statCell(label: "Avg", value: String(format: "%.1f°C", stats.avg), color: .secondary)
            Divider().frame(height: 32)
            statCell(label: "Max", value: String(format: "%.1f°C", stats.max), color: stats.max >= 90 ? .red : stats.max >= 75 ? .orange : .secondary)
            Divider().frame(height: 32)
            statCell(label: "Throttle events", value: "\(stats.throttleEventCount)", color: stats.throttleEventCount > 0 ? .red : .green)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private func statCell(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var chartView: some View {
        let yMin = max(30.0, stats.chartMin - 5)
        let yMax = min(115.0, stats.chartMax + 8)

        Chart {
            // Throttling highlight bands — very subtle, just a hint
            ForEach(Array(throttleRanges.enumerated()), id: \.offset) { _, range in
                RectangleMark(
                    xStart: .value("S", range.lowerBound),
                    xEnd:   .value("E", range.upperBound),
                    yStart: .value("y0", yMin),
                    yEnd:   .value("y1", yMax)
                )
                .foregroundStyle(Color.red.opacity(0.06))
            }

            // 85°C warning line
            if yMax >= 85 {
                RuleMark(y: .value("Hot", 85))
                    .foregroundStyle(Color(red: 1.0, green: 0.75, blue: 0.0).opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    .annotation(position: .trailing, spacing: 4) {
                        Text("85°C").font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color(red: 1.0, green: 0.75, blue: 0.0).opacity(0.8))
                    }
            }

            // GPU temperature line — steel blue, dashed
            ForEach(displayedReadings.filter { $0.gpuTemperature > 0 }) { r in
                LineMark(
                    x: .value("Time", r.timestamp),
                    y: .value("°C", r.gpuTemperature),
                    series: .value("Series", "GPU")
                )
                .foregroundStyle(Color(red: 0.35, green: 0.72, blue: 0.95))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
            }

            // CPU temperature line — single consistent amber, always readable
            ForEach(displayedReadings) { r in
                LineMark(
                    x: .value("Time", r.timestamp),
                    y: .value("°C", r.cpuTemperature),
                    series: .value("Series", "CPU")
                )
                .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.1))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
            }

            // Throttling markers — white ring with red fill, clearly visible on any background
            ForEach(displayedReadings.filter { $0.isThrottling }) { r in
                PointMark(
                    x: .value("Time", r.timestamp),
                    y: .value("°C", r.cpuTemperature)
                )
                .foregroundStyle(Color(red: 1.0, green: 0.22, blue: 0.18))
                .symbolSize(28)
                .symbol(.circle)
            }
        }
        .chartYScale(domain: yMin...yMax)
        .chartXScale(domain: xDomain)
        .chartXAxis {
            AxisMarks(values: xAxisStride) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisTick()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartYAxis {
            AxisMarks(values: .stride(by: yAxisStride(yMin: yMin, yMax: yMax))) { val in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisTick()
                AxisValueLabel { Text(verbatim: "\(val.as(Int.self) ?? 0)°C") }
            }
        }
        .frame(height: 260)
    }

    private var legendRow: some View {
        HStack(spacing: 20) {
            legendLine(color: Color(red: 1.0, green: 0.55, blue: 0.1), dash: false, label: "CPU")
            legendLine(color: Color(red: 0.35, green: 0.72, blue: 0.95), dash: true, label: "GPU")
            HStack(spacing: 5) {
                Circle()
                    .fill(Color(red: 1.0, green: 0.22, blue: 0.18))
                    .frame(width: 8, height: 8)
                Text("Throttling").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 5) {
                Rectangle()
                    .fill(Color(red: 1.0, green: 0.75, blue: 0.0).opacity(0.55))
                    .frame(width: 16, height: 1.5)
                Text("85°C warning").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func legendLine(color: Color, dash: Bool, label: String) -> some View {
        HStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 1)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: dash ? [4, 2] : []))
                    .foregroundStyle(color)
                    .frame(width: 20, height: 2)
            }
            .frame(width: 20, height: 10)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Data refresh (runs off main-thread for heavy computation)

    private func refresh() {
        let source = monitor.recentReadings
        let window = windowHours
        DispatchQueue.global(qos: .userInitiated).async {
            let cutoff  = Date().addingTimeInterval(-window * 3600)
            let raw     = source.filter { $0.timestamp >= cutoff }
            let sampled = downsample(raw, maxPoints: 250)
            let ranges  = buildThrottleRanges(sampled)
            let s       = buildStats(raw)   // stats from full data, not downsampled
            DispatchQueue.main.async {
                displayedReadings = sampled
                throttleRanges    = ranges
                stats             = s
            }
        }
    }

    private func downsample(_ data: [TemperatureReading], maxPoints: Int) -> [TemperatureReading] {
        guard data.count > maxPoints else { return data }
        let step = data.count / maxPoints
        return stride(from: 0, to: data.count, by: step).map { data[$0] }
    }

    private func buildThrottleRanges(_ data: [TemperatureReading]) -> [ClosedRange<Date>] {
        var ranges: [ClosedRange<Date>] = []
        var start: Date?
        for r in data {
            if r.isThrottling, start == nil { start = r.timestamp }
            else if !r.isThrottling, let s = start { ranges.append(s...r.timestamp); start = nil }
        }
        if let s = start, let last = data.last { ranges.append(s...last.timestamp) }
        return ranges
    }

    private func buildStats(_ data: [TemperatureReading]) -> TempStats {
        guard !data.isEmpty else { return .empty }
        let cpuTemps  = data.map(\.cpuTemperature)
        let gpuTemps  = data.compactMap { $0.gpuTemperature > 0 ? $0.gpuTemperature : nil }
        let allTemps  = cpuTemps + gpuTemps
        let minT      = cpuTemps.min() ?? 0
        let maxT      = cpuTemps.max() ?? 0
        let avgT      = cpuTemps.reduce(0, +) / Double(cpuTemps.count)
        let chartMin  = allTemps.min() ?? minT
        let chartMax  = allTemps.max() ?? maxT
        // Count distinct throttling events (transitions into throttling state)
        var eventCount = 0
        var wasThrottling = false
        for r in data {
            if r.isThrottling && !wasThrottling { eventCount += 1 }
            wasThrottling = r.isThrottling
        }
        return TempStats(min: minT, avg: avgT, max: maxT,
                         chartMin: chartMin, chartMax: chartMax,
                         throttleEventCount: eventCount)
    }

    // MARK: - Helpers

    private var xDomain: ClosedRange<Date> {
        Date().addingTimeInterval(-windowHours * 3600)...Date()
    }

    private var xAxisStride: AxisMarkValues {
        switch windowHours {
        case ...0.26: return .stride(by: .minute, count: 5)
        case ...0.51: return .stride(by: .minute, count: 10)
        case ...1.01: return .stride(by: .minute, count: 15)
        case ...2.01: return .stride(by: .minute, count: 30)
        default:      return .stride(by: .hour,   count: 1)
        }
    }

    private func yAxisStride(yMin: Double, yMax: Double) -> Double {
        let range = yMax - yMin
        if range <= 20 { return 5 }
        if range <= 40 { return 10 }
        return 15
    }

    private var windowLabel: String {
        switch windowHours {
        case 0.25: return "15 min"
        case 0.5:  return "30 min"
        case 1.0:  return "1 hr"
        case 2.0:  return "2 hr"
        default:   return "3 hr"
        }
    }
}

// MARK: - Stats model

private struct TempStats {
    let min: Double
    let avg: Double
    let max: Double
    let chartMin: Double
    let chartMax: Double
    let throttleEventCount: Int

    static let empty = TempStats(min: 0, avg: 0, max: 0,
                                 chartMin: 40, chartMax: 100,
                                 throttleEventCount: 0)
}

#Preview {
    HistoricalGraphView()
        .environmentObject(ThermalMonitor())
        .frame(width: 650, height: 480)
}
