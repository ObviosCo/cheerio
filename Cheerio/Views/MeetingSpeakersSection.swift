import CheerioKit
import SwiftData
import SwiftUI

/// Correcting diarization after the fact: rename or merge the speakers in one
/// meeting, confirm one the model already got right, and lift a speaker's audio
/// out as an enrollment sample.
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
    @State private var saveFailure: SaveFailure?

    var body: some View {
        let talkTimes = meeting.speakerTalkTimes
        if !talkTimes.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Who was here")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ParticipantRosterMenu(meeting: meeting)
                        Spacer()
                    }
                    SpeakerTimelineBar(meeting: meeting)
                    Divider()

                    ForEach(talkTimes) { talkTime in
                        row(for: talkTime)
                    }
                    Divider()
                    Text(
                        "Renaming or confirming a speaker updates every line they're on. Corrections stick — “Re-identify speakers” leaves hand-named and confirmed lines alone."
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
            .alert(saveFailure?.title ?? "Couldn't save", isPresented: $saveFailure.presented()) {
                Button("OK") { saveFailure = nil }
            } message: {
                Text(saveFailure?.message ?? "")
            }
        }
    }

    private func row(for talkTime: SpeakerTalkTime) -> some View {
        let summary = talkTime.summary
        let chip = speaker(for: summary)
        return HStack(spacing: 8) {
            SpeakerChip(chip)
            Text(summary.displayName)
                .font(.callout.weight(.medium))
            if summary.isSettled {
                // Renamed and confirmed are now distinguishable states (see
                // `TranscriptSegment.isSpeakerLabelConfirmed`), so the help text says
                // which one actually happened instead of a wording vague enough to
                // cover both.
                Image(systemName: "hand.raised.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(summary.isManual ? "Named by hand" : "Confirmed by you")
            }
            Text(talkTimeText(for: talkTime))
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            rowMenu(for: summary, isModelMatched: chip.provenance == .modelMatched)
        }
    }

    /// Duration and share of the meeting's total talk — replaces the old line-count
    /// readout with the number that actually answers "who spoke how much."
    /// `SpeakerTalkTime.proportion` is already the pure computation (see
    /// `CheerioKit/Models/SpeakerTimeline.swift`); this only formats it.
    private func talkTimeText(for talkTime: SpeakerTalkTime) -> String {
        let duration = Duration.seconds(talkTime.summary.duration).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
        )
        let share = talkTime.proportion.formatted(.percent.precision(.fractionLength(0)))
        return "\(duration) · \(share)"
    }

    /// Rename, confirm and enroll all sat inline before this — the panel's whole job
    /// on a finished meeting is correcting the model, so those controls dominated a
    /// view that should mostly be reporting what happened. One ellipsis per row keeps
    /// every action reachable without them competing with the talk-time readout for
    /// attention. Every save path below is unchanged; this only relocates the buttons
    /// that trigger them.
    private func rowMenu(for summary: SpeakerSummary, isModelMatched: Bool) -> some View {
        Menu {
            // Only a `.modelMatched` row carries the ring, and only that row needs a
            // way to clear it — the model got this one right, so say so once instead
            // of retyping the same name it already guessed.
            if isModelMatched {
                Button("Confirm") { confirm(summary) }
                    .help("The model's name for this speaker is right — settle it and drop the ring.")
            }

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

            Button("Use as voice sample") { enrolling = summary }
                .disabled(meeting.audioDirectory == nil)
                .help(
                    meeting.audioDirectory == nil
                        ? "This meeting's audio has been deleted, so there's nothing to sample."
                        : "Save this speaker's audio from this meeting as their reference clip."
                )
        } label: {
            Label("More for \(summary.displayName)", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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

    /// The chip view model for one "Who was here" row — see the per-segment sibling
    /// in ``MeetingDetailView/speaker(for:)``, which this mirrors against
    /// ``SpeakerSummary`` instead of a single ``TranscriptSegment``.
    private func speaker(for summary: SpeakerSummary) -> Speaker {
        let provenance = SpeakerProvenance(
            isSettled: summary.isSettled,
            isDiarizerGeneratedLabel: TranscriptSegment.isDiarizerGeneratedLabel(summary.label),
            hasName: !summary.isGeneratedLabel
        )
        let slot = meeting.speakerSlotAssigner.assignments[summary.id] ?? .unresolved
        return Speaker(id: summary.id, name: summary.displayName, slot: slot, provenance: provenance)
    }

    private func relabel(_ summary: SpeakerSummary, to newLabel: String?) {
        meeting.relabelSpeaker(summary, to: newLabel)
        let ownerNames = SpeakerLabeling.ownerNames(context: context)
        // A rename changes this speaker's summary id, which is also its slot key —
        // resolve before reconciling, so the row that renders right after this save
        // already has a slot instead of a one-frame `.unresolved` grey.
        meeting.resolveSpeakerSlots(ownerNames: ownerNames)
        // Renaming a speaker can change who owns an action item — keep the stored
        // items in agreement with what an export would now say.
        meeting.reconcileActionItems(ownerNames: ownerNames)
        do {
            try context.save()
        } catch {
            saveFailure = SaveFailure(title: "Couldn't rename this speaker", message: error.localizedDescription)
        }
    }

    /// Settles a `.modelMatched` speaker in one move, without renaming it — the fix
    /// for the ring otherwise never coming off an already-correct name. Rides
    /// ``Meeting/confirmSpeaker(_:)``, which only ever flips
    /// ``TranscriptSegment/isSpeakerLabelConfirmed``; the label, slot and action-item
    /// attribution it might own are all untouched, so unlike ``relabel(_:to:)`` there's
    /// nothing else here to reconcile — only the flag itself to put back on failure.
    ///
    /// Captured before the mutation, the same way ``enroll(_:as:)`` captures
    /// `priorLabels`: without it, a failed save would leave the ring gone and the
    /// button told the user it failed, while a later autosave quietly persisted the
    /// confirm anyway.
    private func confirm(_ summary: SpeakerSummary) {
        let prior = meeting.segments.filter { summary.matches($0) }.map { ($0, $0.isSpeakerLabelConfirmed) }
        guard meeting.confirmSpeaker(summary) > 0 else { return }
        do {
            try context.save()
        } catch {
            for (segment, wasConfirmed) in prior { segment.isSpeakerLabelConfirmed = wasConfirmed }
            saveFailure = SaveFailure(title: "Couldn't confirm this speaker", message: error.localizedDescription)
        }
    }

    private func enroll(_ summary: SpeakerSummary, as name: String) {
        // Everything below has to land together or not at all: the sample file, the new
        // speaker, and the rename of this speaker's lines. Without the rollback, a
        // failed save left the CAF on disk and both model changes pending in the live
        // context — so a later autosave could commit part of what the user was just
        // told had failed.
        let priorLabels = meeting.segments.map {
            ($0, $0.speakerLabel, $0.isSpeakerLabelManual, $0.isSpeakerLabelConfirmed)
        }
        // The reconciliation below mutates trust state too; a failed save must put
        // it back, or a later autosave commits part of an operation the user was
        // told failed.
        let priorActionItems = meeting.actionItems
        // Same reasoning extends to the slot assigner: resolving slots below can
        // hand this newly-named speaker a fresh one, and that has to unwind with
        // everything else on failure or a retry could find the name already
        // holding a slot capacity never actually committed.
        let priorSlotAssigner = meeting.speakerSlotAssigner
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
            let ownerNames = SpeakerLabeling.ownerNames(context: context)
            meeting.resolveSpeakerSlots(ownerNames: ownerNames)
            meeting.reconcileActionItems(ownerNames: ownerNames)
            try context.save()
        } catch {
            if let insertedSpeaker { context.delete(insertedSpeaker) }
            for (segment, label, wasManual, wasConfirmed) in priorLabels {
                segment.speakerLabel = label
                segment.isSpeakerLabelManual = wasManual
                segment.isSpeakerLabelConfirmed = wasConfirmed
            }
            meeting.actionItems = priorActionItems
            meeting.speakerSlotAssigner = priorSlotAssigner
            if let writtenSamplePath {
                try? AudioStorage.removeFile(atRelativePath: writtenSamplePath)
            }
            saveFailure = SaveFailure(title: "Couldn't save the voice sample", message: error.localizedDescription)
        }
    }
}

/// What to say when a speaker-panel save fails. Three actions here can fail — rename,
/// confirm, enroll — and each needs its own accurate title: routing all of them through
/// one fixed string (as this used to) means a failed confirm gets told it's a voice
/// sample problem.
private struct SaveFailure: Identifiable {
    let title: String
    let message: String
    var id: String { title + message }
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
                StatusLabel(
                    .attention,
                    "That's under the \(Int(EnrolledSpeaker.recommendedDuration))s recommended, so it may not be enough to tell similar voices apart. A longer sample from a meeting where they talked more will work better."
                )
                .fixedSize(horizontal: false, vertical: true)
            }

            if isDuplicate {
                // A symbol joins the text here, where there wasn't one before — colour
                // was otherwise the only signal a plain orange `Text` could give.
                StatusLabel(
                    .attention,
                    "“\(trimmedName)” is already enrolled — this adds a second sample under the same name, which wastes one of the four speaker slots."
                )
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
