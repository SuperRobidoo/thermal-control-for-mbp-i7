//
//  HistoricalGraphView.swift
//  Thermal Control
//

import SwiftUI
import Charts

struct HistoricalGraphView: View {
    @EnvironmentObject private var monitor: ThermalMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var windowHours: Double = 1.0 // hours to display

    private var readings: [TemperatureReading] {
        let cutoff = Date().addingTimeInterval(-windowHours * 3600)
        return monitor.recentReadings.filter { $0.timestamp >= cutoff }
    }

    private var xDomain: ClosedRange<Date> {
        let end = Date()
        let start = end.addingTimeInterval(-windowHours * 3600)
        return start...end
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if readings.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "thermometer")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("No Data Yet")
                            .font(.headline)
                        Text("Temperature history will appear here once monitoring starts.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    // Time window picker
                    Picker("Window", selection: $windowHours) {
                        Text("15 min").tag(0.25)
                        Text("30 min").tag(0.5)
                        Text("1 hour").tag(1.0)
                        Text("2 hours").tag(2.0)
                        Text("3 hours").tag(3.0)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    Chart {
                        // Throttling highlight areas
                        ForEach(throttleRanges(), id: \.lowerBound) { range in
                            RectangleMark(
                                xStart: .value("Start", range.lowerBound),
                                xEnd: .value("End", range.upperBound),
                                yStart: nil,
                                yEnd: nil
                            )
                            .foregroundStyle(.red.opacity(0.08))
                        }

                        // CPU temperature line
                        ForEach(readings) { reading in
                            LineMark(
                                x: .value("Time", reading.timestamp),
                                y: .value("°C", reading.cpuTemperature)
                            )
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.green, Color(red: 1, green: 0.6, blue: 0), .red],
                                    startPoint: .bottom,
                                    endPoint: .top
                                )
                            )
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        }

                        // GPU temperature line (dashed blue)
                        ForEach(readings.filter { $0.gpuTemperature > 0 }) { reading in
                            LineMark(
                                x: .value("Time", reading.timestamp),
                                y: .value("°C", reading.gpuTemperature)
                            )
                            .foregroundStyle(Color.blue.opacity(0.7))
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        }

                        // CPU throttle points
                        ForEach(readings.filter { $0.isThrottling }) { reading in
                            PointMark(
                                x: .value("Time", reading.timestamp),
                                y: .value("°C", reading.cpuTemperature)
                            )
                            .foregroundStyle(.red)
                            .symbolSize(30)
                        }

                        // Reference lines
                        RuleMark(y: .value("Warning", 85))
                            .foregroundStyle(.orange.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                            .annotation(position: .trailing) {
                                Text("85°C").font(.caption2).foregroundStyle(.orange)
                            }
                        RuleMark(y: .value("Caution", 60))
                            .foregroundStyle(.yellow.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                            .annotation(position: .trailing) {
                                Text("60°C").font(.caption2).foregroundStyle(.secondary)
                            }
                    }
                    .chartYScale(domain: 0...120)
                    .chartXScale(domain: xDomain)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .minute, count: 15)) { value in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel(format: .dateTime.hour().minute())
                        }
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel { Text("\(value.as(Int.self) ?? 0)°C") }
                        }
                    }
                    .frame(height: 280)
                    .padding(.horizontal)

                    // Legend
                    HStack(spacing: 16) {
                        legendItem(color: .red.opacity(0.12), label: "CPU (gradient line)")
                        legendItem(color: .blue.opacity(0.7), label: "GPU (dashed)")
                        legendItem(color: .red.opacity(0.3), label: "Throttling event")
                        legendItem(color: .orange.opacity(0.7), label: "85°C warning")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                }
            }
            .navigationTitle("Temperature History")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .status) {
                    Text("\(readings.count) readings · last \(windowHours < 1 ? "\(Int(windowHours * 60)) min" : "\(Int(windowHours)) hr")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func throttleRanges() -> [ClosedRange<Date>] {
        var ranges: [ClosedRange<Date>] = []
        var start: Date?
        for reading in readings {
            if reading.isThrottling && start == nil {
                start = reading.timestamp
            } else if !reading.isThrottling, let s = start {
                ranges.append(s...reading.timestamp)
                start = nil
            }
        }
        if let s = start, let last = readings.last {
            ranges.append(s...last.timestamp)
        }
        return ranges
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 14, height: 8)
            Text(label)
        }
    }
}

#Preview {
    HistoricalGraphView()
        .environmentObject(ThermalMonitor())
        .frame(width: 650, height: 450)
}
