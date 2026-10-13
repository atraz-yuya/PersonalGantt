import SwiftUI

struct ClockTimeTextField: View {
    let title: String
    @Binding var text: String
    var allowsEndOfDay = false
    var body: some View {
        TextField(title, text: Binding(get: { text }, set: { value in
            let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
            text = input.count == 4 && input.allSatisfy({ $0.isASCII && $0.isNumber })
                ? ClockTime.normalized(value, allowsEndOfDay: allowsEndOfDay) : value
        }))
        .onSubmit { text = ClockTime.normalized(text, allowsEndOfDay: allowsEndOfDay) }
        #if os(iOS)
        .keyboardType(.numbersAndPunctuation)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        #endif
    }
}

/// Dates use the system picker; the time accepts both 1930 and 19:30.
struct DeadlineFields: View {
    @Environment(\.calendar) private var calendar
    @Binding var selection: Date
    @Binding var isTimeValid: Bool
    let identifier: String
    @State private var timeText: String
    init(selection: Binding<Date>, isTimeValid: Binding<Bool>, identifier: String) {
        _selection = selection; _isTimeValid = isTimeValid
        self.identifier = identifier
        _timeText = State(initialValue: ClockTime.text(for: selection.wrappedValue, calendar: .current))
    }
    var body: some View {
        Group {
            DatePicker("締切日", selection: $selection, in: Date.distantPast...Date.distantFuture, displayedComponents: .date)
                .accessibilityIdentifier(identifier)
            ClockTimeTextField(title: "締切時刻（例: 1930）", text: Binding(get: { timeText }, set: applyTime))
                .accessibilityIdentifier(identifier + "-time")
            if !isTimeValid {
                Text("有効な時刻を4桁（例: 0930）または09:30で入力してください。")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .onAppear { timeText = ClockTime.text(for: selection, calendar: calendar) }
        .onChange(of: selection) { _, date in
            timeText = ClockTime.text(for: date, calendar: calendar)
            isTimeValid = true
        }
    }
    private func applyTime(_ text: String) {
        timeText = text
        guard let date = ClockTime.date(text, on: selection, calendar: calendar),
              date >= .distantPast, date <= .distantFuture else { isTimeValid = false; return }
        isTimeValid = true
        if date != selection { selection = date }
    }
}
