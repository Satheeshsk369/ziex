import { Ziex } from "ziex";
import module from "../zig-out/bin/ziex_dev.wasm";

export default new Ziex<Env>({ module, kv: "KV" });
