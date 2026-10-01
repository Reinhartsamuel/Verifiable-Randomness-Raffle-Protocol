export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

export interface LogFields {
  [key: string]: unknown;
}

export interface Logger {
  debug(message: string, fields?: LogFields): void;
  info(message: string, fields?: LogFields): void;
  warn(message: string, fields?: LogFields): void;
  error(message: string, fields?: LogFields): void;
  child(bindings: LogFields): Logger;
}

const LEVEL_WEIGHT: Record<LogLevel, number> = { debug: 10, info: 20, warn: 30, error: 40 };

/**
 * Keys whose values must never reach a log sink. Salts in particular are
 * secret-until-landed: leaking one into logs/alert webhooks lets a colluding
 * provider precompute the draw.
 */
const REDACTED_KEYS = new Set([
  'salt',
  'salts',
  'privatekey',
  'resolverprivatekey',
  'settlerprivatekey',
  'secret',
  'mnemonic',
  'pk',
  'apikey',
  'authorization',
]);

function sanitizeValue(value: unknown, depth: number): unknown {
  if (value === null || value === undefined) return value;
  const type = typeof value;
  if (type === 'bigint') return (value as bigint).toString();
  if (type === 'string' || type === 'number' || type === 'boolean') return value;
  if (value instanceof Error) {
    return { name: value.name, message: value.message, stack: value.stack };
  }
  if (Array.isArray(value)) return value.map((entry) => sanitizeValue(entry, depth + 1));
  if (type === 'object') {
    if (depth > 5) return '[deep]';
    const out: Record<string, unknown> = {};
    for (const [key, entry] of Object.entries(value as Record<string, unknown>)) {
      out[key] = REDACTED_KEYS.has(key.toLowerCase()) ? '[redacted]' : sanitizeValue(entry, depth + 1);
    }
    return out;
  }
  return String(value);
}

/** Recursively convert a field bag into JSON-safe values (bigints -> strings, secrets redacted). */
export function toPlainObject(fields: LogFields): Record<string, unknown> {
  return sanitizeValue(fields, 0) as Record<string, unknown>;
}

export interface LoggerOptions {
  level: LogLevel;
  pretty: boolean;
}

export function createLogger(options: LoggerOptions): Logger {
  const minWeight = LEVEL_WEIGHT[options.level];

  const write = (level: LogLevel, bindings: LogFields, message: string, fields?: LogFields): void => {
    if (LEVEL_WEIGHT[level] < minWeight) return;
    const extras = fields ? toPlainObject(fields) : {};
    const ts = new Date().toISOString();
    let line: string;
    if (options.pretty) {
      const scope = Object.keys(bindings).length > 0 ? `[${Object.values(bindings).join(':')}] ` : '';
      const extrasText = Object.entries(extras)
        .map(([key, value]) => {
          const rendered = typeof value === 'object' && value !== null ? JSON.stringify(value) : String(value);
          return `${key}=${rendered}`;
        })
        .join(' ');
      line = `${ts} ${level.toUpperCase().padEnd(5)} ${scope}${message}${extrasText ? `  ${extrasText}` : ''}`;
    } else {
      line = JSON.stringify({ ts, level, ...bindings, msg: message, ...extras });
    }
    const sink = level === 'warn' || level === 'error' ? process.stderr : process.stdout;
    sink.write(`${line}\n`);
  };

  const make = (bindings: LogFields): Logger => ({
    debug: (message, fields) => write('debug', bindings, message, fields),
    info: (message, fields) => write('info', bindings, message, fields),
    warn: (message, fields) => write('warn', bindings, message, fields),
    error: (message, fields) => write('error', bindings, message, fields),
    child: (extra) => make({ ...bindings, ...extra }),
  });

  return make({});
}
