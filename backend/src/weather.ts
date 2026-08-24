/// Airport weather, normalised: METAR (observed now) and the TAF period that
/// covers a departure time. The app scores the risk from these numbers, so the
/// thresholds stay testable in Swift rather than buried in a Worker.
///
/// Kept out of index.ts because index.ts cannot be imported by the test runner
/// (it pulls the Worker's whole world in), and this is exactly the part that
/// broke in the field.

/// Rows out of an aviationweather.gov response, tolerantly.
///
/// The provider answers 204 with an EMPTY BODY for a station it doesn't
/// publish — LGSO (Syros) has a METAR but no TAF. `res.ok` is TRUE for 204,
/// so `await res.json()` threw "Unexpected end of JSON input" and the whole
/// request became a 500 on a flight-detail screen. An airport nobody forecasts
/// is a normal fact about the world, not an error, so every way the provider
/// can decline — 204, empty 200, an HTML error page, a non-array, a refused
/// connection — collapses to "no rows".
export async function wxRows(res: Response | null | undefined): Promise<Record<string, any>[]> {
  if (!res || !res.ok || res.status === 204) return [];
  let body: string;
  try { body = await res.text(); } catch { return []; }
  if (!body.trim()) return [];
  let parsed: unknown;
  try { parsed = JSON.parse(body); } catch { return []; }
  return Array.isArray(parsed) ? parsed as Record<string, any>[] : [];
}

export interface AirportWeatherPayload {
  ok: true;
  icao: string;
  now: {
    category: string | null;
    visibilityM: number | null;
    ceilingFt: number | null;
    windKt: number | null;
    gustKt: number | null;
    wx: string | null;
    observed: string | null;
  } | null;
  atTime: {
    visibilityM: number | null;
    ceilingFt: number | null;
    windKt: number | null;
    gustKt: number | null;
    windShear: boolean;
    wx: string | null;
    from: number | null;
    to: number | null;
  } | null;
}

/// Either half may be missing and the payload is still ok: `now` null means
/// no observation, `atTime` null means nothing is forecast for that hour.
export function airportWeatherPayload(
  icao: string,
  atSec: number,
  metarRows: Record<string, any>[],
  tafRows: Record<string, any>[],
): AirportWeatherPayload {
  const metar = metarRows[0] ?? null;
  const taf = tafRows[0] ?? null;

  // The forecast period that contains the departure time.
  let period: Record<string, any> | null = null;
  for (const f of (taf?.fcsts ?? []) as Record<string, any>[]) {
    if (f.timeFrom <= atSec && atSec < (f.timeTo ?? f.timeFrom)) { period = f; break; }
  }
  // Past the end of the TAF: fall back to its last period rather than
  // reporting nothing at all.
  if (!period && (taf?.fcsts?.length ?? 0) > 0) period = taf.fcsts[taf.fcsts.length - 1];

  return {
    ok: true,
    icao,
    now: metar ? {
      category: metar.fltCat ?? null,
      visibilityM: metersFromVisibility(metar.visib),
      ceilingFt: lowestCeiling(metar.clouds),
      windKt: numberOrNull(metar.wspd),
      gustKt: numberOrNull(metar.wgst),
      wx: metar.wxString ?? null,
      observed: metar.reportTime ?? null,
    } : null,
    atTime: period ? {
      visibilityM: metersFromVisibility(period.visib),
      ceilingFt: lowestCeiling(period.clouds),
      windKt: numberOrNull(period.wspd),
      gustKt: numberOrNull(period.wgst),
      windShear: period.wshearSpd != null,
      wx: period.wxString ?? null,
      from: period.timeFrom ?? null,
      to: period.timeTo ?? null,
    } : null,
  };
}

export function numberOrNull(v: unknown): number | null {
  return typeof v === "number" && isFinite(v) ? v : null;
}

/// METAR/TAF visibility comes as statute miles, sometimes as "6+" — normalise
/// to metres so one set of thresholds works everywhere.
export function metersFromVisibility(v: unknown): number | null {
  if (typeof v === "number") return Math.round(v * 1609.34);
  if (typeof v === "string") {
    const n = parseFloat(v.replace("+", ""));
    if (!isNaN(n)) return Math.round(n * 1609.34);
  }
  return null;
}

/// Lowest broken/overcast layer — that's the operational ceiling; scattered
/// and few layers don't count.
export function lowestCeiling(clouds: unknown): number | null {
  if (!Array.isArray(clouds)) return null;
  let lowest: number | null = null;
  for (const layer of clouds as Record<string, any>[]) {
    const cover = String(layer.cover ?? "").toUpperCase();
    if (cover !== "BKN" && cover !== "OVC" && cover !== "OVX") continue;
    const base = numberOrNull(layer.base);
    if (base != null && (lowest == null || base < lowest)) lowest = base;
  }
  return lowest;
}
