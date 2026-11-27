import SwiftUI
import UIKit

/// Take a photo of a player's leftover tiles, count the pips, and let the player check the total.
struct PipCountView: View {
    let playerName: String
    let onUse: (Int) -> Void
    let onCancel: () -> Void

    @State private var picking = true
    @State private var photo: UIImage?
    @State private var result: CountPipeline.Output?
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
                            .overlay { barTint }
                            .overlay { marks }
                            .overlay { labels }
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    if let result {
                        Text("\(result.total) pips on \(result.halves.count) halves")
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

    /// Each divider bar, covered by a semi-transparent white bar with a green tint on top.
    private var barTint: some View {
        GeometryReader { g in
            let sx = g.size.width / Double(result?.workW ?? 1), sy = g.size.height / Double(result?.workH ?? 1)
            ForEach(Array((result?.bars ?? []).enumerated()), id: \.offset) { _, b in
                ZStack {
                    Rectangle().fill(Color.white.opacity(0.6))
                    Rectangle().fill(Color(red: 0.1, green: 0.8, blue: 0.2).opacity(0.45))
                }
                .frame(width: (b.len + 4) * sx, height: (b.thick + 4) * sx)
                .rotationEffect(.radians(atan2(b.dy, b.dx)))
                .position(x: b.cx * sx, y: b.cy * sy)
            }
        }
        .allowsHitTesting(false)
    }

    /// A small dot on every pip that was counted; the dots blink between red and green.
    private var marks: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let green = Int(timeline.date.timeIntervalSinceReferenceDate / 0.5) % 2 == 1
            GeometryReader { g in
                ForEach(Array((result?.pips ?? []).enumerated()), id: \.offset) { _, r in
                    let size = 0.5 * max(r.width * g.size.width, r.height * g.size.height)
                    Circle()
                        .fill(green ? Color.green : Color.red)
                        .frame(width: size, height: size)
                        .position(x: r.midX * g.size.width, y: r.midY * g.size.height)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// The pip count of each half, in white with a black outline, centered on the half.
    private var labels: some View {
        GeometryReader { g in
            ForEach(Array((result?.halves ?? []).enumerated()), id: \.offset) { _, half in
                let t = result?.tiles.first.map { min($0.B, $0.A / 2) / Double(result?.workH ?? 1) } ?? 0.04
                let size = max(14, t * g.size.height * 0.55)
                ZStack {
                    ForEach(Array([(-1.0, 0.0), (1.0, 0.0), (0.0, -1.0), (0.0, 1.0)].enumerated()), id: \.offset) { _, d in
                        Text("\(half.count)").font(.system(size: size, weight: .bold)).foregroundStyle(.black).offset(x: d.0 * 1.5, y: d.1 * 1.5)
                    }
                    Text("\(half.count)").font(.system(size: size, weight: .bold)).foregroundStyle(.white)
                }
                .position(x: half.center.x * g.size.width, y: half.center.y * g.size.height)
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
        guard let cg = upright.cgImage else { return }
        Task.detached(priority: .userInitiated) {
            let found = CountPipeline.run(cg)
            await MainActor.run { result = found; points = found.total }
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
