import Foundation
import SwiftUI
import Combine

public struct TelemetryRecord: Identifiable, Codable {
    public var id = UUID()
    public let timestamp: Date
    public let relativeSeconds: Double
    public let cpuTemp: Double
    public let isHardwareSensor: Bool
    public let thermalState: String
    public let totalCpuUsage: Double
    public let perCoreUsage: [Double]
    public let ramUsedMB: Double
    public let batteryLevel: Int
    public let isCharging: Bool
    public let isLowPowerMode: Bool
    
    public var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SS"
        return formatter.string(from: timestamp)
    }
}

public class LogManager: ObservableObject {
    public static let shared = LogManager()
    
    @Published public var isRecording: Bool = false
    @Published public var samplingInterval: Double = 0.1 // 100ms default
    @Published public var currentTemp: Double = 37.0
    @Published public var isHardwareSensor: Bool = false
    @Published public var thermalStateText: String = "NOMINAL"
    @Published public var totalCpuUsage: Double = 0.0
    @Published public var perCoreUsage: [Double] = []
    @Published public var ramUsedMB: Double = 0.0
    @Published public var ramTotalGB: Double = 8.0
    @Published public var batteryLevel: Int = 100
    @Published public var isCharging: Bool = false
    @Published public var isLowPowerMode: Bool = false
    
    // Summary telemetry
    @Published public var maxTemp: Double = 0.0
    @Published public var minTemp: Double = 100.0
    @Published public var avgTemp: Double = 0.0
    @Published public var sampleCount: Int = 0
    @Published public var elapsedTime: Double = 0.0
    @Published public var throttlingCount: Int = 0
    
    // Ring buffer for UI live waveform (capped to 300 points for smooth 120Hz SwiftUI)
    @Published public var chartHistory: [TelemetryRecord] = []
    
    // Complete session storage
    private var sessionRecords: [TelemetryRecord] = []
    private var pendingBatch: [TelemetryRecord] = []
    private var currentSessionURL: URL?
    
    private var timer: DispatchSourceTimer?
    private let loggerQueue = DispatchQueue(label: "com.corethermal.logger", qos: .userInitiated)
    private var sessionStartTime: Date?
    private var sumTemp: Double = 0.0
    
    private init() {
        prepareSessionFile()
    }
    
    public func startLogging() {
        guard !isRecording else { return }
        
        sessionStartTime = Date()
        sessionRecords.removeAll()
        pendingBatch.removeAll()
        chartHistory.removeAll()
        sampleCount = 0
        elapsedTime = 0.0
        maxTemp = 0.0
        minTemp = 100.0
        avgTemp = 0.0
        sumTemp = 0.0
        throttlingCount = 0
        prepareSessionFile()
        
        let timerSource = DispatchSource.makeTimerSource(queue: loggerQueue)
        let intervalNs = Int(samplingInterval * 1_000_000_000)
        timerSource.schedule(deadline: .now(), repeating: .nanoseconds(intervalNs), leeway: .nanoseconds(10_000))
        
        timerSource.setEventHandler { [weak self] in
            self?.tick()
        }
        
        self.timer = timerSource
        timerSource.resume()
        
        DispatchQueue.main.async {
            self.isRecording = true
        }
    }
    
    public func stopLogging() {
        guard isRecording else { return }
        
        timer?.cancel()
        timer = nil
        
        loggerQueue.sync {
            self.flushPendingBatchToDisk()
        }
        
        DispatchQueue.main.async {
            self.isRecording = false
        }
    }
    
    public func clearData() {
        stopLogging()
        sessionRecords.removeAll()
        pendingBatch.removeAll()
        chartHistory.removeAll()
        sampleCount = 0
        elapsedTime = 0.0
        maxTemp = 0.0
        minTemp = 100.0
        avgTemp = 0.0
        sumTemp = 0.0
        throttlingCount = 0
        prepareSessionFile()
    }
    
    private func tick() {
        let snapshot = SystemStatsReader.shared.captureSnapshot()
        let tempReading = TemperatureReader.shared.readTemperature(currentCpuLoad: snapshot.totalCpuUsage)
        
        let now = Date()
        let relativeSec = sessionStartTime != nil ? now.timeIntervalSince(sessionStartTime!) : 0.0
        
        let thermalString: String
        switch snapshot.thermalState {
        case .nominal:  thermalString = "NOMINAL"
        case .fair:     thermalString = "FAIR"
        case .serious:  thermalString = "SERIOUS"
        case .critical: thermalString = "CRITICAL"
        @unknown default: thermalString = "UNKNOWN"
        }
        
        let record = TelemetryRecord(
            timestamp: now,
            relativeSeconds: (relativeSec * 100).rounded() / 100,
            cpuTemp: tempReading.currentTemp,
            isHardwareSensor: tempReading.isHardwareSensor,
            thermalState: thermalString,
            totalCpuUsage: snapshot.totalCpuUsage,
            perCoreUsage: snapshot.perCoreUsage,
            ramUsedMB: snapshot.ramUsedMB,
            batteryLevel: snapshot.batteryLevel,
            isCharging: snapshot.isCharging,
            isLowPowerMode: snapshot.isLowPowerMode
        )
        
        sessionRecords.append(record)
        pendingBatch.append(record)
        
        sumTemp += record.cpuTemp
        let count = sessionRecords.count
        let newMax = max(maxTemp, record.cpuTemp)
        let newMin = min(minTemp, record.cpuTemp)
        let newAvg = (sumTemp / Double(count) * 10).rounded() / 10
        if snapshot.thermalState == .serious || snapshot.thermalState == .critical {
            throttlingCount += 1
        }
        
        // Batch flush every 50 records (~5s at 10Hz) to eliminate disk IO stutter
        if pendingBatch.count >= 50 {
            flushPendingBatchToDisk()
        }
        
        // Dispatch to UI thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentTemp = record.cpuTemp
            self.isHardwareSensor = record.isHardwareSensor
            self.thermalStateText = record.thermalState
            self.totalCpuUsage = record.totalCpuUsage
            self.perCoreUsage = record.perCoreUsage
            self.ramUsedMB = record.ramUsedMB
            self.ramTotalGB = snapshot.ramTotalGB
            self.batteryLevel = record.batteryLevel
            self.isCharging = record.isCharging
            self.isLowPowerMode = record.isLowPowerMode
            
            self.sampleCount = count
            self.elapsedTime = relativeSec
            self.maxTemp = newMax
            self.minTemp = newMin
            self.avgTemp = newAvg
            
            self.chartHistory.append(record)
            if self.chartHistory.count > 250 {
                self.chartHistory.removeFirst(self.chartHistory.count - 250)
            }
        }
    }
    
    private func prepareSessionFile() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "ThermalCore_Telemetry_\(formatter.string(from: Date())).csv"
        let fileURL = docs.appendingPathComponent(filename)
        self.currentSessionURL = fileURL
        
        let header = "Timestamp,RelativeSeconds,CPUTemp_C,IsHardwareSensor,ThermalState,TotalCPU_Percent,RAM_Used_MB,Battery_Percent,IsCharging,LowPowerMode\n"
        try? header.write(to: fileURL, atomically: true, encoding: .utf8)
    }
    
    private func flushPendingBatchToDisk() {
        guard let url = currentSessionURL, !pendingBatch.isEmpty else { return }
        
        var chunk = ""
        for r in pendingBatch {
            chunk += "\(ISO8601DateFormatter().string(from: r.timestamp)),\(r.relativeSeconds),\(r.cpuTemp),\(r.isHardwareSensor),\(r.thermalState),\(r.totalCpuUsage),\(r.ramUsedMB),\(r.batteryLevel),\(r.isCharging),\(r.isLowPowerMode)\n"
        }
        pendingBatch.removeAll()
        
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            if let data = chunk.data(using: .utf8) {
                handle.write(data)
            }
            try? handle.close()
        }
    }
    
    // MARK: - Export
    public func exportCSV() -> URL? {
        flushPendingBatchToDisk()
        return currentSessionURL
    }
    
    public func exportJSON() -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("ThermalCore_Export_\(Int(Date().timeIntervalSince1970)).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        
        if let data = try? encoder.encode(sessionRecords) {
            try? data.write(to: url)
            return url
        }
        return nil
    }
}
