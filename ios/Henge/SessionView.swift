import SwiftUI
import GameController

/// A running Mac. Upright, its screen sits above a trackpad; on its side the screen fills the device
/// and is its own trackpad. Zoomed in, the screen fills the device either way and follows the pointer.
/// A keyboard, trackpad or mouse attached to an iPad works throughout.
struct SessionView: View {
    let mac: VirtualMac
    let close: () -> Void

    @StateObject private var display = DisplayRouter()
    @State private var showGamepad = false
    @State private var showGamepadSettings = false
    @State private var showWirelessControls = false
    @StateObject private var diagnosticCapture = SessionDiagnosticCapture()
    @AppStorage(M4Performance.statisticsKey) private var sessionDiagnostics = M4Performance.statisticsEnabled
    @ObservedObject private var clipboardStatus = ClipboardStatus.shared
    @ObservedObject private var resumeStatus = InstantResumeStatus.shared
    @State private var bootConfiguration: ResumeConfiguration?
    @State private var bootGeneration: UInt64 = 0
    @State private var viewRevision: UInt64 = 0
    @State private var booting = false
    @State private var manualSaving = false
    @State private var error: String?
    @State private var state: Int32 = 0
    @State private var bootAttempt = 0
    @State private var cpusOn: Int32 = 0
    @State private var userCode = false
    @State private var blocksPerSecond: Double = 0
    @State private var statistics = SessionStatistics()
    @State private var framesOut: UInt64 = 0
    @State private var framesIn: UInt64 = 0
    @State private var log: [String] = []
    @State private var started = Date()
    @State private var runningScreen: GuestScreenSize?
    @State private var thermalState = ProcessInfo.processInfo.thermalState
    @State private var wakeups = SessionWakeups()
    @AppStorage("henge.cpus") private var cpus = 4
    @AppStorage("henge.matchScreenColors") private var matchScreenColors = true
    @AppStorage("henge.display.brightness") private var screenBrightness = 1.0
    @AppStorage("henge.cursor.scale") private var cursorScale = 0
    @AppStorage("henge.cursor.sharp") private var sharpCursor = true
    @AppStorage(HardwareMouse.scrollSpeedKey) private var scrollSpeed = HardwareScroll.defaultSpeed

    @State private var typing = false
    @State private var zoomed = false
    @State private var showDetails = false
    @State private var controlsHidden = false
    @State private var hiddenOnLargeScreen = false // which of an iPhone Duo's two screens they were hidden on
    @State private var showRevealHint = false
    @State private var pointerRefused = false
    @AppStorage("henge.controls.hintsShown") private var revealHintsShown = 0
    @AppStorage(VolumeClicks.inputModeKey) private var inputMode = VolumeClicks.InputMode.touchscreen
    @AppStorage(VolumeClicks.modeKey) private var volumeMode = VolumeClicks.Mode.delayHold
    /// Once per install: macOS's moving wallpapers and aerial screen saver are video, decoded by the emulated
    /// CPUs (a phone ran about 30% faster with a still one).
    @AppStorage("henge.tips.stillWallpaperShown") private var stillWallpaperTipShown = false
    @State private var showWallpaperTip = false
    @State private var confirmStop = false
    @State private var confirmDiscardSave = false
    @State private var bootMac: VirtualMac?
    @State private var zoomCentre = CGPoint(x: 0.5, y: 0.5) // where the zoomed view is, 0...1 of the Mac's screen
    @State private var map: UIImage?
    @State private var zoomFollowing: Task<Void, Never>?
    @State private var nativeTouch = NativeTouchSession()
    @State private var helperRunning = false
    @State private var shown = CGSize(width: 0.5, height: 0.5) // how much of the Mac's screen the zoomed view shows
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let full = CGSize(width: geo.size.width + insets.leading + insets.trailing,
                              height: geo.size.height + insets.top + insets.bottom)
            let landscape = full.width > full.height
            let layout = Layout(full: full, insets: insets, landscape: landscape, zoomed: zoomed, typing: typing, centre: zoomCentre, aspect: displayAspect,
                                strip: Device.largeScreen && !(mac.fillScreen ?? true) ? Device.sideStrip : 0)
            ZStack(alignment: .topLeading) {
                (landscape || zoomed ? Color.black : Desk.page)
                // One view in every layout: it holds the layer the engine draws into.
                BootDisplay(display: display, role: .device)
                    .opacity(display.isExternal ? 0 : 1)
                    .overlay {
                        if display.isExternal && state != 2 {
                            VStack(spacing: 8) {
                                Image(systemName: "display").font(.largeTitle)
                                Text("Mac on external display").font(.headline)
                                Text("Use the trackpad, keyboard or a connected mouse.")
                                    .font(.subheadline)
                            }
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding()
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .frame(width: layout.screen.width, height: layout.screen.height)
                    .clipShape(RoundedRectangle(cornerRadius: layout.fillsPhone ? 0 : 15, style: .continuous))
                    .overlay {
                        if !layout.fillsPhone {
                            RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 0.5)
                        }
                    }
                    .position(x: layout.screen.midX, y: layout.screen.midY)
                if state != 2 {
                Group {
                    if nativeTouch.requested && Sharing.enabledForSession && !display.isExternal {
                        NativeTouchSurface(imageRect: layout.screen.offsetBy(dx: -layout.touch.minX, dy: -layout.touch.minY),
                                           revealsControls: controlsHidden, acceptsInput: nativeTouch.ready && !pointerNeeded && scenePhase == .active)
                            .overlay(alignment: .top) {
                                if !nativeTouch.ready {
                                    Text("Touchscreen connecting · Details → Touch input")
                                        .font(.caption).padding(8).background(.ultraThinMaterial, in: Capsule())
                                        .padding(.top, 8).allowsHitTesting(false)
                                }
                            }
                    } else {
                        Trackpad()
                    }
                }
                .frame(width: layout.touch.width, height: layout.touch.height)
                .position(x: layout.touch.midX, y: layout.touch.midY)
                    if inputMode == .volumeButtons && volumeMode == .intercept {
                        // The capture interaction must live in the SwiftUI hierarchy to receive
                        // the volume-button events; it passes touches through to the trackpad.
                        CaptureInteractionView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                    }
                    if !layout.fillsPhone {
                        uprightControls(layout)
                    } else {
                        floatingControls(layout)
                    }
                    if pointerRefused && !showRevealHint {
                        Label("Make Henge full screen to use the trackpad or mouse as the Mac's", systemImage: "cursorarrow.rays")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .deskGlass(in: Capsule())
                            .position(x: full.width / 2, y: insets.top + 40)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                    if showRevealHint {
                        Label("Tap with three fingers to show the controls", systemImage: "hand.tap")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .deskGlass(in: Capsule())
                            .position(x: full.width / 2, y: insets.top + 40)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                    if showWallpaperTip && !showRevealHint && !pointerRefused {
                        Label("For more speed, give this Mac a still wallpaper and set its screen saver to Never in System Settings.", systemImage: "speedometer")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: min(full.width - 40, 520))
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .deskGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .position(x: full.width / 2, y: insets.top + 56)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
                if state == 2 {
                    StoppedMacView(outcome: henge_vm_exit_outcome(), reason: String(cString: henge_vm_exit_reason()),
                                   start: { bootAttempt += 1 }, close: close)
                        .frame(width: min(layout.touch.width - 32, 360))
                        .position(x: layout.touch.midX, y: layout.fillsPhone ? layout.touch.midY : layout.pad.midY)
                }
                if let error { errorCard(error, layout) }
                KeyboardCatcher(active: $typing).frame(width: 0, height: 0)
            }
            .frame(width: full.width, height: full.height)
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.25), value: zoomed)
            .animation(.easeInOut(duration: 0.25), value: typing)
            .animation(.easeInOut(duration: 0.25), value: controlsHidden)
            .animation(.easeInOut(duration: 0.25), value: showRevealHint)
            .animation(.easeInOut(duration: 0.25), value: showWallpaperTip)
            .onReceive(NotificationCenter.default.publisher(for: UIPointerLockState.didChangeNotification)) { _ in
                pointerRefused = PointerLock.refused
            }
            .onReceive(NotificationCenter.default.publisher(for: .GCMouseDidConnect)) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { pointerRefused = PointerLock.refused }
            }
            .onReceive(NotificationCenter.default.publisher(for: Trackpad.threeFingerTap)) { _ in
                controlsHidden = false
                showRevealHint = false
            }
            .onAppear {
                shown = layout.shown
                HengeLog.log("session", "layout: \(Int(full.width))x\(Int(full.height)) points, insets top \(Int(insets.top)) left \(Int(insets.leading)) "
                             + "bottom \(Int(insets.bottom)) right \(Int(insets.trailing)), Mac at \(Int(layout.screen.minX)),\(Int(layout.screen.minY)) "
                             + "\(Int(layout.screen.width))x\(Int(layout.screen.height)), fill \(mac.fillScreen ?? true)")
            }
            .onChange(of: layout.shown) { shown = $0 }
            .task(id: bootAttempt) { await run(viewport: full) }
        }
        // An iPhone's large screen (iPhone Duo unfolded: regular both ways) keeps its status bar on its side too,
        // over the Mac's menu bar extras: a Mac that fills the screen hides it, one with a side strip has it there.
        .statusBarHidden(zoomed || Device.isPad || (onLargeScreen && (mac.fillScreen ?? true)))
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showDetails) { details }
        .confirmationDialog("Shut down \(mac.name)?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Shut Down", role: .destructive) { finish() }
        } message: {
            Text("This turns the Mac off at once. Anything not saved on it is lost.")
        }
        .confirmationDialog("Discard saved Mac state?", isPresented: $confirmDiscardSave, titleVisibility: .visible) {
            Button("Discard State and Start Fresh", role: .destructive) {
                if InstantResume.discard(for:mac) { bootAttempt += 1 }
                else { error = "The saved state could not be removed. Your Mac’s disk is kept." }
            }
        } message: {
            Text("This loses unsaved work in the saved memory. The Mac’s disk is kept.")
        }
        .onChange(of: zoomed) { on in
            updateZoomFollowing()
        }
        .onChange(of: display.isExternal) { _, external in
            if external { nativeTouch.stop() }; updateZoomFollowing()
        }
        .onChange(of: nativeTouch.requested) { _, _ in nativeTouch.changedRequest() }
        .onChange(of: pointerNeeded) { needed in
            PointerLock.set(!needed && LocalPointerInput.ownership.owner == .hardware)
            HardwareMouse.shared.setAcceptsInput(!needed && scenePhase == .active)
            if needed { LocalPointerInput.cancel() }
        }
        .onChange(of: scenePhase) { phase in
            guard InstantResume.runtime.ownsView(viewRevision) else { return }
            Sharing.setClipboardActive(phase == .active)
            diagnosticCapture.event("scene=\(phase)")
            wakeups.signal()
            updateZoomFollowing()
            HardwareMouse.shared.setAcceptsInput(phase == .active && !pointerNeeded)
            guard phase != .active else {
                display.refresh()
                InstantResume.cameBack(mac)
                return
            }
            nativeTouch.stop()
            GamepadHub.shared.releaseAll()
            HardwareKeys.releaseAll()
            HardwareMouse.shared.releaseButtons()
            VolumeClicks.shared.releaseButtons()
            do {
                if phase == .inactive { InstantResume.pause(force: false) }
                if phase == .background {
                    InstantResume.pause(force: false)
                    if let bootConfiguration { InstantResume.suspend(bootMac ?? mac,configuration:bootConfiguration) }
                }
            }
        }
        .interactiveDismissDisabled(booting || manualSaving)
        .disabled(booting)
        .overlay {
            if booting {
                VStack(spacing:12) {
                    ProgressView()
                    Text(InstantResume.hasSave(for:mac) ? "Restoring saved Mac…" : "Starting Mac…").font(.headline)
                    Text("Keep Henge visible while the Mac’s memory and devices are prepared.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(24).frame(maxWidth:390).background(Desk.raised,in:RoundedRectangle(cornerRadius:22)).padding(20)
            }
        }
        .onChange(of:resumeStatus.phase) { _,phase in
            if phase == .running { manualSaving=false }
            wakeups.signal();updateZoomFollowing()
        }
        .overlay {
            if scenePhase == .active && !booting && (manualSaving || (state == 4 && resumeStatus.generation == henge_vm_generation())) {
                resumeCard
            }
        }
        .onChange(of: state) { _ in
            diagnosticCapture.event("vm_state=\(state)")
            updateZoomFollowing()
            if state != 1 { GamepadHub.shared.releaseAll(); showGamepad = false }
        }
        .overlay(alignment: .bottom) {
            if showGamepad && state == 1 && scenePhase == .active {
                LocalGamepad().padding(.horizontal,8)
            }
        }
        .sheet(isPresented: $showWirelessControls) { WirelessControlsHostView() }
        .sheet(isPresented:$showGamepadSettings) { GamepadSettings() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            diagnosticCapture.event("memory_warning"); wakeups.signal()
            var allocation=HengeGuestMemoryStatus()
            henge_vm_guest_memory(&allocation)
            HengeLog.log("memory","System pressure warning; actual_guest_bytes=\(allocation.bytes) memory_state=\(allocation.state) requested_guest_mib=\(mac.ramMB). Process headroom excludes some guest pages; physical memory remains shared. Compare the 8 GiB baseline after shutdown; no live RAM change.")
            henge_vm_trim_memory()
            LinkHostService.shared.trimMemory()
            HengeLog.logFootprint("memory-warning")
        }
        .onReceive(NotificationCenter.default.publisher(for: SessionNativeEvents.changed)) { _ in
            wakeups.signal(); LinkHostService.shared.resumeVideoIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            diagnosticCapture.event("low_power=\(ProcessInfo.processInfo.isLowPowerModeEnabled)"); wakeups.signal()
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            let next = ProcessInfo.processInfo.thermalState
            if thermalState != next {
                thermalState = next
                diagnosticCapture.event("thermal=\(next.rawValue)")
                wakeups.signal()
                HengeLog.log("session", "thermal state: \(Self.thermalLabel(next))")
            }
        }
        .onChange(of: showDetails) { showing in
            wakeups.signal()
            if showing {
                refreshDetails()
                HardwareKeys.releaseAll(); StickyKeys.shared.releaseAll()
            }
        }
        .onChange(of: confirmStop) { showing in
            if showing { HardwareKeys.releaseAll(); StickyKeys.shared.releaseAll() }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            if sessionDiagnostics { diagnosticCapture.begin(continuous:true) }
            Sharing.startFollowingClipboard()
            HardwareMouse.shared.start()
            VolumeClicks.shared.start()
        }
        .onChange(of: sessionDiagnostics) { _, enabled in
            if enabled { diagnosticCapture.begin(continuous:true) }
            else if diagnosticCapture.continuous { diagnosticCapture.stop() }
            wakeups.signal()
        }
        .onDisappear {
            diagnosticCapture.stop();zoomFollowing?.cancel()
            guard InstantResume.runtime.releaseView(viewRevision) else { return }
            Sharing.stopFollowingClipboard();LinkHostService.shared.stop();nativeTouch.stop()
            GamepadHub.shared.releaseAll();StickyKeys.shared.releaseAll();HardwareKeys.releaseAll()
            HardwareMouse.shared.stop();VolumeClicks.shared.stop()
            UIApplication.shared.isIdleTimerDisabled=false
            if bootGeneration>0,henge_vm_generation()==bootGeneration,henge_vm_state()==1 {
                InstantResume.pause(force:true,generation:bootGeneration)
            }
        }
        .modifier(ExternalMacDisplayModifier(presentation: MacPresentation(display: display, aspect: displayAspect)))
        .task(id: nativeTouchPolling) {
            guard nativeTouchPolling, !Task.isCancelled else { return }
            let pollingID = nativeTouch.beginPolling()
            defer { nativeTouch.endPolling(pollingID) }
            while !Task.isCancelled {
                nativeTouch.poll(active: true, helperRunning: Sharing.helperRunning)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// When there is something of the app's to point at, iPadOS gets its own pointer back.
    private var pointerNeeded: Bool { booting || manualSaving || resumeStatus.busy || state == 2 || showDetails || confirmStop || error != nil }
    private var nativeTouchPolling: Bool {
        nativeTouch.requested && Sharing.enabledForSession && state == 1 && scenePhase == .active
            && !display.isExternal
    }

    // A fold/rotation after boot must fit the mode the guest actually received,
    // rather than stretch it by recalculating only the host view's aspect.
    private var displayAspect: CGFloat { runningScreen?.aspect ?? mac.aspect }

    // MARK: Layout

    /// Where everything goes, in points from the device's top left corner.
    private struct Layout {
        let screen: CGRect
        let touch: CGRect     // what is a trackpad besides the pad itself
        let fillsPhone: Bool
        let toolsY: CGFloat
        let pad: CGRect
        let insets: EdgeInsets
        var barY: CGFloat?    // where the controls go in the space beside the screen, if it has room for them
        var sideX: CGFloat?   // where they go as a column, in the strip a Mac leaves at the right of a large screen

        var shown: CGSize {
            CGSize(width: min(touch.width / max(screen.width, 1), 1), height: min(touch.height / max(screen.height, 1), 1))
        }

        init(full: CGSize, insets: EdgeInsets, landscape: Bool, zoomed: Bool, typing: Bool, centre: CGPoint, aspect: CGFloat, strip: CGFloat) {
            self.insets = insets
            let big = full.height >= 600 // an iPad on its side, or a window on one
            if zoomed {
                // Upright, as tall as the device. On its side, bigger than it fits: a big screen needs less.
                let height = landscape ? full.height * (big ? 1.5 : 2) : max(full.height - insets.bottom, full.width / aspect)
                let width = height * aspect
                let x = min(0, max(full.width - width, full.width / 2 - centre.x * width))
                let y = min(0, max(full.height - height, full.height / 2 - centre.y * height))
                screen = CGRect(x: x, y: y, width: width, height: height)
                touch = CGRect(origin: .zero, size: full)
                fillsPhone = true
                toolsY = 0
                pad = .zero
            } else if landscape, big {
                // Room to keep the controls off the Mac's menu bar, and the Mac above the on-screen keyboard.
                let bar: CGFloat = 62
                let room = typing ? full.height - insets.bottom - insets.top - bar - 8 : full.height
                // An iPad keeps clear of its side insets; a big iPhone (iPhone Duo) fills edge to edge.
                let side = Device.isPad ? 2 * max(insets.leading, insets.trailing) : 0
                // The strip at the right, for the status bar's column and the controls (not while typing: the
                // keyboard covers most of it, and the controls go back above the Mac).
                let strip = typing ? 0 : strip
                let height = max(min(room, (full.width - side - strip) / aspect), 200)
                let width = height * aspect
                let y = typing ? insets.top + bar : (full.height - height) / 2
                screen = CGRect(x: (full.width - strip - width) / 2, y: y, width: width, height: height)
                touch = CGRect(origin: .zero, size: full)
                fillsPhone = true
                toolsY = 0
                pad = .zero
                if strip > 0 {
                    sideX = full.width - Device.sideStripCentre
                } else if y - insets.top >= 54 {
                    barY = insets.top + (y - insets.top) / 2
                }
            } else if landscape {
                // Edge to edge. Phones wider than the Mac fill the height with room to spare beside the
                // Dynamic Island; a squarer phone (iPhone Duo) fills all of it, island and corners included.
                let height = min(full.height, full.width / aspect)
                let width = height * aspect
                screen = CGRect(x: (full.width - width) / 2, y: (full.height - height) / 2, width: width, height: height)
                touch = CGRect(origin: .zero, size: full)
                fillsPhone = true
                toolsY = 0
                pad = .zero
            } else {
                let width = full.width - 16
                let height = width / aspect
                screen = CGRect(x: 8, y: insets.top + 6, width: width, height: height)
                touch = screen
                fillsPhone = false
                toolsY = screen.maxY + 10
                let top = typing ? screen.maxY + 8 : toolsY + 54 + 10
                let bottom = full.height - insets.bottom - (typing ? 8 : 0)
                pad = CGRect(x: 8, y: top, width: width, height: max(bottom - top, 60))
            }
        }
    }

    // MARK: Upright

    @ViewBuilder private func uprightControls(_ layout: Layout) -> some View {
        if !typing && !controlsAreHidden {
            HStack {
                tool("eye.slash", "Hide controls") { hideControls() }
                Spacer()
                tool("keyboard", "Keyboard") { typing = true }
                Spacer()
                pasteTool
                Spacer()
                tool("plus.magnifyingglass", "Zoom in") { zoomed = true }
                Spacer()
                tool("info.circle", "Details") { showDetails = true }
                Spacer()
                tool("power", "Shut down", tint: Desk.bad) { stopTapped() }
            }
            .padding(.horizontal, 22)
            .frame(width: layout.pad.width, height: 54)
            .background(Desk.card, in: Capsule())
            .overlay(Capsule().stroke(Desk.hairline, lineWidth: 0.5))
            .position(x: layout.pad.midX, y: layout.toolsY + 27)
            .transition(.opacity)
        }
        trackpadPanel(layout)
    }

    private func trackpadPanel(_ layout: Layout) -> some View {
        let compact = layout.pad.height < 260
        return VStack(spacing: 0) {
            ZStack {
                Trackpad()
                if compact {
                    Text("Trackpad").font(.system(size: 14)).foregroundStyle(Desk.faint).allowsHitTesting(false)
                } else {
                    VStack(spacing: 6) {
                        hint("Drag", "to move")
                        hint("Tap", "to click")
                        hint("Hold, then drag", "to grab")
                        hint("Two fingers", "to scroll")
                    }
                    .allowsHitTesting(false)
                }
            }
            Rectangle().fill(Desk.hairline).frame(height: 0.5)
            HStack(spacing: 0) {
                MouseButton(title: "Click", button: 0)
                Rectangle().fill(Desk.hairline).frame(width: 0.5)
                MouseButton(title: "Right-click", button: 1)
            }
            .frame(height: compact ? 50 : 70)
        }
        .background(Desk.card)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Desk.hairline, lineWidth: 0.5))
        .frame(width: layout.pad.width, height: layout.pad.height)
        .position(x: layout.pad.midX, y: layout.pad.midY)
    }

    private func hint(_ strong: String, _ rest: String) -> some View {
        (Text(strong).foregroundColor(Desk.dim).fontWeight(.semibold) + Text(" \(rest)").foregroundColor(Desk.faint))
            .font(.system(size: 15))
    }

    /// The system's paste button: iOS asks no permission for it, as it would if the app read the clipboard itself.
    private var pasteTool: some View {
        PasteButton(payloadType: String.self) { texts in
            if let text = texts.first { Sharing.paste(text) }
        }
        .labelStyle(.iconOnly)
        .buttonBorderShape(.circle)
        .tint(Desk.raised)
        .disabled(clipboardStatus.busy || booting || manualSaving || state != 1)
        .overlay { if clipboardStatus.busy { ProgressView().allowsHitTesting(false) } }
        .accessibilityLabel(clipboardStatus.busy ? "Sending clipboard to Mac" : "Paste text into Mac")
    }

    /// An iPhone's large screen: an iPhone Duo unfolded, regular both ways.
    private var onLargeScreen: Bool { Device.largeScreen }

    /// Hidden controls stay hidden on the screen they were hidden on: folding an iPhone Duo moves the Mac to its
    /// other screen, where they are back (and hidden again when it is unfolded).
    private var controlsAreHidden: Bool { controlsHidden && hiddenOnLargeScreen == onLargeScreen }

    /// Hides the session's controls; four fingers on the screen bring them back. The first few times say so.
    private func hideControls() {
        controlsHidden = true
        hiddenOnLargeScreen = onLargeScreen
        typing = false
        guard revealHintsShown < 3 else { return }
        revealHintsShown += 1
        showRevealHint = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { showRevealHint = false }
    }

    private func tool(_ symbol: String, _ label: String, tint: Color = Desk.text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    // MARK: Filling the phone

    @ViewBuilder private func floatingControls(_ layout: Layout) -> some View {
        let landscape = layout.touch.width > layout.touch.height
        let top = layout.insets.top + (landscape ? 8 : 6)
        let pill = HStack(spacing: 4) {
            tool("eye.slash", "Hide controls", tint: .white) { hideControls() }
            floatingTools
            Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1, height: 22).padding(.horizontal, 4)
            tool("power", "Shut down", tint: Desk.bad) { stopTapped() }
        }
        .padding(.horizontal, 8)
        .frame(height: 50)
        .deskGlass(in: Capsule())
        if let sideX = layout.sideX {
            // A column under the status bar's own, in the strip the Mac leaves. It is not over the Mac, so it
            // has no button to hide it and is there whatever that button did before.
            let room = layout.touch.height - Device.sideStripTop
            VStack(spacing: 4) {
                floatingTools
                Rectangle().fill(Color.white.opacity(0.3)).frame(width: 22, height: 1).padding(.vertical, 4)
                tool("power", "Shut down", tint: Desk.bad) { stopTapped() }
            }
            .padding(.vertical, 8)
            .frame(width: 50)
            .deskGlass(in: Capsule())
            .frame(width: 50, height: room, alignment: .top)
            .position(x: sideX, y: Device.sideStripTop + room / 2)
        } else if controlsAreHidden {
            EmptyView()
        } else if let barY = layout.barY {
            pill.position(x: layout.touch.midX, y: barY)
        } else if landscape || typing {
            pill.position(x: layout.touch.midX, y: top + 25)
        } else {
            pill.position(x: layout.touch.midX, y: layout.touch.height - layout.insets.bottom - 34)
        }
        if zoomed { zoomMap(layout) }
    }

    /// The controls a column has too.
    @ViewBuilder private var floatingTools: some View {
        tool("keyboard", "Keyboard", tint: .white) { typing.toggle() }
        Menu {
            Section("Session") {
                if bootConfiguration != nil {
                    Button("Save Mac & Leave",systemImage:"pause.circle") { saveAndLeave() }.disabled(booting || manualSaving)
                }
                Button("Recover sound",systemImage:"speaker.wave.2") { AudioSessionRecovery.shared.recover() }
            }
            Section("Controls") {
                Button(showGamepad ? "Hide Virtual Gamepad" : "Show Virtual Gamepad",systemImage:"gamecontroller") { showGamepad.toggle() }
                Button("Gamepad Settings",systemImage:"slider.horizontal.3") { showGamepadSettings = true }
                Button("Wireless Keyboard / Gamepad",systemImage:"antenna.radiowaves.left.and.right") { showWirelessControls = true }
            }
            Section("Diagnostics") {
                Button(diagnosticCapture.active ? "Stop Diagnostic Capture" : "Capture Diagnostics (30 seconds)",systemImage:"waveform.path.ecg") {
                    if diagnosticCapture.active {
                        if diagnosticCapture.continuous { sessionDiagnostics=false }
                        diagnosticCapture.stop()
                    } else { diagnosticCapture.begin() }
                    wakeups.signal()
                }
            }
        } label: {
            Image(systemName:"gamecontroller").font(.system(size:19,weight:.medium))
                .foregroundStyle(showGamepad || diagnosticCapture.active ? Desk.accentLight : .white)
                .frame(width:44,height:44).contentShape(Rectangle())
        }.accessibilityLabel("Gamepad, wireless controls and diagnostics")
        pasteTool
        tool(zoomed ? "minus.magnifyingglass" : "plus.magnifyingglass", zoomed ? "Zoom out" : "Zoom in", tint: zoomed ? Desk.accentLight : .white) { zoomed.toggle() }
        tool("info.circle", "Details", tint: .white) { showDetails = true }
    }

    /// The whole screen, small, with where the zoomed view is on it.
    private func zoomMap(_ layout: Layout) -> some View {
        let width: CGFloat = 112, height = width / displayAspect
        let viewW = min(layout.touch.width / layout.screen.width, 1) * width
        let viewH = min(layout.touch.height / layout.screen.height, 1) * height
        let left = (-layout.screen.minX / layout.screen.width) * width
        let top = (-layout.screen.minY / layout.screen.height) * height
        return ZStack(alignment: .topLeading) {
            Color.black
            if let map { Image(uiImage: map).resizable() }
            RoundedRectangle(cornerRadius: 3).stroke(Color.white, lineWidth: 1.5)
                .frame(width: viewW, height: viewH)
                .offset(x: left, y: top)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(3)
        .deskGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .position(x: layout.touch.width - width / 2 - 15, y: layout.insets.top + height / 2 + 20)
        .allowsHitTesting(false)
    }

    /// Keeps the pointer in view: the view moves when the pointer nears its edge.
    private func updateZoomFollowing() {
        zoomFollowing?.cancel()
        zoomFollowing = zoomed && state == 1 && scenePhase == .active && !resumeStatus.busy && !display.isExternal
            ? Task { await followPointer() } : nil
    }

    private func followPointer() async {
        var tick = 0
        while !Task.isCancelled {
            var x: Int32 = 0, y: Int32 = 0
            if henge_vm_pointer(&x, &y) == 0 {
                let size = runningScreen ?? GuestScreenSize(width: mac.screen.width, height: mac.screen.height)
                moveZoom(toward: CGPoint(x: CGFloat(x) / CGFloat(size.width), y: CGFloat(y) / CGFloat(size.height)))
            }
            if tick % 60 == 0, let image = MacPreview.capture(width: 224, height: Int(224 / displayAspect)) { map = UIImage(cgImage: image) }
            tick += 1
            try? await Task.sleep(nanoseconds: 33_000_000)
        }
    }

    private func moveZoom(toward p: CGPoint) {
        // How much of the screen the view shows, and a margin inside that.
        let shownX = shown.width, shownY = shown.height
        let reachX = shownX * 0.3, reachY = shownY * 0.3
        var c = zoomCentre
        if p.x < c.x - reachX { c.x = p.x + reachX } else if p.x > c.x + reachX { c.x = p.x - reachX }
        if p.y < c.y - reachY { c.y = p.y + reachY } else if p.y > c.y + reachY { c.y = p.y - reachY }
        c.x = min(max(c.x, shownX / 2), 1 - shownX / 2)
        c.y = min(max(c.y, shownY / 2), 1 - shownY / 2)
        guard c != zoomCentre else { return }
        withAnimation(.linear(duration: 0.08)) { zoomCentre = c }
    }

    // MARK: Status

    private var resumeCard: some View {
        VStack(spacing:14) {
            if resumeStatus.busy { ProgressView() }
            Text(resumeTitle).font(.headline)
            if resumeStatus.phase == .saving {
                let progress=resumeStatus.progress
                ProgressView(value:progress.total>0 ? Double(progress.scanned)/Double(progress.total) : 0)
                Text("\(ByteText.string(progress.scanned)) of \(ByteText.string(progress.total)) scanned")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(progress.cancelled ? "Cancelling the save…" : "Keep Henge visible until saving finishes. A completed save can survive the app closing.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if case .failed(let reason)=resumeStatus.phase {
                Text(reason).font(.footnote)
            } else if resumeStatus.phase == .saved {
                Label("Saved on this device",systemImage:"checkmark.shield.fill").foregroundStyle(Desk.good)
                Text("Your Mac can be restored after Henge closes. Continuing safely invalidates this save before the Mac runs again.").font(.footnote).foregroundStyle(.secondary)
            } else if state == 4 {
                Text("The Mac is paused in memory. Only a completed compatible save can survive Henge being closed.").font(.footnote).foregroundStyle(.secondary)
            }
            Button("Continue Mac") { manualSaving=false;InstantResume.cameBack(bootMac ?? mac) }
                .disabled(resumeStatus.phase == .closing || resumeStatus.phase == .stopping)
            if !resumeStatus.busy,bootConfiguration != nil {
                Button("Save & Leave") { saveAndLeave() }
            }
        }
        .padding(24).frame(maxWidth:390).background(Desk.raised,in:RoundedRectangle(cornerRadius:22))
        .padding(20)
    }
    private var resumeTitle: String {
        switch resumeStatus.phase {
        case .pausing: return "Pausing Mac…"
        case .saving: return "Saving Mac…"
        case .resuming: return "Returning to Mac…"
        case .closing: return "Saved — closing session…"
        case .stopping: return "Stopping Mac…"
        case .saved: return "Mac saved"
        case .failed: return "The session needs attention"
        default: return "Mac paused"
        }
    }
    private func saveAndLeave() {
        guard InstantResume.runtime.ownsView(viewRevision),let bootConfiguration,!manualSaving else { return }
        manualSaving=true
        let owner=viewRevision
        GamepadHub.shared.releaseAll(); HardwareKeys.releaseAll(); HardwareMouse.shared.releaseButtons()
        InstantResume.suspend(bootMac ?? mac,configuration:bootConfiguration,leave:true) { left in
            guard InstantResume.runtime.ownsView(owner) else { return }
            if left { endSessionUI();close() }
            else if henge_vm_generation() != bootGeneration { manualSaving=false }
        }
    }
    private func endSessionUI() {
        nativeTouch.stop(); LinkHostService.shared.stop()
        HardwareKeys.releaseAll(); HardwareMouse.shared.stop(); GamepadHub.shared.releaseAll()
        UIApplication.shared.isIdleTimerDisabled=false
    }

    private func errorCard(_ text: String, _ layout: Layout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This Mac could not start").font(.system(size: 17, weight: .semibold))
            Text(text).font(.system(size: 14)).foregroundStyle(Desk.dim)
            if InstantResume.hasSave(for: mac) {
                Button("Discard Saved State…", role: .destructive) { confirmDiscardSave = true }
            }
            Button("Close") { close() }.font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight)
        }
        .padding(18)
        .frame(width: min(layout.touch.width, 390) - 32, alignment: .leading)
        .background(Desk.raised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .position(x: (layout.fillsPhone ? layout.touch.midX : layout.pad.midX), y: layout.fillsPhone ? layout.touch.midY : layout.pad.midY)
    }

    private var phase: String {
        switch state {
        case 0: return error == nil ? "Starting…" : "Not started"
        case 1: return userCode ? "macOS is running" : "Booting"
        case 3: return "Finishing shutdown…"
        default: return "Stopped (\(String(cString: henge_vm_exit_reason())))"
        }
    }

    private func refreshDetails() {
        blocksPerSecond = statistics.blocksPerSecond
        framesOut = henge_vm_net_frames(1)
        framesIn = henge_vm_net_frames(0)
        helperRunning = Sharing.helperRunning
        // Exactly the same 30 lines that Details displays. The complete log is
        // still written independently, including while this panel is closed.
        let recent = HengeLog.recentLines(30)
        if recent != log { log = recent }
    }

    private var details: some View {
        NavigationStack {
            List {
                Section(phase) {
                    LabeledContent("CPUs on", value: "\(cpusOn) of \(bootConfiguration?.cpus ?? cpus)")
                    LabeledContent("Temperature", value: Self.thermalLabel(thermalState))
                    LabeledContent("Translated blocks", value: String(format: "%.1f M/s", blocksPerSecond / 1e6))
                    LabeledContent("Network frames", value: "\(framesOut) out, \(framesIn) in")
                    LabeledContent("Up", value: "\(Int(Date().timeIntervalSince(started))) s")
                }

                Section("Display") {
                    if let screen = runningScreen {
                        LabeledContent("Current guest pixels", value: "\(screen.width) × \(screen.height)")
                        if bootConfiguration?.presentationScale == 2 {
                            LabeledContent("MetalFX output target", value: "\(screen.width * 2) × \(screen.height * 2)")
                            Text("Reconstructed desktop, same logical workspace as Desktop Retina. The cursor is composed after upscaling. Native Retina has more source detail; game FPS is not guaranteed.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if mac.desktopLayout == true {
                            let requested = mac.displaySize(in: Device.displayViewport)
                            if screen != requested {
                                Text("This Mac kept its previous \(screen.width) × \(screen.height) display. The selected desktop mode will use \(requested.width) × \(requested.height) after you shut down macOS and start again. Save & Leave preserves the current display.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if LinkHostService.shared.active {
                        Text("Main desktop on iPad: in macOS System Settings → Displays, select the iPad display and choose Use as → Main Display. Leave the Duo as an extended display. This Mac saves that choice.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let screen = runningScreen {
                            LabeledContent("iPad guest pixels", value: "\(screen.width) × \(screen.height)")
                        }
                    }
                    Toggle("Color matching", isOn: $matchScreenColors)
                    LabeledContent("Brightness", value: "\(Int(screenBrightness * 100))%")
                    Slider(value: $screenBrightness, in: 0.4...1)
                    Text("Brightness dims only the Mac's screen.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Pointer") {
                    Picker("Size", selection: $cursorScale) {
                        Text("Auto").tag(0)
                        Text("1×").tag(1)
                        Text("2×").tag(2)
                        Text("3×").tag(3)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Sharp edges", isOn: $sharpCursor)
                    LabeledContent("Magic Keyboard / mouse scroll speed", value: String(format: "%.2f×", scrollSpeed))
                    Slider(value: $scrollSpeed, in: HardwareScroll.minimumSpeed...HardwareScroll.maximumSpeed)
                    Button("Reset hardware scroll speed") { scrollSpeed = HardwareScroll.defaultSpeed }
                    Text("Auto preserves the Mac’s Retina pointer size and enlarges smaller phone modes. Fixed sizes keep your choice. Scroll speed changes apply immediately.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Touch input") {
                    Toggle("Native touch (experimental)", isOn: $nativeTouch.requested)
                        .disabled(!Sharing.enabledForSession)
                    if !Sharing.enabledForSession {
                        Text("Enable Guest sharing in Henge Settings and reopen Henge to use native touch.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("Requires macOS 27.2 or later and the updated Henge sharing helper. Allow Local Network for Henge Sharing Agent if macOS asks. Touchscreen stays selected while reconnecting. Turn Native touch off to use the screen as a trackpad. Magic Keyboard and Pencil tip input work alongside native touch; pressure, hover and squeeze are not exposed to the Mac.")
                        .font(.footnote).foregroundStyle(.secondary)
                    switch nativeTouch.status {
                    case 2: Text("Native touch is ready.")
                    case 3: Text("This guest needs macOS 27.2 or later. Turn Native touch off to use trackpad.")
                    case 4: Text("Update the guest sharing helper to use USB touch. Turn Native touch off to use trackpad.")
                    case 5: Text("The Mac could not connect its touchscreen. Reconnecting with a short backoff. Update the helper if this continues; turn Native touch off to use trackpad.")
                    case 6: Text("The touch helper did not respond. Retrying with increasing backoff; touchscreen stays selected.")
                    case 7: Text("The Mac touch helper is delayed. Contacts were released and the USB mapping is retained during bounded recovery. Keyboard and trackpad remain available.")
                    case 8: Text("The sharing helper is connected, but the touchscreen companion is not responding. Use Helper Update below to repair or update both Mac helpers. Touch reconnects automatically when the companion returns.")
                    case 1: Text("Waiting for the updated guest sharing helper. Connecting without restarting the Mac.")
                    default: Text("Native touch off uses the trackpad. When selected, waiting for the guest helper.")
                    }
                    Button("Type the Helper Update Command") {
                        showDetails = false
                        Task {
                            try? await Task.sleep(for: .milliseconds(600))
                            await Sharing.typeSetUpCommand()
                        }
                    }
                    .disabled(!Sharing.enabledForSession)
                }
                Section("Sharing") {
                    LabeledContent("Clipboard and folder", value: helperRunning ? "On" : "Not set up")
                    LabeledContent("Confirmed paste", value: helperRunning && henge_share_clipboard_ready() != 0 ? "Ready" : "Companion update needed")
                    Text("Text only. Copying on the Mac updates this device while Henge is active. Use the system Paste button to send text to the Mac; it waits for confirmation before pressing Command-V. Henge never reads your clipboard automatically. Universal Clipboard also works between nearby Apple devices when the same Apple Account, Handoff, Wi-Fi and Bluetooth are enabled; Apple controls its availability.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !helperRunning || henge_share_clipboard_ready() == 0 {
                        Button(helperRunning ? "Type Companion Update Command" : "Type the Set Up Command") {
                            showDetails = false
                            Task {
                                try? await Task.sleep(nanoseconds: 600_000_000)
                                await Sharing.typeSetUpCommand()
                            }
                        }
                    }
                    Text(helperRunning
                         ? "Put files in Files, Henge, Shared to see them in the Henge folder in this Mac's home folder. What you copy on the Mac is copied here too, and the paste button pastes from here into the Mac."
                         : "Once for each Mac: open Terminal on the Mac, tap this, then press Return. When macOS asks about henge-agent and local networks, choose Allow. It types \(Sharing.setUpCommand) and needs the Mac's keyboard layout to be U.S.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Log") {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(log.suffix(30).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: Running

    private static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot — performance reduced"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private func run(viewport: CGSize) async {
        viewRevision=InstantResume.runtime.claimView()
        SessionNativeEvents.start()
        error = nil
        state = 0
        userCode = false
        cpusOn = 0
        blocksPerSecond = 0
        framesOut = 0
        framesIn = 0
        zoomed = false
        controlsHidden = false
        showRevealHint = false
        zoomCentre = CGPoint(x: 0.5, y: 0.5)
        map = nil
        showWallpaperTip = false
        booting=true; manualSaving=false
        while henge_vm_state() == 3 && !Task.isCancelled { await wakeups.wait() }
        guard !Task.isCancelled else { booting=false;return }
        let configuration:ResumeConfiguration
        var sessionMac=mac
        if let existing=InstantResume.runtime.configuration(macID:mac.id,generation:henge_vm_generation(),state:henge_vm_state()) {
            configuration=existing
            HengeLog.log("resume","reattaching live generation=\(henge_vm_generation()); no new VM, devices or JIT")
        } else {
            guard henge_vm_state() == 0 || henge_vm_state() == 2 else {
                booting=false;error="Another Mac is running or paused. Return to that Mac before starting this one.";return
            }
            let restoring:ResumeConfiguration?
            do { restoring=try InstantResume.configuration(for:mac) }
            catch { booting=false;self.error=error.localizedDescription;return }
            let screen=restoring.map { GuestScreenSize(width:$0.width,height:$0.height) } ?? mac.displaySize(in:viewport)
            if let restoring { sessionMac.ramMB=Int(restoring.ramMB) }
            let ram=GuestMemory.prepare(sessionMac)
            HengeLog.log("session","available memory \(henge_available_memory() >> 20) MB")
            guard ram>=1024,restoring == nil || restoring?.ramMB == ram else {
                booting=false;error="There is not enough storage or address space for this Mac's saved memory. The saved state and disk are kept.";return
            }
            JITBootstrap.releaseLingeringDebugger();Sharing.prepare();EngineTuning.apply()
            let presentationScale = restoring.map { $0.presentationScale ?? 1 } ?? (mac.usesDesktopMetalFX ? 2 : 1)
            setenv("HV_PVG_DESKTOP_FX", presentationScale == 2 ? "2" : "1", 1)
            HengeLog.log("display", "Desktop presentation requested=\(presentationScale)x; guest=\(screen.width)x\(screen.height); layout follows actual guest pixels; native fallback is explicit")
            let mmWidth=restoring?.mmWidth ?? (mac.isRetina ? Int((Double(screen.width)/264*25.4).rounded()) : 0)
            let mmHeight=restoring?.mmHeight ?? (mac.isRetina ? Int((Double(screen.height)/264*25.4).rounded()) : 0)
            henge_vm_set_display(UInt32(screen.width),UInt32(screen.height))
            henge_vm_set_display_mm(UInt32(mmWidth),UInt32(mmHeight))
            if let restoring { setenv("HV_HZ",String(restoring.hz),1) }
            sessionMac.screenWidth=screen.width;sessionMac.screenHeight=screen.height
            configuration=restoring ?? InstantResume.identity(for:sessionMac,ramMB:ram,cpus:cpus,
                hz:getenv("HV_HZ").flatMap { Int(String(cString:$0)) } ?? 60,mmWidth:mmWidth,mmHeight:mmHeight)
            do { try LinkHostService.shared.prepareBoot() }
            catch { booting=false;self.error=error.localizedDescription;return }
            HengeLog.log("session","screen \(configuration.width)x\(configuration.height) retina \(configuration.retina); CPUs \(configuration.cpus); saved_configuration=\(restoring != nil)")
            let (rc,reason)=await InstantResume.start(mac,configuration:configuration,restore:restoring != nil)
            if rc != 0 {
                booting=false;LinkHostService.shared.stop();error=reason;return
            }
            MacPreview.beginSession()
        }
        sessionMac.screenWidth=configuration.width;sessionMac.screenHeight=configuration.height
        sessionMac.retina=configuration.retina;sessionMac.ramMB=Int(configuration.ramMB)
        runningScreen=GuestScreenSize(width:configuration.width,height:configuration.height)
        bootConfiguration=configuration;bootMac=sessionMac
        bootGeneration=henge_vm_generation();booting=false
        LinkHostService.shared.resumeVideoIfNeeded()
        guard !Task.isCancelled else {
            guard !InstantResume.runtime.hasActiveView else { return }
            InstantResume.pause(force:true,generation:bootGeneration)
            if InstantResume.enabled { InstantResume.suspend(sessionMac,configuration:configuration) }
            return
        }
        UIApplication.shared.isIdleTimerDisabled=true;HardwareMouse.shared.start()
        if scenePhase == .active { InstantResume.cameBack(sessionMac) }
        else {
            InstantResume.pause(force:false,generation:bootGeneration)
            if InstantResume.enabled { InstantResume.suspend(sessionMac,configuration:configuration) }
        }
        started = Date()
        var used = mac
        used.lastUsed = started
        Machines.shared.update(used)
        let wallStart = ProcessInfo.processInfo.systemUptime
        var counters = HengeVmCounters()
        var observation=HengeVmObservation()
        if henge_vm_try_observation(&observation) != 0 { counters=observation.counters }
        statistics.reset(blocks: counters.blocks, time: wallStart, epoch: counters.epoch)
        var gpuCounter = SessionCounter()
        _ = gpuCounter.sample(count: counters.gpu_frames, time: wallStart, epoch: counters.epoch)
        var nextDiagnostics = wallStart + 10
        var nextFootprint = wallStart + 30
        var nextPreview = wallStart + 60
        let wallpaperTipAt = wallStart + 60
        while !Task.isCancelled {
            if resumeStatus.busy && resumeStatus.generation == bootGeneration {
                state=henge_vm_state()
                if scenePhase == .active && resumeStatus.phase == .saving { InstantResume.updateProgress() }
                await wakeups.wait(seconds:scenePhase == .active && resumeStatus.phase == .saving ? 0.25 : nil)
                continue
            }
            guard henge_vm_try_observation(&observation) != 0 else {
                await wakeups.wait(seconds:0.1);continue
            }
            counters=observation.counters
            diagnosticCapture.sample()
            let currentState = counters.state, currentCPUs = observation.cpus_on
            if currentState != state { state = currentState }
            if currentCPUs != cpusOn { cpusOn = currentCPUs }
            if !userCode && observation.guest_el0 != 0 { userCode = true }
            if state == 3 {
                await wakeups.wait()
                continue
            }
            let uptime = ProcessInfo.processInfo.systemUptime
            if state == 4 {
                statistics.reset(blocks: counters.blocks, time: uptime, epoch: counters.epoch)
                gpuCounter.reset()
                await wakeups.wait(seconds: diagnosticCapture.nextDeadline.map { max(0,$0-ProcessInfo.processInfo.systemUptime) })
                continue
            }
            statistics.sample(blocks: counters.blocks, time: uptime, epoch: counters.epoch)
            if showDetails { refreshDetails() }
            let heat = thermalState
            if state == 2 {
                LinkHostService.shared.stop()
                nativeTouch.stop()
                typing = false
                showDetails = false
                confirmStop = false
                zoomFollowing?.cancel()
                StickyKeys.shared.releaseAll()
                HardwareKeys.releaseAll()
                HardwareMouse.shared.stop()
                UIApplication.shared.isIdleTimerDisabled = false
                HengeLog.log("session", "showing stopped Mac: \(String(cString: henge_vm_exit_reason()))")
                if henge_vm_exit_outcome() == Int32(HENGE_VM_OUTCOME_RESTART.rawValue) && henge_vm_can_start() != 0 {
                    bootAttempt += 1
                }
                break
            }
            if uptime >= nextDiagnostics && EngineTuning.diagnosticsEnabled {
                nextDiagnostics = uptime + 10
                let frameInterval = gpuCounter.sample(count: counters.gpu_frames, time: uptime, epoch: counters.epoch)
                let frameText = frameInterval.map {
                    "GPU frames \($0.count) in \(String(format: "%.3f", $0.seconds))s (\(String(format: "%.2f", $0.perSecond))/s)"
                } ?? "GPU frames unavailable (new run baseline)"
                HengeLog.log("perf", "session wall elapsed \(Int(uptime - wallStart))s, run epoch \(counters.epoch), blocks/s \(String(format: "%.0f", statistics.blocksPerSecond)), \(frameText), "
                             + "network tx \(counters.tx), rx \(counters.rx), dns answered \(henge_vm_dns(0)) fallback \(henge_vm_dns(1)) timed-out \(henge_vm_dns(2)), thermal \(Self.thermalLabel(heat))")
                diagnosticCapture.requestNativeReport()
                HengeLog.log("input", HardwareMouse.shared.scrollDiagnostics)
                JITBootstrap.releaseLingeringDebugger()
            }
            if uptime >= wallpaperTipAt && !stillWallpaperTipShown {
                stillWallpaperTipShown = true
                showWallpaperTip = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { showWallpaperTip = false }
            }
            if uptime >= nextFootprint && EngineTuning.diagnosticsEnabled {
                nextFootprint = uptime + 30
                HengeLog.logFootprint("session")
            }
            let previewAllowed = scenePhase == .active && (!M4Performance.enabled || heat == .nominal)
            if uptime >= nextPreview && previewAllowed {
                nextPreview = uptime + 60
                MacPreview.save(for: mac, aspect: displayAspect)
            }
            // State changes wake this task directly. Poll only for visible
            // consumers/startup or an actual maintenance deadline.
            var deadlines: [Double] = []
            if let captureDeadline = diagnosticCapture.nextDeadline { deadlines.append(captureDeadline) }
            if showDetails || !userCode { deadlines.append(uptime + 1) }
            if EngineTuning.diagnosticsEnabled { deadlines += [nextDiagnostics, nextFootprint] }
            if !stillWallpaperTipShown { deadlines.append(wallpaperTipAt) }
            if previewAllowed { deadlines.append(nextPreview) }
            await wakeups.wait(seconds: deadlines.min().map { max(0, $0 - ProcessInfo.processInfo.systemUptime) })
        }
    }

    private func stopTapped() {
        guard !booting else { return }
        if state == 1 || state == 4 { confirmStop = true } else { close() }
    }

    private func finish() {
        guard !booting,InstantResume.runtime.ownsView(viewRevision) else { return }
        let owner=viewRevision
        nativeTouch.stop();manualSaving=true
        InstantResume.stop(bootMac ?? mac) { stopped in
            guard InstantResume.runtime.ownsView(owner) else { return }
            if stopped { endSessionUI();close() }
            else { manualSaving=false }
        }
    }

}
