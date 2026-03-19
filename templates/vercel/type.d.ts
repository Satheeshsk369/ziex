declare module "*.wasm?module" {
    /** Compiled Ziex WASI Binary */
    const module: WebAssembly.Module;
    export default module;
}

