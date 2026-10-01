import { toPlainObject, type LogFields, type Logger } from './logger.ts';

export interface Alerter {
  /**
   * Loud, rate-limited alert: error-level structured log plus optional webhook
   * POST. Repeated identical alerts (same `key`) are suppressed for the
   * cooldown window so a misconfigured key cannot spam every cron cycle.
   */
  alert(title: string, fields?: LogFields, options?: { key?: string }): void;
}

const DEFAULT_COOLDOWN_MS = 15 * 60_000;

export function createAlerter(logger: Logger, webhookUrl?: string, cooldownMs = DEFAULT_COOLDOWN_MS): Alerter {
  const lastSentAt = new Map<string, number>();

  return {
    alert(title, fields = {}, options = {}) {
      const key = options.key ?? title;
      const now = Date.now();
      const previous = lastSentAt.get(key);
      if (previous !== undefined && now - previous < cooldownMs) {
        logger.debug('alert suppressed (cooldown)', { alert: title, key });
        return;
      }
      lastSentAt.set(key, now);

      const payload = toPlainObject(fields);
      logger.error(`ALERT: ${title}`, { alert: true, ...payload });

      if (webhookUrl === undefined) return;
      const body = JSON.stringify({
        // `content` for Discord, `text` for Slack-compatible endpoints.
        content: `[keeper] ${title}`,
        text: `[keeper] ${title}`,
        fields: payload,
      });
      void fetch(webhookUrl, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body,
        signal: AbortSignal.timeout(10_000),
      }).catch((error) => {
        logger.warn('alert webhook delivery failed', { error: error instanceof Error ? error.message : String(error) });
      });
    },
  };
}
