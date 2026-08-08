import AVFoundation
import Foundation
import Testing

@testable import CheerioKit

/// Interleaved stereo Float32 at 48kHz — what the system-audio tap delivers.
private func makeTapFormat() throws -> AVAudioFormat {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8,
        mFramesPerPacket: 1,
        mBytesPerFrame: 8,
        mChannelsPerFrame: 2,
        mBitsPerChannel: 32,
        mReserved: 0
    )
    return try #require(AVAudioFormat(streamDescription: &asbd))
}

private func makeBuffer(format: AVAudioFormat, frames: AVAudioFrameCount, seed: Float) throws -> AVAudioPCMBuffer {
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    let count = Int(list[0].mDataByteSize) / 4
    let samples = try #require(list[0].mData).bindMemory(to: Float.self, capacity: count)
    for index in 0..<count {
        samples[index] = sin(Float(index) * 0.05) * seed
    }
    return buffer
}

@Suite struct BufferCopyTests {
    @Test func detachedCopyDuplicatesSamplesIntoIndependentStorage() throws {
        let format = try makeTapFormat()
        let source = try makeBuffer(format: format, frames: 128, seed: 0.5)
        let copy = try #require(source.detachedCopy())

        #expect(copy.frameLength == source.frameLength)
        #expect(copy.format.sampleRate == source.format.sampleRate)
        #expect(copy.format.channelCount == source.format.channelCount)

        let sourceList = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let copyList = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        #expect(sourceList.count == copyList.count)

        let count = Int(sourceList[0].mDataByteSize) / 4
        let sourceSamples = try #require(sourceList[0].mData).bindMemory(to: Float.self, capacity: count)
        let copySamples = try #require(copyList[0].mData).bindMemory(to: Float.self, capacity: count)

        // Distinct allocations…
        #expect(sourceSamples != copySamples)
        // …holding identical samples.
        for index in 0..<count {
            #expect(copySamples[index] == sourceSamples[index])
        }

        // Mutating the original must not disturb the copy.
        let original = copySamples[0]
        sourceSamples[0] = 0.99
        #expect(copySamples[0] == original)
    }
}

@Suite struct MeetingAudioRecorderTests {
    @Test func writesReadableCAFPerChannel() async throws {
        let directory = URL.temporaryDirectory.appending(path: "cheerio-rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let format = try makeTapFormat()
        let recorder = MeetingAudioRecorder(directory: directory)
        await recorder.start()

        let frames: AVAudioFrameCount = 512
        let bufferCount = 10
        for index in 0..<bufferCount {
            let mine = try makeBuffer(format: format, frames: frames, seed: 0.4)
            let theirs = try makeBuffer(format: format, frames: frames, seed: 0.8)
            recorder.submit(mine, channel: .me)
            recorder.submit(theirs, channel: .them)
            _ = index
        }
        await recorder.finish()

        for channel in [SpeakerChannel.me, .them] {
            let url = directory.appending(path: "\(channel.rawValue).caf")
            #expect(FileManager.default.fileExists(atPath: url.path), "missing \(channel.rawValue).caf")

            let file = try AVAudioFile(forReading: url)
            #expect(file.length == Int64(frames) * Int64(bufferCount))
            #expect(file.fileFormat.sampleRate == 48_000)
            #expect(file.fileFormat.channelCount == 2)
        }
    }

    @Test func finishIsSafeWithNoAudioSubmitted() async throws {
        let directory = URL.temporaryDirectory.appending(path: "cheerio-rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = MeetingAudioRecorder(directory: directory)
        await recorder.start()
        await recorder.finish()

        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(contents.isEmpty)
    }
}

@Suite struct AudioRetentionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func foreverNeverPurges() {
        #expect(AudioRetention.forever.purgeCutoff(now: now) == nil)
    }

    @Test func nonePurgesEverythingAlreadyFinished() {
        #expect(AudioRetention.none.purgeCutoff(now: now) == now)
    }

    @Test func windowedRetentionCutsOffNDaysBack() throws {
        let week = try #require(AudioRetention.week.purgeCutoff(now: now))
        #expect(week == now.addingTimeInterval(-7 * 86_400))

        let month = try #require(AudioRetention.month.purgeCutoff(now: now))
        #expect(month == now.addingTimeInterval(-30 * 86_400))
    }

    @Test func defaultIsSevenDays() {
        #expect(AudioRetention.default == .week)
        #expect(AudioRetention.default.rawValue == 7)
    }
}
