// Date supplies calendar/timezone parsing, but cannot retain sub-ms precision.
// ISO inputs are validated at the HTTP boundary before reaching these helpers.
export function timestampMicros(value) {
  const fraction = value.match(/\.(\d+)(?:Z|[+-]\d{2}:\d{2})$/i)?.[1] ?? '';
  return BigInt(Date.parse(value)) * 1000n + BigInt(fraction.padEnd(6, '0').slice(3, 6));
}

export function formatMicros(value) {
  const remainder = ((value % 1000n) + 1000n) % 1000n;
  const iso = new Date(Number((value - remainder) / 1000n)).toISOString();
  return remainder === 0n ? iso : iso.replace('Z', `${remainder.toString().padStart(3, '0')}Z`);
}

export function compareTimes(a, b) {
  const delta = timestampMicros(a) - timestampMicros(b);
  return delta < 0n ? -1 : delta > 0n ? 1 : 0;
}
