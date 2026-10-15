package com.byeolmuri.petai.platform;

final class NotificationFailure extends Exception {
    final String code;
    NotificationFailure(String code) { super(code); this.code = code; }
}
