/**
 * The wire protocol, as one table.
 *
 * mediasoup defines no client protocol — it is a library, not a server —
 * so this is the app's, written down in `docs/call-signalling.md` and
 * implemented here. The two are meant to be read against each other: if
 * a method appears in one and not the other, one of them is wrong.
 *
 * Frames:
 *   request       { id, method, data }
 *   response      { id, ok: true, data } | { id, ok: false, error }
 *   notification  { notification, data }
 *
 * Nothing here touches a socket. It takes a peer and a room and returns
 * a plain object, which is what lets the whole surface be driven in a
 * test with a real mediasoup router and no network at all.
 */

export class ProtocolError extends Error {}

function requireJoined(peer) {
  if (!peer.joined) {
    throw new ProtocolError(
      'Join the room first — see docs/call-signalling.md',
    );
  }
}

/** @type {Record<string, (ctx: {room: object, peer: object}, data: object) => Promise<object>>} */
export const methods = {
  async getRouterRtpCapabilities({ room }) {
    // Returned bare rather than wrapped in a field. The client feeds it
    // straight to `Device.load`, and a wrapper would be one more thing
    // for the two ends to disagree about.
    return room.router.rtpCapabilities;
  },

  async createWebRtcTransport({ room, peer }, data = {}) {
    const producing = data.producing === true;
    const consuming = data.consuming === true;
    if (producing === consuming) {
      // One or the other. A transport that is both is legal in
      // mediasoup and is not what this protocol says, and accepting it
      // quietly means the two ends disagree about which transport a
      // producer lives on.
      throw new ProtocolError(
        'A transport is either producing or consuming, not both and not neither',
      );
    }
    return room.createWebRtcTransport(peer, { producing, consuming });
  },

  async connectWebRtcTransport({ peer }, data = {}) {
    const transport = peer.transports.get(data.transportId);
    if (!transport) throw new ProtocolError('No such transport');
    await transport.connect({ dtlsParameters: data.dtlsParameters });
    return {};
  },

  async join({ room, peer }, data = {}) {
    if (peer.joined) throw new ProtocolError('Already joined');
    if (!data.rtpCapabilities) {
      throw new ProtocolError('join needs rtpCapabilities');
    }
    return room.join(peer, {
      rtpCapabilities: data.rtpCapabilities,
      displayName: data.displayName,
    });
  },

  async produce({ room, peer }, data = {}) {
    requireJoined(peer);
    if (data.kind !== 'audio' && data.kind !== 'video') {
      throw new ProtocolError(`Cannot produce "${data.kind}"`);
    }
    return room.produce(peer, {
      transportId: data.transportId,
      kind: data.kind,
      rtpParameters: data.rtpParameters,
      appData: data.appData,
    });
  },

  async closeProducer({ peer }, data = {}) {
    const producer = peer.producers.get(data.producerId);
    if (!producer) throw new ProtocolError('No such producer');
    producer.close();
    peer.producers.delete(producer.id);
    return {};
  },

  async pauseProducer({ peer }, data = {}) {
    const producer = peer.producers.get(data.producerId);
    if (!producer) throw new ProtocolError('No such producer');
    await producer.pause();
    return {};
  },

  async resumeProducer({ peer }, data = {}) {
    const producer = peer.producers.get(data.producerId);
    if (!producer) throw new ProtocolError('No such producer');
    await producer.resume();
    return {};
  },

  async resumeConsumer({ peer }, data = {}) {
    const consumer = peer.consumers.get(data.consumerId);
    // Not an error worth failing on. A consumer whose producer closed in
    // the same breath as the client resuming it is a race that happens,
    // and the client cannot do anything useful with a refusal.
    if (!consumer) return {};
    await consumer.resume();
    return {};
  },

  async pauseConsumer({ peer }, data = {}) {
    const consumer = peer.consumers.get(data.consumerId);
    if (!consumer) return {};
    await consumer.pause();
    return {};
  },
};

/**
 * Turns one incoming frame into one outgoing frame.
 *
 * Returns null when there is nothing to answer — a notification from the
 * client, or a frame that is not a request at all. A malformed frame
 * gets a refusal rather than a closed socket: a client sending rubbish
 * is a client with a bug, and dropping the connection turns that into
 * "the call server keeps hanging up".
 */
export async function handleFrame(ctx, raw) {
  let frame;
  try {
    frame = JSON.parse(raw);
  } catch {
    return { id: null, ok: false, error: 'Not JSON' };
  }

  if (!frame || typeof frame !== 'object') {
    return { id: null, ok: false, error: 'Not a frame' };
  }
  if (frame.notification !== undefined) return null;

  const { id, method } = frame;
  if (typeof id !== 'number') {
    return { id: null, ok: false, error: 'A request needs a numeric id' };
  }

  const handler = Object.prototype.hasOwnProperty.call(methods, method)
    ? methods[method]
    : null;
  if (!handler) {
    return { id, ok: false, error: `Unknown method "${method}"` };
  }

  try {
    const data = await handler(ctx, frame.data ?? {});
    return { id, ok: true, data: data ?? {} };
  } catch (error) {
    return { id, ok: false, error: error?.message ?? 'Refused' };
  }
}
