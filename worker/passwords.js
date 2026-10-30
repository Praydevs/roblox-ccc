// Workers has no synchronous scrypt, so the cloud build uses PBKDF2-SHA256.
// Format: pbkdf2$<iterations>$<salt hex>$<key hex>

// The Workers runtime caps PBKDF2 work, and the exact ceiling varies by plan, so
// step down until one is accepted. The iteration count is stored in the hash.
const ITERATIONS = [210000, 100000, 10000, 1];
const KEY_BITS = 256;
const encoder = new TextEncoder();

const hex = (bytes) => [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, '0')).join('');

const fromHex = (value) => {
  const out = new Uint8Array(value.length / 2);
  for (let i = 0; i < out.length; i += 1) out[i] = parseInt(value.slice(i * 2, i * 2 + 2), 16);
  return out;
};

const derive = async (password, salt, iterations) => {
  const base = await crypto.subtle.importKey('raw', encoder.encode(String(password)), 'PBKDF2', false, ['deriveBits']);
  return new Uint8Array(await crypto.subtle.deriveBits(
    { name: 'PBKDF2', hash: 'SHA-256', salt, iterations },
    base,
    KEY_BITS,
  ));
};

const equal = (a, b) => {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) diff |= a[i] ^ b[i];
  return diff === 0;
};

export const hashPassword = async (password) => {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  let lastError = null;
  for (const iterations of ITERATIONS) {
    try {
      const key = await derive(password, salt, iterations);
      return `pbkdf2$${iterations}$${hex(salt)}$${hex(key)}`;
    } catch (err) {
      lastError = err;
    }
  }
  throw lastError ?? new Error('password hashing unavailable');
};

export const verifyPassword = async (password, stored) => {
  if (!stored) return false;
  const [scheme, iterations, salt, digest] = String(stored).split('$');
  if (scheme !== 'pbkdf2' || !iterations || !salt || !digest) return false;
  const expected = fromHex(digest);
  if (expected.length !== KEY_BITS / 8) return false;
  const derived = await derive(password, fromHex(salt), Number(iterations) || 210000);
  return equal(derived, expected);
};
