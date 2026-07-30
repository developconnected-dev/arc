import SwiftUI

/// A side-profile airliner drawn from an `AircraftProfile`, nose to the left.
///
/// One shape rather than a stack of overlapping fills: a single path unions
/// cleanly, so a translucent tint doesn't show seams where the wing meets the
/// fuselage. No background, no frame — it floats on the glass and takes its
/// colour from `foregroundStyle`.
struct AircraftSilhouette: Shape {
    var profile: AircraftProfile = .narrowbody

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()

        // Laid out from the top down, the way the real dimensions stack:
        // fin tip, fuselage top, fuselage bottom, then gear/engine clearance.
        // That keeps the centre line honest instead of guessed.
        let half = h * profile.fuselage / 2
        let cy = h * (profile.finHeight + profile.fuselage / 2)
        let nose = w * 0.03
        let tail = w * 0.97
        let noseEnd = nose + w * profile.noseLength
        let upsweep = h * profile.tailUpsweep

        // Fuselage: rounded nose, straight spine, belly sweeping up to a
        // pointed tail cone — the belly rises further than the spine, which is
        // what gives an airliner its tail.
        path.move(to: CGPoint(x: nose, y: cy + half * 0.15))
        path.addQuadCurve(to: CGPoint(x: noseEnd, y: cy - half),
                          control: CGPoint(x: nose + w * 0.01, y: cy - half))
        path.addLine(to: CGPoint(x: tail - w * 0.13, y: cy - half))
        path.addQuadCurve(to: CGPoint(x: tail, y: cy - half - upsweep),
                          control: CGPoint(x: tail - w * 0.05, y: cy - half - upsweep))
        path.addQuadCurve(to: CGPoint(x: tail - w * 0.20, y: cy + half),
                          control: CGPoint(x: tail - w * 0.08, y: cy + half))
        path.addLine(to: CGPoint(x: noseEnd - w * 0.01, y: cy + half))
        path.addQuadCurve(to: CGPoint(x: nose, y: cy + half * 0.15),
                          control: CGPoint(x: nose + w * 0.005, y: cy + half))
        path.closeSubpath()

        // Upper deck. The 747 hump sits forward and fairs back into the spine;
        // the A380 carries it the whole length, so its fuselage is simply
        // deeper and no extra shape is needed.
        if profile.deck == .foreHump {
            var hump = Path()
            let humpTop = cy - half - h * 0.085
            hump.move(to: CGPoint(x: noseEnd - w * 0.03, y: cy - half))
            hump.addQuadCurve(to: CGPoint(x: noseEnd + w * 0.05, y: humpTop),
                              control: CGPoint(x: noseEnd - w * 0.005, y: humpTop))
            hump.addLine(to: CGPoint(x: noseEnd + w * 0.17, y: humpTop))
            hump.addQuadCurve(to: CGPoint(x: noseEnd + w * 0.32, y: cy - half),
                              control: CGPoint(x: noseEnd + w * 0.28, y: cy - half))
            hump.closeSubpath()
            path.addPath(hump)
        }

        // Vertical fin: swept leading edge, tip near the top of the box.
        let finTop = h * 0.02
        let finBase = tail - w * profile.finChord
        var fin = Path()
        fin.move(to: CGPoint(x: finBase - w * 0.02, y: cy - half))
        fin.addLine(to: CGPoint(x: finBase + w * profile.finChord * 0.80, y: finTop))
        fin.addLine(to: CGPoint(x: tail - w * 0.005, y: finTop))
        fin.addQuadCurve(to: CGPoint(x: tail - w * 0.02, y: cy - half),
                         control: CGPoint(x: tail, y: cy - half - upsweep))
        fin.closeSubpath()
        path.addPath(fin)

        // Tailplane: atop the fin on a T-tail, on the rear fuselage otherwise.
        let tailplaneY = profile.tailplane == .tMount ? finTop + h * 0.02 : cy - half - upsweep * 0.3
        var tailplane = Path()
        tailplane.move(to: CGPoint(x: finBase + w * 0.03, y: tailplaneY + h * 0.02))
        tailplane.addLine(to: CGPoint(x: tail + w * 0.02, y: tailplaneY - h * 0.02))
        tailplane.addLine(to: CGPoint(x: tail + w * 0.02, y: tailplaneY + h * 0.005))
        tailplane.addLine(to: CGPoint(x: finBase + w * 0.03, y: tailplaneY + h * 0.05))
        tailplane.closeSubpath()
        path.addPath(tailplane)

        // Wing. Side-on, most of the wing is hidden behind the fuselage — what
        // actually shows is the root fairing and, below it, the engines. Drawing
        // a big swept blade merged everything into one blob under the belly, so
        // this is deliberately a short fairing rather than a whole wing.
        let isProp = profile.engines.isTurboprop
        let rootX = w * profile.wingRoot
        let rootY = isProp ? cy - half * 0.95 : cy + half * 0.75
        var wing = Path()
        if isProp {
            // A high wing sits proud of the spine, so it does read side-on.
            wing.addRoundedRect(in: CGRect(x: rootX - w * 0.04, y: rootY - h * 0.03,
                                           width: w * profile.wingChord * 2.2, height: h * 0.045),
                                cornerSize: CGSize(width: h * 0.02, height: h * 0.02))
        } else {
            wing.move(to: CGPoint(x: rootX - w * profile.wingChord * 0.6, y: cy + half * 0.2))
            wing.addLine(to: CGPoint(x: rootX + w * profile.wingChord, y: rootY + h * 0.055))
            wing.addLine(to: CGPoint(x: rootX + w * profile.wingChord * 0.45, y: rootY + h * 0.055))
            wing.addLine(to: CGPoint(x: rootX - w * profile.wingChord * 0.6, y: cy + half))
            wing.closeSubpath()
        }
        path.addPath(wing)

        path.addPath(engines(w: w, h: h, cy: cy, half: half,
                             rootX: rootX, rootY: rootY, tail: tail))
        return path
    }

    /// Engines are where the families read most distinctly: pods under the
    /// wing, pods on the rear fuselage, or props on the leading edge.
    private func engines(w: CGFloat, h: CGFloat, cy: CGFloat, half: CGFloat,
                         rootX: CGFloat, rootY: CGFloat, tail: CGFloat) -> Path {
        var path = Path()
        switch profile.engines {
        case .underwing(let count):
            // A twin shows one pod side-on; a quad shows inboard and outboard,
            // which is what makes four engines recognisable in profile.
            let pods: [CGFloat] = count >= 4 ? [-0.01, 0.10] : [0.0]
            for dx in pods {
                let pod = CGRect(x: rootX + w * dx, y: rootY + h * 0.02,
                                 width: w * 0.125, height: h * 0.125)
                path.addRoundedRect(in: pod, cornerSize: CGSize(width: h * 0.06, height: h * 0.06))
            }
        case .rearFuselage:
            let pod = CGRect(x: tail - w * 0.30, y: cy - half - h * 0.075,
                             width: w * 0.13, height: h * 0.105)
            path.addRoundedRect(in: pod, cornerSize: CGSize(width: h * 0.05, height: h * 0.05))
        case .turboprop:
            let nacelle = CGRect(x: rootX - w * 0.03, y: cy - half * 1.15,
                                 width: w * 0.17, height: h * 0.095)
            path.addRoundedRect(in: nacelle, cornerSize: CGSize(width: h * 0.045, height: h * 0.045))
            // Propeller disc seen edge-on: a slim blade ahead of the nacelle.
            path.addRoundedRect(in: CGRect(x: rootX - w * 0.045, y: cy - half * 2.05,
                                           width: w * 0.016, height: h * 0.30),
                                cornerSize: CGSize(width: w * 0.008, height: w * 0.008))
        }
        return path
    }
}

private extension AircraftProfile.Engines {
    var isTurboprop: Bool { if case .turboprop = self { return true } else { return false } }
}

/// The silhouette for a given aircraft type, tinted and free of any background.
///
/// A `Shape` filled with the caller's colour, so it behaves like a template
/// image would — white on the dark "Where's My Plane" card, accent-coloured in
/// Passport — while staying vector-crisp at any size.
struct AircraftArt: View {
    let type: String?
    var color: Color = .white

    var body: some View {
        AircraftSilhouette(profile: AircraftImage.profile(for: type))
            .fill(color)
            .aspectRatio(AircraftImage.profile(for: type).aspect, contentMode: .fit)
            .accessibilityLabel(Text(type ?? "Aircraft"))
    }
}
