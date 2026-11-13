import Foundation
import AVFoundation

public class BackgroundAudioManager: ObservableObject {
    public static let shared = BackgroundAudioManager()
    
    @Published public var isBackgroundModeActive: Bool = false
    private var audioPlayer: AVAudioPlayer?
    
    private init() {}
    
    public func startKeepAlive() {
        guard !isBackgroundModeActive else { return }
        
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .duckOthers])
            try session.setActive(true)
            
            // Generate a 1-second silent WAV in memory
            let silentWavData = createSilentWav()
            audioPlayer = try AVAudioPlayer(data: silentWavData)
            audioPlayer?.numberOfLoops = -1 // Infinite loop
            audioPlayer?.volume = 0.0 // True silence
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            
            isBackgroundModeActive = true
            print("[ThermalCore] Background audio keep-alive activated.")
        } catch {
            print("[ThermalCore] Failed to activate background audio: \(error)")
        }
    }
    
    public func stopKeepAlive() {
        guard isBackgroundModeActive else { return }
        
        audioPlayer?.stop()
        audioPlayer = nil
        
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("[ThermalCore] Error deactivating audio session: \(error)")
        }
        
        isBackgroundModeActive = false
        print("[ThermalCore] Background audio keep-alive stopped.")
    }
    
    private func createSilentWav() -> Data {
        // Standard 44-byte WAV header for 1 second of 8000Hz 8-bit mono silence (0x80)
        let sampleRate: UInt32 = 8000
        let numSamples: UInt32 = 8000 // 1 second
        let subchunk2Size: UInt32 = numSamples * 1 * 1
        let chunkSize: UInt32 = 36 + subchunk2Size
        
        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(withUnsafeBytes(of: chunkSize.littleEndian) { Data($0) })
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        
        let subchunk1Size: UInt32 = 16
        let audioFormat: UInt16 = 1 // PCM
        let numChannels: UInt16 = 1 // Mono
        let byteRate: UInt32 = sampleRate * 1 * 1
        let blockAlign: UInt16 = 1
        let bitsPerSample: UInt16 = 8
        
        data.append(withUnsafeBytes(of: subchunk1Size.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: audioFormat.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: numChannels.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        
        data.append("data".data(using: .ascii)!)
        data.append(withUnsafeBytes(of: subchunk2Size.littleEndian) { Data($0) })
        
        // 1 second of 0x80 (PCM 8-bit silent center)
        let silence = [UInt8](repeating: 0x80, count: Int(numSamples))
        data.append(contentsOf: silence)
        
        return data
    }
}
