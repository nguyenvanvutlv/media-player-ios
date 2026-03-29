import SwiftUI

enum AppTheme {
    enum Gradient {
        static let primaryBackground = LinearGradient(
            colors: [
                Color(.sRGB, red: 8/255, green: 11/255, blue: 23/255, opacity: 1),
                Color(.sRGB, red: 18/255, green: 24/255, blue: 48/255, opacity: 1)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        
        static let settingsBackground = LinearGradient(
            colors: [
                Color(.sRGB, red: 3/255, green: 7/255, blue: 20/255, opacity: 1),
                Color(.sRGB, red: 18/255, green: 25/255, blue: 50/255, opacity: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        
        static let accentButton = LinearGradient(
            colors: [
                Color(.sRGB, red: 0.98, green: 0.86, blue: 0.23, opacity: 1),
                Color(.sRGB, red: 0.99, green: 0.63, blue: 0.12, opacity: 1)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    enum Surface {
        static let elevated = LinearGradient(
            colors: [
                Color.white.opacity(0.06),
                Color.white.opacity(0.02)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

