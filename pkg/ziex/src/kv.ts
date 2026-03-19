// Minimal type definition for a key-value namespace
export interface KVNamespace {
    get(key: string): Promise<string | null>;
    put(key: string, value: string, options?: { expiration?: number; expirationTtl?: number }): Promise<void>;
    delete(key: string): Promise<void>;
    list(options?: { prefix?: string }): Promise<{ keys: { name: string }[] }>;
}

/**
 * In-memory KV namespace. Used as the default shim on platforms that don't
 * provide a real KV binding (e.g. Vercel). Data lives only for the lifetime
 * of the isolate instance.
 */
export function createMemoryKV(): KVNamespace {
    const store = new Map<string, string>();
    return {
        async get(key) { return store.get(key) ?? null; },
        async put(key, value) { store.set(key, value); },
        async delete(key) { store.delete(key); },
        async list(options) {
            const keys = [...store.keys()]
                .filter(k => !options?.prefix || k.startsWith(options.prefix))
                .map(name => ({ name }));
            return { keys };
        },
    };
}

/**
 * Create a `__zx_kv` import object for use with `run({ kv: ... })`.
 * Always returns a valid import object. When JSPI is unavailable all KV
 * operations are stubbed (get → not-found, put/delete → success, list → []).
 */
export function createKVImports(
    bindings: Record<string, KVNamespace>,
    getMemory: () => WebAssembly.Memory,
): Record<string, unknown> {
    const encoder = new TextEncoder();
    const decoder = new TextDecoder();

    function readStr(ptr: number, len: number): string {
        return decoder.decode(new Uint8Array(getMemory().buffer, ptr, len));
    }

    function writeBytes(buf_ptr: number, buf_max: number, data: Uint8Array): number {
        if (data.length > buf_max) return -2;
        new Uint8Array(getMemory().buffer, buf_ptr, data.length).set(data);
        return data.length;
    }

    function binding(ns: string): KVNamespace | null {
        return bindings[ns] ?? bindings["default"] ?? null;
    }

    const Suspending = (WebAssembly as any).Suspending;
    if (typeof Suspending !== 'function') {
        // No JSPI: KV cannot be async. Stub all operations with sync no-ops.
        return {
            kv_get: (_ns: number, _nsLen: number, _key: number, _keyLen: number, _buf: number, _max: number): number => -1,
            kv_put: (_ns: number, _nsLen: number, _key: number, _keyLen: number, _val: number, _valLen: number): number => 0,
            kv_delete: (_ns: number, _nsLen: number, _key: number, _keyLen: number): number => 0,
            kv_list: (_ns: number, _nsLen: number, _pfx: number, _pfxLen: number, buf_ptr: number, buf_max: number): number =>
                writeBytes(buf_ptr, buf_max, encoder.encode("[]")),
        };
    }

    return {
        kv_get: new Suspending(async (
            ns_ptr: number, ns_len: number,
            key_ptr: number, key_len: number,
            buf_ptr: number, buf_max: number,
        ): Promise<number> => {
            const b = binding(readStr(ns_ptr, ns_len));
            if (!b) return -1;
            const value = await b.get(readStr(key_ptr, key_len));
            if (value === null) return -1;
            return writeBytes(buf_ptr, buf_max, encoder.encode(value));
        }),

        kv_put: new Suspending(async (
            ns_ptr: number, ns_len: number,
            key_ptr: number, key_len: number,
            val_ptr: number, val_len: number,
        ): Promise<number> => {
            const b = binding(readStr(ns_ptr, ns_len));
            if (!b) return -1;
            await b.put(readStr(key_ptr, key_len), readStr(val_ptr, val_len));
            return 0;
        }),

        kv_delete: new Suspending(async (
            ns_ptr: number, ns_len: number,
            key_ptr: number, key_len: number,
        ): Promise<number> => {
            const b = binding(readStr(ns_ptr, ns_len));
            if (!b) return -1;
            await b.delete(readStr(key_ptr, key_len));
            return 0;
        }),

        kv_list: new Suspending(async (
            ns_ptr: number, ns_len: number,
            prefix_ptr: number, prefix_len: number,
            buf_ptr: number, buf_max: number,
        ): Promise<number> => {
            const b = binding(readStr(ns_ptr, ns_len));
            if (!b) return writeBytes(buf_ptr, buf_max, encoder.encode("[]"));
            const prefix = readStr(prefix_ptr, prefix_len);
            const result = await b.list(prefix.length > 0 ? { prefix } : undefined);
            return writeBytes(buf_ptr, buf_max, encoder.encode(JSON.stringify(result.keys.map((k) => k.name))));
        }),
    };
}
