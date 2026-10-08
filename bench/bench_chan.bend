# bench_chan.bend: the cost of a channel round trip between two
# computations of the Bend runtime (the server pays two per batch)
import Base

@unsafe
def echo(+inp: Chan(U32), +out: Chan(U32)) -> IO(Unit):
  do IO<Unit>:
    m : Maybe<&1, U32> <- Chan.recv(U32, inp)
    echo.next(inp, out, m)

@unsafe
def echo.next(+inp: Chan(U32), +out: Chan(U32), m: Maybe<&1, U32>) -> IO(Unit):
  match m:
    case Some{x}:
      do IO<Unit>:
        ok : Bool <- Chan.send(U32, out, x)
        echo(inp, out)
    case None{}:
      IO.pure(Unit, Unit{})

@unsafe
def ping(n: Nat, +inp: Chan(U32), +out: Chan(U32)) -> IO(Unit):
  match n:
    case 0n:
      Chan.close(U32, out)
    case 1n+p:
      do IO<Unit>:
        ok : Bool <- Chan.send(U32, out, 1)
        m : Maybe<&1, U32> <- Chan.recv(U32, inp)
        ping(p, inp, out)

def main() -> IO(Unit):
  do IO<Unit>:
    +a : Chan(U32) <- Chan.new(U32, 1)
    +b : Chan(U32) <- Chan.new(U32, 1)
    IO.spawn(Unit, echo(a, b))
    +t0 : Nat <- IO.now()
    ping(100000n, b, a)
    +t1 : Nat <- IO.now()
    IO.print("100000 channel round trips: " ++ Nat.show(Nat.sub(t1, t0)) ++ " ms")
