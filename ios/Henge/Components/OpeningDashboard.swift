import SwiftUI

/// Presentation only: callers retain machine, JIT and connection ownership.
struct OpeningDashboard<Mac: View, Connections: View>: View {
    let wide: Bool
    let mac: () -> Mac
    let connections: () -> Connections
    init(wide: Bool, @ViewBuilder mac: @escaping () -> Mac, @ViewBuilder connections: @escaping () -> Connections) {
        self.wide = wide; self.mac = mac; self.connections = connections
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your workspace").font(.largeTitle.bold())
                Text("A Mac when you need it. Your devices, connected.")
                    .font(.subheadline).foregroundStyle(Desk.dim)
            }.accessibilityElement(children: .combine)
            if wide {
                HStack(alignment: .top, spacing: 24) {
                    mac().frame(maxWidth: .infinity)
                    connections().frame(width: 320)
                }
            } else {
                mac()
                connections()
            }
        }
        .foregroundStyle(Desk.text)
        .frame(maxWidth: 1120, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}

struct MacLaunchCard: View {
    let name: String
    let summary: String
    let ready: Bool
    let saved: Bool
    var inMemory = false
    var preview: UIImage?
    var setupNote: String?
    let start: () -> Void
    let setup: () -> Void
    let configure: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 20).fill(Desk.raised)
                if let preview {
                    Image(uiImage: preview).resizable().scaledToFill()
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "desktopcomputer").font(.system(size: 44, weight: .light))
                        Text("Your Mac desktop").font(.subheadline)
                    }.foregroundStyle(Desk.dim)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 200)
            .clipped().clipShape(RoundedRectangle(cornerRadius: 20))
            .accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top) { title; Spacer(minLength: 12); status }
                VStack(alignment: .leading, spacing: 10) { title; status }
            }
            if !ready, let setupNote {
                Label(setupNote, systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(Desk.dim).fixedSize(horizontal: false, vertical: true)
            }
            Button(action: ready ? start : setup) {
                HStack {
                    Image(systemName: ready ? (inMemory ? "play.fill" : (saved ? "arrow.clockwise" : "play.fill")) : "bolt.fill")
                    Text(ready ? (inMemory ? "Continue Mac" : (saved ? "Resume Mac" : "Start Mac")) : "Enable JIT")
                    Spacer()
                    Image(systemName: "arrow.right")
                }.font(.headline).padding(.horizontal, 20).frame(minHeight: 54)
                    .foregroundStyle(.white).background(Desk.accent, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain).accessibilityIdentifier("launch-mac")
            Button(action: configure) {
                Label("Mac settings", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.plain).foregroundStyle(Desk.accentLight)
        }
        .padding(20)
        .background(Desk.card, in: RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(Desk.hairline))
    }
    private var title: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.title2.bold()).lineLimit(2)
            Text(summary).font(.subheadline).foregroundStyle(Desk.dim).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var status: some View {
        Label(ready ? (saved ? "Saved session" : (inMemory ? "Paused in memory" : "Ready")) : "Setup needed",
              systemImage: ready ? (saved ? "pause.circle.fill" : "checkmark.circle.fill") : "bolt.circle")
            .font(.caption.weight(.semibold)).foregroundStyle(ready ? Desk.good : Desk.warn)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background((ready ? Desk.good : Desk.warn).opacity(0.12), in: Capsule())
    }
}

struct WorkspaceConnections: View {
    var canExtend = false
    let controls: () -> Void
    let display: () -> Void
    let extend: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CONNECT YOUR DEVICES").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(Desk.dim)
            action("Wireless controller", detail: "Keyboard, touchpad and gamepad", icon: "gamecontroller.fill", tint: Desk.accentLight, action: controls)
            action("Use as a display", detail: "Show a Mac from another device", icon: "rectangle.on.rectangle", tint: Desk.good, action: display)
            if canExtend {
                action("Extend your Mac", detail: "Add a second screen wirelessly", icon: "display.2", tint: Desk.accentLight, action: extend)
            }
        }
    }
    private func action(_ title: String, detail: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title3).foregroundStyle(tint)
                    .frame(width: 44, height: 44).background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Desk.text)
                    Text(detail).font(.caption).foregroundStyle(Desk.dim)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Desk.dim)
            }.padding(16).frame(maxWidth: .infinity, minHeight: 76)
                .background(Desk.card, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Desk.hairline))
        }.buttonStyle(.plain).accessibilityElement(children: .combine)
    }
}

struct AutomaticSaveCard: View {
    @Binding var enabled: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Automatic saving", systemImage: "clock.arrow.circlepath").font(.subheadline.weight(.semibold))
                Spacer()
                Text(enabled ? "On" : "Off").font(.caption.bold()).foregroundStyle(enabled ? Desk.good : Desk.dim)
            }
            Text(enabled ? "Starts saving when you leave. Returning safely cancels an unfinished save and resumes the Mac." : "Keep your place when switching apps. Enable Instant Resume to save automatically.")
                .font(.caption).foregroundStyle(Desk.dim).fixedSize(horizontal: false, vertical: true)
            if !enabled {
                Button("Enable automatic saving") { enabled = true }.font(.subheadline.weight(.semibold)).frame(minHeight: 44)
            }
            Text("iOS may interrupt large saves. Use Save Mac & Leave and wait for completion for a persistent save.")
                .font(.caption2).foregroundStyle(Desk.dim)
        }.padding(16).background(Desk.card, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Desk.hairline))
    }
}
