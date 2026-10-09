// WatchApp.swift — NineExplorer for watchOS.
//
// A thin view onto the iPhone app: the watch never speaks 9P. It asks the
// iPhone (WatchConnectivity sendMessage) to connect, list folders and preview
// files, and shows the iPhone's current server and recents from the
// application context. Shared types (Entry, Fmt, FileIcon, Config,
// WatchProto) come from NineExplorer.swift; NineP.swift is not built in.
//
// LIMITATIONS
//
// Connectivity
//  - Requires the iPhone app. There is no 9P code on the watch, and the app is
//    not independent (WKRunsIndependentlyOfCompanionApp = false), so it needs
//    the companion iPhone app installed.
//  - Works only while the iPhone is reachable (WCSession.isReachable: nearby
//    over Bluetooth or on the same Wi-Fi). Otherwise every screen shows
//    "Open NineExplorer on your iPhone" and nothing loads.
//  - Uses only live request/reply messages (sendMessage). Nothing is queued
//    for later delivery (no transferUserInfo or background transfers), and
//    nothing is cached. Every folder or file opened is fetched again from
//    the iPhone, and there is no offline browsing.
//  - Time limits: a watch request may wake the iPhone app in the background,
//    which then has only a short time to answer. NineService gives up
//    connecting after 5 s and on any single read/write after 15 s. If the
//    reply takes longer than WatchConnectivity allows, the watch shows the
//    timeout error.
//  - Large 9P2000.L folders are slow: the iPhone does one walk + Tgetattr per
//    entry, so big folders or slow servers can exceed that time limit.
//
// Shared session
//  - The watch borrows the iPhone's single 9P session. Opening a server on
//    the watch connects the iPhone app to that server too, which resets the
//    iPhone's navigation back to the root.
//  - If the iPhone is switched to another server while the watch is
//    browsing, the watch's next request switches the iPhone back (every
//    request carries the server the watch is browsing).
//
// Servers
//  - The server list on the watch comes from the iPhone: its recent servers
//    (at most 6) plus the server it is connected to. Servers cannot be added,
//    edited, removed or reordered on the watch, and there is no option to
//    type in an address.
//  - The list is pushed with updateApplicationContext only when the iPhone's
//    connection status changes. Removing a recent server on the iPhone does
//    not reach the watch until the next connect or disconnect.
//  - No authentication (Tauth) and no per-server credentials beyond the
//    user name / uid saved with the recent entry.
//
// Browsing
//  - Read-only: browse folders and preview files. No writing, creating,
//    renaming, deleting or changing permissions.
//  - Folder listings are cut to fit WatchConnectivity's message size limit:
//    the encoded entries are capped at WatchProto.maxEntriesBytes (40 KB,
//    roughly 500-600 entries). Entries past that are dropped and the folder
//    says "Showing N of M". There is no paging, and the search, sorting and
//    refresh controls of the iPhone app are not available.
//  - Entries carry only name, path, kind, size, modification time and the
//    executable bit (Entry.forWatch). Permissions, owner, group and qid are
//    not shown on the watch.
//  - Symbolic links are shown as files (with their target). A link to a
//    folder cannot be followed; opening it shows the iPhone's error.
//
// Previews
//  - Only the first 2 KB of a file (WatchProto.previewLimit) is fetched and
//    shown, as plain monospaced text, with a "Preview truncated" note.
//  - Binary files just say "Binary file" (no hex dump), and images, PDFs and
//    other rich formats are not rendered. Text cannot be copied or shared
//    from the watch.
//
// Errors
//  - Errors from the iPhone or the 9P server are shown as the raw message
//    text, e.g. "server error: ENOENT: no such file or directory (errno 2)".

import SwiftUI
import WatchConnectivity

// MARK: - Link to the iPhone

enum LinkError: LocalizedError {
    case unreachable
    case phone(String)

    var errorDescription: String? {
        switch self {
        case .unreachable: return "Open NineExplorer on your iPhone."
        case .phone(let s): return s
        }
    }
}

@MainActor
final class PhoneLink: NSObject, ObservableObject, WCSessionDelegate {
    @Published var activated = false
    @Published var reachable = false
    @Published var context = WatchProto.Context()
    /// The server being browsed; sent with every request so a freshly woken
    /// iPhone can reconnect to it.
    @Published var server: Config?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
    }

    private func refresh(_ s: WCSession) {
        activated = s.activationState == .activated
        reachable = s.isReachable
        if !s.receivedApplicationContext.isEmpty {
            context = WatchProto.Context(s.receivedApplicationContext)
        }
    }

    /// Request/reply round trip to the iPhone.
    func send(_ req: WatchProto.Request) async throws -> WatchProto.Reply {
        let s = WCSession.default
        guard s.activationState == .activated, s.isReachable else { throw LinkError.unreachable }
        let reply: WatchProto.Reply = try await withCheckedThrowingContinuation { cont in
            s.sendMessage(req.dict, replyHandler: { d in
                cont.resume(returning: WatchProto.Reply(d))
            }, errorHandler: { e in
                cont.resume(throwing: e)
            })
        }
        if let e = reply.error { throw LinkError.phone(e) }
        return reply
    }

    func connect(_ c: Config) async throws -> String {
        let r = try await send(.init(op: .connect, server: c))
        server = c
        return r.title ?? c.host
    }

    func list(_ path: String) async throws -> WatchProto.Reply {
        try await send(.init(op: .list, path: path, server: server))
    }

    func preview(_ path: String) async throws -> WatchProto.Reply {
        try await send(.init(op: .preview, path: path, server: server))
    }

    // MARK: WCSessionDelegate (called off the main thread)

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in self.refresh(session) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.refresh(session) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let ctx = WatchProto.Context(applicationContext)
        Task { @MainActor in self.context = ctx }
    }
}

// MARK: - Views

struct OpenPhoneView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Open NineExplorer on your iPhone", systemImage: "iphone")
        } description: {
            Text("The watch browses 9P servers through your iPhone.")
        }
    }
}

struct ServersView: View {
    @EnvironmentObject var link: PhoneLink
    @Binding var path: [Entry]
    @State private var connecting: String?
    @State private var error: String?

    var body: some View {
        Group {
            if !link.reachable {
                OpenPhoneView()
            } else if link.context.recents.isEmpty && link.context.server == nil {
                ContentUnavailableView("No Servers", systemImage: "server.rack",
                                       description: Text("Connect to a server on your iPhone first."))
            } else {
                List {
                    if let cur = link.context.server, link.context.status == "connected" {
                        Section("iPhone") {
                            serverRow(cur, title: link.context.title, subtitle: link.context.version)
                        }
                    }
                    Section("Servers") {
                        ForEach(link.context.recents, id: \.key) { c in
                            serverRow(c, title: c.endpoint, subtitle: c.recentSubtitle)
                        }
                    }
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle("9P")
    }

    func serverRow(_ c: Config, title: String, subtitle: String) -> some View {
        Button {
            Task { await open(c) }
        } label: {
            HStack(spacing: 8) {
                SymbolTile(symbol: "server.rack", color: .indigo, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if connecting == c.key { ProgressView().frame(width: 18) }
            }
        }
        .disabled(connecting != nil)
    }

    func open(_ c: Config) async {
        connecting = c.key
        error = nil
        defer { connecting = nil }
        do {
            let title = try await link.connect(c)
            path = [Entry.root(title: title)]
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct DirectoryView: View {
    @EnvironmentObject var link: PhoneLink
    let entry: Entry

    @State private var entries: [Entry]?
    @State private var total = 0
    @State private var error: Error?

    var body: some View {
        Group {
            if let error {
                if case LinkError.unreachable = error {
                    OpenPhoneView()
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow)
                            Text(error.localizedDescription).font(.footnote).multilineTextAlignment(.center)
                            Button("Retry") { Task { await load() } }
                        }
                    }
                }
            } else if let entries {
                if entries.isEmpty {
                    ContentUnavailableView("Empty Folder", systemImage: "folder")
                } else {
                    List {
                        ForEach(entries) { e in
                            NavigationLink(value: e) {
                                HStack(spacing: 8) {
                                    FileIcon(entry: e, size: 24)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(e.name).lineLimit(1).truncationMode(.middle)
                                        Text(Fmt.subtitle(e)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                        if total > entries.count {
                            Text("Showing \(entries.count) of \(total). Open the folder on your iPhone for the rest.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(entry.name)
        .task { if entries == nil { await load() } }
    }

    func load() async {
        error = nil
        do {
            let r = try await link.list(entry.path)
            entries = r.entries ?? []
            total = r.total
        } catch {
            self.error = error
        }
    }
}

struct FileView: View {
    @EnvironmentObject var link: PhoneLink
    let entry: Entry

    @State private var reply: WatchProto.Reply?
    @State private var error: Error?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    FileIcon(entry: entry, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.name).font(.headline).lineLimit(2)
                        Text("\(Fmt.kind(entry)) \u{00B7} \(Fmt.size(entry.size))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(Fmt.long(entry.mtime)).font(.caption2).foregroundStyle(.secondary)
                Divider()
                preview
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(entry.name)
        .task { if reply == nil && error == nil { await load() } }
    }

    @ViewBuilder var preview: some View {
        if let error {
            if case LinkError.unreachable = error {
                Label("Open NineExplorer on your iPhone", systemImage: "iphone").font(.footnote)
            } else {
                Text(error.localizedDescription).font(.footnote).foregroundStyle(.red)
            }
        } else if let reply {
            if reply.binary {
                Text("Binary file").foregroundStyle(.secondary)
            } else if let t = reply.text, !t.isEmpty {
                Text(t).font(.system(.footnote, design: .monospaced))
                if reply.truncated {
                    Text("Preview truncated.").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("Empty file").foregroundStyle(.secondary)
            }
        } else {
            ProgressView()
        }
    }

    func load() async {
        do { reply = try await link.preview(entry.path) } catch { self.error = error }
    }
}

struct WatchRootView: View {
    @State private var path: [Entry] = []

    var body: some View {
        NavigationStack(path: $path) {
            ServersView(path: $path)
                .navigationDestination(for: Entry.self) { e in
                    if e.isDir { DirectoryView(entry: e) } else { FileView(entry: e) }
                }
        }
    }
}

// MARK: - App

@main
struct NineExplorerWatchApp: App {
    @StateObject private var link = PhoneLink()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(link)
        }
    }
}
