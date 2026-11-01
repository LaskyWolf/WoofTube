import SwiftUI

/// Pauses playback after a countdown or when the current video ends. From Woof Music's SleepTimer.
@MainActor
final class SleepTimer: ObservableObject {
    @Published private(set) var endsAt: Date?
    @Published private(set) var stopsAtVideoEnd = false
    private(set) var minutes: Int?
    private var task: Task<Void, Never>?
    private let onEnd: () -> Void

    var isActive: Bool { endsAt != nil || stopsAtVideoEnd }

    init(onEnd: @escaping () -> Void) {
        self.onEnd = onEnd
    }

    func start(minutes: Int) {
        cancel()
        self.minutes = minutes
        let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
        endsAt = end
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(end.timeIntervalSinceNow))
            guard !Task.isCancelled, let self else { return }
            self.cancel()
            self.onEnd()
        }
    }

    func stopAtVideoEnd() {
        cancel()
        stopsAtVideoEnd = true
    }

    func cancel() {
        task?.cancel()
        task = nil
        endsAt = nil
        minutes = nil
        stopsAtVideoEnd = false
    }
}

struct SleepTimerSheet: View {
    @ObservedObject var timer: SleepTimer
    @Environment(\.dismiss) private var dismiss
    @State private var duration: TimeInterval
    @State private var contentHeight: CGFloat = 0

    private static let lastMinutesKey = "sleepTimerLastMinutes"
    private static let defaultMinutes = 15

    init(timer: SleepTimer) {
        self.timer = timer
        let saved = UserDefaults.standard.integer(forKey: Self.lastMinutesKey)
        let minutes = timer.minutes ?? (saved > 0 ? saved : Self.defaultMinutes)
        _duration = State(initialValue: TimeInterval(minutes * 60))
    }

    var body: some View {
        let minutes = Int(duration / 60)
        VStack(spacing: 20) {
            Text("Sleep Timer").font(.headline)

            if timer.stopsAtVideoEnd {
                Label("Stops when this video ends", systemImage: "moon.zzz.fill")
                    .font(.subheadline)
                    .foregroundStyle(.tint)
            } else if let end = timer.endsAt {
                Label {
                    Text(timerInterval: Date()...max(end, Date()), countsDown: true)
                } icon: {
                    Image(systemName: "moon.zzz.fill")
                }
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.tint)
            }

            CountdownPicker(duration: $duration)
                .frame(maxWidth: .infinity)

            HStack {
                roundButton("Cancel", icon: "xmark", isAccent: false) { timer.cancel() }
                    .disabled(!timer.isActive)
                Spacer()
                roundButton("Start", icon: "play.fill", isAccent: true) {
                    UserDefaults.standard.set(minutes, forKey: Self.lastMinutesKey)
                    timer.start(minutes: minutes)
                    dismiss()
                }
                .disabled(minutes < 1)
            }

            Button {
                timer.stopAtVideoEnd()
                dismiss()
            } label: {
                Label("End of Video", systemImage: "play.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(20)
        // Below the sheet's handle.
        .padding(.top, Layout.chipSpacing)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        // Taller than the medium size, which pushed the title under the handle.
        .presentationDetents(contentHeight > 0 ? [.height(contentHeight)] : [.large])
        .presentationDragIndicator(.visible)
    }

    /// The Clock app's round timer button.
    private func roundButton(_ title: String, icon: String, isAccent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: Layout.cardSpacing) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isAccent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .frame(width: 64, height: 64)
                    .background {
                        if isAccent {
                            Circle().fill(.tint).opacity(0.22)
                        } else {
                            Circle().fill(Color.primary.opacity(0.1))
                        }
                    }
                Text(title).font(.caption)
            }
        }
        .buttonStyle(ZoomPressStyle())
    }
}

/// SwiftUI's DatePicker has no countdown mode.
private struct CountdownPicker: UIViewRepresentable {
    @Binding var duration: TimeInterval

    func makeUIView(context: Context) -> UIDatePicker {
        let picker = UIDatePicker()
        picker.datePickerMode = .countDownTimer
        picker.countDownDuration = duration
        picker.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return picker
    }

    func updateUIView(_ picker: UIDatePicker, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(duration: $duration)
    }

    final class Coordinator: NSObject {
        @Binding private var duration: TimeInterval

        init(duration: Binding<TimeInterval>) {
            _duration = duration
        }

        @objc func changed(_ picker: UIDatePicker) {
            duration = picker.countDownDuration
        }
    }
}
