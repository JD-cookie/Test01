import type { ReactNode } from 'react';
import {
  ActivityIndicator,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
  type TextInputProps,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { colors, radius, space } from '../theme';
import { apiBaseUrl, appVariant, appVersion } from '../api';

export function Screen({ children }: { children: ReactNode }) {
  return (
    <SafeAreaView style={styles.safe}>
      <KeyboardAvoidingView style={styles.flex} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
        <ScrollView contentContainerStyle={styles.scroll} keyboardShouldPersistTaps="handled">
          {children}
          {appVariant !== 'production' ? (
            // Non-production builds show which build and server they are using.
            <Text style={styles.envInfo}>{`${appVariant} · v${appVersion} · ${apiBaseUrl()}`}</Text>
          ) : null}
        </ScrollView>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

export function Title({ children, subtitle }: { children: ReactNode; subtitle?: string }) {
  return (
    <View style={{ marginBottom: space.lg }}>
      <Text style={styles.title}>{children}</Text>
      {subtitle ? <Text style={styles.subtitle}>{subtitle}</Text> : null}
    </View>
  );
}

export function Field({ label, error, ...input }: TextInputProps & { label: string; error?: string }) {
  return (
    <View style={{ marginBottom: space.md }}>
      <Text style={styles.label}>{label}</Text>
      <TextInput
        placeholderTextColor={colors.muted}
        style={[styles.input, error ? styles.inputError : null]}
        {...input}
      />
      {error ? <Text style={styles.fieldError}>{error}</Text> : null}
    </View>
  );
}

export function Button({
  title,
  onPress,
  busy,
  variant = 'primary',
}: {
  title: string;
  onPress: () => void;
  busy?: boolean;
  variant?: 'primary' | 'link';
}) {
  if (variant === 'link') {
    return (
      <Pressable onPress={onPress} disabled={busy} style={styles.link} accessibilityRole="button">
        <Text style={styles.linkText}>{title}</Text>
      </Pressable>
    );
  }
  return (
    <Pressable
      onPress={onPress}
      disabled={busy}
      accessibilityRole="button"
      style={({ pressed }) => [styles.button, (pressed || busy) && { opacity: 0.7 }]}
    >
      {busy ? <ActivityIndicator color={colors.primaryText} /> : <Text style={styles.buttonText}>{title}</Text>}
    </Pressable>
  );
}

export function ErrorBanner({ message }: { message?: string | null }) {
  if (!message) return null;
  return (
    <View style={styles.banner} accessibilityRole="alert">
      <Text style={styles.bannerText}>{message}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  safe: { flex: 1, backgroundColor: colors.background },
  flex: { flex: 1 },
  scroll: { flexGrow: 1, justifyContent: 'center', padding: space.lg },
  title: { fontSize: 32, fontWeight: '800', color: colors.text },
  subtitle: { fontSize: 16, color: colors.muted, marginTop: space.xs },
  label: { fontSize: 14, fontWeight: '600', color: colors.text, marginBottom: space.xs },
  input: {
    backgroundColor: colors.surface,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: radius,
    paddingHorizontal: space.md,
    paddingVertical: 12,
    fontSize: 16,
    color: colors.text,
  },
  inputError: { borderColor: colors.error },
  fieldError: { color: colors.error, fontSize: 13, marginTop: space.xs },
  button: {
    backgroundColor: colors.primary,
    borderRadius: radius,
    paddingVertical: 14,
    alignItems: 'center',
    marginTop: space.sm,
    minHeight: 50,
    justifyContent: 'center',
  },
  buttonText: { color: colors.primaryText, fontSize: 16, fontWeight: '700' },
  link: { paddingVertical: space.md, alignItems: 'center' },
  linkText: { color: colors.primary, fontSize: 15, fontWeight: '600' },
  banner: { backgroundColor: colors.errorBg, borderRadius: radius, padding: space.md, marginBottom: space.md },
  bannerText: { color: colors.error, fontSize: 14 },
  envInfo: { color: colors.muted, fontSize: 12, textAlign: 'center', marginTop: space.xl },
});
