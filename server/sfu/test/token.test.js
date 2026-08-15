/**
 * Who gets into a room.
 *
 * Every case here is a way a token check has been got wrong in real
 * systems rather than a way this one might be. The room name is public
 * to a whole conversation, so the token is the only thing standing
 * between somebody who was invited to a call and somebody who was not.
 */
import { createHmac } from 'node:crypto';
import assert from 'node:assert/strict';
import test from 'node:test';

import { TokenError, tokenFromRequest, verifyToken } from '../src/token.js';

const SECRET = 'a-secret-that-only-the-edge-function-and-this-server-hold';

function b64(value) {
  return Buffer.from(JSON.stringify(value)).toString('base64url');
}

/** Mints one exactly as `supabase/functions/call-token` does. */
function mint(claims, { secret = SECRET, header = { alg: 'HS256', typ: 'JWT' } } = {}) {
  const body = `${b64(header)}.${b64(claims)}`;
  const signature = createHmac('sha256', secret).update(body).digest('base64url');
  return `${body}.${signature}`;
}

const future = Math.floor(Date.now() / 1000) + 600;

const good = {
  sub: '11111111-1111-1111-1111-111111111111',
  room: '9f2c4e6a8b0d2f4a6c8e0a2c4e6a8b0d',
  name: 'Siti Nurhaliza',
  kind: 'video',
  exp: future,
};

test('a token from the edge function is taken, and says who and where', () => {
  const identity = verifyToken(mint(good), SECRET);
  assert.equal(identity.peerId, good.sub);
  assert.equal(identity.room, good.room);
  assert.equal(identity.displayName, 'Siti Nurhaliza');
  assert.equal(identity.kind, 'video');
});

test('a token signed with a different secret is refused', () => {
  assert.throws(
    () => verifyToken(mint(good, { secret: 'not-the-secret' }), SECRET),
    TokenError,
  );

  // The control: the same claims under the right secret are taken. An
  // assertion that only checks "was this refused?" passes for any reason
  // a call can fail, including the function being broken outright.
  assert.equal(verifyToken(mint(good), SECRET).peerId, good.sub);
});

test('"alg": "none" is refused, signature or no signature', () => {
  const header = b64({ alg: 'none', typ: 'JWT' });
  const payload = b64(good);

  assert.throws(() => verifyToken(`${header}.${payload}.`, SECRET), TokenError);
  assert.throws(
    () => verifyToken(`${header}.${payload}.${payload}`, SECRET),
    TokenError,
  );

  // This is the oldest JWT attack there is and it only works against a
  // verifier that reads `alg` and does what it says. Nothing about the
  // claims is wrong here — the same ones under HS256 are fine — so a
  // refusal has to be coming from the algorithm check.
  assert.equal(verifyToken(mint(good), SECRET).room, good.room);
});

test('an expired token is refused, and clock skew is forgiven', () => {
  const now = Math.floor(Date.now() / 1000);
  const stale = mint({ ...good, exp: now - 60 });

  assert.throws(() => verifyToken(stale, SECRET), TokenError);

  // Server clocks drift. Two minutes of tolerance takes a token that
  // expired one minute ago.
  assert.equal(
    verifyToken(stale, SECRET, { clockToleranceSeconds: 120 }).peerId,
    good.sub,
  );
});

test('a token without an expiry is refused', () => {
  const { exp: _dropped, ...noExpiry } = good;
  assert.throws(() => verifyToken(mint(noExpiry), SECRET), TokenError);
});

test('claims cannot be edited without the secret', () => {
  const original = mint(good);
  const [header, , signature] = original.split('.');
  // Somebody who has been given a token for their own call, editing it
  // to point at a room they were never invited to.
  const forged = `${header}.${b64({ ...good, room: 'somebody-elses-room' })}.${signature}`;

  assert.throws(() => verifyToken(forged, SECRET), TokenError);
  assert.equal(verifyToken(original, SECRET).room, good.room);
});

test('a token naming no room or nobody is refused', () => {
  assert.throws(
    () => verifyToken(mint({ ...good, room: '' }), SECRET),
    TokenError,
  );
  assert.throws(
    () => verifyToken(mint({ ...good, sub: undefined }), SECRET),
    TokenError,
  );
});

test('rubbish is refused rather than crashing the connection', () => {
  for (const rubbish of ['', 'not-a-token', 'a.b', 'a.b.c.d', '...']) {
    assert.throws(() => verifyToken(rubbish, SECRET), TokenError, rubbish);
  }
  assert.throws(() => verifyToken(undefined, SECRET), TokenError);
});

test('a nameless token still gets a name, because the UI needs one', () => {
  const { name: _dropped, ...anonymous } = good;
  assert.equal(verifyToken(mint(anonymous), SECRET).displayName, 'Somebody');
});

test('the token is read from the query string, and the header wins', () => {
  const token = mint(good);
  assert.equal(tokenFromRequest({ url: `/?token=${token}`, headers: {} }), token);
  assert.equal(
    tokenFromRequest({
      url: `/?token=wrong`,
      headers: { authorization: `Bearer ${token}` },
    }),
    token,
  );
  assert.equal(tokenFromRequest({ url: '/', headers: {} }), '');
});
