import Foundation
import UIKit
import Darwin
import MachO

public struct SystemSnapshot {
    public let totalCpuUsage: Double
    public let perCoreUsage: [Double]
    public let ramUsedMB: Double
    public let ramTotalGB: Double
    public let thermalState: ProcessInfo.ThermalState
    public let batteryLevel: Int
    public let isCharging: Bool
    public let isLowPowerMode: Bool
    public let activeCores: Int
}

public class SystemStatsReader {
    public static let shared = SystemStatsReader()
    
    private var previousCpuInfo: processor_info_array_t?
    private var previousCpuInfoCount: mach_msg_type_number_t = 0
    private var numProcessors: natural_t = 0
    private let cpuLock = NSLock()
    
    private init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        var processorCount: natural_t = 0
        let host = mach_host_self()
        let result = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &processorCount, &previousCpuInfo, &previousCpuInfoCount)
        if result == KERN_SUCCESS {
            self.numProcessors = processorCount
        } else {
            self.numProcessors = natural_t(ProcessInfo.processInfo.activeProcessorCount)
        }
    }
    
    public func captureSnapshot() -> SystemSnapshot {
        let (totalCpu, coreCpu) = readCpuUsage()
        let (ramUsed, ramTotal) = readMemoryUsage()
        
        let battery = Int(max(0, UIDevice.current.batteryLevel * 100))
        let charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let thermal = ProcessInfo.processInfo.thermalState
        let cores = ProcessInfo.processInfo.activeProcessorCount
        
        return SystemSnapshot(
            totalCpuUsage: totalCpu,
            perCoreUsage: coreCpu,
            ramUsedMB: ramUsed,
            ramTotalGB: ramTotal,
            thermalState: thermal,
            batteryLevel: battery,
            isCharging: charging,
            isLowPowerMode: lowPower,
            activeCores: cores
        )
    }
    
    private func readCpuUsage() -> (Double, [Double]) {
        cpuLock.lock()
        defer { cpuLock.unlock() }
        
        var processorCount: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0
        
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &processorCount, &cpuInfo, &cpuInfoCount)
        guard result == KERN_SUCCESS, let currentCpuInfo = cpuInfo else {
            return (0.0, [])
        }
        
        var perCore: [Double] = []
        var totalInUse: Int64 = 0
        var totalTotal: Int64 = 0
        
        if let prevInfo = previousCpuInfo {
            for i in 0..<Int(processorCount) {
                let base = i * Int(CPU_STATE_MAX)
                let user = Int64(currentCpuInfo[base + Int(CPU_STATE_USER)] - prevInfo[base + Int(CPU_STATE_USER)])
                let system = Int64(currentCpuInfo[base + Int(CPU_STATE_SYSTEM)] - prevInfo[base + Int(CPU_STATE_SYSTEM)])
                let nice = Int64(currentCpuInfo[base + Int(CPU_STATE_NICE)] - prevInfo[base + Int(CPU_STATE_NICE)])
                let idle = Int64(currentCpuInfo[base + Int(CPU_STATE_IDLE)] - prevInfo[base + Int(CPU_STATE_IDLE)])
                
                let inUse = max(0, user + system + nice)
                let total = max(1, inUse + max(0, idle))
                
                let corePercent = (Double(inUse) / Double(total)) * 100.0
                perCore.append((corePercent * 10).rounded() / 10)
                
                totalInUse += inUse
                totalTotal += total
            }
            
            // Deallocate previous info
            let prevSize = vm_size_t(previousCpuInfoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: prevInfo)), prevSize)
        } else {
            // First run baseline
            for _ in 0..<Int(processorCount) {
                perCore.append(0.0)
            }
        }
        
        previousCpuInfo = currentCpuInfo
        previousCpuInfoCount = cpuInfoCount
        
        let totalUsage = totalTotal > 0 ? (Double(totalInUse) / Double(totalTotal)) * 100.0 : 0.0
        return ((totalUsage * 10).rounded() / 10, perCore)
    }
    
    private func readMemoryUsage() -> (Double, Double) {
        var taskInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / 4)
        let kerr = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        let residentMB = kerr == KERN_SUCCESS ? Double(taskInfo.resident_size) / (1024.0 * 1024.0) : 0.0
        let totalGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024.0 * 1024.0 * 1024.0)
        
        return ((residentMB * 10).rounded() / 10, (totalGB * 10).rounded() / 10)
    }
}
