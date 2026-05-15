import { defineConfig } from "vite";

// Served from https://ezmesh.github.io/ezos/console/.
// Output goes into the docs/ tree so the existing Pages deploy picks it
// up alongside the manual and API reference (see .github/workflows/docs.yml).
export default defineConfig({
    base: "/ezos/console/",
    build: {
        outDir: "../docs/console",
        emptyOutDir: true,
        target: "es2022",
    },
    server: {
        port: 5173,
    },
});
