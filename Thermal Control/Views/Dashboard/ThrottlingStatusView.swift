//
//  ThrottlingStatusView.swift
//  Thermal Control
//

import SwiftUI

struct ThrottlingStatusView: View {
    var pressure: ThermalPressure

    private var statusColor: Color {
        switch pressure {
        case .nominal: return .green
        case .moderate: return .yellow
        case .heavy: return .orange
        case .trapping: return .red
        }
    }

    private var iconName: String {
        switch pressure {
        case .nominal: return "checkmark.circle.fill"
        case .moderate: return "exclamationmark.triangle.fill"
        case .heavy: return "flame.fill"
        case .trapping: return "exclamationmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .foregroundStyle(statusColor)
            Text(pressure.displayName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(pressure.isThrottling ? statusColor : .secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(statusColor.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(statusColor.opacity(0.3), lineWidth: 1))
        .animation(.easeInOut(duration: 0.3), value: pressure)
    }
}

#Preview {
    VStack(spacing: 12) {
        ThrottlingStatusView(pressure: .nominal)
        ThrottlingStatusView(pressure: .moderate)
        ThrottlingStatusView(pressure: .heavy)
        ThrottlingStatusView(pressure: .trapping)
    }
    .padding()
}
