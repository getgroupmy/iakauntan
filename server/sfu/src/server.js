/**
 * The socket, and what happens on it.
 *
 * One WebSocket per person per call. The token in the query string says
 * who they are and which room they are in; nothing after the handshake
 * can change either.
 *
 * Terminated at the edge, not here. This listens for plain `ws` and
 * expects nginx or a load balancer in front doing TLS — which is also
 * where the certificate renewal already lives on any machine that serves
 * anything else. `wss://` is what the client uses; `ws://` is what
 * arrives.
 */
import { createServer } from 'node:http';
import { WebSocketServer } from 'ws';

import { Peer } from './room.js';
import { handleFrame } from './protocol.js';
import { TokenError, tokenFromRequest, verifyToken } from './token.js';

function log(level, event, fields = {}) {
  const line = { at: new Date().toISOString(), level, event, ...fields };
  (level === 'error' ? console.error : console.log)(JSON.stringify(line));
}

/**
 * @param {{ config: object, rooms: import('./rooms.js').Rooms }} deps
 */
export function createCallServer({ config, rooms }) {
  const http = createServer((req, res) => {
    // One endpoint that is not a socket, because every load balancer
    // wants one and the alternative is it deciding this process is dead
    // in the middle of a call.
    if (req.url?.startsWith('/healthz')) {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(
        JSON.stringify({
          ok: true,
          rooms: rooms.size,
          workers: rooms.workers.length,
          uptimeSeconds: Math.round(process.uptime()),
        }),
      );
      return;
    }
    res.writeHead(404).end();
  });

  // No `path` restriction. The client builds its URL from whatever
  // `call-token` returned, and behind nginx that is as likely to be
  // `wss://host/call` as `wss://host` — pinning the path here turns a
  // reverse-proxy prefix into a 404 during the handshake, which surfaces
  // in the app as "the call server did not answer".
  const wss = new WebSocketServer({ server: http });

  wss.on('connection', async (socket, req) => {
    // Nothing is read off this socket until there is something to read
    // it with.
    //
    // Everything below the first `await` — opening the room, which
    // creates a mediasoup router in a subprocess — takes long enough for
    // a client to send its first request, and `ws` drops messages that
    // arrive before a `message` listener exists. So the first
    // `getRouterRtpCapabilities` of the first person into a call would
    // occasionally vanish, and the app would sit on "Connecting…" until
    // it timed out. Intermittent, load-dependent, and invisible in any
    // log.
    socket.pause();

    let identity;
    try {
      identity = verifyToken(tokenFromRequest(req), config.secret, {
        clockToleranceSeconds: config.clockToleranceSeconds,
      });
    } catch (error) {
      // 4401 rather than a plain close: the client can tell "your token
      // is no good, get another" from "the network went away", and only
      // one of those is worth retrying.
      const why = error instanceof TokenError ? error.message : 'Refused';
      log('warn', 'connection.refused', { why });
      socket.resume();
      socket.close(4401, why);
      return;
    }

    let room;
    try {
      room = await rooms.get(identity.room);
    } catch (error) {
      log('error', 'room.failed', { room: identity.room, error: error.message });
      socket.resume();
      socket.close(4500, 'The call server could not open that room');
      return;
    }

    if (room.isFull && !room.peers.has(identity.peerId)) {
      log('warn', 'room.full', { room: room.id, peers: room.peers.size });
      socket.resume();
      socket.close(4503, 'That call is full');
      return;
    }

    const peer = new Peer({
      id: identity.peerId,
      displayName: identity.displayName,
      send: (frame) => {
        if (socket.readyState !== socket.OPEN) return;
        socket.send(JSON.stringify(frame));
      },
    });

    room.addPeer(peer);
    log('info', 'peer.connected', {
      room: room.id,
      peer: peer.id,
      peers: room.peers.size,
    });

    // A socket whose far end vanished without a FIN — a phone going into
    // a tunnel, a laptop lid closing — stays open here indefinitely, and
    // the room keeps somebody in it who cannot hear anything. Ping, and
    // reap whatever has not answered by the next round.
    let alive = true;
    socket.on('pong', () => {
      alive = true;
    });
    const heartbeat = setInterval(() => {
      if (!alive) {
        log('info', 'peer.silent', { room: room.id, peer: peer.id });
        socket.terminate();
        return;
      }
      alive = false;
      socket.ping();
    }, config.heartbeatMs);

    // Requests are handled one at a time, in the order they arrive.
    let queue = Promise.resolve();

    socket.on('message', async (raw) => {
      // Requests are handled in order. mediasoup's own objects are
      // async, and two `createWebRtcTransport` calls racing would give
      // the client back its send and receive transports in whichever
      // order they finished — which is fine — but `join` racing ahead of
      // the transport it needs is not. Serialising costs nothing at this
      // volume and removes a whole class of ordering bug.
      queue = queue.then(async () => {
        const response = await handleFrame({ room, peer, config }, raw.toString());
        if (response && socket.readyState === socket.OPEN) {
          socket.send(JSON.stringify(response));
        }
      });
      await queue;
    });

    const leave = () => {
      clearInterval(heartbeat);
      room.removePeer(peer);
      log('info', 'peer.left', { room: room.id, peer: peer.id });
    };

    socket.on('close', leave);
    socket.on('error', (error) => {
      log('warn', 'socket.error', { peer: peer.id, error: error.message });
      leave();
    });

    // Everything is wired. Whatever the client sent while the room was
    // being opened is delivered now, in order.
    socket.resume();
  });

  return {
    http,
    wss,
    listen: () =>
      new Promise((resolve) => {
        http.listen(config.port, config.host, () => {
          log('info', 'listening', {
            host: config.host,
            port: config.port,
            workers: rooms.workers.length,
            rtcPorts: `${config.worker.rtcMinPort}-${config.worker.rtcMaxPort}`,
            announced:
              config.listenInfos[0].announcedAddress ?? '(none — local only)',
          });
          resolve(http.address());
        });
      }),
    close: () =>
      new Promise((resolve) => {
        for (const client of wss.clients) client.terminate();
        wss.close(() => http.close(() => resolve()));
      }),
  };
}
