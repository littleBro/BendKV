# Archive: BendKV with shards

This branch keeps BendKV as it was before the shards were taken out: the
database split across cores (`shard.bend`), shards that answer in RESP bytes
(`wire.bend`), an append-only file per shard, a key hashed once (`exec.at`),
and the laws and proofs for all of it. It is a snapshot of an earlier layout
(the sources sit at the top level) and is not maintained.

Why they were taken out, and what they gave: `docs/FINDINGS.md` on `main`,
sections 3a–3c, 3g, 3h and 3l. They may come back into BendKV in a later round
of optimization, once it works as a drop-in Redis for one node.

The current code is on the `main` branch.
