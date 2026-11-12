import { useState } from 'react';
import { Text } from 'react-native';
import { Button, Screen, Title } from '@/components/ui';
import { useSession } from '@/session';
import { colors } from '@/theme';

export default function HomeScreen() {
  const { user, logout } = useSession();
  const [busy, setBusy] = useState(false);
  return (
    <Screen>
      <Title subtitle={user?.email}>{`Hi, ${user?.displayName ?? 'there'}!`}</Title>
      <Text style={{ color: colors.muted, fontSize: 16, marginBottom: 24 }}>{"You're logged in."}</Text>
      <Button
        title="Log out"
        busy={busy}
        onPress={async () => {
          setBusy(true);
          await logout();
        }}
      />
    </Screen>
  );
}
