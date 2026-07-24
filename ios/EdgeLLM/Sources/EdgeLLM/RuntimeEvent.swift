public enum RuntimeEvent: Equatable, Sendable {
    case stateChanged(RuntimeState)
    case textDelta(String)
    case completed
    case failed(RuntimeError)
}
