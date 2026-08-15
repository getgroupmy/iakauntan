/**
 * Who is allowed into which room.
 *
 * The token is minted by the `call-token` edge function, which is the
 * only other thing holding `CALL_SFU_SECRET`, and which will not sign
 * one for anybody whose `chat_call_participants` row has not joined. So
 * the whole permission model — module bought, person switched on,
 * companies linked, participant of that conversation — is already
 * decided by the time a socket arrives here. This end's job is narrow:
 * establish that the token is genuine, and take the room and the
 * identity *from it*.
 *
 * That last part is the reason this file exists rather than a call to a
 * JWT library and a `req.url` parse. A server that reads the room from
 * the query string has no access control at all: the app is the only
 * thing that would ever send the right one.
 *
 * Written against `node:crypto` rather than a library because the
 * verification is twenty lines, the failure modes are well known, and
 * the ones that matter are asserted in `test/token.test.js` — including
 * the two that have historically emptied rooms: `alg: none`, and a
 * signature compared with `===`.
 */
import { createHmac, timingSafeEqual } from 'node:crypto';

export class TokenError extends Error {}

function decodeSegment(segment) {
  return Buffer.from(segment, 'base64url').toString('utf8');
}

/**
 * @param {string} token   the compact JWS from the edge function
 * @param {string} secret  CALL_SFU_SECRET
 * @param {{ now?: number, clockToleranceSeconds?: number }} [options]
 * @returns {{ peerId: string, room: string, displayName: string, kind: string }}
 */
export function verifyToken(token, secret, options = {}) {
  const now = options.now ?? Math.floor(Date.now() / 1000);
  const tolerance = options.clockToleranceSeconds ?? 0;

  if (typeof token !== 'string' || token.length === 0) {
    throw new TokenError('No token');
  }

  const parts = token.split('.');
  if (parts.length !== 3) throw new TokenError('Malformed token');
  const [headerPart, payloadPart, signaturePart] = parts;

  let header;
  try {
    header = JSON.parse(decodeSegment(headerPart));
  } catch {
    throw new TokenError('Malformed token header');
  }

  // An allowlist of one. The attack this closes is old and still works
  // against anything that reads `alg` and dispatches on it: present a
  // token with `alg: none` and no signature, or with `alg: HS256`
  // against a server that verifies with a public key, and the token
  // verifies itself. There is exactly one algorithm in use here, so
  // anything else is a forgery attempt rather than a compatibility
  // problem.
  if (header.alg !== 'HS256') {
    throw new TokenError(`Unsupported token algorithm: ${header.alg}`);
  }

  const expected = createHmac('sha256', secret)
    .update(`${headerPart}.${payloadPart}`)
    .digest();
  const actual = Buffer.from(signaturePart, 'base64url');

  // Lengths first: `timingSafeEqual` throws on a mismatch rather than
  // returning false, and a thrown error here would read as a server
  // fault instead of a rejected token.
  if (
    actual.length !== expected.length ||
    !timingSafeEqual(actual, expected)
  ) {
    throw new TokenError('Bad token signature');
  }

  let claims;
  try {
    claims = JSON.parse(decodeSegment(payloadPart));
  } catch {
    throw new TokenError('Malformed token payload');
  }

  if (typeof claims.exp !== 'number') {
    throw new TokenError('Token does not expire');
  }
  if (claims.exp + tolerance < now) {
    throw new TokenError('Token has expired');
  }
  if (typeof claims.room !== 'string' || claims.room.length === 0) {
    throw new TokenError('Token names no room');
  }
  if (typeof claims.sub !== 'string' || claims.sub.length === 0) {
    throw new TokenError('Token names nobody');
  }

  return {
    peerId: claims.sub,
    room: claims.room,
    displayName:
      typeof claims.name === 'string' && claims.name.length > 0
        ? claims.name
        : 'Somebody',
    kind: claims.kind === 'video' ? 'video' : 'voice',
  };
}

/**
 * Pulls the token out of a connection.
 *
 * Query string first, because that is what the Flutter client sends and
 * what a browser WebSocket can do at all — the WebSocket API has no way
 * to set an Authorization header. The header is accepted too, for
 * anything that can send one, and it wins when both are present.
 */
export function tokenFromRequest(req) {
  const auth = req.headers?.authorization;
  if (typeof auth === 'string' && auth.startsWith('Bearer ')) {
    return auth.slice('Bearer '.length).trim();
  }
  try {
    const url = new URL(req.url ?? '/', 'http://placeholder');
    return url.searchParams.get('token') ?? '';
  } catch {
    return '';
  }
}
