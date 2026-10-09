// NineExplorer.swift — shared core of NineExplorer (macOS + iOS).
//
// Platform-neutral pieces only: configuration, recents, the 9P service actor,
// the app model, connect-form validation, formatting, file icons and previews.
// Each platform supplies its own views and @main App:
//   MacApp.swift    — macOS, hand-drawn iPhone-style UI, command-line flags
//   iOSApp.swift    — iOS, native Form/List/NavigationStack equivalents,
//                     plus the WatchConnectivity bridge that serves the watch
//   WatchApp.swift  — watchOS, a thin view onto the iPhone app (no 9P)
//   TVApp.swift     — tvOS, native focus-driven Form/List (speaks 9P itself)
//
// macOS/iOS/tvOS build this with NineP/NineP.swift. The watch build leaves out
// NineP.swift, NineService and AppModel (#if !os(watchOS)) — it never talks 9P.
// See the Makefile (mac-app / ios-app / watch-app / tv-app).

import SwiftUI

#if os(watchOS)
/// The few protocol constants the shared code needs, without the 9P library.
enum NineP {
    static let version = "9P2000"
    static let version9P2000L = "9P2000.L"
    static let noNuname: UInt32 = 0xFFFF_FFFF
}
#endif

// MARK: - Configuration

struct Config {
    var host = "127.0.0.1"
    var port: UInt16 = 564
    var proto = "auto"
    #if os(macOS)
    var uname = ProcessInfo.processInfo.environment["USER"] ?? ""
    #else
    var uname = ""
    #endif
    var uid: UInt32 = NineP.noNuname
    var aname = ""
    var msize: UInt32 = 65536

    var endpoint: String { "\(host):\(port)" }

    /// Identity used to de-duplicate recent servers.
    var key: String { "\(proto)|\(uname)|\(uid)|\(host)|\(port)|\(aname)" }

    var dict: [String: String] {
        ["host": host, "port": String(port), "proto": proto, "uname": uname,
         "uid": String(uid), "aname": aname, "msize": String(msize)]
    }

    init() {}

    init?(dict d: [String: String]) {
        guard let h = d["host"], let p = d["port"].flatMap({ UInt16($0) }) else { return nil }
        host = h; port = p
        proto = d["proto"] ?? "auto"
        uname = d["uname"] ?? ""
        uid = d["uid"].flatMap { UInt32($0) } ?? NineP.noNuname
        aname = d["aname"] ?? ""
        msize = d["msize"].flatMap { UInt32($0) } ?? 65536
    }

    /// Parse "host:port", "tcp://host:port" or "[v6]:port".
    static func parseHostPort(_ s: String) -> (String, UInt16)? {
        var rest = s
        if rest.hasPrefix("tcp://") { rest.removeFirst(6) }
        var host: String, portStr: String
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            guard after.hasPrefix(":") else { return nil }
            portStr = String(after.dropFirst())
        } else {
            guard let colon = rest.lastIndex(of: ":") else { return nil }
            host = String(rest[..<colon])
            portStr = String(rest[rest.index(after: colon)...])
        }
        if host.isEmpty { host = "127.0.0.1" }
        guard let port = UInt16(portStr) else { return nil }
        return (host, port)
    }
}

/// Recently used servers, newest first (UserDefaults).
enum Recents {
    static let key = "recentServers"
    static let max = 6

    static func load() -> [Config] {
        (UserDefaults.standard.array(forKey: key) as? [[String: String]] ?? []).compactMap(Config.init(dict:))
    }

    static func save(_ list: [Config]) {
        UserDefaults.standard.set(list.prefix(max).map(\.dict), forKey: key)
    }

    static func add(_ c: Config) {
        save([c] + load().filter { $0.key != c.key })
    }

    static func remove(_ c: Config) {
        save(load().filter { $0.key != c.key })
    }
}

// MARK: - Connect form (shared validation)

struct ServerForm {
    var host = ""
    var port = "564"
    var proto = "auto"
    var uname = ""
    var uid = ""
    var aname = ""
    var msize = "65536"

    init() {}

    init(_ c: Config, blankHost: Bool = false) {
        host = blankHost ? "" : c.host
        port = String(c.port)
        proto = c.proto
        uname = c.uname
        uid = c.uid == NineP.noNuname ? "" : String(c.uid)
        aname = c.aname
        msize = String(c.msize)
    }

    private func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }

    /// The form as a Config, or nil if a field is invalid.
    var config: Config? {
        var c = Config()
        guard !trim(host).isEmpty, let p = UInt16(trim(port)), p > 0 else { return nil }
        c.host = trim(host); c.port = p
        c.proto = proto
        c.uname = uname
        if trim(uid).isEmpty { c.uid = NineP.noNuname } else { guard let n = UInt32(trim(uid)) else { return nil }; c.uid = n }
        c.aname = trim(aname)
        if trim(msize).isEmpty { c.msize = 65536 } else { guard let n = UInt32(trim(msize)), n >= 256 else { return nil }; c.msize = n }
        return c
    }

    /// A human-readable validation problem (nil when fine or nothing typed yet).
    var problem: String? {
        if trim(host).isEmpty { return nil }
        if (UInt16(trim(port)) ?? 0) == 0 { return "Port must be 1\u{2013}65535." }
        if !trim(uid).isEmpty && UInt32(trim(uid)) == nil { return "UID must be a number." }
        if !trim(msize).isEmpty && (UInt32(trim(msize)) ?? 0) < 256 { return "Max message must be a number \u{2265} 256." }
        return nil
    }

    var protoFooter: String {
        switch proto {
        case NineP.version: return "Plan 9 / classic 9P2000."
        case NineP.version9P2000L: return "Linux dialect, used by diod, QEMU and most Go/Rust servers."
        default: return "Tries 9P2000 first, then falls back to 9P2000.L."
        }
    }

    static let accountFooter = "Leave User empty for an anonymous attach. UID is only sent with 9P2000.L."
    static let protocols: [(label: String, tag: String)] =
        [("Auto", "auto"), ("9P2000", NineP.version), ("9P2000.L", NineP.version9P2000L)]
}

extension Config {
    var recentSubtitle: String {
        let user = uname.isEmpty ? "anonymous" : uname
        let p = proto == "auto" ? "Auto" : proto
        return aname.isEmpty ? "\(p) \u{00B7} \(user)" : "\(p) \u{00B7} \(user) \u{00B7} \(aname)"
    }
}

// MARK: - Model types

struct Entry: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let isDir: Bool
    let isLink: Bool
    let linkTarget: String?
    let size: UInt64
    let mtime: Date
    let modeString: String
    let perm: UInt32
    let uid: String
    let gid: String
    let qidPath: UInt64
    let qidVersion: UInt32
    let qidType: UInt8

    var isExecutable: Bool { !isDir && perm & 0o111 != 0 }
    var ext: String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }
    var qidString: String { "type 0x\(String(qidType, radix: 16)) \u{00B7} v\(qidVersion) \u{00B7} \(qidPath)" }

    /// The attach root of a server, as a navigable folder.
    static func root(title: String) -> Entry {
        Entry(name: title, path: ".", isDir: true, isLink: false, linkTarget: nil, size: 0,
              mtime: Date(timeIntervalSince1970: 0), modeString: "", perm: 0, uid: "", gid: "",
              qidPath: 0, qidVersion: 0, qidType: 0)
    }

    /// Only what the watch shows (name, kind, size, date); the rest is blanked so
    /// it is omitted from the encoded payload.
    var forWatch: Entry {
        Entry(name: name, path: path, isDir: isDir, isLink: isLink, linkTarget: linkTarget, size: size,
              mtime: mtime, modeString: "", perm: perm & 0o111, uid: "", gid: "",
              qidPath: 0, qidVersion: 0, qidType: 0)
    }
}

/// Compact Codable form (short keys, defaults omitted) so directory listings
/// fit in WatchConnectivity messages. Written out by hand because NineP.swift
/// defines its own `Encoder`/`Decoder` wire types, hence the `Swift.` prefixes.
extension Entry: Codable {
    private enum K: String, CodingKey {
        case name = "n", path = "p", isDir = "d", isLink = "l", linkTarget = "t", size = "s"
        case mtime = "m", modeString = "o", perm = "x", uid = "u", gid = "g"
        case qidPath = "qp", qidVersion = "qv", qidType = "qt"
    }

    init(from decoder: Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        isDir = try c.decodeIfPresent(Bool.self, forKey: .isDir) ?? false
        isLink = try c.decodeIfPresent(Bool.self, forKey: .isLink) ?? false
        linkTarget = try c.decodeIfPresent(String.self, forKey: .linkTarget)
        size = try c.decodeIfPresent(UInt64.self, forKey: .size) ?? 0
        mtime = Date(timeIntervalSince1970: try c.decodeIfPresent(Double.self, forKey: .mtime) ?? 0)
        modeString = try c.decodeIfPresent(String.self, forKey: .modeString) ?? ""
        perm = try c.decodeIfPresent(UInt32.self, forKey: .perm) ?? 0
        uid = try c.decodeIfPresent(String.self, forKey: .uid) ?? ""
        gid = try c.decodeIfPresent(String.self, forKey: .gid) ?? ""
        qidPath = try c.decodeIfPresent(UInt64.self, forKey: .qidPath) ?? 0
        qidVersion = try c.decodeIfPresent(UInt32.self, forKey: .qidVersion) ?? 0
        qidType = try c.decodeIfPresent(UInt8.self, forKey: .qidType) ?? 0
    }

    func encode(to encoder: Swift.Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(name, forKey: .name)
        try c.encode(path, forKey: .path)
        if isDir { try c.encode(true, forKey: .isDir) }
        if isLink { try c.encode(true, forKey: .isLink) }
        try c.encodeIfPresent(linkTarget, forKey: .linkTarget)
        if size != 0 { try c.encode(size, forKey: .size) }
        if mtime.timeIntervalSince1970 != 0 { try c.encode(mtime.timeIntervalSince1970.rounded(), forKey: .mtime) }
        if !modeString.isEmpty { try c.encode(modeString, forKey: .modeString) }
        if perm != 0 { try c.encode(perm, forKey: .perm) }
        if !uid.isEmpty { try c.encode(uid, forKey: .uid) }
        if !gid.isEmpty { try c.encode(gid, forKey: .gid) }
        if qidPath != 0 { try c.encode(qidPath, forKey: .qidPath) }
        if qidVersion != 0 { try c.encode(qidVersion, forKey: .qidVersion) }
        if qidType != 0 { try c.encode(qidType, forKey: .qidType) }
    }
}

// MARK: - Watch <-> iPhone protocol (WatchConnectivity)
//
// The watch sends a Request with sendMessage(_:replyHandler:); the iPhone
// does the 9P work and answers with a Reply. The iPhone also pushes a Context
// with updateApplicationContext so the watch has something to show at once.
// All payloads are property-list dictionaries.

enum WatchProto {
    /// Stay well under the WatchConnectivity message limit.
    static let maxEntriesBytes = 40_000
    static let previewLimit = 2_048

    enum Op: String { case list, preview, connect, disconnect, state }

    struct Request {
        var op: Op
        var path: String = "."
        var server: Config? = nil      // the server the watch is browsing

        var dict: [String: Any] {
            var d: [String: Any] = ["op": op.rawValue, "path": path]
            if let server { d["server"] = server.dict }
            return d
        }

        init(op: Op, path: String = ".", server: Config? = nil) {
            self.op = op; self.path = path; self.server = server
        }

        init?(_ d: [String: Any]) {
            guard let o = (d["op"] as? String).flatMap(Op.init(rawValue:)) else { return nil }
            op = o
            path = d["path"] as? String ?? "."
            server = (d["server"] as? [String: String]).flatMap(Config.init(dict:))
        }
    }

    struct Reply {
        var error: String? = nil
        var entries: [Entry]? = nil
        var total = 0                  // entries in the folder (may exceed entries.count)
        var text: String? = nil
        var binary = false
        var truncated = false
        var title: String? = nil

        var dict: [String: Any] {
            var d: [String: Any] = ["total": total, "binary": binary, "truncated": truncated]
            if let error { d["error"] = error }
            if let text { d["text"] = text }
            if let title { d["title"] = title }
            if let entries {
                // Drop entries from the end until the encoded list fits.
                var n = entries.count
                var data = (try? JSONEncoder().encode(entries)) ?? Data()
                while data.count > WatchProto.maxEntriesBytes && n > 0 {
                    n = max(0, min(n - 1, n * WatchProto.maxEntriesBytes / max(data.count, 1)))
                    data = (try? JSONEncoder().encode(Array(entries.prefix(n)))) ?? Data()
                }
                d["entries"] = data
            }
            return d
        }

        init(error: String? = nil) { self.error = error }

        init(_ d: [String: Any]) {
            error = d["error"] as? String
            total = d["total"] as? Int ?? 0
            text = d["text"] as? String
            binary = d["binary"] as? Bool ?? false
            truncated = d["truncated"] as? Bool ?? false
            title = d["title"] as? String
            if let data = d["entries"] as? Data {
                entries = try? JSONDecoder().decode([Entry].self, from: data)
            }
        }
    }

    /// iPhone state pushed to the watch with updateApplicationContext.
    struct Context {
        var status = "setup"           // setup | connecting | connected | failed
        var server: Config? = nil
        var title = ""
        var version = ""
        var error: String? = nil
        var recents: [Config] = []

        var dict: [String: Any] {
            var d: [String: Any] = ["status": status, "title": title, "version": version,
                                    "recents": recents.map(\.dict)]
            if let server { d["server"] = server.dict }
            if let error { d["error"] = error }
            return d
        }

        init() {}

        init(_ d: [String: Any]) {
            status = d["status"] as? String ?? "setup"
            server = (d["server"] as? [String: String]).flatMap(Config.init(dict:))
            title = d["title"] as? String ?? ""
            version = d["version"] as? String ?? ""
            error = d["error"] as? String
            recents = (d["recents"] as? [[String: String]] ?? []).compactMap(Config.init(dict:))
        }
    }
}

func joinPath(_ a: String, _ b: String) -> String {
    (a.isEmpty || a == ".") ? b : (a.hasSuffix("/") ? a + b : a + "/" + b)
}

#if !os(watchOS)
// MARK: - 9P service (owns the connection)

/// The NineP Client is synchronous and not thread-safe, so it lives inside
/// this actor; views talk to it with async calls.
actor NineService {
    let cfg: Config
    private var client: Client?
    private var root: UInt32 = 0
    private(set) var version = ""

    static let connectTimeout = 5.0
    static let ioTimeout = 15.0

    init(cfg: Config) { self.cfg = cfg }

    @discardableResult
    func connect() throws -> String {
        reset()
        // Bounded so a slow or dead server fails fast (the iPhone has only a
        // short window when woken in the background by the watch).
        let t = try FDTransport.tcp(host: cfg.host, port: cfg.port,
                                    timeout: NineService.connectTimeout, ioTimeout: NineService.ioTimeout)
        let c = Client(transport: t, msize: cfg.msize)
        let versions = cfg.proto == "auto" ? [NineP.version, NineP.version9P2000L] : [cfg.proto]
        let (_, v) = try c.negotiate(versions: versions)
        let r = c.allocFid()
        _ = try c.attach(fid: r, uname: cfg.uname, aname: cfg.aname, nUname: cfg.uid)
        client = c; root = r; version = v
        return v
    }

    func reset() {
        client?.close()
        client = nil
    }

    /// Run `body` with a live client, reconnecting once if needed. Transport or
    /// protocol failures drop the connection so the next call starts fresh.
    private func withClient<T>(_ body: (Client, UInt32) throws -> T) throws -> T {
        if client == nil { try connect() }
        do {
            return try body(client!, root)
        } catch let e as NinePError {
            switch e {
            case .io, .closed, .protocolError: reset()
            default: break
            }
            throw e
        }
    }

    func list(_ path: String) throws -> [Entry] {
        try withClient { c, root in
            let f = c.allocFid()
            try c.walk(fid: root, newfid: f, path: path)
            defer { try? c.clunk(fid: f) }

            if c.dialect == .linux {
                let iou = try c.lopen(fid: f, flags: LinuxOpen.RDONLY).iounit
                let ents = try c.readdirAll(fid: f, iounit: iou).filter { $0.name != "." && $0.name != ".." }
                return ents.map { d in
                    let p = joinPath(path, d.name)
                    let ef = c.allocFid()
                    do {
                        try c.walk(fid: root, newfid: ef, path: p)
                        defer { try? c.clunk(fid: ef) }
                        let a = try c.getattr(fid: ef)
                        let isLink = a.mode & LinuxMode.IFMT == LinuxMode.IFLNK
                        return Entry(name: d.name, path: p, isDir: a.isDir, isLink: isLink,
                                     linkTarget: isLink ? try? c.readlink(fid: ef) : nil,
                                     size: a.size, mtime: Date(timeIntervalSince1970: TimeInterval(a.mtimeSec)),
                                     modeString: a.modeString, perm: a.mode & 0o7777,
                                     uid: String(a.uid), gid: String(a.gid),
                                     qidPath: a.qid.path, qidVersion: a.qid.version, qidType: a.qid.type)
                    } catch {
                        // Fall back to what Treaddir told us.
                        return Entry(name: d.name, path: p, isDir: d.qid.isDir, isLink: false, linkTarget: nil,
                                     size: 0, mtime: Date(timeIntervalSince1970: 0), modeString: "?",
                                     perm: 0, uid: "?", gid: "?",
                                     qidPath: d.qid.path, qidVersion: d.qid.version, qidType: d.qid.type)
                    }
                }
            }

            let iou = try c.open(fid: f, mode: Client.OREAD).iounit
            return try c.readDir(fid: f, iounit: iou).map { s in
                Entry(name: s.name, path: joinPath(path, s.name), isDir: s.qid.isDir, isLink: false,
                      linkTarget: nil, size: s.length,
                      mtime: Date(timeIntervalSince1970: TimeInterval(s.mtime)),
                      modeString: s.modeString, perm: s.mode & 0o777, uid: s.uid, gid: s.gid,
                      qidPath: s.qid.path, qidVersion: s.qid.version, qidType: s.qid.type)
            }
        }
    }

    /// Read up to `limit` bytes from the start of a file.
    func read(_ path: String, limit: Int) throws -> (bytes: [UInt8], truncated: Bool) {
        try withClient { c, root in
            let f = c.allocFid()
            try c.walk(fid: root, newfid: f, path: path)
            defer { try? c.clunk(fid: f) }
            let iou = c.dialect == .linux
                ? try c.lopen(fid: f, flags: LinuxOpen.RDONLY).iounit
                : try c.open(fid: f, mode: Client.OREAD).iounit
            let chunk = Int(c.maxIO(iounit: iou))
            var out: [UInt8] = []
            while out.count < limit {
                let want = UInt32(min(chunk, limit - out.count))
                let b = try c.read(fid: f, offset: UInt64(out.count), count: want)
                if b.isEmpty { return (out, false) }
                out += b
            }
            let more = try c.read(fid: f, offset: UInt64(out.count), count: 1)
            return (out, !more.isEmpty)
        }
    }
}

// MARK: - App model

@MainActor
final class AppModel: ObservableObject {
    enum Status { case setup, connecting, connected(String), failed(String) }

    @Published var cfg: Config
    private(set) var service: NineService
    @Published var status: Status
    @Published var nav: [Entry] = []

    init(cfg: Config, autoConnect: Bool) {
        self.cfg = cfg
        self.service = NineService(cfg: cfg)
        self.status = autoConnect ? .connecting : .setup
    }

    var version: String {
        if case .connected(let v) = status { return v }
        return ""
    }

    var rootTitle: String { cfg.aname.isEmpty ? cfg.host : (cfg.aname as NSString).lastPathComponent }

    func footer(count n: Int) -> String {
        "\(n) item\(n == 1 ? "" : "s") \u{00B7} \(version) \u{00B7} \(cfg.endpoint)"
    }

    /// Connect with `newConfig` (or the current one), replacing any old session.
    func connect(_ newConfig: Config? = nil) async {
        let old = service
        await old.reset()
        if let newConfig { cfg = newConfig }
        service = NineService(cfg: cfg)
        nav = []
        status = .connecting
        do {
            status = .connected(try await service.connect())
            Recents.add(cfg)
        } catch {
            status = .failed("\(error)")
        }
    }

    /// Drop the session and return to the connect screen.
    func disconnect() {
        let old = service
        Task { await old.reset() }
        nav = []
        status = .setup
    }

    /// True when connected to the server described by `c`.
    func isConnected(to c: Config) -> Bool {
        if case .connected = status { return cfg.key == c.key }
        return false
    }

    /// Current state for the watch (WatchConnectivity application context).
    var watchContext: WatchProto.Context {
        var x = WatchProto.Context()
        switch status {
        case .setup: x.status = "setup"
        case .connecting: x.status = "connecting"; x.server = cfg
        case .connected(let v): x.status = "connected"; x.server = cfg; x.version = v
        case .failed(let e): x.status = "failed"; x.server = cfg; x.error = e
        }
        x.title = rootTitle
        x.recents = Recents.load()
        return x
    }

    /// Directory listing, folders first, then Finder-style name order.
    func list(_ path: String) async throws -> [Entry] {
        try await service.list(path).sorted {
            if $0.isDir != $1.isDir { return $0.isDir }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func preview(_ path: String, limit: Int = FilePreview.limit) async throws -> (preview: FilePreview, truncated: Bool) {
        let (bytes, more) = try await service.read(path, limit: limit)
        return (FilePreview(bytes), more)
    }
}

#endif // !os(watchOS)

// MARK: - Formatting

enum Fmt {
    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func size(_ n: UInt64) -> String { bytes.string(fromByteCount: Int64(clamping: n)) }

    static func short(_ d: Date) -> String {
        if d.timeIntervalSince1970 == 0 { return "\u{2014}" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(date: .numeric, time: .omitted)
    }

    static func long(_ d: Date) -> String {
        d.timeIntervalSince1970 == 0 ? "\u{2014}" : d.formatted(date: .long, time: .shortened)
    }

    static func kind(_ e: Entry) -> String {
        if e.isDir { return "Folder" }
        if e.isLink { return "Symbolic Link" }
        if e.isExecutable && e.ext.isEmpty { return "Executable" }
        return e.ext.isEmpty ? "Document" : "\(e.ext.uppercased()) File"
    }

    static func subtitle(_ e: Entry) -> String {
        let date = short(e.mtime)
        if e.isDir { return "Folder \u{00B7} \(date)" }
        if e.isLink, let t = e.linkTarget { return "\u{2192} \(t)" }
        return "\(size(e.size)) \u{00B7} \(date)"
    }

    /// (label, value, monospaced) rows for a file's Information section.
    static func infoRows(_ e: Entry) -> [(String, String, Bool)] {
        var rows: [(String, String, Bool)] = [
            ("Kind", kind(e), false),
            ("Size", "\(size(e.size)) (\(e.size) bytes)", false),
            ("Modified", long(e.mtime), false),
            ("Permissions", e.modeString, true),
            ("Owner", e.uid, false),
            ("Group", e.gid, false),
        ]
        if let t = e.linkTarget { rows.append(("Link Target", t, true)) }
        rows.append(("Path", "/" + e.path, true))
        rows.append(("Qid", e.qidString, true))
        return rows
    }
}

// MARK: - File icon

struct FileIcon: View {
    let entry: Entry
    var size: CGFloat = 30

    static func symbol(for entry: Entry) -> (name: String, color: Color) {
        if entry.isDir { return ("folder.fill", .blue) }
        if entry.isLink { return ("link", .teal) }
        switch entry.ext {
        case "swift", "go", "c", "h", "m", "cpp", "rs", "py", "js", "ts", "sh", "rb", "java", "kt",
             "json", "yaml", "yml", "toml", "xml", "html", "css", "mod", "sum", "mk":
            return ("chevron.left.forwardslash.chevron.right", .orange)
        case "md", "txt", "rtf", "log", "csv":
            return ("doc.text.fill", .gray)
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "svg":
            return ("photo.fill", .pink)
        case "mp3", "wav", "m4a", "flac", "aac":
            return ("music.note", .red)
        case "mp4", "mov", "mkv", "avi":
            return ("film.fill", .purple)
        case "zip", "tar", "gz", "tgz", "xz", "bz2", "7z":
            return ("archivebox.fill", .brown)
        case "pdf":
            return ("doc.richtext.fill", .red)
        default:
            return entry.isExecutable ? ("terminal.fill", .green) : ("doc.fill", .gray)
        }
    }

    var body: some View {
        let (name, color) = Self.symbol(for: entry)
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: name)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

/// App-icon-style tile used on the connect screen and recents.
struct SymbolTile: View {
    let symbol: String
    var color: Color = .blue
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white))
    }
}

// MARK: - File preview

enum FilePreview {
    case text(String)
    case binary(String)
    case empty

    static let limit = 64 * 1024

    init(_ b: [UInt8]) {
        if b.isEmpty { self = .empty; return }
        if !b.contains(0) {
            // Allow a multi-byte character cut off at the preview limit.
            for drop in 0...min(3, b.count - 1) {
                if let s = String(bytes: b.dropLast(drop), encoding: .utf8) { self = .text(s); return }
            }
        }
        self = .binary(FilePreview.hexDump(Array(b.prefix(1024))) + (b.count > 1024 ? "\n\u{2026}" : ""))
    }

    var text: String? {
        if case .text(let s) = self { return s }
        return nil
    }

    static var truncatedNote: String { "Showing the first \(Fmt.size(UInt64(limit)))." }

    static func hexDump(_ b: [UInt8]) -> String {
        var lines: [String] = []
        for off in stride(from: 0, to: b.count, by: 16) {
            let row = b[off..<min(off + 16, b.count)]
            let hex = row.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = String(row.map { (0x20..<0x7f).contains($0) ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%06x  ", off) + hex.padding(toLength: 47, withPad: " ", startingAt: 0) + "  " + ascii)
        }
        return lines.joined(separator: "\n")
    }
}
