import AudioToolbox
import CoreAudio
import Foundation

/// Fängt das Audio einer Gruppe von Prozessen ab (Core Audio Process Tap, macOS 14.2+),
/// schaltet das Original stumm und spielt es mit eigener Verstärkung auf dem Ausgabegerät ab.
///
/// Aufbau: Tap (stummgeschaltetes Original) → private Aggregate-Device (Tap als Eingang,
/// Ausgabegerät als Ausgang) → IOProc kopiert Eingang × Gain in den Ausgang.
final class ProcessTap {
    let processObjects: [AudioObjectID]
    let outputUID: String

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    /// Ziel-Gain (vom Main-Thread geschrieben) und aktueller Gain (nur im IO-Thread benutzt).
    /// Ein einzelnes ausgerichtetes Float wird atomar gelesen/geschrieben; für die Rampe genügt das.
    private let targetGain = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let currentGain = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    init(processObjects: [AudioObjectID], outputDevice: AudioDeviceID, outputUID: String,
         name: String, gain: Float) throws {
        self.processObjects = processObjects
        self.outputUID = outputUID
        targetGain.initialize(to: gain)
        currentGain.initialize(to: gain)

        do {
            try createTap(name: name)
            try createAggregate(name: name)
            try start(inputStreamsToSkip: CA.streamCount(outputDevice, scope: kAudioObjectPropertyScopeInput))
        } catch {
            invalidate()
            throw error
        }
    }

    deinit {
        invalidate()
        targetGain.deallocate()
        currentGain.deallocate()
    }

    func setGain(_ gain: Float) {
        targetGain.pointee = gain
    }

    func invalidate() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: Einrichtung

    private var tapUUID = UUID()

    private func createTap(name: String) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.uuid = tapUUID
        description.name = "AppVolume – \(name)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Erzeugen des Process Taps")
    }

    private func createAggregate(name: String) throws {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AppVolume – \(name)",
            kAudioAggregateDeviceUIDKey: "AppVolume-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
        ]
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
                  "Erzeugen des Aggregate-Device")
    }

    private func start(inputStreamsToSkip: Int) throws {
        let target = targetGain
        let current = currentGain
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, inInput, _, outOutput, _ in
            ProcessTap.render(input: inInput, output: outOutput, skipInputBuffers: inputStreamsToSkip,
                              target: target, current: current)
        }, "Anlegen der IOProc")
        try check(AudioDeviceStart(aggregateID, ioProcID), "Starten des Aggregate-Device")
    }

    // MARK: Echtzeit-Verarbeitung (keine Allokationen, keine Locks)

    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               skipInputBuffers: Int,
                               target: UnsafeMutablePointer<Float>,
                               current: UnsafeMutablePointer<Float>) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        // Eingang des Aggregats = Eingänge des Ausgabegeräts (falls vorhanden) + Tap. Der Tap kommt zuletzt.
        let firstTapBuffer = inList.count > skipInputBuffers ? skipInputBuffers : max(inList.count - 1, 0)

        var inChannels = 0
        var inFrames = Int.max
        for i in firstTapBuffer..<inList.count {
            let ch = Int(inList[i].mNumberChannels)
            guard ch > 0, inList[i].mData != nil else { continue }
            inChannels += ch
            inFrames = min(inFrames, Int(inList[i].mDataByteSize) / (ch * MemoryLayout<Float>.size))
        }

        var outChannels = 0
        var outFrames = Int.max
        for b in 0..<outList.count {
            let ch = Int(outList[b].mNumberChannels)
            guard ch > 0 else { continue }
            outChannels += ch
            outFrames = min(outFrames, Int(outList[b].mDataByteSize) / (ch * MemoryLayout<Float>.size))
        }

        guard inChannels > 0, outChannels > 0, inFrames != .max, outFrames != .max else {
            for b in 0..<outList.count where outList[b].mData != nil {
                memset(outList[b].mData, 0, Int(outList[b].mDataByteSize))
            }
            return
        }
        let frames = min(inFrames, outFrames)

        // Liest Sample (Kanal, Frame) aus dem Tap – funktioniert für interleaved und non-interleaved.
        @inline(__always) func sample(_ channel: Int, _ frame: Int) -> Float {
            var c = channel
            for i in firstTapBuffer..<inList.count {
                let ch = Int(inList[i].mNumberChannels)
                if c < ch, let data = inList[i].mData {
                    return data.assumingMemoryBound(to: Float.self)[frame * ch + c]
                }
                c -= ch
            }
            return 0
        }

        let start = current.pointee
        let end = target.pointee
        let step = frames > 0 ? (end - start) / Float(frames) : 0

        var globalChannel = 0
        for b in 0..<outList.count {
            let ch = Int(outList[b].mNumberChannels)
            guard ch > 0, let data = outList[b].mData?.assumingMemoryBound(to: Float.self) else {
                globalChannel += ch
                continue
            }
            let totalSamples = Int(outList[b].mDataByteSize) / MemoryLayout<Float>.size
            for f in 0..<frames {
                let gain = start + step * Float(f + 1)
                for c in 0..<ch {
                    let g = globalChannel + c
                    let value: Float
                    if outChannels == 1 {
                        value = inChannels >= 2 ? (sample(0, f) + sample(1, f)) * 0.5 : sample(0, f)
                    } else if g < inChannels {
                        value = sample(g, f)
                    } else if inChannels == 1 {
                        value = sample(0, f)
                    } else {
                        value = 0
                    }
                    data[f * ch + c] = value * gain
                }
            }
            // Rest (falls Ausgang mehr Frames erwartet) mit Stille füllen.
            if frames * ch < totalSamples {
                (data + frames * ch).update(repeating: 0, count: totalSamples - frames * ch)
            }
            globalChannel += ch
        }
        current.pointee = end
    }
}
