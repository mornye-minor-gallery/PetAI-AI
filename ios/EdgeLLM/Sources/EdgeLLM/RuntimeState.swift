public enum RuntimeState: Equatable, Sendable {
    case modelRequired
    case preparingModel
    case ready
    case generating
    case failed(message: String)
}
