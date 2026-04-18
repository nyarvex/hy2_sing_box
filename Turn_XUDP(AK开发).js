import { connect } from 'cloudflare:sockets';
const uuid = '58153d94-64a4-40c0-b4ae-27da6b90babe', maxED = 8192;
export default { fetch: req => req.headers.get('Upgrade') === 'websocket' ? ws(req) : new Response('ok') };
const idB = Uint8Array.fromHex(uuid.replaceAll('-', '')), dec = new TextDecoder(), enc = s => new TextEncoder().encode(s);
const u16 = (b, o = 0) => (b[o] << 8) | b[o + 1], pad4 = n => -n & 3;
const checkUUID = c => !idB.some((v, i) => c[i + 1] !== v);
const addr = (t, b) => t === 3 ? dec.decode(b) : t === 1 ? b.join('.') : t === 4 ? `[${Array.from({ length: 8 }, (_, i) => u16(b, i * 2).toString(16)).join(':')}]` : '';
const parseAddr = (b, o, t) => { const l = t === 3 ? b[o++] : t === 1 ? 4 : t === 4 ? 16 : 0; return l && o + l <= b.length ? { addrBytes: b.subarray(o, o + l), dataOffset: o + l } : null; };
const vless = c => { if (!checkUUID(c)) return null; const o = 19 + c[17], t = c[o + 2] === 1 ? 1 : c[o + 2] + 1, a = parseAddr(c, o + 3, t); return a ? { addrType: t, ...a, port: u16(c, o) } : null; };
const vlessUDP = c => checkUUID(c) && c[18 + c[17]] === 3 ? { cmd: 3, dataOffset: 19 + c[17] } : null;
const relay = async (rd, send, close) => { try { for (;;) { const { done, value } = await rd.read(); if (done) break; value?.byteLength && send(value); } } catch {} finally { rd.releaseLock(); close(); } };
const MAGIC = new Uint8Array([0x21, 0x12, 0xA4, 0x42]);
const MT = { AQ: 0x003, AO: 0x103, AE: 0x113, PQ: 0x008, PO: 0x108, CQ: 0x00A, CO: 0x10A, BQ: 0x00B, BO: 0x10B, SI: 0x016, DI: 0x017 };
const AT = { USER: 0x006, MI: 0x008, ERR: 0x009, PEER: 0x012, DATA: 0x013, REALM: 0x014, NONCE: 0x015, TRANSPORT: 0x019, CONNID: 0x02A };
const cat = (...a) => { const r = new Uint8Array(a.reduce((s, x) => s + x.length, 0)); a.reduce((o, x) => (r.set(x, o), o + x.length), 0); return r; };
const safeClose = (...a) => a.forEach(x => { try { x?.close?.(); } catch {} });
const dial = async (h, p) => { const s = connect({ hostname: h, port: p }); await s.opened; return s; };
const tid = () => crypto.getRandomValues(new Uint8Array(12));
const stunAttr = (t, v) => { const b = new Uint8Array(4 + v.length + pad4(v.length)), d = new DataView(b.buffer); d.setUint16(0, t); d.setUint16(2, v.length); b.set(v, 4); return b; };
const stunMsg = (t, id, a) => { const bd = cat(...a), h = new Uint8Array(20), d = new DataView(h.buffer); d.setUint16(0, t); d.setUint16(2, bd.length); h.set(MAGIC, 4); h.set(id, 8); return cat(h, bd); };
const xorPeer = (ip, port) => { const b = new Uint8Array(8); b[1] = 1; new DataView(b.buffer).setUint16(2, port ^ 0x2112); ip.split('.').forEach((v, i) => b[4 + i] = +v ^ MAGIC[i]); return b; };
const parseStun = d => {
  if (d.length < 20 || MAGIC.some((v, i) => d[4 + i] !== v)) return null;
  const dv = new DataView(d.buffer, d.byteOffset, d.byteLength), ml = dv.getUint16(2), attrs = {};
  for (let o = 20; o + 4 <= 20 + ml; ) { const t = dv.getUint16(o), l = dv.getUint16(o + 2); if (o + 4 + l > d.length) break; attrs[t] = d.slice(o + 4, o + 4 + l); o += 4 + l + pad4(l); }
  return { type: dv.getUint16(0), attrs };
};
const parseErr = d => d?.length >= 4 ? (d[2] & 7) * 100 + d[3] : 0;
const parseXorPeer = d => d?.length >= 8 ? [MAGIC.map((m, i) => d[4 + i] ^ m).join('.'), u16(d, 2) ^ 0x2112] : ['', 0];
const addIntegrity = async (m, key) => { const c = new Uint8Array(m), d = new DataView(c.buffer); d.setUint16(2, d.getUint16(2) + 24); const k = await crypto.subtle.importKey('raw', key, { name: 'HMAC', hash: 'SHA-1' }, false, ['sign']); return cat(c, stunAttr(AT.MI, new Uint8Array(await crypto.subtle.sign('HMAC', k, c)))); };
const readStun = async (rd, buf) => {
  let b = buf ?? new Uint8Array(0); const pull = async () => { const { done, value } = await rd.read(); if (done) throw 0; b = cat(b, new Uint8Array(value)); };
  try { while (b.length < 20) await pull(); const n = 20 + u16(b, 2); while (b.length < n) await pull();
    return [parseStun(b.subarray(0, n)), b.length > n ? b.subarray(n) : null]; } catch { return [null, null]; }
};
const resolveIP = async h => /^\d+\.\d+\.\d+\.\d+$/.test(h) ? h : (await fetch(`https://cloudflare-dns.com/dns-query?name=${encodeURIComponent(h)}&type=A`, { headers: { Accept: 'application/dns-json' } }).then(r => r.json()).catch(() => ({}))).Answer?.find(a => a.type === 1)?.data ?? null;
const md5 = async s => new Uint8Array(await crypto.subtle.digest('MD5', enc(s)));
const turnAuth = async (w, r, transport, { user, pass }, pipeline) => {
  const tp = new Uint8Array([transport, 0, 0, 0]);
  await w.write(stunMsg(MT.AQ, tid(), [stunAttr(AT.TRANSPORT, tp)]));
  let [msg, ex] = await readStun(r); if (!msg) return null;
  let key = null, aa = [];
  const sign = m => key ? addIntegrity(m, key) : Promise.resolve(m);
  if (msg.type === MT.AE && user && parseErr(msg.attrs[AT.ERR]) === 401) {
    const realm = dec.decode(msg.attrs[AT.REALM] ?? new Uint8Array(0)), nonce = msg.attrs[AT.NONCE] ?? new Uint8Array(0);
    key = await md5(`${user}:${realm}:${pass}`);
    aa = [stunAttr(AT.USER, enc(user)), stunAttr(AT.REALM, enc(realm)), stunAttr(AT.NONCE, nonce)];
    const aq = await addIntegrity(stunMsg(MT.AQ, tid(), [stunAttr(AT.TRANSPORT, tp), ...aa]), key);
    const extras = pipeline ? await Promise.all(pipeline(aa, sign)) : [];
    await w.write(extras.length ? cat(aq, ...extras) : aq);
    [msg, ex] = await readStun(r, ex); if (!msg) return null;
  } else if (pipeline && msg.type === MT.AO) {
    const extras = await Promise.all(pipeline(aa, sign));
    if (extras.length) await w.write(cat(...extras));
  }
  return msg.type === MT.AO ? { key, aa, ex, sign } : null;
};
const getTurn = url => { const m = decodeURIComponent(url).match(/\/turn:\/\/([^?&#\s]*)/i); if (!m) return null; const t = m[1], at = t.lastIndexOf('@'), cred = at >= 0 ? t.slice(0, at) : '', hp = t.slice(at + 1), [host, p] = hp.split(':'), ci = cred.indexOf(':'); return p ? { host, port: +p, user: ci >= 0 ? cred.slice(0, ci) : '', pass: ci >= 0 ? cred.slice(ci + 1) : '' } : null; };
const encodeAddr = h => {
  const s = h.replace(/^\[|\]$/g, ''), m = s.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
  if (m) return new Uint8Array([0x01, ...m.slice(1).map(Number)]);
  if (s.includes(':')) { const b = new Uint8Array(17); b[0] = 0x03; s.split(':').forEach((x, i) => { const v = parseInt(x, 16) || 0; b[1 + i * 2] = v >> 8; b[2 + i * 2] = v & 0xff; }); return b; }
  const e = enc(h); return cat(new Uint8Array([0x02, e.length]), e);
};
const xudpAddr = d => {
  if (!d.length) return ['', 0];
  if (d[0] <= 1) return d.length >= 5 ? [d.subarray(1, 5).join('.'), 5] : ['', 0];
  if (d[0] === 2) return d.length >= 2 + d[1] ? [dec.decode(d.subarray(2, 2 + d[1])), 2 + d[1]] : ['', 0];
  return d[0] === 3 && d.length >= 17 ? [`[${Array.from({ length: 8 }, (_, i) => u16(d, 1 + i * 2).toString(16)).join(':')}]`, 17] : ['', 0];
};
const fakeIPType = h => { const m = h.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/); return m && +m[1] === 198 && [18, 19].includes(+m[2]) ? 4 : h.replace(/^\[|\]$/g, '').startsWith('fc') && h.includes(':') ? 6 : 0; };
const parseXUDP = d => {
  if (d.length < 6) return null;
  const metaLen = u16(d), metaEnd = 2 + metaLen;
  if (metaLen < 4 || metaEnd > d.length) return null;
  const f = { network: metaEnd > 6 ? d[6] : 0, port: metaEnd >= 9 ? u16(d, 7) : 0, host: metaEnd > 9 ? xudpAddr(d.subarray(9, metaEnd))[0] : '', payload: null, totalLen: metaEnd };
  if ((d[5] & 1) && metaEnd + 2 <= d.length) { const pLen = u16(d, metaEnd); if (metaEnd + 2 + pLen <= d.length) { f.payload = d.subarray(metaEnd + 2, metaEnd + 2 + pLen); f.totalLen = metaEnd + 2 + pLen; } }
  return f;
};
const xudpResp = (host, port, payload) => { const a = encodeAddr(host), ml = 7 + a.length, buf = new Uint8Array(2 + ml + 2 + payload.length); [buf[0], buf[1], buf[4], buf[5], buf[6], buf[7], buf[8]] = [ml >> 8, ml & 0xff, 2, 1, 2, port >> 8, port & 0xff]; buf.set(a, 9); const pOff = 2 + ml; [buf[pOff], buf[pOff + 1]] = [payload.length >> 8, payload.length & 0xff]; buf.set(payload, pOff + 2); return buf; };
const turnConn = async ({ host, port, user, pass }, targetIp, targetPort) => {
  let ctrl = null, data = null;
  const close = () => safeClose(ctrl, data);
  try {
    ctrl = await dial(host, port);
    const cw = ctrl.writable.getWriter(), cr = ctrl.readable.getReader();
    const peer = stunAttr(AT.PEER, xorPeer(targetIp, targetPort));
    const auth = await turnAuth(cw, cr, 6, { user, pass }, (aa, sign) => [sign(stunMsg(MT.PQ, tid(), [peer, ...aa])), sign(stunMsg(MT.CQ, tid(), [peer, ...aa]))]);
    if (!auth) { close(); return null; }
    const { aa, sign } = auth; let ex = auth.ex;
    data = connect({ hostname: host, port });
    let r; [r, ex] = await readStun(cr, ex); if (r?.type !== MT.PO) { close(); return null; }
    [r, ex] = await readStun(cr, ex); if (r?.type !== MT.CO || !r.attrs[AT.CONNID]) { close(); return null; }
    await data.opened; const dw = data.writable.getWriter(), dr = data.readable.getReader();
    await dw.write(await sign(stunMsg(MT.BQ, tid(), [stunAttr(AT.CONNID, r.attrs[AT.CONNID]), ...aa])));
    let extra; [r, extra] = await readStun(dr); if (r?.type !== MT.BO) { close(); return null; }
    cr.releaseLock(); cw.releaseLock(); dw.releaseLock();
    const readable = new ReadableStream({ start: c => extra?.length && c.enqueue(extra), pull: c => dr.read().then(({ done, value }) => done ? c.close() : c.enqueue(new Uint8Array(value))), cancel: () => dr.cancel() });
    return { readable, writable: data.writable, close };
  } catch { close(); return null; }
};
const turnUDP = async ({ host, port, user, pass }, sendWs) => {
  let sock = null, closed = false;
  const perms = new Set(), sess = new Map(), reverse = {};
  const close = () => { closed = true; safeClose(sock); };
  try {
    sock = await dial(host, port);
    const w = sock.writable.getWriter(), r = sock.readable.getReader();
    const auth = await turnAuth(w, r, 17, { user, pass }); if (!auth) { close(); return null; }
    const { aa, sign } = auth; let buf = auth.ex;
    (async () => { while (!closed) { const [m, nx] = await readStun(r, buf); buf = nx; if (!m) break; if (m.type === MT.DI && m.attrs[AT.PEER] && m.attrs[AT.DATA]) { const [ip, pt] = parseXorPeer(m.attrs[AT.PEER]), s = reverse[`${ip}:${pt}`]; sendWs(xudpResp(s?.host ?? ip, s?.port ?? pt, m.attrs[AT.DATA])); } } })();
    const ensurePerm = ip => { if (perms.has(ip)) return; perms.add(ip); sign(stunMsg(MT.PQ, tid(), [stunAttr(AT.PEER, xorPeer(ip, 0)), ...aa])).then(m => w.write(m)); };
    const sendUDP = (ip, port, data) => w.write(stunMsg(MT.SI, tid(), [stunAttr(AT.PEER, xorPeer(ip, port)), stunAttr(AT.DATA, data)]));
    const getIP = (h, p) => {
      const k = `${h}:${p}`, c = sess.get(k); if (c) return c.ip;
      const ft = fakeIPType(h); if (ft) for (const s of sess.values()) if (s.port === p && s.isV6 === (ft === 6)) { const ns = { ip: s.ip, host: h, port: p, isV6: s.isV6 }; sess.set(k, ns); reverse[`${s.ip}:${p}`] = ns; return s.ip; }
      return null;
    };
    const resolveAsync = async (h, p, k) => { const ip = await resolveIP(h); if (ip) { const s = { ip, host: h, port: p, isV6: ip.includes(':') }; sess.set(k, s); reverse[`${ip}:${p}`] = s; } };
    const processXUDP = data => { while (data.length >= 6) { const f = parseXUDP(data); if (!f) break; if (f.network === 2 && f.payload?.length && f.host) { const k = `${f.host}:${f.port}`, ip = getIP(f.host, f.port); ip ? (ensurePerm(ip), sendUDP(ip, f.port, f.payload)) : sess.has(k) || resolveAsync(f.host, f.port, k); } data = data.subarray(f.totalLen); } };
    return { processXUDP, close };
  } catch { close(); return null; }
};
const ws = async req => {
  const [client, server] = Object.values(new WebSocketPair()); server.accept();
  const ed = req.headers.get('sec-websocket-protocol'), turn = getTurn(req.url);
  let w = null, sock = null, udp = null, chain = Promise.resolve();
  const close = () => { udp?.close(); safeClose(sock, server); }, send = d => { try { server.send(d); } catch {} };
  const process = async chunk => {
    if (w) return w.write(chunk);
    if (udp) return udp.processXUDP(chunk);
    const ack = () => send(new Uint8Array([chunk[0], 0])), u = vlessUDP(chunk);
    if (u && turn) { ack(); udp = await turnUDP(turn, send); if (!udp) return close(); const ud = chunk.subarray(u.dataOffset); ud.length && udp.processXUDP(ud); return; }
    const v = vless(chunk); if (!v) return close(); ack();
    const { addrType, addrBytes, dataOffset, port } = v, host = addr(addrType, addrBytes), payload = chunk.subarray(dataOffset);
    if (turn) { const ip = addrType === 1 ? host : await resolveIP(host); if (!ip) return close(); sock = await turnConn(turn, ip, port).catch(() => null); if (!sock) return close(); }
    else { try { sock = await dial(host, port); } catch { return close(); } }
    w = sock.writable.getWriter(); payload.byteLength && await w.write(payload); relay(sock.readable.getReader(), send, close);
  };
  if (ed?.length <= maxED) chain = chain.then(() => process(Uint8Array.fromBase64(ed, { alphabet: 'base64url' }))).catch(close);
  server.addEventListener('message', e => { chain = chain.then(() => process(new Uint8Array(e.data instanceof ArrayBuffer ? e.data : e.data.buffer ?? e.data))).catch(close); });
  server.addEventListener('close', close); server.addEventListener('error', close);
  return new Response(null, { status: 101, webSocket: client, headers: ed ? { 'sec-websocket-protocol': ed } : {} });
};