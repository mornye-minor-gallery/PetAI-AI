import Foundation

extension ChatSessionController {
    func handleNativeToolIfNeeded(
        requestID: String,
        userMessage: String,
        accessPolicy: NativeToolAccessPolicy
    ) async -> Bool {
        guard let nativeToolRouter else {
            return false
        }
        let harness = NativeToolProposalHarness(
            router: nativeToolRouter,
            validator: NativeToolProposalValidator(),
            coordinator: nativeToolCoordinator,
            generator: runtime,
            configuration: slmConfiguration
        )

        do {
            let outcome = try await harness.prepare(
                requestID: requestID,
                userMessage: userMessage,
                promptContext: NativeToolPromptContext(
                    now: Date(),
                    calendar: .current
                ),
                allowedTools: accessPolicy.allowedTools,
                supportedTools: nativeToolAdapterHub.supportedTools
            )
            switch outcome {
            case .unsupported:
                await finishFailedRequest(requestID, code: "platform_unsupported",
                    message: nativeToolAdapterHub.unsupportedMessage)
                return true
            case .normal:
                if cancelRequested {
                    await finishCancelledRequest(requestID)
                    return true
                }
                return false

            case .conflict(let message, _):
                await finishNativeToolRequest(
                    requestID: requestID,
                    visibleText: message
                )
                return true

            case .locked(let tool):
                let source = accessPolicy.unlockSource(for: tool)
                let message = source.map {
                    "방꾸미기에서 \($0) 가구를 배치하고 저장하면 이 기능을 사용할 수 있어."
                } ?? "이 기능은 아직 해금되지 않았어."
                await finishNativeToolRequest(
                    requestID: requestID,
                    visibleText: message
                )
                return true

            case .clarification(let message):
                await finishNativeToolRequest(
                    requestID: requestID,
                    visibleText: message
                )
                return true

            case .proposal(let draft, _, _):
                _ = try await nativeToolCoordinator.beginConfirmation(
                    requestID: requestID
                )
                let editedDraft = try await
                    nativeToolAdapterHub.confirm(draft)
                guard activeRequestId == requestID, !cancelRequested else {
                    throw NativeToolConfirmationError.cancelled
                }
                let confirmed = try NativeToolProposalValidator()
                    .validate(editedDraft)
                let envelope = try await nativeToolCoordinator
                    .approveAndExecute(confirmed)

                if envelope.status == .success {
                    let formatter = NativeToolResultFormatter()
                    let visibleText: String
                    do {
                        visibleText = try formatter.visibleText(for: envelope)
                    } catch {
                        // The OS side effect is committed. A display error must not turn
                        // it into an execution failure or invite a duplicate retry.
                        logger.error("native_tool_result_format_failed tool=\(envelope.tool.rawValue) error=\(error)")
                        visibleText = formatter.unformattedSuccessText(for: envelope.tool)
                    }
                    await finishNativeToolRequest(
                        requestID: requestID,
                        visibleText: visibleText,
                        homeSteps: HomeStepObservation.make(
                            envelope: envelope, proposal: confirmed
                        ),
                        committedTool: true
                    )
                } else {
                    await finishNativeToolFailure(
                        requestID: requestID,
                        code: envelope.errorCode ?? .nativeFailure,
                        message: try NativeToolResultFormatter()
                            .visibleText(for: envelope)
                    )
                }
                try? await nativeToolCoordinator.removeFinished(
                    requestID: requestID
                )
                return true
            }
        } catch let error as NativeToolRoutingError {
            logger.error(
                "Native Tool routing failed closed to chat request=\(requestID) error=\(error.localizedDescription)"
            )
            return false
        } catch NativeToolConfirmationError.cancelled, RuntimeError.generationCancelled {
            _ = try? await nativeToolCoordinator.cancel(
                requestID: requestID
            )
            try? await nativeToolCoordinator.removeFinished(
                requestID: requestID
            )
            await finishCancelledRequest(requestID)
            return true
        } catch let error as NativeToolValidationError {
            _ = try? await nativeToolCoordinator.cancel(
                requestID: requestID
            )
            try? await nativeToolCoordinator.removeFinished(
                requestID: requestID
            )
            await finishNativeToolFailure(
                requestID: requestID,
                code: error.code
            )
            return true
        } catch {
            _ = try? await nativeToolCoordinator.cancel(
                requestID: requestID
            )
            try? await nativeToolCoordinator.removeFinished(
                requestID: requestID
            )
            await finishNativeToolFailure(
                requestID: requestID,
                code: .nativeFailure
            )
            logger.error(
                "Native tool proposal failed request=\(requestID) error=\(error.localizedDescription)"
            )
            return true
        }
    }

    func finishNativeToolRequest(
        requestID: String,
        visibleText: String,
        homeSteps: HomeStepObservation? = nil,
        committedTool: Bool = false
    ) async {
        guard activeRequestId == requestID else { return }
        guard committedTool || !cancelRequested else { await finishCancelledRequest(requestID); return }
        // Once a tool has executed successfully, a late cancel cannot undo its side effect.
        emitVisibleAnswer(visibleText, requestID: requestID, allowAfterCancel: committedTool)
        do {
            try await finishCompletedRequest(requestID, visibleText: visibleText,
                homeSteps: homeSteps, allowAfterCancel: committedTool, presentation: .tool)
        } catch {
            logger.error("Could not complete native tool chat turn request=\(requestID) error=\(error.localizedDescription)")
            await finishFailedRequest(requestID, code: "chat_turn_state_failed", message: "대화 상태를 기록하지 못했습니다.")
        }
    }

    func finishNativeToolFailure(
        requestID: String,
        code: NativeToolErrorCode,
        message: String = "요청을 처리하지 못했어요. 다시 시도해 주세요."
    ) async {
        guard activeRequestId == requestID else { return }
        await finishFailedRequest(requestID,
            code: code.rawValue,
            message: message)
    }

}
