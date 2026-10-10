import Foundation

/// 与 Swift 版本和数值类型无关的展示格式化助手。
/// 原工程大量使用 `Text(value, format: .currency(code: "CNY"))` 等 FormatStyle 写法，
/// 在 CI 所用的 Swift 版本上，对 Decimal 或带标签的字符串插值无法推断基类型而编译失败。
/// 这里改用 NumberFormatter 实现，Double / Decimal / Int 均可直接调用，行为保持一致。
extension BinaryFloatingPoint {
    func cny(_ digits: Int = 2) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "CNY"
        nf.locale = Locale(identifier: "zh_CN")
        nf.minimumFractionDigits = digits
        nf.maximumFractionDigits = digits
        return nf.string(from: NSNumber(value: Double(self))) ?? String(format: "%.*f", digits, Double(self))
    }

    func num(_ digits: Int) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.locale = Locale(identifier: "zh_CN")
        nf.minimumFractionDigits = digits
        nf.maximumFractionDigits = digits
        return nf.string(from: NSNumber(value: Double(self))) ?? String(format: "%.*f", digits, Double(self))
    }

    func pct(_ digits: Int) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .percent
        nf.locale = Locale(identifier: "zh_CN")
        nf.minimumFractionDigits = digits
        nf.maximumFractionDigits = digits
        return nf.string(from: NSNumber(value: Double(self))) ?? String(format: "%.*f", digits, Double(self) * 100)
    }
}

extension Decimal {
    func cny(_ digits: Int = 2) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "CNY"
        nf.locale = Locale(identifier: "zh_CN")
        nf.minimumFractionDigits = digits
        nf.maximumFractionDigits = digits
        return nf.string(from: self as NSDecimalNumber) ?? "\(self)"
    }

    func num(_ digits: Int) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.locale = Locale(identifier: "zh_CN")
        nf.minimumFractionDigits = digits
        nf.maximumFractionDigits = digits
        return nf.string(from: self as NSDecimalNumber) ?? "\(self)"
    }

    func pct(_ digits: Int) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .percent
        nf.locale = Locale(identifier: "zh_CN")
        nf.minimumFractionDigits = digits
        nf.maximumFractionDigits = digits
        return nf.string(from: self as NSDecimalNumber) ?? "\(self)"
    }
}

extension Int {
    func cny(_ digits: Int = 2) -> String { Double(self).cny(digits) }
    func num(_ digits: Int) -> String { Double(self).num(digits) }
    func pct(_ digits: Int) -> String { Double(self).pct(digits) }
}
