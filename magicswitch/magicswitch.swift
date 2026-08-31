// magicswitch.swift — release / grab Apple Magic input devices between Macs.
//
// Build:
//   swiftc -O -o magicswitch magicswitch.swift -framework Foundation -framework IOBluetooth
//
// Both Macs must already be paired with the device. Classic-Bluetooth HID
// devices hold exactly one host link at a time, so the handoff is:
//   Mac A:  magicswitch release      (drop the link)
//   Mac B:  magicswitch grab         (claim it)

import Foundation
import IOBluetooth

let toolVersion = "1.0"

let defaultPatterns = ["magic mouse", "magic keyboard", "magic trackpad"]

// MARK: - Device lookup

func normalize(_ s: String) -> String {
    s.lowercased()
        .replacingOccurrences(of: ":", with: "-")
        .trimmingCharacters(in: .whitespaces)
}

func pairedDevices() -> [IOBluetoothDevice] {
    (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
}

func label(_ d: IOBluetoothDevice) -> String {
    "\(d.name ?? "(unnamed)")  \(d.addressString ?? "??")"
}

/// A pattern matches on exact MAC address (":" or "-" separated) or a
/// case-insensitive substring of the device name.
func matches(_ d: IOBluetoothDevice, _ patterns: [String]) -> Bool {
    let name = normalize(d.name ?? "")
    let addr = normalize(d.addressString ?? "")
    return patterns.contains { raw in
        let p = normalize(raw)
        return !p.isEmpty && (addr == p || name.contains(p))
    }
}

func resolve(_ patterns: [String]) -> [IOBluetoothDevice] {
    let list = patterns.isEmpty ? defaultPatterns : patterns
    return pairedDevices().filter { matches($0, list) }
}

// MARK: - Commands

func cmdList() -> Int32 {
    let devices = pairedDevices()
    if devices.isEmpty {
        FileHandle.standardError.write("No paired Bluetooth devices found.\n".data(using: .utf8)!)
        return 1
    }
    for d in devices {
        let state = d.isConnected() ? "connected   " : "disconnected"
        print("\(state)  \(label(d))")
    }
    return 0
}

func cmdStatus(_ patterns: [String]) -> Int32 {
    let targets = resolve(patterns)
    guard !targets.isEmpty else { return notFound(patterns) }
    var anyConnected = false
    for d in targets {
        let connected = d.isConnected()
        anyConnected = anyConnected || connected
        print("\(connected ? "connected   " : "disconnected")  \(label(d))")
    }
    // exit 0 when at least one target is connected, 2 when none are.
    return anyConnected ? 0 : 2
}

/// Close the baseband link so another host can take the device.
/// `hold` keeps re-closing for N seconds, which defeats macOS's habit of
/// immediately re-opening the link when the HID manager sees the device.
func cmdRelease(_ patterns: [String], delay: Double, hold: Double) -> Int32 {
    let targets = resolve(patterns)
    guard !targets.isEmpty else { return notFound(patterns) }

    if delay > 0 {
        note("Releasing \(targets.count) device(s) in \(fmt(delay))s…")
        Thread.sleep(forTimeInterval: delay)
    }

    var announced = Set<String>()
    var failed = Set<String>()
    let deadline = Date().addingTimeInterval(max(hold, 0))

    repeat {
        for d in targets {
            let key = d.addressString ?? d.name ?? UUID().uuidString
            guard d.isConnected() else {
                if announced.insert(key).inserted {
                    print("already free   \(label(d))")
                }
                continue
            }
            let result = d.closeConnection()
            if result == kIOReturnSuccess {
                failed.remove(key)
                if announced.insert(key).inserted {
                    print("released       \(label(d))")
                }
            } else {
                failed.insert(key)
                if announced.insert(key).inserted {
                    print("FAILED (\(result))  \(label(d))")
                }
            }
        }
        if hold > 0 { Thread.sleep(forTimeInterval: 0.35) }
    } while Date() < deadline

    return failed.isEmpty ? 0 : 1
}

/// Open the link from this Mac. Retries until every target is connected or
/// the timeout expires (timeout 0 = wait forever).
func cmdGrab(_ patterns: [String], timeout: Double) -> Int32 {
    var pending = resolve(patterns)
    guard !pending.isEmpty else { return notFound(patterns) }

    let forever = timeout <= 0
    let deadline = Date().addingTimeInterval(forever ? 0 : timeout)
    var attempts = 0

    while !pending.isEmpty && (forever || Date() < deadline) {
        attempts += 1
        var stillPending: [IOBluetoothDevice] = []
        for d in pending {
            if d.isConnected() {
                print("connected      \(label(d))")
                continue
            }
            // Synchronous; blocks a few seconds while the radio negotiates.
            let result = d.openConnection()
            if result == kIOReturnSuccess && d.isConnected() {
                print("connected      \(label(d))")
            } else {
                stillPending.append(d)
            }
        }
        pending = stillPending
        if !pending.isEmpty {
            if attempts == 1 {
                note("Waiting for: \(pending.map { $0.name ?? "?" }.joined(separator: ", ")) — make sure the other Mac has released it.")
            }
            Thread.sleep(forTimeInterval: 0.75)
        }
    }

    if pending.isEmpty { return 0 }
    for d in pending { print("unreachable    \(label(d))") }
    return 1
}

// MARK: - Plumbing

func note(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func fmt(_ d: Double) -> String {
    d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d)
}

func notFound(_ patterns: [String]) -> Int32 {
    let what = patterns.isEmpty
        ? "any Magic mouse/keyboard/trackpad"
        : patterns.joined(separator: ", ")
    note("No paired device matched \(what). Run `magicswitch list` to see what this Mac knows about.")
    return 1
}

let usage = """
magicswitch \(toolVersion) — hand Apple Magic input devices between Macs.

USAGE
  magicswitch list
  magicswitch status  [device …]
  magicswitch release [--delay S] [--hold S] [device …]
  magicswitch grab    [--timeout S] [device …]

DEVICE
  A MAC address (aa:bb:cc:dd:ee:ff) or any substring of the device name.
  With no device given, defaults to: \(defaultPatterns.joined(separator: ", ")).

OPTIONS
  --delay S     release: wait S seconds first, so you can move your hand off
                the trackpad / finish typing. Default 0.
  --hold S      release: keep the link closed for S seconds, defeating macOS's
                automatic re-connect. Default 3.
  --timeout S   grab: give up after S seconds. 0 = wait forever. Default 20.

EXIT CODES
  0 success · 1 failure or no match · 2 (status) nothing connected
"""

// MARK: - Argument parsing

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print(usage)
    exit(0)
}
args.removeFirst()

if ["-h", "--help", "help"].contains(command) { print(usage); exit(0) }
if ["-v", "--version"].contains(command) { print(toolVersion); exit(0) }

var delay: Double = 0
var hold: Double = 3
var timeout: Double = 20
var devices: [String] = []

var i = 0
while i < args.count {
    let a = args[i]
    func value(_ name: String) -> Double {
        guard i + 1 < args.count, let v = Double(args[i + 1]) else {
            note("\(name) needs a number of seconds."); exit(64)
        }
        i += 1
        return v
    }
    switch a {
    case "--delay":   delay = value("--delay")
    case "--hold":    hold = value("--hold")
    case "--timeout": timeout = value("--timeout")
    default:
        if a.hasPrefix("--") { note("Unknown option \(a)"); exit(64) }
        devices.append(a)
    }
    i += 1
}

switch command {
case "list":    exit(cmdList())
case "status":  exit(cmdStatus(devices))
case "release", "disconnect", "drop":
    exit(cmdRelease(devices, delay: delay, hold: hold))
case "grab", "connect", "take":
    exit(cmdGrab(devices, timeout: timeout))
default:
    note("Unknown command '\(command)'.\n")
    print(usage)
    exit(64)
}
