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

extension UTType {
    public static let iso = UTType(filenameExtension: "iso")
    public static let img = UTType(filenameExtension: "img")
}

struct ContentView: View {
    let pickerValues = ["One", "Two", "Three"]
    @State private var selection = "Test"
    
    var body: some View {
        VStack {
            Picker("External device ", selection: $selection) {
                                pickerContent()
                            }
                            .padding()
            FilePicker()
        }
        .padding()
    }



    
    @ViewBuilder
        func pickerContent() -> some View {
            ForEach(pickerValues, id: \.self) {
                Text($0)
            }
        }
}

struct FilePicker: View {
    @State var fileName: String = ""
    @State var showFileImporter = false
    @State var connectedDevices = MassStorageDevices()
    
    var body: some View {
        VStack(spacing: 25) {
        Text(fileName)
        Button("Open Document Picker") {
        showFileImporter.toggle()
        }
        .fileImporter(
        isPresented: $showFileImporter,
        allowedContentTypes: [.iso!, .img!],
        allowsMultipleSelection: false
        ) { result in
        switch result {
            case .success(let urls):
                if let firstURL = urls.first {
                    fileName = firstURL.lastPathComponent
                }
                case .failure(let error):
                    print("Error reading file: \(error.localizedDescription)")
                }
            }
        }
    }
}

@Observable class MassStorageDevice: Identifiable
{
    var deviceModel: String = ""
    var volumeKind: String = ""
    var bsdName: String = ""
}

@Observable class MassStorageDevices {
    var devices = [MassStorageDevice]();
    
    fun loadDevices(){
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            print("Failed to create Disk Arbitration session.")
            return
        }

        let matchingDict = IOBSDNameMatching(kIOMainPortDefault, 0, "")
        let serviceIterator = UnsafeMutablePointer<io_iterator_t>.allocate(capacity: 1)
        defer { serviceIterator.deallocate() }

        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, serviceIterator)
        guard result == KERN_SUCCESS else {
            print("Failed to get matching services.")
            return
        }

        var service = IOIteratorNext(serviceIterator.pointee)
        while service != 0 {
            if let bsdName = IORegistryEntryCreateCFProperty(service, kIOBSDNameKey as CFString, kCFAllocatorDefault, 0)?.takeUnretainedValue() as? String {
                if let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, "/dev/\(bsdName)") {
                    if let desc = DADiskCopyDescription(disk) as NSDictionary? {
                        if let volumeKind = desc[kDADiskDescriptionVolumeKindKey] as? String,
                           let deviceModel = desc[kDADiskDescriptionDeviceModelKey] as? String {
                            //print("Device: \(deviceModel), Volume Kind: \(volumeKind), BSD Name: \(bsdName)")
                            devices.append(MassStorageDevice(deviceModel, volumeKind, bsdName))
                        }
                    }
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(serviceIterator.pointee)
        }
    }
    
}

#Preview {
    ContentView()
}
