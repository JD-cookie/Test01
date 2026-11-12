import type { ConfigContext, ExpoConfig } from 'expo/config';

/**
 * Build-time configuration per environment. app.json holds the shared, static values;
 * this file layers the per-variant ones on top. See docs/devops.md.
 *
 * Inputs (environment variables, read when the app is bundled or built):
 *   APP_VARIANT  development | staging | production   (default: development)
 *   API_URL      backend base URL, e.g. http://10.0.0.78:4000 or https://api.example.com.
 *                Optional for development (falls back to the bundle host, port 3000);
 *                required for staging and production builds.
 */
type Variant = 'development' | 'staging' | 'production';

const VARIANTS: Record<Variant, { nameSuffix: string; idSuffix: string }> = {
  development: { nameSuffix: ' (Dev)', idSuffix: '.dev' },
  staging: { nameSuffix: ' (Staging)', idSuffix: '.staging' },
  production: { nameSuffix: '', idSuffix: '' },
};

export default ({ config }: ConfigContext): ExpoConfig => {
  const variant = (process.env.APP_VARIANT ?? 'development') as Variant;
  if (!(variant in VARIANTS)) {
    throw new Error(`APP_VARIANT must be one of ${Object.keys(VARIANTS).join(', ')}; got "${variant}"`);
  }
  const apiUrl = process.env.API_URL?.trim().replace(/\/+$/, '') || undefined;
  if (!apiUrl && variant !== 'development') {
    throw new Error(`API_URL must be set for ${variant} builds (see docs/devops.md)`);
  }
  if (apiUrl && variant === 'production' && !apiUrl.startsWith('https://')) {
    throw new Error('Production builds must use an https:// API_URL');
  }

  const { nameSuffix, idSuffix } = VARIANTS[variant];
  const baseId = config.android?.package ?? 'com.test01.app';
  const appId = baseId + idSuffix;
  // Android 9+ blocks plain-HTTP requests in release builds unless this is enabled.
  const allowHttp = variant !== 'production';

  return {
    ...config,
    name: `${config.name ?? 'Test01'}${nameSuffix}`,
    slug: config.slug ?? 'test01',
    scheme: `${config.scheme ?? 'test01'}${idSuffix.replace('.', '-')}`,
    ios: { ...config.ios, bundleIdentifier: appId },
    android: { ...config.android, package: appId },
    plugins: [
      ...(config.plugins ?? []),
      ['expo-build-properties', { android: { usesCleartextTraffic: allowHttp } }],
    ],
    extra: { ...config.extra, variant, apiUrl },
  };
};
