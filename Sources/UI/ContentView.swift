import SwiftUI
import UIKit

// MARK: - ShareSheet Helper
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Clean Light-Mode Waveform Chart
struct CockpitWaveformChart: View {
    let records: [TelemetryRecord]
    
    var body: some View {
        Canvas { context, size in
            guard records.count > 1 else { return }
            
            let minTemp: Double = 25.0
            let maxTemp: Double = 95.0
            let tempRange = maxTemp - minTemp
            
            // Horizontal reference lines (35, 50, 65, 80°C)
            let gridTemps: [Double] = [35.0, 50.0, 65.0, 80.0]
            for gTemp in gridTemps {
                let yNorm = 1.0 - (gTemp - minTemp) / tempRange
                let yPos = CGFloat(yNorm) * size.height
                
                var gridPath = Path()
                gridPath.move(to: CGPoint(x: 0, y: yPos))
                gridPath.addLine(to: CGPoint(x: size.width, y: yPos))
                context.stroke(gridPath, with: .color(Color(UIColor.systemGray5)), lineWidth: 1)
                
                context.draw(
                    Text("\(Int(gTemp))°C")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(UIColor.tertiaryLabel)),
                    at: CGPoint(x: 18, y: yPos - 6)
                )
            }
            
            // Curve path
            var linePath = Path()
            var fillPath = Path()
            let stepX = size.width / CGFloat(max(1, records.count - 1))
            
            for (index, record) in records.enumerated() {
                let x = CGFloat(index) * stepX
                let clampedTemp = max(minTemp, min(record.peakDieTemp, maxTemp))
                let yNorm = 1.0 - (clampedTemp - minTemp) / tempRange
                let y = CGFloat(yNorm) * size.height
                
                if index == 0 {
                    linePath.move(to: CGPoint(x: x, y: y))
                    fillPath.move(to: CGPoint(x: x, y: size.height))
                    fillPath.addLine(to: CGPoint(x: x, y: y))
                } else {
                    linePath.addLine(to: CGPoint(x: x, y: y))
                    fillPath.addLine(to: CGPoint(x: x, y: y))
                }
            }
            
            if let _ = records.last {
                let lastX = CGFloat(records.count - 1) * stepX
                fillPath.addLine(to: CGPoint(x: lastX, y: size.height))
                fillPath.closeSubpath()
            }
            
            // Subtle fill
            let gradient = Gradient(colors: [
                Color.orange.opacity(0.18),
                Color.orange.opacity(0.04),
                Color.clear
            ])
            context.fill(fillPath, with: .linearGradient(gradient, startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
            
            // Crisp vector line
            context.stroke(linePath, with: .color(Color.orange), lineWidth: 2.0)
        }
        .frame(height: 130)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(UIColor.separator).opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - Main Cockpit View
struct ContentView: View {
    @StateObject private var logManager = LogManager.shared
    @StateObject private var bgManager = BackgroundAudioManager.shared
    
    @State private var shareURL: URL?
    @State private var showShareSheet = false
    @State private var showDeleteConfirm = false
    
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                // 1. Cockpit Flight Deck Header
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("THERMALCORE")
                                .font(.system(size: 20, weight: .heavy, design: .monospaced))
                                .foregroundColor(.primary)
                            Text("COCKPIT")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.12))
                                .foregroundColor(.blue)
                                .cornerRadius(4)
                        }
                        Text("Apple A17 Pro (2P + 4E) · High-Frequency Avionics")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    
                    // Live Status Pill
                    HStack(spacing: 5) {
                        Circle()
                            .fill(logManager.isRecording ? Color.red : Color.green)
                            .frame(width: 8, height: 8)
                        Text(logManager.isRecording ? String(format: "REC %04.1fs", logManager.elapsedTime) : "\(Int(1.0 / logManager.samplingInterval))Hz LIVE")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(logManager.isRecording ? .red : .green)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(UIColor.separator).opacity(0.4), lineWidth: 1)
                    )
                }
                .padding(.horizontal, 4)
                .padding(.top, 6)
                
                // 2. Primary Flight Display (PFD) 3-Dial Cluster
                HStack(spacing: 10) {
                    pfdGauge(
                        title: "PEAK DIE",
                        value: String(format: "%.1f°C", logManager.currentPeakTemp),
                        subtitle: logManager.thermalStateText,
                        color: tempColor(logManager.currentPeakTemp)
                    )
                    
                    pfdGauge(
                        title: "CPU LOAD",
                        value: String(format: "%.1f%%", logManager.totalCpuUsage),
                        subtitle: "\(logManager.ramUsedMB.formatted(.number.precision(.fractionLength(0))))MB RAM",
                        color: .blue
                    )
                    
                    pfdGauge(
                        title: "HEADROOM",
                        value: String(format: "+%.1f°C", logManager.thermalHeadroom),
                        subtitle: "\(logManager.throttlingRisk)% RISK",
                        color: logManager.thermalHeadroom < 15 ? .red : (logManager.thermalHeadroom < 30 ? .orange : .green)
                    )
                }
                
                // 3. Multi-Zone Thermal Instrument Matrix (온도 상세 계기판)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "thermometer.medium")
                            .foregroundColor(.orange)
                            .font(.system(size: 12, weight: .bold))
                        Text("MULTI-ZONE THERMAL SENSORS")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(logManager.sensorMode)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        zoneItem(label: "P-CORE (P1-P2)", temp: logManager.currentPTemp, desc: "High Performance")
                        zoneItem(label: "E-CORE (E1-E4)", temp: logManager.currentETemp, desc: "High Efficiency")
                        zoneItem(label: "GPU CLUSTER", temp: logManager.currentGPUTemp, desc: "Metal Graphics")
                        zoneItem(label: "BATTERY PMU", temp: logManager.currentBatTemp, desc: "Power Cell")
                        zoneItem(label: "CHASSIS", temp: logManager.currentChassisTemp, desc: "Surface Enclosure")
                        zoneItem(label: "TJMAX LIMIT", temp: 95.0, desc: "Throttle Target", isTarget: true)
                    }
                }
                .padding(14)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(UIColor.separator).opacity(0.4), lineWidth: 1)
                )
                
                // 4. Hexa-Core Load Tape Matrix (6-Core Airspeed Tapes)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "cpu")
                            .foregroundColor(.blue)
                            .font(.system(size: 12, weight: .bold))
                        Text("CORE TELEMETRY TAPES")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("2P + 4E DUAL CLUSTER")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    HStack(spacing: 8) {
                        ForEach(0..<min(6, logManager.perCoreUsage.count), id: \.self) { i in
                            VStack(spacing: 3) {
                                Text(i < 2 ? "P\(i+1)" : "E\(i-1)")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundColor(i < 2 ? .orange : .blue)
                                
                                ZStack(alignment: .bottom) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color(UIColor.systemGray5))
                                        .frame(height: 50)
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(i < 2 ? Color.orange : Color.blue)
                                        .frame(height: max(2, CGFloat(logManager.perCoreUsage[i] / 100.0) * 50))
                                }
                                
                                Text("\(Int(logManager.perCoreUsage[i]))%")
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundColor(.primary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(14)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(UIColor.separator).opacity(0.4), lineWidth: 1)
                )
                
                // 5. Cockpit Waveform Instrument
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "waveform.path.ecg")
                            .foregroundColor(.orange)
                            .font(.system(size: 12, weight: .bold))
                        Text("FLIGHT RECORDER TELEMETRY")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(logManager.chartHistory.count) PTS · 120Hz")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    CockpitWaveformChart(records: logManager.chartHistory)
                }
                .padding(14)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(UIColor.separator).opacity(0.4), lineWidth: 1)
                )
                
                // 6. Master Flight Controls (제어반)
                VStack(spacing: 12) {
                    // Start/Stop Primary Button
                    Button(action: {
                        let impact = UIImpactFeedbackGenerator(style: .medium)
                        impact.impactOccurred()
                        if logManager.isRecording {
                            logManager.stopLogging()
                        } else {
                            logManager.startLogging()
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: logManager.isRecording ? "stop.circle.fill" : "record.circle.fill")
                                .font(.system(size: 16, weight: .bold))
                            Text(logManager.isRecording ? "STOP & SAVE LOG" : "START FLIGHT RECORDING")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(logManager.isRecording ? Color.red : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    
                    // Sampling Frequency Selector
                    HStack(spacing: 8) {
                        freqPill(label: "10 Hz (0.1s)", interval: 0.1)
                        freqPill(label: "2 Hz (0.5s)", interval: 0.5)
                        freqPill(label: "1 Hz (1.0s)", interval: 1.0)
                    }
                    
                    Divider().background(Color(UIColor.separator).opacity(0.3))
                    
                    // Background Keep-Alive Audio Toggle
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Background Audio Keep-Alive")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.primary)
                            Text("화면을 끄거나 타 앱 전환 시에도 0.1초 기록 유지")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { bgManager.isBackgroundModeActive },
                            set: { val in
                                if val {
                                    bgManager.startKeepAlive()
                                } else {
                                    bgManager.stopKeepAlive()
                                }
                            }
                        ))
                        .labelsHidden()
                        .tint(.blue)
                    }
                }
                .padding(14)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(UIColor.separator).opacity(0.4), lineWidth: 1)
                )
                
                // 7. Storage Footprint & Data Export Deck (용량 및 데이터)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "internaldrive")
                            .foregroundColor(.indigo)
                            .font(.system(size: 12, weight: .bold))
                        Text("STORAGE FOOTPRINT & EXPORT")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    
                    // Storage Meter Display
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("로그 파일 누적 용량")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                            Text(logManager.totalStorageString)
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .foregroundColor(.primary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("보유 세션")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                            Text("\(logManager.sessionFilesCount)개 파일")
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                .foregroundColor(.primary)
                        }
                    }
                    .padding(10)
                    .background(Color(UIColor.systemGray6))
                    .cornerRadius(8)
                    
                    // Action Buttons
                    HStack(spacing: 10) {
                        Button(action: {
                            if let url = logManager.exportCSV() {
                                shareURL = url
                                showShareSheet = true
                            }
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: "doc.text")
                                Text("CSV 공유")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.blue.opacity(0.1))
                            .foregroundColor(.blue)
                            .cornerRadius(8)
                        }
                        
                        Button(action: {
                            if let url = logManager.exportJSON() {
                                shareURL = url
                                showShareSheet = true
                            }
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: "curlybraces")
                                Text("JSON 공유")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.indigo.opacity(0.1))
                            .foregroundColor(.indigo)
                            .cornerRadius(8)
                        }
                        
                        Button(action: {
                            showDeleteConfirm = true
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "trash")
                                Text("삭제")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.red.opacity(0.1))
                            .foregroundColor(.red)
                            .cornerRadius(8)
                        }
                    }
                }
                .padding(14)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(UIColor.separator).opacity(0.4), lineWidth: 1)
                )
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 28)
        }
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        .preferredColorScheme(.light) // Force clean Apple native Light Mode!
        .sheet(isPresented: $showShareSheet) {
            if let url = shareURL {
                ShareSheet(activityItems: [url])
            }
        }
        .alert("로그 파일 전체 삭제", isPresented: $showDeleteConfirm) {
            Button("취소", role: .cancel) {}
            Button("모두 삭제", role: .destructive) {
                logManager.clearAllLogs()
            }
        } message: {
            Text("기기에 저장된 모든 CSV 및 JSON 텔레메트리 로그를 삭제하여 용량을 확보하시겠습니까?")
        }
    }
    
    // UI Helpers
    private func pfdGauge(title: String, value: String, subtitle: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .heavy, design: .monospaced))
                .foregroundColor(color)
            Text(subtitle)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(UIColor.separator).opacity(0.4), lineWidth: 1)
        )
    }
    
    private func zoneItem(label: String, temp: Double, desc: String, isTarget: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)
            Text(String(format: "%.1f°C", temp))
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(isTarget ? .secondary : tempColor(temp))
            Text(desc)
                .font(.system(size: 8))
                .foregroundColor(Color(UIColor.tertiaryLabel))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(UIColor.systemGray6))
        .cornerRadius(6)
    }
    
    private func freqPill(label: String, interval: Double) -> some View {
        let isSelected = logManager.samplingInterval == interval
        return Button(action: {
            logManager.updateSamplingInterval(interval)
        }) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(isSelected ? Color.blue : Color(UIColor.systemGray6))
                .foregroundColor(isSelected ? .white : .secondary)
                .cornerRadius(6)
        }
    }
    
    private func tempColor(_ temp: Double) -> Color {
        if temp < 42.0 {
            return Color.blue
        } else if temp < 60.0 {
            return Color.orange
        } else {
            return Color.red
        }
    }
}
