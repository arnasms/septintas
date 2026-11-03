import Foundation

/// The same perceptual grouping and selection used by the music gradient preview.
enum ArtworkPalette {
    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double
        var components: [Double] { [red, green, blue] }
    }
    struct Sample {
        var color: RGB
        var count: Int
    }
    /// Shared with the music widget so its readability limit follows the actual label colour.
    static let secondaryText = RGB(red: 0.631 * 255, green: 0.631 * 255, blue: 0.651 * 255)
    private static var maximumBackgroundLuminance: Double {
        // Tone bright colours down: preserve 7:1 for white and 4.5:1 for secondary text.
        min(1.05 / 7 - 0.05, (luminance(secondaryText) + 0.05) / 4.5 - 0.05)
    }

    private struct Group {
        var color: RGB
        var count: Int
        var lab: [Double]
    }

    static func colors(from samples: [Sample]) -> [RGB] {
        var groups: [Group] = []
        let total = samples.reduce(0) { $0 + max(0, $1.count) }
        guard total > 0 else { return [] }
        for sample in samples.filter({ $0.count > 0 }).sorted(by: { $0.count > $1.count }) {
            let group = Group(color: sample.color, count: sample.count, lab: lab(sample.color))
            var closest: Int?
            var best = 25.0
            for index in groups.indices {
                let delta = distance(group.lab, groups[index].lab)
                if delta < best { best = delta; closest = index }
            }
            if let closest { groups[closest] = merge(groups[closest], group) }
            else { groups.append(group) }
        }
        while true {
            var pair: (Int, Int)?
            var best = 25.0
            for i in groups.indices {
                for j in (i + 1)..<groups.count {
                    let delta = distance(groups[i].lab, groups[j].lab)
                    if delta < best { best = delta; pair = (i, j) }
                }
            }
            guard let (i, j) = pair else { break }
            groups[i] = merge(groups[i], groups[j])
            groups.remove(at: j)
        }
        groups.sort { $0.count > $1.count }
        if groups.count > 1, Double(groups[0].count) / Double(groups[1].count) >= 3.25 {
            return [groups[0].color]
        }
        let qualifying = groups.filter { Double($0.count) / Double(total) >= 0.24 }
        return (qualifying.isEmpty ? Array(groups.prefix(1)) : Array(qualifying.prefix(3))).map { $0.color }
    }

    /// Match the preview's 68% colour strength over its #0C0C0C dark base.
    static func backgroundColor(_ color: RGB) -> RGB {
        RGB(red: (12 + (color.red - 12) * 0.68).rounded(),
            green: (12 + (color.green - 12) * 0.68).rounded(),
            blue: (12 + (color.blue - 12) * 0.68).rounded())
    }

    /// Keep every stop close to every other stop, regardless of hue or brightness.
    /// Artwork selection stays unchanged; only the displayed gradient is softened.
    static func backgroundStops(from colors: [RGB]) -> [RGB] {
        guard let first = colors.first else { return [] }
        func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
            RGB(red: a.red + (b.red - a.red) * t, green: a.green + (b.green - a.green) * t,
                blue: a.blue + (b.blue - a.blue) * t)
        }
        func darken(_ color: RGB) -> RGB {
            guard luminance(color) > maximumBackgroundLuminance else { return color }
            var low = 0.0, high = 1.0
            for _ in 0..<24 {
                let t = (low + high) / 2
                if luminance(mix(RGB(red: 0, green: 0, blue: 0), color, t)) <= maximumBackgroundLuminance { low = t }
                else { high = t }
            }
            return mix(RGB(red: 0, green: 0, blue: 0), color, low)
        }
        let anchor = darken(backgroundColor(first))
        var candidates = colors.dropFirst().map { darken(backgroundColor($0)) }
        if candidates.isEmpty {
            // A single-colour cover gets a nearby shade, never a fixed black endpoint.
            candidates = [RGB(red: anchor.red * 0.8, green: anchor.green * 0.8, blue: anchor.blue * 0.8)]
        }
        var stops = [anchor]
        for candidate in candidates {
            func acceptable(_ color: RGB) -> Bool {
                stops.allSatisfy { distance(lab($0), lab(color)) <= 18 && abs(luminance($0) - luminance(color)) <= 0.035 }
            }
            if acceptable(candidate) { stops.append(candidate); continue }
            var low = 0.0, high = 1.0
            for _ in 0..<24 {
                let t = (low + high) / 2
                if acceptable(mix(anchor, candidate, t)) { low = t }
                else { high = t }
            }
            stops.append(mix(anchor, candidate, low))
        }
        return stops
    }

    private static func luminance(_ color: RGB) -> Double {
        let c = color.components.map { value -> Double in
            let v = value / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return c[0] * 0.2126 + c[1] * 0.7152 + c[2] * 0.0722
    }

    private static func merge(_ a: Group, _ b: Group) -> Group {
        let count = a.count + b.count
        let values = zip(a.color.components, b.color.components).map { ($0 * Double(a.count) + $1 * Double(b.count)) / Double(count) }
        let color = RGB(red: values[0], green: values[1], blue: values[2])
        return Group(color: color, count: count, lab: lab(color))
    }
    private static func distance(_ a: [Double], _ b: [Double]) -> Double {
        sqrt(zip(a, b).reduce(0) { $0 + pow($1.0 - $1.1, 2) })
    }
    private static func lab(_ color: RGB) -> [Double] {
        let c = color.components.map { value -> Double in
            let v = value / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        func f(_ v: Double) -> Double { v > 0.008856 ? cbrt(v) : 7.787 * v + 16.0 / 116 }
        let x = f((c[0] * 0.4124 + c[1] * 0.3576 + c[2] * 0.1805) / 0.95047)
        let y = f(c[0] * 0.2126 + c[1] * 0.7152 + c[2] * 0.0722)
        let z = f((c[0] * 0.0193 + c[1] * 0.1192 + c[2] * 0.9505) / 1.08883)
        return [116 * y - 16, 500 * (x - y), 200 * (y - z)]
    }
}
