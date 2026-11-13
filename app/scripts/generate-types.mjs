// Writes the TypeScript files that `expo start` normally generates: `expo-env.d.ts` and
// Expo Router's typed routes in `.expo/types/router.d.ts`, built from the route files in
// `src/app`. Both are git-ignored, so a fresh clone or the pre-commit snapshot has neither,
// and a copy from elsewhere could describe routes that aren't there any more. Running this
// before `tsc` makes the typecheck match the files actually being checked.
//
// It calls the same function `expo start` uses. That's an internal @expo/cli module, so an
// Expo upgrade may move it. If so, this fails loudly rather than skipping the generation.
import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(resolve(projectRoot, 'package.json'));
const { startTypescriptTypeGenerationAsync } = require(
  '@expo/cli/build/src/start/server/type-generation/startTypescriptTypeGeneration',
);

// Without Metro or a dev server, this generates the files once and doesn't watch.
await startTypescriptTypeGenerationAsync({ projectRoot, metro: null, server: null });
