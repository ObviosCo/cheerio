import CheerioKit
import SwiftData
import SwiftUI

/// Correcting diarization after the fact: rename or merge the speakers in one
/// meeting, and lift a speaker's audio out as an enrollment sample.
///
/// Sortformer sometimes splits one person across two slots — observed on a 25s
/// recording where a speaker's own turns came back as both "Glen" and "Speaker 3",
/// overlapping in time. Nothing downstream can untangle that, so the fix is to let
/// the person watching say who's who.
struct MeetingSpeakersSection: View {
    let meeting: Meeting

    @Environment(\.modelContext) private var context
    @Query(sort: \EnrolledSpeaker.enrolledAt) private var enrolled: [EnrolledSpeaker]

    @State private var enrolling: SpeakerSummary?
    @State private var errorMessage: String?

    var body: some View {
        let summaries = meeting.speakerSummaries
        if !summaries.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Who was here")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ParticipantRosterMenu(meeting: meeting)
                        Spacer()
                    }
                    Divider()

                    ForEach(summaries) { summary in
                        row(for: summary)
                    }
                    Divider()
                    Text(
                        "Renaming a speaker updates every line they're on. Corrections stick — “Re-identify speakers” leaves hand-named lines alone."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Speakers")
            }
            .sheet(item: $enrolling) { summary in
                EnrollFromMeetingSheet(
                    summary: summary,
                    suggestedName: summary.isGeneratedLabel ? "" : summary.label,
                    existingNames: enrolled.map(\.name)
                ) { name in
                    enroll(summary, as: name)
                }
            }
            .alert("Couldn't save the voice sample", isPresented: $errorMessage.presented()) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func row(for summary: SpeakerSummary) -> some View {
        HStack(spacing: 8) {
            Text(summary.displayName)
                .font(.callout.weight(.medium))
            if summary.isManual {
                Image(systemName: "hand.raised.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Named by hand")
            }
            Text("\(summary.lineCount) \(summary.lineCount == 1 ? "line" : "lines") · \(Int(summary.duration.rounded()))s")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Menu("Rename") {
                let others = candidates(for: summary)
                if others.isEmpty {
                    Text("Enroll a voice in Settings → Participants first")
                } else {
                    ForEach(others, id: \.self) { name in
                        Button(name) { relabel(summary, to: name) }
                    }
                }
                Divider()
                Button("Reset to “\(summary.channel == .me ? "Me" : "Them")”") {
                    relabel(summary, to: nil)
                }
            }
            .fixedSize()

            Button("Use as voice sample") { enrolling = summary }
                .disabled(meeting.audioDirectory == nil)
                .help(
                    meeting.audioDirectory == nil
                        ? "This meeting's audio has been deleted, so there's nothing to sample."
                        : "Save this speaker's audio from this meeting as their reference clip."
                )
        }
    }

    /// Enrolled names plus the other speakers in this meeting — merging into a
    /// sibling label is how a split speaker gets put back together.
    ///
    /// Another channel's diarizer label is excluded: those are unrelated people, so
    /// offering to merge into one would only create the confusion this scoping fixed.
    private func candidates(for summary: SpeakerSummary) -> [String] {
        var seen = Set([summary.label])
        var names: [String] = []
        for name in enrolled.map(\.name) where seen.insert(name).inserted {
            names.append(name)
        }
        for other in meeting.speakerSummaries where other.id != summary.id {
            if let scoped = other.scopedChannel, scoped != summary.channel { continue }
            if seen.insert(other.label).inserted { names.append(other.label) }
        }
        return names
    }

    private func relabel(_ summary: SpeakerSummary, to newLabel: String?) {
        meeting.relabelSpeaker(summary, to: newLabel)
        // Renaming a speaker can change who owns an action item — keep the stored
        // items in agreement with what an export would now say.
        meeting.reconcileActionItems(ownerNames: SpeakerLabeling.ownerNames(context: context))
        do {
            try context.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func enroll(_ summary: SpeakerSummary, as name: String) {
        // Everything below has to land together or not at all: the sample file, the new
        // speaker, and the rename of this speaker's lines. Without the rollback, a
        // failed save left the CAF on disk and both model changes pending in the live
        // context — so a later autosave could commit part of what the user was just
        // told had failed.
        let priorLabels = meeting.segments.map {
            ($0, $0.speakerLabel, $0.isSpeakerLabelManual)
        }
        // The reconciliation below mutates trust state too; a failed save must put
        // it back, or a later autosave commits part of an operation the user was
        // told failed.
        let priorActionItems = meeting.actionItems
        var insertedSpeaker: EnrolledSpeaker?
        var writtenSamplePath: String?

        do {
            guard let relativePath = meeting.audioDirectory else {
                throw SpeakerLabeling.LabelingError.audioUnavailable
            }
            let source = try AudioStorage.url(forRelativePath: relativePath)
                .appending(path: "\(summary.channel.rawValue).caf")
            let (samplePath, sampleURL) = try AudioStorage.makeSpeakerSampleFile()
            let duration = try AudioExcerpt.write(
                meeting.ranges(for: summary),
                from: source,
                to: sampleURL
            )
            writtenSamplePath = samplePath

            let speaker = EnrolledSpeaker(name: name, audioPath: samplePath, duration: duration)
            context.insert(speaker)
            insertedSpeaker = speaker
            // Now that this speaker has a name, put it on their lines too — and
            // re-check the action items, since the lines just changed owners.
            meeting.relabelSpeaker(summary, to: name)
            meeting.reconcileActionItems(ownerNames: SpeakerLabeling.ownerNames(context: context))
            try context.save()
        } catch {
            if let insertedSpeaker { context.delete(insertedSpeaker) }
            for (segment, label, wasManual) in priorLabels {
                segment.speakerLabel = label
                segment.isSpeakerLabelManual = wasManual
            }
            meeting.actionItems = priorActionItems
            if let writtenSamplePath {
                try? AudioStorage.removeFile(atRelativePath: writtenSamplePath)
            }
            errorMessage = error.localizedDescription
        }
    }
}

extension SpeakerSummary {
    /// True for labels the app invented — "Speaker 2", "Me", "Them" — as opposed to a
    /// real name worth pre-filling into the enrollment sheet.
    var isGeneratedLabel: Bool {
        label == "Me" || label == "Them" || TranscriptSegment.isDiarizerGeneratedLabel(label)
    }
}

/// Names the speaker whose audio is about to become an enrollment sample.
private struct EnrollFromMeetingSheet: View {
    let summary: SpeakerSummary
    let suggestedName: String
    let existingNames: [String]
    let save: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var isDuplicate: Bool {
        existingNames.contains { $0.caseInsensitiveCompare(trimmedName) == .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Use as voice sample")
                .font(.headline)
            Text(
                "Takes the \(Int(summary.duration.rounded()))s this speaker was recorded for in this meeting and saves it as their reference clip."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            TextField("Name", text: $name)
                .onSubmit(commit)

            if summary.duration < EnrolledSpeaker.recommendedDuration {
                // Better to say this now than to have them wonder why the next
                // meeting still splits this person in two.
                Label(
                    "That's under the \(Int(EnrolledSpeaker.recommendedDuration))s recommended, so it may not be enough to tell similar voices apart. A longer sample from a meeting where they talked more will work better.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            if isDuplicate {
                Text(
                    "“\(trimmedName)” is already enrolled — this adds a second sample under the same name, which wastes one of the four speaker slots."
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { name = suggestedName }
    }

    private func commit() {
        guard !trimmedName.isEmpty else { return }
        save(trimmedName)
        dismiss()
    }
}
