import Foundation
func sample(_ r: Double, _ g: Double, _ b: Double, _ count: Int) -> ArtworkPalette.Sample {
    .init(color: .init(red: r, green: g, blue: b), count: count)
}
precondition(ArtworkPalette.colors(from: []).isEmpty)
precondition(ArtworkPalette.colors(from: [sample(255, 0, 0, 80), sample(0, 0, 255, 15), sample(0, 255, 0, 5)]).count == 1)
precondition(ArtworkPalette.colors(from: [sample(255, 0, 0, 40), sample(0, 0, 255, 35), sample(0, 255, 0, 25)]).count == 3)
precondition(ArtworkPalette.colors(from: [sample(255, 0, 0, 45), sample(0, 0, 255, 40), sample(0, 255, 0, 15)]).count == 2)
precondition(ArtworkPalette.colors(from: [sample(120, 90, 170, 40), sample(125, 95, 175, 35), sample(0, 0, 0, 25)]).count == 2)
precondition(ArtworkPalette.colors(from: [sample(0, 0, 0, 100)]).first == .init(red: 0, green: 0, blue: 0))
let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures.json")
let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
for row in rows {
    let bins = row["bins"] as! [[Double]]
    let colors = ArtworkPalette.colors(from: bins.map { sample($0[0], $0[1], $0[2], Int($0[3])) })
    precondition((1...3).contains(colors.count))
    print("\(row["artist"]!): \(colors.count) color(s)")
}
print("Palette checks passed")

func luminance(_ color: ArtworkPalette.RGB) -> Double {
    let values = color.components.map { v -> Double in
        let c = v / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return zip(values, [0.2126, 0.7152, 0.0722]).reduce(0) { $0 + $1.0 * $1.1 }
}
let black = ArtworkPalette.RGB(red: 0, green: 0, blue: 0)
let white = ArtworkPalette.RGB(red: 255, green: 255, blue: 255)
let yellow = ArtworkPalette.RGB(red: 255, green: 255, blue: 0)
let red = ArtworkPalette.RGB(red: 255, green: 0, blue: 0)
let blue = ArtworkPalette.RGB(red: 0, green: 0, blue: 255)
for palette in [[black, white], [white, black], [yellow, black], [black, yellow], [yellow], [white], [red, blue, yellow]] {
    let stops = ArtworkPalette.backgroundStops(from: palette)
    precondition(stops.count >= 2)
    for a in stops {
        precondition((1.05 / (luminance(a) + 0.05)) >= 7, "White text must remain readable")
        for b in stops {
            let contrast = (max(luminance(a), luminance(b)) + 0.05) / (min(luminance(a), luminance(b)) + 0.05)
            precondition(contrast <= 1.701, "Gradient stops must not have a large brightness jump")
        }
    }
}
print("Gradient contrast checks passed: black/white, yellow/black, single colours, opposing hues")

let brightColors: [ArtworkPalette.RGB] = [white, yellow, .init(red: 0, green: 255, blue: 0),
    .init(red: 0, green: 255, blue: 255), .init(red: 255, green: 0, blue: 255)]
let secondaryLuminance = luminance(ArtworkPalette.secondaryText)
for bright in brightColors {
    let stops = ArtworkPalette.backgroundStops(from: [bright, black, red])
    for pair in zip(stops, stops.dropFirst()) {
        for step in 0...20 {
            let t = Double(step) / 20
            let values = zip(pair.0.components, pair.1.components).map { $0 + ($1 - $0) * t }
            let l = luminance(.init(red: values[0], green: values[1], blue: values[2]))
            precondition((secondaryLuminance + 0.05) / (l + 0.05) >= 4.5 - 0.00001,
                         "Secondary text must stay readable along the whole gradient")
            precondition(1.05 / (l + 0.05) >= 7)
        }
    }
}
print("Readability checks passed for bright white, yellow, green, cyan and magenta, including interpolated stops")
