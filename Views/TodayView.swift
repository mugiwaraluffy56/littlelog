import SwiftData
import SwiftUI

struct TodayView: View {
    @Environment(Library.self) private var library
    var focus: FocusState<FocusTarget?>.Binding

    var body: some View {
        TaskList(dayKey: library.dayKey, day: library.day, focus: focus)
            .id(library.dayKey)
    }
}

private struct TaskList: View {
    @Environment(AppState.self) private var state
    @Environment(Library.self) private var library
    @Query private var tasks: [DailyTask]
    let day: Date
    var focus: FocusState<FocusTarget?>.Binding

    init(dayKey: String, day: Date, focus: FocusState<FocusTarget?>.Binding) {
        _tasks = Query(DailyTask.descriptor(for: dayKey), animation: Style.motion)
        self.day = day
        self.focus = focus
    }

    @State private var draggingID: UUID?

    /// A stack drawn like an inset list rather than a `List`: on macOS a `List` paints an opaque
    /// background behind text fields in its rows (the task and New Task fields).
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.title3.weight(.semibold))
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                    .accessibilityAddTraits(.isHeader)

                ForEach(tasks) { task in
                    TaskRow(task: task, focus: focus)
                        .overlay(alignment: .bottom) { RowSeparator() }
                        .onDrag {
                            draggingID = task.id
                            return NSItemProvider(object: task.text as NSString)
                        }
                        .onDrop(
                            of: [.plainText],
                            delegate: TaskDropDelegate(target: task, tasks: tasks, draggingID: $draggingID, library: library)
                        )
                        .contextMenu {
                            Button(task.isCompleted ? "Mark as Not Completed" : "Mark as Completed") {
                                library.toggle(task)
                            }
                            Button("Edit") { state.beginEditing(task) }
                            Divider()
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                library.removeTaskReportingErrors(task)
                            }
                        }
                }

                if tasks.isEmpty {
                    Text("A clean slate.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, TaskMetrics.rowPadding)
                }

                AddTaskRow(focus: focus)
            }
            .padding(.horizontal, Style.contentInset)
            .padding(.bottom, Style.contentInset)
        }
        .scrollIndicators(.hidden)
    }
}

private enum TaskMetrics {
    static let controlWidth: CGFloat = 20
    static let spacing: CGFloat = 8
    static let rowPadding: CGFloat = 8
    /// Separators start at the text, like Reminders.
    static let textInset: CGFloat = controlWidth + spacing
}

private struct RowSeparator: View {
    var body: some View {
        Divider().padding(.leading, TaskMetrics.textInset)
    }
}

/// Reorders live while a row is dragged over another, then clears on drop.
private struct TaskDropDelegate: DropDelegate {
    let target: DailyTask
    let tasks: [DailyTask]
    @Binding var draggingID: UUID?
    let library: Library

    func dropEntered(info: DropInfo) {
        guard let draggingID, draggingID != target.id,
              let from = tasks.firstIndex(where: { $0.id == draggingID }),
              let to = tasks.firstIndex(where: { $0.id == target.id })
        else { return }
        library.moveTasks(tasks, from: IndexSet(integer: from), to: to > from ? to + 1 : to)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggingID != nil
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}

/// A Reminders-style row: a circular completion toggle, then the task text (click to edit).
private struct TaskRow: View {
    @Environment(AppState.self) private var state
    @Environment(Library.self) private var library
    @Bindable var task: DailyTask
    var focus: FocusState<FocusTarget?>.Binding

    private var isEditing: Bool { state.editingTaskID == task.id }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: TaskMetrics.spacing) {
            Toggle(task.text, isOn: Binding(get: { task.isCompleted }, set: { _ in library.toggle(task) }))
                .toggleStyle(CircleToggleStyle())
                .labelsHidden()

            if isEditing {
                TextField("Task", text: $task.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused(focus, equals: .task(task.id))
                    .onSubmit { state.endEditingTask() }
                    .accessibilityLabel("Edit Task")
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(task.text)
                        .strikethrough(task.isCompleted)
                        .foregroundStyle(task.isCompleted ? .secondary : .primary)
                    if task.addedByAssistant {
                        Image(systemName: "sparkle")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .help("Added by ChatGPT")
                            .accessibilityLabel("Added by assistant")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .onTapGesture { state.beginEditing(task) }
            }
        }
        .padding(.vertical, TaskMetrics.rowPadding)
        .animation(Style.motion, value: task.isCompleted)
        .onChange(of: task.text) { library.taskDidChange(task) }
        .onChange(of: focus.wrappedValue) { _, newValue in
            if isEditing, newValue != .task(task.id) {
                state.endEditingTask(restoreFocus: false)
            }
        }
    }
}

/// The same circle-and-checkmark control Reminders uses, in monochrome.
private struct CircleToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .fontWeight(.light)
                .foregroundStyle(configuration.isOn ? .secondary : .tertiary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: TaskMetrics.controlWidth)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

private struct AddTaskRow: View {
    @Environment(AppState.self) private var state
    var focus: FocusState<FocusTarget?>.Binding

    var body: some View {
        @Bindable var state = state
        HStack(alignment: .firstTextBaseline, spacing: TaskMetrics.spacing) {
            Image(systemName: "plus.circle")
                .font(.title3)
                .fontWeight(.light)
                .foregroundStyle(.tertiary)
                .frame(width: TaskMetrics.controlWidth)
                .accessibilityHidden(true)
            TextField("New Task", text: $state.newTaskDraft)
                .textFieldStyle(.plain)
                .focused(focus, equals: .newTask)
                .onSubmit {
                    state.addTask()
                    state.requestFocus(.newTask)
                }
                .accessibilityLabel("New Task")
        }
        .padding(.vertical, TaskMetrics.rowPadding)
    }
}
