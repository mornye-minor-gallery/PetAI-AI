package com.byeolmuri.petai.platform;

final class StepFailure extends RuntimeException {
    final String code;
    StepFailure(String code) { super(code); this.code = code; }
}
