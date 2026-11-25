import SwiftUI
import UIKit

/// Take a photo of a player's leftover tiles, count the pips, and let the player check the total.
struct PipCountView: View {
    let playerName: String
    let onUse: (Int) -> Void
    let onCancel: () -> Void

    @State private var picking = true
    @State private var photo: UIImage?
    @State private var result: PipCounter.Result?
    @State private var points = 0

    var body: some View {
        if picking {
            ImagePicker { image in
                if let image {
                    photo = image
                    result = nil
                    picking = false
                    analyze(image)
                } else if photo == nil {
                    onCancel()
                } else {
                    picking = false
                }
            }
            .ignoresSafeArea()
        } else {
            NavigationStack {
                VStack(spacing: 16) {
                    if let photo {
                        Image(uiImage: photo)
                            .resizable()
                            .scaledToFit()
                            .overlay { marks }
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    if let result {
                        Text(result.count == 1 ? "Found 1 pip" : "Found \(result.count) pips")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView("Counting…")
                    }
                    HStack {
                        Text("Points").font(.title2)
                        Spacer()
                        Stepper(value: $points, in: 0...999) {
                            Text("\(points)").font(.system(size: 40, weight: .semibold)).monospacedDigit()
                        }
                        .fixedSize()
                    }
                    .padding(.horizontal)
                    Button("Retake Photo", systemImage: "camera") { picking = true }
                    Spacer(minLength: 0)
                }
                .padding()
                .navigationTitle(playerName.isEmpty ? "Count Pips" : "\(playerName)'s Pips")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Use \(points)") { onUse(points) }.disabled(result == nil)
                    }
                }
            }
        }
    }

    /// A bright red dot on every pip that was counted.
    private var marks: some View {
        GeometryReader { g in
            ForEach(Array((result?.pips ?? []).enumerated()), id: \.offset) { _, r in
                let size = max(r.width * g.size.width, r.height * g.size.height)
                Circle()
                    .fill(Color.red)
                    .frame(width: size, height: size)
                    .position(x: r.midX * g.size.width, y: r.midY * g.size.height)
            }
        }
        .allowsHitTesting(false)
    }

    private func analyze(_ image: UIImage) {
        // Redraw upright (camera photos carry a rotation flag), at most 1600 pixels across.
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, 1600 / max(longest, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let upright = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let cg = upright.cgImage else { result = .init(pips: []); return }
        Task.detached(priority: .userInitiated) {
            let found = PipCounter.count(cg)
            await MainActor.run {
                result = found
                points = found.count
            }
        }
    }
}

/// The system camera (or, where there is none, such as the Simulator, the photo library).
private struct ImagePicker: UIViewControllerRepresentable {
    let onPick: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: (UIImage?) -> Void
        init(onPick: @escaping (UIImage?) -> Void) { self.onPick = onPick }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onPick(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onPick(nil) }
    }
}
