declare module "json-dup-key-validator" {
  export function parse(source: string, allowDuplicatedKeys?: boolean): unknown;
  export function validate(
    source: string,
    allowDuplicatedKeys?: boolean,
  ): Error | undefined;
}
