// TVApp.swift — NineExplorer for tvOS.
//
// A minimal, native tvOS front end. Apple TV has full networking, so unlike
// the watch it speaks 9P itself: it is built with NineP/NineP.swift and the
// shared NineExplorer.swift (AppModel, NineService, Entry, Fmt, FileIcon …).
//
// tvOS is driven by focus and the Siri Remote, so:
//  - the connect screen is a Form (text fields open the tvOS keyboard, the
//    protocol Picker opens a native selection list);
//  - folders are a focusable List of NavigationLinks with .searchable;
//  - refresh / disconnect are buttons in the list (no pull-to-refresh or
//    toolbars on tvOS);
//  - file previews are split into focusable chunks so the remote can scroll
//    through them (plain Text is not focusable on tvOS);
//  - there is no copy/share (no pasteboard or share sheet on tvOS).

import SwiftUI

// MARK: - Connect screen

struct ConnectView: View {
    @EnvironmentObject var model: AppModel
    @State private var form: ServerForm
    @State private var recents: [Config] = Recents.load()

    init() {
        _form = State(initialValue: Recents.load().first.map { ServerForm($0) } ?? ServerForm())
    }

    var body: some View {
        Form {
            Section {
                TextField("Host (name or IP)", text: $form.host)
                    .textContentType(.URL)
                TextField("Port", text: $form.port)
                    .keyboardType(.numberPad)
            } header: {
                Text("Server")
            } footer: {
                if let p = form.problem { Text(p).foregroundStyle(.red) }
            }

            Section {
                Picker("Protocol", selection: $form.proto) {
                    ForEach(ServerForm.protocols, id: \.tag) { Text($0.label).tag($0.tag) }
                }
            } footer: {
                Text(form.protoFooter)
            }

            Section {
                TextField("User (empty = anonymous)", text: $form.uname)
                TextField("UID (optional)", text: $form.uid)
                    .keyboardType(.numberPad)
                TextField("Export (optional)", text: $form.aname)
                TextField("Max Message (65536)", text: $form.msize)
                    .keyboardType(.numberPad)
            } header: {
                Text("Account")
            } footer: {
                Text(ServerForm.accountFooter)
            }

            Section {
                Button {
                    connect()
                } label: {
                    Label("Connect", systemImage: "network")
                }
                .disabled(form.config == nil)
            }

            if !recents.isEmpty {
                Section {
                    ForEach(recents, id: \.key) { r in
                        Button { Task { await model.connect(r) } } label: {
                            HStack(spacing: 20) {
                                SymbolTile(symbol: "server.rack", color: .indigo, size: 50)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(r.endpoint)
                                    Text(r.recentSubtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .contextMenu {
                            Button("Fill In Form") { form = ServerForm(r) }
                            Button("Remove", role: .destructive) {
                                Recents.remove(r)
                                recents = Recents.load()
                            }
                        }
                    }
                } header: {
                    Text("Recent")
                } footer: {
                    Text("Press and hold a server for more options.")
                }
            }
        }
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .navigationTitle("Connect to Server")
    }

    func connect() {
        guard let c = form.config else { return }
        Task { await model.connect(c) }
    }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.status {
        case .setup:
            NavigationStack { ConnectView() }

        case .connecting:
            VStack(spacing: 30) {
                ProgressView()
                Text("Connecting to \(model.cfg.endpoint)\u{2026}").foregroundStyle(.secondary)
                Button("Cancel") { model.disconnect() }
            }

        case .failed(let msg):
            ContentUnavailableView {
                Label("Can\u{2019}t Connect", systemImage: "network.slash")
            } description: {
                Text("\(model.cfg.endpoint)\n\(msg)")
            } actions: {
                Button("Try Again") { Task { await model.connect() } }
                Button("Edit Server") { model.disconnect() }
            }

        case .connected:
            NavigationStack(path: $model.nav) {
                DirectoryView(path: ".", title: model.rootTitle)
                    .navigationDestination(for: Entry.self) { e in
                        if e.isDir {
                            DirectoryView(path: e.path, title: e.name)
                        } else {
                            FileView(entry: e)
                        }
                    }
            }
        }
    }
}

// MARK: - Directory

struct DirectoryView: View {
    @EnvironmentObject var model: AppModel
    let path: String
    let title: String

    @State private var entries: [Entry]?
    @State private var error: String?
    @State private var query = ""

    var filtered: [Entry] {
        let all = entries ?? []
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if let entries, !filtered.isEmpty {
                Section {
                    ForEach(filtered) { e in
                        NavigationLink(value: e) {
                            HStack(spacing: 24) {
                                FileIcon(entry: e, size: 56)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(e.name).lineLimit(1).truncationMode(.middle)
                                    Text(Fmt.subtitle(e)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } footer: {
                    Text(entries.count == filtered.count
                         ? model.footer(count: filtered.count)
                         : "\(filtered.count) of \(entries.count) items")
                }
            }

            Section {
                Button { Task { await load() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                if path == "." {
                    Button { model.disconnect() } label: {
                        Label("Disconnect from \(model.cfg.endpoint)", systemImage: "eject")
                    }
                }
            }
        }
        .overlay { overlay }
        .navigationTitle(title)
        .searchable(text: $query)
        .task { if entries == nil { await load() } }
    }

    @ViewBuilder var overlay: some View {
        if let error {
            ContentUnavailableView("Couldn\u{2019}t Load Folder", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if entries == nil {
            ProgressView()
        } else if entries?.isEmpty == true {
            ContentUnavailableView("Empty Folder", systemImage: "folder",
                                   description: Text("This folder has no items."))
        } else if filtered.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }

    func load() async {
        do {
            entries = try await model.list(path)
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }
}

// MARK: - File

struct FileView: View {
    @EnvironmentObject var model: AppModel
    let entry: Entry

    @State private var preview: FilePreview?
    @State private var truncated = false
    @State private var error: String?

    /// Preview split into chunks of lines, each focusable so the remote can scroll.
    var chunks: [String] {
        let s: String
        switch preview {
        case .text(let t): s = t
        case .binary(let d): s = d
        default: return []
        }
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        return stride(from: 0, to: lines.count, by: 12).map {
            lines[$0..<min($0 + 12, lines.count)].joined(separator: "\n")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            // Left: icon + information
            VStack(alignment: .leading, spacing: 18) {
                FileIcon(entry: entry, size: 140)
                Text(entry.name).font(.title2.bold()).lineLimit(3)
                Text("\(Fmt.kind(entry)) \u{00B7} \(Fmt.size(entry.size))").foregroundStyle(.secondary)
                Divider()
                ForEach(Array(Fmt.infoRows(entry).enumerated()), id: \.offset) { _, r in
                    LabeledContent(r.0) {
                        Text(r.1).font(r.2 ? .caption.monospaced() : .caption).lineLimit(2)
                    }
                    .font(.caption)
                }
            }
            .frame(width: 560)

            // Right: preview
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .focusable()
                    } else if preview == nil {
                        ProgressView()
                    } else if case .empty = preview {
                        Text("Empty file").foregroundStyle(.secondary).focusable()
                    } else {
                        ForEach(Array(chunks.enumerated()), id: \.offset) { _, c in
                            PreviewChunk(text: c, small: { if case .binary = preview { return true }; return false }())
                        }
                        if truncated {
                            Text(FilePreview.truncatedNote)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 20)
                                .focusable()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 40)
        .navigationTitle(entry.name)
        .task { if preview == nil && error == nil { await load() } }
    }

    func load() async {
        do {
            (preview, truncated) = try await model.preview(entry.path)
        } catch {
            self.error = "\(error)"
        }
    }
}

/// A focusable block of preview text; the focused block is highlighted.
struct PreviewChunk: View {
    let text: String
    var small = false
    @FocusState private var focused: Bool

    var body: some View {
        Text(text)
            .font(.system(size: small ? 20 : 24, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(focused ? Color.white.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .focusable()
            .focused($focused)
    }
}

// MARK: - App

@main
struct NineExplorerTVApp: App {
    @StateObject private var model = AppModel(cfg: Recents.load().first ?? Config(), autoConnect: false)

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
    }
}
