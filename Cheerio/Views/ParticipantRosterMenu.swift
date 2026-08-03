import CheerioKit
import SwiftData
import SwiftUI

/// Chooses which enrolled voices were in one meeting.
///
/// Sortformer resolves at most four speakers and every primed voice takes one, so
/// priming someone who wasn't there costs a slot a real participant needed. Picking
/// per meeting means you can keep as many saved voices as you like and still only
/// spend the four on people who were actually in the room.
struct ParticipantRosterMenu: View {
    let meeting: Meeting

    @Environment(\.modelContext) private var context
    @Query(sort: \EnrolledSpeaker.enrolledAt) private var enrolled: [EnrolledSpeaker]

    private var limit: Int { SpeakerAttributionService.maximumSpeakers }

    /// What's selected. Nil on the meeting means nobody has chosen, which behaves as
    /// everyone — so that's what the checkmarks show too.
    private var selectedNames: [String] {
        meeting.participantNames ?? enrolled.map(\.name)
    }

    private var isOverCap: Bool { selectedNames.count > limit }

    var body: some View {
        if enrolled.isEmpty {
            Label("No voices enrolled", systemImage: "person.2.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Enroll voices in Settings → Participants to have speakers named.")
        } else {
            Menu {
                ForEach(enrolled, id: \EnrolledSpeaker.persistentModelID) { speaker in
                    Toggle(isOn: binding(for: speaker)) {
                        Text(speaker.isMe ? "\(speaker.name) (me)" : speaker.name)
                    }
                }
                Divider()
                Button("Everyone enrolled") { setRoster(enrolled.map(\.name)) }
                // An all-remote call needs no priming at all: the mic/system split
                // already separates you from them.
                Button("Nobody — all remote") { setRoster([]) }
            } label: {
                Label(summary, systemImage: isOverCap ? "exclamationmark.triangle" : "person.2")
            }
            .fixedSize()
            .help(helpText)
        }
    }

    private var summary: String {
        let names = selectedNames
        if names.isEmpty { return "No voices primed" }
        if isOverCap { return "\(names.count) selected — over the \(limit)-voice cap" }
        return names.joined(separator: ", ")
    }

    private var helpText: String {
        if isOverCap {
            let (chosen, dropped) = meeting.participants(from: enrolled, limit: limit)
            return """
                Only \(limit) voices can be primed. Using \(chosen.map(\.name).joined(separator: ", ")); \
                leaving out \(dropped.map(\.name).joined(separator: ", ")). Deselect someone to choose.
                """
        }
        return "Who was in this meeting. Only these voices get named; re-identify speakers after changing it."
    }

    private func binding(for speaker: EnrolledSpeaker) -> Binding<Bool> {
        Binding(
            get: { selectedNames.contains(speaker.name) },
            set: { isOn in
                var names = selectedNames
                if isOn {
                    guard !names.contains(speaker.name) else { return }
                    names.append(speaker.name)
                } else {
                    names.removeAll { $0 == speaker.name }
                }
                setRoster(names)
            }
        )
    }

    private func setRoster(_ names: [String]) {
        meeting.participantNames = names
        try? context.save()
    }
}
