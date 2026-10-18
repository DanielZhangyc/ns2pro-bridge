import SwiftUI
import AppKit

struct ControllerInputDiagram: View {
    let buttons: UInt64
    let axes: [Double]

    // 坐标对应任天堂原图的 975×975 画布，缩放时与照片一起变化。
    // Coordinates use Nintendo's original 975×975 canvas and scale with the photograph.
    private static let markers: [(bit: Int, x: Double, y: Double, diameter: Double)] = [
        (0, 786, 365, 70), (1, 715, 426, 70), (2, 715, 304, 70), (3, 644, 366, 70),
        (10, 594, 296, 42), (11, 382, 296, 42),
        (12, 315, 489, 35), (13, 359, 447, 35), (14, 403, 489, 35), (15, 359, 533, 35),
        (16, 541, 365, 46), (17, 434, 365, 38), (18, 487, 555, 38)
    ]
    private static let image: NSImage = {
        guard let url = Bundle.main.url(forResource: "ns2-pro-front", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            preconditionFailure("Missing bundled controller photograph")
        }
        return image
    }()

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let scale = geometry.size.width / 975
                ZStack(alignment: .topLeading) {
                    Image(nsImage: Self.image).resizable().scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.width)
                    ForEach(Self.markers, id: \.bit) { marker in
                        if pressed(marker.bit) {
                            Circle().fill(Color.accentColor.opacity(0.55))
                                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                                .frame(width: marker.diameter * scale, height: marker.diameter * scale)
                                .position(x: marker.x * scale, y: marker.y * scale)
                        }
                    }
                    stick(x: 242, y: 364, axis: 0, bit: 4, scale: scale)
                    stick(x: 592, y: 489, axis: 2, bit: 5, scale: scale)
                }
                .frame(width: geometry.size.width, height: geometry.size.width)
                .offset(y: -150 * scale)
            }
            .aspectRatio(975.0 / 675, contentMode: .fit)
            .clipped()
            .accessibilityHidden(true)
            HStack(spacing: 12) {
                ForEach([(6, "L"), (8, "ZL"), (19, "GL"), (20, "GR"), (9, "ZR"), (7, "R")], id: \.0) { bit, name in
                    Text(name).font(.caption.monospaced().weight(.medium))
                        .foregroundStyle(pressed(bit) ? Color.accentColor : .secondary)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(pressed(bit) ? Color.accentColor.opacity(0.15) : .clear, in: Capsule())
                        .accessibilityLabel("\(name)，\(pressed(bit) ? "按下" : "松开")")
                }
            }
        }
        .frame(maxWidth: 400)
    }

    private func pressed(_ bit: Int) -> Bool { buttons & (UInt64(1) << bit) != 0 }

    private func stick(x: Double, y: Double, axis: Int, bit: Int, scale: Double) -> some View {
        ZStack {
            Circle().strokeBorder(pressed(bit) ? Color.accentColor : .white.opacity(0.6), lineWidth: 2)
                .frame(width: 110 * scale, height: 110 * scale)
            Circle().fill(Color.accentColor)
                .frame(width: 18 * scale, height: 18 * scale)
                .offset(x: axes[axis] * 40 * scale, y: -axes[axis + 1] * 40 * scale)
        }
        .position(x: x * scale, y: y * scale)
    }
}
