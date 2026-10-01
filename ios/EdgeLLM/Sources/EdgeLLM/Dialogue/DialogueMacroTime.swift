import Foundation

extension DialogueMacroEvaluator {
    func timeMacro(_ name: String, values: [String]) throws -> String {
        guard let milliseconds = host("nowMilliseconds").flatMap(Double.init), milliseconds.isFinite, (-62_135_596_800_000...253_402_300_799_999).contains(milliseconds) else {
            throw WorldInfoTextError.missingHostValue("nowMilliseconds")
        }
        let now = Date(timeIntervalSince1970:milliseconds/1000)
        var offset = Int(host("utcOffsetMinutes") ?? "0") ?? 0
        if name == "time", let zone = values.first, zone.hasPrefix("UTC") {
            guard let hours = Int(zone.dropFirst(3)), (-24...24).contains(hours) else { throw WorldInfoTextError.invalidMacro("Invalid UTC offset") }
            offset = hours*60
        }
        guard (-1440...1440).contains(offset) else { throw WorldInfoTextError.invalidMacro("Invalid UTC offset") }
        guard let zone = TimeZone(secondsFromGMT:offset*60) else { throw WorldInfoTextError.invalidMacro("Invalid UTC offset") }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:host("locale") ?? "en_US_POSIX")
        formatter.timeZone = zone
        if name == "timediff" {
            guard values.count == 2 else { throw WorldInfoTextError.invalidMacro("timeDiff requires two dates") }
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let iso = ISO8601DateFormatter()
            guard let left = formatter.date(from:values[0]) ?? iso.date(from:values[0]), let right = formatter.date(from:values[1]) ?? iso.date(from:values[1]) else { throw WorldInfoTextError.invalidMacro("Invalid timeDiff date") }
            return relativeDuration(left.timeIntervalSince(right), suffix:true)
        }
        if name == "idleduration" || name == "idle_duration" {
            var passedLast = false
            for message in messages.reversed() where message["is_system"] != .bool(true) {
                if passedLast, message["is_user"] == .bool(true), let value = message["send_date"] {
                    let date = Double(scalar(value)).map { Date(timeIntervalSince1970:$0/1000) } ?? ISO8601DateFormatter().date(from:scalar(value))
                    guard let date, date.timeIntervalSince1970.isFinite, (-62_135_596_800...253_402_300_799).contains(date.timeIntervalSince1970) else { throw WorldInfoTextError.invalidMacro("Invalid message timestamp") }
                    return relativeDuration(now.timeIntervalSince(date),suffix:false)
                }
                passedLast = true
            }
            return "just now"
        }
        switch name {
        case "isodate": formatter.dateFormat = "yyyy-MM-dd"
        case "isotime": formatter.dateFormat = "HH:mm"
        case "weekday": formatter.dateFormat = "EEEE"
        case "date": formatter.dateStyle = .long
        case "time": formatter.timeStyle = .short
        default: formatter.dateFormat = try momentFormat(values.first ?? "")
        }
        return formatter.string(from:now)
    }
    private func relativeDuration(_ seconds: Double, suffix: Bool) -> String {
        // Moment's default English thresholds. Other locales require explicit translations.
        let n = abs(seconds), minutes = (n/60).rounded(), hours = (n/3600).rounded(), days = (n/86400).rounded()
        let text: String
        if n.rounded() < 45 { text = "a few seconds" }
        else if minutes <= 1 { text = "a minute" }
        else if minutes < 45 { text = "\(Int(minutes)) minutes" }
        else if hours <= 1 { text = "an hour" }
        else if hours < 22 { text = "\(Int(hours)) hours" }
        else if days <= 1 { text = "a day" }
        else if days < 26 { text = "\(Int(days)) days" }
        else if days < 46 { text = "a month" }
        else if days < 320 { text = "\(Int((days/30).rounded())) months" }
        else if days < 548 { text = "a year" }
        else { text = "\(Int((days/365).rounded())) years" }
        return suffix ? (seconds > 0 ? "in \(text)" : "\(text) ago") : text
    }
    private func momentFormat(_ format: String) throws -> String {
        let tokens = ["YYYY":"yyyy","YY":"yy","MMMM":"MMMM","MMM":"MMM","MM":"MM","M":"M",
            "DD":"dd","D":"d","dddd":"EEEE","ddd":"EEE","HH":"HH","H":"H","hh":"hh","h":"h",
            "mm":"mm","m":"m","ss":"ss","s":"s","SSS":"SSS","A":"a","a":"a","Z":"XXX","ZZ":"xx",
            "LLLL":"EEEE, MMMM d, yyyy h:mm a","LLL":"MMMM d, yyyy h:mm a","LL":"MMMM d, yyyy","L":"MM/dd/yyyy",
            "LTS":"h:mm:ss a","LT":"h:mm a"]
        let ordered = tokens.keys.sorted { $0.count > $1.count }
        var result = "", rest = format[...]
        while !rest.isEmpty {
            if rest.first == "[", let end = rest.firstIndex(of:"]") {
                result += "'" + rest[rest.index(after:rest.startIndex)..<end].replacingOccurrences(of:"'",with:"''") + "'"
                rest = rest[rest.index(after:end)...]
            } else if let token = ordered.first(where: { rest.hasPrefix($0) }) {
                result += tokens[token]!; rest = rest.dropFirst(token.count)
            } else {
                guard let c = rest.first else { break }
                if c.isLetter { throw WorldInfoTextError.invalidMacro("Unsupported date-format token \(c)") }
                result.append(c); rest = rest.dropFirst()
            }
        }
        return result
    }
}
