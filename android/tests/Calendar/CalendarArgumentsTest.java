package com.byeolmuri.petai.platform;

import org.json.JSONObject;

/** Run on ART so this checks Android's JSONObject, not a desktop substitute. */
public final class CalendarArgumentsTest {
    public static void main(String[] args) throws Exception {
        check("{}", "");
        check("{\"location\":null}", "");
        check("{\"location\":\"\"}", "");
        check("{\"location\":\"회의실\"}", "회의실");
        check("{\"location\":\"null\"}", "null");
        System.out.println("PASS CalendarArguments 5 checks");
    }
    private static void check(String json, String expected) throws Exception {
        String actual = CalendarArguments.location(new JSONObject(json));
        if (!expected.equals(actual)) throw new AssertionError(json + ": expected [" + expected + "], got [" + actual + "]");
    }
}
