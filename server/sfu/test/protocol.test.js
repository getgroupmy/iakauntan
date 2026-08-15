/**
 * The protocol, end to end, against real mediasoup.
 *
 * These run a server, open real WebSockets, and create real routers,
 * transports, producers and consumers. No media flows — see
 * `helpers.js` for exactly what that does and does not cover.
 */
import assert from 'node:assert/strict';
import test, { after, before, describe } from 'node:test';

import {
  connect,
  connectExpectingRefusal,
  joinRoom,
  mintToken,
  opusParameters,
  startServer,
} from './helpers.js';

let server;

before(async () => {
  server = await startServer();
});

after(async () => {
  await server?.stop();
});

// A room and a person per test, never shared.
//
// Three tests used to share the room `bugs` and the peer id `peer-a`,
// and node runs them concurrently — so the reconnect rule in
// `Room.addPeer`, which is correct, quite properly threw one test's
// socket out from under it because another test had presented the same
// identity. The tests were wrong, not the server. Unique names make
// each test independent of how the runner schedules it.
let counter = 0;
const uniqueRoom = (label) => `${label}-${++counter}`;
const other = (n) => `peer-${n}-${counter}`;

describe('getting in', () => {
  test('a socket with no token is refused, and one with a token is not', async () => {
    const refused = await connectExpectingRefusal(server.url, '');
    assert.equal(refused.code, 4401);

    // The control. Without it "refused" would pass for a server that
    // refuses everybody, including a broken one.
    const room = uniqueRoom('lets-a-token-in');
    const client = await connect(
      server.url,
      mintToken({ sub: other('a'), room }),
    );
    const caps = await client.call('getRouterRtpCapabilities');
    assert.ok(caps.codecs.length > 0);
    await client.close();
  });

  test('a request sent the instant the socket opens is answered', async () => {
    // The first person into a call sends `getRouterRtpCapabilities` as
    // soon as the socket opens, and the server is still creating a
    // mediasoup router in a subprocess at that moment. `ws` drops
    // messages that arrive before a `message` listener exists, so that
    // first request used to vanish now and then and the app sat on
    // "Connecting…" until it gave up.
    //
    // A fresh room each time, because an existing room is already open
    // and there is nothing to race.
    for (let i = 0; i < 10; i++) {
      const room = uniqueRoom('instant');
      const client = await connect(
        server.url,
        mintToken({ sub: other('a'), room }),
      );
      const caps = await client.call('getRouterRtpCapabilities');
      assert.ok(caps.codecs.length > 0, `attempt ${i}`);
      await client.close();
    }
  });

  test('a forged token is refused', async () => {
    const good = mintToken({ sub: other('a'), room: uniqueRoom('forged') });
    const [header, payload] = good.split('.');
    const forged = `${header}.${payload}.${'x'.repeat(43)}`;

    const refused = await connectExpectingRefusal(server.url, forged);
    assert.equal(refused.code, 4401);
  });

  test('the room comes from the token, not from the URL', async () => {
    // Somebody with a valid token for their own call, asking for
    // another room in the query string. It has to be ignored: room
    // names are visible to everybody in a conversation, so if the URL
    // decided, a room name would be a key.
    const mine = uniqueRoom('my-own-room');
    const token = mintToken({ sub: other('a'), room: mine });
    const socket = await connect(
      `${server.url}`,
      `${token}&room=somebody-elses-room`,
    );
    await joinRoom(socket);

    assert.ok(server.rooms.rooms.has(mine));
    assert.equal(server.rooms.rooms.has('somebody-elses-room'), false);
    await socket.close();
  });
});

describe('a room', () => {
  test('two people in the same room see each other', async () => {
    const room = uniqueRoom('sees-each-other');
    const a = await connect(server.url, mintToken({ sub: other('a'), room }));
    await joinRoom(a, { displayName: 'Ahmad' });

    const b = await connect(server.url, mintToken({ sub: other('b'), room }));
    const { joined } = await joinRoom(b, { displayName: 'Mei Ling' });

    // B is told who is already here…
    assert.deepEqual(joined.peers, [{ id: other('a'), displayName: 'Ahmad' }]);
    // …and A is told B arrived.
    const arrival = await a.waitFor('peerJoined');
    // `peerId`, spelled exactly as `docs/call-signalling.md` says and as
    // `call_engine.dart` reads it. The server sent `id` at first, which
    // the app ignored — so the caller sat alone on screen while somebody
    // was in fact in the room with them.
    assert.equal(arrival.data.peerId, other('b'));
    assert.equal(arrival.data.displayName, 'Mei Ling');

    await a.close();
    await b.close();
  });

  test('two people in different rooms do not', async () => {
    const a = await connect(server.url, mintToken({ sub: other('a'), room: uniqueRoom('one') }));
    const b = await connect(server.url, mintToken({ sub: other('b'), room: uniqueRoom('two') }));

    await joinRoom(a);
    const { joined } = await joinRoom(b);

    assert.deepEqual(joined.peers, [], 'a different room is a different call');
    // Give any stray notification time to arrive before asserting none did.
    await new Promise((r) => setTimeout(r, 100));
    assert.deepEqual(a.seen('peerJoined'), []);

    await a.close();
    await b.close();
  });

  test('leaving tells the room, and the last one out closes it', async () => {
    const room = uniqueRoom('closes-behind-itself');
    const a = await connect(server.url, mintToken({ sub: other('a'), room }));
    const b = await connect(server.url, mintToken({ sub: other('b'), room }));
    await joinRoom(a);
    await joinRoom(b);

    await b.close();
    const gone = await a.waitFor('peerClosed');
    assert.equal(gone.data.peerId, other('b'));
    assert.equal(server.rooms.rooms.get(room)?.peers.size, 1);

    await a.close();
    await new Promise((r) => setTimeout(r, 100));
    assert.equal(
      server.rooms.rooms.has(room),
      false,
      'an empty room keeps a router alive for nothing',
    );
  });

  test('reconnecting replaces the old socket rather than doubling up', async () => {
    const room = uniqueRoom('reconnects');
    const token = mintToken({ sub: other('a'), room });
    const first = await connect(server.url, token);
    await joinRoom(first);

    const second = await connect(server.url, token);
    await joinRoom(second);

    assert.equal(
      server.rooms.rooms.get(room)?.peers.size,
      1,
      'the same person twice is one person, not two',
    );
    // And the room is still alive: closing the old peer must not empty
    // a room the new one is standing in.
    assert.equal(server.rooms.rooms.get(room)?.closed, false);

    await first.close();
    await second.close();
  });

  test('a full room is refused, and is not full for somebody already in it', async () => {
    // Its own RTC port range. Two mediasoup workers pointed at the same
    // range race for the same UDP ports, and the loser fails to create a
    // transport — which shows up as an unrelated test failing about one
    // run in five.
    const small = await startServer({
      CALL_MAX_PEERS_PER_ROOM: '1',
      MEDIASOUP_MIN_PORT: '42100',
      MEDIASOUP_MAX_PORT: '42199',
    });
    try {
      const room = uniqueRoom('full');
      const a = await connect(small.url, mintToken({ sub: other('a'), room }));
      await joinRoom(a);

      const refused = await connectExpectingRefusal(
        small.url,
        mintToken({ sub: other('b'), room }),
      );
      assert.equal(refused.code, 4503);

      // Somebody already in the room reconnecting is not a new arrival,
      // and must not be locked out of their own call.
      const again = await connect(small.url, mintToken({ sub: other('a'), room }));
      await joinRoom(again);
      await again.close();
      await a.close();
    } finally {
      await small.stop();
    }
  });
});

describe('media', () => {
  test('a produced track reaches the other person, paused', async () => {
    const room = uniqueRoom('produces');
    const a = await connect(server.url, mintToken({ sub: other('a'), room }));
    const b = await connect(server.url, mintToken({ sub: other('b'), room }));

    const { caps, send } = await joinRoom(a, { displayName: 'Ahmad' });
    await joinRoom(b, { displayName: 'Mei Ling' });

    const { id: producerId } = await a.call('produce', {
      transportId: send.id,
      kind: 'audio',
      rtpParameters: opusParameters(caps),
      appData: { source: 'mic' },
    });

    const arrived = await b.waitFor('newConsumer');
    assert.equal(arrived.data.producerId, producerId);
    assert.equal(arrived.data.peerId, other('a'), 'the far side needs to know whose');
    assert.equal(arrived.data.kind, 'audio');
    assert.equal(arrived.data.appData.source, 'mic');
    assert.ok(arrived.data.rtpParameters.codecs.length > 0);

    // Resuming is the client's to do once it has somewhere to put the
    // track — the server always creates them paused, so the first key
    // frame is not thrown at a client with no receiver.
    await b.call('resumeConsumer', { consumerId: arrived.data.id });

    await a.close();
    await b.close();
  });

  test('somebody joining late is told what is already being sent', async () => {
    const room = uniqueRoom('late-arrival');
    const a = await connect(server.url, mintToken({ sub: other('a'), room }));
    const { caps, send } = await joinRoom(a);
    const { id: producerId } = await a.call('produce', {
      transportId: send.id,
      kind: 'audio',
      rtpParameters: opusParameters(caps),
      appData: { source: 'mic' },
    });

    // B arrives after the fact. Without this the second person into
    // every call hears the first one only if they happen to speak again.
    const b = await connect(server.url, mintToken({ sub: other('b'), room }));
    await joinRoom(b);

    const arrived = await b.waitFor('newConsumer');
    assert.equal(arrived.data.producerId, producerId);

    await a.close();
    await b.close();
  });

  test('muting and unmuting reach the other side', async () => {
    const room = uniqueRoom('mutes');
    const a = await connect(server.url, mintToken({ sub: other('a'), room }));
    const b = await connect(server.url, mintToken({ sub: other('b'), room }));
    const { caps, send } = await joinRoom(a);
    await joinRoom(b);

    const { id: producerId } = await a.call('produce', {
      transportId: send.id,
      kind: 'audio',
      rtpParameters: opusParameters(caps),
      appData: { source: 'mic' },
    });
    const consumer = (await b.waitFor('newConsumer')).data;

    await a.call('pauseProducer', { producerId });
    const paused = await b.waitFor('consumerPaused');
    assert.equal(paused.data.consumerId, consumer.id);

    await a.call('resumeProducer', { producerId });
    const resumed = await b.waitFor('consumerResumed');
    assert.equal(resumed.data.consumerId, consumer.id);

    await a.close();
    await b.close();
  });

  test('closing a track closes it on the other side too', async () => {
    const room = uniqueRoom('closes-a-track');
    const a = await connect(server.url, mintToken({ sub: other('a'), room }));
    const b = await connect(server.url, mintToken({ sub: other('b'), room }));
    const { caps, send } = await joinRoom(a);
    await joinRoom(b);

    const { id: producerId } = await a.call('produce', {
      transportId: send.id,
      kind: 'audio',
      rtpParameters: opusParameters(caps),
      appData: { source: 'mic' },
    });
    const consumer = (await b.waitFor('newConsumer')).data;

    await a.call('closeProducer', { producerId });
    const closed = await b.waitFor('consumerClosed');
    assert.equal(
      closed.data.consumerId,
      consumer.id,
      'otherwise the far side shows a frozen last frame forever',
    );

    await a.close();
    await b.close();
  });

  test('producing before joining is refused, and after it is not', async () => {
    const room = uniqueRoom('order-matters');
    const a = await connect(server.url, mintToken({ sub: other('a'), room }));
    const caps = await a.call('getRouterRtpCapabilities');
    const send = await a.call('createWebRtcTransport', {
      producing: true,
      consuming: false,
    });

    const early = await a.request('produce', {
      transportId: send.id,
      kind: 'audio',
      rtpParameters: opusParameters(caps),
    });
    assert.equal(early.ok, false);

    await a.call('createWebRtcTransport', { producing: false, consuming: true });
    await a.call('join', { rtpCapabilities: caps });

    const late = await a.request('produce', {
      transportId: send.id,
      kind: 'audio',
      rtpParameters: opusParameters(caps),
    });
    assert.equal(late.ok, true, 'the refusal has to be about order, not the parameters');

    await a.close();
  });

  test('a receive transport will not send', async () => {
    const room = uniqueRoom('wrong-transport');
    const a = await connect(server.url, mintToken({ sub: other('a'), room }));
    const { caps, recv } = await joinRoom(a);

    const refused = await a.request('produce', {
      transportId: recv.id,
      kind: 'audio',
      rtpParameters: opusParameters(caps),
    });
    assert.equal(refused.ok, false);

    await a.close();
  });
});

describe('a client with a bug', () => {
  test('an unknown method is refused and the socket carries on', async () => {
    const a = await connect(
      server.url,
      mintToken({ sub: other('a'), room: uniqueRoom('bugs') }),
    );

    const refused = await a.request('deleteEverything');
    assert.equal(refused.ok, false);
    assert.match(refused.error, /Unknown method/);

    // The point of the test: hanging up on a buggy client turns one bug
    // into "the call server keeps dropping us".
    const caps = await a.call('getRouterRtpCapabilities');
    assert.ok(caps.codecs.length > 0);

    await a.close();
  });

  test('rubbish is refused and the socket carries on', async () => {
    const a = await connect(
      server.url,
      mintToken({ sub: other('a'), room: uniqueRoom('bugs') }),
    );

    const answer = new Promise((resolve) =>
      a.socket.once('message', (raw) => resolve(JSON.parse(raw.toString()))),
    );
    a.socket.send('}{ not json');
    assert.equal((await answer).ok, false);

    const caps = await a.call('getRouterRtpCapabilities');
    assert.ok(caps.codecs.length > 0);

    await a.close();
  });

  test('a transport that is both, or neither, is refused', async () => {
    const a = await connect(
      server.url,
      mintToken({ sub: other('a'), room: uniqueRoom('bugs') }),
    );

    for (const data of [
      { producing: true, consuming: true },
      { producing: false, consuming: false },
      {},
    ]) {
      const refused = await a.request('createWebRtcTransport', data);
      assert.equal(refused.ok, false, JSON.stringify(data));
    }

    const ok = await a.request('createWebRtcTransport', {
      producing: true,
      consuming: false,
    });
    assert.equal(ok.ok, true);

    await a.close();
  });

  test('joining twice is refused', async () => {
    const a = await connect(
      server.url,
      mintToken({ sub: other('a'), room: uniqueRoom('joins-twice') }),
    );
    const { caps } = await joinRoom(a);

    const again = await a.request('join', { rtpCapabilities: caps });
    assert.equal(again.ok, false);

    await a.close();
  });

  test('joining without capabilities is refused', async () => {
    const a = await connect(
      server.url,
      mintToken({ sub: other('a'), room: uniqueRoom('no-caps') }),
    );
    const refused = await a.request('join', {});
    assert.equal(refused.ok, false);

    // Control: with them, it works.
    const caps = await a.call('getRouterRtpCapabilities');
    const ok = await a.request('join', { rtpCapabilities: caps });
    assert.equal(ok.ok, true);

    await a.close();
  });
});
