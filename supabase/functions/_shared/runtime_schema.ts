import * as v from "jsr:@valibot/valibot@0.42.1";

export interface SchemaIssue {
  message: string;
}

export type RuntimeSchema = v.BaseSchema<
  unknown,
  unknown,
  v.BaseIssue<unknown>
>;

export type SchemaParseResult<TSchema extends RuntimeSchema> =
  | { ok: true; output: v.InferOutput<TSchema> }
  | { ok: false; issues: SchemaIssue[] };

export function parseWithSchema<TSchema extends RuntimeSchema>(
  schema: TSchema,
  input: unknown,
): SchemaParseResult<TSchema> {
  const parsed = v.safeParse(schema, input);
  if (parsed.success) {
    return { ok: true, output: parsed.output };
  }

  const issues = parsed.issues.map((issue) => ({
    message: issue.message,
  }));
  return { ok: false, issues };
}

export { v };
