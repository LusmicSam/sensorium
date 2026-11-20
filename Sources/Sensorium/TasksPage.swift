import SensoriumCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Task creator: named lists of steps that gestures (or the Run button) execute in order.
struct TasksPage: View {
    @Environment(SensorHub.self) private var hub
    @Environment(Tweaks.self) private var tweaks

    var body: some View {
        @Bindable var tweaks = tweaks
        VStack(spacing: 14) {
            Card("Task creator", subtitle: "\(tweaks.v.gestures.tasks.count) tasks") {
                Text("A task is a list of steps: open apps, files, folders or web pages, run shell commands, change brightness or volume, toggle No Sleep, press a shortcut, or wait. Link tasks to gestures on the Trackpad Gestures page.")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    tweaks.v.gestures.tasks.append(UserTask(name: "New task \(tweaks.v.gestures.tasks.count + 1)"))
                } label: { Label("New task", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
            }
            ForEach($tweaks.v.gestures.tasks) { $task in
                TaskEditor(task: $task) { hub.runTask(task) } delete: {
                    tweaks.v.gestures.tasks.removeAll { $0.id == task.id }
                }
            }
            if !hub.taskLog.isEmpty {
                Card("Run log") {
                    ForEach(hub.taskLog, id: \.self) { Text($0).font(.caption.monospaced()) }
                }
            }
        }
    }
}

struct TaskEditor: View {
    @Binding var task: UserTask
    var run: () -> Void
    var delete: () -> Void

    var body: some View {
        Card(task.name, subtitle: "\(task.actions.count) step\(task.actions.count == 1 ? "" : "s")") {
            HStack {
                TextField("Name", text: $task.name).frame(width: 260)
                Spacer()
                Button { run() } label: { Label("Run now", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).tint(Neon.cyan)
                Button(role: .destructive) { delete() } label: { Image(systemName: "trash") }
            }
            ForEach(Array(task.actions.enumerated()), id: \.element.id) { i, _ in
                ActionRow(action: $task.actions[i], index: i, count: task.actions.count) { delta in
                    let j = i + delta
                    guard task.actions.indices.contains(j) else { return }
                    task.actions.swapAt(i, j)
                } remove: {
                    task.actions.remove(at: i)
                }
            }
            Menu {
                ForEach(ActionKind.allCases) { k in
                    Button { task.actions.append(TaskAction(kind: k, amount: k == .wait ? 1 : 0.1)) } label: { Label(k.rawValue, systemImage: k.icon) }
                }
            } label: { Label("Add step", systemImage: "plus.circle") }
            .fixedSize()
        }
    }
}

struct ActionRow: View {
    @Binding var action: TaskAction
    var index: Int
    var count: Int
    var move: (Int) -> Void
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 16)
            Image(systemName: action.kind.icon).foregroundStyle(Neon.cyan).frame(width: 20)
            Picker("", selection: $action.kind) {
                ForEach(ActionKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 250)
            if action.kind.usesText {
                TextField(placeholder, text: $action.text)
                if action.kind == .openApp || action.kind == .open {
                    Button("Choose…") { choose() }
                }
            }
            if action.kind.usesAmount {
                Slider(value: $action.amount, in: action.kind == .wait ? 0.1...10 : 0.02...0.5).frame(width: 160)
                Text(action.kind == .wait ? fmt(action.amount, 1, " s") : "\(Int(action.amount * 100))%")
                    .monospacedDigit().frame(width: 44)
            }
            Spacer(minLength: 0)
            Button { move(-1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
            Button { move(1) } label: { Image(systemName: "chevron.down") }.disabled(index == count - 1)
            Button(role: .destructive) { remove() } label: { Image(systemName: "xmark") }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private var placeholder: String {
        switch action.kind {
        case .openApp: return "/Applications/Safari.app"
        case .open: return "~/Downloads  or  https://example.com"
        case .shell: return "open -a Calculator; say done"
        case .shortcut: return "cmd+shift+4"
        case .terminalHere: return "cc"
        default: return ""
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = action.kind == .open
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if action.kind == .openApp {
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
        }
        if panel.runModal() == .OK, let url = panel.url { action.text = url.path }
    }
}
