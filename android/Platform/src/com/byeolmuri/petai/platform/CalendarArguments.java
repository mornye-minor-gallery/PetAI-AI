package com.byeolmuri.petai.platform;

import org.json.JSONObject;

/** Shared decoding for calendar confirmation and execution. */
final class CalendarArguments {
    static String location(JSONObject arguments) {
        // Swift encodes an absent location as JSON null. Android optString turns
        // JSONObject.NULL into the literal "null", so distinguish it explicitly.
        return arguments.isNull("location") ? "" : arguments.optString("location", "");
    }
}
