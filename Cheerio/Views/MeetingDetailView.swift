import CheerioKit
import SwiftData
import SwiftUI

struct MeetingDetailView: View {
    let meeting: Meeting
    /// Run after this meeting is deleted, so the caller can clear whatever
    /// selection was pointing at it — this view owns no binding to that itself,
    /// since `ContentView` passes it a plain `Meeting`, not a `Binding<Meeting?>`.
    var onDelete: () -> Void = {}

    @Environment(\.modelContext) private var context
    @Environment(CaptureSession.self) private var session
    @Query(sort: \EnrolledSpeaker.enrolledAt) private var enrolled: [EnrolledSpeaker]
    @State private var isRelabeling = false
    @State private var relabelError: String?
    @State private var isDeleteConfirming = false
    @State private var deleteError: String?
    /// Expanded by default: opening an old meeting is usually about re-reading what
    /// was said, and a collapsed disclosure made the transcript look like it was gone.
    @State private var isTranscriptExpanded = true

    private var sortedSegments: [TranscriptSegment] {
        meeting.segments.sorted { $0.startTime < $1.startTime }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                notes

                if !meeting.roughNotes.isEmpty {
                    GroupBox("Your rough notes") {
                        Text(meeting.roughNotes)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }

                if meeting.audioDirectory != nil {
                    HStack(spacing: 8) {
                        Button {
                            Task { await relabel() }
                        } label: {
                            Label(
                                isRelabeling ? "Identifying speakers…" : "Re-identify speakers",
                                systemImage: "person.wave.2"
                            )
                        }
                        .disabled(isRelabeling)
                        Text("Uses the voices enrolled in Settings → Participants.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                MeetingSpeakersSection(meeting: meeting)

                Divider()
                transcript
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(meeting.title)
        // Slot assignment is call-order dependent by design (Theme's speaker-identity
        // vocabulary): this is the first point a meeting not opened before might need
        // one resolved. Re-keyed per meeting so switching in the sidebar re-runs it,
        // and a no-op for one that already has every current speaker slotted.
        .task(id: meeting.persistentModelID) {
            meeting.resolveSpeakerSlots(ownerNames: SpeakerLabeling.ownerNames(context: context))
            try? context.save()
        }
        .alert("Couldn't identify speakers", isPresented: $relabelError.presented()) {
            Button("OK") { relabelError = nil }
        } message: {
            Text(relabelError ?? "")
        }
        .confirmationDialog(
            DeleteMeetingConfirmation.title(for: meeting.title),
            isPresented: $isDeleteConfirming,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(DeleteMeetingConfirmation.message)
        }
        .alert("Couldn't delete meeting", isPresented: $deleteError.presented()) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
        .toolbar {
            ToolbarItem {
                ShareLink(item: exportMarkdown()) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }
            ToolbarItem {
                // Reachable even for the meeting currently recording (selecting it
                // mid-call replaces the live view with this one) — `.disabled`
                // rather than omitted, matching the library list's context menu, so
                // the control doesn't appear to vanish depending on state.
                // `canDelete` also covers this view's own "Re-identify speakers"
                // pass: it mutates `meeting.segments` across an `await`, and a
                // delete racing that would resume the pass against an already-
                // deleted model. See `CaptureSession.canDelete(_:)`.
                Button(role: .destructive) {
                    isDeleteConfirming = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(!session.canDelete(meeting))
            }
        }
    }

    /// The window title bar carries the meeting name, but the detail column needs its
    /// own heading — and the date is how you tell two "Call with Mary" apart.
    ///
    /// Editable in place, the same affordance `RecordingView` offers live: a typo
    /// like the one issue #32 was filed over ("Cheerio pivot to actionable
    /// transcripts") is otherwise permanent once the meeting has ended. Routed
    /// through `rename(to:)`, not a direct `$meeting.title` binding, so a rename
    /// here retires `isTitleAutomatic` the same way it does mid-recording.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("Meeting name", text: Binding(get: { meeting.title }, set: { meeting.rename(to: $0) }))
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .onSubmit { save() }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        var parts = [meeting.startedAt.formatted(date: .abbreviated, time: .shortened)]
        if let endedAt = meeting.endedAt {
            let elapsed = Int(endedAt.timeIntervalSince(meeting.startedAt).rounded())
            parts.append(
                Duration.seconds(elapsed).formatted(
                    .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
                )
            )
        } else {
            // No end date means the app quit mid-recording; say so rather than
            // showing a duration of zero.
            parts.append("didn’t finish recording")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var notes: some View {
        if let notes = meeting.enhancedNotes, !notes.isEmpty {
            MarkdownNotesView(markdown: notes)
        } else {
            // Summarization can fail, or never have run. The transcript below is
            // still the record, so point at it.
            Label(
                "No enhanced notes for this meeting — the transcript below is intact.",
                systemImage: "sparkles"
            )
            .foregroundStyle(.secondary)
        }
    }

    private var transcript: some View {
        DisclosureGroup(isExpanded: $isTranscriptExpanded) {
            if sortedSegments.isEmpty {
                Text("No transcript for this meeting.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            } else {
                // Lazy: a long meeting runs to hundreds of lines, and each one carries
                // a menu now.
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(sortedSegments) { segment in
                        HStack(alignment: .top, spacing: 8) {
                            speakerMenu(for: segment)
                            Text(segment.text)
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.top, 6)
            }
        } label: {
            Text("Transcript (\(meeting.segments.count) segments)")
                .font(.headline)
        }
    }

    /// The speaker label, as a menu for fixing one line. Whole-speaker renames live in
    /// ``MeetingSpeakersSection`` — this is for the odd line the diarizer put on the
    /// wrong person.
    private func speakerMenu(for segment: TranscriptSegment) -> some View {
        Menu {
            ForEach(candidateLabels(for: segment), id: \.self) { label in
                Button(label) {
                    segment.assignSpeaker(label)
                    save()
                }
            }
            if segment.isSpeakerLabelManual {
                Divider()
                Button("Undo my change") {
                    segment.assignSpeaker(nil)
                    save()
                }
            }
        } label: {
            // A minimum-width rail, not a fixed 72pt one — `SpeakerRailLabel`'s
            // provenance styling (bold, primary text for a manual label) already
            // carries what the hand icon used to say on its own.
            SpeakerRailLabel(speaker(for: segment))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Who this line could plausibly belong to: anyone enrolled, plus the other
    /// speakers on this line's own channel. Another channel's "Speaker 1" is an
    /// unrelated person, so it isn't offered.
    private func candidateLabels(for segment: TranscriptSegment) -> [String] {
        var seen = Set([segment.displayLabel])
        var labels: [String] = []
        for name in enrolled.map(\.name) where seen.insert(name).inserted {
            labels.append(name)
        }
        for summary in meeting.speakerSummaries {
            if let scoped = summary.scopedChannel, scoped != segment.channel { continue }
            if seen.insert(summary.label).inserted { labels.append(summary.label) }
        }
        return labels
    }

    private func save() {
        let ownerNames = SpeakerLabeling.ownerNames(context: context)
        // Resolving slots before reconciling action items is order-independent —
        // they read disjoint state — but both belong wherever a label just changed.
        meeting.resolveSpeakerSlots(ownerNames: ownerNames)
        // Correcting who said a line can change who owns an action item; the stored
        // items must agree with what an export would now say (see
        // Meeting.reconcileActionItems). Idempotent, so harmless for saves that
        // didn't touch a label.
        meeting.reconcileActionItems(ownerNames: ownerNames)
        do {
            try context.save()
        } catch {
            relabelError = error.localizedDescription
        }
    }

    /// Re-runs diarization. Worth offering because labels improve as more voices get
    /// enrolled, and the audio stays on disk until retention purges it.
    private func relabel() async {
        isRelabeling = true
        // Before the first `await` below, so nothing can observe this meeting as
        // deletable between that call starting and this line running. Cleared in
        // the `defer`, which runs on the error path too — see `CaptureSession`.
        session.beginProcessing(meeting)
        defer {
            isRelabeling = false
            session.endProcessing(meeting)
        }
        do {
            try await SpeakerLabeling.label(meeting: meeting, context: context)
            let ownerNames = SpeakerLabeling.ownerNames(context: context)
            meeting.resolveSpeakerSlots(ownerNames: ownerNames)
            // A fresh diarization pass rewrites non-manual labels wholesale — the
            // same trust-state invalidation as a hand correction, so the persisted
            // items must be re-checked the same way (see Meeting.reconcileActionItems).
            meeting.reconcileActionItems(ownerNames: ownerNames)
            try? context.save()
        } catch {
            relabelError = error.localizedDescription
        }
    }

    /// Commits the toolbar's "Delete" flow, after confirmation.
    private func delete() {
        do {
            try MeetingDeletion.delete(meeting, context: context)
            onDelete()
        } catch {
            deleteError = error.localizedDescription
        }
    }

    /// The chip-and-name view model for one transcript line, reading provenance
    /// straight off the model rather than inventing it here — see
    /// ``SpeakerProvenance/init(isSpeakerLabelManual:isDiarizerGeneratedLabel:hasName:)``.
    /// The slot itself is a lookup, not an assignment: ``Meeting/resolveSpeakerSlots(ownerNames:)``
    /// is what hands new slots out, at the points above where speakers actually resolve,
    /// so this stays a pure read safe to call from `body`.
    private func speaker(for segment: TranscriptSegment) -> Speaker {
        let isDiarizerGenerated = TranscriptSegment.isDiarizerGeneratedLabel(segment.speakerLabel)
        let provenance = SpeakerProvenance(
            isSpeakerLabelManual: segment.isSpeakerLabelManual,
            isDiarizerGeneratedLabel: isDiarizerGenerated,
            hasName: segment.speakerLabel != nil && !isDiarizerGenerated
        )
        let slot = meeting.speakerSlotAssigner.assignments[segment.speakerSlotKey] ?? .unresolved
        return Speaker(id: segment.speakerSlotKey, name: segment.displayLabel, slot: slot, provenance: provenance)
    }

    private func exportMarkdown() -> String {
        var out = "# \(meeting.title)\n\(meeting.startedAt.formatted())\n\n"
        if let notes = meeting.enhancedNotes { out += notes + "\n\n" }
        out += "## Transcript\n\(meeting.transcriptText)\n"
        return out
    }
}
