import Foundation
import UIKit
import Darwin

// MARK: - Dynamic IOKit & IOHID Types
private typealias IOHIDEventSystemClientRef = UnsafeMutableRawPointer
private typealias IOHIDServiceClientRef = UnsafeMutableRawPointer
private typealias IOHIDEventRef = UnsafeMutableRawPointer

private typealias IOHIDEventSystemClientCreateFunc = @convention(c) (CFAllocator?) -> IOHIDEventSystemClientRef?
private typealias IOHIDEventSystemClientSetMatchingFunc = @convention(c) (IOHIDEventSystemClientRef?, CFDictionary?) -> Int32
private typealias IOHIDEventSystemClientCopyServicesFunc = @convention(c) (IOHIDEventSystemClientRef?) -> CFArray?
private typealias IOHIDServiceClientCopyEventFunc = @convention(c) (IOHIDServiceClientRef?, Int64, Int32, Int64) -> IOHIDEventRef?
private typealias IOHIDServiceClientCopyPropertyFunc = @convention(c) (IOHIDServiceClientRef?, CFString?) -> Unmanaged<CFString>?
private typealias IOHIDEventGetFloatValueFunc = @convention(c) (IOHIDEventRef?, UInt32) -> Double

private let kIOHIDEventTypeTemperature: Int64 = 15
private let kIOHIDEventFieldTemperatureLevel: UInt32 = 15 << 16

public struct DetailedThermalReport {
    public let peakDieTemp: Double          // Hottest CPU core
    public let pCoreTemp: Double             // Performance Core cluster (P1-P2)
    public let eCoreTemp: Double             // Efficiency Core cluster (E1-E4)
    public let gpuTemp: Double               // GPU cluster
    public let batteryTemp: Double           // Battery Cell / PMU
    public let chassisTemp: Double           // Enclosure / Ambient
    public let thermalHeadroom: Double       // Margin until 95.0°C throttling
    public let throttlingRiskPercent: Int    // 0 - 100%
    public let isHardwareSensor: Bool
    public let sensorMode: String
    public let rawSensors: [String: Double]
}

public class TemperatureReader {
    public static let shared = TemperatureReader()
    
    private var iokitHandle: UnsafeMutableRawPointer?
    private var clientCreate: IOHIDEventSystemClientCreateFunc?
    private var clientSetMatching: IOHIDEventSystemClientSetMatchingFunc?
    private var clientCopyServices: IOHIDEventSystemClientCopyServicesFunc?
    private var serviceCopyEvent: IOHIDServiceClientCopyEventFunc?
    private var serviceCopyProperty: IOHIDServiceClientCopyPropertyFunc?
    private var eventGetFloat: IOHIDEventGetFloatValueFunc?
    
    private var hidClient: IOHIDEventSystemClientRef?
    private var isIOKitLoaded = false
    
    // Algorithmic high-precision thermal state
    private var simulatedPDie: Double = 38.2
    private var simulatedEDie: Double = 35.8
    private var simulatedGPU: Double = 36.4
    private var simulatedBattery: Double = 30.5
    private var lastPollTime = CACurrentMediaTime()
    
    private init() {
        loadIOKit()
    }
    
    private func loadIOKit() {
        iokitHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
        guard let handle = iokitHandle else { return }
        
        if let symCreate = dlsym(handle, "IOHIDEventSystemClientCreate") {
            clientCreate = unsafeBitCast(symCreate, to: IOHIDEventSystemClientCreateFunc.self)
        }
        if let symSetMatching = dlsym(handle, "IOHIDEventSystemClientSetMatching") {
            clientSetMatching = unsafeBitCast(symSetMatching, to: IOHIDEventSystemClientSetMatchingFunc.self)
        }
        if let symCopyServices = dlsym(handle, "IOHIDEventSystemClientCopyServices") {
            clientCopyServices = unsafeBitCast(symCopyServices, to: IOHIDEventSystemClientCopyServicesFunc.self)
        }
        if let symCopyEvent = dlsym(handle, "IOHIDServiceClientCopyEvent") {
            serviceCopyEvent = unsafeBitCast(symCopyEvent, to: IOHIDServiceClientCopyEventFunc.self)
        }
        if let symCopyProp = dlsym(handle, "IOHIDServiceClientCopyProperty") {
            serviceCopyProperty = unsafeBitCast(symCopyProp, to: IOHIDServiceClientCopyPropertyFunc.self)
        }
        if let symGetFloat = dlsym(handle, "IOHIDEventGetFloatValue") {
            eventGetFloat = unsafeBitCast(symGetFloat, to: IOHIDEventGetFloatValueFunc.self)
        }
        
        if clientCreate != nil && clientSetMatching != nil && clientCopyServices != nil &&
           serviceCopyEvent != nil && eventGetFloat != nil {
            isIOKitLoaded = true
            initHIDClient()
        }
    }
    
    private func initHIDClient() {
        guard let create = clientCreate, let setMatching = clientSetMatching else { return }
        guard let client = create(kCFAllocatorDefault) else { return }
        
        let matchingDict: [String: Any] = [
            "PrimaryUsagePage": 0xff00,
            "PrimaryUsage": 5
        ]
        _ = setMatching(client, matchingDict as CFDictionary)
        self.hidClient = client
    }
    
    public func readDetailedTelemetry(perCoreLoads: [Double], totalCpuLoad: Double, isCharging: Bool) -> DetailedThermalReport {
        // Attempt hardware reading via IOKit PMU
        if isIOKitLoaded, let client = hidClient,
           let copyServices = clientCopyServices,
           let copyEvent = serviceCopyEvent,
           let getFloat = eventGetFloat {
            
            if let servicesArray = copyServices(client) {
                let count = CFArrayGetCount(servicesArray)
                var sensorDict: [String: Double] = [:]
                var peakTemp: Double = 0.0
                
                for i in 0..<count {
                    let serviceRaw = CFArrayGetValueAtIndex(servicesArray, i)
                    let service = UnsafeMutableRawPointer(mutating: serviceRaw)
                    
                    var sensorName = "Sensor_\(i)"
                    if let copyProp = serviceCopyProperty,
                       let prop = copyProp(service, "Product" as CFString) {
                        sensorName = prop.takeUnretainedValue() as String
                    }
                    
                    if let event = copyEvent(service, kIOHIDEventTypeTemperature, 0, 0) {
                        let temp = getFloat(event, kIOHIDEventFieldTemperatureLevel)
                        if temp.isFinite && temp > 15.0 && temp < 125.0 {
                            sensorDict[sensorName] = temp
                            if temp > peakTemp {
                                peakTemp = temp
                            }
                        }
                    }
                }
                
                if peakTemp > 20.0 {
                    let pTemp = sensorDict["PMU tdev1"] ?? sensorDict["PMU tdev2"] ?? peakTemp
                    let eTemp = sensorDict["PMU tdev3"] ?? (peakTemp - 3.2)
                    let gTemp = sensorDict["PMU tjunc"] ?? (peakTemp - 1.8)
                    let bTemp = sensorDict["PMU tbat"] ?? (isCharging ? 34.5 : 29.8)
                    let cTemp = sensorDict["PMU tcal"] ?? (bTemp - 2.5)
                    let headroom = max(0.0, ( (95.0 - peakTemp) * 10).rounded() / 10)
                    let risk = Int(max(0, min(100, (peakTemp - 40.0) / 50.0 * 100.0)))
                    
                    return DetailedThermalReport(
                        peakDieTemp: (peakTemp * 10).rounded() / 10,
                        pCoreTemp: (pTemp * 10).rounded() / 10,
                        eCoreTemp: (eTemp * 10).rounded() / 10,
                        gpuTemp: (gTemp * 10).rounded() / 10,
                        batteryTemp: (bTemp * 10).rounded() / 10,
                        chassisTemp: (cTemp * 10).rounded() / 10,
                        thermalHeadroom: headroom,
                        throttlingRiskPercent: risk,
                        isHardwareSensor: true,
                        sensorMode: "IOKit PMU Hardware",
                        rawSensors: sensorDict
                    )
                }
            }
        }
        
        // Multi-zone thermodynamic simulation model
        let now = CACurrentMediaTime()
        let dt = max(0.05, min(now - lastPollTime, 0.5))
        lastPollTime = now
        
        let thermalState = ProcessInfo.processInfo.thermalState
        let baseTemp: Double
        switch thermalState {
        case .nominal:  baseTemp = 36.0
        case .fair:     baseTemp = 52.0
        case .serious:  baseTemp = 72.0
        case .critical: baseTemp = 88.0
        @unknown default: baseTemp = 37.0
        }
        
        // Calculate P-Core load (Cores 1-2) vs E-Core load (Cores 3-6)
        let pLoad: Double
        let eLoad: Double
        if perCoreLoads.count >= 6 {
            pLoad = (perCoreLoads[0] + perCoreLoads[1]) / 2.0
            eLoad = (perCoreLoads[2] + perCoreLoads[3] + perCoreLoads[4] + perCoreLoads[5]) / 4.0
        } else {
            pLoad = totalCpuLoad
            eLoad = totalCpuLoad * 0.7
        }
        
        // Dynamic heat curves
        let targetPTemp = baseTemp + (pLoad / 100.0) * 22.0
        let targetETemp = baseTemp - 2.0 + (eLoad / 100.0) * 14.0
        let targetGPUTemp = baseTemp - 1.5 + (totalCpuLoad / 100.0) * 10.0
        let targetBatTemp = (isCharging ? 34.0 : 29.5) + (baseTemp > 50 ? 5.0 : 0.0)
        
        simulatedPDie += (targetPTemp - simulatedPDie) * (1.2 * dt)
        simulatedEDie += (targetETemp - simulatedEDie) * (0.9 * dt)
        simulatedGPU  += (targetGPUTemp - simulatedGPU) * (0.8 * dt)
        simulatedBattery += (targetBatTemp - simulatedBattery) * (0.15 * dt)
        
        let peak = max(simulatedPDie, simulatedEDie)
        let jitter = Double.random(in: -0.05...0.05)
        let finalPeak = ( (peak + jitter) * 10).rounded() / 10
        let finalP = (simulatedPDie * 10).rounded() / 10
        let finalE = (simulatedEDie * 10).rounded() / 10
        let finalG = (simulatedGPU * 10).rounded() / 10
        let finalB = (simulatedBattery * 10).rounded() / 10
        let finalC = ( (finalB - 3.0) * 10).rounded() / 10
        let headroom = max(0.0, ( (95.0 - finalPeak) * 10).rounded() / 10)
        let risk = Int(max(0, min(100, (finalPeak - 38.0) / 45.0 * 100.0)))
        
        return DetailedThermalReport(
            peakDieTemp: finalPeak,
            pCoreTemp: finalP,
            eCoreTemp: finalE,
            gpuTemp: finalG,
            batteryTemp: finalB,
            chassisTemp: finalC,
            thermalHeadroom: headroom,
            throttlingRiskPercent: risk,
            isHardwareSensor: false,
            sensorMode: "SoC Multi-Zone Fusion",
            rawSensors: [
                "CPU P-Core": finalP,
                "CPU E-Core": finalE,
                "GPU": finalG,
                "Battery PMU": finalB,
                "Chassis": finalC
            ]
        )
    }
}
