import Foundation

/// Installing a built app on a real iPhone, from any Mac, only after the user says yes in RigWatch each time.
/// The phone is reached through the Mac it is paired with (devicectl, over USB or the local network); a request
/// from another Mac copies the app there over SSH and installs it from there.
enum IPhones {
    struct Phone: Codable, Equatable {
        let name: String
        let udid: String
        let model: String
        let transport: String   // wired, localNetwork
    }

    /// Paired iPhones and iPads this Mac sees over USB or the local network, from devicectl.
    static func here() -> [Phone] {
        let f = NSTemporaryDirectory() + "rigwatch-iphones-\(getpid()).json"
        defer { try? FileManager.default.removeItem(atPath: f) }
        _ = Sh.run("/usr/bin/xcrun", ["devicectl", "list", "devices", "-j", f], timeout: 30)
        guard let d = FileManager.default.contents(atPath: f), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let devs = (j["result"] as? [String: Any])?["devices"] as? [[String: Any]] else { return [] }
        return devs.compactMap { x in
            let hw = x["hardwareProperties"] as? [String: Any] ?? [:], cp = x["connectionProperties"] as? [String: Any] ?? [:]
            guard hw["platform"] as? String == "iOS", hw["reality"] as? String == "physical", let udid = hw["udid"] as? String,
                  cp["pairingState"] as? String == "paired", cp["transportType"] != nil else { return nil }   // devicectl connects when asked
            return Phone(name: (x["deviceProperties"] as? [String: Any])?["name"] as? String ?? udid, udid: udid,
                         model: hw["marketingName"] as? String ?? "iPhone", transport: cp["transportType"] as? String ?? "")
        }
    }

    /// Phones here and on the allowed Macs, with the Mac each is on (nil for this one).
    static func everywhere() -> [(phone: Phone, host: String?)] {
        var out = here().map { (phone: $0, host: String?.none) }
        let hosts = Peers.load().filter(\.allowed).map(\.host)
        let found = UnsafeMutablePointer<[(Phone, String)]>.allocate(capacity: 1); found.initialize(to: [])
        defer { found.deinitialize(count: 1); found.deallocate() }
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: hosts.count) { i in
            let r = Sh.run("/usr/bin/ssh", Peers.sshOpts + [hosts[i], Peers.remote(["iphones"])], timeout: 45)
            guard r.code == 0, let line = r.out.split(separator: "\n").last,
                  let list = try? JSONDecoder().decode([Phone].self, from: Data(line.utf8)) else { return }
            lock.lock(); found.pointee += list.map { ($0, hosts[i]) }; lock.unlock()
        }
        for (p, h) in found.pointee where !out.contains(where: { $0.phone.udid == p.udid }) { out.append((p, h)) }
        return out
    }

    /// What an app bundle says about itself, and whether it is built for a real device.
    struct AppInfo { let name: String; let bundleID: String; let version: String; let platform: String }

    static func appInfo(_ path: String) -> AppInfo? {
        guard let p = NSDictionary(contentsOfFile: path + "/Info.plist") else { return nil }
        let short = p["CFBundleShortVersionString"] as? String ?? "", build = p["CFBundleVersion"] as? String ?? ""
        return AppInfo(name: p["CFBundleDisplayName"] as? String ?? p["CFBundleName"] as? String ?? (path as NSString).lastPathComponent,
                       bundleID: p["CFBundleIdentifier"] as? String ?? "?", version: build.isEmpty ? short : "\(short) (\(build))",
                       platform: (p["CFBundleSupportedPlatforms"] as? [String])?.first ?? p["DTPlatformName"] as? String ?? "")
    }

    // MARK: asking the user

    struct Request: Codable, Equatable, Identifiable {
        var id = UUID().uuidString
        let app: String, bundleID: String, version: String, path: String
        let phone: String, mac: String       // the phone, and the Mac it is installed from
        let session: String
        let askedAt: Date
        var answer: Bool?
        var expired: Bool { Date().timeIntervalSince(askedAt) > IPhones.wait }
    }

    static let file = Rules.dir + "/iphone-installs.json"
    static let wait: TimeInterval = 600   // an unanswered request is refused after this long

    static func requests() -> [Request] {
        (FileManager.default.contents(atPath: file).flatMap { try? JSONDecoder().decode([Request].self, from: $0) } ?? []).filter { !$0.expired }
    }

    /// The list under an exclusive lock, expired requests dropped.
    static func edit<T>(_ body: (inout [Request]) -> T) -> T {
        try? FileManager.default.createDirectory(atPath: Rules.dir, withIntermediateDirectories: true)
        let fd = open(Rules.dir + "/iphone-installs.lock", O_RDWR | O_CREAT, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { close(fd) } }
        var list = requests()
        let out = body(&list)
        Rules.write(try? JSONEncoder().encode(list), to: file)
        return out
    }

    /// The user's answer, from the app's prompt only: there is no command for it, so an agent can't answer for the user.
    static func answer(_ id: String, _ yes: Bool) {
        edit { list in if let i = list.firstIndex(where: { $0.id == id }) { list[i].answer = yes } }
        Rules.log("iphone: install request \(id) \(yes ? "allowed" : "refused") by the user")
    }

    /// Records the request and waits for the user's answer; false when refused or not answered in time.
    static func ask(_ r: Request) -> Bool {
        edit { $0.append(r) }
        Rules.log("iphone: session \(r.session) asks to install \(r.app) \(r.version) (\(r.bundleID)) on \(r.phone) from \(r.mac)")
        while Date().timeIntervalSince(r.askedAt) < wait {
            if let a = requests().first(where: { $0.id == r.id })?.answer {
                edit { $0.removeAll { $0.id == r.id } }
                return a
            }
            Thread.sleep(forTimeInterval: 1)
        }
        edit { $0.removeAll { $0.id == r.id } }
        Rules.log("iphone: install request \(r.id) not answered in \(Int(wait / 60)) min; refused")
        return false
    }

    // MARK: installing

    /// Installs an .app built for iphoneos on a phone here or on an allowed Mac, once the user allows it.
    static func install(path raw: String, device want: String?, session: String) throws -> [String: Any] {
        let full = (raw as NSString).expandingTildeInPath
        let path = ((full.hasPrefix("/") ? full : FileManager.default.currentDirectoryPath + "/" + full) as NSString).standardizingPath.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard path.hasSuffix(".app"), let info = appInfo(path) else {
            throw DeviceManager.Failure(message: "\(raw) is not an .app bundle. Give the path of the built .app, e.g. build/Build/Products/Debug-iphoneos/App.app.")
        }
        guard info.platform == "iPhoneOS" || info.platform == "iphoneos" else {
            throw DeviceManager.Failure(message: "\(info.name) is built for \(info.platform.isEmpty ? "an unknown platform" : info.platform), not a real iPhone. Build with -sdk iphoneos (or -destination generic/platform=iOS) and a signing identity that includes the phone.")
        }
        let all = everywhere()
        let match = want.map { w in all.filter { $0.phone.name.caseInsensitiveCompare(w) == .orderedSame || $0.phone.udid == w } } ?? all
        guard let (phone, host) = match.first else {
            let seen = all.map { "\($0.phone.name) (\($0.host ?? "this Mac"))" }
            throw DeviceManager.Failure(message: (want.map { "No paired iPhone named \($0) is reachable." } ?? "No paired iPhone is reachable.")
                + (seen.isEmpty ? " Connect it to a Mac it is paired with by USB, or put it on the same Wi-Fi as that Mac." : " Reachable: \(seen.joined(separator: ", ")).")
                + " A phone on another network is not reachable: devicectl finds phones on the local network only.")
        }
        guard want != nil || match.count == 1 else {
            throw DeviceManager.Failure(message: "More than one iPhone is reachable; name one with device: \(match.map { $0.phone.name }.joined(separator: ", ")).")
        }
        let mac = host ?? Peers.localName
        let req = Request(app: info.name, bundleID: info.bundleID, version: info.version, path: path, phone: phone.name, mac: mac, session: session, askedAt: Date())
        guard ask(req) else {
            throw DeviceManager.Failure(message: "The user did not allow installing \(info.name) on \(phone.name) (refused, or no answer in \(Int(wait / 60)) minutes). Don't retry unless they ask you to.")
        }
        let r: Sh.Result
        if let host {
            let dest = "Library/Caches/RigWatch/iphone-installs/\(req.id)"
            let ssh = (["/usr/bin/ssh"] + Peers.sshOpts).joined(separator: " ")
            let c = Sh.run("/usr/bin/rsync", ["-az", "--rsync-path", "mkdir -p \(dest) && rsync", "-e", ssh, path, host + ":" + dest + "/"], timeout: 1800)
            guard c.code == 0 else { throw DeviceManager.Failure(message: "Could not copy \(info.name) to \(host): \(c.err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))") }
            r = Sh.run("/usr/bin/ssh", Peers.sshOpts + [host, Peers.remote(["iphone-install", phone.udid, dest + "/" + (path as NSString).lastPathComponent])], timeout: 900)
            _ = Sh.run("/usr/bin/ssh", Peers.sshOpts + [host, "rm -rf " + Rules.quote(dest)], timeout: 60)
        } else {
            r = installHere(phone.udid, path)
        }
        let out = (r.out + "\n" + r.err).trimmingCharacters(in: .whitespacesAndNewlines)
        Rules.log("iphone: installed \(info.name) \(info.version) on \(phone.name) from \(mac) for session \(session): exit \(r.code)")
        guard r.code == 0 else { throw DeviceManager.Failure(message: "devicectl could not install \(info.name) on \(phone.name) (exit \(r.code)): \(out.suffix(600))") }
        return ["installed": info.name, "version": info.version, "bundle_id": info.bundleID, "device": phone.name, "udid": phone.udid, "from": mac,
                "note": "Installed. Launch it with: xcrun devicectl device process launch --device \(phone.udid) \(info.bundleID)" + (host == nil ? "" : " (on \(mac))")]
    }

    static func installHere(_ udid: String, _ path: String) -> Sh.Result {
        Sh.run("/usr/bin/xcrun", ["devicectl", "device", "install", "app", "--device", udid, path], timeout: 900)
    }

    /// `RigWatch iphone list|install PATH [--device NAME]`
    static func main(_ a: [String]) -> Int32 {
        switch a.first {
        case "list":
            for (p, h) in everywhere() { print("\(p.name)  \(p.model)  \(p.udid)  \(p.transport)  on \(h ?? "this Mac")") }
            return 0
        case "install" where a.count >= 2:
            let dev = a.firstIndex(of: "--device").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
            let path = a.dropFirst().first { !$0.hasPrefix("--") && $0 != dev } ?? ""
            do {
                let r = try install(path: path, device: dev, session: DeviceManager.session)
                print(r["note"] as? String ?? "Installed."); return 0
            } catch let f as DeviceManager.Failure { Rules.say(f.message); return 1 } catch { Rules.say("\(error)"); return 1 }
        default:
            Rules.say("usage: RigWatch iphone list | install PATH.app [--device NAME]"); return 2
        }
    }
}
