import Foundation

private struct ValidationRow: Codable {
    let caseID: String
    let arm: String
    let swiftParsePass: Bool
    let swiftValidationPass: Bool
    let validationError: String?

    enum CodingKeys: String, CodingKey {
        case caseID = "case_id"
        case arm
        case swiftParsePass = "swift_parse_pass"
        case swiftValidationPass = "swift_validation_pass"
        case validationError = "validation_error"
    }
}

@main
private struct ValidatePredictions {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            FileHandle.standardError.write(
                Data("usage: validate-predictions INPUT OUTPUT\n".utf8)
            )
            Foundation.exit(2)
        }
        let input = try String(
            contentsOfFile: CommandLine.arguments[1],
            encoding: .utf8
        )
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = calendar.date(
            from: DateComponents(
                year: 2026, month: 8, day: 13, hour: 21, minute: 0
            )
        )!
        let parser = NativeToolProposalParser()
        let validator = NativeToolProposalValidator(now: now, calendar: calendar)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for line in input.split(separator: "\n") {
            let data = Data(line.utf8)
            guard
                let object = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                let caseID = object["case_id"] as? String,
                let arm = object["arm"] as? String,
                let rawTool = object["selected_tool"] as? String,
                let tool = NativeToolKind(rawValue: rawTool)
            else {
                continue
            }
            let calls = object["function_calls"] as? [[String: Any]] ?? []
            guard let call = calls.first,
                  let name = call["name"] as? String,
                  let arguments = call["arguments"] as? [String: Any]
            else {
                let row = ValidationRow(
                    caseID: caseID,
                    arm: arm,
                    swiftParsePass: false,
                    swiftValidationPass: false,
                    validationError: "no_call"
                )
                try output.write(encoder.encode(row) + Data("\n".utf8))
                continue
            }

            do {
                let argumentData = try JSONSerialization.data(
                    withJSONObject: arguments,
                    options: [.sortedKeys]
                )
                let proposal = try parser.parse(
                    NativeToolFunctionCall(
                        name: name,
                        argumentsJSON: argumentData
                    ),
                    selectedTool: tool,
                    requestID: caseID
                )
                do {
                    _ = try validator.validate(proposal)
                    let row = ValidationRow(
                        caseID: caseID,
                        arm: arm,
                        swiftParsePass: true,
                        swiftValidationPass: true,
                        validationError: nil
                    )
                    try output.write(encoder.encode(row) + Data("\n".utf8))
                } catch {
                    let row = ValidationRow(
                        caseID: caseID,
                        arm: arm,
                        swiftParsePass: true,
                        swiftValidationPass: false,
                        validationError: String(describing: error)
                    )
                    try output.write(encoder.encode(row) + Data("\n".utf8))
                }
            } catch {
                let row = ValidationRow(
                    caseID: caseID,
                    arm: arm,
                    swiftParsePass: false,
                    swiftValidationPass: false,
                    validationError: String(describing: error)
                )
                try output.write(encoder.encode(row) + Data("\n".utf8))
            }
        }
    }
}
