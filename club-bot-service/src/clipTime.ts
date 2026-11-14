// "🎬 Мой удар": the time a client types ("21:47", "21.47", "вчера 23:50")
// turned into a moment. Kept apart from index.ts so it can be tested.

export type DayInZone = { y: number; mo: number; d: number };
export type ToUtc = (y: number, mo: number, d: number, hh: number, mm: number) => Date;

const YESTERDAY = /вчера|kecha/i;

/** The moment the client means, or null if there is no time in the text.
 *  Today by default; "вчера"/"kecha" means yesterday; a time that is still to
 *  come today ("23:50" typed at 00:10) was yesterday's. */
export function parseClipMoment(
  text: string, now: Date, today: DayInZone, toUtc: ToUtc, fixedDay?: DayInZone,
): Date | null {
  const m = text.match(/(?<!\d)(\d{1,2})\s*[:.\-]\s*(\d{2})(?!\d)/);
  if (!m) return null;
  const hh = Number(m[1]);
  const mm = Number(m[2]);
  if (hh > 23 || mm > 59) return null;
  const back = (days: number) => {
    const day = new Date(Date.UTC(today.y, today.mo - 1, today.d - days));
    return toUtc(day.getUTCFullYear(), day.getUTCMonth() + 1, day.getUTCDate(), hh, mm);
  };
  // The client chose the day in the calendar: take it as it is.
  if (fixedDay) return toUtc(fixedDay.y, fixedDay.mo, fixedDay.d, hh, mm);
  if (YESTERDAY.test(text)) return back(1);
  const moment = back(0);
  return moment.getTime() > now.getTime() ? back(1) : moment;
}
