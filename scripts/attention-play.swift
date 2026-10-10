// workflow-dev — a persistent-context development workflow for Claude Code
// Copyright (C) 2026  lbecjx
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version. See LICENSE for the full text.
//
// Plays one sound file on one named audio output, on macOS (WD-0052).
// `afplay` can only use the system's default output, so a human wearing a
// headset would never hear an alert meant for the laptop's speakers. This
// helper finds the output by its name (as System Settings shows it), and plays
// the file there through AVAudioPlayer.currentDevice.
//
//   attention-play <device name> <file> [gain 0-1]   play, then exit 0
//   attention-play --list                 one output per line: <transport>\t<default>\t<name>
//
// Exit 1 when the device is not connected or the file cannot be played, so the
// caller can fall back to `afplay` on the default output instead of staying
// silent. scripts/attention-alert.sh compiles this once, with `swiftc`, when the
// human picks a device; it is never compiled in a hook.

import AVFoundation
import CoreAudio
import Foundation

func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 _ initial: T) -> T? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                             mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
    }
    return status == noErr ? value : nil
}

func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
          let text = value?.takeRetainedValue() else { return nil }
    return text as String
}

func hasOutput(_ device: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                             mScope: kAudioObjectPropertyScopeOutput,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
}

func outputDevices() -> [AudioObjectID] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.filter(hasOutput)
}

func transportName(_ device: AudioObjectID) -> String {
    switch property(device, kAudioDevicePropertyTransportType, UInt32(0)) ?? 0 {
    case kAudioDeviceTransportTypeBuiltIn: return "builtin"
    case kAudioDeviceTransportTypeUSB: return "usb"
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
    case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
    case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "virtual"
    case kAudioDeviceTransportTypeAirPlay: return "airplay"
    default: return "other"
    }
}

let args = CommandLine.arguments
if args.count == 2 && args[1] == "--list" {
    let defaultOut = property(AudioObjectID(kAudioObjectSystemObject),
                              kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
    for device in outputDevices() {
        guard let name = stringProperty(device, kAudioObjectPropertyName) else { continue }
        print("\(transportName(device))\t\(device == defaultOut ? "default" : "-")\t\(name)")
    }
    exit(0)
}
guard args.count == 3 || args.count == 4 else {
    FileHandle.standardError.write("usage: attention-play <device name> <file> [gain 0-1] | --list\n".data(using: .utf8)!)
    exit(2)
}
let gain = args.count == 4 ? min(max(Float(args[3]) ?? 1, 0), 1) : 1
let wanted = args[1]
guard let device = outputDevices().first(where: { stringProperty($0, kAudioObjectPropertyName) == wanted }),
      let uid = stringProperty(device, kAudioDevicePropertyDeviceUID),
      let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: args[2])) else {
    exit(1)
}
player.currentDevice = uid
player.volume = gain
guard player.play() else { exit(1) }
Thread.sleep(forTimeInterval: player.duration + 0.2)
exit(0)
