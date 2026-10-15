package com.byeolmuri.petai.platform;

public final class AlarmFailure extends Exception {
    public final String code;
    public AlarmFailure(String code) { super(code); this.code = code; }
    public AlarmFailure(String code, Throwable cause) { super(code, cause); this.code = code; }
}
