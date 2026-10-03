import Testing

@testable import EdgeLLM

@Test
func koreanRouterSelectsEverySupportedTool() {
    let router = KoreanNativeToolRouter()
    let cases: [(String, NativeToolKind)] = [
        ("오늘 몇 걸음 걸었어?", .getStepCount),
        ("내일 아침 7시에 운동 알람 맞춰 줘", .createAlarm),
        ("내 알람 목록 보여 줘", .listAlarms),
        ("10분 타이머 시작해 줘", .createTimer),
        ("오후 3시에 물 마시라고 알려 줘", .scheduleLocalNotification),
        ("내일 일정 알려 줘", .getCalendarEvents),
        ("내일 3시에 멘토링 일정 잡아 줘", .createCalendarEvent),
    ]

    for (utterance, tool) in cases {
        #expect(router.route(utterance) == .tool(tool))
    }
}

@Test
func koreanRouterTreatsRelativeDurationAlarmsAsTimers() {
    let router = KoreanNativeToolRouter()
    let timerRequests = [
        "10초 뒤 알람 맞춰 줘",
        "10분 후 알람 설정해 줘",
        "한 시간 뒤에 깨워 줘",
        "다섯 분 뒤 깨워줘",
        "여섯 시간 후 알람 맞춰줘",
        "한 시간 반 뒤 깨워 줘",
        "ㄷ10초뒤 알람 맞춰줘",
    ]

    for utterance in timerRequests {
        #expect(router.route(utterance) == .tool(.createTimer))
    }

    #expect(
        router.route("내일 아침 7시에 알람 맞춰 줘")
            == .tool(.createAlarm)
    )
}

@Test
func koreanRouterSupportsTimerCreationPhrases() {
    let router = KoreanNativeToolRouter()
    for utterance in [
        "10분 타이머 만들어줘",
        "30초 타이머 등록해 줘",
        "타이머 5분 추가해줘",
        "두 시간 카운트다운 만들어 줘",
    ] {
        #expect(router.route(utterance) == .tool(.createTimer))
    }
    #expect(router.route("타이머 만드는 방법이 궁금해") == .normal)
    #expect(router.route("타이머를 등록했어") == .normal)
}

@Test
func koreanRouterPreservesOtherIntentsAlongsideRelativeTimer() {
    let router = KoreanNativeToolRouter()
    #expect(
        router.route("내일 일정을 보여 주고 다섯 분 뒤 알람 맞춰 줘")
            == .conflict([.createTimer, .getCalendarEvents])
    )
    #expect(
        router.route("한 시간 뒤 알람 목록 보여줘") == .tool(.listAlarms)
    )
}

@Test
func koreanRouterKeepsStatementsAndCasualConversationOnChatPath() {
    let router = KoreanNativeToolRouter()
    let cases = [
        "오늘 만 보 걸었어",
        "알람 소리 너무 싫어",
        "내일 약속이 있어",
        "요즘 타이머를 자주 써",
        "안녕, 오늘 기분 어때?",
    ]

    for utterance in cases {
        #expect(router.route(utterance) == .normal)
    }
}

@Test
func koreanRouterRejectsMultipleToolIntentsAsConflict() {
    let route = KoreanNativeToolRouter().route(
        "내일 일정을 보여 주고 7시 알람도 맞춰 줘"
    )

    #expect(
        route == .conflict([.createAlarm, .getCalendarEvents])
    )
}
