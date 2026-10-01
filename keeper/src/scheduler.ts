import type { Logger } from './logger.ts';

export interface JobDefinition {
  name: string;
  everyMs: number;
  jitterMs: number;
  runOnStart: boolean;
  run: () => Promise<void>;
}

/**
 * Minimal self-scheduling timer (replaces node-cron so the only dependency is
 * viem). Each job is a setTimeout chain: the next run is scheduled only after
 * the previous one finishes, so cycles can never overlap; a crash inside a job
 * is logged and the schedule continues. Optional jitter de-synchronises jobs
 * after restarts.
 */
export class Scheduler {
  readonly #logger: Logger;
  readonly #timers = new Map<string, NodeJS.Timeout>();
  readonly #active = new Set<Promise<void>>();
  #stopped = false;

  constructor(logger: Logger) {
    this.#logger = logger;
  }

  start(jobs: readonly JobDefinition[]): void {
    for (const job of jobs) {
      this.#schedule(job, job.runOnStart ? 0 : job.everyMs);
    }
  }

  #schedule(job: JobDefinition, delayMs: number): void {
    if (this.#stopped) return;
    const jitter = delayMs === 0 ? 0 : Math.floor(Math.random() * job.jitterMs);
    const timer = setTimeout(() => {
      void this.#runOnce(job);
    }, delayMs + jitter);
    this.#timers.set(job.name, timer);
  }

  async #runOnce(job: JobDefinition): Promise<void> {
    const run = (async () => {
      try {
        await job.run();
      } catch (error) {
        this.#logger.error('job crashed', {
          job: job.name,
          error: error instanceof Error ? error.message : String(error),
        });
      }
    })();
    this.#active.add(run);
    try {
      await run;
    } finally {
      this.#active.delete(run);
    }
    this.#timers.delete(job.name);
    this.#schedule(job, job.everyMs);
  }

  async stop(): Promise<void> {
    this.#stopped = true;
    for (const timer of this.#timers.values()) clearTimeout(timer);
    this.#timers.clear();
    await Promise.allSettled([...this.#active]);
  }
}
