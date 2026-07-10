import Cocoa

enum AppLanguage: String, CaseIterable {
    case system, korean, english

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .system
    }

    static var usesKorean: Bool {
        switch current {
        case .system:
            return Locale.preferredLanguages.first?.lowercased().hasPrefix("ko") == true
        case .korean:
            return true
        case .english:
            return false
        }
    }

    var label: String {
        switch self {
        case .system: return appText("시스템 언어", "System language")
        case .korean: return appText("한국어", "Korean")
        case .english: return appText("영어", "English")
        }
    }
}

func appText(_ ko: String, _ en: String) -> String {
    AppLanguage.usesKorean ? ko : en
}

func countText(_ count: Int, _ koUnit: String, _ enSingular: String, _ enPlural: String) -> String {
    if AppLanguage.usesKorean {
        return "\(count)\(koUnit)"
    }
    return "\(count) \(count == 1 ? enSingular : enPlural)"
}

enum SpeedDriver: String, CaseIterable {
    case busiest, cpu, gpu, memory

    var label: String {
        switch self {
        case .busiest: return appText("가장 바쁜 쪽", "Busiest")
        case .cpu: return appText("CPU 사용률", "CPU usage")
        case .gpu: return appText("GPU 연산 부하", "GPU compute load")
        case .memory: return appText("메모리 사용률", "Memory usage")
        }
    }

    func value(_ metrics: Metrics) -> Double {
        switch self {
        case .busiest: return max(metrics.cpu, metrics.gpuAvailable ? metrics.gpuCompute : 0)
        case .cpu: return metrics.cpu
        case .gpu: return metrics.gpuAvailable ? metrics.gpuCompute : 0
        case .memory: return metrics.memory
        }
    }
}

enum CatColor: String, CaseIterable {
    case auto, white, black

    var label: String {
        switch self {
        case .auto: return appText("자동 (메뉴바에 맞춤)", "Auto (match menu bar)")
        case .white: return appText("흰색", "White")
        case .black: return appText("검정", "Black")
        }
    }
}

enum MeterColor: String, CaseIterable {
    case graphite, accent, blue, green, orange, purple

    var label: String {
        switch self {
        case .graphite: return appText("흑연", "Graphite")
        case .accent: return appText("시스템 강조색", "System accent")
        case .blue: return appText("파랑", "Blue")
        case .green: return appText("초록", "Green")
        case .orange: return appText("주황", "Orange")
        case .purple: return appText("보라", "Purple")
        }
    }

    var color: NSColor {
        switch self {
        case .graphite: return .systemGray
        case .accent: return .controlAccentColor
        case .blue: return .systemBlue
        case .green: return .systemGreen
        case .orange: return .systemOrange
        case .purple: return .systemPurple
        }
    }
}

enum StatusTextMode: String, CaseIterable {
    case off, driver, cpu, gpu, memory, temperature, thermal

    var label: String {
        switch self {
        case .off: return appText("표시 안 함", "Hidden")
        case .driver: return appText("고양이 속도 %", "Cat speed %")
        case .cpu: return "CPU %"
        case .gpu: return appText("GPU 연산 %", "GPU compute %")
        case .memory: return appText("메모리 %", "Memory %")
        case .temperature: return appText("최고 센서 온도", "Hottest sensor temperature")
        case .thermal: return appText("열 압박", "Thermal pressure")
        }
    }
}

final class SpeedStatusRowView: NSView {
    private let textField = NSTextField(labelWithString: "")

    init(_ title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 190, height: 20))
        textField.font = .menuFont(ofSize: 11)
        textField.textColor = .secondaryLabelColor
        textField.lineBreakMode = .byTruncatingTail
        textField.maximumNumberOfLines = 1
        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        update(title)
    }

    func update(_ title: String) {
        textField.stringValue = title
        let font = textField.font ?? .menuFont(ofSize: 11)
        let width = min(210, max(150, (title as NSString).size(withAttributes: [.font: font]).width + 26))
        setFrameSize(NSSize(width: width, height: 20))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

final class StatusContainerView: NSView {
    var onDisplayPropertiesChanged: (() -> Void)?

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onDisplayPropertiesChanged?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onDisplayPropertiesChanged?()
    }
}
