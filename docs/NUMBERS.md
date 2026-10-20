# BendKV in numbers

The counts the other documents link to, written by
[`tools/gen_counts.py`](../tools/gen_counts.py) from the files they count; `make gencheck`
fails when one is out of date. Lines of code leave out comments and blank lines and are
rounded to two significant figures; they are out of date once a file's count is a tenth
away.

<!-- BEGIN gen_counts: numbers -->
| what | how many | counted in |
|---|---:|---|
| laws | 68 | `proof/LAWS.bend` (by group: [What is proved](../README.md#what-is-proved)) |
| patches to the Bend compiler | 39 | `bend-patches/apply.sh` |
| constructors of `Cmd`, a parsed command | 30 | `src/redis.bend` |
| Redis 7.2.16's parameters, all of which CONFIG serves | 184 | `tools/data/redis-configs.json` |

| file | lines of code | of them written by a generator | the laws import it |
|---|---:|---:|---|
| `src/map.bend` | 5,700 | 1,500 | yes |
| `src/redis.bend` | 21,000 | 6,800 | yes |
| `src/batch.bend` | 84 |  | yes |
| `src/aof.bend` | 1,300 |  | yes |
| `src/session.bend` | 3,400 |  | yes |
| `src/config.bend` | 1,400 | 190 | yes |
| `src/acl.bend` | 2,300 | 760 | no |
| `src/aofdir.bend` | 360 |  | no |
| `src/command.bend` | 2,800 | 2,100 | no |
| `src/float.bend` | 1,600 |  | no |
| `src/geo.bend` | 870 |  | no |
| `src/hll.bend` | 1,400 |  | no |
| `src/info.bend` | 3,200 |  | no |
| `src/lolwut.bend` | 470 |  | no |
| `src/rdb.bend` | 3,100 |  | no |
| `src/resp.bend` | 1,200 |  | no |
| `src/script.bend` | 51 |  | no |
| `src/server.bend` | 15,000 |  | no |
| `src/sha.bend` | 120 |  | no |
| `src/startup.bend` | 460 |  | no |
| `src/stream.bend` | 1,700 |  | no |
| `proof/LAWS.bend` | 920 | 20 |  |
| `proof/SPEC.bend` | 370 |  |  |
| `proof/PROOF.bend` | 18,000 | 2,800 |  |
| `src/`, the 6 files the laws import | 31,000 | 8,200 |  |
| `src/`, the 15 others | 36,000 | 3,100 |  |
| `proof/` | 20,000 | 2,800 |  |
<!-- END gen_counts: numbers -->
