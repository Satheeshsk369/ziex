// Minimal type definitions for Cloudflare KV (subset of @cloudflare/workers-types)
export interface KVNamespace {
    get(key: string): Promise<string | null>;
    put(key: string, value: string, options?: { expiration?: number; expirationTtl?: number }): Promise<void>;
    delete(key: string): Promise<void>;
    list(options?: { prefix?: string }): Promise<{ keys: { name: string }[] }>;
}

/**
 * Create a `__zx_kv` import object for use with `worker.run({ kv: ... })`.
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

    const Suspending = (WebAssembly as unknown as { Suspending: new (fn: Function) => unknown }).Suspending;

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
