import SwiftUI
import UIKit

// MARK: - ShareSheet Helper
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Live Waveform Canvas
struct ThermalWaveformChart: View {
    let records: [TelemetryRecord]
    
    var body: some View {
        Canvas { context, size in
            guard records.count > 1 else { return }
            
            let minTemp: Double = 25.0
            let maxTemp: Double = 95.0
            let tempRange = maxTemp - minTemp
            
            // Draw horizontal grid lines (35, 50, 65, 80)
            let gridTemps: [Double] = [35.0, 50.0, 65.0, 80.0]
            for gTemp in gridTemps {
                let yNorm = 1.0 - (gTemp - minTemp) / tempRange
                let yPos = CGFloat(yNorm) * size.height
                
                var gridPath = Path()
                gridPath.move(to: CGPoint(x: 0, y: yPos))
                gridPath.addLine(to: CGPoint(x: size.width, y: yPos))
                context.stroke(gridPath, with: .color(Color.gray.opacity(0.18)), lineWidth: 1)
                
                context.draw(
                    Text("\(Int(gTemp))°C").font(.system(size: 9, design: .monospaced)).foregroundColor(.gray.opacity(0.6)),
                    at: CGPoint(x: 18, y: yPos - 6)
                )
            }
            
            // Path for temperature curve
            var linePath = Path()
            var fillPath = Path()
            
            let stepX = size.width / CGFloat(max(1, records.count - 1))
            
            for (index, record) in records.enumerated() {
                let x = CGFloat(index) * stepX
                let clampedTemp = max(minTemp, min(record.cpuTemp, maxTemp))
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
            
            if let last = records.last {
                let lastX = CGFloat(records.count - 1) * stepX
                fillPath.addLine(to: CGPoint(x: lastX, y: size.height))
                fillPath.closeSubpath()
            }
            
            // Gradient fill under curve
            let gradient = Gradient(colors: [
                Color.orange.opacity(0.35),
                Color.red.opacity(0.15),
                Color.clear
            ])
            context.fill(fillPath, with: .linearGradient(gradient, startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
            
            // Stroke curve
            context.stroke(linePath, with: .color(Color(red: 1.0, green: 0.42, blue: 0.0)), lineWidth: 2.2)
        }
        .frame(height: 140)
        .background(Color.black.opacity(0.4))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Main Diagnostic View
struct ContentView: View {
    @StateObject private var logManager = LogManager.shared
    @StateObject private var bgManager = BackgroundAudioManager.shared
    
    @State private var shareURL: URL?
    @State private var showShareSheet = false
    
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                // Header Deck
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("⚡ ThermalCore")
                                .font(.system(size: 22, weight: .black, design: .rounded))
                                .foregroundColor(.white)
                            Text("PRO")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.25))
                                .foregroundColor(.orange)
                                .cornerRadius(4)
                        }
                        Text("Apple A17 Pro · 6 Cores · 8 GB RAM")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                    Spacer()
                    
                    // Live Status Beacon
                    HStack(spacing: 6) {
                        Circle()
                            .fill(logManager.isRecording ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                            .shadow(color: logManager.isRecording ? Color.green.opacity(0.8) : Color.clear, radius: 4)
                        Text(logManager.isRecording ? "\(Int(1.0 / logManager.samplingInterval)) Hz" : "IDLE")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(logManager.isRecording ? .green : .gray)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(UIColor.secondarySystemBackground).opacity(0.4))
                    .cornerRadius(8)
                }
                .padding(.horizontal, 4)
                .padding(.top, 4)
                
                // 1. Hero Temperature Gauge Card
                VStack(spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("CPU DIE TEMPERATURE")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.gray)
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(String(format: "%.1f", logManager.currentTemp))
                                    .font(.system(size: 54, weight: .black, design: .rounded))
                                    .foregroundColor(tempColor(logManager.currentTemp))
                                Text("°C")
                                    .font(.system(size: 24, weight: .bold, design: .rounded))
                                    .foregroundColor(.gray)
                            }
                        }
                        Spacer()
                        
                        // Thermal State Pill Badge
                        VStack(alignment: .trailing, spacing: 6) {
                            Text(logManager.thermalStateText)
                                .font(.system(size: 11, weight: .black, design: .monospaced))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(thermalColor(logManager.thermalStateText).opacity(0.2))
                                .foregroundColor(thermalColor(logManager.thermalStateText))
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(thermalColor(logManager.thermalStateText).opacity(0.4), lineWidth: 1)
                                )
                            
                            HStack(spacing: 4) {
                                Image(systemName: logManager.isHardwareSensor ? "cpu" : "waveform.path")
                                    .font(.system(size: 10))
                                Text(logManager.isHardwareSensor ? "IOKit PMU" : "Fusion Sensor")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundColor(.gray)
                        }
                    }
                    
                    Divider().background(Color.gray.opacity(0.25))
                    
                    // Min / Max / Avg Metrics Bar
                    HStack(spacing: 12) {
                        statItem(label: "MIN", value: String(format: "%.1f°C", logManager.minTemp < 100 ? logManager.minTemp : logManager.currentTemp), color: .cyan)
                        Spacer()
                        statItem(label: "AVG", value: String(format: "%.1f°C", logManager.avgTemp > 0 ? logManager.avgTemp : logManager.currentTemp), color: .orange)
                        Spacer()
                        statItem(label: "MAX", value: String(format: "%.1f°C", logManager.maxTemp > 0 ? logManager.maxTemp : logManager.currentTemp), color: .red)
                        Spacer()
                        statItem(label: "SAMPLES", value: "\(logManager.sampleCount)", color: .white)
                    }
                }
                .padding(18)
                .background(Color(UIColor.secondarySystemBackground).opacity(0.35))
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(tempColor(logManager.currentTemp).opacity(0.35), lineWidth: 1)
                )
                
                // 2. Real-time Waveform Chart
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "chart.xyaxis.line")
                            .font(.system(size: 13))
                            .foregroundColor(.orange)
                        Text("REAL-TIME THERMAL TELEMETRY")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                        Spacer()
                        Text(logManager.isRecording ? "Live (\(logManager.chartHistory.count) pts)" : "Paused")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                    
                    ThermalWaveformChart(records: logManager.chartHistory)
                }
                .padding(16)
                .background(Color(UIColor.secondarySystemBackground).opacity(0.35))
                .cornerRadius(16)
                
                // 3. Control Deck
                VStack(spacing: 14) {
                    HStack(spacing: 12) {
                        // Start/Stop Primary Action
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
                                Image(systemName: logManager.isRecording ? "stop.fill" : "record.circle.fill")
                                    .font(.headline)
                                Text(logManager.isRecording ? "STOP RECORDING" : "START LOGGING")
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(logManager.isRecording ? Color.red.opacity(0.85) : Color.orange)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                            .shadow(color: (logManager.isRecording ? Color.red : Color.orange).opacity(0.4), radius: 8)
                        }
                        
                        // Clear Button
                        Button(action: {
                            let gen = UINotificationFeedbackGenerator()
                            gen.notificationOccurred(.warning)
                            logManager.clearData()
                        }) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.gray)
                                .frame(width: 48, height: 48)
                                .background(Color.white.opacity(0.08))
                                .cornerRadius(12)
                        }
                    }
                    
                    // Sampling Frequency Selector
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SAMPLING FREQUENCY")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.gray)
                        
                        HStack(spacing: 8) {
                            freqButton(label: "0.1s (10 Hz)", interval: 0.1)
                            freqButton(label: "0.5s (2 Hz)", interval: 0.5)
                            freqButton(label: "1.0s (1 Hz)", interval: 1.0)
                        }
                    }
                    
                    Divider().background(Color.gray.opacity(0.2))
                    
                    // Background Keep-Alive Toggle
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Background Audio Keep-Alive")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                            Text("화면 소등 및 타 앱 사용 중에도 0.1초 기록 유지")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { bgManager.isBackgroundModeActive },
                            set: { newValue in
                                if newValue {
                                    bgManager.startKeepAlive()
                                } else {
                                    bgManager.stopKeepAlive()
                                }
                            }
                        ))
                        .labelsHidden()
                        .tint(.orange)
                    }
                }
                .padding(16)
                .background(Color(UIColor.secondarySystemBackground).opacity(0.35))
                .cornerRadius(16)
                
                // 4. System Telemetry Deck
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "cpu")
                            .foregroundColor(.cyan)
                        Text("HARDWARE TELEMETRY")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                        Spacer()
                        Text("6 CORES")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                    
                    HStack {
                        metricRow(title: "CPU Load", val: String(format: "%.1f%%", logManager.totalCpuUsage), icon: "gauge")
                        Spacer()
                        metricRow(title: "RAM (App/Total)", val: "\(Int(logManager.ramUsedMB))MB / \(String(format: "%.0fGB", logManager.ramTotalGB))", icon: "memorychip")
                        Spacer()
                        metricRow(title: "Battery", val: "\(logManager.batteryLevel)% \(logManager.isCharging ? "⚡" : "")", icon: "battery.100")
                    }
                    
                    // Core mini load bars
                    if !logManager.perCoreUsage.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("PER-CORE WORKLOAD (2P + 4E)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.gray)
                            HStack(spacing: 4) {
                                ForEach(0..<logManager.perCoreUsage.count, id: \.self) { i in
                                    VStack(spacing: 2) {
                                        Text("C\(i+1)")
                                            .font(.system(size: 8, design: .monospaced))
                                            .foregroundColor(.gray)
                                        ZStack(alignment: .bottom) {
                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(Color.gray.opacity(0.2))
                                                .frame(height: 32)
                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(i < 2 ? Color.orange : Color.cyan)
                                                .frame(height: CGFloat(logManager.perCoreUsage[i] / 100.0) * 32)
                                        }
                                        Text("\(Int(logManager.perCoreUsage[i]))%")
                                            .font(.system(size: 8, design: .monospaced))
                                            .foregroundColor(.white)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .background(Color(UIColor.secondarySystemBackground).opacity(0.35))
                .cornerRadius(16)
                
                // 5. Export Deck
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundColor(.yellow)
                        Text("DATA EXPORT & LOGS")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                        Spacer()
                        Text("\(logManager.sampleCount) Recorded")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                    
                    HStack(spacing: 12) {
                        Button(action: {
                            if let url = logManager.exportCSV() {
                                shareURL = url
                                showShareSheet = true
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "tablecells")
                                Text("EXPORT CSV")
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.yellow.opacity(0.2))
                            .foregroundColor(.yellow)
                            .cornerRadius(10)
                        }
                        
                        Button(action: {
                            if let url = logManager.exportJSON() {
                                shareURL = url
                                showShareSheet = true
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "curlybraces")
                                Text("EXPORT JSON")
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.cyan.opacity(0.2))
                            .foregroundColor(.cyan)
                            .cornerRadius(10)
                        }
                    }
                }
                .padding(16)
                .background(Color(UIColor.secondarySystemBackground).opacity(0.35))
                .cornerRadius(16)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Color(red: 0.05, green: 0.05, blue: 0.07).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showShareSheet) {
            if let url = shareURL {
                ShareSheet(activityItems: [url])
            }
        }
    }
    
    // Helpers
    private func tempColor(_ temp: Double) -> Color {
        if temp < 45.0 {
            return Color.cyan
        } else if temp < 65.0 {
            return Color.orange
        } else {
            return Color(red: 1.0, green: 0.25, blue: 0.25)
        }
    }
    
    private func thermalColor(_ state: String) -> Color {
        switch state {
        case "NOMINAL":  return .green
        case "FAIR":     return .yellow
        case "SERIOUS":  return .orange
        case "CRITICAL": return .red
        default:         return .gray
        }
    }
    
    private func statItem(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.gray)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(color)
        }
    }
    
    private func metricRow(title: String, val: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
                Text(title)
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
            Text(val)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
        }
    }
    
    private func freqButton(label: String, interval: Double) -> some View {
        let isSelected = logManager.samplingInterval == interval
        return Button(action: {
            logManager.samplingInterval = interval
        }) {
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(isSelected ? Color.orange.opacity(0.3) : Color.white.opacity(0.06))
                .foregroundColor(isSelected ? .orange : .gray)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.orange : Color.clear, lineWidth: 1)
                )
        }
    }
}
