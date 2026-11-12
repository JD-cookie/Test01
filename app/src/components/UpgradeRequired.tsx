import { Text } from 'react-native';
import { Screen, Title } from './ui';
import { appVersion } from '@/api';
import { colors } from '@/theme';

/** Shown in place of every screen once the server rejects this app version. */
export function UpgradeRequired() {
  return (
    <Screen>
      <Title subtitle={`You have version ${appVersion}.`}>Update required</Title>
      <Text style={{ color: colors.muted, fontSize: 16 }}>
        This version of the app is no longer supported. Please install the latest version, then
        open the app again. You will not need to log in again.
      </Text>
    </Screen>
  );
}
