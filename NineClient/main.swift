// main.swift — NineClient: CLI for the NineP library (9P2000 and 9P2000.L).
//
// usage:
//   NineClient [flags] <tcp://host:port | host:port | --stdio> [command [args...]]
//
// Each invocation negotiates a version, attaches, runs one command, clunks
// every fid it used, and exits. (virgil-client keeps progress across
// connections, so its curriculum can be played one command at a time.)
//
// All diagnostics go to stderr so stdout stays clean in --stdio mode.

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

func log(_ s: String) {
    fputs("NineClient: \(s)\n", stderr)
}

func usage() -> Never {
    fputs("""
    usage: NineClient [flags] <tcp://host:port | host:port | --stdio> [command [args...]]

    flags:
      --proto <p>     9P2000 | 9P2000.L | auto (default auto: try 9P2000, then 9P2000.L)
      --msize <n>     requested msize (default 8192)
      --uname <name>  attach user name (default $USER; may be "")
      --uid <n>       numeric uid for 9P2000.L attach n_uname (default: none, 0xFFFFFFFF)
      --aname <path>  attach name / export to mount (default "")
      --perm <octal>  permission bits for create (default 0644)
      --auth          authenticate (Tauth + echo challenge) before attach
      --verbose, -v   hex-dump every frame to stderr

    commands (paths are relative to the attach root):
      ls [-l] [-q] [-R] [path...]  list directories (default: root)
                              -l long  -q show qids  -R recursive
      cat <path>              read a file to stdout          (default: cat task)
      write <path> <text>     write text at offset 0
      walk <path>             walk to path and print qids
      stat <path>             print stat (9P2000) or getattr (9P2000.L)
      statfs [path]           file system stats (9P2000.L)
      create <dir> <name> [text]  create file (perm 0644 or --perm), write text
      mkdir <dir> <name>      create directory (0755)
      rename <path> <newname> rename within the same directory
      chmod <octal> <path>    change permission bits
      rm <path>               remove file or empty directory
      open <path> [mode]      open (9P mode 0-3); on error prints the error to stdout
      flush <path>            open, send Tread without waiting, then Tflush its tag
      auth                    authenticated attach (same as --auth with no command)
      clunk [path]            walk to path (default: clone walk, nwname=0),
                              then clunk that fid

    """, stderr)
    exit(2)
}

func hex(_ b: [UInt8]) -> String {
    b.map { let h = String($0, radix: 16); return h.count == 1 ? "0" + h : h }.joined(separator: " ")
}

func parseHostPort(_ s: String) -> (String, UInt16)? {
    var rest = s
    if rest.hasPrefix("tcp://") { rest.removeFirst(6) }
    var host: String
    var portStr: String
    if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {   // [v6]:port
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

// MARK: args

var args = Array(CommandLine.arguments.dropFirst())
var msize: UInt32 = NineP.defaultMsize
var verbose = false
var useStdio = false
var uname = getenv("USER").map { String(cString: $0) } ?? "nobody"
var nUname = NineP.noNuname
var aname = ""
var proto = "auto"
var target: String?
var permFlag: UInt32?
var useAuth = false

func flagValue() -> String {
    args.removeFirst()
    guard !args.isEmpty else { usage() }
    return args[0]
}

flagLoop: while !args.isEmpty {
    let a = args[0]
    switch a {
    case "-h", "--help": usage()
    case "--verbose", "-v": verbose = true
    case "--stdio": useStdio = true
    case "--auth": useAuth = true
    case "--msize":
        guard let n = UInt32(flagValue()) else { usage() }
        msize = n
    case "--perm":
        guard let p = UInt32(flagValue(), radix: 8) else { usage() }
        permFlag = p
    case "--uname": uname = flagValue()
    case "--uid":
        guard let n = UInt32(flagValue()) else { usage() }
        nUname = n
    case "--aname": aname = flagValue()
    case "--proto":
        proto = flagValue()
        guard ["auto", NineP.version, NineP.version9P2000L].contains(proto) else { usage() }
    default:
        if a.hasPrefix("-") { usage() }
        if useStdio || target != nil { break flagLoop }   // start of command
        target = a
    }
    args.removeFirst()
}

let command = args.isEmpty ? ["cat", "task"] : args

// MARK: connect

let transport: Transport
do {
    if useStdio {
        transport = FDTransport.stdio()
    } else {
        guard let t = target, let (host, port) = parseHostPort(t) else { usage() }
        transport = try FDTransport.tcp(host: host, port: port)
    }
} catch {
    log("\(error)")
    exit(1)
}

let client = Client(transport: transport, msize: msize)
if verbose {
    client.trace = { dir, bytes in log("\(dir) \(hex(bytes))") }
}

// MARK: fid helpers

var openFids: [UInt32] = []

/// Walk from root to path on a fresh fid that will be clunked at exit.
func walkTo(_ root: UInt32, _ path: String) throws -> (UInt32, [Qid]) {
    let f = client.allocFid()
    let q = try client.walk(fid: root, newfid: f, path: path)
    openFids.append(f)
    return (f, q)
}

func forget(_ f: UInt32) { openFids.removeAll { $0 == f } }

func clunkAll() {
    for f in openFids.reversed() { try? client.clunk(fid: f) }
    openFids.removeAll()
}

func need(_ n: Int) {
    if command.count - 1 < n { usage() }
}

func joinPath(_ a: String, _ b: String) -> String {
    (a.isEmpty || a == "." || a == "/") ? b : (a.hasSuffix("/") ? a + b : a + "/" + b)
}

/// Split "a/b/c" into ("a/b", "c"); "c" into (".", "c").
func splitPath(_ p: String) -> (dir: String, base: String) {
    let trimmed = p.hasSuffix("/") ? String(p.dropLast()) : p
    guard let slash = trimmed.lastIndex(of: "/") else { return (".", trimmed) }
    let dir = String(trimmed[..<slash])
    return (dir.isEmpty ? "." : dir, String(trimmed[trimmed.index(after: slash)...]))
}

// MARK: dialect-neutral operations

var linux: Bool { client.dialect == .linux }

/// Open with a 9P2000 mode; mapped to Linux flags under 9P2000.L.
func openFid(_ f: UInt32, _ mode: UInt8) throws -> UInt32 {
    if linux { return try client.lopen(fid: f, flags: LinuxOpen.from9P(mode)).iounit }
    return try client.open(fid: f, mode: mode).iounit
}

/// File metadata common to both dialects.
struct Info {
    var name: String
    var isDir: Bool
    var mode: String
    var uid: String
    var gid: String
    var length: UInt64
    var mtime: UInt64
    var qid: Qid
    var link: String? = nil
}

func info(from s: Stat) -> Info {
    Info(name: s.name, isDir: s.qid.isDir, mode: s.modeString, uid: s.uid, gid: s.gid,
         length: s.length, mtime: UInt64(s.mtime), qid: s.qid)
}

func info(from a: LAttr, name: String) -> Info {
    Info(name: name, isDir: a.isDir, mode: a.modeString, uid: String(a.uid), gid: String(a.gid),
         length: a.size, mtime: a.mtimeSec, qid: a.qid)
}

/// Metadata for a walked fid. `name` is used under 9P2000.L (getattr has no name).
func info(_ f: UInt32, name: String) throws -> Info {
    if linux {
        let a = try client.getattr(fid: f)
        var i = info(from: a, name: name)
        if a.mode & LinuxMode.IFMT == LinuxMode.IFLNK { i.link = try? client.readlink(fid: f) }
        return i
    }
    return info(from: try client.stat(fid: f))
}

/// List the directory at `path`. Under 9P2000.L with `long`, each entry is
/// walked to and getattr'd individually (Treaddir carries only qid/type/name).
func listDir(root: UInt32, path: String, long: Bool) throws -> [Info] {
    let f = client.allocFid()
    try client.walk(fid: root, newfid: f, path: path)
    defer { try? client.clunk(fid: f) }
    let iou = try openFid(f, Client.OREAD)
    if !linux {
        return try client.readDir(fid: f, iounit: iou).map { info(from: $0) }
    }
    let ents = try client.readdirAll(fid: f, iounit: iou).filter { $0.name != "." && $0.name != ".." }
    return try ents.map { d in
        guard long else {
            return Info(name: d.name, isDir: d.qid.isDir, mode: "", uid: "", gid: "",
                        length: 0, mtime: 0, qid: d.qid)
        }
        let ef = client.allocFid()
        try client.walk(fid: root, newfid: ef, path: joinPath(path, d.name))
        defer { try? client.clunk(fid: ef) }
        return try info(ef, name: d.name)
    }
}

/// Group id of a directory, for 9P2000.L create/mkdir.
func dirGid(_ f: UInt32) throws -> UInt32 {
    try client.getattr(fid: f, mask: LAttr.GID).gid
}

// MARK: ls

func fmtTime(_ t: UInt64) -> String {
    var tt = time_t(t)
    var tmv = tm()
    localtime_r(&tt, &tmv)
    let recent = abs(Int(time(nil)) - Int(t)) < 180 * 24 * 3600
    var buf = [Int8](repeating: 0, count: 32)
    strftime(&buf, buf.count, recent ? "%b %e %H:%M" : "%b %e  %Y", &tmv)
    return String(cString: buf)
}

func pad(_ s: String, _ w: Int, right: Bool = false) -> String {
    let p = String(repeating: " ", count: max(0, w - s.count))
    return right ? p + s : s + p
}

func printEntries(_ entries: [Info], long: Bool, qids: Bool) {
    if !long {
        for s in entries {
            let name = s.name + (s.isDir ? "/" : "")
            print(qids ? "\(pad(name, 24)) \(s.qid)" : name)
        }
        return
    }
    let uw = entries.map { $0.uid.count }.max() ?? 0
    let gw = entries.map { $0.gid.count }.max() ?? 0
    let lw = entries.map { String($0.length).count }.max() ?? 0
    for s in entries {
        var line = "\(s.mode) \(pad(s.uid, uw)) \(pad(s.gid, gw)) "
        line += "\(pad(String(s.length), lw, right: true)) \(fmtTime(s.mtime)) "
        line += s.name + (s.isDir ? "/" : "")
        if let l = s.link { line += " -> \(l)" }
        if qids { line += "  \(s.qid)" }
        print(line)
    }
}

/// List one path: a directory's entries, or a file's own metadata.
func listPath(root: UInt32, path: String, long: Bool, qids: Bool, recursive: Bool, header: Bool) throws {
    let f = client.allocFid()
    let wq = try client.walk(fid: root, newfid: f, path: path)
    let isDir: Bool
    if let last = wq.last {
        isDir = last.isDir
    } else {
        isDir = try info(f, name: ".").isDir     // path was the root itself
    }
    if !isDir {
        defer { try? client.clunk(fid: f) }
        printEntries([try info(f, name: splitPath(path).base)], long: long, qids: qids)
        return
    }
    try? client.clunk(fid: f)
    let entries = try listDir(root: root, path: path, long: long).sorted { $0.name < $1.name }
    if header { print("\(path.isEmpty ? "." : path):") }
    printEntries(entries, long: long, qids: qids)
    if recursive {
        for e in entries where e.isDir {
            print("")
            try listPath(root: root, path: joinPath(path, e.name), long: long, qids: qids,
                         recursive: true, header: true)
        }
    }
}

func runLs(root: UInt32, args: [String]) throws {
    var long = false, qids = false, recursive = false
    var paths: [String] = []
    for a in args {
        if a.hasPrefix("-") && a.count > 1 {
            for c in a.dropFirst() {
                switch c {
                case "l": long = true
                case "q": qids = true
                case "R": recursive = true
                default: log("ls: unknown flag -\(c)"); usage()
                }
            }
        } else {
            paths.append(a)
        }
    }
    if paths.isEmpty { paths = ["."] }
    for (i, p) in paths.enumerated() {
        if i > 0 { print("") }
        try listPath(root: root, path: p, long: long, qids: qids, recursive: recursive,
                     header: paths.count > 1 || recursive)
    }
}

// MARK: session

do {
    let versions: [String]
    switch proto {
    case "auto": versions = [NineP.version, NineP.version9P2000L]
    default: versions = [proto]
    }
    let (m, v) = try client.negotiate(versions: versions)
    if verbose { log("Rversion: msize=\(m) version=\(v)") }

    // Optional auth: Tauth, then run virgil's echo-challenge protocol on the
    // afid (read the challenge, write it back), then attach with that afid.
    var afid = NineP.noFid
    if useAuth || command[0] == "auth" {
        afid = client.allocFid()
        let aq = try client.auth(afid: afid, uname: uname, aname: aname, nUname: nUname)
        openFids.append(afid)
        log("Rauth: afid=\(afid) aqid=\(aq)")
        let challenge = try client.read(fid: afid, offset: 0, count: 4096)
        log("challenge: \(hex(challenge))")
        try client.writeAll(fid: afid, data: challenge)
    }

    let root = client.allocFid()
    let rq = try client.attach(fid: root, afid: afid, uname: uname, aname: aname, nUname: nUname)
    openFids.append(root)
    if verbose || afid != NineP.noFid { log("Rattach: fid=\(root) afid=\(afid) qid=\(rq)") }

    switch command[0] {
    case "cat":
        need(1)
        let (f, _) = try walkTo(root, command[1])
        let iou = try openFid(f, Client.OREAD)
        let data = try client.readAll(fid: f, iounit: iou)
        data.withUnsafeBytes { _ = fwrite($0.baseAddress, 1, $0.count, stdout) }
        fflush(stdout)

    case "write":
        need(2)
        let (f, _) = try walkTo(root, command[1])
        let iou = try openFid(f, Client.OWRITE)
        let text = command[2...].joined(separator: " ")
        try client.writeAll(fid: f, data: Array(text.utf8), iounit: iou)
        log("wrote \(text.utf8.count) bytes to \(command[1])")

    case "walk":
        need(1)
        let (f, q) = try walkTo(root, command[1])
        print("fid=\(f) qids=\(q)")

    case "stat":
        need(1)
        let (f, _) = try walkTo(root, command[1])
        if linux { print(try client.getattr(fid: f, mask: LAttr.ALL)) }
        else { print(try client.stat(fid: f)) }

    case "statfs":
        guard linux else { log("statfs requires 9P2000.L"); exit(1) }
        let (f, _) = try walkTo(root, command.count > 1 ? command[1] : ".")
        print(try client.statfs(fid: f))

    case "create":
        // create <dir> <name> [text...] — perm 0644 (or --perm), open for writing, write text
        need(2)
        let (f, _) = try walkTo(root, command[1])
        let perm = permFlag ?? 0o644
        let q: Qid, iou: UInt32
        if linux {
            (q, iou) = try client.lcreate(fid: f, name: command[2], flags: LinuxOpen.WRONLY,
                                          mode: perm, gid: try dirGid(f))
        } else {
            (q, iou) = try client.create(fid: f, name: command[2], perm: perm, mode: Client.OWRITE)
        }
        log("created \(joinPath(command[1], command[2])) qid=\(q)")
        if command.count > 3 {
            let text = command[3...].joined(separator: " ")
            try client.writeAll(fid: f, data: Array(text.utf8), iounit: iou)
            log("wrote \(text.utf8.count) bytes")
        }

    case "mkdir":
        need(2)
        let (f, _) = try walkTo(root, command[1])
        let q: Qid
        if linux {
            q = try client.mkdir(dfid: f, name: command[2], mode: 0o755, gid: try dirGid(f))
        } else {
            q = try client.create(fid: f, name: command[2], perm: Client.DMDIR | 0o755, mode: Client.OREAD).qid
        }
        log("created directory \(joinPath(command[1], command[2])) qid=\(q)")

    case "rename":
        need(2)
        if linux {
            let (dir, base) = splitPath(command[1])
            let (d, _) = try walkTo(root, dir)
            try client.renameat(oldDirFid: d, oldName: base, newDirFid: d, newName: command[2])
        } else {
            let (f, _) = try walkTo(root, command[1])
            var st = Stat.dontTouch()
            st.name = command[2]
            try client.wstat(fid: f, stat: st)
        }
        log("renamed \(command[1]) -> \(command[2])")

    case "chmod":
        need(2)
        guard let m = UInt32(command[1], radix: 8) else { usage() }
        let (f, _) = try walkTo(root, command[2])
        if linux {
            var a = LSetAttr()
            a.valid = LSetAttr.MODE
            a.mode = m & 0o7777
            try client.setattr(fid: f, a)
        } else {
            let cur = try client.stat(fid: f)
            var st = Stat.dontTouch()
            st.mode = (cur.mode & 0xFFFF_FE00) | (m & 0o777)
            try client.wstat(fid: f, stat: st)
        }
        log("chmod \(command[1]) \(command[2])")

    case "rm":
        need(1)
        if linux {
            let (dir, base) = splitPath(command[1])
            let (t, tq) = try walkTo(root, command[1])
            let isDir = tq.last?.isDir ?? false
            try client.clunk(fid: t); forget(t)
            let (d, _) = try walkTo(root, dir)
            try client.unlinkat(dirFid: d, name: base, flags: isDir ? Client.AT_REMOVEDIR : 0)
        } else {
            let (f, _) = try walkTo(root, command[1])
            forget(f)   // Tremove retires the fid even on error
            try client.remove(fid: f)
        }
        log("removed \(command[1])")

    case "open":
        // open <path> [mode]
        // On success prints the qid/iounit; on error prints the bare error to stdout.
        need(1)
        let mode = command.count > 2 ? UInt8(command[2]) ?? Client.OREAD : Client.OREAD
        let (f, _) = try walkTo(root, command[1])
        do {
            let (q, iou) = linux ? try client.lopen(fid: f, flags: LinuxOpen.from9P(mode))
                                 : try client.open(fid: f, mode: mode)
            print("qid=\(q) iounit=\(iou)")
        } catch let err as NinePError {
            switch err {
            case .server(let ename): print(ename)
            case .lerror(let code): print(NinePError.linuxErrnoName(code))
            default: throw err
            }
            clunkAll()
            client.close()
            exit(1)
        }

    case "flush":
        need(1)
        let (f, _) = try walkTo(root, command[1])
        let iou = try openFid(f, Client.OREAD)
        var e = Encoder()
        e.u32(f); e.u64(0); e.u32(client.maxIO(iounit: iou))
        let tag = try client.start(.Tread, body: e.bytes)
        log("Tread outstanding on tag \(tag); sending Tflush")
        if let late = try client.flush(oldtag: tag) {
            log("server answered tag \(tag) (type \(late.type)) before Rflush")
        } else {
            log("Rflush: tag \(tag) flushed")
        }

    case "auth":
        log("authenticated attach complete")

    case "ls":
        try runLs(root: root, args: Array(command.dropFirst()))

    case "clunk":
        // No path (or ".") = clone walk: Twalk nwname=0 copies root onto a new fid.
        let path = command.count > 1 ? command[1] : "."
        let (f, _) = try walkTo(root, path)
        try client.clunk(fid: f)
        forget(f)
        log("clunked fid \(f) (\(path))")

    default:
        log("unknown command '\(command[0])'")
        usage()
    }

    clunkAll()
} catch {
    log("\(error)")
    clunkAll()
    client.close()
    exit(1)
}

client.close()
exit(0)
