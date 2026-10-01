import Foundation

/// Final destinations are independent of matching and budget selection. Inactive AN
/// destinations still consume WI budget, matching upstream, but do not enter model input.
struct WorldInfoPromptProjection {
    let insertions: [DialoguePromptInsertion]
    let note: AuthorsNoteResolution?
    let trace: WorldInfoTrace
    let selection: WorldInfoSelection
    let outlets: [String: String]

    init(selection: WorldInfoSelection, note: AuthorsNoteResolution?) {
        let renderOrder = selection.selected.enumerated().sorted {
            $0.element.order == $1.element.order ? $0.offset < $1.offset : $0.element.order > $1.element.order
        }.map(\.element).reversed().filter { !$0.content.isEmpty }
        func text(_ position: WorldInfoEntry.Position) -> String {
            renderOrder.filter { $0.position == position }.map(\.content).joined(separator: "\n")
        }
        var insertions: [DialoguePromptInsertion] = []
        for (position, placement, id) in [
            (WorldInfoEntry.Position.beforeCharacter, DialoguePromptInsertion.Placement.beforePersona, "worldInfo.beforeCharacter"),
            (.afterCharacter, .afterPersona, "worldInfo.afterCharacter")
        ] {
            let content = text(position)
            if !content.isEmpty { insertions.append(.init(id: id, source: .worldInfo, text: content, placement: placement)) }
        }
        var outlets: [String: String] = [:]
        var depthGroups: [(depth: Int, role: DialoguePromptRole, entries: [WorldInfoEntry])] = []
        for entry in renderOrder.reversed() {
            if entry.position == .inChat {
                let depth = entry.rules.depth ?? 4, role = entry.rules.role ?? .system
                if let i = depthGroups.firstIndex(where: { $0.depth == depth && $0.role == role }) {
                    depthGroups[i].entries.insert(entry, at: 0)
                } else { depthGroups.append((depth, role, [entry])) }
            }
        }
        for entry in renderOrder {
            if entry.position == .outlet, let name = entry.rules.outlet {
                // Outlet insertion is opt-in via a macro, never an implicit prompt block.
                outlets[name] = entry.content + (outlets[name].map { "\n" + $0 } ?? "")
            }
        }
        for group in depthGroups {
            insertions.append(.init(id: "worldInfo.depth.\(group.depth).\(group.role.rawValue)", source: .worldInfo,
                text: group.entries.map(\.content).joined(separator: "\n"), placement: .inChat,
                role: group.role, depth: group.depth))
        }
        for (position, id, order) in [(WorldInfoEntry.Position.beforeExamples, "worldInfo.beforeExamples", 0), (.afterExamples, "worldInfo.afterExamples", 200)] {
            let content = text(position)
            if !content.isEmpty { insertions.append(.init(id: id, source: .worldInfo, text: content, placement: .afterSystem, order: order)) }
        }
        var combined = note
        if let original = note, original.active {
            var content = text(.beforeNote) + "\n" + original.text + "\n" + text(.afterNote)
            if content.hasPrefix("\n") { content.removeFirst() }
            if content.hasSuffix("\n") { content.removeLast() }
            combined = original.replacingText(content)
        }
        var trace = selection.trace
        let selectedByID = Dictionary(uniqueKeysWithValues: selection.selected.map { ($0.id, $0) })
        for index in trace.entries.indices {
            guard trace.entries[index].reason == .selected, let entry = selectedByID[trace.entries[index].id] else { continue }
            let isNote = entry.position == .beforeNote || entry.position == .afterNote
            trace.entries[index].delivery = entry.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty
                : (entry.position == .outlet ? .outlet : (isNote && note?.active != true ? .noteInactive : .inserted))
        }
        self.selection = selection; self.outlets = outlets
        self.insertions = insertions; self.note = combined; self.trace = trace
    }
}

extension AuthorsNoteResolution {
    func replacingText(_ text: String) -> Self {
        .init(state: state, text: text, interval: interval, position: position, depth: depth, role: role,
            userMessageNumber: userMessageNumber, allowWorldInfoScan: allowWorldInfoScan)
    }
}
