// ThrottleBar: menu bar indicator for CPU throttling on Apple Silicon Macs.
//
// Two signals, both readable without root:
//  1. macOS thermal pressure level (libnotify key "com.apple.system.thermalpressurelevel"):
//     0 nominal, 1 moderate, 2 heavy, 3 trapping, 4 sleeping.
//  2. Real CPU clock: per-core residency in each DVFS state (private IOReport framework,
//     group "CPU Stats" / "CPU Core Performance States"), mapped to frequencies from the
//     pmgr device's "voltage-states*-sram" tables in the IORegistry.
// Shown value = average clock of the busy P-cores in % of the chip's highest P-core clock.
// Only meaningful under load (an idle Mac also clocks down), so it shows "–" when P-cores are idle.

import AppKit
import IOKit
import ServiceManagement
import notify

// MARK: - Helpers (same style as AIUsageBar)

final class ActionItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, state: NSControl.StateValue = .off, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        self.target = self
        self.state = state
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}

func infoItem(_ s: String) -> NSMenuItem {
    let i = NSMenuItem(title: s, action: nil, keyEquivalent: "")
    i.isEnabled = false
    return i
}

let isGerman = Locale.preferredLanguages.first?.hasPrefix("de") ?? false
func L(_ en: String, _ de: String) -> String { isGerman ? de : en }

func ghz(_ mhz: Double) -> String { String(format: "%.2f GHz", mhz / 1000) }

func fmtDuration(_ t: TimeInterval) -> String {
    let m = Int(t / 60)
    return m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60) min"
}

// MARK: - Thermal pressure

enum Pressure: Int {
    case nominal = 0, moderate, heavy, trapping, sleeping
    var label: String {
        switch self {
        case .nominal: return L("normal", "normal")
        case .moderate: return L("moderate", "mäßig")
        case .heavy: return L("heavy", "stark")
        case .trapping: return L("critical", "kritisch")
        case .sleeping: return L("max", "max")
        }
    }
}

final class PressureReader {
    private var token: Int32 = 0
    private let ok: Bool
    init() { ok = notify_register_check("com.apple.system.thermalpressurelevel", &token) == UInt32(NOTIFY_STATUS_OK) }
    func read() -> Pressure {
        if ok {
            var st: UInt64 = 0
            if notify_get_state(token, &st) == UInt32(NOTIFY_STATUS_OK) { return Pressure(rawValue: Int(min(st, 4))) ?? .nominal }
        }
        // Fallback: public, coarser API
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .moderate
        case .serious: return .heavy
        case .critical: return .trapping
        @unknown default: return .nominal
        }
    }
}

// MARK: - IOReport (private framework, /usr/lib/libIOReport.dylib)

typealias IOReportSubscriptionRef = OpaquePointer

@_silgen_name("IOReportCopyChannelsInGroup")
func IOReportCopyChannelsInGroup(_ group: CFString?, _ subgroup: CFString?, _ a: UInt64, _ b: UInt64, _ c: UInt64) -> Unmanaged<CFMutableDictionary>?
@_silgen_name("IOReportCreateSubscription")
func IOReportCreateSubscription(_ a: UnsafeMutableRawPointer?, _ channels: CFMutableDictionary, _ sub: UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, _ b: UInt64, _ c: CFTypeRef?) -> IOReportSubscriptionRef?
@_silgen_name("IOReportCreateSamples")
func IOReportCreateSamples(_ s: IOReportSubscriptionRef, _ sub: CFMutableDictionary, _ a: CFTypeRef?) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportCreateSamplesDelta")
func IOReportCreateSamplesDelta(_ a: CFDictionary, _ b: CFDictionary, _ c: CFTypeRef?) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportChannelGetChannelName")
func IOReportChannelGetChannelName(_ ch: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportStateGetCount")
func IOReportStateGetCount(_ ch: CFDictionary) -> Int32
@_silgen_name("IOReportStateGetNameForIndex")
func IOReportStateGetNameForIndex(_ ch: CFDictionary, _ i: Int32) -> Unmanaged<CFString>?
@_silgen_name("IOReportStateGetResidency")
func IOReportStateGetResidency(_ ch: CFDictionary, _ i: Int32) -> Int64

/// Frequencies (MHz) of the E- and P-cluster DVFS states, from the pmgr node in the IORegistry.
func readFrequencyTables() -> (e: [Double], p: [Double]) {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iter) == KERN_SUCCESS else { return ([], []) }
    defer { IOObjectRelease(iter) }
    func table(_ entry: io_registry_entry_t, _ key: String) -> [Double] {
        guard let d = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data else { return [] }
        // Pairs of little-endian UInt32: (frequency, voltage)
        var out: [Double] = []
        d.withUnsafeBytes { raw in
            for i in stride(from: 0, to: raw.count - 7, by: 8) { out.append(Double(raw.loadUnaligned(fromByteOffset: i, as: UInt32.self))) }
        }
        // M4+ "-sram" tables are in kHz, older plain tables in Hz
        let div = (out.max() ?? 0) > 100_000_000 ? 1_000_000.0 : 1_000.0
        return out.map { $0 / div }
    }
    while case let e = IOIteratorNext(iter), e != 0 {
        defer { IOObjectRelease(e) }
        var name = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(e, &name)
        guard String(cString: name) == "pmgr" else { continue }
        var ef = table(e, "voltage-states1-sram"), pf = table(e, "voltage-states5-sram")
        if ef.isEmpty { ef = table(e, "voltage-states1") }
        if pf.isEmpty { pf = table(e, "voltage-states5") }
        return (ef, pf)
    }
    return ([], [])
}

struct ClusterSample {
    var busy: Double = 0      // fraction of time the cores were not idle (avg over cores)
    var avgMHz: Double = 0    // average clock while not idle
    var peakMHz: Double = 0   // highest clock that held at least 2 % of the busy time
    var maxMHz: Double = 0    // highest clock this cluster supports
}

final class CPUReader {
    private var sub: IOReportSubscriptionRef?
    private var subDict: CFMutableDictionary?
    private var last: CFDictionary?
    private let eFreq: [Double], pFreq: [Double]
    let available: Bool

    init() {
        (eFreq, pFreq) = readFrequencyTables()
        var s: Unmanaged<CFMutableDictionary>?
        if let ch = IOReportCopyChannelsInGroup("CPU Stats" as CFString, "CPU Core Performance States" as CFString, 0, 0, 0)?.takeRetainedValue() {
            sub = IOReportCreateSubscription(nil, ch, &s, 0, nil)
            subDict = s?.takeRetainedValue()
        }
        available = sub != nil && subDict != nil && !pFreq.isEmpty
        if available { last = IOReportCreateSamples(sub!, subDict!, nil)?.takeRetainedValue() }
    }

    /// Delta since the previous call.
    func sample() -> (e: ClusterSample, p: ClusterSample)? {
        guard available, let prev = last, let now = IOReportCreateSamples(sub!, subDict!, nil)?.takeRetainedValue() else { return nil }
        last = now
        guard let delta = IOReportCreateSamplesDelta(prev, now, nil)?.takeRetainedValue() as? [String: Any],
              let channels = delta["IOReportChannels"] as? [CFDictionary] else { return nil }
        return (aggregate(channels, prefix: "ECPU", freqs: eFreq), aggregate(channels, prefix: "PCPU", freqs: pFreq))
    }

    private func aggregate(_ channels: [CFDictionary], prefix: String, freqs: [Double]) -> ClusterSample {
        var r = ClusterSample()
        guard !freqs.isEmpty else { return r }
        var total = 0.0, active = 0.0, weighted = 0.0
        var perState: [Double: Double] = [:]
        var usedMax = 0.0
        for ch in channels {
            guard let name = IOReportChannelGetChannelName(ch)?.takeUnretainedValue() as String?,
                  name.hasPrefix(prefix), name.dropFirst(prefix.count).allSatisfy(\.isNumber), name.count > prefix.count else { continue }
            var idx = 0
            for i in 0..<IOReportStateGetCount(ch) {
                let res = Double(IOReportStateGetResidency(ch, i))
                let sn = IOReportStateGetNameForIndex(ch, i)?.takeUnretainedValue() as String? ?? ""
                total += res
                if sn == "IDLE" || sn == "OFF" || sn == "DOWN" { continue }
                // Non-idle states map in order onto the frequency table
                let f = freqs[min(idx, freqs.count - 1)]
                usedMax = max(usedMax, f)
                idx += 1
                active += res
                weighted += res * f
                perState[f, default: 0] += res
            }
        }
        r.maxMHz = usedMax > 0 ? usedMax : (freqs.max() ?? 0)
        guard total > 0 else { return r }
        r.busy = active / total
        if active > 0 {
            r.avgMHz = weighted / active
            r.peakMHz = perState.filter { $0.value / active >= 0.02 }.keys.max() ?? 0
        }
        return r
    }
}

// MARK: - Rendering (Stats-style: small label on top, value below; identical to AIUsageBar)

func renderSegment(label: String, value: String) -> NSImage {
    let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 7, weight: .regular), .foregroundColor: NSColor.black]
    let valueAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.black]
    let l = NSAttributedString(string: label, attributes: labelAttrs)
    let v = NSAttributedString(string: value, attributes: valueAttrs)
    let width = ceil(max(l.size().width, v.size().width))
    let img = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
        l.draw(at: NSPoint(x: 0, y: 12.5))
        v.draw(at: NSPoint(x: 0, y: -0.5))
        return true
    }
    img.isTemplate = true
    return img
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let pressure = PressureReader()
    let cpu = CPUReader()

    var level: Pressure = .nominal
    var throttledSince: Date?
    var e = ClusterSample(), p = ClusterSample()
    var smoothedPct: Double?          // EMA of P-core clock %, only updated under load
    let busyThreshold = 0.25          // P-cores must be ≥ 25 % busy for the % to mean anything

    func applicationDidFinishLaunching(_ n: Notification) {
        if CommandLine.arguments.contains("--enable-login") { try? SMAppService.mainApp.register() }
        if CommandLine.arguments.contains("--disable-login") { try? SMAppService.mainApp.unregister() }
        item.autosaveName = "ThrottleBar"
        item.button?.imagePosition = .imageOnly
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func tick() {
        level = pressure.read()
        if level == .nominal { throttledSince = nil } else if throttledSince == nil { throttledSince = Date() }
        if let s = cpu.sample() {
            e = s.e; p = s.p
            if p.busy >= busyThreshold, p.maxMHz > 0 {
                let pct = min(100, p.avgMHz / p.maxMHz * 100)
                smoothedPct = smoothedPct.map { $0 * 0.5 + pct * 0.5 } ?? pct
            } else {
                smoothedPct = nil
            }
        }
        render()
    }

    var valueText: String {
        guard cpu.available else { return "?" }
        return smoothedPct.map { "\(Int($0.rounded()))%" } ?? "–"
    }

    func render() {
        item.button?.image = renderSegment(label: level.label, value: valueText)
        var tip = L("Thermal pressure", "Wärmedruck") + ": \(level.label)"
        if let s = smoothedPct { tip += "\n" + L("P-core clock", "P-Kern-Takt") + ": \(Int(s.rounded())) % " + L("of max", "vom Maximum") }
        else { tip += "\n" + L("CPU idle, nothing to measure", "CPU im Leerlauf, nichts zu messen") }
        item.button?.toolTip = tip
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(infoItem(L("Thermal pressure", "Wärmedruck") + ": \(level.label)"))
        if let t = throttledSince {
            menu.addItem(infoItem(L("Throttled for", "Gedrosselt seit") + " " + fmtDuration(Date().timeIntervalSince(t))))
        }
        menu.addItem(.separator())
        if cpu.available {
            func row(_ name: String, _ c: ClusterSample) -> NSMenuItem {
                let load = "\(Int((c.busy * 100).rounded())) %"
                return c.avgMHz > 0
                    ? infoItem("\(name): \(ghz(c.avgMHz)) " + L("of", "von") + " \(ghz(c.maxMHz))  ·  " + L("load", "Last") + " \(load)")
                    : infoItem("\(name): " + L("idle", "Leerlauf"))
            }
            menu.addItem(row(L("P-cores", "P-Kerne"), p))
            menu.addItem(row(L("E-cores", "E-Kerne"), e))
            if p.peakMHz > 0 {
                menu.addItem(infoItem(L("P-cores peak", "P-Kerne Spitze") + ": \(ghz(p.peakMHz))"))
            }
            menu.addItem(infoItem(L("% = P-core clock vs. max (single-core boost), shown under load",
                                    "% = P-Kern-Takt im Verhältnis zum Maximum (Einzelkern-Boost), nur unter Last")))
        } else {
            menu.addItem(infoItem(L("CPU clock not readable on this Mac", "CPU-Takt auf diesem Mac nicht lesbar")))
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem(L("Open Activity Monitor", "Aktivitätsanzeige öffnen")) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
        })
        menu.addItem(ActionItem(L("Launch at login", "Bei Anmeldung starten"), state: SMAppService.mainApp.status == .enabled ? .on : .off) {
            if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
            else { try? SMAppService.mainApp.register() }
        })
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Quit", "Beenden"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
}

// Debug: `ThrottleBar --sample` prints a few readings to stdout and exits.
if CommandLine.arguments.contains("--sample") {
    let t = readFrequencyTables()
    print("E table (MHz):", t.e.map { Int($0) })
    print("P table (MHz):", t.p.map { Int($0) })
    let r = CPUReader(), pr = PressureReader()
    for _ in 0..<3 {
        Thread.sleep(forTimeInterval: 1)
        if let s = r.sample() {
            print(String(format: "pressure=%@  P busy %.0f%% avg %.0f peak %.0f max %.0f  |  E busy %.0f%% avg %.0f max %.0f",
                         pr.read().label, s.p.busy * 100, s.p.avgMHz, s.p.peakMHz, s.p.maxMHz, s.e.busy * 100, s.e.avgMHz, s.e.maxMHz))
        } else { print("no sample") }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
