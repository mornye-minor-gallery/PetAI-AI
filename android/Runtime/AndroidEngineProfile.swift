import Foundation

/// The build profile describes packaged capabilities, not the user's selected backend.
/// GPU distributions contain both CPU and GPU execution support.
struct AndroidEngineProfile: Decodable {
    let backend: String

    func supports(_ requested: String) -> Bool {
        switch (backend, requested) {
        case ("cpu", "cpu"), ("gpu", "cpu"), ("gpu", "gpu"): true
        default: false
        }
    }
}
