import SwiftUI
import AVFAudio

@main
struct HengeApp: App {
    /// Answers for external display scenes before iOS 27 (LegacyExternalDisplay.swift).
    @UIApplicationDelegateAdaptor(HengeAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Order matters: HengeLog takes over stderr, so the engine's and the JIT
        // allocator's first lines land in Documents/henge.log too.
        HengeLog.start()
        HengeLog.log("boot", "address space: \(henge_largest_reservation_gb()) GB can be reserved in one piece")
        M4Performance.prepareDiagnosticBuild()
        EngineTuning.apply()
        M4Performance.logProfile()
        HengeLog.logFootprint("app-launch")
        JITBootstrap.noteLaunchState()
        HengeLog.log("app", "increased memory limit: \(Entitlements.increasedMemory ? "yes" : "no"); extended addressing: \(Entitlements.extendedAddressing ? "yes" : "no"); process headroom at launch \(Entitlements.memoryLimitAtLaunch >> 20) MiB")
        // Without the guard, a brk no debugger answers kills the app instead of failing.
        JITBootstrap.installTrapGuard()
        AudioSessionRecovery.shared.start()
        Machines.shared.collectImports()
        // The display question: does this iOS have Apple's paravirtualized graphics at all?
        for path in ["/System/Library/Frameworks/ParavirtualizedGraphics.framework/ParavirtualizedGraphics",
                     "/System/Library/PrivateFrameworks/ParavirtualizedGraphics.framework/ParavirtualizedGraphics"] {
            HengeLog.log("app", "\(path): \(dlopen(path, RTLD_LAZY) != nil ? "present" : "absent")")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .onOpenURL { url in
                    // Callback queries can contain tokens. Log receipt without their contents.
                    HengeLog.log("app", "URL callback received; scheme=\(url.scheme ?? "?"); path/query omitted")
                } // henge:// back from LocalDevVPN
        }
    }
}

struct RootView: View {
    enum Tab: Hashable { case macs, install, settings }

    @ObservedObject private var machines = Machines.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var running: VirtualMac?
    @State private var tab = Tab.macs
    @AppStorage(DeskAppearance.key) private var appearance = DeskAppearance.system
    @AppStorage("henge.link.viewerOnly") private var viewerOnly = false

    var body: some View {
        ZStack {
            if viewerOnly {
                LinkViewerView { viewerOnly = false }
            } else {
                TabView(selection: $tab) {
                    HomeView(running: $running, tab: $tab)
                        .tabItem { Label("Macs", systemImage: "macwindow") }
                        .tag(Tab.macs)
                    InstallView()
                        .tabItem { Label("Install", systemImage: "arrow.down.circle") }
                        .tag(Tab.install)
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag(Tab.settings)
                }
                .tint(Desk.accentLight)
                if let running {
                    SessionView(mac: running) { LinkHostService.shared.stop(); self.running = nil }
                        .transition(.opacity)
                }
            }
        }
        .background(WindowStyle(style: running != nil ? .dark : appearance.style))
        .sheet(isPresented: $jit.showSetup) { JITSetupFlow() }
        .task(id: viewerOnly ? "link-viewer" : String(describing: scenePhase)) {
            guard !viewerOnly, scenePhase == .active else { return }
            machines.collectImports()
            jit.enableAtLaunchIfAsked()
            // StikDebug can launch Henge before it attaches. A task also runs
            // on the first appearance, when there may be no phase change.
            for _ in 0..<100 {
                guard !Task.isCancelled, !viewerOnly else { return }
                if JITBootstrap.prewarmed || JITBootstrap.isLive {
                    jit.objectWillChange.send()
                    return
                }
                if JITBootstrap.debuggedFlag || JITBootstrap.canGrantOwnJIT {
                    JITBootstrap.prewarm()
                    // Readiness lives outside the observable coordinator.
                    jit.objectWillChange.send()
                    return
                }
                do { try await Task.sleep(nanoseconds: 100_000_000) }
                catch { return } // going into the background cancels this wait
            }
        }
        .onChange(of: jit.attachGeneration) { _ in if !viewerOnly { JITBootstrap.prewarm() } } // the built-in helper attached
        .task { // testing only: HENGE_AUTOPILOT
            guard !viewerOnly else { return }
            await Autopilot.run { mac in
                guard !viewerOnly else { return }
                // Close a stopped session before starting the same Mac again.
                guard running != nil else { running = mac; return }
                running = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if !viewerOnly { running = mac }
                }
            }
        }
    }
}

extension View {
    /// Husk's screens are written against an iOS 15 shim; Henge needs iOS 17, so this is the real thing.
    func hengeDestination<D: Hashable, C: View>(for data: D.Type, @ViewBuilder destination: @escaping (D) -> C) -> some View {
        navigationDestination(for: data, destination: destination)
    }
}
