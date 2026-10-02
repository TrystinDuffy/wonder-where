import SwiftUI

enum Palette {
    static let paper = Color(uiColor: .systemGroupedBackground)
    static let ink = Color.primary
}

enum AccentColor: String, CaseIterable, Identifiable {
    case blue, teal, green, orange, red, pink, purple, graphite
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .blue: return .blue
        case .teal: return .teal
        case .green: return .green
        case .orange: return .orange
        case .red: return .red
        case .pink: return .pink
        case .purple: return .purple
        case .graphite: return .gray
        }
    }
}

enum CompassIcon: String, CaseIterable, Identifiable {
    case arrow, needle, chevron, outline, slim, triangle, kite, doubleChevron

    var id: String { rawValue }
    var title: String { self == .doubleChevron ? "Double" : rawValue.capitalized }
}

enum CompassBorder: String, CaseIterable, Identifiable {
    case classic, ring, doubleRing, dashed, dots, quarters, none
    var id: String { rawValue }
    var title: String { self == .doubleRing ? "Double ring" : rawValue.capitalized }
}

@MainActor
final class CompassAppearance: ObservableObject {
    private let defaults: UserDefaults
    @Published var accent: AccentColor { didSet { defaults.set(accent.rawValue, forKey: "accentColor") } }
    @Published var icon: CompassIcon { didSet { defaults.set(icon.rawValue, forKey: "compassIcon") } }

    @Published var border: CompassBorder { didSet { defaults.set(border.rawValue, forKey: "compassBorder") } }
    @Published var usesCustomColor: Bool { didSet { defaults.set(usesCustomColor, forKey: "usesCustomColor") } }
    @Published private(set) var customHex: String { didSet { defaults.set(customHex, forKey: "customColorHex") } }

    var customColor: Color {
        let rgb = UInt32(customHex, radix: 16) ?? 0x007AFF
        return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                     green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
    }
    var color: Color { usesCustomColor ? customColor : accent.color }

    static func normalizedHex(_ input: String) -> String? {
        var hex = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard [3, 6].contains(hex.count), hex.allSatisfy({ "0123456789ABCDEF".contains($0) }) else { return nil }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        return hex
    }

    @discardableResult func setCustomHex(_ input: String) -> Bool {
        guard let hex = Self.normalizedHex(input) else { return false }
        customHex = hex
        usesCustomColor = true
        return true
    }

    func setCustomColor(_ color: Color) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
        let channels = [red, green, blue].map { Int((min(1, max(0, $0)) * 255).rounded()) }
        setCustomHex(String(format: "%02X%02X%02X", channels[0], channels[1], channels[2]))
    }

    init(defaults: UserDefaults? = nil) {
        var storage = defaults ?? .standard
        #if DEBUG
        if defaults == nil, let id = ProcessInfo.processInfo.environment["COMPASS_UI_TEST_DATA"], UUID(uuidString: id) != nil {
            storage = UserDefaults(suiteName: "com.duffy.CompassDay.appearance-tests.\(id)") ?? .standard
        }
        #endif
        self.defaults = storage
        accent = AccentColor(rawValue: storage.string(forKey: "accentColor") ?? "") ?? .blue
        icon = CompassIcon(rawValue: storage.string(forKey: "compassIcon") ?? "") ?? .arrow
        border = CompassBorder(rawValue: storage.string(forKey: "compassBorder") ?? "") ?? .classic
        usesCustomColor = storage.bool(forKey: "usesCustomColor")
        customHex = Self.normalizedHex(storage.string(forKey: "customColorHex") ?? "") ?? "007AFF"
    }
}

@main
struct CompassDayApp: App {
    @StateObject private var store = TripStore()
    @StateObject private var appearance = CompassAppearance()
    @StateObject private var access = ConfigurationAccess()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environmentObject(store)
                .environmentObject(appearance)
                .environmentObject(access)
                .tint(appearance.color)
                .alert("Couldn’t save your day", isPresented: Binding(
                    get: { store.storageError != nil },
                    set: { if !$0 { store.storageError = nil } }
                )) { Button("OK") { store.storageError = nil } }
                message: { Text(store.storageError ?? "") }
        }
    }
}

struct AppearanceView: View {
    @EnvironmentObject private var appearance: CompassAppearance
    @Environment(\.dismiss) private var dismiss
    @State private var category = "Color"
    @State private var hexInput = ""
    @FocusState private var hexFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    CompassBorderView(style: appearance.border)
                    CompassSymbol(icon: appearance.icon, color: appearance.color)
                        .frame(width: 44, height: 104).rotationEffect(.degrees(35))
                }.frame(width: 150, height: 150).padding(.vertical, 20)
                    .accessibilityLabel("Compass preview")
                Picker("Appearance options", selection: $category) {
                    Text("Color").tag("Color")
                    Text("Pointer").tag("Pointer")
                    Text("Border").tag("Border")
                }.pickerStyle(.segmented).accessibilityIdentifier("appearance-options")
                    .padding(.horizontal, 20).padding(.bottom, 12)
                Form {
                    if category == "Color" { colorOptions }
                    if category == "Pointer" {
                        Section {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(CompassIcon.allCases) { icon in
                                    Button { appearance.icon = icon } label: {
                                        option(title: icon.title, selected: appearance.icon == icon) {
                                            CompassSymbol(icon: icon, color: appearance.color).frame(width: 23, height: 48)
                                        }
                                    }.buttonStyle(.plain).accessibilityLabel(icon.title)
                                        .accessibilityValue(appearance.icon == icon ? "Selected" : "")
                                        .accessibilityIdentifier("icon-\(icon.rawValue)")
                                }
                            }.padding(.vertical, 4)
                        }
                    }
                    if category == "Border" {
                        Section {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(CompassBorder.allCases) { border in
                                    Button { appearance.border = border } label: {
                                        option(title: border.title, selected: appearance.border == border) {
                                            ZStack {
                                                CompassBorderView(style: border)
                                                CompassSymbol(icon: .needle, color: appearance.color).frame(width: 12, height: 30)
                                            }.frame(width: 52, height: 52)
                                        }
                                    }.buttonStyle(.plain).accessibilityLabel(border.title)
                                        .accessibilityValue(appearance.border == border ? "Selected" : "")
                                        .accessibilityIdentifier("border-\(border.rawValue)")
                                }
                            }.padding(.vertical, 4)
                        }
                    }
                }.contentMargins(.top, 0).scrollDismissesKeyboard(.interactively)
            }.background(Palette.paper)
                .navigationTitle("Appearance").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("appearance-done") } }
                .onAppear { hexInput = appearance.customHex }
                .onChange(of: appearance.customHex) { _, hex in hexInput = hex }
        }
    }

    private var columns: [GridItem] { Array(repeating: GridItem(.flexible()), count: 4) }

    private func option<Content: View>(title: String, selected: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 8) {
            content().frame(height: 56).accessibilityHidden(true)
            Text(title).font(.caption).foregroundStyle(Color.primary).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(selected ? appearance.color.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(selected ? appearance.color : .clear, lineWidth: 2) }
            .contentShape(Rectangle())
    }

    private var colorOptions: some View {
        Group {
            Section {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(AccentColor.allCases) { accent in
                        Button { appearance.accent = accent; appearance.usesCustomColor = false } label: {
                            VStack(spacing: 5) {
                                Circle().fill(accent.color).frame(width: 34, height: 34)
                                    .overlay { if !appearance.usesCustomColor && appearance.accent == accent { Image(systemName: "checkmark").font(.body.bold()).foregroundStyle(.white) } }
                                Text(accent.title).font(.caption).foregroundStyle(Color.primary)
                            }.frame(maxWidth: .infinity).padding(.vertical, 4).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(accent.title)
                            .accessibilityValue(!appearance.usesCustomColor && appearance.accent == accent ? "Selected" : "")
                            .accessibilityIdentifier("accent-\(accent.rawValue)")
                    }
                }.padding(.vertical, 4)
            }
            Section {
                Toggle("Use custom color", isOn: $appearance.usesCustomColor).accessibilityIdentifier("use-custom-color")
                ColorPicker("Custom color", selection: Binding(get: { appearance.customColor }, set: { appearance.setCustomColor($0) }), supportsOpacity: false)
                    .accessibilityIdentifier("custom-color-picker")
                HStack {
                    Text("Hex")
                    TextField("RRGGBB", text: $hexInput)
                        .font(.system(.body, design: .monospaced)).multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled().focused($hexFocused)
                        .submitLabel(.done).accessibilityIdentifier("custom-color-hex")
                        .onSubmit { applyHex() }
                    Button("Apply") { applyHex() }.disabled(CompassAppearance.normalizedHex(hexInput) == nil)
                        .accessibilityIdentifier("apply-custom-color")
                }
                if !hexInput.isEmpty && CompassAppearance.normalizedHex(hexInput) == nil {
                    Text("Enter 3 or 6 hex digits, such as #7C5CFC.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func applyHex() {
        if appearance.setCustomHex(hexInput) { hexInput = appearance.customHex; hexFocused = false }
    }
}

@MainActor
final class ConfigurationAccess: ObservableObject {
    private let defaults: UserDefaults
    @Published private(set) var pin: String
    @Published var isUnlocked: Bool
    var hasPIN: Bool { !pin.isEmpty }

    init(defaults: UserDefaults? = nil) {
        var storage = defaults ?? .standard
        #if DEBUG
        if defaults == nil, let id = ProcessInfo.processInfo.environment["COMPASS_UI_TEST_DATA"], UUID(uuidString: id) != nil {
            storage = UserDefaults(suiteName: "com.duffy.CompassDay.access-tests.\(id)") ?? .standard
        }
        #endif
        self.defaults = storage
        let saved = storage.string(forKey: "configurationPIN") ?? ""
        let valid = Self.validPIN(saved) ? saved : ""
        pin = valid
        isUnlocked = valid.isEmpty
    }

    static func validPIN(_ pin: String) -> Bool { pin.count == 4 && pin.allSatisfy { "0123456789".contains($0) } }
    @discardableResult func setPIN(_ value: String) -> Bool {
        guard Self.validPIN(value) else { return false }
        pin = value
        defaults.set(value, forKey: "configurationPIN")
        isUnlocked = true
        return true
    }
    @discardableResult func unlock(_ value: String) -> Bool {
        guard !hasPIN || value == pin else { return false }
        isUnlocked = true
        return true
    }
    func removePIN() {
        pin = ""
        defaults.removeObject(forKey: "configurationPIN")
        isUnlocked = true
    }
}

struct AppRootView: View {
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var access: ConfigurationAccess
    @Environment(\.scenePhase) private var scenePhase
    @State private var adventureOpen = UserDefaults.standard.bool(forKey: "adventureOpen")

    var body: some View {
        Group {
            if store.isLoading {
                ProgressView("Opening trips…")
            } else if adventureOpen, store.selectedTrip != nil {
                CompassView {
                    access.isUnlocked = true
                    adventureOpen = false
                }
            } else if access.hasPIN && !access.isUnlocked {
                ConfigurationUnlockView(onUnlock: {}, onCancel: store.activeTrip == nil ? nil : { adventureOpen = true })
            } else {
                TripLibraryView(onOpenCompass: { adventureOpen = true })
            }
        }
        .onChange(of: adventureOpen) { _, value in UserDefaults.standard.set(value, forKey: "adventureOpen") }
        .onChange(of: scenePhase, initial: true) { _, value in store.sceneChanged(value) }
    }
}

struct PINSettingsView: View {
    @EnvironmentObject private var access: ConfigurationAccess
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var confirmRemoval = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("New 4-digit PIN", text: $pin).keyboardType(.numberPad)
                        .accessibilityIdentifier("new-configuration-pin")
                    SecureField("Confirm PIN", text: $confirmation).keyboardType(.numberPad)
                        .accessibilityIdentifier("confirm-configuration-pin")
                } footer: {
                    Text("Ask for this PIN before showing your places. It prevents accidental spoilers.")
                }
                if !confirmation.isEmpty && confirmation != pin {
                    Text("PINs don’t match.").foregroundStyle(.secondary)
                }
                if access.hasPIN {
                    Section {
                        Button("Remove PIN", role: .destructive) { confirmRemoval = true }
                            .accessibilityIdentifier("remove-configuration-pin")
                    }
                }
            }

            .navigationTitle("Configuration PIN").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { if access.setPIN(pin) { dismiss() } }
                        .disabled(!ConfigurationAccess.validPIN(pin) || pin != confirmation)
                        .accessibilityIdentifier("save-configuration-pin")
                }
            }
            .alert("Remove PIN?", isPresented: $confirmRemoval) {
                Button("Cancel", role: .cancel) {}
                Button("Remove PIN", role: .destructive) { access.removePIN(); dismiss() }
            } message: { Text("Configuration will use a confirmation instead of a PIN.") }
        }
    }
}

struct ConfigurationUnlockView: View {
    @EnvironmentObject private var access: ConfigurationAccess
    var onUnlock: () -> Void
    var onCancel: (() -> Void)?
    var destinationName = "Configuration"
    @State private var pin = ""
    @State private var incorrect = false
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("4-digit PIN", text: $pin).keyboardType(.numberPad)
                        .accessibilityIdentifier("unlock-configuration-pin")
                        .onChange(of: pin) { _, value in if !value.isEmpty { incorrect = false } }
                    if incorrect {
                        Text("Incorrect PIN. Try again.").foregroundStyle(.red).accessibilityIdentifier("incorrect-pin")
                    }
                    Button("Open \(destinationName.lowercased())") {
                        if access.unlock(pin) { onUnlock() } else { incorrect = true; pin = "" }
                    }.disabled(!ConfigurationAccess.validPIN(pin)).accessibilityIdentifier("unlock-configuration")
                } footer: { Text("Enter your PIN to show the saved places.") }
                Section {
                    Button("Forgot PIN?") { confirmReset = true }.accessibilityIdentifier("forgot-configuration-pin")
                }
            }

            .navigationTitle(destinationName).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onCancel { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) } }
            }
            .alert("Remove PIN and show places?", isPresented: $confirmReset) {
                Button("Cancel", role: .cancel) {}
                Button("Remove PIN", role: .destructive) { access.removePIN(); onUnlock() }
            } message: { Text("This will reveal your itinerary. Your places and progress will be kept.") }
        }
    }
}
