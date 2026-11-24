import { defineConfig } from "vite";

// The page imports ../deployments/*.json from the repo, so let the dev server read the parent folder.
export default defineConfig({ server: { fs: { allow: [".."] } } });
