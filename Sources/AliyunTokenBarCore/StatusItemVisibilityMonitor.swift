public struct StatusItemVisibilityMonitor {
    private let requiredHiddenSamples: Int
    private var hiddenSamples = 0
    private var didNotify = false

    public init(requiredHiddenSamples: Int) {
        self.requiredHiddenSamples = max(1, requiredHiddenSamples)
    }

    public mutating func record(isVisible: Bool) -> Bool {
        guard !didNotify else { return false }
        if isVisible {
            hiddenSamples = 0
            return false
        }

        hiddenSamples += 1
        guard hiddenSamples >= requiredHiddenSamples else { return false }
        didNotify = true
        return true
    }
}
