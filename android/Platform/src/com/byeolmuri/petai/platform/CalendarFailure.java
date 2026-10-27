package com.byeolmuri.petai.platform;

final class CalendarFailure extends RuntimeException {
    final String code;
    CalendarFailure(String code) { super(code); this.code = code; }
}
