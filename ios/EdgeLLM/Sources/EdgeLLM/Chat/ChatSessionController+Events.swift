import Foundation

extension ChatSessionController {
    func emitState() {
        switch state {
        case .modelRequired:
            let asset = requiredAsset ?? .languageModel
            emit(
                type: "model_required",
                code: asset.requiredCode,
                message: asset.requiredMessage
            )
        case .loading:
            emit(type: "loading")
        case .ready:
            emit(type: "ready")
        case .generating:
            emit(type: "generating", requestId: activeRequestId)
        case .failed:
            emitError(
                code: "runtime_failed",
                message: "The native chat runtime must be initialized again."
            )
        }
    }

    func emit(
        type: String,
        requestId: String? = nil,
        text: String? = nil,
        code: String? = nil,
        message: String? = nil,
        homeSteps: HomeStepObservation? = nil,
        presentation: ChatReplyPresentation? = nil,
        worldInfoAutomation: [String]? = nil,
        recentEntries: [NativeRestoredDialogueEntry]? = nil,
        diary: NativeDiaryEntry? = nil,
        diaries: [NativeDiaryEntry]? = nil
    ) {
        eventSink(
            NativeChatEvent(
                type: type,
                requestId: requestId ?? NativePreparationContext.requestID,
                text: text,
                code: code,
                message: message,
                homeSteps: homeSteps,
                presentation: presentation,
                worldInfoAutomation: worldInfoAutomation,
                recentEntries: recentEntries,
                diary: diary,
                diaries: diaries
            )
        )
    }

    func emitError(
        code: String,
        message: String,
        requestId: String? = nil
    ) {
        emit(
            type: "error",
            requestId: requestId,
            code: code,
            message: message
        )
    }
}
