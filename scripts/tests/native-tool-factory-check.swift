import Foundation
import LiteRTLM

private enum NativeToolFactoryCheckError: Error {
    case invalidSchema(NativeToolGenerationKind)
}

@main
struct NativeToolFactoryCheck {
    static func main() throws {
        for kind in NativeToolGenerationKind.allCases {
            let tool = LiteRTLMNativeToolFactory.makeTool(for: kind)
            let schema = tool.getSchema()
            guard let function = schema["function"] as? [String: Any],
                  function["name"] as? String == kind.rawValue,
                  let parameters = function["parameters"] as? [String: Any],
                  let properties = parameters["properties"] as? [String: Any],
                  !properties.isEmpty,
                  let required = parameters["required"] as? [String],
                  !required.isEmpty,
                  Set(required).isSubset(of: Set(properties.keys))
            else {
                throw NativeToolFactoryCheckError.invalidSchema(kind)
            }
        }
        print("Production native tool factory: \(NativeToolGenerationKind.allCases.count) schemas passed")
    }
}
