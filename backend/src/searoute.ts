// Sea routing over OpenStreetMap's ferry network.
//
// Apple Maps draws the faint ferry lines you see between islands from OSM,
// where every ferry line is a `route=ferry` way with full geometry. Nobody
// publishes per-sailing tracks (Ferryhopper carries none, and AIS needs an
// MMSI we don't have), but the LINE a service follows is mapped — so a
// sailing can be drawn along it instead of as a straight stroke across
// whatever islands lie between the ports.
//
// This module is pure: it takes the ways Overpass returned and finds the
// shortest path along them between two ports. Fetching lives in the route
// handler so this can be tested without a network.

export interface OSMWay {
  id: number;
  nodes: number[];
  geometry: { lat: number; lon: number }[];
}

export type LatLon = [number, number];

const R = 6371;
export function haversineKm(a: LatLon, b: LatLon): number {
  const toRad = (d: number) => d * Math.PI / 180;
  const dLat = toRad(b[0] - a[0]), dLon = toRad(b[1] - a[1]);
  const h = Math.sin(dLat / 2) ** 2
    + Math.cos(toRad(a[0])) * Math.cos(toRad(b[0])) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

interface Graph {
  pos: Map<number, LatLon>;
  adj: Map<number, { to: number; w: number }[]>;
}

/// Consecutive nodes of each way are edges. Ways mapped as separate lines
/// that meet at a port rarely share a node, so endpoints within `bridgeKm`
/// of each other are joined — that is what lets a path change line at a
/// port of call.
export function buildFerryGraph(ways: OSMWay[], bridgeKm = 0.4): Graph {
  const pos = new Map<number, LatLon>();
  const adj = new Map<number, { to: number; w: number }[]>();
  const add = (u: number, v: number, w: number) => {
    if (!adj.has(u)) adj.set(u, []);
    if (!adj.has(v)) adj.set(v, []);
    adj.get(u)!.push({ to: v, w });
    adj.get(v)!.push({ to: u, w });
  };
  for (const way of ways) {
    if (!way.nodes || !way.geometry || way.nodes.length !== way.geometry.length) continue;
    way.nodes.forEach((id, i) => pos.set(id, [way.geometry[i].lat, way.geometry[i].lon]));
    for (let i = 0; i + 1 < way.nodes.length; i++) {
      add(way.nodes[i], way.nodes[i + 1],
          haversineKm(pos.get(way.nodes[i])!, pos.get(way.nodes[i + 1])!));
    }
  }
  const ends = [...new Set(ways.flatMap(w => w.nodes?.length ? [w.nodes[0], w.nodes[w.nodes.length - 1]] : []))];
  for (let i = 0; i < ends.length; i++) {
    for (let j = i + 1; j < ends.length; j++) {
      const a = pos.get(ends[i]), b = pos.get(ends[j]);
      if (!a || !b) continue;
      const d = haversineKm(a, b);
      if (d > 0 && d < bridgeKm) add(ends[i], ends[j], d);
    }
  }
  return { pos, adj };
}

/// Shortest path along the ferry network from `from` to `to`.
///
/// Snapping is the subtle part. Every ferry line ends at its own quay, so
/// "the nearest node to Piraeus" belongs to whichever line happens to berth
/// closest — and if that line doesn't go where we're going, the only route
/// left may wander via Crete. Instead a virtual source reaches EVERY node
/// within `snapKm` of the port (cost: twice the straight distance, so a
/// nearer quay still wins when lines are otherwise equal), likewise the
/// target, and Dijkstra picks the line that actually serves the pair.
///
/// Returns null when either port is off the network or the two are not
/// connected — the caller draws its fallback and says nothing.
export function routeAlongFerries(
  graph: Graph, from: LatLon, to: LatLon, snapKm = 4,
): { path: LatLon[]; km: number } | null {
  const S: { n: number; d: number }[] = [], T: { n: number; d: number }[] = [];
  for (const [n, p] of graph.pos) {
    const ds = haversineKm(from, p); if (ds <= snapKm) S.push({ n, d: ds });
    const dt = haversineKm(to, p);   if (dt <= snapKm) T.push({ n, d: dt });
  }
  if (!S.length || !T.length) return null;
  const targetCost = new Map(T.map(t => [t.n, t.d * 2]));

  const SRC = -1, DST = -2;
  const dist = new Map<number, number>([[SRC, 0]]);
  const prev = new Map<number, number>();
  // Binary heap keyed by distance.
  const heap: { d: number; n: number }[] = [{ d: 0, n: SRC }];
  const push = (d: number, n: number) => {
    heap.push({ d, n }); let i = heap.length - 1;
    while (i > 0) { const p = (i - 1) >> 1; if (heap[p].d <= heap[i].d) break; [heap[p], heap[i]] = [heap[i], heap[p]]; i = p; }
  };
  const pop = () => {
    const top = heap[0], last = heap.pop()!;
    if (heap.length) { heap[0] = last; let i = 0;
      for (;;) { const l = 2 * i + 1, r = l + 1; let m = i;
        if (l < heap.length && heap[l].d < heap[m].d) m = l;
        if (r < heap.length && heap[r].d < heap[m].d) m = r;
        if (m === i) break; [heap[m], heap[i]] = [heap[i], heap[m]]; i = m; } }
    return top;
  };
  while (heap.length) {
    const { d, n } = pop();
    if (n === DST) break;
    if (d > (dist.get(n) ?? Infinity)) continue;
    const edges: { to: number; w: number }[] = n === SRC
      ? S.map(s => ({ to: s.n, w: s.d * 2 }))
      : [...(graph.adj.get(n) ?? []), ...(targetCost.has(n) ? [{ to: DST, w: targetCost.get(n)! }] : [])];
    for (const e of edges) {
      const nd = d + e.w;
      if (nd < (dist.get(e.to) ?? Infinity)) { dist.set(e.to, nd); prev.set(e.to, n); push(nd, e.to); }
    }
  }
  if (!dist.has(DST)) return null;
  const nodes: number[] = [];
  for (let cur = prev.get(DST)!; cur !== SRC; cur = prev.get(cur)!) nodes.push(cur);
  nodes.reverse();
  const path: LatLon[] = [from, ...nodes.map(n => graph.pos.get(n)!), to];
  return { path, km: dist.get(DST)! };
}

/// Douglas–Peucker, so a route with hundreds of survey points travels as a
/// few dozen without visibly changing shape at any zoom the app draws.
export function simplify(path: LatLon[], toleranceKm = 0.15): LatLon[] {
  if (path.length <= 2) return path;
  const keep = new Array(path.length).fill(false);
  keep[0] = keep[path.length - 1] = true;
  const perp = (p: LatLon, a: LatLon, b: LatLon) => {
    // Distance from p to segment ab in km, in a local equirectangular frame.
    const kx = Math.cos((a[0] * Math.PI) / 180) * 111.32, ky = 110.57;
    const px = (p[1] - a[1]) * kx, py = (p[0] - a[0]) * ky;
    const bx = (b[1] - a[1]) * kx, by = (b[0] - a[0]) * ky;
    const len2 = bx * bx + by * by;
    const t = len2 ? Math.max(0, Math.min(1, (px * bx + py * by) / len2)) : 0;
    return Math.hypot(px - t * bx, py - t * by);
  };
  const stack: [number, number][] = [[0, path.length - 1]];
  while (stack.length) {
    const [i, j] = stack.pop()!;
    let maxD = 0, maxK = -1;
    for (let k = i + 1; k < j; k++) {
      const d = perp(path[k], path[i], path[j]);
      if (d > maxD) { maxD = d; maxK = k; }
    }
    if (maxD > toleranceKm && maxK > 0) { keep[maxK] = true; stack.push([i, maxK], [maxK, j]); }
  }
  return path.filter((_, i) => keep[i]);
}

/// The Overpass QL for every ferry way in a box around the two ports, padded
/// so a route that swings wide of the straight line is still inside.
export function overpassQuery(from: LatLon, to: LatLon, padDeg = 0.35): string {
  const s = Math.min(from[0], to[0]) - padDeg, n = Math.max(from[0], to[0]) + padDeg;
  const w = Math.min(from[1], to[1]) - padDeg, e = Math.max(from[1], to[1]) + padDeg;
  return `[out:json][timeout:25];way["route"="ferry"](${s.toFixed(3)},${w.toFixed(3)},${n.toFixed(3)},${e.toFixed(3)});out geom qt;`;
}
