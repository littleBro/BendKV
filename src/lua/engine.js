// The JS lane has no Lua engine: BendKV's server is built to C
// (src/lua/engine.c). These answer so that a program that names the
// effects still compiles for bun; a script fails at once there.
const none = "ERR BendKV runs Lua scripts on the C lane alone";
const step = (w, s) => ({$: CID(Step), w: w, s: s});
io_eff(CID(Engine.load), (body) => step(0, none));
io_eff(CID(Engine.find), (sha) => 0);
io_eff(CID(Engine.start), (sha, keys, args, word) => step(2 | (1 << 8), none));
io_eff(CID(Engine.next), (word, data) => step(2 | (1 << 8), none));
io_eff(CID(Engine.flush), () => ({$: CID(Unit)}));
io_eff(CID(Engine.count), () => 0);
io_eff(CID(Engine.mem), () => 0);
io_eff(CID(Engine.cache_mem), () => 0);
