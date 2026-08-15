/**
 * Everything this server reads from its environment, resolved once and
 * checked here rather than in whatever code path first needs it.
 *
 * A media server that starts happily and then hands out unreachable ICE
 * candidates is the worst failure mode available: every call connects,
 * every call is silent, and nothing in any log says why. So the two
 * settings that cause it — the shared secret and the announced address
 * — are refused at start-up rather than defaulted.
 */
import os from 'node:os';

function required(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(
      `${name} is not set. See server/sfu/README.md — this server cannot ` +
        'start without it.',
    );
  }
  return value;
}

function int(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;
  const value = Number.parseInt(raw, 10);
  if (!Number.isInteger(value)) {
    throw new Error(`${name} must be a whole number, got "${raw}"`);
  }
  return value;
}

export function loadConfig(env = process.env) {
  const previous = process.env;
  process.env = env;
  try {
    const listenIp = env.MEDIASOUP_LISTEN_IP || '0.0.0.0';

    // The address remote peers are told to send media to. On a cloud VM
    // the socket binds to a private address and nothing outside can
    // reach it, so this has to be the public one — and getting it wrong
    // produces a call that connects and stays silent, which is why it
    // is required rather than guessed.
    const announcedAddress =
      env.MEDIASOUP_ANNOUNCED_IP || env.MEDIASOUP_ANNOUNCED_ADDRESS;
    if (!announcedAddress && env.NODE_ENV === 'production') {
      throw new Error(
        'MEDIASOUP_ANNOUNCED_IP is not set. In production it must be the ' +
          'public address of this machine, or every call will connect and ' +
          'nobody will hear anything.',
      );
    }

    const minPort = int('MEDIASOUP_MIN_PORT', 40000);
    const maxPort = int('MEDIASOUP_MAX_PORT', 40999);
    if (maxPort < minPort) {
      throw new Error(
        `MEDIASOUP_MAX_PORT (${maxPort}) is below MEDIASOUP_MIN_PORT (${minPort})`,
      );
    }

    return {
      port: int('PORT', 4443),
      host: env.HOST || '0.0.0.0',
      secret: required('CALL_SFU_SECRET'),

      /**
       * How far a token's `exp` may be in the past and still be taken.
       *
       * Server clocks drift. Zero tolerance turns a two-second skew into
       * "the call server refused" with nothing to debug.
       */
      clockToleranceSeconds: int('CALL_TOKEN_CLOCK_TOLERANCE', 30),

      /**
       * A ceiling on a room, not a business rule — the business rule is
       * in Postgres, where a call cannot reach further than the
       * conversation it came from. This is the thing that stops one
       * runaway room taking the machine down with it.
       */
      maxPeersPerRoom: int('CALL_MAX_PEERS_PER_ROOM', 16),

      /**
       * A half-open socket leaves a peer in the room that nobody can
       * hear and nobody can remove. Ping, and reap what does not answer.
       */
      heartbeatMs: int('CALL_HEARTBEAT_MS', 20000),

      worker: {
        count: int('MEDIASOUP_WORKERS', os.cpus().length),
        rtcMinPort: minPort,
        rtcMaxPort: maxPort,
        logLevel: env.MEDIASOUP_LOG_LEVEL || 'warn',
        logTags: ['info', 'ice', 'dtls', 'rtp', 'srtp', 'rtcp'],
      },

      listenInfos: [
        {
          protocol: 'udp',
          ip: listenIp,
          ...(announcedAddress ? { announcedAddress } : {}),
          portRange: { min: minPort, max: maxPort },
        },
        // TCP as well as UDP. On a corporate network that blocks UDP
        // outright, ICE-TCP to the SFU is what turns a failed call into
        // a working one — and it costs nothing when UDP works, because
        // ICE prefers UDP anyway.
        {
          protocol: 'tcp',
          ip: listenIp,
          ...(announcedAddress ? { announcedAddress } : {}),
          portRange: { min: minPort, max: maxPort },
        },
      ],

      initialAvailableOutgoingBitrate: int('MEDIASOUP_INITIAL_BITRATE', 600000),
    };
  } finally {
    process.env = previous;
  }
}

/**
 * What the router will carry.
 *
 * Opus for voice. For video: VP8 first because every target decodes it,
 * then H.264 because iOS Safari decodes that in hardware and VP8 in
 * software, and then VP9. The order matters — mediasoup offers them in
 * this order and the endpoint takes the first it likes.
 *
 * `x-google-start-bitrate` is a hint to the sender's encoder, not a
 * limit: without it Chrome opens at a bitrate low enough that the first
 * few seconds of every call look like a fax.
 */
export const mediaCodecs = [
  {
    kind: 'audio',
    mimeType: 'audio/opus',
    clockRate: 48000,
    channels: 2,
  },
  {
    kind: 'video',
    mimeType: 'video/VP8',
    clockRate: 90000,
    parameters: { 'x-google-start-bitrate': 1000 },
  },
  {
    kind: 'video',
    mimeType: 'video/H264',
    clockRate: 90000,
    parameters: {
      'packetization-mode': 1,
      // Constrained Baseline 3.1. The profile every phone decodes in
      // hardware; anything higher is a battery bill.
      'profile-level-id': '42e01f',
      'level-asymmetry-allowed': 1,
      'x-google-start-bitrate': 1000,
    },
  },
  {
    kind: 'video',
    mimeType: 'video/VP9',
    clockRate: 90000,
    parameters: { 'profile-id': 2, 'x-google-start-bitrate': 1000 },
  },
];
