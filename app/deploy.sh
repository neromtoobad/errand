#!/usr/bin/env bash
# Builds the page and uploads the static files to Vercel (project "errand", errand.nerom.site).
# Built locally because the page reads ../deployments/*.json from the repo.
set -euo pipefail
cd "$(dirname "$0")"
npm run build
printf '{ "framework": null, "buildCommand": "", "outputDirectory": "." }\n' > dist/vercel.json
cp -r .vercel dist/ 2>/dev/null || true
npx -y vercel@latest deploy dist --prod --yes --scope moren808s-projects
