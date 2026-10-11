//
//  ImageReader.swift
//  hypergolic
//

import Foundation
import Compression

/// Sequential source of raw image bytes, hiding whether the file is compressed.
protocol ImageReader: AnyObject {
    /// Size of the raw (uncompressed) image, if known before reading it.
    var expectedSize: Int64? { get }
    /// Fraction of the source file consumed so far. Used for progress when `expectedSize` is unknown.
    var sourceProgress: Double { get }
    /// Reads up to `count` bytes. Returns fewer than `count` only at the end of the image.
    func read(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int
}

/// Opens a reader for `url`, decompressing on the fly for `.xz` files.
func makeImageReader(for url: URL) throws -> ImageReader {
    if url.pathExtension.lowercased() == "xz" {
        try XZImageReader(url: url)
    } else {
        try RawImageReader(url: url)
    }
}

// MARK: - Raw images

/// Reads an uncompressed .iso / .img file as-is.
final class RawImageReader: ImageReader {
    private let file: ImageFile
    private var offset: Int64 = 0

    var expectedSize: Int64? { file.size }
    var sourceProgress: Double { Double(offset) / Double(max(file.size, 1)) }

    init(url: URL) throws {
        file = try ImageFile(url: url)
    }

    func read(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int {
        var done = 0
        while done < count {
            let result = try file.read(into: buffer + done, count: count - done)
            guard result > 0 else { break }
            done += result
        }
        offset += Int64(done)
        return done
    }
}

// MARK: - xz images

/// Decompresses an .xz file using the Compression framework, whose LZMA decoder
/// understands the xz container format.
final class XZImageReader: ImageReader {
    private static let inputCapacity = 1024 * 1024

    private let file: ImageFile
    private let stream: UnsafeMutablePointer<compression_stream>
    private let input: UnsafeMutablePointer<UInt8>
    private var sourceRead: Int64 = 0
    private var reachedEndOfInput = false
    private var reachedEndOfStream = false

    let expectedSize: Int64?

    var sourceProgress: Double {
        // Count only input the decoder has actually consumed.
        Double(sourceRead - Int64(stream.pointee.src_size)) / Double(max(file.size, 1))
    }

    init(url: URL) throws {
        let file = try ImageFile(url: url)
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) == COMPRESSION_STATUS_OK else {
            stream.deallocate()
            throw FlashError.corruptImage
        }

        self.file = file
        self.stream = stream
        self.input = .allocate(capacity: Self.inputCapacity)
        self.expectedSize = XZIndex.uncompressedSize(of: file)
        stream.pointee.src_ptr = UnsafePointer(input)
        stream.pointee.src_size = 0
    }

    deinit {
        compression_stream_destroy(stream)
        stream.deallocate()
        input.deallocate()
    }

    func read(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int {
        let output = buffer.bindMemory(to: UInt8.self, capacity: count)
        var produced = 0

        while produced < count && !reachedEndOfStream {
            // Refill the input buffer once the decoder has consumed it.
            if stream.pointee.src_size == 0 && !reachedEndOfInput {
                let length = try file.read(into: input, count: Self.inputCapacity)
                sourceRead += Int64(length)
                reachedEndOfInput = length == 0
                stream.pointee.src_ptr = UnsafePointer(input)
                stream.pointee.src_size = length
            }

            let available = count - produced
            let inputBefore = stream.pointee.src_size
            stream.pointee.dst_ptr = output + produced
            stream.pointee.dst_size = available

            let flags = reachedEndOfInput ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status = compression_stream_process(stream, flags)
            let written = available - stream.pointee.dst_size
            produced += written

            switch status {
            case COMPRESSION_STATUS_OK:
                // Out of input and making no progress means the file was truncated.
                if reachedEndOfInput && written == 0 && inputBefore == stream.pointee.src_size {
                    throw FlashError.corruptImage
                }
            case COMPRESSION_STATUS_END:
                reachedEndOfStream = true
            default:
                throw FlashError.corruptImage
            }
        }
        return produced
    }
}

/// Reads the uncompressed size from the index at the end of an xz stream, without
/// decompressing anything. See the "Index" section of the .xz file format spec.
enum XZIndex {
    private static let headerSize: Int64 = 12
    private static let footerSize: Int64 = 12

    /// Returns `nil` if the file can't be parsed, or holds several concatenated streams.
    static func uncompressedSize(of file: ImageFile) -> Int64? {
        // Skip optional stream padding: null bytes in multiples of four.
        var end = file.size
        while end >= headerSize + footerSize, let word = file.bytes(at: end - 4, count: 4), word.allSatisfy({ $0 == 0 }) {
            end -= 4
        }
        guard end >= headerSize + footerSize,
              let footer = file.bytes(at: end - footerSize, count: Int(footerSize)),
              footer[10] == 0x59, footer[11] == 0x5A else { return nil } // "YZ"

        // Backward Size is stored as (real size / 4) - 1, little-endian.
        let storedSize = footer[4..<8].reversed().reduce(0) { Int64($0) << 8 | Int64($1) }
        let indexSize = (storedSize + 1) * 4
        let indexStart = end - footerSize - indexSize
        guard indexStart >= headerSize, indexSize <= 64 * 1024 * 1024,
              let index = file.bytes(at: indexStart, count: Int(indexSize)),
              index.first == 0x00 else { return nil } // Index Indicator

        var position = 1
        guard let recordCount = readVarint(index, &position), recordCount < Int64(index.count) else { return nil }

        var uncompressedTotal: Int64 = 0
        var blocksTotal: Int64 = 0
        for _ in 0..<recordCount {
            guard let unpaddedSize = readVarint(index, &position),
                  let uncompressedSize = readVarint(index, &position) else { return nil }
            uncompressedTotal += uncompressedSize
            blocksTotal += (unpaddedSize + 3) & ~3
        }

        // Only trust the index if this single stream spans the whole file.
        guard headerSize + blocksTotal + indexSize + footerSize == end else { return nil }
        return uncompressedTotal
    }

    /// Decodes an xz variable-length integer (7 bits per byte, least significant first).
    private static func readVarint(_ bytes: [UInt8], _ position: inout Int) -> Int64? {
        var value: Int64 = 0
        for shift in stride(from: 0, to: 63, by: 7) {
            guard position < bytes.count else { return nil }
            let byte = bytes[position]
            position += 1
            value |= Int64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
        }
        return nil
    }
}

// MARK: - File access

/// A read-only file descriptor with its size.
final class ImageFile {
    let descriptor: Int32
    let size: Int64

    init(url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw FlashError.posix(operation: "open the image", code: errno) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = errno
            close(descriptor)
            throw FlashError.posix(operation: "read the image size", code: code)
        }
        self.descriptor = descriptor
        self.size = Int64(info.st_size)
    }

    deinit {
        close(descriptor)
    }

    /// Sequential read from the current position. Returns 0 at end of file.
    func read(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int {
        while true {
            let result = Darwin.read(descriptor, buffer, count)
            if result >= 0 { return result }
            if errno != EINTR { throw FlashError.posix(operation: "read the image", code: errno) }
        }
    }

    /// Reads exactly `count` bytes at `offset` without moving the read position.
    func bytes(at offset: Int64, count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        let result = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, count, off_t(offset)) }
        return result == count ? bytes : nil
    }
}
