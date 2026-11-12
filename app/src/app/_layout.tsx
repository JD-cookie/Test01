import { SplashScreen, Stack } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { SessionProvider, useSession } from '@/session';
import { UpgradeRequired } from '@/components/UpgradeRequired';

SplashScreen.preventAutoHideAsync();

export default function RootLayout() {
  return (
    <SessionProvider>
      <RootNavigator />
      <StatusBar style="dark" />
    </SessionProvider>
  );
}

function RootNavigator() {
  const { isLoading, upgradeRequired, token } = useSession();
  if (isLoading) return null; // Splash stays up while the saved session is restored.
  SplashScreen.hide();
  if (upgradeRequired) return <UpgradeRequired />;
  const signedIn = !!token;
  return (
    <Stack screenOptions={{ headerShown: false }}>
      <Stack.Protected guard={signedIn}>
        <Stack.Screen name="(app)" />
      </Stack.Protected>
      <Stack.Protected guard={!signedIn}>
        <Stack.Screen name="login" />
        <Stack.Screen name="signup" />
      </Stack.Protected>
    </Stack>
  );
}
