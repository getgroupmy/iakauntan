/**
 * The worker pool, and the rooms spread across it.
 *
 * mediasoup runs its media handling in C++ subprocesses, one per core,
 * and a single worker saturates one core and no more — so a machine with
 * eight cores and one worker is a machine using an eighth of itself.
 * Each router lives entirely inside one worker, which is why a *room* is
 * the unit assigned: everybody in a call has to be in the same router to
 * hear each other.
 *
 * Assignment is round-robin rather than least-loaded. Least-loaded needs
 * a definition of load, and the honest ones (`worker.getResourceUsage`)
 * are asynchronous and lag reality. Calls in an accounting system are a
 * handful of people each and arrive at random, so round-robin spreads
 * them about as well and cannot get stuck.
 */
import * as mediasoup from 'mediasoup';

import { mediaCodecs } from './config.js';
import { Room } from './room.js';

export class Rooms {
  /** @param {object} config from `loadConfig` */
  constructor(config) {
    this.config = config;
    /** @type {import('mediasoup').types.Worker[]} */
    this.workers = [];
    /** @type {Map<string, Room>} */
    this.rooms = new Map();
    /** @type {Map<string, Promise<Room>>} */
    this._creating = new Map();
    this._next = 0;
    this.closed = false;
  }

  async start() {
    const count = Math.max(1, this.config.worker.count);
    for (let i = 0; i < count; i++) {
      const worker = await mediasoup.createWorker({
        logLevel: this.config.worker.logLevel,
        logTags: this.config.worker.logTags,
        rtcMinPort: this.config.worker.rtcMinPort,
        rtcMaxPort: this.config.worker.rtcMaxPort,
      });

      // A dead worker takes its rooms with it and cannot be revived —
      // mediasoup is explicit about this. Staying up would mean serving
      // calls that can never carry audio, so the process ends and
      // whatever supervises it starts a new one.
      worker.on('died', (error) => {
        console.error(
          JSON.stringify({
            at: new Date().toISOString(),
            level: 'fatal',
            event: 'worker.died',
            pid: worker.pid,
            error: error?.message,
          }),
        );
        process.exit(1);
      });

      this.workers.push(worker);
    }
    return this;
  }

  nextWorker() {
    const worker = this.workers[this._next % this.workers.length];
    this._next += 1;
    return worker;
  }

  /**
   * The room by that name, made if it is not there yet.
   *
   * The in-flight map is not decoration. `createRouter` is asynchronous,
   * and two people answering the same call within a few milliseconds of
   * each other is the normal case rather than a rare one — without it
   * they each build a router, the second overwrites the first in the
   * map, and two people in the same call sit in different rooms hearing
   * silence. That is a bug that only ever appears in production, because
   * it needs two real clients and real latency.
   */
  async get(roomId) {
    const existing = this.rooms.get(roomId);
    if (existing && !existing.closed) return existing;

    const inFlight = this._creating.get(roomId);
    if (inFlight) return inFlight;

    const creating = (async () => {
      const worker = this.nextWorker();
      const router = await worker.createRouter({ mediaCodecs });
      const room = new Room({
        id: roomId,
        router,
        config: this.config,
        onEmpty: (id) => {
          if (this.rooms.get(id)?.closed !== false) this.rooms.delete(id);
        },
      });
      this.rooms.set(roomId, room);
      return room;
    })().finally(() => this._creating.delete(roomId));

    this._creating.set(roomId, creating);
    return creating;
  }

  get size() {
    return this.rooms.size;
  }

  async close() {
    if (this.closed) return;
    this.closed = true;
    for (const room of [...this.rooms.values()]) room.close();
    this.rooms.clear();
    for (const worker of this.workers) worker.close();
    this.workers = [];
  }
}
