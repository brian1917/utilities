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

let toolVersion = "1.4"

let defaultPatterns = ["magic mouse", "magic keyboard", "magic trackpad"]

// MARK: - Controller power
//
// closeConnection() only drops the current link; it does not stop this Mac
// from accepting the device's next page. Since a woken Magic device pages the
// host it saw last, the only way to reliably hand it over is to make this
// Mac's radio unavailable for a window.
//
// IOBluetoothPreference{Get,Set}ControllerPowerState are private IOBluetooth
// symbols (this is what blueutil drives too), so resolve them at runtime
// rather than link against headers that don't declare them.

private typealias PowerGetFn = @convention(c) () -> Int32
private typealias PowerSetFn = @convention(c) (Int32) -> Void

private let ioBluetoothHandle: UnsafeMutableRawPointer? = dlopen(
    "/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)

func bluetoothPowerIsOn() -> Bool? {
    guard let h = ioBluetoothHandle,
          let sym = dlsym(h, "IOBluetoothPreferenceGetControllerPowerState") else { return nil }
    return unsafeBitCast(sym, to: PowerGetFn.self)() != 0
}

@discardableResult
func setBluetoothPower(_ on: Bool) -> Bool {
    guard let h = ioBluetoothHandle,
          let sym = dlsym(h, "IOBluetoothPreferenceSetControllerPowerState") else { return false }
    unsafeBitCast(sym, to: PowerSetFn.self)(on ? 1 : 0)
    // The daemon takes a moment; confirm rather than assume.
    for _ in 0..<20 {
        Thread.sleep(forTimeInterval: 0.1)
        if bluetoothPowerIsOn() == on { return true }
    }
    return false
}

/// Set while the radio is off on purpose, so an interrupt can put it back.
var radioIsOffByUs = false

func installRadioGuard() {
    let restore: @convention(c) (Int32) -> Void = { _ in
        if radioIsOffByUs { setBluetoothPower(true) }
        _exit(130)
    }
    signal(SIGINT, restore)
    signal(SIGTERM, restore)
    signal(SIGHUP, restore)
}

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

/// Decode the IOReturn codes that actually show up during a handoff.
func ioName(_ r: IOReturn) -> String {
    switch r {
    case kIOReturnSuccess:      return "success"
    case kIOReturnBusy:         return "busy — still linked to another host"
    case kIOReturnTimeout:      return "timeout — device never answered the page (asleep, or out of range)"
    case kIOReturnNoDevice:     return "noDevice — radio can't see it at all"
    case kIOReturnNotPermitted: return "notPermitted — grant Bluetooth access to whatever launched this"
    case kIOReturnNotAttached:  return "notAttached"
    case kIOReturnNotOpen:      return "notOpen"
    case kIOReturnError:        return "generic error"
    default:                    return String(format: "0x%08X", UInt32(bitPattern: r))
    }
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

func cmdRadio(_ arg: String?) -> Int32 {
    switch arg?.lowercased() {
    case "on":
        return setBluetoothPower(true) ? 0 : 1
    case "off":
        return setBluetoothPower(false) ? 0 : 1
    case nil, "status":
        guard let on = bluetoothPowerIsOn() else {
            note("Can't read controller power state."); return 1
        }
        print(on ? "on" : "off")
        return on ? 0 : 2
    default:
        note("radio takes: on | off | status"); return 64
    }
}

/// Dump everything IOBluetooth knows, so we can tell whether these devices are
/// classic BR/EDR (pageable, grab can work) or LE (they are not, and never will
/// be — IOBluetooth's openConnection has no LE path).
func cmdProbe(_ patterns: [String]) -> Int32 {
    let targets = patterns.isEmpty ? pairedDevices() : resolve(patterns)
    guard !targets.isEmpty else { return notFound(patterns) }

    if let on = bluetoothPowerIsOn() { print("controller power: \(on ? "on" : "off")\n") }

    for d in targets {
        let cod = d.classOfDevice
        let services = (d.services as? [IOBluetoothSDPServiceRecord])?.count ?? 0
        print("\(d.name ?? "(unnamed)")  \(d.addressString ?? "??")")
        print("  paired:         \(d.isPaired())")
        print("  connected:      \(d.isConnected())")
        print("  classOfDevice:  0x\(String(format: "%06X", cod))")
        print("  major/minor:    \(d.deviceClassMajor) / \(d.deviceClassMinor)")
        print("  SDP services:   \(services)")

        // A classic HID peripheral reports a non-zero class of device (a mouse
        // is major 5 / minor 0x80, a keyboard major 5 / minor 0x40) and carries
        // SDP records. An LE-only device shows up with neither.
        if cod == 0 && services == 0 {
            print("  transport:      LE (no class-of-device, no SDP)")
            print("                  → openConnection() cannot reach this. Use `wait`.")
        } else if d.deviceClassMajor == 5 {
            print("  transport:      classic BR/EDR HID — pageable, grab should work")
        } else {
            print("  transport:      unclear — classic fields present but not HID-shaped")
        }
        print("")
    }
    return 0
}

/// Passive counterpart to grab: never pages, just waits for macOS to bring the
/// device up on its own. This is the only thing that works for LE HID, where
/// the system HID stack owns reconnection and there is no public API to force it.
func cmdWait(_ patterns: [String], timeout: Double) -> Int32 {
    let targets = resolve(patterns)
    guard !targets.isEmpty else { return notFound(patterns) }

    let forever = timeout <= 0
    let deadline = Date().addingTimeInterval(forever ? 0 : timeout)
    var reported = Set<String>()

    note("Waiting for macOS to pick these up on its own (no paging). "
       + "Wake the device — move the mouse, tap a key.")

    while forever || Date() < deadline {
        var allUp = true
        for d in targets {
            let key = d.addressString ?? d.name ?? "?"
            if d.isConnected() {
                if reported.insert(key).inserted { print("connected      \(label(d))") }
            } else {
                allUp = false
            }
        }
        if allUp { return 0 }
        Thread.sleep(forTimeInterval: 0.5)
    }

    for d in targets where !d.isConnected() { print("still down     \(label(d))") }
    return 1
}

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
func cmdRelease(_ patterns: [String], delay: Double, hold: Double, radioOff: Double?) -> Int32 {
    let targets = resolve(patterns)
    guard !targets.isEmpty else { return notFound(patterns) }

    if delay > 0 {
        note("Releasing \(targets.count) device(s) in \(fmt(delay))s…")
        Thread.sleep(forTimeInterval: delay)
    }

    // Preferred path: drop the links, then take this Mac's radio off the air
    // so the device can't come straight back. Anything else just flaps.
    if let window = radioOff {
        for d in targets where d.isConnected() {
            _ = d.closeConnection()
            print("released       \(label(d))")
        }
        installRadioGuard()
        guard setBluetoothPower(false) else {
            note("Could not power down the Bluetooth controller. The private "
               + "IOBluetooth power symbols may be unavailable on this macOS build; "
               + "fall back to `blueutil -p 0`.")
            return 1
        }
        radioIsOffByUs = true
        note("Bluetooth OFF on this Mac. Run `magicswitch grab` on the other one NOW.")

        if window > 0 {
            Thread.sleep(forTimeInterval: window)
            setBluetoothPower(true)
            radioIsOffByUs = false
            note("Bluetooth back on. If the other Mac claimed the devices, they stay there.")
        } else {
            radioIsOffByUs = false   // deliberate: leave it off past exit
            note("Bluetooth left off. Re-enable with:  magicswitch radio on")
        }
        return 0
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
///
/// `pageTimeout` is in 0.625 ms units and is the important knob: the default
/// bare `openConnection()` pages for ~5 s, which is usually shorter than the
/// interval a sleeping Magic device waits between page scans, so the call
/// returns kIOReturnTimeout before the device ever listens. 0x8000 ≈ 20 s.
func cmdGrab(_ patterns: [String], timeout: Double, pageSeconds: Double, verbose: Bool) -> Int32 {
    var pending = resolve(patterns)
    guard !pending.isEmpty else { return notFound(patterns) }

    for d in pending where !d.isPaired() {
        note("WARNING: \(label(d)) is not paired with this Mac. Pair it in "
           + "System Settings → Bluetooth first; grab can only reconnect known devices.")
    }
    if verbose {
        note("magicswitch \(toolVersion)  page=\(fmt(pageSeconds))s  timeout=\(fmt(timeout))s")
        for d in pending {
            note("target \(label(d))  paired=\(d.isPaired())  connected=\(d.isConnected())")
        }
    }

    // HCI page timeout is a 16-bit count of 0.625 ms slots; cap at 0xFFFF (~41 s).
    let pageTimeout = UInt16(min(max(pageSeconds / 0.000625, 1), 65535))

    // openConnection blocks for up to pageSeconds PER DEVICE, so one full round
    // costs pageSeconds × count. If the overall timeout is smaller than that,
    // you get exactly one attempt and the retry loop is decorative. Guarantee
    // room for a few rounds instead.
    let roundCost = pageSeconds * Double(pending.count)
    let forever = timeout <= 0
    var budget = timeout
    if !forever && budget < roundCost * 3 {
        budget = roundCost * 3
        note("timeout raised to \(fmt(budget))s — \(fmt(pageSeconds))s page × \(pending.count) devices needs room to repeat")
    }

    // Say this BEFORE the first blocking page, not after: it's an instruction,
    // and it's useless once the window has already closed.
    note(">>> Nudge the mouse and tap a key NOW. A Magic device only listens for "
       + "pages while it's awake. <<<")

    let deadline = Date().addingTimeInterval(forever ? 0 : budget)
    var attempts = 0
    var lastError: [String: IOReturn] = [:]

    while !pending.isEmpty && (forever || Date() < deadline) {
        attempts += 1
        var stillPending: [IOBluetoothDevice] = []
        for d in pending {
            if d.isConnected() {
                print("connected      \(label(d))")
                continue
            }
            let result = d.openConnection(nil,
                                          withPageTimeout: pageTimeout,
                                          authenticationRequired: true)
            if result == kIOReturnSuccess && d.isConnected() {
                print("connected      \(label(d))")
                continue
            }
            let key = d.addressString ?? d.name ?? "?"
            if verbose || lastError[key] != result {
                note("  attempt \(attempts): \(d.name ?? "?") → \(ioName(result))")
            }
            lastError[key] = result
            stillPending.append(d)
        }
        pending = stillPending
        if !pending.isEmpty { Thread.sleep(forTimeInterval: 0.4) }
    }

    if pending.isEmpty { return 0 }
    for d in pending {
        let key = d.addressString ?? d.name ?? "?"
        print("unreachable    \(label(d))  last: \(ioName(lastError[key] ?? kIOReturnError))")
    }
    note("All attempts timed out. Check `magicswitch status` on the other Mac — "
       + "if it shows them connected there, they're not page-scanning and no "
       + "amount of paging from here will reach them.")
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
  magicswitch release [--radio-off S] [--delay S] [device …]
  magicswitch grab    [--timeout S] [--page S] [device …]
  magicswitch radio   [on | off | status]
  magicswitch probe   [device …]      what transport is this device really on?
  magicswitch wait    [--timeout S] [device …]
                                      passive: don't page, just wait for macOS
                                      to connect it. The LE path.

DEVICE
  A MAC address (aa:bb:cc:dd:ee:ff) or any substring of the device name.
  With no device given, defaults to: \(defaultPatterns.joined(separator: ", ")).

OPTIONS
  --delay S     release: wait S seconds first, so you can move your hand off
                the trackpad / finish typing. Default 0.
  --radio-off S THE ONE THAT WORKS. Drop the links, then power this Mac's
                Bluetooth controller down for S seconds so the device cannot
                page its way straight back. S=0 leaves it off until you run
                `magicswitch radio on`. Ctrl-C restores the radio.
  --hold S      Legacy: re-close the link for S seconds without touching the
                radio. This FLAPS — macOS keeps accepting the device's pages
                and it never settles into page-scan mode for the other Mac.
                Kept for diagnostics; prefer --radio-off. Default 12.
  --timeout S   grab: give up after S seconds. 0 = wait forever. Default 45.
                Raised automatically if it can't fit ~3 rounds of paging.
  --page S      grab: how long each connect attempt pages for, in seconds.
                Costs this much PER DEVICE per round. Default 6 — short enough
                to retry often while you're waking the device by hand.
  --verbose     print per-attempt IOReturn codes.

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
var hold: Double = 12
var timeout: Double = 45
var pageSeconds: Double = 6
var radioOff: Double? = nil
var verbose = false
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
    case "--page":    pageSeconds = value("--page")
    case "--radio-off": radioOff = value("--radio-off")
    case "--verbose", "-V": verbose = true
    default:
        if a.hasPrefix("--") { note("Unknown option \(a)"); exit(64) }
        devices.append(a)
    }
    i += 1
}

switch command {
case "list":    exit(cmdList())
case "status":  exit(cmdStatus(devices))
case "radio":
    exit(cmdRadio(devices.first))
case "probe":
    exit(cmdProbe(devices))
case "wait":
    exit(cmdWait(devices, timeout: timeout))
case "release", "disconnect", "drop":
    exit(cmdRelease(devices, delay: delay, hold: hold, radioOff: radioOff))
case "grab", "connect", "take":
    exit(cmdGrab(devices, timeout: timeout, pageSeconds: pageSeconds, verbose: verbose))
default:
    note("Unknown command '\(command)'.\n")
    print(usage)
    exit(64)
}
