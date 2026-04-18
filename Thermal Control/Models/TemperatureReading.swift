//
//  TemperatureReading.swift
//  Thermal Control
//

import Foundation

struct TemperatureReading: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let cpuTemperature: Double
    let thermalPressure: String
    let isThrottling: Bool

    // Extended SMC metrics
    let cpuThermalLevel: Int
    let gpuThermalLevel: Int
    let ioThermalLevel: Int
    let fanRPM: Int
    let gpuTemperature: Double
    let cpuPLimit: Double
    let gpuPLimitInt: Double
    let gpuPLimitExt: Double
    let prochotCount: Int

    init(
        timestamp: Date,
        cpuTemperature: Double,
        thermalPressure: String,
        isThrottling: Bool,
        cpuThermalLevel: Int = 0,
        gpuThermalLevel: Int = 0,
        ioThermalLevel: Int = 0,
        fanRPM: Int = 0,
        gpuTemperature: Double = 0,
        cpuPLimit: Double = 0,
        gpuPLimitInt: Double = 0,
        gpuPLimitExt: Double = 0,
        prochotCount: Int = 0
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.cpuTemperature = cpuTemperature
        self.thermalPressure = thermalPressure
        self.isThrottling = isThrottling
        self.cpuThermalLevel = cpuThermalLevel
        self.gpuThermalLevel = gpuThermalLevel
        self.ioThermalLevel = ioThermalLevel
        self.fanRPM = fanRPM
        self.gpuTemperature = gpuTemperature
        self.cpuPLimit = cpuPLimit
        self.gpuPLimitInt = gpuPLimitInt
        self.gpuPLimitExt = gpuPLimitExt
        self.prochotCount = prochotCount
    }

    // Custom decoding with defaults so old JSON history still loads
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        cpuTemperature = try c.decode(Double.self, forKey: .cpuTemperature)
        thermalPressure = try c.decode(String.self, forKey: .thermalPressure)
        isThrottling = try c.decode(Bool.self, forKey: .isThrottling)
        cpuThermalLevel = try c.decodeIfPresent(Int.self, forKey: .cpuThermalLevel) ?? 0
        gpuThermalLevel = try c.decodeIfPresent(Int.self, forKey: .gpuThermalLevel) ?? 0
        ioThermalLevel  = try c.decodeIfPresent(Int.self, forKey: .ioThermalLevel) ?? 0
        fanRPM          = try c.decodeIfPresent(Int.self, forKey: .fanRPM) ?? 0
        gpuTemperature  = try c.decodeIfPresent(Double.self, forKey: .gpuTemperature) ?? 0
        cpuPLimit       = try c.decodeIfPresent(Double.self, forKey: .cpuPLimit) ?? 0
        gpuPLimitInt    = try c.decodeIfPresent(Double.self, forKey: .gpuPLimitInt) ?? 0
        gpuPLimitExt    = try c.decodeIfPresent(Double.self, forKey: .gpuPLimitExt) ?? 0
        prochotCount    = try c.decodeIfPresent(Int.self, forKey: .prochotCount) ?? 0
    }
}
