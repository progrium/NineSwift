// NineP.swift — single-file 9P2000 client library.
//
// Scope: wire codec, framing, transports (TCP / stdio / any fd pair), and
// the Tversion/Rversion handshake (with Rerror handling). The codec is
// written so further T/R messages can be added as small methods on Client.

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Constants

public enum NineP {
    public static let version = "9P2000"
    public static let noTag: UInt16 = 0xFFFF
    public static let noFid: UInt32 = 0xFFFF_FFFF
    public static let headerSize = 7          // size[4] type[1] tag[2]
    public static let defaultMsize: UInt32 = 8192
    public static let version9P2000L = "9P2000.L"
    /// "No numeric uid" for the 9P2000.L n_uname field.
    public static let noNuname: UInt32 = 0xFFFF_FFFF
}

/// Protocol dialect, chosen by the version string the server accepts.
public enum Dialect: CustomStringConvertible {
    case plain      // 9P2000
    case linux      // 9P2000.L

    public var description: String { self == .plain ? NineP.version : NineP.version9P2000L }
}

public enum MsgType: UInt8 {
    case Tversion = 100, Rversion
    case Tauth = 102, Rauth
    case Tattach = 104, Rattach
    case Terror = 106, Rerror
    case Tflush = 108, Rflush
    case Twalk = 110, Rwalk
    case Topen = 112, Ropen
    case Tcreate = 114, Rcreate
    case Tread = 116, Rread
    case Twrite = 118, Rwrite
    case Tclunk = 120, Rclunk
    case Tremove = 122, Rremove
    case Tstat = 124, Rstat
    case Twstat = 126, Rwstat

    // 9P2000.L additions
    case Tlerror = 6, Rlerror
    case Tstatfs = 8, Rstatfs
    case Tlopen = 12, Rlopen
    case Tlcreate = 14, Rlcreate
    case Tsymlink = 16, Rsymlink
    case Tmknod = 18, Rmknod
    case Trename = 20, Rrename
    case Treadlink = 22, Rreadlink
    case Tgetattr = 24, Rgetattr
    case Tsetattr = 26, Rsetattr
    case Txattrwalk = 30, Rxattrwalk
    case Txattrcreate = 32, Rxattrcreate
    case Treaddir = 40, Rreaddir
    case Tfsync = 50, Rfsync
    case Tlock = 52, Rlock
    case Tgetlock = 54, Rgetlock
    case Tlink = 70, Rlink
    case Tmkdir = 72, Rmkdir
    case Trenameat = 74, Rrenameat
    case Tunlinkat = 76, Runlinkat
}

// MARK: - Errors

public enum NinePError: Error, CustomStringConvertible {
    case io(String)
    case closed
    case protocolError(String)
    case server(String)          // Rerror ename
    case lerror(UInt32)          // 9P2000.L Rlerror (Linux errno)

    public var description: String {
        switch self {
        case .io(let s): return "io: \(s)"
        case .closed: return "connection closed"
        case .protocolError(let s): return "protocol: \(s)"
        case .server(let s): return "server error: \(s)"
        case .lerror(let e): return "server error: \(NinePError.linuxErrnoName(e))"
        }
    }

    /// Linux errno numbers (as sent in Rlerror) \u{2014} not the host's, which differ on macOS.
    static let linuxErrnos: [UInt32: String] = [
        1: "EPERM: operation not permitted", 2: "ENOENT: no such file or directory",
        5: "EIO: input/output error", 9: "EBADF: bad file descriptor",
        11: "EAGAIN: try again", 12: "ENOMEM: out of memory",
        13: "EACCES: permission denied", 16: "EBUSY: device or resource busy",
        17: "EEXIST: file exists", 18: "EXDEV: cross-device link",
        20: "ENOTDIR: not a directory", 21: "EISDIR: is a directory",
        22: "EINVAL: invalid argument", 24: "EMFILE: too many open files",
        27: "EFBIG: file too large", 28: "ENOSPC: no space left on device",
        30: "EROFS: read-only file system", 31: "EMLINK: too many links",
        36: "ENAMETOOLONG: file name too long", 38: "ENOSYS: function not implemented",
        39: "ENOTEMPTY: directory not empty", 40: "ELOOP: too many symbolic links",
        61: "ENODATA: no data available", 71: "EPROTO: protocol error",
        75: "EOVERFLOW: value too large", 95: "EOPNOTSUPP: operation not supported",
        110: "ETIMEDOUT: connection timed out", 116: "ESTALE: stale file handle",
        122: "EDQUOT: disk quota exceeded",
    ]

    public static func linuxErrnoName(_ e: UInt32) -> String {
        linuxErrnos[e].map { "\($0) (errno \(e))" } ?? "errno \(e)"
    }
}

// MARK: - Codec (little-endian)

public struct Encoder {
    public private(set) var bytes: [UInt8] = []
    public init() {}

    public mutating func u8(_ v: UInt8) { bytes.append(v) }
    public mutating func u16(_ v: UInt16) {
        bytes.append(UInt8(v & 0xff)); bytes.append(UInt8(v >> 8))
    }
    public mutating func u32(_ v: UInt32) {
        for i in 0..<4 { bytes.append(UInt8((v >> (8 * UInt32(i))) & 0xff)) }
    }
    public mutating func u64(_ v: UInt64) {
        for i in 0..<8 { bytes.append(UInt8((v >> (8 * UInt64(i))) & 0xff)) }
    }
    public mutating func str(_ s: String) {
        let utf8 = Array(s.utf8)
        u16(UInt16(utf8.count)); bytes.append(contentsOf: utf8)
    }
    public mutating func raw(_ b: [UInt8]) { bytes.append(contentsOf: b) }
}

public struct Decoder {
    let bytes: [UInt8]
    public private(set) var pos: Int = 0
    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public var remaining: Int { bytes.count - pos }

    mutating func need(_ n: Int) throws {
        if remaining < n { throw NinePError.protocolError("short message: need \(n) bytes, have \(remaining)") }
    }
    public mutating func u8() throws -> UInt8 {
        try need(1); defer { pos += 1 }; return bytes[pos]
    }
    public mutating func u16() throws -> UInt16 {
        try need(2); defer { pos += 2 }
        return UInt16(bytes[pos]) | UInt16(bytes[pos + 1]) << 8
    }
    public mutating func u32() throws -> UInt32 {
        try need(4); defer { pos += 4 }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[pos + i]) << (8 * UInt32(i)) }
        return v
    }
    public mutating func u64() throws -> UInt64 {
        try need(8); defer { pos += 8 }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[pos + i]) << (8 * UInt64(i)) }
        return v
    }
    public mutating func str() throws -> String {
        let n = Int(try u16()); try need(n); defer { pos += n }
        return String(decoding: bytes[pos..<pos + n], as: UTF8.self)
    }
    public mutating func raw(_ n: Int) throws -> [UInt8] {
        try need(n); defer { pos += n }; return Array(bytes[pos..<pos + n])
    }
}

/// A decoded frame: type, tag, and the body after the 7-byte header.
public struct Frame {
    public let type: UInt8
    public let tag: UInt16
    public let body: [UInt8]

    public var msgType: MsgType? { MsgType(rawValue: type) }

    /// Build a complete wire frame: size[4] type[1] tag[2] body.
    public static func encode(_ type: MsgType, tag: UInt16, body: [UInt8]) -> [UInt8] {
        var e = Encoder()
        e.u32(UInt32(NineP.headerSize + body.count))
        e.u8(type.rawValue)
        e.u16(tag)
        e.raw(body)
        return e.bytes
    }
}

// MARK: - Transport

public protocol Transport {
    func write(_ bytes: [UInt8]) throws
    func read(exactly n: Int) throws -> [UInt8]
    func close()
}

/// Transport over a pair of file descriptors (sockets, pipes, stdio).
public final class FDTransport: Transport {
    let rfd: Int32
    let wfd: Int32
    let owns: Bool
    private var closed = false

    public init(readFD: Int32, writeFD: Int32, ownsFDs: Bool) {
        rfd = readFD; wfd = writeFD; owns = ownsFDs
    }

    /// stdin/stdout — for `virgil-client stdio://./client`.
    public static func stdio() -> FDTransport {
        signal(SIGPIPE, SIG_IGN)
        return FDTransport(readFD: 0, writeFD: 1, ownsFDs: false)
    }

    /// Connect over TCP to host:port.
    /// Connect over TCP to host:port.
    /// - timeout: max seconds for the TCP connect (per address); nil = OS default.
    /// - ioTimeout: max seconds a single read/write may block; nil = forever.
    public static func tcp(host: String, port: UInt16,
                           timeout: Double? = nil, ioTimeout: Double? = nil) throws -> FDTransport {
        signal(SIGPIPE, SIG_IGN)
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let first = res else {
            throw NinePError.io("resolve \(host): \(String(cString: gai_strerror(rc)))")
        }
        defer { freeaddrinfo(first) }
        var lastErr = "no addresses"
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if fd >= 0 {
                #if canImport(Darwin)
                var nosig: Int32 = 1   // no SIGPIPE on this socket even if the process handler changes
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
                #endif
                if let err = connectFD(fd, a.pointee.ai_addr, a.pointee.ai_addrlen, timeout: timeout) {
                    lastErr = err
                    Darwin_close(fd)
                } else {
                    var one: Int32 = 1
                    setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                    if let t = ioTimeout, t > 0 {
                        var tv = timeval(tv_sec: Int(t), tv_usec: Int32((t - Double(Int(t))) * 1_000_000))
                        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                    }
                    return FDTransport(readFD: fd, writeFD: fd, ownsFDs: true)
                }
            } else {
                lastErr = String(cString: strerror(errno))
            }
            ai = a.pointee.ai_next
        }
        throw NinePError.io("connect \(host):\(port): \(lastErr)")
    }

    /// connect(2), optionally bounded by a timeout. Returns an error string or nil on success.
    private static func connectFD(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t,
                                  timeout: Double?) -> String? {
        guard let timeout, timeout > 0 else {
            return connect(fd, addr, len) == 0 ? nil : String(cString: strerror(errno))
        }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, flags) }
        if connect(fd, addr, len) == 0 { return nil }
        guard errno == EINPROGRESS else { return String(cString: strerror(errno)) }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let n = poll(&pfd, 1, Int32(timeout * 1000))
        if n == 0 { return "timed out after \(timeout)s" }
        if n < 0 { return String(cString: strerror(errno)) }
        var soerr: Int32 = 0
        var sl = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &sl)
        return soerr == 0 ? nil : String(cString: strerror(soerr))
    }

    public func write(_ bytes: [UInt8]) throws {
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { buf in
                sysWrite(wfd, buf.baseAddress, buf.count)
            }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw NinePError.io("write: timed out") }
                throw NinePError.io("write: \(String(cString: strerror(errno)))")
            }
            off += n
        }
    }

    public func read(exactly n: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: n)
        var off = 0
        while off < n {
            let r = buf.withUnsafeMutableBytes { p in
                sysRead(rfd, p.baseAddress! + off, n - off)
            }
            if r == 0 { throw NinePError.closed }
            if r < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw NinePError.io("read: timed out") }
                throw NinePError.io("read: \(String(cString: strerror(errno)))")
            }
            off += r
        }
        return buf
    }

    public func close() {
        guard !closed else { return }
        closed = true
        if owns {
            Darwin_close(rfd)
            if wfd != rfd { Darwin_close(wfd) }
        }
    }

    deinit { close() }
}

// Disambiguate libc calls from our method names.
@inline(__always) private func sysRead(_ fd: Int32, _ p: UnsafeMutableRawPointer?, _ n: Int) -> Int {
    #if canImport(Darwin)
    return Darwin.read(fd, p, n)
    #else
    return Glibc.read(fd, p, n)
    #endif
}
@inline(__always) private func sysWrite(_ fd: Int32, _ p: UnsafeRawPointer?, _ n: Int) -> Int {
    #if canImport(Darwin)
    return Darwin.write(fd, p, n)
    #else
    return Glibc.write(fd, p, n)
    #endif
}
@inline(__always) private func Darwin_close(_ fd: Int32) {
    #if canImport(Darwin)
    _ = Darwin.close(fd)
    #else
    _ = Glibc.close(fd)
    #endif
}

// MARK: - Client

/// qid[13]: type[1] version[4] path[8]
public struct Qid: CustomStringConvertible, Equatable {
    public let type: UInt8
    public let version: UInt32
    public let path: UInt64

    public static let dir: UInt8 = 0x80
    public static let append: UInt8 = 0x40
    public static let excl: UInt8 = 0x20
    public static let auth: UInt8 = 0x08
    public static let tmp: UInt8 = 0x04

    public var isDir: Bool { type & Qid.dir != 0 }

    public init(type: UInt8, version: UInt32, path: UInt64) {
        self.type = type; self.version = version; self.path = path
    }

    public static func decode(_ d: inout Decoder) throws -> Qid {
        Qid(type: try d.u8(), version: try d.u32(), path: try d.u64())
    }

    public var description: String {
        "(type=0x\(String(type, radix: 16)) vers=\(version) path=\(path))"
    }
}

/// Directory entry / stat record:
/// size[2] type[2] dev[4] qid[13] mode[4] atime[4] mtime[4] length[8]
/// name[s] uid[s] gid[s] muid[s]
public struct Stat: CustomStringConvertible {
    public var type: UInt16
    public var dev: UInt32
    public var qid: Qid
    public var mode: UInt32
    public var atime: UInt32
    public var mtime: UInt32
    public var length: UInt64
    public var name: String
    public var uid: String
    public var gid: String
    public var muid: String

    public init(type: UInt16 = 0, dev: UInt32 = 0, qid: Qid = Qid(type: 0, version: 0, path: 0),
                mode: UInt32 = 0, atime: UInt32 = 0, mtime: UInt32 = 0, length: UInt64 = 0,
                name: String = "", uid: String = "", gid: String = "", muid: String = "") {
        self.type = type; self.dev = dev; self.qid = qid; self.mode = mode
        self.atime = atime; self.mtime = mtime; self.length = length
        self.name = name; self.uid = uid; self.gid = gid; self.muid = muid
    }

    /// A stat for Twstat where every field means "don't change":
    /// all-ones integers and empty strings.
    public static func dontTouch() -> Stat {
        Stat(type: 0xFFFF, dev: 0xFFFF_FFFF,
             qid: Qid(type: 0xFF, version: 0xFFFF_FFFF, path: 0xFFFF_FFFF_FFFF_FFFF),
             mode: 0xFFFF_FFFF, atime: 0xFFFF_FFFF, mtime: 0xFFFF_FFFF,
             length: 0xFFFF_FFFF_FFFF_FFFF)
    }

    /// Decode one stat record (including its leading size[2]).
    public static func decode(_ d: inout Decoder) throws -> Stat {
        let size = Int(try d.u16())
        guard d.remaining >= size else {
            throw NinePError.protocolError("stat size \(size) exceeds \(d.remaining) available")
        }
        return Stat(type: try d.u16(), dev: try d.u32(), qid: try Qid.decode(&d),
                    mode: try d.u32(), atime: try d.u32(), mtime: try d.u32(),
                    length: try d.u64(), name: try d.str(), uid: try d.str(),
                    gid: try d.str(), muid: try d.str())
    }

    /// Decode a directory read: a sequence of stat records.
    public static func decodeAll(_ bytes: [UInt8]) throws -> [Stat] {
        var d = Decoder(bytes)
        var out: [Stat] = []
        while d.remaining > 0 { out.append(try decode(&d)) }
        return out
    }

    /// Encode the stat record, including its leading size[2].
    public func encode() -> [UInt8] {
        var e = Encoder()
        e.u16(type); e.u32(dev)
        e.u8(qid.type); e.u32(qid.version); e.u64(qid.path)
        e.u32(mode); e.u32(atime); e.u32(mtime); e.u64(length)
        e.str(name); e.str(uid); e.str(gid); e.str(muid)
        var out = Encoder()
        out.u16(UInt16(e.bytes.count))
        out.raw(e.bytes)
        return out.bytes
    }

    /// Plan 9 style mode string, e.g. "d-rwxr-xr-x", "a-rw-r--r--".
    public var modeString: String {
        var s = ""
        if mode & 0x8000_0000 != 0 { s += "d" }
        else if mode & 0x4000_0000 != 0 { s += "a" }
        else if mode & 0x0800_0000 != 0 { s += "A" }     // DMAUTH
        else { s += "-" }
        s += mode & 0x2000_0000 != 0 ? "l" : "-"         // DMEXCL
        let rwx: [Character] = ["r", "w", "x"]
        for shift in stride(from: 6, through: 0, by: -3) {
            let bits = (mode >> UInt32(shift)) & 7
            for (i, c) in rwx.enumerated() {
                s.append(bits & (4 >> UInt32(i)) != 0 ? c : "-")
            }
        }
        return s
    }

    public var description: String {
        "name=\(name) qid=\(qid) mode=0\(String(mode, radix: 8)) atime=\(atime) mtime=\(mtime) "
        + "length=\(length) uid=\(uid) gid=\(gid) muid=\(muid) type=\(type) dev=\(dev)"
    }
}

public final class Client {
    public let transport: Transport
    /// Negotiated maximum message size (set by `version`).
    public private(set) var msize: UInt32
    /// Negotiated protocol version string (set by `version`).
    public private(set) var negotiatedVersion: String = ""
    /// Optional hook for tracing frames: (direction, frame bytes).
    public var trace: ((String, [UInt8]) -> Void)?

    private var nextTag: UInt16 = 0

    public init(transport: Transport, msize: UInt32 = NineP.defaultMsize) {
        self.transport = transport
        self.msize = msize
    }

    public func close() { transport.close() }

    // MARK: framing

    func allocTag() -> UInt16 {
        let t = nextTag
        nextTag = nextTag &+ 1
        if nextTag == NineP.noTag { nextTag = 0 }
        return t
    }

    public func send(_ type: MsgType, tag: UInt16, body: [UInt8]) throws {
        let frame = Frame.encode(type, tag: tag, body: body)
        trace?("->", frame)
        try transport.write(frame)
    }

    public func receive() throws -> Frame {
        let szb = try transport.read(exactly: 4)
        var d = Decoder(szb)
        let size = try d.u32()
        guard size >= UInt32(NineP.headerSize) else {
            throw NinePError.protocolError("frame size \(size) smaller than header")
        }
        guard size <= max(msize, NineP.defaultMsize) else {
            throw NinePError.protocolError("frame size \(size) exceeds msize \(msize)")
        }
        let rest = try transport.read(exactly: Int(size) - 4)
        trace?("<-", szb + rest)
        var h = Decoder(rest)
        let type = try h.u8()
        let tag = try h.u16()
        return Frame(type: type, tag: tag, body: Array(rest[3...]))
    }

    /// Send a T-message and wait for its reply. Rerror becomes a thrown
    /// `.server`; any other unexpected type/tag is a protocol error.
    public func rpc(_ type: MsgType, tag: UInt16? = nil, body: [UInt8], expect: MsgType) throws -> Decoder {
        let t = tag ?? allocTag()
        try send(type, tag: t, body: body)
        let f = try receive()
        guard f.tag == t else {
            throw NinePError.protocolError("reply tag \(f.tag) does not match request tag \(t)")
        }
        try checkError(f)
        guard f.type == expect.rawValue else {
            throw NinePError.protocolError("expected \(expect) (\(expect.rawValue)), got type \(f.type)")
        }
        return Decoder(f.body)
    }

    /// Throw if the frame is Rerror (9P2000) or Rlerror (9P2000.L).
    public func checkError(_ f: Frame) throws {
        if f.type == MsgType.Rerror.rawValue {
            var d = Decoder(f.body)
            throw NinePError.server(try d.str())
        }
        if f.type == MsgType.Rlerror.rawValue {
            var d = Decoder(f.body)
            throw NinePError.lerror(try d.u32())
        }
    }

    // MARK: Tversion / Rversion

    /// Dialect in effect after `version` (affects attach/auth encoding).
    public private(set) var dialect: Dialect = .plain

    /// size[4] Tversion tag[2]=NOTAG msize[4] version[s]
    /// size[4] Rversion tag[2] msize[4] version[s]
    @discardableResult
    public func version(msize requested: UInt32? = nil, version v: String = NineP.version) throws -> (msize: UInt32, version: String) {
        let want = requested ?? msize
        var e = Encoder()
        e.u32(want)
        e.str(v)
        var d = try rpc(.Tversion, tag: NineP.noTag, body: e.bytes, expect: .Rversion)
        let rmsize = try d.u32()
        let rversion = try d.str()
        if rversion == "unknown" {
            throw NinePError.protocolError("server does not speak \(v)")
        }
        guard rversion == v || v.hasPrefix(rversion) else {
            throw NinePError.protocolError("server replied with version \(rversion)")
        }
        guard rmsize <= want else {
            throw NinePError.protocolError("server msize \(rmsize) exceeds requested \(want)")
        }
        guard rmsize >= UInt32(NineP.headerSize + 17) else {
            throw NinePError.protocolError("server msize \(rmsize) too small")
        }
        msize = rmsize
        negotiatedVersion = rversion
        dialect = rversion == NineP.version9P2000L ? .linux : .plain
        nextTag = 0  // Tversion resets the session
        nextFid = 0
        return (rmsize, rversion)
    }

    /// Try each version in order on this connection (a fresh Tversion is
    /// allowed after a refusal) and keep the first one the server accepts.
    @discardableResult
    public func negotiate(versions: [String] = [NineP.version, NineP.version9P2000L],
                          msize requested: UInt32? = nil) throws -> (msize: UInt32, version: String) {
        let want = requested ?? msize
        var lastError: Error = NinePError.protocolError("no versions to try")
        for v in versions {
            do {
                return try version(msize: want, version: v)
            } catch let err as NinePError {
                if case .protocolError = err { lastError = err; continue }
                throw err
            }
        }
        throw lastError
    }

    // MARK: fids

    private var nextFid: UInt32 = 0

    /// Allocate a fresh fid number (never NOFID).
    public func allocFid() -> UInt32 {
        let f = nextFid
        nextFid = nextFid &+ 1
        if nextFid == NineP.noFid { nextFid = 0 }
        return f
    }

    // MARK: Tattach / Rattach

    /// size[4] Tattach tag[2] fid[4] afid[4] uname[s] aname[s]            (9P2000)
    /// size[4] Tattach tag[2] fid[4] afid[4] uname[s] aname[s] n_uname[4] (9P2000.L)
    /// size[4] Rattach tag[2] qid[13]
    public func attach(fid: UInt32, afid: UInt32 = NineP.noFid, uname: String, aname: String = "",
                       nUname: UInt32 = NineP.noNuname) throws -> Qid {
        var e = Encoder()
        e.u32(fid)
        e.u32(afid)
        e.str(uname)
        e.str(aname)
        if dialect == .linux { e.u32(nUname) }
        var d = try rpc(.Tattach, body: e.bytes, expect: .Rattach)
        return try Qid.decode(&d)
    }

    // MARK: Twalk / Rwalk

    /// Maximum path elements in a single Twalk.
    public static let maxWalkElements = 16

    /// size[4] Twalk tag[2] fid[4] newfid[4] nwname[2] nwname*(wname[s])
    /// size[4] Rwalk tag[2] nwqid[2] nwqid*(wqid[13])
    ///
    /// Returns the qids for the elements walked. Per the protocol, a short
    /// result (fewer qids than names, and > 0 names) means the walk failed
    /// part-way and newfid was NOT established; a full result means newfid
    /// now refers to the destination. Zero names clones fid into newfid.
    public func walk(fid: UInt32, newfid: UInt32, names: [String]) throws -> [Qid] {
        guard names.count <= Client.maxWalkElements else {
            throw NinePError.protocolError("walk of \(names.count) elements exceeds \(Client.maxWalkElements)")
        }
        var e = Encoder()
        e.u32(fid)
        e.u32(newfid)
        e.u16(UInt16(names.count))
        for n in names { e.str(n) }
        var d = try rpc(.Twalk, body: e.bytes, expect: .Rwalk)
        let n = Int(try d.u16())
        guard n <= names.count else {
            throw NinePError.protocolError("Rwalk returned \(n) qids for \(names.count) names")
        }
        var qids: [Qid] = []
        for _ in 0..<n { qids.append(try Qid.decode(&d)) }
        return qids
    }

    /// Walk a slash-separated path from `fid` to `newfid`, throwing if any
    /// element fails. Paths longer than 16 elements are walked in chunks.
    @discardableResult
    public func walk(fid: UInt32, newfid: UInt32, path: String) throws -> [Qid] {
        let names = path.split(separator: "/").map(String.init).filter { $0 != "." }
        if names.isEmpty { return try walk(fid: fid, newfid: newfid, names: []) }
        var all: [Qid] = []
        var from = fid
        var i = 0
        while i < names.count {
            let chunk = Array(names[i..<min(i + Client.maxWalkElements, names.count)])
            let qids = try walk(fid: from, newfid: newfid, names: chunk)
            if qids.count != chunk.count {
                if from == newfid { try? clunkQuiet(newfid) }
                throw NinePError.server("walk: '\(names[i + qids.count])' not found")
            }
            all += qids
            from = newfid
            i += chunk.count
        }
        return all
    }

    /// Minimal Tclunk used to clean up after a failed multi-chunk walk.
    private func clunkQuiet(_ fid: UInt32) throws {
        try clunk(fid: fid)
    }

    // MARK: Topen / Ropen

    public static let OREAD: UInt8 = 0
    public static let OWRITE: UInt8 = 1
    public static let ORDWR: UInt8 = 2
    public static let OEXEC: UInt8 = 3
    public static let OTRUNC: UInt8 = 0x10
    public static let ORCLOSE: UInt8 = 0x40

    /// size[4] Topen tag[2] fid[4] mode[1]
    /// size[4] Ropen tag[2] qid[13] iounit[4]
    public func open(fid: UInt32, mode: UInt8) throws -> (qid: Qid, iounit: UInt32) {
        var e = Encoder()
        e.u32(fid)
        e.u8(mode)
        var d = try rpc(.Topen, body: e.bytes, expect: .Ropen)
        let q = try Qid.decode(&d)
        return (q, try d.u32())
    }

    /// Largest data payload for read/write on this connection.
    /// Tread/Rread/Twrite overhead is 24 bytes (header 7 + fid 4 + offset 8 + count 4 + slack).
    public func maxIO(iounit: UInt32 = 0) -> UInt32 {
        let cap = msize - 24
        return (iounit == 0 || iounit > cap) ? cap : iounit
    }

    // MARK: Tread / Rread

    /// size[4] Tread tag[2] fid[4] offset[8] count[4]
    /// size[4] Rread tag[2] count[4] data[count]
    public func read(fid: UInt32, offset: UInt64, count: UInt32) throws -> [UInt8] {
        var e = Encoder()
        e.u32(fid)
        e.u64(offset)
        e.u32(count)
        var d = try rpc(.Tread, body: e.bytes, expect: .Rread)
        let n = Int(try d.u32())
        guard n <= Int(count) else {
            throw NinePError.protocolError("Rread returned \(n) bytes, asked for \(count)")
        }
        return try d.raw(n)
    }

    /// Read from offset 0 until a zero-length Rread (EOF).
    public func readAll(fid: UInt32, iounit: UInt32 = 0) throws -> [UInt8] {
        let chunk = maxIO(iounit: iounit)
        var out: [UInt8] = []
        while true {
            let b = try read(fid: fid, offset: UInt64(out.count), count: chunk)
            if b.isEmpty { return out }
            out += b
        }
    }

    /// Read a directory fid (already opened OREAD) to EOF and decode its entries.
    public func readDir(fid: UInt32, iounit: UInt32 = 0) throws -> [Stat] {
        try Stat.decodeAll(try readAll(fid: fid, iounit: iounit))
    }

    // MARK: Twrite / Rwrite

    /// size[4] Twrite tag[2] fid[4] offset[8] count[4] data[count]
    /// size[4] Rwrite tag[2] count[4]
    public func write(fid: UInt32, offset: UInt64, data: [UInt8]) throws -> UInt32 {
        guard data.count <= Int(maxIO()) else {
            throw NinePError.protocolError("write of \(data.count) bytes exceeds msize")
        }
        var e = Encoder()
        e.u32(fid)
        e.u64(offset)
        e.u32(UInt32(data.count))
        e.raw(data)
        var d = try rpc(.Twrite, body: e.bytes, expect: .Rwrite)
        let n = try d.u32()
        guard n <= UInt32(data.count) else {
            throw NinePError.protocolError("Rwrite count \(n) exceeds \(data.count) sent")
        }
        return n
    }

    /// Write all of `data` starting at `offset`, chunking by iounit/msize.
    public func writeAll(fid: UInt32, offset: UInt64 = 0, data: [UInt8], iounit: UInt32 = 0) throws {
        let chunk = Int(maxIO(iounit: iounit))
        var off = 0
        repeat {
            let end = min(off + chunk, data.count)
            let n = try write(fid: fid, offset: offset + UInt64(off), data: Array(data[off..<end]))
            if n == 0 && end > off { throw NinePError.io("short write (0 bytes)") }
            off += Int(n)
        } while off < data.count
    }

    // MARK: Tclunk / Rclunk

    /// size[4] Tclunk tag[2] fid[4]
    /// size[4] Rclunk tag[2]
    public func clunk(fid: UInt32) throws {
        var e = Encoder()
        e.u32(fid)
        _ = try rpc(.Tclunk, body: e.bytes, expect: .Rclunk)
    }

    // MARK: Tstat / Rstat

    /// size[4] Tstat tag[2] fid[4]
    /// size[4] Rstat tag[2] stat[n]   (n[2] then the stat record, which has its own size[2])
    public func stat(fid: UInt32) throws -> Stat {
        var e = Encoder()
        e.u32(fid)
        var d = try rpc(.Tstat, body: e.bytes, expect: .Rstat)
        let n = Int(try d.u16())
        var sd = Decoder(try d.raw(n))
        return try Stat.decode(&sd)
    }

    // MARK: Twstat / Rwstat

    /// size[4] Twstat tag[2] fid[4] stat[n]
    /// size[4] Rwstat tag[2]
    /// Use `Stat.dontTouch()` and set only the fields you want changed.
    public func wstat(fid: UInt32, stat: Stat) throws {
        let rec = stat.encode()
        var e = Encoder()
        e.u32(fid)
        e.u16(UInt16(rec.count))
        e.raw(rec)
        _ = try rpc(.Twstat, body: e.bytes, expect: .Rwstat)
    }

    // MARK: Tcreate / Rcreate

    public static let DMDIR: UInt32 = 0x8000_0000
    public static let DMAPPEND: UInt32 = 0x4000_0000
    public static let DMEXCL: UInt32 = 0x2000_0000
    public static let DMTMP: UInt32 = 0x0400_0000

    /// size[4] Tcreate tag[2] fid[4] name[s] perm[4] mode[1]
    /// size[4] Rcreate tag[2] qid[13] iounit[4]
    /// On success `fid` (which must be a directory) now refers to the new, opened file.
    public func create(fid: UInt32, name: String, perm: UInt32, mode: UInt8) throws -> (qid: Qid, iounit: UInt32) {
        var e = Encoder()
        e.u32(fid)
        e.str(name)
        e.u32(perm)
        e.u8(mode)
        var d = try rpc(.Tcreate, body: e.bytes, expect: .Rcreate)
        let q = try Qid.decode(&d)
        return (q, try d.u32())
    }

    // MARK: Tremove / Rremove

    /// size[4] Tremove tag[2] fid[4]
    /// size[4] Rremove tag[2]
    /// The fid is clunked by the server whether or not the remove succeeds.
    public func remove(fid: UInt32) throws {
        var e = Encoder()
        e.u32(fid)
        _ = try rpc(.Tremove, body: e.bytes, expect: .Rremove)
    }

    // MARK: Tflush / Rflush

    /// Send a T-message without waiting for the reply; returns its tag.
    public func start(_ type: MsgType, body: [UInt8]) throws -> UInt16 {
        let t = allocTag()
        try send(type, tag: t, body: body)
        return t
    }

    /// size[4] Tflush tag[2] oldtag[2]
    /// size[4] Rflush tag[2]
    ///
    /// Abort the outstanding request `oldtag`. The server may still answer
    /// the old request before Rflush; any such reply is returned (nil if it
    /// was flushed). Rflush always arrives last.
    @discardableResult
    public func flush(oldtag: UInt16) throws -> Frame? {
        var e = Encoder()
        e.u16(oldtag)
        let t = allocTag()
        try send(.Tflush, tag: t, body: e.bytes)
        var oldReply: Frame?
        while true {
            let f = try receive()
            if f.tag == t {
                try checkError(f)
                guard f.type == MsgType.Rflush.rawValue else {
                    throw NinePError.protocolError("expected Rflush, got type \(f.type)")
                }
                return oldReply
            } else if f.tag == oldtag {
                oldReply = f
            } else {
                throw NinePError.protocolError("unexpected reply tag \(f.tag) while flushing \(oldtag)")
            }
        }
    }

    // MARK: Tauth / Rauth

    /// size[4] Tauth tag[2] afid[4] uname[s] aname[s] [n_uname[4] in 9P2000.L]
    /// size[4] Rauth tag[2] aqid[13]
    /// On success, afid is an auth file to read/write per the server's auth
    /// protocol, then pass as `afid` to `attach`.
    public func auth(afid: UInt32, uname: String, aname: String = "",
                     nUname: UInt32 = NineP.noNuname) throws -> Qid {
        var e = Encoder()
        e.u32(afid)
        e.str(uname)
        e.str(aname)
        if dialect == .linux { e.u32(nUname) }
        var d = try rpc(.Tauth, body: e.bytes, expect: .Rauth)
        return try Qid.decode(&d)
    }
}

// MARK: - 9P2000.L
//
// Linux dialect (negotiated with version "9P2000.L"). Walk, read, write,
// clunk, flush and auth/attach (with n_uname) are shared with 9P2000; the
// messages below replace Topen/Tcreate/Tstat/Twstat/directory-Tread, and
// errors arrive as Rlerror (numeric Linux errno).

/// Linux open(2) flags as carried on the wire (Linux values, not the host's).
public enum LinuxOpen {
    public static let RDONLY: UInt32    = 0o0
    public static let WRONLY: UInt32    = 0o1
    public static let RDWR: UInt32      = 0o2
    public static let CREAT: UInt32     = 0o100
    public static let EXCL: UInt32      = 0o200
    public static let TRUNC: UInt32     = 0o1000
    public static let APPEND: UInt32    = 0o2000
    public static let DIRECTORY: UInt32 = 0o200000

    /// Map a 9P2000 open mode (OREAD/OWRITE/ORDWR [| OTRUNC]) to Linux flags.
    public static func from9P(_ mode: UInt8) -> UInt32 {
        var f: UInt32
        switch mode & 3 {
        case Client.OWRITE: f = WRONLY
        case Client.ORDWR: f = RDWR
        default: f = RDONLY
        }
        if mode & Client.OTRUNC != 0 { f |= TRUNC }
        return f
    }
}

/// Linux st_mode file-type bits.
public enum LinuxMode {
    public static let IFMT: UInt32   = 0o170000
    public static let IFSOCK: UInt32 = 0o140000
    public static let IFLNK: UInt32  = 0o120000
    public static let IFREG: UInt32  = 0o100000
    public static let IFBLK: UInt32  = 0o060000
    public static let IFDIR: UInt32  = 0o040000
    public static let IFCHR: UInt32  = 0o020000
    public static let IFIFO: UInt32  = 0o010000

    /// ls(1)-style mode string, e.g. "drwxr-xr-x".
    public static func string(_ mode: UInt32) -> String {
        let t: String
        switch mode & IFMT {
        case IFDIR: t = "d"
        case IFLNK: t = "l"
        case IFCHR: t = "c"
        case IFBLK: t = "b"
        case IFIFO: t = "p"
        case IFSOCK: t = "s"
        default: t = "-"
        }
        var s = t
        let rwx: [Character] = ["r", "w", "x"]
        for shift in stride(from: 6, through: 0, by: -3) {
            let bits = (mode >> UInt32(shift)) & 7
            for (i, c) in rwx.enumerated() { s.append(bits & (4 >> UInt32(i)) != 0 ? c : "-") }
        }
        // setuid/setgid/sticky
        var chars = Array(s)
        if mode & 0o4000 != 0 { chars[3] = chars[3] == "x" ? "s" : "S" }
        if mode & 0o2000 != 0 { chars[6] = chars[6] == "x" ? "s" : "S" }
        if mode & 0o1000 != 0 { chars[9] = chars[9] == "x" ? "t" : "T" }
        return String(chars)
    }
}

/// Rgetattr result.
public struct LAttr: CustomStringConvertible {
    // request_mask / valid bits
    public static let MODE: UInt64 = 0x1, NLINK: UInt64 = 0x2, UID: UInt64 = 0x4, GID: UInt64 = 0x8
    public static let RDEV: UInt64 = 0x10, ATIME: UInt64 = 0x20, MTIME: UInt64 = 0x40, CTIME: UInt64 = 0x80
    public static let INO: UInt64 = 0x100, SIZE: UInt64 = 0x200, BLOCKS: UInt64 = 0x400
    public static let BTIME: UInt64 = 0x800, GEN: UInt64 = 0x1000, DATA_VERSION: UInt64 = 0x2000
    public static let BASIC: UInt64 = 0x7FF, ALL: UInt64 = 0x3FFF

    public var valid: UInt64
    public var qid: Qid
    public var mode: UInt32
    public var uid: UInt32
    public var gid: UInt32
    public var nlink: UInt64
    public var rdev: UInt64
    public var size: UInt64
    public var blksize: UInt64
    public var blocks: UInt64
    public var atimeSec: UInt64, atimeNsec: UInt64
    public var mtimeSec: UInt64, mtimeNsec: UInt64
    public var ctimeSec: UInt64, ctimeNsec: UInt64
    public var btimeSec: UInt64, btimeNsec: UInt64
    public var gen: UInt64
    public var dataVersion: UInt64

    public var isDir: Bool { mode & LinuxMode.IFMT == LinuxMode.IFDIR }
    public var modeString: String { LinuxMode.string(mode) }

    public static func decode(_ d: inout Decoder) throws -> LAttr {
        LAttr(valid: try d.u64(), qid: try Qid.decode(&d), mode: try d.u32(), uid: try d.u32(),
              gid: try d.u32(), nlink: try d.u64(), rdev: try d.u64(), size: try d.u64(),
              blksize: try d.u64(), blocks: try d.u64(),
              atimeSec: try d.u64(), atimeNsec: try d.u64(),
              mtimeSec: try d.u64(), mtimeNsec: try d.u64(),
              ctimeSec: try d.u64(), ctimeNsec: try d.u64(),
              btimeSec: try d.u64(), btimeNsec: try d.u64(),
              gen: try d.u64(), dataVersion: try d.u64())
    }

    public var description: String {
        "qid=\(qid) mode=\(modeString) (0\(String(mode, radix: 8))) uid=\(uid) gid=\(gid) "
        + "nlink=\(nlink) rdev=\(rdev) size=\(size) blksize=\(blksize) blocks=\(blocks) "
        + "atime=\(atimeSec).\(atimeNsec) mtime=\(mtimeSec).\(mtimeNsec) ctime=\(ctimeSec).\(ctimeNsec) "
        + "btime=\(btimeSec).\(btimeNsec) gen=\(gen) data_version=\(dataVersion) "
        + "valid=0x\(String(valid, radix: 16))"
    }
}

/// Tsetattr request. Only fields whose bit is set in `valid` are applied.
public struct LSetAttr {
    public static let MODE: UInt32 = 0x1, UID: UInt32 = 0x2, GID: UInt32 = 0x4, SIZE: UInt32 = 0x8
    public static let ATIME: UInt32 = 0x10, MTIME: UInt32 = 0x20, CTIME: UInt32 = 0x40
    public static let ATIME_SET: UInt32 = 0x80, MTIME_SET: UInt32 = 0x100

    public var valid: UInt32 = 0
    public var mode: UInt32 = 0
    public var uid: UInt32 = 0
    public var gid: UInt32 = 0
    public var size: UInt64 = 0
    public var atimeSec: UInt64 = 0, atimeNsec: UInt64 = 0
    public var mtimeSec: UInt64 = 0, mtimeNsec: UInt64 = 0

    public init() {}
}

/// One Rreaddir entry: qid[13] offset[8] type[1] name[s]
public struct Dirent: CustomStringConvertible {
    public let qid: Qid
    public let offset: UInt64     // cookie to pass as the next Treaddir offset
    public let type: UInt8        // Linux DT_* value
    public let name: String

    public var description: String { "\(name) qid=\(qid) type=\(type) offset=\(offset)" }
}

/// Rstatfs result.
public struct StatFS: CustomStringConvertible {
    public let type: UInt32, bsize: UInt32
    public let blocks: UInt64, bfree: UInt64, bavail: UInt64
    public let files: UInt64, ffree: UInt64, fsid: UInt64
    public let namelen: UInt32

    public var description: String {
        "type=0x\(String(type, radix: 16)) bsize=\(bsize) blocks=\(blocks) bfree=\(bfree) "
        + "bavail=\(bavail) files=\(files) ffree=\(ffree) fsid=\(fsid) namelen=\(namelen)"
    }
}

extension Client {
    /// size[4] Tstatfs tag[2] fid[4]
    /// size[4] Rstatfs tag[2] type[4] bsize[4] blocks[8] bfree[8] bavail[8] files[8] ffree[8] fsid[8] namelen[4]
    public func statfs(fid: UInt32) throws -> StatFS {
        var e = Encoder(); e.u32(fid)
        var d = try rpc(.Tstatfs, body: e.bytes, expect: .Rstatfs)
        return StatFS(type: try d.u32(), bsize: try d.u32(), blocks: try d.u64(), bfree: try d.u64(),
                      bavail: try d.u64(), files: try d.u64(), ffree: try d.u64(), fsid: try d.u64(),
                      namelen: try d.u32())
    }

    /// size[4] Tlopen tag[2] fid[4] flags[4]
    /// size[4] Rlopen tag[2] qid[13] iounit[4]
    public func lopen(fid: UInt32, flags: UInt32) throws -> (qid: Qid, iounit: UInt32) {
        var e = Encoder(); e.u32(fid); e.u32(flags)
        var d = try rpc(.Tlopen, body: e.bytes, expect: .Rlopen)
        let q = try Qid.decode(&d)
        return (q, try d.u32())
    }

    /// size[4] Tlcreate tag[2] fid[4] name[s] flags[4] mode[4] gid[4]
    /// size[4] Rlcreate tag[2] qid[13] iounit[4]
    /// Like Tcreate, `fid` (a directory) moves to the new, opened file.
    public func lcreate(fid: UInt32, name: String, flags: UInt32, mode: UInt32, gid: UInt32) throws -> (qid: Qid, iounit: UInt32) {
        var e = Encoder(); e.u32(fid); e.str(name); e.u32(flags); e.u32(mode); e.u32(gid)
        var d = try rpc(.Tlcreate, body: e.bytes, expect: .Rlcreate)
        let q = try Qid.decode(&d)
        return (q, try d.u32())
    }

    /// size[4] Tsymlink tag[2] fid[4] name[s] symtgt[s] gid[4]
    /// size[4] Rsymlink tag[2] qid[13]
    public func symlink(dfid: UInt32, name: String, target: String, gid: UInt32) throws -> Qid {
        var e = Encoder(); e.u32(dfid); e.str(name); e.str(target); e.u32(gid)
        var d = try rpc(.Tsymlink, body: e.bytes, expect: .Rsymlink)
        return try Qid.decode(&d)
    }

    /// size[4] Tmknod tag[2] dfid[4] name[s] mode[4] major[4] minor[4] gid[4]
    /// size[4] Rmknod tag[2] qid[13]
    public func mknod(dfid: UInt32, name: String, mode: UInt32, major: UInt32, minor: UInt32, gid: UInt32) throws -> Qid {
        var e = Encoder(); e.u32(dfid); e.str(name); e.u32(mode); e.u32(major); e.u32(minor); e.u32(gid)
        var d = try rpc(.Tmknod, body: e.bytes, expect: .Rmknod)
        return try Qid.decode(&d)
    }

    /// size[4] Trename tag[2] fid[4] dfid[4] name[s]
    /// size[4] Rrename tag[2]
    public func rename(fid: UInt32, dfid: UInt32, name: String) throws {
        var e = Encoder(); e.u32(fid); e.u32(dfid); e.str(name)
        _ = try rpc(.Trename, body: e.bytes, expect: .Rrename)
    }

    /// size[4] Treadlink tag[2] fid[4]
    /// size[4] Rreadlink tag[2] target[s]
    public func readlink(fid: UInt32) throws -> String {
        var e = Encoder(); e.u32(fid)
        var d = try rpc(.Treadlink, body: e.bytes, expect: .Rreadlink)
        return try d.str()
    }

    /// size[4] Tgetattr tag[2] fid[4] request_mask[8]
    /// size[4] Rgetattr tag[2] valid[8] qid[13] mode[4] uid[4] gid[4] nlink[8] rdev[8] size[8]
    ///   blksize[8] blocks[8] atime_sec[8] atime_nsec[8] mtime_sec[8] mtime_nsec[8]
    ///   ctime_sec[8] ctime_nsec[8] btime_sec[8] btime_nsec[8] gen[8] data_version[8]
    public func getattr(fid: UInt32, mask: UInt64 = LAttr.BASIC) throws -> LAttr {
        var e = Encoder(); e.u32(fid); e.u64(mask)
        var d = try rpc(.Tgetattr, body: e.bytes, expect: .Rgetattr)
        return try LAttr.decode(&d)
    }

    /// size[4] Tsetattr tag[2] fid[4] valid[4] mode[4] uid[4] gid[4] size[8]
    ///   atime_sec[8] atime_nsec[8] mtime_sec[8] mtime_nsec[8]
    /// size[4] Rsetattr tag[2]
    public func setattr(fid: UInt32, _ a: LSetAttr) throws {
        var e = Encoder()
        e.u32(fid); e.u32(a.valid); e.u32(a.mode); e.u32(a.uid); e.u32(a.gid); e.u64(a.size)
        e.u64(a.atimeSec); e.u64(a.atimeNsec); e.u64(a.mtimeSec); e.u64(a.mtimeNsec)
        _ = try rpc(.Tsetattr, body: e.bytes, expect: .Rsetattr)
    }

    /// size[4] Txattrwalk tag[2] fid[4] newfid[4] name[s]
    /// size[4] Rxattrwalk tag[2] size[8]
    /// newfid can then be read for the attribute value (empty name lists names).
    public func xattrwalk(fid: UInt32, newfid: UInt32, name: String) throws -> UInt64 {
        var e = Encoder(); e.u32(fid); e.u32(newfid); e.str(name)
        var d = try rpc(.Txattrwalk, body: e.bytes, expect: .Rxattrwalk)
        return try d.u64()
    }

    /// size[4] Txattrcreate tag[2] fid[4] name[s] attr_size[8] flags[4]
    /// size[4] Rxattrcreate tag[2]
    /// fid then becomes an xattr fid to Twrite the value into, then clunk.
    public func xattrcreate(fid: UInt32, name: String, size: UInt64, flags: UInt32) throws {
        var e = Encoder(); e.u32(fid); e.str(name); e.u64(size); e.u32(flags)
        _ = try rpc(.Txattrcreate, body: e.bytes, expect: .Rxattrcreate)
    }

    /// size[4] Treaddir tag[2] fid[4] offset[8] count[4]
    /// size[4] Rreaddir tag[2] count[4] data[count]   (data = packed Dirents)
    public func readdir(fid: UInt32, offset: UInt64, count: UInt32) throws -> [Dirent] {
        var e = Encoder(); e.u32(fid); e.u64(offset); e.u32(count)
        var d = try rpc(.Treaddir, body: e.bytes, expect: .Rreaddir)
        let n = Int(try d.u32())
        var dd = Decoder(try d.raw(n))
        var out: [Dirent] = []
        while dd.remaining > 0 {
            out.append(Dirent(qid: try Qid.decode(&dd), offset: try dd.u64(), type: try dd.u8(), name: try dd.str()))
        }
        return out
    }

    /// Read a directory (opened with Tlopen) to the end, following offset cookies.
    public func readdirAll(fid: UInt32, iounit: UInt32 = 0) throws -> [Dirent] {
        let chunk = maxIO(iounit: iounit)
        var all: [Dirent] = []
        var off: UInt64 = 0
        while true {
            let batch = try readdir(fid: fid, offset: off, count: chunk)
            guard let last = batch.last else { return all }
            all += batch
            off = last.offset
        }
    }

    /// size[4] Tfsync tag[2] fid[4]   (some servers add datasync[4]; we send the original form)
    /// size[4] Rfsync tag[2]
    public func fsync(fid: UInt32) throws {
        var e = Encoder(); e.u32(fid)
        _ = try rpc(.Tfsync, body: e.bytes, expect: .Rfsync)
    }

    /// size[4] Tlink tag[2] dfid[4] fid[4] name[s]
    /// size[4] Rlink tag[2]
    public func link(dfid: UInt32, fid: UInt32, name: String) throws {
        var e = Encoder(); e.u32(dfid); e.u32(fid); e.str(name)
        _ = try rpc(.Tlink, body: e.bytes, expect: .Rlink)
    }

    /// size[4] Tmkdir tag[2] dfid[4] name[s] mode[4] gid[4]
    /// size[4] Rmkdir tag[2] qid[13]
    public func mkdir(dfid: UInt32, name: String, mode: UInt32, gid: UInt32) throws -> Qid {
        var e = Encoder(); e.u32(dfid); e.str(name); e.u32(mode); e.u32(gid)
        var d = try rpc(.Tmkdir, body: e.bytes, expect: .Rmkdir)
        return try Qid.decode(&d)
    }

    /// size[4] Trenameat tag[2] olddirfid[4] oldname[s] newdirfid[4] newname[s]
    /// size[4] Rrenameat tag[2]
    public func renameat(oldDirFid: UInt32, oldName: String, newDirFid: UInt32, newName: String) throws {
        var e = Encoder(); e.u32(oldDirFid); e.str(oldName); e.u32(newDirFid); e.str(newName)
        _ = try rpc(.Trenameat, body: e.bytes, expect: .Rrenameat)
    }

    public static let AT_REMOVEDIR: UInt32 = 0x200

    /// size[4] Tunlinkat tag[2] dirfd[4] name[s] flags[4]
    /// size[4] Runlinkat tag[2]
    public func unlinkat(dirFid: UInt32, name: String, flags: UInt32 = 0) throws {
        var e = Encoder(); e.u32(dirFid); e.str(name); e.u32(flags)
        _ = try rpc(.Tunlinkat, body: e.bytes, expect: .Runlinkat)
    }
}
