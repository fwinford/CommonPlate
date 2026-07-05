// Shared date formatting helpers for meal request windows
export function formatMealRequestWindow(start?: string | Date, end?: string | Date, fallback?: string) {
  // If a human-readable fallback was provided (e.g. generated earlier by the app)
  // prefer it when it looks like a formatted window (contains AM/PM or a month name).
  if (fallback && /\b(AM|PM)\b|Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec/i.test(fallback)) {
    return fallback;
  }
  if (!start && !end) return fallback || 'Time window not specified';
  try {
    const s = start ? new Date(start) : null;
    const e = end ? new Date(end) : null;
    const optsDate: Intl.DateTimeFormatOptions = { month: 'short', day: 'numeric' };
    const optsTime: Intl.DateTimeFormatOptions = { hour: 'numeric', minute: '2-digit', hour12: true, timeZone: 'America/New_York' };

    if (s && e) {
      const sameDay = s.toLocaleDateString('en-US', { timeZone: 'America/New_York' }) === e.toLocaleDateString('en-US', { timeZone: 'America/New_York' });
      if (sameDay) {
        return `${s.toLocaleDateString('en-US', optsDate)}, ${s.toLocaleTimeString('en-US', optsTime)} – ${e.toLocaleTimeString('en-US', optsTime)}`;
      }
      return `${s.toLocaleString('en-US', { ...optsDate, ...optsTime })} – ${e.toLocaleString('en-US', { ...optsDate, ...optsTime })}`;
    }

    if (s) return `${s.toLocaleDateString('en-US', optsDate)}, ${s.toLocaleTimeString('en-US', optsTime)}`;
    if (e) return `Until ${e.toLocaleString('en-US', { ...optsDate, ...optsTime })}`;
    return fallback || 'Time window not specified';
  } catch {
    // safe fallback: present raw ISO in NY timezone
    if (start) return new Date(start).toLocaleString('en-US', { timeZone: 'America/New_York' });
    if (end) return new Date(end).toLocaleString('en-US', { timeZone: 'America/New_York' });
    return fallback || 'Time window not specified';
  }
}
