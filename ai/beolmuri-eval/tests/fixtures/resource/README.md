# 측정 표 fixture

`power.xml`은 로컬 Xcode Power Profiler 내보내기에서 얻은 작은 표의 구조를 사용한다. `signposts.xml`은 Mac의 합성 signpost 시험에서 얻은 구간 표를 축소하고 PID와 실행 식별자를 고정한 자료다. 앱·기기 성능을 대표하지 않는다.

검증 목적은 xctrace XML의 열·단위·id/ref 참조 해석, 구간 경계, 누락·중복 거부와 실행 소유권 대조다. 재현 시 Power Profiler와 os_signpost를 기록한 뒤 `xctrace export --toc`로 실제 표 스키마를 조회하고 해당 표를 내보낸다. 기기 식별자와 개인 경로를 제거한 최소 자료만 fixture로 보존한다. 전체 원본은 무시되는 실험 산출물에 남긴다.
