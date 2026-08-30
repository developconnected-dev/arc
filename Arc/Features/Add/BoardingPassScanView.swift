import SwiftUI
import VisionKit
import AVFoundation

/// Point the camera at any boarding pass — paper, mobile, a screenshot on
/// another phone — and the BCBP barcode hands over flight number, date,
/// route, seat and booking code in one deterministic decode. No AI call,
/// no provider call, works with no network at all: exactly the input a
/// traveller is holding at the moment they most want the flight in Arc.
struct BoardingPassScanSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onFound: (BoardingPass) -> Void
    /// Tracked explicitly because `DataScannerViewController.isAvailable`
    /// is true only once access is GRANTED — on the first-ever tap it still
    /// reads false, and gating on it alone showed "allow in Settings" to a
    /// user who had never been asked. The tap on the scan button is the
    /// context the question needs, so undecided access prompts right here.
    @State private var cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        NavigationStack {
            Group {
                if !DataScannerViewController.isSupported {
                    fallback("This device can't scan barcodes.")
                } else {
                    switch cameraAccess {
                    case .authorized:
                        if DataScannerViewController.isAvailable {
                            BoardingPassScanView(onFound: onFound)
                                .ignoresSafeArea()
                        } else {
                            fallback("The camera can't start right now — close any app using it and try again.")
                        }
                    case .notDetermined:
                        ProgressView()
                            .task {
                                _ = await AVCaptureDevice.requestAccess(for: .video)
                                cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
                            }
                    default:
                        // Denied or restricted — say which action fixes it
                        // rather than showing black.
                        fallback("Allow camera access in Settings to scan boarding passes.")
                    }
                }
            }
            .navigationTitle("Scan Boarding Pass")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func fallback(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.badge.ellipsis")
                .font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("Camera unavailable")
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}

private struct BoardingPassScanView: UIViewControllerRepresentable {
    let onFound: (BoardingPass) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            // Every symbology BCBP ships in: PDF417 on paper, Aztec and QR on
            // mobile passes. Anything else the parser rejects by shape.
            recognizedDataTypes: [.barcode(symbologies: [.pdf417, .aztec, .qr, .dataMatrix])],
            qualityLevel: .accurate,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        try? scanner.startScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onFound: (BoardingPass) -> Void
        /// One decode per presentation: the camera keeps seeing the same
        /// barcode thirty times a second, and every sighting after the
        /// first would re-fire the whole add flow.
        private var done = false

        init(onFound: @escaping (BoardingPass) -> Void) { self.onFound = onFound }

        func dataScanner(_ scanner: DataScannerViewController,
                         didAdd added: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for case .barcode(let code) in added {
                guard let payload = code.payloadStringValue,
                      let pass = BoardingPass.parse(payload) else { continue }
                done = true
                scanner.stopScanning()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onFound(pass)
                return
            }
        }
    }
}
