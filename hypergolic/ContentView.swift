//
//  ContentView.swift
//  hypergolic
//
//  Created by Saúl Núñez Castruita on 09/06/25.
//

import SwiftUI
import UniformTypeIdentifiers
import Foundation
import DiskArbitration
import IOKit

extension UTType {
    public static let iso = UTType(filenameExtension: "iso") ?? .diskImage
    public static let img = UTType(filenameExtension: "img") ?? .diskImage
}

// MARK: - Flash state

enum FlashState: Equatable {
    case idle
    case writing(progress: Double)
    case verifying(progress: Double)
    case finished
    case failed(message: String)
}

// MARK: - Main view

struct ContentView: View {
    @State private var imageURL: URL?
    @State private var selectedDeviceID: MassStorageDevice.ID?
    @State private var connectedDevices = MassStorageDevices()
    @State private var flashState: FlashState = .idle
    @State private var showFileImporter = false
    @State private var showConfirmation = false

    private var selectedDevice: MassStorageDevice? {
        connectedDevices.devices.first { $0.id == selectedDeviceID }
    }

    private var isBusy: Bool {
        switch flashState {
        case .writing, .verifying: true
        default: false
        }
    }

    private var canFlash: Bool {
        imageURL != nil && selectedDevice != nil && !isBusy
    }

    var body: some View {
        VStack(spacing: 24) {
            header

            HStack(alignment: .top, spacing: 16) {
                imageStep
                Image(systemName: "chevron.right")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 80)
                driveStep
                Image(systemName: "chevron.right")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 80)
                flashStep
            }

            statusFooter
        }
        .padding(24)
        .frame(minWidth: 820, minHeight: 440)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.iso, .img],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                imageURL = urls.first
                flashState = .idle
            case .failure(let error):
                flashState = .failed(message: error.localizedDescription)
            }
        }
        .confirmationDialog(
            "Erase \(selectedDevice?.deviceModel ?? "drive")?",
            isPresented: $showConfirmation
        ) {
            Button("Erase and Flash", role: .destructive) {
                startFlashing()
            }
        } message: {
            Text("All data on /dev/\(selectedDevice?.bsdName ?? "") will be permanently erased.")
        }
        .task {
            connectedDevices.loadDevices()
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(spacing: 4) {
            Image(systemName: "flame.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange.gradient)
            Text("hypergolic")
                .font(.largeTitle.bold())
            Text("Write .iso and .img files to external drives")
                .foregroundStyle(.secondary)
        }
    }

    private var imageStep: some View {
        StepCard(number: 1, title: "Image", systemImage: "opticaldisc") {
            if let imageURL {
                VStack(spacing: 4) {
                    Text(imageURL.lastPathComponent)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    if let size = fileSize(of: imageURL) {
                        Text(size.formatted(.byteCount(style: .file)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Change…") { showFileImporter = true }
                    .disabled(isBusy)
            } else {
                Text("No image selected")
                    .foregroundStyle(.secondary)
                Button("Select Image…") { showFileImporter = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var driveStep: some View {
        StepCard(number: 2, title: "Target", systemImage: "externaldrive") {
            if connectedDevices.devices.isEmpty {
                Text("No external drives found")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Drive", selection: $selectedDeviceID) {
                    Text("Select a drive").tag(MassStorageDevice.ID?.none)
                    ForEach(connectedDevices.devices) { device in
                        Text("\(device.deviceModel) (\(device.formattedSize))")
                            .tag(Optional(device.id))
                    }
                }
                .labelsHidden()
                .disabled(isBusy)

                if let selectedDevice {
                    Text("/dev/\(selectedDevice.bsdName)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Button("Refresh", systemImage: "arrow.clockwise") {
                connectedDevices.loadDevices()
                if selectedDevice == nil { selectedDeviceID = nil }
            }
            .disabled(isBusy)
        }
    }

    private var flashStep: some View {
        StepCard(number: 3, title: "Flash", systemImage: "bolt.fill") {
            switch flashState {
            case .writing(let progress):
                ProgressView("Writing…", value: progress)
            case .verifying(let progress):
                ProgressView("Verifying…", value: progress)
            case .finished:
                Label("Done", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .idle, .failed:
                Text(canFlash ? "Ready to flash" : "Select an image and a drive")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button("Flash!") { showConfirmation = true }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.large)
                .disabled(!canFlash)
        }
    }

    @ViewBuilder
    private var statusFooter: some View {
        if case .failed(let message) = flashState {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        } else {
            Label("Make sure you selected the right drive — it will be completely erased.",
                  systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private func startFlashing() {
        // TODO: Implement the actual write (unmount via DiskArbitration, then copy the
        // image to /dev/rdiskN with elevated privileges) and report progress here.
        flashState = .writing(progress: 0)
    }

    private func fileSize(of url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize.map(Int64.init)
    }
}

// MARK: - Step card

/// A titled, numbered card used for each step of the flashing flow.
struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(.orange.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: systemImage)
                    .font(.title)
                    .foregroundStyle(.orange)
            }
            Text("\(number). \(title)")
                .font(.title3.bold())

            content
        }
        .frame(maxWidth: .infinity, minHeight: 240, alignment: .top)
        .padding()
        .background(.background.secondary, in: .rect(cornerRadius: 16))
    }
}

// MARK: - Devices

struct MassStorageDevice: Identifiable, Hashable {
    var id: String { bsdName }
    var deviceModel: String
    var bsdName: String
    var size: Int64

    var formattedSize: String {
        size.formatted(.byteCount(style: .file))
    }
}

@Observable class MassStorageDevices {
    var devices = [MassStorageDevice]()

    /// Enumerates whole, external (non-internal) disks using IOKit + DiskArbitration.
    func loadDevices() {
        devices.removeAll()

        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            print("Failed to create Disk Arbitration session.")
            return
        }

        // Match only whole disks (e.g. disk4), not their partitions (disk4s1).
        let matching = IOServiceMatching(kIOMediaClass) as NSMutableDictionary
        matching[kIOMediaWholeKey] = true

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            print("Failed to get matching services.")
            return
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let bsdName = IORegistryEntryCreateCFProperty(service, kIOBSDNameKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String,
               let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName),
               let desc = DADiskCopyDescription(disk) as NSDictionary? {
                let isInternal = desc[kDADiskDescriptionDeviceInternalKey] as? Bool ?? true
                let isVirtual = (desc[kDADiskDescriptionDeviceProtocolKey] as? String) == "Virtual Interface"

                if !isInternal && !isVirtual {
                    let model = (desc[kDADiskDescriptionDeviceModelKey] as? String)?
                        .trimmingCharacters(in: .whitespaces) ?? "Unknown Drive"
                    let size = (desc[kDADiskDescriptionMediaSizeKey] as? NSNumber)?.int64Value ?? 0
                    devices.append(MassStorageDevice(deviceModel: model, bsdName: bsdName, size: size))
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }
}

#Preview {
    ContentView()
}
