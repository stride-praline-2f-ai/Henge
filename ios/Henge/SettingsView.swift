import SwiftUI

struct SettingsView: View {
    @ObservedObject private var jit = JITCoordinator.shared
    @AppStorage(JITCoordinator.autoEnableKey) private var jitAtLaunch = false
    @AppStorage(Sharing.enabledKey) private var guestSharing = true
    @AppStorage(HardwareMouse.speedKey) private var mouseSpeed = 1.0
    @AppStorage(HardwareMouse.reverseKey) private var reverseScrolling = false
    @AppStorage(PhysicalMouseButtons.swapKey) private var swapMouseButtons = false
    @AppStorage(Trackpad.scrollSpeedKey) private var trackpadScroll = Trackpad.defaultScrollSpeed
    @AppStorage(HardwareMouse.scrollSpeedKey) private var scrollSpeed = HardwareScroll.defaultSpeed
    @AppStorage(M4Performance.statisticsKey) private var sessionDiagnostics = M4Performance.statisticsEnabled
    @AppStorage(EngineTuning.fastmemKey) private var fastmem = true
    @AppStorage(EngineTuning.graphicsBackendKey) private var graphicsBackend = "automatic"
    @AppStorage(VolumeClicks.inputModeKey) private var inputMode = VolumeClicks.InputMode.touchscreen
    @AppStorage(VolumeClicks.modeKey) private var volumeMode = VolumeClicks.Mode.delayHold
    @AppStorage(VolumeClicks.swapKey) private var swapButtons = false
    @AppStorage(EngineTuning.refreshKey) private var refreshRate = 60
    @AppStorage(EngineTuning.fastFlushKey) private var fastFlush = true
    @AppStorage(JITBootstrap.codeCacheKey) private var codeCacheMB = JITBootstrap.defaultCodeCacheMB
    @AppStorage(DeskAppearance.key) private var appearance = DeskAppearance.system
    @AppStorage(InstantResume.key) private var instantResume = true
    @AppStorage(MacAppsFeature.key) private var macApps = false

    /// The second footer paragraph: how you click, given the selected input mode.
    private var inputDescription: String {
        if inputMode == .touchscreen {
            return "Tap to click once. Tap then hold to begin dragging. Quickly tap with two fingers to right-click."
        }
        switch volumeMode {
        case .delayHold:
            return "Delay hold waits to see if you're holding or just clicking the volume button, which results in all clicks being ~0.5s long."
        case .tapThenDrag:
            return "Tap then drag waits to see if you're holding or just clicking the volume button, but it unconditionally sends a single click regardless of whether you tap or hold, which results in shorter clicks at the cost of sending a click before holding."
        case .intercept:
            return "Activates the camera in order to intercept volume keys properly. This causes the volume keys to behave in the same way a mouse's buttons do, but it causes higher temperatures, as the camera is always on."
        }
    }

    @AppStorage("henge.perf.thermalProtection") private var thermalProtection = false
    @AppStorage("henge.perf.lowPowerAware") private var lowPowerAware = true
    @AppStorage(EngineTuning.lowPowerGuestRefreshKey) private var lowPowerGuestRefresh = true
    @AppStorage("henge.perf.presentationCap") private var presentationCap = 0
    @State private var memoryHeadroom: UInt64 = 0
    @State private var guestMemory = HengeGuestMemoryStatus()

    private var guestMemoryDescription: String {
        if guestMemory.state == -1 { return "Changing session state" }
        guard guestMemory.bytes > 0 else { return "No active Mac" }
        let size = ByteText.string(guestMemory.bytes)
        switch guestMemory.backing {
        case 1: return "\(size) · kernel footprint exclusion active"
        case 2: return "\(size) · file-backed"
        case 3: return "\(size) · anonymous (counts toward allowance)"
        default: return "\(size) · allocation status unavailable"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("JIT") {
                    LabeledContent("Status", value: JITBootstrap.ready ? "On" : "Off")
                    Picker("Method", selection: $jit.method) {
                        ForEach(JITMethod.allCases) { Text($0.title).tag($0) }
                    }
                    Text(jit.method == .automatic ? jit.automaticDescription : "Henge uses \(jit.method.title).")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Set up JIT") { jit.showSetup = true }
                    Toggle("Turn on JIT when Henge opens", isOn: $jitAtLaunch)
                    if jitAtLaunch {
                        Text("Henge connects LocalDevVPN first when it is off, and comes back.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    LabeledContent("Code region", value: "\(JITBootstrap.jitBytes >> 20) MB, claimed once per launch")
                }
                .listRowBackground(Desk.card)
                Section("Memory") {
                    LabeledContent("Device physical RAM", value: ByteText.string(ProcessInfo.processInfo.physicalMemory))
                    LabeledContent("Extra memory", value: Entitlements.increasedMemory ? "On" : "Off")
                    LabeledContent("Process headroom at launch", value: ByteText.string(UInt64(Entitlements.memoryLimitAtLaunch)))
                    LabeledContent("Process headroom when opened", value: ByteText.string(memoryHeadroom))
                    LabeledContent("Guest RAM allocation", value: guestMemoryDescription)
                    Text("iOS controls the process allowance; it can differ between iPhone and iPad. A 6 GB allowance can coexist with a larger guest using kernel footprint exclusion or file backing. JIT, graphics and other resources still need headroom, and all resident pages use real device memory. These figures do not grant unlimited RAM.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                .onAppear {
                    memoryHeadroom = UInt64(henge_available_memory())
                    henge_vm_guest_memory(&guestMemory)
                }
                Section("On-screen trackpad") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Scroll speed")
                        Slider(value: $trackpadScroll, in: 0.05...1)
                        Button("Reset on-screen scroll speed") { trackpadScroll = Trackpad.defaultScrollSpeed }
                    }
                    Text("How far two fingers scroll the Mac. Applies straight away.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                if Device.isPad {
                    Section("Mouse and Trackpad") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Pointer speed")
                            Slider(value: $mouseSpeed, in: 0.5...3)
                        }
                        Toggle("Reverse scrolling", isOn: $reverseScrolling)
                        Toggle("Swap physical right and middle buttons", isOn: $swapMouseButtons)
                        Text("Only enable if those physical buttons are reversed. Touch controls are unchanged. Applies when a new Mac session starts.")
                            .font(.footnote).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent("Magic Keyboard / mouse scroll speed", value: String(format: "%.2f×", scrollSpeed))
                            Slider(value: $scrollSpeed, in: HardwareScroll.minimumSpeed...HardwareScroll.maximumSpeed)
                            Button("Reset hardware scroll speed") { scrollSpeed = HardwareScroll.defaultSpeed }
                        }
                        Text("A Magic Keyboard or a Bluetooth mouse moves the Mac's pointer. Pointer speed changes apply the next time a Mac starts; scroll speed changes apply immediately.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .listRowBackground(Desk.card)
                }
                if !Device.isPad {
                    Section("Trackpad") {
                        Picker("Input mode", selection: $inputMode) {
                            Text("Touchscreen").tag(VolumeClicks.InputMode.touchscreen)
                            Text("Volume buttons").tag(VolumeClicks.InputMode.volumeButtons)
                        }
                        .pickerStyle(.menu)
                        if inputMode == .volumeButtons {
                            Picker("Button mode", selection: $volumeMode) {
                                Text("Delay hold").tag(VolumeClicks.Mode.delayHold)
                                Text("Tap then drag").tag(VolumeClicks.Mode.tapThenDrag)
                                Text("Camera intercept").tag(VolumeClicks.Mode.intercept)
                            }
                            .pickerStyle(.menu)
                            Toggle("Swap buttons", isOn: $swapButtons)
                        }
                        Text("Henge is able to emulate a Magic Trackpad, allowing you to perform native macOS gestures using your device's touchscreen.\n\n\(inputDescription)")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .listRowBackground(Desk.card)
                }
                Section("Performance") {
                    Picker("Graphics backend", selection: $graphicsBackend) {
                        Text("Metal 4 preferred").tag("automatic")
                        Text("Compatibility").tag("compatibility")
                    }
                    Text("Metal 4 preferred sends supported render, compute and copy work to Metal 4 on a capable GPU. A command that needs compatibility keeps that encoder on the established Metal path, without diverting unrelated encoders. Both choices use the GPU; macOS instruction and memory translation run on the CPU. Compatibility is available if a game renders incorrectly. Applies when the Mac starts again.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if M4Performance.enabled {
                        Text("M4 Automatic · 10-core / 16 GB").font(.headline)
                        Text("The default baseline is 4 guest CPUs and 8 GB guest RAM. Retina and 60/120 Hz remain your choices. The app’s memory permission and current headroom are separate from the iPad’s 16 GB.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Toggle("Session diagnostics", isOn: $sessionDiagnostics)
                    Text("Logs the entire session: CPU hot-code samples, translation/fastmem counters, JIT recycling, disk waits, GPU timing, frame pacing and touch/Pencil delivery. Adds overhead. Restart the Mac after changing this to apply engine instrumentation. The test build enables it once; you can turn it off. The capture button remains available for a short sample.")
                        .font(.footnote).foregroundStyle(.secondary)
                    LabeledContent("Host chip", value: HostScheduling.chip)
                    LabeledContent("Host CPU layout", value: HostScheduling.layout)
                    Text("\(HostScheduling.model) · \(HostScheduling.layoutSource). iOS decides which physical core runs a thread.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Automatic scheduling keeps guest CPUs responsive while nonurgent host maintenance uses utility priority. The operating system chooses physical cores; adding guest CPUs can increase emulation overhead.")
                        .font(.footnote).foregroundStyle(.secondary)
                    NavigationLink { settingsPage("Display & power") { displayControls } } label: {
                        Label("Display & power", systemImage: "display")
                    }
                    NavigationLink { settingsPage("Engine & memory") { engineControls } } label: {
                        Label("Engine & memory", systemImage: "cpu")
                    }
                    Text("Your display quality and engine options are kept on separate pages. Changes marked for the next session apply when the Mac starts again.")
                        .font(.footnote).foregroundStyle(.secondary)

                }
                .listRowBackground(Desk.card)
                Section("Guest sharing") {
                    Toggle("Shared folder and automatic clipboard", isOn: $guestSharing)
                    Text("Allows the Mac to access Henge's Shared folder and send its clipboard to the iPad. Turn off to keep them separate. Quit and reopen Henge to apply. Explicit Paste still types the text you choose. Update an older Mac sharing companion from Details → Sharing to remove its obsolete Runner worker.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section("Instant Resume") {
                    Toggle("Save automatically when leaving", isOn: $instantResume)
                    Text("Pauses macOS when Henge becomes inactive and tries to save while iOS allows background time. Returning cancels an unfinished save and resumes in memory. Use Save Mac & Leave from the three-finger menu and keep Henge visible to finish a persistent save. Saved sessions retain their original CPU, memory and display configuration. iOS can interrupt background saving; only a completed compatible save survives the app closing. Turning this off stops future automatic saves; existing saved sessions are still restored.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section("Mac Apps") {
                    Toggle("Mac apps without macOS", isOn: $macApps)
                    Text("Bring in a .dmg or an .app (the + button on Home) and run it inside Henge through its own translation layer, without starting a Mac. Some compatible command-line programs can run, one per app launch. This is not a complete macOS environment: Xcode and the GitHub Actions runner are not supported through this layer yet. Experimental.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(DeskAppearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("System follows the \(Device.name)'s Light or Dark setting. Henge stays dark while a Mac is running.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section("Log") {
                    ShareLink(items: HengeLog.diagnosticFileURLs) { Label("Share diagnostic logs", systemImage: "square.and.arrow.up") }
                    Text("Includes this launch, the previous launch and available native/profile logs. After a crash, the previous files contain the Mac session; the new startup log alone does not. iOS termination reports remain in Settings → Privacy & Security → Analytics & Improvements → Analytics Data.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
            }
            .scrollContentBackground(.hidden)
            .background(Desk.page)
            .navigationTitle("Settings")
        }
    }
    private func settingsPage<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Form { Section { content() }.listRowBackground(Desk.card) }
            .scrollContentBackground(.hidden).background(Desk.page).navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
    private var displayControls: some View {
        Group {
                    Picker("Mac refresh rate", selection: $refreshRate) {
                        Text("30 Hz").tag(30)
                        Text("60 Hz").tag(60)
                        Text("120 Hz").tag(120)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Thermal display protection", isOn: $thermalProtection)
                    Toggle("Match Low Power Mode", isOn: $lowPowerAware)
                    Toggle("60 Hz Mac in Low Power Mode (next start)",isOn:$lowPowerGuestRefresh)
                    Text("Optional: when Low Power Mode is on at startup, a requested 120 Hz Mac starts at 60 Hz to avoid guest animation work that the display cannot show. Turn Low Power Mode off and restart to restore 120 Hz. This is an explicit refresh trade-off, never a Retina resolution reduction.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Aligns display presentation with the system’s 60 Hz Low Power Mode limit. Turning Low Power Mode off restores your selected presentation policy. Retina, guest CPU count and the saved 60/120 Hz Mac preference stay unchanged.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker("Presentation limit", selection: $presentationCap) {
                        Text("Automatic").tag(0)
                        Text("60 fps").tag(60)
                        Text("30 fps").tag(30)
                    }
                    Text("Presentation limit and thermal protection are optional and off by default. Both preserve Retina. Thermal protection limits presentation to 30 fps when hot and 20 fps in critical heat. This reduces display compositing; the guest may still render faster. Choose a 30 Hz Mac refresh rate before restarting to also reduce guest animation work. Presentation and thermal changes are applied through notifications.")
                        .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var engineControls: some View {
        Group {
                    Toggle("Ordered disk writes", isOn: $fastFlush)
                    Text("On: preserves write ordering without waiting for a full storage sync, improving write latency. Off: uses full sync for stronger power-loss durability. Applies to the next Mac session.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle("Kernel read cache", isOn: $fastmem)
                    Text("Checks a larger permission-validated cache only when the normal translation cache misses. Helps repeated kernel reads when translations collide; uses additional memory. Existing on/off choices are kept. Applies to the next Mac session; per-access counting stays off.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker("Code cache", selection: $codeCacheMB) {
                        Text("512 MB").tag(512)
                        Text("1 GB").tag(1024)
                        Text("1.5 GB").tag(1536)
                    }
                    Text("A larger code region keeps more translations and uses more memory (about 1.75 times its size). Henge chooses a size from its process memory limit. Oldest segments are recycled when possible, with full reset as a fallback. Guest CPU translations are not saved between app launches. Applies the next time Henge opens. If JIT stops turning on, or a Mac closes Henge during setup, choose a smaller one.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Event-driven CPU waits, indexed translation reuse, segmented code-cache recycling and direct Metal presentation are automatic. Experimental engine overrides remain available through henge-env.txt.")
                        .font(.footnote).foregroundStyle(.secondary)        }
    }

}
