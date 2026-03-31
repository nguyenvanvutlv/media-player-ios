import Foundation

/// Thread-safe bounded packet queue for the demux→decode pipeline.
/// One producer (demux thread) pushes cloned packets; one consumer (decode thread) takes them.
/// When full, the producer BLOCKS until space is available, preventing corrupted streams.
final class PacketQueue {
    private let condition = NSCondition()
    private var ring: [UnsafeMutablePointer<AVPacket>?]
    private var head = 0
    private var tail = 0
    private var count_: Int = 0
    private var closed = false
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = max(4, capacity)
        self.ring = [UnsafeMutablePointer<AVPacket>?](repeating: nil, count: self.capacity)
    }

    deinit {
        flush()
    }

    /// Number of queued packets.
    var count: Int {
        condition.lock()
        defer { condition.unlock() }
        return count_
    }

    /// Push a **clone** of the packet into the queue.
    /// If full, blocks until space is available or the queue is closed/flushed.
    /// Returns `false` if the queue is closed.
    @discardableResult
    func put(_ packet: UnsafeMutablePointer<AVPacket>) -> Bool {
        condition.lock()
        while count_ >= capacity && !closed {
            condition.wait()
        }
        if closed {
            condition.unlock()
            return false
        }
        
        // Clone the packet so the caller can unref the original.
        let clone = av_packet_alloc()!
        av_packet_ref(clone, packet)

        ring[tail] = clone
        tail = (tail + 1) % capacity
        count_ += 1
        
        condition.signal() // wake up any waiting consumer
        condition.unlock()
        return true
    }

    /// Blocking take. Returns `nil` if the queue is closed (or flushed while waiting).
    /// `timeoutMs`: max wait in ms; 0 = indefinite.
    func take(timeoutMs: Int = 200) -> UnsafeMutablePointer<AVPacket>? {
        condition.lock()
        
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        
        while count_ == 0 && !closed {
            if timeoutMs > 0 {
                let signaled = condition.wait(until: deadline)
                if !signaled && count_ == 0 {
                    // Timed out
                    break
                }
            } else {
                condition.wait()
            }
        }
        
        if closed && count_ == 0 {
            condition.unlock()
            return nil
        }
        
        if count_ > 0 {
            let pkt = ring[head]
            ring[head] = nil
            head = (head + 1) % capacity
            count_ -= 1
            condition.signal() // wake up waiting producer
            condition.unlock()
            return pkt
        }
        
        condition.unlock()
        return nil
    }

    /// Flush all packets (used on seek). Wakes blocked consumers and producers.
    func flush() {
        condition.lock()
        while count_ > 0 {
            if let pkt = ring[head] {
                av_packet_unref(pkt)
                av_packet_free_ptr(pkt)
                ring[head] = nil
            }
            head = (head + 1) % capacity
            count_ -= 1
        }
        head = 0
        tail = 0
        condition.broadcast() // Wake any blocked consumer or producer
        condition.unlock()
    }

    /// Close the queue: flush + prevent new pushes. Wake blocked consumers and producers.
    func close() {
        condition.lock()
        closed = true
        // Flush remaining.
        while count_ > 0 {
            if let pkt = ring[head] {
                av_packet_unref(pkt)
                av_packet_free_ptr(pkt)
                ring[head] = nil
            }
            head = (head + 1) % capacity
            count_ -= 1
        }
        head = 0
        tail = 0
        condition.broadcast()
        condition.unlock()
    }

    /// Reopen after close (for new session or after seek).
    func reopen() {
        condition.lock()
        closed = false
        head = 0
        tail = 0
        count_ = 0
        condition.unlock()
    }
}

/// Helper to free an `AVPacket` pointer (since `av_packet_free` takes `UnsafeMutablePointer<UnsafeMutablePointer<AVPacket>?>` in C).
private func av_packet_free_ptr(_ pkt: UnsafeMutablePointer<AVPacket>) {
    var p: UnsafeMutablePointer<AVPacket>? = pkt
    av_packet_free(&p)
}
