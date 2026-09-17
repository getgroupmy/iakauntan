/**
 * The four pieces of Deno the edge functions actually use.
 *
 * `check_with_tsc.sh` needs these because `tsc` knows nothing about the
 * Deno runtime. Deliberately narrow: what is declared here is what this
 * repository uses, and a fifth thing appearing is a compile error that
 * makes somebody come and add it, which is the right prompt. A blanket
 * `declare const Deno: any` would hide a typo in `Deno.env.get`.
 *
 * `deno check` ignores this file entirely — it has the real
 * definitions — so this is only the shape of the fallback.
 */
declare namespace Deno {
  interface Env {
    get(key: string): string | undefined;
    set(key: string, value: string): void;
  }
  const env: Env;
  function serve(handler: (req: Request) => Response | Promise<Response>): {
    finished: Promise<void>;
  };
  function readTextFile(path: string | URL): Promise<string>;
  function test(
    nameOrDef: string | { name: string; fn: () => unknown },
    fn?: () => unknown,
  ): void;
}
