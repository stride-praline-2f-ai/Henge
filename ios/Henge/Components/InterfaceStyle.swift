import SwiftUI
import UIKit

enum Desk {
    static let page = tone(light: (242, 243, 247), dark: (11, 12, 16))
    static let card = tone(light: (255, 255, 255), dark: (22, 24, 31))
    static let raised = tone(light: (228, 230, 236), dark: (35, 38, 47))
    static let text = tone(light: (17, 19, 24), dark: (242, 243, 247))
    static let dim = tone(light: (92, 97, 112), dark: (144, 149, 164))
    static let faint = tone(light: (138, 143, 157), dark: (106, 111, 126))
    static let accent = Color(red: 46 / 255, green: 107 / 255, blue: 1)
    /// Blue for tints and text: lighter on the dark page, deeper on the light one.
    static let accentLight = tone(light: (31, 91, 235), dark: (91, 141, 255))
    static let good = tone(light: (20, 145, 90), dark: (57, 217, 138))
    static let warn = tone(light: (184, 119, 0), dark: (255, 188, 46))
    static let bad = tone(light: (210, 56, 43), dark: (255, 122, 112))
    static let hairline = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.1) : UIColor(white: 0, alpha: 0.1) })

    private static func tone(light: (Int, Int, Int), dark: (Int, Int, Int)) -> Color {
        func ui(_ c: (Int, Int, Int)) -> UIColor {
            UIColor(red: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
        }
        let l = ui(light), d = ui(dark)
        return Color(UIColor { $0.userInterfaceStyle == .dark ? d : l })
    }
}
