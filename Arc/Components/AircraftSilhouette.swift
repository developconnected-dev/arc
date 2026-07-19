import SwiftUI

/// An original, stylised side-profile airliner silhouette (nose left), drawn from
/// primitive shapes so there's no third-party artwork. Tinted by `color`.
/// `wide` gives a twin-aisle proportion (longer, taller tail).
struct AircraftSilhouette: View {
    var color: Color = .white
    var wide: Bool = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let cy = h * 0.56                     // fuselage centre line
            let fuseH = h * (wide ? 0.26 : 0.22)  // fuselage thickness
            let noseX = w * 0.06
            let tailX = w * 0.90

            ZStack {
                // Wing (swept, seen side-on as a slim triangle going down-back)
                Path { p in
                    p.move(to: CGPoint(x: w * 0.44, y: cy))
                    p.addLine(to: CGPoint(x: w * 0.70, y: cy + h * 0.20))
                    p.addLine(to: CGPoint(x: w * 0.60, y: cy + h * 0.20))
                    p.addLine(to: CGPoint(x: w * 0.40, y: cy + fuseH * 0.3))
                    p.closeSubpath()
                }
                .fill(color.opacity(0.85))

                // Engine pod under the wing
                Capsule()
                    .fill(color.opacity(0.9))
                    .frame(width: w * 0.11, height: h * 0.10)
                    .position(x: w * 0.5, y: cy + fuseH * 0.75)

                // Vertical tail fin (swept back)
                Path { p in
                    p.move(to: CGPoint(x: tailX - w * 0.10, y: cy - fuseH * 0.3))
                    p.addLine(to: CGPoint(x: tailX + w * 0.04, y: h * (wide ? 0.10 : 0.14)))
                    p.addLine(to: CGPoint(x: tailX - w * 0.02, y: h * (wide ? 0.10 : 0.14)))
                    p.addLine(to: CGPoint(x: tailX - w * 0.20, y: cy - fuseH * 0.3))
                    p.closeSubpath()
                }
                .fill(color)

                // Fuselage: long rounded body with a tapered nose
                Path { p in
                    let top = cy - fuseH / 2
                    let bot = cy + fuseH / 2
                    p.move(to: CGPoint(x: noseX, y: cy))
                    p.addQuadCurve(to: CGPoint(x: noseX + w * 0.10, y: top),
                                   control: CGPoint(x: noseX, y: top))
                    p.addLine(to: CGPoint(x: tailX - w * 0.02, y: top))
                    p.addQuadCurve(to: CGPoint(x: tailX + w * 0.06, y: cy - fuseH * 0.1),
                                   control: CGPoint(x: tailX + w * 0.03, y: top))
                    p.addQuadCurve(to: CGPoint(x: tailX - w * 0.02, y: bot),
                                   control: CGPoint(x: tailX + w * 0.06, y: cy + fuseH * 0.3))
                    p.addLine(to: CGPoint(x: noseX + w * 0.10, y: bot))
                    p.addQuadCurve(to: CGPoint(x: noseX, y: cy),
                                   control: CGPoint(x: noseX, y: bot))
                    p.closeSubpath()
                }
                .fill(color)
            }
        }
    }
}

/// Prefers a bundled `Image` asset if present, else the drawn silhouette.
struct AircraftArt: View {
    let type: String?
    var color: Color = .white
    var body: some View {
        let asset = AircraftImage.assetName(for: type)
        if UIImage(named: asset) != nil {
            Image(asset).resizable().scaledToFit()
        } else {
            AircraftSilhouette(color: color, wide: AircraftImage.isWide(type))
        }
    }
}
