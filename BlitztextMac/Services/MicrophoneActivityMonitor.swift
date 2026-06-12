import CoreAudio

/// Prüft über CoreAudio, ob das Standard-Eingabegerät (Mikrofon) gerade von
/// irgendeinem Prozess benutzt wird. Grundlage für die Meeting-Erkennung bei
/// Apps, die dauerhaft im Hintergrund laufen (z. B. Microsoft Teams): dort
/// löst der App-Start nichts aus, die Mikrofon-Aktivität schon.
enum MicrophoneActivityMonitor {
    /// True, wenn das Standard-Eingabegerät von irgendeinem Prozess läuft
    /// (kAudioDevicePropertyDeviceIsRunningSomewhere). Jeder Fehler → false.
    static func isDefaultInputInUse() -> Bool {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var deviceIDSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let deviceStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            0,
            nil,
            &deviceIDSize,
            &deviceID
        )
        guard deviceStatus == noErr, deviceID != kAudioObjectUnknown else { return false }

        var isRunning: UInt32 = 0
        var isRunningSize = UInt32(MemoryLayout<UInt32>.size)
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let runningStatus = AudioObjectGetPropertyData(
            deviceID,
            &runningAddress,
            0,
            nil,
            &isRunningSize,
            &isRunning
        )
        guard runningStatus == noErr else { return false }
        return isRunning != 0
    }
}
