import Foundation
import SwiftUI
import Combine

public struct TelemetryRecord: Identifiable, Codable {
    public var id = UUID()
    public let timestamp: Date
    public let relativeSeconds: Double
    public let peakDieTemp: Double
    public let pCoreTemp: Double
    public let eCoreTemp: Double
    public let gpuTemp: Double
    public let batteryTemp: Double
    public let chassisTemp: Double
    public let thermalHeadroom: Double
    public let throttlingRisk: Int
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
    
    // Live Monitoring Telemetry (ALWAYS ACTIVE, never freezes!)
    @Published public var currentPeakTemp: Double = 37.2
    @Published public var currentPTemp: Double = 38.0
    @Published public var currentETemp: Double = 35.5
    @Published public var currentGPUTemp: Double = 36.2
    @Published public var currentBatTemp: Double = 30.0
    @Published public var currentChassisTemp: Double = 27.5
    @Published public var thermalHeadroom: Double = 57.8
    @Published public var throttlingRisk: Int = 0
    @Published public var sensorMode: String = "SoC Multi-Zone Fusion"
    @Published public var isHardwareSensor: Bool = false
    @Published public var thermalStateText: String = "NOMINAL"
    
    @Published public var totalCpuUsage: Double = 0.0
    @Published public var perCoreUsage: [Double] = [0, 0, 0, 0, 0, 0]
    @Published public var ramUsedMB: Double = 0.0
    @Published public var ramTotalGB: Double = 8.0
    @Published public var batteryLevel: Int = 100
    @Published public var isCharging: Bool = false
    @Published public var isLowPowerMode: Bool = false
    
    // Recording Session State
    @Published public var isRecording: Bool = false
    @Published public var samplingInterval: Double = 0.1 // 100ms
    @Published public var sampleCount: Int = 0
    @Published public var elapsedTime: Double = 0.0
    @Published public var maxRecordedTemp: Double = 0.0
    @Published public var minRecordedTemp: Double = 100.0
    @Published public var avgRecordedTemp: Double = 0.0
    
    // Storage Footprint Meter
    @Published public var totalStorageString: String = "0 KB"
    @Published public var sessionFilesCount: Int = 0
    
    // Waveform Ring Buffer (last 200 points for smooth 120Hz chart)
    @Published public var chartHistory: [TelemetryRecord] = []
    
    private var sessionRecords: [TelemetryRecord] = []
    private var pendingBatch: [TelemetryRecord] = []
    private var currentSessionURL: URL?
    private var sessionStartTime: Date?
    private var sumTemp: Double = 0.0
    
    private var monitorTimer: DispatchSourceTimer?
    private let monitorQueue = DispatchQueue(label: "com.corethermal.monitor", qos: .userInteractive)
    private let diskQueue = DispatchQueue(label: "com.corethermal.disk", qos: .utility)
    
    private init() {
        startContinuousMonitoring()
        refreshStorageFootprint()
    }
    
    // MARK: - Continuous Live Monitoring Engine
    public func startContinuousMonitoring() {
        monitorTimer?.cancel()
        
        let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
        let intervalNs = Int(samplingInterval * 1_000_000_000)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(intervalNs), leeway: .nanoseconds(5_000))
        
        timer.setEventHandler { [weak self] in
            self?.monitorTick()
        }
        
        self.monitorTimer = timer
        timer.resume()
    }
    
    public func updateSamplingInterval(_ newInterval: Double) {
        self.samplingInterval = newInterval
        startContinuousMonitoring()
    }
    
    private func monitorTick() {
        let snapshot = SystemStatsReader.shared.captureSnapshot()
        let thermal = TemperatureReader.shared.readDetailedTelemetry(
            perCoreLoads: snapshot.perCoreUsage,
            totalCpuLoad: snapshot.totalCpuUsage,
            isCharging: snapshot.isCharging
        )
        
        let now = Date()
        let relativeSec: Double
        if isRecording, let start = sessionStartTime {
            relativeSec = now.timeIntervalSince(start)
        } else {
            relativeSec = 0.0
        }
        
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
            peakDieTemp: thermal.peakDieTemp,
            pCoreTemp: thermal.pCoreTemp,
            eCoreTemp: thermal.eCoreTemp,
            gpuTemp: thermal.gpuTemp,
            batteryTemp: thermal.batteryTemp,
            chassisTemp: thermal.chassisTemp,
            thermalHeadroom: thermal.thermalHeadroom,
            throttlingRisk: thermal.throttlingRiskPercent,
            isHardwareSensor: thermal.isHardwareSensor,
            thermalState: thermalString,
            totalCpuUsage: snapshot.totalCpuUsage,
            perCoreUsage: snapshot.perCoreUsage,
            ramUsedMB: snapshot.ramUsedMB,
            batteryLevel: snapshot.batteryLevel,
            isCharging: snapshot.isCharging,
            isLowPowerMode: snapshot.isLowPowerMode
        )
        
        if isRecording {
            sessionRecords.append(record)
            pendingBatch.append(record)
            sumTemp += record.peakDieTemp
            
            if pendingBatch.count >= 50 {
                let toFlush = pendingBatch
                pendingBatch.removeAll()
                diskQueue.async { [weak self] in
                    self?.writeBatchToDisk(records: toFlush)
                }
            }
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentPeakTemp = record.peakDieTemp
            self.currentPTemp = record.pCoreTemp
            self.currentETemp = record.eCoreTemp
            self.currentGPUTemp = record.gpuTemp
            self.currentBatTemp = record.batteryTemp
            self.currentChassisTemp = record.chassisTemp
            self.thermalHeadroom = record.thermalHeadroom
            self.throttlingRisk = record.throttlingRisk
            self.sensorMode = thermal.sensorMode
            self.isHardwareSensor = record.isHardwareSensor
            self.thermalStateText = record.thermalState
            
            self.totalCpuUsage = record.totalCpuUsage
            self.perCoreUsage = record.perCoreUsage
            self.ramUsedMB = record.ramUsedMB
            self.ramTotalGB = snapshot.ramTotalGB
            self.batteryLevel = record.batteryLevel
            self.isCharging = record.isCharging
            self.isLowPowerMode = record.isLowPowerMode
            
            if self.isRecording {
                let count = self.sessionRecords.count
                self.sampleCount = count
                self.elapsedTime = relativeSec
                self.maxRecordedTemp = max(self.maxRecordedTemp, record.peakDieTemp)
                self.minRecordedTemp = min(self.minRecordedTemp, record.peakDieTemp)
                self.avgRecordedTemp = (self.sumTemp / Double(count) * 10).rounded() / 10
            }
            
            self.chartHistory.append(record)
            if self.chartHistory.count > 200 {
                self.chartHistory.removeFirst(self.chartHistory.count - 200)
            }
        }
    }
    
    // MARK: - Recording Actions (Non-blocking!)
    public func startLogging() {
        guard !isRecording else { return }
        
        sessionStartTime = Date()
        sessionRecords.removeAll()
        pendingBatch.removeAll()
        sampleCount = 0
        elapsedTime = 0.0
        maxRecordedTemp = currentPeakTemp
        minRecordedTemp = currentPeakTemp
        avgRecordedTemp = currentPeakTemp
        sumTemp = 0.0
        prepareSessionFile()
        
        isRecording = true
    }
    
    public func stopLogging() {
        guard isRecording else { return }
        isRecording = false
        
        let remaining = pendingBatch
        pendingBatch.removeAll()
        
        diskQueue.async { [weak self] in
            self?.writeBatchToDisk(records: remaining)
            DispatchQueue.main.async {
                self?.refreshStorageFootprint()
            }
        }
    }
    
    public func clearData() {
        stopLogging()
        sessionRecords.removeAll()
        pendingBatch.removeAll()
        sampleCount = 0
        elapsedTime = 0.0
        maxRecordedTemp = 0.0
        minRecordedTemp = 100.0
        avgRecordedTemp = 0.0
        sumTemp = 0.0
    }
    
    // MARK: - Disk Management
    private func prepareSessionFile() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "ThermalCore_Log_\(formatter.string(from: Date())).csv"
        let fileURL = docs.appendingPathComponent(filename)
        self.currentSessionURL = fileURL
        
        let header = "Timestamp,RelativeSeconds,PeakDie_C,PCore_C,ECore_C,GPU_C,Battery_C,Chassis_C,Headroom_C,Risk_Percent,HardwareSensor,ThermalState,TotalCPU_Percent,RAM_Used_MB,Battery_Percent,IsCharging,LowPowerMode\n"
        try? header.write(to: fileURL, atomically: true, encoding: .utf8)
    }
    
    private func writeBatchToDisk(records: [TelemetryRecord]) {
        guard let url = currentSessionURL, !records.isEmpty else { return }
        
        var chunk = ""
        for r in records {
            chunk += "\(ISO8601DateFormatter().string(from: r.timestamp)),\(r.relativeSeconds),\(r.peakDieTemp),\(r.pCoreTemp),\(r.eCoreTemp),\(r.gpuTemp),\(r.batteryTemp),\(r.chassisTemp),\(r.thermalHeadroom),\(r.throttlingRisk),\(r.isHardwareSensor),\(r.thermalState),\(r.totalCpuUsage),\(r.ramUsedMB),\(r.batteryLevel),\(r.isCharging),\(r.isLowPowerMode)\n"
        }
        
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            if let data = chunk.data(using: .utf8) {
                handle.write(data)
            }
            try? handle.close()
        }
    }
    
    public func refreshStorageFootprint() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let files = try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: [.fileSizeKey], options: []) else {
            return
        }
        
        var totalBytes: Int64 = 0
        var count = 0
        for file in files {
            if file.pathExtension.lowercased() == "csv" || file.pathExtension.lowercased() == "json" {
                count += 1
                if let resourceValues = try? file.resourceValues(forKeys: [.fileSizeKey]),
                   let size = resourceValues.fileSize {
                    totalBytes += Int64(size)
                }
            }
        }
        
        let formattedSize = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        DispatchQueue.main.async {
            self.totalStorageString = formattedSize
            self.sessionFilesCount = count
        }
    }
    
    public func clearAllLogs() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let files = try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil, options: []) {
            for file in files {
                if file.pathExtension.lowercased() == "csv" || file.pathExtension.lowercased() == "json" {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        clearData()
        refreshStorageFootprint()
    }
    
    // MARK: - Export
    public func exportCSV() -> URL? {
        let remaining = pendingBatch
        pendingBatch.removeAll()
        writeBatchToDisk(records: remaining)
        refreshStorageFootprint()
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
            refreshStorageFootprint()
            return url
        }
        return nil
    }
}
