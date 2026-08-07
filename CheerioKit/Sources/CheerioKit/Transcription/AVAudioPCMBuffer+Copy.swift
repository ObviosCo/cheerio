import AVFoundation

extension AVAudioPCMBuffer {
    /// Deep-copies the samples into a newly allocated, independently owned buffer.
    ///
    /// Buffers vended by an AVAudioEngine tap or a Core Audio IOProc are only valid
    /// for the duration of that callback — the framework recycles the backing storage
    /// as soon as it returns. Anything that outlives the callback (everything we hand
    /// to a `TranscriptionEngine`) has to own its samples.
    public func detachedCopy() -> sending AVAudioPCMBuffer? {
        // Copying bytes out of our own buffer list makes region isolation treat the
        // fresh allocation as part of `self`'s region. It is a new object that nothing
        // else references, so transferring it out is sound.
        UnsafeTransfer(value: makeDetachedCopy()).value
    }

    /// The format is rebuilt from the stream description rather than reused so the
    /// result shares no reference with `self`.
    private func makeDetachedCopy() -> AVAudioPCMBuffer? {
        var streamDescription = format.streamDescription.pointee
        let detachedFormat: AVAudioFormat?
        if let layoutTag = format.channelLayout?.layoutTag,
           let layout = AVAudioChannelLayout(layoutTag: layoutTag) {
            detachedFormat = AVAudioFormat(streamDescription: &streamDescription, channelLayout: layout)
        } else {
            detachedFormat = AVAudioFormat(streamDescription: &streamDescription)
        }
        guard let detachedFormat,
              let copy = AVAudioPCMBuffer(pcmFormat: detachedFormat, frameCapacity: frameLength)
        else { return nil }
        copy.frameLength = frameLength

        let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in 0..<source.count {
            guard let sourceData = source[index].mData,
                  let destinationData = destination[index].mData
            else { return nil }
            let byteCount = min(source[index].mDataByteSize, destination[index].mDataByteSize)
            destinationData.copyMemory(from: sourceData, byteCount: Int(byteCount))
        }
        return copy
    }
}
