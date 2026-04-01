//
//  SettingScreenView.swift
//  player
//
//  Created by nvv on 29/3/26.
//

import SwiftUI
import SwiftData

struct SettingScreenView : View {
    struct LanguageOption: Identifiable, Hashable {
        let code: String
        let displayName: String
        var id: String { code }
    }
    
    private static let languageOptions: [LanguageOption] = {
        let uiLocale = Locale.current
        return Locale.LanguageCode.isoLanguageCodes.map(\.identifier)
            .compactMap { code in
                guard let name = uiLocale.localizedString(forLanguageCode: code) else { return nil }
                return LanguageOption(code: code, displayName: name)
            }
            .sorted { a, b in
                a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            }
    }()
    
    @Environment(\.modelContext) private var modelContext
    @Query private var subtitleSettings: [SubtitleSettings]

    @State private var preferredAudioLanguageCode: String = Locale.current.language.languageCode?.identifier ?? "en"
    
    enum SubtitleColor: String, CaseIterable, Identifiable {
        case white = "White"
        case oledYellow = "OLED Yellow"
        case black = "Black"
        
        var id: String { rawValue }
        
        var color: Color {
            switch self {
            case .white: return .white
            case .oledYellow:
                return Color(.sRGB, red: 1.0, green: 0.87, blue: 0.32, opacity: 1)
            case .black: return .black
            }
        }
    }
    
    @State private var subtitleHasBackground: Bool = true
    @State private var subtitleBoldEnabled: Bool = false
    @State private var enableLibass: Bool = Settings.shared.enableLibass
    
    private let previewBaseText: String = "This is a preview subtitle"
    
    private func languageLabel(for code: String) -> String {
        if let match = Self.languageOptions.first(where: { $0.code == code }) {
            return "\(match.displayName) (\(match.code))"
        }
        let fallbackName = Locale.current.localizedString(forLanguageCode: code) ?? code
        return "\(fallbackName) (\(code))"
    }

    private var subtitleSettingsSignature: String {
        guard let s = subtitleSettings.first else { return "none" }
        return [
            String(format: "%.3f", s.fontSize),
            s.textColor,
            s.backgroundColor,
            s.isBoldEnabled ? "1" : "0",
            String(format: "%.3f", s.position),
            s.preferredLanguage,
            s.isEnabled ? "1" : "0",
        ].joined(separator: "|")
    }

    private func ensureSingleSubtitleSettingsRow() {
        if subtitleSettings.isEmpty {
            modelContext.insert(SubtitleSettings())
            return
        }
        if subtitleSettings.count > 1 {
            for extra in subtitleSettings.dropFirst() {
                modelContext.delete(extra)
            }
        }
    }

    private func saveSettingsNonBlocking() {
        Task { @MainActor in
            do {
                try modelContext.save()
            } catch {
                // Non-blocking best-effort persistence; UI should remain responsive.
            }
        }
    }
    
    var body: some View {
        ZStack {
            AppTheme.Gradient.settingsBackground
                .ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Player Settings")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        
                        Text("Adjust audio & subtitle preferences for your playback.")
                            .font(.system(size: 14, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    
                    // Preview Card
                    previewSection
                        .padding(.horizontal, 20)
                    
                    // Settings sections
                    VStack(spacing: 18) {
                        audioAndLanguageSection
                        Divider().background(Color.white.opacity(0.08))
                        subtitleStyleSection
                    }
                    .padding(18)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(AppTheme.Surface.elevated)
                            .overlay(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .strokeBorder(.white.opacity(0.05), lineWidth: 1)
                            )
                    )
                    .padding(.horizontal, 20)
                    
                    Spacer(minLength: 24)
                }
                .padding(.bottom, 20)
            }
        }
        .onAppear {
            ensureSingleSubtitleSettingsRow()
            syncLegacyPreviewStateFromModel()
            enableLibass = Settings.shared.enableLibass
        }
        .onChange(of: enableLibass) { _, newValue in
            Settings.shared.enableLibass = newValue
        }
        .onChange(of: subtitleHasBackground) { _, newValue in
            subtitleSettings.first?.backgroundColor = newValue ? "Black" : "Clear"
        }
        .onChange(of: subtitleSettingsSignature) { _, _ in
            saveSettingsNonBlocking()
        }
    }
    
    // MARK: - Sections
    
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Preview")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                
                Spacer()
                
                Text("Live preview for subtitle & audio styling")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
            
            ZStack {
                // Fake video frame
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(.sRGB, red: 0.13, green: 0.18, blue: 0.3, opacity: 1),
                                Color(.sRGB, red: 0.05, green: 0.08, blue: 0.17, opacity: 1)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                    )
                    .overlay(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.06),
                                .clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .center
                        )
                        .clipShape(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                    )
                
                // Fake play icon
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 68, height: 68)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                    )
                    .overlay(
                        Image(systemName: "play.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.9))
                    )
                    .offset(y: -28)
                
                // Subtitle preview
                VStack {
                    Spacer()

                    Group {
                        if subtitleSettings.first?.isEnabled ?? true {
                            subtitlePreviewText
                                .padding(.horizontal, 18)
                                .padding(.vertical, 8)
                                .background(
                                    Group {
                                        if subtitleHasBackground {
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(Color.black.opacity(0.55))
                                        } else {
                                            Color.clear
                                        }
                                    }
                                )
                        } else {
                            Text("Subtitles disabled")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.65))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.white.opacity(0.06))
                                )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, previewBottomPadding)
                }
            }
            .frame(height: 210)
        }
    }

    private var previewBottomPadding: CGFloat {
        // Match the on-player behavior conceptually:
        // - Positive values move subtitles up (more bottom padding)
        // - Negative values move subtitles down (less bottom padding), but never below a small floor
        let raw = subtitleSettings.first?.position ?? 0
        let clamped = max(-160.0, min(80.0, raw))
        let preferred = 24.0 + clamped
        return CGFloat(max(8.0, preferred))
    }
    
    private var subtitlePreviewText: some View {
        let s = subtitleSettings.first
        let displayText = previewBaseText

        return Text(displayText)
            .font(
                .system(
                    size: 15 * subtitleSizeMultiplier,
                    weight: (subtitleBoldEnabled || (s?.isBoldEnabled ?? false)) ? .bold : .semibold,
                    design: .rounded
                )
            )
            .foregroundStyle(subtitleColor == .black ? Color.white : subtitleColor.color)
            .shadow(
                color: .black.opacity(0.7),
                radius: 4,
                x: 0,
                y: 2
            )
    }
    
    private var audioAndLanguageSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Language & Audio")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
            
            VStack(spacing: 12) {
                settingRow(
                    title: "Subtitle preference",
                    description: "Preferred subtitle language."
                ) {
                    Menu {
                        ForEach(Self.languageOptions) { lang in
                            Button("\(lang.displayName) (\(lang.code))") {
                                subtitleSettings.first?.preferredLanguage = lang.code
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(languageLabel(for: subtitleSettings.first?.preferredLanguage ?? "en"))
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                    }
                }
                
                settingRow(
                    title: "Audio preference",
                    description: "Preferred audio language."
                ) {
                    Menu {
                        ForEach(Self.languageOptions) { lang in
                            Button("\(lang.displayName) (\(lang.code))") {
                                preferredAudioLanguageCode = lang.code
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(languageLabel(for: preferredAudioLanguageCode))
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                    }
                }
            }
        }
    }
    
    private var subtitleStyleSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Subtitle")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
            
            VStack(spacing: 10) {
                toggleRow(
                    title: "Enable libass (Advanced subtitles)",
                    description: "Use high-quality subtitle rendering with better styling support.",
                    isOn: $enableLibass
                )
            }

            // Size
            settingRow(
                title: "Size",
                description: "Adjust subtitle font size."
            ) {
#if os(tvOS)
                Text("\(subtitleSizeMultiplier, specifier: "%.2f")×")
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: 170, alignment: .trailing)
#else
                Slider(
                    value: Binding(
                        get: { subtitleSizeMultiplier },
                        set: { newValue in subtitleSettings.first?.fontSize = 18.0 * newValue }
                    ),
                    in: 0.7...1.6
                )
                    .tint(.white)
                    .frame(maxWidth: 170)
#endif
            }
            
            // Position
            settingRow(
                title: "Vertical position",
                description: "Move subtitles up or down."
            ) {
#if os(tvOS)
                Text("\(subtitleSettings.first?.position ?? 0.0, specifier: "%.0f")")
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: 170, alignment: .trailing)
#else
                Slider(
                    value: Binding(
                        get: { subtitleSettings.first?.position ?? 0.0 },
                        set: { subtitleSettings.first?.position = $0 }
                    ),
                    in: -160...80
                )
                    .tint(.white)
                    .frame(maxWidth: 170)
#endif
            }
            
            // Color
            settingRow(
                title: "Color",
                description: "Choose subtitle text color."
            ) {
                Menu {
                    ForEach(SubtitleColor.allCases) { color in
                        Button(color.rawValue) { subtitleSettings.first?.textColor = color.rawValue }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text((subtitleSettings.first?.textColor).flatMap(SubtitleColor.init(rawValue:))?.rawValue ?? SubtitleColor.white.rawValue)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                }
            }
            
            // Toggles
            VStack(spacing: 10) {
                toggleRow(
                    title: "Subtitles enabled",
                    description: "Enable or disable subtitle rendering.",
                    isOn: Binding(
                        get: { subtitleSettings.first?.isEnabled ?? true },
                        set: { subtitleSettings.first?.isEnabled = $0 }
                    )
                )

                toggleRow(
                    title: "Subtitle background",
                    description: "Enable background for better readability.",
                    isOn: $subtitleHasBackground
                )
                
                toggleRow(
                    title: "Enable Bold",
                    description: "Render subtitles with bold + drop shadow (OLED-style).",
                    isOn: Binding(
                        get: { subtitleSettings.first?.isBoldEnabled ?? subtitleBoldEnabled },
                        set: { newValue in
                            subtitleBoldEnabled = newValue
                            subtitleSettings.first?.isBoldEnabled = newValue
                            if newValue {
                                // OLED-like look: bold + shadow is best with no box background.
                                subtitleHasBackground = false
                                subtitleSettings.first?.backgroundColor = "Clear"
                            }
                        }
                    )
                )
            }
        }
    }
    
    // MARK: - Reusable Rows
    
    private func settingRow<Content: View>(
        title: String,
        description: String,
        @ViewBuilder control: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                Text(description)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
            
            Spacer()
            
            control()
        }
    }
    
    private func toggleRow(
        title: String,
        description: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                Text(description)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
            
            Spacer()
            
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.white)
        }
    }

    private var subtitleColor: SubtitleColor {
        let raw = subtitleSettings.first?.textColor ?? SubtitleColor.white.rawValue
        return SubtitleColor(rawValue: raw) ?? .white
    }

    private var subtitleSizeMultiplier: Double {
        let points = subtitleSettings.first?.fontSize ?? 18.0
        return max(0.7, min(1.6, points / 18.0))
    }

    private func syncLegacyPreviewStateFromModel() {
        subtitleHasBackground = (subtitleSettings.first?.backgroundColor ?? "Black") != "Clear"
        subtitleBoldEnabled = subtitleSettings.first?.isBoldEnabled ?? false
    }
}
