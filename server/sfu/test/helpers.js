/**
 * A real server, a real client, no mocks.
 *
 * The whole protocol surface can be driven from here against actual
 * mediasoup workers, routers, transports, producers and consumers. What
 * cannot be driven is media: nothing in a test process performs a DTLS
 * handshake or sends an RTP packet, so producers here never carry audio.
 *
 * That is a smaller gap than it sounds. `transport.produce()` does not
 * need a connected transport — it needs RTP parameters the router
 * accepts — so the objects these tests create are the same objects a
 * real call creates, and the routing decisions made about them
 * (`canConsume`, who gets a `newConsumer`, what happens when a producer
 * closes) are the real ones. What is untested is whether packets arrive,
 * which needs two browsers and a network.
 */
import { createHmac } from 'node:crypto';
import { once } from 'node:events';

import { WebSocket } from 'ws';

import { loadConfig } from '../src/config.js';
import { Rooms } from '../src/rooms.js';
import { createCallServer } from '../src/server.js';

export const SECRET = 'test-secret-shared-with-the-edge-function';

export function mintToken(claims) {
  const encode = (value) =>
    Buffer.from(JSON.stringify(value)).toString('base64url');
  const body = `${encode({ alg: 'HS256', typ: 'JWT' })}.${encode({
    exp: Math.floor(Date.now() / 1000) + 600,
    kind: 'voice',
    ...claims,
  })}`;
  const signature = createHmac('sha256', SECRET).update(body).digest('base64url');
  return `${body}.${signature}`;
}

/**
 * One worker and a narrow RTC port range, because a test run should not
 * reserve a thousand UDP ports per suite.
 */
export async function startServer(overrides = {}) {
  const config = loadConfig({
    CALL_SFU_SECRET: SECRET,
    PORT: '0',
    HOST: '127.0.0.1',
    MEDIASOUP_WORKERS: '1',
    MEDIASOUP_LISTEN_IP: '127.0.0.1',
    MEDIASOUP_MIN_PORT: '42000',
    MEDIASOUP_MAX_PORT: '42099',
    MEDIASOUP_LOG_LEVEL: 'error',
    ...overrides,
  });

  const rooms = await new Rooms(config).start();
  const server = createCallServer({ config, rooms });
  const address = await server.listen();

  return {
    config,
    rooms,
    url: `ws://127.0.0.1:${address.port}`,
    async stop() {
      await server.close();
      await rooms.close();
    },
  };
}

/** A client that speaks the protocol in `docs/call-signalling.md`. */
export class TestClient {
  constructor(socket) {
    this.socket = socket;
    this._nextId = 1;
    this._pending = new Map();
    /** Every notification received, in order. */
    this.notifications = [];
    this._waiters = [];

    socket.on('message', (raw) => {
      const frame = JSON.parse(raw.toString());
      if (frame.notification) {
        this.notifications.push(frame);
        for (const waiter of [...this._waiters]) {
          if (waiter.matches(frame)) {
            this._waiters.splice(this._waiters.indexOf(waiter), 1);
            waiter.resolve(frame);
          }
        }
        return;
      }
      const pending = this._pending.get(frame.id);
      if (!pending) return;
      this._pending.delete(frame.id);
      pending.resolve(frame);
    });
  }

  /** Resolves with the whole frame, refusals included — they are results. */
  request(method, data = {}) {
    const id = this._nextId++;
    return new Promise((resolve, reject) => {
      this._pending.set(id, { resolve });
      this.socket.send(JSON.stringify({ id, method, data }));
      setTimeout(
        () => reject(new Error(`No answer to "${method}"`)),
        5000,
      ).unref();
    });
  }

  /** Like `request`, but a refusal is a thrown error. */
  async call(method, data = {}) {
    const frame = await this.request(method, data);
    if (!frame.ok) throw new Error(frame.error);
    return frame.data;
  }

  /** Waits for a notification, counting ones that already arrived. */
  waitFor(name, predicate = () => true) {
    const already = this.notifications.find(
      (f) => f.notification === name && predicate(f.data),
    );
    if (already) return Promise.resolve(already);

    return new Promise((resolve, reject) => {
      const waiter = {
        matches: (f) => f.notification === name && predicate(f.data),
        resolve,
      };
      this._waiters.push(waiter);
      setTimeout(() => {
        const i = this._waiters.indexOf(waiter);
        if (i >= 0) this._waiters.splice(i, 1);
        reject(new Error(`No "${name}" notification arrived`));
      }, 5000).unref();
    });
  }

  seen(name) {
    return this.notifications.filter((f) => f.notification === name);
  }

  close() {
    return new Promise((resolve) => {
      if (this.socket.readyState === WebSocket.CLOSED) return resolve();
      this.socket.once('close', resolve);
      this.socket.close();
    });
  }
}

export async function connect(url, token) {
  const socket = new WebSocket(`${url}/?token=${token}`);
  await once(socket, 'open');
  return new TestClient(socket);
}

/** Connects and waits to be refused, returning the close code. */
export async function connectExpectingRefusal(url, token) {
  const socket = new WebSocket(`${url}/?token=${token}`);
  const [code, reason] = await once(socket, 'close');
  return { code, reason: reason.toString() };
}

/**
 * Everything a peer does before it can be heard: two transports, then
 * join. The client does it in exactly this order, and the order matters
 * — see `docs/call-signalling.md`.
 */
export async function joinRoom(client, { displayName } = {}) {
  const caps = await client.call('getRouterRtpCapabilities');
  const send = await client.call('createWebRtcTransport', {
    producing: true,
    consuming: false,
  });
  const recv = await client.call('createWebRtcTransport', {
    producing: false,
    consuming: true,
  });
  const joined = await client.call('join', {
    rtpCapabilities: caps,
    displayName,
  });
  return { caps, send, recv, joined };
}

let mid = 0;
const nextMid = () => `M${++mid}`;

/**
 * RTP parameters for a VP8 track — a camera or a screen, which differ
 * only by the `source` label on them.
 */
export function vp8Parameters(caps, { ssrc = 55555555 } = {}) {
  const vp8 = caps.codecs.find((c) => c.mimeType.toLowerCase() === 'video/vp8');
  if (!vp8) throw new Error('The router offers no VP8');
  return {
    // A `mid` per producer, not per kind. Two producers on one transport
    // sharing a mid is refused by mediasoup with "MID already exists in
    // RTP listener" — which reads exactly like the server rejecting the
    // second share, and is in fact this helper being wrong.
    mid: nextMid(),
    codecs: [
      {
        mimeType: vp8.mimeType,
        payloadType: vp8.preferredPayloadType,
        clockRate: vp8.clockRate,
        parameters: {},
        rtcpFeedback: vp8.rtcpFeedback ?? [],
      },
    ],
    headerExtensions: [],
    encodings: [{ ssrc }],
    rtcp: { cname: 'test', reducedSize: true },
  };
}

/**
 * RTP parameters for an Opus track, built from what the router actually
 * offers rather than from a remembered payload type — mediasoup assigns
 * those, and hard-coding 111 works until it does not.
 */
export function opusParameters(caps, { ssrc = 22222222 } = {}) {
  const opus = caps.codecs.find((c) => c.mimeType.toLowerCase() === 'audio/opus');
  if (!opus) throw new Error('The router offers no Opus');
  return {
    mid: nextMid(),
    codecs: [
      {
        mimeType: opus.mimeType,
        payloadType: opus.preferredPayloadType,
        clockRate: opus.clockRate,
        channels: opus.channels,
        parameters: { useinbandfec: 1 },
        rtcpFeedback: [],
      },
    ],
    headerExtensions: [],
    encodings: [{ ssrc }],
    rtcp: { cname: 'test', reducedSize: true },
  };
}
