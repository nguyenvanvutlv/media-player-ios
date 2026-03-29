import Foundation
import SwiftData

@Model
final class SubtitleSettings {
    /// Stored as a point size (e.g. 18, 24).
    var fontSize: Double
    /// Color name (e.g. "White", "OLED Yellow", "Black").
    var textColor: String
    /// Color name for subtitle background (e.g. "Black", "Clear").
    var backgroundColor: String
    /// Positive values move subtitles up (adds bottom padding).
    var position: Double
    var preferredLanguage: String
    var isEnabled: Bool

    init(
        fontSize: Double = 18.0,
        textColor: String = "White",
        backgroundColor: String = "Black",
        position: Double = 0.0,
        preferredLanguage: String = Locale.current.language.languageCode?.identifier ?? "en",
        isEnabled: Bool = true
    ) {
        self.fontSize = fontSize
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.position = position
        self.preferredLanguage = preferredLanguage
        self.isEnabled = isEnabled
    }
}

