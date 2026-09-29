// Authoritative API validation. Flutter also validates for quick feedback, but
// every client—including future hardware—must pass these server checks.
export const CHANNEL_COUNT = 16;
export const MAX_SAMPLES_PER_REQUEST = 1000;

// A distinct error type is safer than guessing status codes from message text.
export class ValidationError extends Error {}

// JSON arrays are objects in JavaScript, so explicitly reject them here.
function requireObject(value, name) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new ValidationError(`${name} must be a JSON object`);
  }
  return value;
}

// Trim human-entered fields once, then enforce small documented limits.
function cleanText(value, name, maximum, { allowEmpty = false } = {}) {
  if (typeof value !== 'string') {
    throw new ValidationError(`${name} must be a string`);
  }
  const result = value.trim();
  if (!allowEmpty && result.length === 0) {
    throw new ValidationError(`${name} is required`);
  }
  if (result.length > maximum) {
    throw new ValidationError(`${name} must be ${maximum} characters or fewer`);
  }
  return result;
}

// Parse only explicit ISO-like timestamps. The calendar round-trip catches dates
// JavaScript would otherwise normalize silently, such as February 30.
function normalizeTimestamp(value, name) {
  if (typeof value !== 'string') {
    throw new ValidationError(`${name} must be a valid timestamp with a timezone`);
  }
  const match = value.match(
    /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})$/i,
  );
  const parsed = Date.parse(value);
  const day = match ? new Date(`${match[1]}-${match[2]}-${match[3]}T00:00:00.000Z`) : null;
  const validDay = day && Number.isFinite(day.valueOf()) &&
    day.toISOString().slice(0, 10) === `${match[1]}-${match[2]}-${match[3]}`;
  const validTime = match && Number(match[4]) <= 23 &&
    Number(match[5]) <= 59 && Number(match[6]) <= 59;
  if (!match || !Number.isFinite(parsed) || !validDay || !validTime) {
    throw new ValidationError(`${name} must be a valid timestamp with a timezone`);
  }
  return new Date(parsed).toISOString();
}

// PostgreSQL reports malformed UUIDs as database errors; reject them earlier with
// a useful 400 response instead.
export function validateUuid(value, name = 'id') {
  if (typeof value !== 'string' ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)) {
    throw new ValidationError(`${name} must be a valid UUID`);
  }
  return value;
}

// Return new normalized objects rather than mutating Express request bodies.
export function validateDevice(value) {
  const body = requireObject(value, 'request body');
  return {
    deviceName: cleanText(body.deviceName, 'deviceName', 100),
    serialNumber: cleanText(body.serialNumber, 'serialNumber', 100),
  };
}

export function validateSession(value) {
  const body = requireObject(value, 'request body');
  return {
    deviceId: validateUuid(body.deviceId, 'deviceId'),
    sessionName: cleanText(body.sessionName, 'sessionName', 120),
    startTime: normalizeTimestamp(body.startTime, 'startTime'),
    notes: body.notes === undefined ? '' : cleanText(body.notes, 'notes', 2000, {allowEmpty: true}),
  };
}

// History boundaries deliberately require Z because the UI labels them as UTC.
export function validateRange(query) {
  const result = {};
  for (const name of ['from', 'to']) {
    const value = query[name];
    if (value === undefined) continue;
    if (typeof value !== 'string' ||
        !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$/.test(value) ||
        !Number.isFinite(Date.parse(value)) ||
        new Date(value).toISOString().slice(0, 19) !== value.slice(0, 19)) {
      throw new ValidationError(`${name} must be a valid UTC timestamp ending in Z`);
    }
    result[name] = new Date(value).toISOString();
  }
  if (result.from && result.to && result.from > result.to) {
    throw new ValidationError('from must be before or equal to to');
  }
  return result;
}

export function validateSamples(samples) {
  // The upper bound prevents one request from producing an unbounded query loop.
  if (!Array.isArray(samples) || samples.length === 0) {
    throw new ValidationError("samples must be a non-empty array");
  }
  if (samples.length > MAX_SAMPLES_PER_REQUEST) {
    throw new ValidationError(`samples must contain ${MAX_SAMPLES_PER_REQUEST} items or fewer`);
  }

  // Include array indexes in messages so a bad frame is easy to locate.
  return samples.map((sample, sampleIndex) => {
    if (!sample || sample.recordedAt === undefined) throw new ValidationError("recordedAt is required");
    const recordedAt = normalizeTimestamp(sample.recordedAt, `samples[${sampleIndex}].recordedAt`);
    if (!Array.isArray(sample.channels) || sample.channels.length !== CHANNEL_COUNT) {
      throw new ValidationError(`samples[${sampleIndex}].channels must contain exactly ${CHANNEL_COUNT} values`);
    }

    // Number.isFinite rejects strings, NaN, and infinities as well as bad ranges.
    const channels = sample.channels.map((voltage, channel) => {
      if (!Number.isFinite(voltage) || voltage < -5 || voltage > 5) {
        throw new ValidationError(`samples[${sampleIndex}].channels[${channel}] must be between -5 and 5 volts`);
      }
      return voltage;
    });

    return { recordedAt, channels };
  });
}
