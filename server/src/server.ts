import { buildApp } from './app.ts';

const port = Number(process.env.PORT ?? 3000);
const host = process.env.HOST ?? '0.0.0.0'; // 0.0.0.0 so a phone on the LAN can reach it
const dbPath = process.env.DB_PATH ?? new URL('../data/test01.db', import.meta.url).pathname;

const minAppVersion = process.env.MIN_APP_VERSION ?? '0.0.0';

const app = buildApp({ dbPath, minAppVersion, logger: true });
await app.listen({ port, host });
