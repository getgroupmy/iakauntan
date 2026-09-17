/**
 * `jsr:@std/assert@1`, for the test files that import it.
 *
 * Only the assertions this repository uses, and each with the real
 * arity — the point of the fallback is to catch an argument of the
 * wrong shape, so `assertEquals(a)` with one argument has to be an
 * error here as it is in CI.
 *
 * A seventh assertion appearing is a compile error that makes somebody
 * come and add it, which is the right prompt. A blanket `any` export
 * would hide a misspelled one.
 */
export function assert(expr: unknown, msg?: string): void {}
export function assertFalse(expr: unknown, msg?: string): void {}
export function assertEquals(actual: unknown, expected: unknown, msg?: string): void {}
export function assertNotEquals(actual: unknown, expected: unknown, msg?: string): void {}
// The real shapes, not simplified ones. `assertThrows(fn, Error, 'x')`
// is how three of these tests are written, and a two-argument stub
// turns a correct call into a compile error -- which is the fallback
// inventing a failure rather than finding one.
export function assertThrows(
  fn: () => unknown,
  errorClass?: (new (...args: never[]) => Error) | string,
  msgIncludes?: string,
  msg?: string,
): Error {
  return new Error();
}
export function assertRejects(
  fn: () => Promise<unknown>,
  errorClass?: (new (...args: never[]) => Error) | string,
  msgIncludes?: string,
  msg?: string,
): Promise<Error> {
  return Promise.resolve(new Error());
}
