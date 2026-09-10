// deno-coverage-ignore-file
export interface MockQueryFilter {
  op: string;
  column: string;
  value: unknown;
}

export interface MockQueryState {
  table: string;
  action: "select" | "update" | "upsert" | "insert" | "delete" | null;
  payload?: unknown;
  options?: unknown;
  selected?: string;
  filters: MockQueryFilter[];
  limit?: number;
  orderBy: Array<{ column: string; options: unknown }>;
  range?: { from: number; to: number };
  terminal: "then" | "returns" | "maybeSingle" | "single";
}

export interface MockQueryResult {
  count?: number | null;
  data?: unknown;
  error?: { code?: string; message: string } | null;
}

export function createMockSupabaseService(
  resolver: (
    state: MockQueryState,
  ) => MockQueryResult | Promise<MockQueryResult>,
) {
  const calls: MockQueryState[] = [];

  const buildQuery = (table: string) => {
    const state: Omit<MockQueryState, "terminal"> = {
      table,
      action: null as MockQueryState["action"],
      payload: undefined as unknown,
      options: undefined as unknown,
      selected: undefined as string | undefined,
      filters: [] as MockQueryFilter[],
      limit: undefined as number | undefined,
      orderBy: [] as Array<{ column: string; options: unknown }>,
      range: undefined as MockQueryState["range"],
    };

    const execute = async (
      terminal: MockQueryState["terminal"],
    ): Promise<MockQueryResult> => {
      const snapshot = structuredClone({
        ...state,
        terminal,
      }) as MockQueryState;
      calls.push(snapshot);
      return await resolver(snapshot);
    };

    const query = {
      delete() {
        state.action = "delete";
        return query;
      },
      eq(column: string, value: unknown) {
        state.filters.push({ op: "eq", column, value });
        return query;
      },
      neq(column: string, value: unknown) {
        state.filters.push({ op: "neq", column, value });
        return query;
      },
      or(value: string) {
        state.filters.push({ op: "or", column: "", value });
        return query;
      },
      gte(column: string, value: unknown) {
        state.filters.push({ op: "gte", column, value });
        return query;
      },
      in(column: string, value: unknown) {
        state.filters.push({ op: "in", column, value });
        return query;
      },
      insert(payload: unknown) {
        state.action = "insert";
        state.payload = payload;
        return query;
      },
      ilike(column: string, value: unknown) {
        state.filters.push({ op: "ilike", column, value });
        return query;
      },
      is(column: string, value: unknown) {
        state.filters.push({ op: "is", column, value });
        return query;
      },
      like(column: string, value: unknown) {
        state.filters.push({ op: "like", column, value });
        return query;
      },
      lt(column: string, value: unknown) {
        state.filters.push({ op: "lt", column, value });
        return query;
      },
      lte(column: string, value: unknown) {
        state.filters.push({ op: "lte", column, value });
        return query;
      },
      limit(count: number) {
        state.limit = count;
        return query;
      },
      maybeSingle<T>() {
        void (0 as T | undefined);
        return execute("maybeSingle");
      },
      order(column: string, options: unknown) {
        state.orderBy.push({ column, options });
        return query;
      },
      range(from: number, to: number) {
        state.range = { from, to };
        return query;
      },
      returns<T>() {
        void (0 as T | undefined);
        return execute("returns");
      },
      select(columns: string, options?: unknown) {
        if (state.action === null) {
          state.action = "select";
        }
        state.selected = columns;
        state.options = options;
        return query;
      },
      single<T>() {
        void (0 as T | undefined);
        return execute("single");
      },
      then<TResult1 = MockQueryResult, TResult2 = never>(
        onFulfilled?:
          | ((value: MockQueryResult) => TResult1 | PromiseLike<TResult1>)
          | null,
        onRejected?:
          | ((reason: unknown) => TResult2 | PromiseLike<TResult2>)
          | null,
      ) {
        return execute("then").then(onFulfilled, onRejected);
      },
      update(payload: unknown) {
        state.action = "update";
        state.payload = payload;
        return query;
      },
      upsert(payload: unknown, options?: unknown) {
        state.action = "upsert";
        state.payload = payload;
        state.options = options;
        return query;
      },
    };

    return query;
  };

  return {
    from(table: string) {
      return buildQuery(table);
    },
    __calls: calls,
  };
}
