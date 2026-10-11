//
//  DiskFlasher.swift
//  hypergolic
//

import Foundation
import DiskArbitration

enum FlashError: LocalizedError {
    case diskNotFound(String)
    case internalDisk
    case emptyImage
    case imageTooLarge(image: Int64, device: Int64)
    case diskArbitration(String)
    case authorizationFailed
    case posix(operation: String, code: Int32)
    case unexpectedEndOfFile
    case verificationFailed(offset: Int64)

    var errorDescription: String? {
        switch self {
        case .diskNotFound(let bsdName):
            "The drive /dev/\(bsdName) could not be found."
        case .internalDisk:
            "Refusing to write to an internal disk."
        case .emptyImage:
            "The selected image is empty."
        case .imageTooLarge(let image, let device):
            "The image (\(image.formatted(.byteCount(style: .file)))) is larger than the drive (\(device.formatted(.byteCount(style: .file))))."
        case .diskArbitration(let reason):
            "The drive could not be unmounted: \(reason)"
        case .authorizationFailed:
            "Administrator authorization was denied or cancelled."
        case .posix(let operation, let code):
            "Failed to \(operation): \(String(cString: strerror(code)))"
        case .unexpectedEndOfFile:
            "Reached the end of the file unexpectedly."
        case .verificationFailed(let offset):
            "Verification failed: the drive contents differ from the image at byte \(offset)."
        }
    }
}

/// Writes a raw disk image (.iso / .img) to a whole external disk, reporting progress.
///
/// Writing to `/dev/rdiskN` requires root, so the device is opened through Apple's
/// `/usr/libexec/authopen`, which shows the standard administrator prompt and hands the
/// open file descriptor back over a Unix socket. The app itself never runs as root.
struct DiskFlasher {
    let imageURL: URL
    let bsdName: String
    var verify = true

    /// Size of each read/write. A multiple of every common sector size (512 / 4096).
    private static let chunkSize = 4 * 1024 * 1024

    /// Starts flashing and streams `.writing` / `.verifying` progress updates.
    /// Cancelling the consuming task cancels the write.
    func flash() -> AsyncThrowingStream<FlashState, Error> {
        AsyncThrowingStream { continuation in
            // The work is mostly blocking I/O, so keep it off the main actor.
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await run { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Flashing

    private func run(report: (FlashState) -> Void) async throws {
        let disk = try DiskSession(bsdName: bsdName)
        let description = disk.description

        // Double-check the target, in case the device list is stale.
        guard description[kDADiskDescriptionDeviceInternalKey] as? Bool == false else {
            throw FlashError.internalDisk
        }
        let deviceSize = (description[kDADiskDescriptionMediaSizeKey] as? NSNumber)?.int64Value ?? 0
        let reportedBlockSize = (description[kDADiskDescriptionMediaBlockSizeKey] as? NSNumber)?.intValue ?? 512
        let blockSize = reportedBlockSize > 0 && Self.chunkSize.isMultiple(of: reportedBlockSize)
            ? reportedBlockSize : 512

        let imageFD = open(imageURL.path, O_RDONLY)
        guard imageFD >= 0 else { throw FlashError.posix(operation: "open the image", code: errno) }
        defer { close(imageFD) }

        var info = stat()
        guard fstat(imageFD, &info) == 0 else { throw FlashError.posix(operation: "read the image size", code: errno) }
        let imageSize = Int64(info.st_size)
        guard imageSize > 0 else { throw FlashError.emptyImage }
        guard deviceSize == 0 || imageSize <= deviceSize else {
            throw FlashError.imageTooLarge(image: imageSize, device: deviceSize)
        }

        report(.writing(progress: 0))
        try await disk.unmount()
        try Task.checkCancellation()

        let deviceFD = try openWithAuthorization("/dev/r\(bsdName)")
        do {
            try write(from: imageFD, to: deviceFD, imageSize: imageSize, blockSize: blockSize, report: report)
            if verify {
                try verifyWrite(of: imageFD, on: deviceFD, imageSize: imageSize, blockSize: blockSize, report: report)
            }
            close(deviceFD)
        } catch {
            close(deviceFD)
            throw error
        }

        // Best effort: eject so macOS doesn't try to mount the freshly written partitions
        // (which often triggers a "disk not readable" alert for Linux images).
        try? await disk.unmount()
        try? await disk.eject()
    }

    private func write(from imageFD: Int32, to deviceFD: Int32, imageSize: Int64, blockSize: Int,
                       report: (FlashState) -> Void) throws {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.chunkSize, alignment: 4096)
        defer { buffer.deallocate() }

        var offset: Int64 = 0
        while offset < imageSize {
            try Task.checkCancellation()
            let length = Int(min(Int64(Self.chunkSize), imageSize - offset))
            try readFully(imageFD, into: buffer, count: length, at: offset)

            // Raw devices only accept whole sectors, so zero-pad the final partial chunk.
            let padded = roundUp(length, to: blockSize)
            if padded > length {
                (buffer + length).initializeMemory(as: UInt8.self, repeating: 0, count: padded - length)
            }
            try writeFully(deviceFD, from: buffer, count: padded, at: offset)

            offset += Int64(length)
            report(.writing(progress: Double(offset) / Double(imageSize)))
        }

        guard fsync(deviceFD) == 0 else { throw FlashError.posix(operation: "flush the drive", code: errno) }
    }

    private func verifyWrite(of imageFD: Int32, on deviceFD: Int32, imageSize: Int64, blockSize: Int,
                             report: (FlashState) -> Void) throws {
        let imageBuffer = UnsafeMutableRawPointer.allocate(byteCount: Self.chunkSize, alignment: 4096)
        let deviceBuffer = UnsafeMutableRawPointer.allocate(byteCount: Self.chunkSize, alignment: 4096)
        defer {
            imageBuffer.deallocate()
            deviceBuffer.deallocate()
        }

        report(.verifying(progress: 0))
        var offset: Int64 = 0
        while offset < imageSize {
            try Task.checkCancellation()
            let length = Int(min(Int64(Self.chunkSize), imageSize - offset))
            try readFully(imageFD, into: imageBuffer, count: length, at: offset)
            try readFully(deviceFD, into: deviceBuffer, count: roundUp(length, to: blockSize), at: offset)

            guard memcmp(imageBuffer, deviceBuffer, length) == 0 else {
                throw FlashError.verificationFailed(offset: offset)
            }

            offset += Int64(length)
            report(.verifying(progress: Double(offset) / Double(imageSize)))
        }
    }

    // MARK: Privileged open

    /// Opens `path` read/write via `authopen`, which prompts for administrator credentials
    /// and sends the resulting file descriptor back over a socket (`-stdoutpipe`).
    private func openWithAuthorization(_ path: String) throws -> Int32 {
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw FlashError.posix(operation: "create a socket pair", code: errno)
        }
        let receiver = sockets[0]
        defer { close(receiver) }
        let sender = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/authopen")
        process.arguments = ["-stdoutpipe", "-o", String(O_RDWR), path]
        process.standardOutput = sender
        try process.run()

        // Close our copy of the sending end so recvmsg sees EOF if authopen exits
        // without sending a descriptor (e.g. the user cancels the password prompt).
        try? sender.close()

        let fd = receiveFileDescriptor(from: receiver)
        process.waitUntilExit()

        guard let fd, process.terminationStatus == 0 else {
            if let fd { close(fd) }
            throw FlashError.authorizationFailed
        }
        return fd
    }

    /// Receives a single file descriptor sent with `SCM_RIGHTS` over a Unix socket.
    private func receiveFileDescriptor(from socket: Int32) -> Int32? {
        // Equivalent of CMSG_SPACE(sizeof(int)); the CMSG_* macros aren't available in Swift.
        let headerSize = MemoryLayout<cmsghdr>.size
        let controlLength = headerSize + MemoryLayout<Int32>.size
        let control = UnsafeMutableRawPointer.allocate(byteCount: controlLength,
                                                       alignment: MemoryLayout<cmsghdr>.alignment)
        defer { control.deallocate() }
        control.initializeMemory(as: UInt8.self, repeating: 0, count: controlLength)

        var data = [UInt8](repeating: 0, count: 64)
        return data.withUnsafeMutableBytes { dataBuffer -> Int32? in
            var iov = iovec(iov_base: dataBuffer.baseAddress, iov_len: dataBuffer.count)
            return withUnsafeMutablePointer(to: &iov) { iovPointer -> Int32? in
                var message = msghdr()
                message.msg_iov = iovPointer
                message.msg_iovlen = 1
                message.msg_control = control
                message.msg_controllen = socklen_t(controlLength)

                var received: Int
                repeat {
                    received = recvmsg(socket, &message, 0)
                } while received < 0 && errno == EINTR

                guard received > 0, Int(message.msg_controllen) >= controlLength else { return nil }
                let header = control.load(as: cmsghdr.self)
                guard header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_RIGHTS else { return nil }
                return control.load(fromByteOffset: headerSize, as: Int32.self)
            }
        }
    }

    // MARK: I/O helpers

    private func readFully(_ fd: Int32, into buffer: UnsafeMutableRawPointer, count: Int, at offset: Int64) throws {
        var done = 0
        while done < count {
            let result = pread(fd, buffer + done, count - done, off_t(offset) + off_t(done))
            if result < 0 {
                if errno == EINTR { continue }
                throw FlashError.posix(operation: "read", code: errno)
            }
            guard result > 0 else { throw FlashError.unexpectedEndOfFile }
            done += result
        }
    }

    private func writeFully(_ fd: Int32, from buffer: UnsafeRawPointer, count: Int, at offset: Int64) throws {
        var done = 0
        while done < count {
            let result = pwrite(fd, buffer + done, count - done, off_t(offset) + off_t(done))
            if result < 0 {
                if errno == EINTR { continue }
                throw FlashError.posix(operation: "write to the drive", code: errno)
            }
            done += result
        }
    }

    private func roundUp(_ value: Int, to multiple: Int) -> Int {
        (value + multiple - 1) / multiple * multiple
    }
}

// MARK: - Disk Arbitration

/// A Disk Arbitration session for one disk, with async unmount / eject.
private final class DiskSession {
    let session: DASession
    let disk: DADisk
    private let queue = DispatchQueue(label: "com.saulnunez.hypergolic.diskarbitration")

    init(bsdName: String) throws {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else {
            throw FlashError.diskNotFound(bsdName)
        }
        self.session = session
        self.disk = disk
        DASessionSetDispatchQueue(session, queue)
    }

    deinit {
        DASessionSetDispatchQueue(session, nil)
    }

    var description: NSDictionary {
        DADiskCopyDescription(disk) as NSDictionary? ?? [:]
    }

    /// Unmounts every volume on the whole disk.
    func unmount() async throws {
        try await perform { disk, callback, context in
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionWhole), callback, context)
        }
    }

    func eject() async throws {
        try await perform { disk, callback, context in
            DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), callback, context)
        }
    }

    /// Bridges a Disk Arbitration completion callback to async/await. The continuation is
    /// passed through the C context pointer, since C callbacks can't capture.
    private func perform(_ operation: (DADisk, DADiskUnmountCallback, UnsafeMutableRawPointer) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let context = Unmanaged.passRetained(ContinuationBox(continuation)).toOpaque()
            operation(disk, { _, dissenter, context in
                guard let context else { return }
                let box = Unmanaged<ContinuationBox>.fromOpaque(context).takeRetainedValue()
                if let dissenter {
                    let status = UInt32(bitPattern: DADissenterGetStatus(dissenter))
                    let reason = DADissenterGetStatusString(dissenter) as String?
                    box.continuation.resume(throwing: FlashError.diskArbitration(
                        reason ?? String(format: "error 0x%08X", status)))
                } else {
                    box.continuation.resume()
                }
            }, context)
        }
    }
}

private final class ContinuationBox {
    let continuation: CheckedContinuation<Void, Error>

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }
}
