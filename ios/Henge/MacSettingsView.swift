import SwiftUI

/// One Mac: what it has, and what can be done with it.
struct MacSettingsView: View {
    @ObservedObject private var machines = Machines.shared
    @Environment(\.dismiss) private var dismiss
    @State private var mac: VirtualMac
    @State private var showDiskExpansion=false
    @State private var confirmDelete = false
    @State private var movingExport = false
    @State private var processHeadroom: UInt64 = 0
    @AppStorage("henge.cpus") private var cpus = 4

    init(mac: VirtualMac) { _mac = State(initialValue: mac) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                DeskHeading("Name")
                TextField("Name", text: $mac.name)
                    .font(.system(size: 16))
                    .submitLabel(.done)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 14)
                    .deskCard()
                    .onSubmit(save)

                if Device.isPad && ProcessInfo.processInfo.physicalMemory >> 20 >= 14_000 {
                    DeskHeading("Performance")
                    VStack(alignment: .leading, spacing: 12) {
                        Button(M4Performance.enabled ? "Apply M4 Automatic (Desktop Retina)" : "Apply performance settings") {
                            M4Performance.applyAutomaticDefaults()
                            cpus = 4
                            mac.ramMB = 8192
                            if M4Performance.enabled {
                                M4Performance.applyRetinaDisplay(to: &mac)
                            } else {
                                mac.desktopLayout = false
                                mac.retina = false
                                mac.fitScreen = false
                                (mac.screenWidth, mac.screenHeight) = Device.performanceScreen
                            }
                            save()
                        }
                        .font(.system(size: 16, weight: .semibold))
                        Text(M4Performance.enabled
                             ? "4 CPUs, 8 GB guest memory, automatic scheduling and sleeping CPU waits. Restricted translation reuse is automatic; broad experiments and diagnostic counters stay off. Desktop Retina uses 1280 logical points with a 2× backing; Native Retina remains selectable. Your refresh selection and code-cache choice are preserved. An optional henge-env.txt still overrides engine settings. Applies on the next Mac start."
                             : "4 CPUs, 8 GB memory and a \(Device.performanceScreen.width) × \(Device.performanceScreen.height) screen. Reduces drawing work with a softer image. Applies on the next Mac start. CPU selection applies to all Macs.")
                            .font(.system(size: 13)).foregroundStyle(Desk.dim)
                    }
                    .padding(17)
                    .deskCard()
                }

                DeskHeading("Memory")
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(mac.ramMB / 1024) GB").font(.system(size: 26, weight: .bold))
                        Spacer()
                        Text("Guest virtual memory")
                            .font(.system(size: 13)).foregroundStyle(Desk.dim).multilineTextAlignment(.trailing)
                    }
                    if UInt64(mac.ramMB) << 20 >= ProcessInfo.processInfo.physicalMemory {
                        Text("The guest's configured RAM equals or exceeds this device's physical RAM (\(ByteText.string(ProcessInfo.processInfo.physicalMemory))). iPadOS, JIT and graphics share the same memory. A larger process allowance or footprint exclusion does not add physical RAM. Use the 8 GB comparison preset after a full shutdown when testing pressure or freezing; saved sessions keep their original RAM.")
                            .font(.footnote).foregroundStyle(.orange)
                    } else if M4Performance.enabled && mac.ramMB > 8192 {
                        Text("This Mac uses more than the 8 GB comparison baseline. Excluded guest pages still use physical RAM shared with iPadOS and graphics. Compare 8 GB after shutdown if memory-pressure warnings occur; saved Macs keep their chosen RAM.")
                            .font(.footnote).foregroundStyle(.secondary).padding(.horizontal,17)
                    }
                    Stepper("Memory", value: Binding(get: { mac.ramMB / 1024 }, set: { mac.ramMB = $0 * 1024; save() }), in: Device.memoryChoices)
                        .font(.system(size: 16))
                    if let note = Device.memoryNote(mac.ramMB / 1024) {
                        Text(note).font(.system(size: 13)).foregroundStyle(Desk.dim)
                    }
                    Text("Guest RAM can be file-backed. JIT, graphics and other resident resources still need process memory headroom; physical RAM is not the app's allowance.")
                        .font(.system(size: 13)).foregroundStyle(Desk.dim)
                    if processHeadroom > 0 {
                        Text("Process headroom when opened: \(ByteText.string(processHeadroom)). This changes while Henge runs.")
                            .font(.system(size: 13)).foregroundStyle(Desk.dim)
                    }
                }
                .padding(17)
                .deskCard()

                DeskHeading("Processors")
                Stepper(value: $cpus, in: 1...M4Performance.maximumGuestCPUs) {
                    HStack {
                        Text("CPUs").font(.system(size: 16))
                        Spacer()
                        Text("\(cpus)").font(.system(size: 16, weight: .semibold))
                    }
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 10)
                .deskCard()

                if Device.fittingScreen.height != 1080 {
                    DeskHeading("Screen")
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Screen", selection: Binding(get: {
                            if mac.desktopLayout == true { return mac.desktopMetalFX == true ? "desktopFX" : "desktop" }
                            if mac.isRetina { return "retina" }
                            if mac.fitsDeviceScreen { return "fit" }
                            if mac.screen.width == Device.performanceScreen.width,
                               mac.screen.height == Device.performanceScreen.height { return "performance" }
                            if mac.screen.width == 1920, mac.screen.height == 1080 { return "wide" }
                            return "fit"
                        }, set: { choice in
                            mac.desktopLayout = choice == "desktop" || choice == "desktopFX"
                            mac.desktopMetalFX = choice == "desktopFX"
                            mac.retina = choice == "retina" || choice == "desktop"
                            mac.fitScreen = choice == "fit"
                            switch choice {
                            case "retina", "desktop", "desktopFX": break
                            case "performance": (mac.screenWidth, mac.screenHeight) = Device.performanceScreen
                            case "wide": (mac.screenWidth, mac.screenHeight) = (1920, 1080)
                            default: (mac.screenWidth, mac.screenHeight) = Device.fitting(for: mac)
                            }
                            save()
                        })) {
                            Text("Desktop Retina").tag("desktop")
                            if Device.supportsDesktopMetalFX || mac.desktopMetalFX == true {
                                Text("Desktop MetalFX · experimental").tag("desktopFX")
                            }
                            if Device.isPad {
                                Text("Native Retina").tag("retina")
                                Text("Performance").tag("performance")
                            }
                            Text("Fit this \(Device.name)").tag("fit")
                            Text("16:9").tag("wide")
                        }
                        .pickerStyle(.menu)
                        if mac.desktopLayout == true {
                            if mac.desktopMetalFX == true {
                                Text("Same default desktop workspace as Desktop Retina: 1280 points across. Render at 1× and reconstruct a 2× output (iPad 2560 × 1920) using MetalFX with Metal 4. This reduces source pixels by 75%, not all emulation work. Text may look softer. No macOS scaling change is needed at the default resolution. Requires a full macOS shutdown and fresh start; saved sessions keep their original mode. Native Retina is used on unsupported hardware or the Compatibility backend.")
                                    .font(.system(size: 13)).foregroundStyle(Desk.dim)
                            } else {
                                Text("Like the mirrored Mac layout: 1280 points across with a sharp 2× backing. The iPad keeps its panel's proportions when Henge's window changes; Duo uses its current screen. Fit follows the window instead. Native Retina remains available for every panel pixel. A saved Mac keeps its original display: shut down macOS and start again to apply this layout.")
                                .font(.system(size: 13)).foregroundStyle(Desk.dim)
                            }
                        }
                        if Device.largeScreen {
                            Toggle("Fill the whole screen", isOn: Binding(get: { mac.fillScreen ?? true }, set: { value in
                                mac.fillScreen = value
                                save()
                            }))
                            Text("Off leaves room beside the Mac for the status bar and controls. Fit adapts to the current Duo screen when the Mac starts.")
                                .font(.system(size: 13)).foregroundStyle(Desk.dim)
                        }
                        Text("\(mac.screen.width) × \(mac.screen.height). \(Device.isPad ? "Performance reduces pixel work at the cost of sharpness. " : "")Changes apply the next time this Mac starts.")
                            .font(.system(size: 13)).foregroundStyle(Desk.dim)
                    }
                    .padding(17)
                    .deskCard()
                    // A Mac fitted to another screen (an iPhone Duo's other one) shows the size it will start with.
                    .onAppear { mac = machines.fittedForStart(mac) }
                }

                DeskHeading("Storage")
                VStack(spacing: 11) {
                    HStack {
                        Text("\(ByteText.string(UInt64(max(mac.bytesUsed, 0)))) used").font(.system(size: 16))
                        Spacer()
                        Text("of \(ByteText.string(UInt64(max(mac.diskBytes, 0))))").font(.system(size: 16)).foregroundStyle(Desk.dim)
                    }
                    DeskBar(fraction: Double(mac.bytesUsed) / Double(max(mac.diskBytes, 1)))
                    Button("Expand disk capacity…",systemImage:"externaldrive.badge.plus") { showDiskExpansion=true }
                }
                .padding(17)
                .deskCard()

                DeskHeading("Manage")
                manage
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .deskColumn()
        }
        .background(Desk.page)
        .navigationTitle(mac.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { processHeadroom = UInt64(henge_available_memory()) }
        .onDisappear(perform: save)
        .fileMover(isPresented: $movingExport, file: machines.lastExport) { result in
            switch result {
            case .success: machines.lastExport = nil
            case .failure(let error): machines.lastError = error.localizedDescription
            }
        }
        .sheet(isPresented:$showDiskExpansion) { DiskExpansionView(mac:mac) { updated in mac=updated } }
        .confirmationDialog("Delete \(mac.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                machines.delete(mac.id)
                dismiss()
            }
        } message: {
            Text("Its disk is removed from this \(Device.name).")
        }
    }

    private var manage: some View {
        VStack(spacing: 0) {
            if let name = machines.exporting {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Exporting \(name)… keep Henge open").font(.system(size: 15))
                    DeskBar(fraction: machines.exported)
                }
                .padding(17)
            } else {
                row("Export", symbol: "square.and.arrow.up", tint: Desk.accentLight) { machines.export(mac) }
            }
            if let folder = machines.lastExport {
                divider
                VStack(alignment: .leading, spacing: 8) {
                    Text("Saved in Files, under Henge, Exports, \(folder.lastPathComponent). Deleting Henge deletes it too, so move it somewhere else first.")
                        .font(.system(size: 13)).foregroundStyle(Desk.dim)
                    Button("Move Out of Henge…") { movingExport = true }
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight)
                }
                .padding(17)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            divider
            row("Delete this Mac", symbol: nil, tint: Desk.bad) { confirmDelete = true }
        }
        .deskCard()
    }

    private var divider: some View { Rectangle().fill(Desk.hairline).frame(height: 0.5) }

    private func row(_ title: String, symbol: String?, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 16)).foregroundStyle(tint)
                Spacer()
                if let symbol { Image(systemName: symbol).foregroundStyle(tint) }
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
    }

    private func save() {
        if mac.name.isEmpty { mac.name = "Mac" }
        machines.update(mac)
    }
}
