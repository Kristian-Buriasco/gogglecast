import Foundation

#if canImport(SwiftUI)
import SwiftUI

// Shared building blocks for the Settings window: a card holding a titled table of rows,
// and a row with a fixed-width label column so labels line up across every group.
// Layout only; nothing here touches preferences.

enum SettingsLayout {
    static let labelWidth: CGFloat = 210
    static let sliderWidth: CGFloat = 190
}

/// A titled card whose rows are separated by hairlines.
struct SettingsGroup<Content: View>: View {
    let title: LocalizedStringKey
    var footer: LocalizedStringKey?
    var info: LocalizedStringKey?
    @ViewBuilder var content: () -> Content
    @State private var showInfo = false

    init(_ title: LocalizedStringKey, footer: LocalizedStringKey? = nil, info: LocalizedStringKey? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.info = info
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                if let info {
                    Button { showInfo.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel(Text("More information"))
                        .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                            Text(info).font(.callout).fixedSize(horizontal: false, vertical: true)
                                .frame(width: 340, alignment: .leading).padding(14)
                        }
                }
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)
            // Each row draws a hairline above itself; the offset + clip hides the first one.
            VStack(alignment: .leading, spacing: 0) { content() }
                .offset(y: -1)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(AppChrome.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppChrome.cardStroke))
    }
}

/// One row: label on the left (fixed width), control on the right, optional one-line help
/// under the control and an (i) popover for the long explanation.
struct SettingsRow<Control: View>: View {
    let label: LocalizedStringKey
    var help: LocalizedStringKey?
    var info: LocalizedStringKey?
    var indented = false
    @ViewBuilder var control: () -> Control
    @Environment(\.isEnabled) private var isEnabled
    @State private var showInfo = false

    init(_ label: LocalizedStringKey, help: LocalizedStringKey? = nil, info: LocalizedStringKey? = nil,
         indented: Bool = false, @ViewBuilder control: @escaping () -> Control) {
        self.label = label
        self.help = help
        self.info = info
        self.indented = indented
        self.control = control
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HStack(spacing: 4) {
                Text(label).foregroundStyle(isEnabled ? .primary : .secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.leading, indented ? 14 : 0)
            .frame(width: SettingsLayout.labelWidth, alignment: .leading)
            .frame(minHeight: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    control()
                    if let info {
                        Button { showInfo.toggle() } label: { Image(systemName: "info.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel(Text("More information"))
                            .popover(isPresented: $showInfo, arrowEdge: .trailing) {
                                Text(info).font(.callout).fixedSize(horizontal: false, vertical: true)
                                    .frame(width: 320, alignment: .leading).padding(14)
                            }
                    }
                }
                .frame(minHeight: 22, alignment: .leading)
                if let help {
                    Text(help).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
    }
}

/// A switch row.
struct SettingsToggleRow: View {
    let label: LocalizedStringKey
    @Binding var isOn: Bool
    var help: LocalizedStringKey?
    var info: LocalizedStringKey?
    var indented = false
    var accessibilityName: LocalizedStringKey?

    init(_ label: LocalizedStringKey, isOn: Binding<Bool>, help: LocalizedStringKey? = nil,
         info: LocalizedStringKey? = nil, indented: Bool = false, accessibilityName: LocalizedStringKey? = nil) {
        self.label = label; self._isOn = isOn; self.help = help; self.info = info; self.indented = indented
        self.accessibilityName = accessibilityName
    }

    var body: some View {
        SettingsRow(label, help: help, info: info, indented: indented) {
            Toggle(accessibilityName ?? label, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

/// A slider row with a fixed-width value readout (`unit` follows the number).
struct SettingsSliderRow: View {
    let label: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format = "%.0f"
    var scale = 1.0
    var unit = ""
    var help: LocalizedStringKey?
    var info: LocalizedStringKey?
    var indented = false

    init(_ label: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, format: String = "%.0f",
         scale: Double = 1, unit: String = "", help: LocalizedStringKey? = nil, info: LocalizedStringKey? = nil,
         indented: Bool = false) {
        self.label = label; self._value = value; self.range = range; self.format = format
        self.scale = scale; self.unit = unit; self.help = help; self.info = info; self.indented = indented
    }

    var body: some View {
        let text = String(format: format, value * scale) + unit
        SettingsRow(label, help: help, info: info, indented: indented) {
            HStack(spacing: 8) {
                Slider(value: $value, in: range).frame(width: SettingsLayout.sliderWidth)
                    .accessibilityLabel(Text(label)).accessibilityValue(text)
                Text(verbatim: text).monospacedDigit().foregroundStyle(.secondary)
                    .fixedSize().frame(minWidth: 56, alignment: .leading).accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Text input style

/// Rounded, hairline-bordered field chrome shared by every text input in Settings.
/// `valid` (nil = no indicator) shows a green check or red mark where validation already exists.
struct SettingsFieldChrome: ViewModifier {
    var width: CGFloat?
    var mono = true
    var unit: String?
    var valid: Bool?
    var trailing: AnyView?
    var onFocus: (() -> Void)?
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        HStack(spacing: 6) {
            content
                .textFieldStyle(.plain)
                .font(mono ? .system(size: 12, design: .monospaced) : .body)
                .focused($focused)
                .focusEffectDisabled()
                .onChange(of: focused) { _, f in if f { onFocus?() } }
            if let unit { Text(verbatim: unit).font(.caption).foregroundStyle(.secondary) }
            if let valid {
                Image(systemName: valid ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(valid ? Color.green : Color.red)
                    .accessibilityLabel(valid ? Text("Valid") : Text("Invalid"))
            }
            if let trailing { trailing }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .background(RoundedRectangle(cornerRadius: 7).fill(AppChrome.subtleFill))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(focused ? Color.accentColor : AppChrome.cardStroke, lineWidth: focused ? 1.5 : 1))
        .opacity(isEnabled ? 1 : 0.5)
        .contentShape(Rectangle())
    }
}

extension View {
    /// Apply to a `TextField` or `SecureField`. `width: nil` = fill the control column.
    func settingsField(width: CGFloat? = nil, mono: Bool = true, unit: String? = nil, valid: Bool? = nil,
                       onFocus: (() -> Void)? = nil) -> some View {
        modifier(SettingsFieldChrome(width: width, mono: mono, unit: unit, valid: valid, trailing: nil, onFocus: onFocus))
    }
}

/// A password / key field with a show-hide eye. `onReveal` runs when the field is focused or revealed,
/// so callers can keep their lazy Keychain read.
struct SettingsSecretField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    var prompt: LocalizedStringKey?
    var width: CGFloat?
    var onReveal: (() -> Void)?
    @State private var shown = false

    var body: some View {
        let field = Group {
            if shown {
                TextField(title, text: $text, prompt: prompt.map { Text($0) })
            } else {
                SecureField(title, text: $text, prompt: prompt.map { Text($0) })
            }
        }
        .labelsHidden()
        let eye = Button {
            if !shown { onReveal?() }
            shown.toggle()
        } label: { Image(systemName: shown ? "eye.slash" : "eye").foregroundStyle(.secondary) }
            .buttonStyle(.plain)
            .accessibilityLabel(shown ? Text("Hide") : Text("Show"))
        field.modifier(SettingsFieldChrome(width: width, mono: true, unit: nil, valid: nil,
                                           trailing: AnyView(eye), onFocus: onReveal))
    }
}
#endif
