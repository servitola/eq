public struct Rect: Equatable {
    public var x, y, width, height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = max(width, 0)
        self.height = max(height, 0)
    }

    public var isEmpty: Bool { width == 0 || height == 0 }
    public var bottom: Int { y + height }
    public var right: Int { x + width }

    public func intersection(_ other: Rect) -> Rect {
        let left = max(x, other.x), top = max(y, other.y)
        return Rect(x: left, y: top, width: min(right, other.right) - left, height: min(bottom, other.bottom) - top)
    }

    public func inset(by n: Int) -> Rect {
        Rect(x: x + n, y: y + n, width: width - 2 * n, height: height - 2 * n)
    }

    public func contains(x px: Int, y py: Int) -> Bool { (x..<right).contains(px) && (y..<bottom).contains(py) }

    public func row(_ i: Int) -> Rect { Rect(x: x, y: y + i, width: width, height: i < height ? 1 : 0) }

    /// A `width`×`height` box in the middle, shrunk to fit.
    public func centered(width w: Int, height h: Int) -> Rect {
        let cw = min(w, width), ch = min(h, height)
        return Rect(x: x + (width - cw) / 2, y: y + (height - ch) / 2, width: cw, height: ch)
    }

    public enum Axis { case vertical, horizontal }

    /// One pass, no solver: fixed and percent first, then each min, then what is left by weight
    /// over the fills (over the mins when there are none). Too little room takes from the end.
    public func split(_ axis: Axis, _ constraints: [Constraint]) -> [Rect] {
        let total = axis == .vertical ? height : width
        var sizes = constraints.map { c -> Int in
            switch c {
            case .fixed(let n), .min(let n): return max(n, 0)
            case .percent(let p): return total * min(max(p, 0), 100) / 100
            case .fill: return 0
            }
        }
        var left = total - sizes.reduce(0, +)
        if left < 0 {
            for i in sizes.indices.reversed() where left < 0 {
                let cut = min(sizes[i], -left)
                sizes[i] -= cut
                left += cut
            }
        }
        let fills = constraints.indices.compactMap { i -> (Int, Int)? in
            if case .fill(let w) = constraints[i] { return (i, max(w, 1)) }
            return nil
        }
        let growing = fills.isEmpty ? constraints.indices.compactMap { i -> (Int, Int)? in
            if case .min = constraints[i] { return (i, 1) }
            return nil
        } : fills
        let weight = growing.reduce(0) { $0 + $1.1 }
        if left > 0, weight > 0 {
            var given = 0
            for (n, (i, w)) in growing.enumerated() {
                let share = n == growing.count - 1 ? left - given : left * w / weight
                sizes[i] += share
                given += share
            }
        }
        var offset = axis == .vertical ? y : x
        return sizes.map { size in
            defer { offset += size }
            return axis == .vertical ? Rect(x: x, y: offset, width: width, height: size)
                : Rect(x: offset, y: y, width: size, height: height)
        }
    }
}

public enum Constraint: Equatable {
    case fixed(Int), min(Int), fill(Int), percent(Int)
}
