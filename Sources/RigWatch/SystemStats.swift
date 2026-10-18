import Darwin
import Foundation
import IOKit

struct Volume: Identifiable, Hashable {
    let name: String; let path: String; let total: Int64; let free: Int64
    var id: String { path }
    var used: Int64 { total - free }
}

struct SysSnapshot {
    var cpu: Double = 0                 // 0–100, whole machine
    var cores: [Double] = []
    var load: (Double, Double, Double) = (0, 0, 0)
    var memTotal: UInt64 = 0, memApp: UInt64 = 0, memWired: UInt64 = 0, memCompressed: UInt64 = 0, memCached: UInt64 = 0, memFree: UInt64 = 0, memPurgeable: UInt64 = 0
    var memUsed: UInt64 { memApp + memWired + memCompressed }
    var pressure: Int32 = 1             // 1 normal, 2 warning, 4 critical
    var swapUsed: UInt64 = 0, swapTotal: UInt64 = 0
    var gpu: Int = 0, gpuMem: UInt64 = 0, gpuModel = ""
    var diskRead: Double = 0, diskWrite: Double = 0
    var netIn: Double = 0, netOut: Double = 0
    var volumes: [Volume] = []
    var thermal: ProcessInfo.ThermalState = .nominal
    var tempMax: Double? = nil, tempAvg: Double? = nil
    var uptime: TimeInterval = 0
}

/// Machine-wide numbers from Mach, sysctl and IOKit. No subprocesses.
final class SystemSampler {
    private var prevTicks: [[UInt32]] = []
    private var prevDisk: (UInt64, UInt64)?
    private var prevNet: [String: (UInt32, UInt32)] = [:]
    private var prevTime = Date()
    private var volumesAt = Date.distantPast
    private var volumes: [Volume] = []
    private lazy var gpuModel: String = {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        defer { IOObjectRelease(s) }
        return (IORegistryEntryCreateCFProperty(s, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String) ?? "GPU"
    }()

    init() { _ = sample() }   // primes the CPU/disk/net counters so the first real sample has a delta

    func sample() -> SysSnapshot {
        var s = SysSnapshot()
        let now = Date(); let dt = max(now.timeIntervalSince(prevTime), 0.001); prevTime = now
        cpu(&s)
        memory(&s)
        var l = [Double](repeating: 0, count: 3); getloadavg(&l, 3); s.load = (l[0], l[1], l[2])
        gpu(&s)
        disk(&s, dt)
        net(&s, dt)
        if now.timeIntervalSince(volumesAt) > 30 { volumes = Self.readVolumes(); volumesAt = now }
        s.volumes = volumes
        s.thermal = ProcessInfo.processInfo.thermalState
        if let t = Thermals.soc() { s.tempMax = t.max; s.tempAvg = t.avg }
        s.uptime = ProcessInfo.processInfo.systemUptime
        return s
    }

    /// CPU and memory only (Mach and sysctl calls, no IOKit): the cheap check run while the window is hidden.
    func light() -> SysSnapshot { var s = SysSnapshot(); cpu(&s); memory(&s); return s }

    private func cpu(_ s: inout SysSnapshot) {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var n: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &n) == KERN_SUCCESS, let info else { return }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(n) * MemoryLayout<integer_t>.stride)) }
        var ticks: [[UInt32]] = []
        for c in 0..<Int(count) {
            let b = c * Int(CPU_STATE_MAX)
            ticks.append((0..<Int(CPU_STATE_MAX)).map { UInt32(bitPattern: info[b + $0]) })
        }
        if prevTicks.count == ticks.count {
            var busyAll = 0.0, totalAll = 0.0
            for (a, p) in zip(ticks, prevTicks) {
                let d = zip(a, p).map { Double($0 &- $1) }
                let idle = d[Int(CPU_STATE_IDLE)], total = d.reduce(0, +)
                s.cores.append(total > 0 ? (total - idle) / total * 100 : 0)
                busyAll += total - idle; totalAll += total
            }
            s.cpu = totalAll > 0 ? busyAll / totalAll * 100 : 0
        }
        prevTicks = ticks
    }

    private func memory(_ s: inout SysSnapshot) {
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &s.memTotal, &size, nil, 0)
        var vm = vm_statistics64()
        var cnt = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &vm) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(cnt)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &cnt) } }
        let pg = UInt64(vm_kernel_page_size)
        s.memApp = (UInt64(vm.internal_page_count) - min(UInt64(vm.internal_page_count), UInt64(vm.purgeable_count))) * pg
        s.memWired = UInt64(vm.wire_count) * pg
        s.memCompressed = UInt64(vm.compressor_page_count) * pg
        s.memCached = (UInt64(vm.external_page_count) + UInt64(vm.purgeable_count)) * pg
        s.memPurgeable = UInt64(vm.purgeable_count) * pg
        s.memFree = UInt64(vm.free_count) * pg
        var lvl: Int32 = 1; size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &lvl, &size, nil, 0); s.pressure = lvl
        var sw = xsw_usage(); size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &sw, &size, nil, 0); s.swapUsed = sw.xsu_used; s.swapTotal = sw.xsu_total
    }

    private func gpu(_ s: inout SysSnapshot) {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        defer { IOObjectRelease(svc) }
        s.gpuModel = gpuModel
        guard let st = IORegistryEntryCreateCFProperty(svc, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else { return }
        s.gpu = (st["Device Utilization %"] as? Int) ?? 0
        s.gpuMem = UInt64((st["In use system memory"] as? Int) ?? 0)
    }

    private func disk(_ s: inout SysSnapshot, _ dt: Double) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        var r: UInt64 = 0, w: UInt64 = 0
        while case let e = IOIteratorNext(it), e != 0 {
            if let st = IORegistryEntryCreateCFProperty(e, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                r += UInt64((st["Bytes (Read)"] as? Int) ?? 0); w += UInt64((st["Bytes (Write)"] as? Int) ?? 0)
            }
            IOObjectRelease(e)
        }
        if let p = prevDisk { s.diskRead = Double(r &- p.0) / dt; s.diskWrite = Double(w &- p.1) / dt }
        prevDisk = (r, w)
    }

    private func net(_ s: inout SysSnapshot, _ dt: Double) {
        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0 else { return }
        defer { freeifaddrs(ifa) }
        var cur: [String: (UInt32, UInt32)] = [:]
        var p = ifa
        while let c = p {
            if let a = c.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_LINK), let d = c.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                let name = String(cString: c.pointee.ifa_name)
                if !name.hasPrefix("lo") { cur[name] = (d.pointee.ifi_ibytes, d.pointee.ifi_obytes) }
            }
            p = c.pointee.ifa_next
        }
        var i = 0.0, o = 0.0
        for (k, v) in cur { if let pv = prevNet[k] { i += Double(v.0 &- pv.0); o += Double(v.1 &- pv.1) } }
        if !prevNet.isEmpty { s.netIn = i / dt; s.netOut = o / dt }
        prevNet = cur
    }

    static func readVolumes() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeIsBrowsableKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable == true, v.volumeIsLocal == true,
                  let t = v.volumeTotalCapacity, t > 0 else { return nil }
            return Volume(name: v.volumeName ?? u.lastPathComponent, path: u.path, total: Int64(t), free: v.volumeAvailableCapacityForImportantUsage ?? 0)
        }
    }
}

// MARK: temperature

// The SoC's temperature sensors through IOHID (the same source Stats and iStat use). These calls are
// exported by IOKit but not in its headers; if any is missing the readout simply shows nothing.
@_silgen_name("IOHIDEventSystemClientCreate") private func IOHIDEventSystemClientCreate(_ a: CFAllocator?) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventSystemClientSetMatching") private func IOHIDEventSystemClientSetMatching(_ c: CFTypeRef, _ m: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices") private func IOHIDEventSystemClientCopyServices(_ c: CFTypeRef) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty") private func IOHIDServiceClientCopyProperty(_ s: CFTypeRef, _ k: CFString) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDServiceClientCopyEvent") private func IOHIDServiceClientCopyEvent(_ s: CFTypeRef, _ t: Int64, _ a: Int32, _ b: Int64) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventGetFloatValue") private func IOHIDEventGetFloatValue(_ e: CFTypeRef, _ f: Int32) -> Double

enum Thermals {
    private static let client: CFTypeRef? = {
        guard let c = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        _ = IOHIDEventSystemClientSetMatching(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        return c
    }()

    /// Hottest and average SoC die temperature in °C, or nil when the sensors cannot be read.
    static func soc() -> (max: Double, avg: Double)? {
        guard let c = client, let services = IOHIDEventSystemClientCopyServices(c)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        var temps: [Double] = []
        for s in services {
            let name = (IOHIDServiceClientCopyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String) ?? ""
            guard name.contains("tdie") || name.contains("tdev") || name.hasPrefix("PMU") else { continue }
            guard let e = IOHIDServiceClientCopyEvent(s, 15, 0, 0)?.takeRetainedValue() else { continue }   // 15 = temperature
            let t = IOHIDEventGetFloatValue(e, 15 << 16)
            if t > 5 && t < 130 { temps.append(t) }
        }
        guard !temps.isEmpty else { return nil }
        return (temps.max()!, temps.reduce(0, +) / Double(temps.count))
    }
}
