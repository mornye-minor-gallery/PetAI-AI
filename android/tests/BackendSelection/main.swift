import Foundation

let gpu = AndroidEngineProfile(backend: "gpu")
let cpu = AndroidEngineProfile(backend: "cpu")
precondition(gpu.supports("gpu"))
precondition(gpu.supports("cpu"))
precondition(cpu.supports("cpu"))
precondition(!cpu.supports("gpu"))
precondition(!gpu.supports("auto"))
precondition(!AndroidEngineProfile(backend: "unknown").supports("cpu"))
print("Backend capability checks passed (6).")
