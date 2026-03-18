// Vendored from zollans/OnlyEQ @ 6569655 (Unlicense), trimmed for eq.
import Foundation

enum FilterType: String, Codable, CaseIterable {
    case peak, lowShelf, highShelf, lowPass, highPass, notch, bandPass
}

struct EQBand: Codable, Equatable {
    var type: FilterType = .peak
    var frequency: Double = 1000
    var gain: Double = 0
    var q: Double = 1.41
    var isEnabled = true
}
