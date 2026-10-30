// Seals a generated Lua payload behind a small loader. The Lua side has no
// crypto library, so this is a seeded 32-bit stream cipher plus base64: enough
// that the served file is unreadable and un-copyable, while the dashboard can
// reveal the real source to admins from the database rather than from the wire.

const ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

const seedOf = (text) => {
  let hash = 2166136261;
  const value = String(text ?? '');
  for (let i = 0; i < value.length; i += 1) {
    hash ^= value.charCodeAt(i);
    hash = Math.imul(hash, 16777619) >>> 0;
  }
  return hash >>> 0;
};

const base64 = (bytes) => {
  let out = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i];
    const b = bytes[i + 1];
    const c = bytes[i + 2];
    out += ALPHABET[a >> 2];
    out += ALPHABET[((a & 3) << 4) | ((b ?? 0) >> 4)];
    out += b === undefined ? '=' : ALPHABET[((b & 15) << 2) | ((c ?? 0) >> 6)];
    out += c === undefined ? '=' : ALPHABET[c & 63];
  }
  return out;
};

export const scriptSeed = (token, kind, secret) => seedOf(`${token}:${kind}:${secret}`);

export const sealLua = (source, seed) => {
  const bytes = new TextEncoder().encode(String(source));
  let state = Number(seed) >>> 0;
  for (let i = 0; i < bytes.length; i += 1) {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    bytes[i] ^= (state >>> 24) & 0xff;
  }

  return `-- Vexora | sealed payload
local p = "${base64(bytes)}"
local s = ${Number(seed) >>> 0}
local a = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local map = {}
for i = 1, #a do map[a:sub(i, i)] = i - 1 end

local bytes, value, bits = {}, 0, 0
for i = 1, #p do
    local c = p:sub(i, i)
    if c ~= "=" then
        local n = map[c]
        if n then
            value = value * 64 + n
            bits = bits + 6
            while bits >= 8 do
                bits = bits - 8
                local step = 2 ^ bits
                local byte = math.floor(value / step)
                bytes[#bytes + 1] = byte % 256
                value = value - byte * step
            end
        end
    end
end

local function xor8(x, y)
    local out, bit = 0, 1
    for _ = 1, 8 do
        local xb, yb = x % 2, y % 2
        if xb ~= yb then out = out + bit end
        x = (x - xb) / 2
        y = (y - yb) / 2
        bit = bit * 2
    end
    return out
end

local plain = {}
for i = 1, #bytes do
    s = (s * 1664525 + 1013904223) % 4294967296
    plain[i] = string.char(xor8(bytes[i], math.floor(s / 16777216) % 256))
end

if type(loadstring) ~= "function" then
    return warn("[vexora] this executor does not expose loadstring")
end

local chunk, loadError = loadstring(table.concat(plain))
if not chunk then
    return warn("[vexora] loader failed: " .. tostring(loadError))
end

local ok, runError = pcall(chunk)
if not ok then
    warn("[vexora] runtime error: " .. tostring(runError))
end
`;
};
