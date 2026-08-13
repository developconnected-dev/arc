// Route geometry — pure, no network. Turns a provider's encoded polyline into
// the handful of points a map line actually needs.
//
// A train does not travel in a straight line, and Arc's map was drawing one:
// every leg went through a great-circle arc, which is exactly right for a plane
// and false for rail. Berlin→Basel rendered as a line across open countryside
// rather than routing via Frankfurt and Mannheim — plausible enough to go
// unnoticed, and wrong.
//
// MOTIS publishes the real track as an encoded polyline. The catch is size: one
// ICE run is 19,407 points and 110 KB, which is absurd to store per leg, mirror
// to Supabase and push through a widget payload for a line a few hundred pixels
// wide. So it is decoded and simplified here, and the app receives roughly 3 KB
// of coordinates it can hand straight to MapPolyline.

/// Decode a Google-style encoded polyline.
///
/// `precision` matters: the format is usually precision 5, but MOTIS reports 7
/// and says so in the payload. Decoding a precision-7 string as precision 5
/// silently puts every point 100× too far from the origin — coordinates land in
/// the thousands of degrees, which is not an error anything throws on, just a
/// line that vanishes off the map. Always pass what the provider states.
export function decodePolyline(encoded: unknown, precision = 5): [number, number][] {
  const str = String(encoded ?? "");
  const factor = Math.pow(10, precision);
  const out: [number, number][] = [];
  let index = 0, lat = 0, lon = 0;
  while (index < str.length) {
    let b: number, shift = 0, result = 0;
    do {
      b = str.charCodeAt(index++) - 63;
      if (isNaN(b)) return out;             // truncated input: keep what decoded
      result |= (b & 0x1f) << shift; shift += 5;
    } while (b >= 0x20);
    lat += (result & 1) ? ~(result >> 1) : (result >> 1);
    shift = 0; result = 0;
    do {
      b = str.charCodeAt(index++) - 63;
      if (isNaN(b)) return out;
      result |= (b & 0x1f) << shift; shift += 5;
    } while (b >= 0x20);
    lon += (result & 1) ? ~(result >> 1) : (result >> 1);
    out.push([lat / factor, lon / factor]);
  }
  return out;
}

/// Squared distance from p to the segment a→b, in degrees².
function segmentDistanceSq(p: number[], a: number[], b: number[]): number {
  const [x, y] = p, [x1, y1] = a, [x2, y2] = b;
  const dx = x2 - x1, dy = y2 - y1;
  if (dx === 0 && dy === 0) return (x - x1) ** 2 + (y - y1) ** 2;
  const t = Math.max(0, Math.min(1, ((x - x1) * dx + (y - y1) * dy) / (dx * dx + dy * dy)));
  return (x - (x1 + t * dx)) ** 2 + (y - (y1 + t * dy)) ** 2;
}

/// Ramer–Douglas–Peucker: drop points that sit within `epsilon` of the line
/// their neighbours already describe.
///
/// Iterative rather than recursive on purpose — a 19,000-point track recurses
/// deep enough to risk the stack in a Worker, and blowing the stack here would
/// take the whole search response with it.
export function simplify(points: [number, number][], epsilon: number): [number, number][] {
  if (points.length < 3 || epsilon <= 0) return points;
  const keep = new Uint8Array(points.length);
  keep[0] = 1; keep[points.length - 1] = 1;
  const stack: [number, number][] = [[0, points.length - 1]];
  const epsSq = epsilon * epsilon;
  while (stack.length) {
    const [first, last] = stack.pop()!;
    let index = -1, maxSq = 0;
    for (let i = first + 1; i < last; i++) {
      const d = segmentDistanceSq(points[i], points[first], points[last]);
      if (d > maxSq) { maxSq = d; index = i; }
    }
    if (index >= 0 && maxSq > epsSq) {
      keep[index] = 1;
      stack.push([first, index], [index, last]);
    }
  }
  const out: [number, number][] = [];
  for (let i = 0; i < points.length; i++) if (keep[i]) out.push(points[i]);
  return out;
}

/// ~200 m at European latitudes. Chosen by looking at what it costs and what it
/// keeps: an ICE run drops from 19,407 points to a few hundred while every bend
/// visible at map zoom survives. Tighter buys detail no one can see; looser
/// starts cutting real curves into chords.
export const ROUTE_EPSILON = 0.002;

/// The drawable path for a transit leg, or null when the provider gave none.
///
/// Returns flat [lat, lon] pairs because that is what survives JSON, SwiftData
/// and the Supabase mirror without a bespoke type at each layer.
export function routePath(
  leg: Record<string, any>,
  epsilon = ROUTE_EPSILON,
): [number, number][] | null {
  const geom = leg?.legGeometry;
  const encoded = geom?.points;
  if (typeof encoded !== "string" || !encoded) return null;
  const decoded = decodePolyline(encoded, Number(geom?.precision ?? 5));
  if (decoded.length < 2) return null;
  const reduced = simplify(decoded, epsilon);
  // A path that survives simplification down to its two endpoints carries no
  // more information than the straight line the map would draw anyway.
  return reduced.length >= 3 ? reduced : null;
}
