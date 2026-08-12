import crypto from 'node:crypto';

function encode(value) { return Buffer.from(value).toString('base64url'); }
function sign(value, secret) { return crypto.createHmac('sha256', secret).update(value).digest('base64url'); }

export function createSubtitleToken(payload, secret, now = Math.floor(Date.now() / 1000)) {
  if (!secret) throw new Error('token secret is required');
  const body = encode(JSON.stringify({ data: payload, exp: now + 300 }));
  return `${body}.${sign(body, secret)}`;
}

export function verifySubtitleToken(token, secret, now = Math.floor(Date.now() / 1000)) {
  try {
    const [body, signature, extra] = String(token).split('.');
    if (!body || !signature || extra) throw new Error();
    const expected = sign(body, secret);
    if (signature.length !== expected.length || !crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expected))) throw new Error();
    const value = JSON.parse(Buffer.from(body, 'base64url').toString('utf8'));
    if (!value?.data || typeof value.exp !== 'number') throw new Error();
    if (now > value.exp) throw new Error('expired token');
    return value.data;
  } catch (error) {
    if (error.message === 'expired token') throw error;
    throw new Error('invalid token');
  }
}
