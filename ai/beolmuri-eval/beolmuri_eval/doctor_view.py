"""Human terminal output using the terminal's own ANSI palette."""
import os
import re
import unicodedata

LABELS = {
    "deployment_model": "배포 모델",
    "litert_python": "LiteRT Python",
    "codex_cli": "Codex CLI",
    "swift_toolchain": "Swift",
    "swift_worker": "Swift 평가 실행부",
    "litert_native_library": "LiteRT-LM",
    "gemma_generation": "Gemma 실제 생성",
    "codex_judge": "Codex 실제 채점",
}


def supports_color(stream):
    return stream.isatty() and "NO_COLOR" not in os.environ and os.environ.get("TERM") != "dumb"


def clean(value):
    # Diagnostic strings are data, not terminal control sequences.
    return re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", str(value)).replace("\n", " ")


def detail(check):
    value, name = check["detail"], check["name"]
    if check["status"] != "pass":
        return clean(value)
    if name == "deployment_model":
        return "Gemma 4 E2B · 모바일 QAT · SHA-256 일치"
    if name == "litert_python":
        return "실행 환경 확인"
    if name == "swift_worker":
        return "빌드 최신 상태"
    if name == "swift_toolchain":
        match = re.search(r"Swift version ([\d.]+)", str(value))
        return match.group(1) if match else clean(value).split("(")[0].strip()
    if name == "litert_native_library":
        return f"{value['version']} · {value['backend'].upper()} · 출력 제한 지원"
    if name == "gemma_generation":
        elapsed = value.get("elapsed_ms")
        return f"응답 수신 · {elapsed / 1000:.2f}초" if elapsed is not None else "응답 수신"
    if name == "codex_judge":
        return f"{clean(value['model'])} · {clean(value['reasoning_effort'])} · 판정 검증 완료"
    return clean(value)


def render_doctor(report, *, color=False):
    def paint(value, code):
        return f"\x1b[{code}m{value}\x1b[0m" if color else value

    # ANSI magenta inherits Ghostty's Dusty Mauve accent; green/yellow/red retain
    # their semantic meanings. Pipes and NO_COLOR receive plain readable text.
    lines = ["", paint("  BEOLMURI EVAL", "1;35") + "  " + paint("환경 점검", "2"), ""]
    if report.get("installation"):
        lines += ["  소스: " + clean(report["installation"]["repository"]),
                  "  결과: " + clean(report["installation"]["results"]), ""]
    for check in report["checks"]:
        passed = check["status"] == "pass"
        symbol = paint("✓" if passed else "✗", "32" if passed else "31")
        label = LABELS.get(check["name"], check["name"])
        width = sum(2 if unicodedata.east_asian_width(char) in "WF" else 1 for char in label)
        padding = " " * max(2, 24 - width)
        explanation = detail(check)
        lines.append(f"  {symbol} {label}{padding}" + paint(explanation, "2" if passed else "31"))
    passed = sum(item["status"] == "pass" for item in report["checks"])
    count = len(report["checks"])
    lines += ["", "  " + paint(
        f"{'✓ 환경 점검 통과' if report['ready'] else '✗ 환경 점검 실패'}  {passed}/{count}",
        "1;32" if report["ready"] else "1;31")]
    if report["judge"]["access"] != "probed":
        lines.append("  " + paint("○ 실제 생성·채점 미확인", "33") + "  beolmuri-eval doctor --probe")
    parity = clean(report["runtime_parity"])
    versions = re.search(r"Mac LiteRT-LM ([\d.]+); mobile fork ([\d.]+)", parity)
    if versions:
        parity = f"Mac {versions.group(1)} / 모바일 {versions.group(2)} · 기기 검증 별도"
    lines.append("  " + paint("! 런타임 버전 차이", "33") + "  " + parity)
    lines += ["", paint("  평가 범위: 단일 턴 · 장면 고정 · 빈 기억", "2"),
              paint("  상세 정보: beolmuri-eval doctor --json", "2"), ""]
    return "\n".join(lines)
