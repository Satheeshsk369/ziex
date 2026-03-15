import { worker } from "ziex/cloudflare";
// @ts-ignore
import module from "../zig-out/bin/zx_bench_client.wasm";

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext) {
    return worker.run({
      request,
      env,
      ctx,
      module,
      kv: { default: env.KV }
    });
  },
} satisfies ExportedHandler<Env>;
