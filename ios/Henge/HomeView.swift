import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Your Mac as you left it, and one big button.
struct HomeView: View {
    @ObservedObject private var machines = Machines.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @ObservedObject private var installer = Installer.shared
    @Binding var running: VirtualMac?
    @Binding var tab: RootView.Tab
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [VirtualMac] = []
    @AppStorage(InstantResume.key) private var automaticSave = true
    @State private var picking = false
    @State private var showingLink = false
    @AppStorage("henge.link.viewerOnly") private var viewerOnly = false
    @AppStorage("henge.link.controlsOnly") private var controlsOnly = false
    @State private var jitReady = JITBootstrap.ready
    @State private var chosen: UUID?
    @State private var showMacApps = false
    @AppStorage(MacAppsFeature.key) private var macApps = false

    /// The Mac on show: the one picked, or the one used last.
    private var mac: VirtualMac? {
        if let chosen, let mac = machines.all.first(where: { $0.id == chosen }) { return mac }
        return machines.all.max { ($0.lastUsed ?? $0.added) < ($1.lastUsed ?? $1.added) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 20) {
                        notices
                        OpeningDashboard(wide: geometry.size.width >= 900) {
                            if let mac {
                                MacHero(mac: mac, jitReady: jitReady,
                                    start: { running = Machines.shared.fittedForStart(mac) },
                                    turnOnJIT: { jit.enable() }, configure: { path.append(mac) },
                                    jitNote: jitReady ? nil : (JITBootstrap.lastFailure ?? jit.automaticDescription))
                            } else { firstMac }
                        } connections: {
                            VStack(spacing: 20) {
                                WorkspaceConnections(canExtend: mac != nil && jitReady,
                                    controls: { connect(controls: true) }, display: { connect(controls: false) },
                                    extend: { showingLink = true })
                                if mac != nil {
                                    AutomaticSaveCard(enabled: $automaticSave)
                                }
                                if let mac {
                                    HStack(spacing: 12) {
                                        FactTile(title: "Disk used", value: ByteText.string(UInt64(max(mac.bytesUsed, 0))))
                                        FactTile(title: "Last opened", value: mac.lastUsedText)
                                    }
                                }
                            }
                        }
                        if let mac { others(besides: mac) }
                    }
                    .padding(geometry.size.width >= 900 ? 28 : 18)
                    .frame(maxWidth: 1176).frame(maxWidth: .infinity)
                }
            }
            .background(Desk.page)
            .navigationTitle("Henge")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: VirtualMac.self) { MacSettingsView(mac: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Install macOS…") { tab = .install }
                        Button("Bring in a Mac from a computer…") { picking = true }
                        if macApps { Button("Mac Apps…") { showMacApps = true } }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add a Mac")
                }
            }
            .sheet(isPresented: $showingLink) {
                if let mac { LinkHostView { running = mac } }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                if case let .success(url) = result { machines.importFolder(url) }
            }
            .sheet(isPresented: $showMacApps) { MacAppsView() }
            .task(id: scenePhase == .active && running == nil) {
                guard scenePhase == .active, running == nil else { return }
                repeat {
                    jitReady = JITBootstrap.ready
                    if jitReady { return }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                } while !Task.isCancelled
            }
        }
    }

    private func connect(controls: Bool) {
        LinkHostService.shared.stop(); jit.showSetup = false
        controlsOnly = controls; viewerOnly = true
    }

    @ViewBuilder private var notices: some View {
        if Device.chipTooOld {
            NoticeRow(symbol: "exclamationmark.triangle.fill", text: Device.chipTooOldText, tint: Desk.bad)
        }
        if installer.busy {
            Button { tab = .install } label: {
                NoticeRow(symbol: "arrow.down.circle.fill", text: "Installing \(installer.machineName)…", trailing: "See")
            }
        }
        if let name = machines.importing {
            NoticeRow(symbol: "square.and.arrow.down.fill",
                      text: machines.unpacked > 0 ? String(format: "Unpacking %@'s disk… %.0f%%", name, machines.unpacked * 100) : "Bringing in \(name)…")
        }
        if let error = machines.lastError {
            NoticeRow(symbol: "exclamationmark.triangle.fill", text: error, tint: Desk.bad)
        }
    }

    private var firstMac: some View {
        VStack(spacing: 14) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Desk.accentLight)
                .frame(maxWidth: .infinity)
                .frame(height: 190)
                .background(Desk.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text("No Mac yet").font(.system(size: 24, weight: .bold))
            Text("Install macOS on this \(Device.name), or bring in a Mac made on a computer.")
                .font(.system(size: 15)).foregroundStyle(Desk.dim).multilineTextAlignment(.center)
            Button("Install macOS") { tab = .install }.buttonStyle(DeskButtonStyle())
            Button("Bring in a Mac") { picking = true }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight)
        }
        .padding(14)
        .deskCard(radius: 30)
    }

    @ViewBuilder private func others(besides shown: VirtualMac) -> some View {
        let rest = machines.all.filter { $0.id != shown.id }
        if !rest.isEmpty {
            DeskHeading("Other Macs")
            VStack(spacing: 0) {
                ForEach(rest) { other in
                    Button { chosen = other.id } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(other.name).font(.system(size: 16, weight: .medium)).foregroundStyle(Desk.text)
                                Text(other.summary).font(.system(size: 13)).foregroundStyle(Desk.dim)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Desk.faint)
                        }
                        .padding(.horizontal, 17)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    if other.id != rest.last?.id { Rectangle().fill(Desk.hairline).frame(height: 0.5) }
                }
            }
            .deskCard()
        }
    }
}

extension VirtualMac {
    var bytesUsed: Int64 {
        Int64((try? disk.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
    }

    var lastUsedText: String {
        guard let lastUsed else { return "Never" }
        if Calendar.current.isDateInToday(lastUsed) { return "Today" }
        if Calendar.current.isDateInYesterday(lastUsed) { return "Yesterday" }
        return lastUsed.formatted(.dateTime.month(.abbreviated).day())
    }

    var summary: String {
        var parts: [String] = []
        if let osName { parts.append(osName) }
        parts.append("\(ramMB / 1024) GB")
        return parts.joined(separator: " · ")
    }
}

/// The picture of the Mac, its name, and Start.
private struct MacHero: View {
    let mac: VirtualMac
    let jitReady: Bool
    let start: () -> Void
    let turnOnJIT: () -> Void
    let configure: () -> Void
    let jitNote: String?
    @AppStorage("henge.cpus") private var cpus = 4
    @ObservedObject private var resumeStatus = InstantResumeStatus.shared
    @State private var previewImage: UIImage?
    private var inMemory: Bool {
        InstantResume.runtime.configuration(macID:mac.id,generation:henge_vm_generation(),state:henge_vm_state()) != nil
    }
    var body: some View {
        MacLaunchCard(name: mac.name, summary: "\(mac.summary) · \(cpus) CPUs",
            ready: jitReady || inMemory, saved: InstantResume.hasSave(for: mac), inMemory: inMemory, preview: previewImage,
            setupNote: jitNote, start: start, setup: turnOnJIT, configure: configure)
        .task(id: mac.lastUsed) {
            let path = MacPreview.file(for: mac).path
            let image = await Task.detached(priority: .utility) { UIImage(contentsOfFile: path) }.value
            if !Task.isCancelled { previewImage = image }
        }
    }
}

private struct FactTile: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13)).foregroundStyle(Desk.dim)
            Text(value).font(.system(size: 21, weight: .bold)).foregroundStyle(Desk.text).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .deskCard()
    }
}

struct NoticeRow: View {
    let symbol: String
    let text: String
    var trailing: String?
    var tint: Color = Desk.accentLight

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.system(size: 15)).foregroundStyle(Desk.text).multilineTextAlignment(.leading)
            Spacer(minLength: 4)
            if let trailing { Text(trailing).font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight) }
        }
        .padding(14)
        .deskCard()
    }
}
