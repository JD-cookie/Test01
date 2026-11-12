import { useState } from 'react';
import { useRouter } from 'expo-router';
import { Button, ErrorBanner, Field, Screen, Title } from '@/components/ui';
import { useSession } from '@/session';
import { ApiError } from '@/api';

export default function LoginScreen() {
  const { login } = useSession();
  const router = useRouter();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function submit() {
    if (busy) return;
    if (!email.trim() || !password) {
      setError('Enter your email and password.');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await login(email, password); // On success the navigator switches to the home screen.
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Something went wrong. Please try again.');
      setBusy(false);
    }
  }

  return (
    <Screen>
      <Title subtitle="Welcome back. Log in to continue.">Test01</Title>
      <ErrorBanner message={error} />
      <Field
        label="Email"
        value={email}
        onChangeText={setEmail}
        placeholder="you@example.com"
        autoCapitalize="none"
        autoComplete="email"
        keyboardType="email-address"
        textContentType="emailAddress"
        returnKeyType="next"
      />
      <Field
        label="Password"
        value={password}
        onChangeText={setPassword}
        secureTextEntry
        autoComplete="current-password"
        textContentType="password"
        returnKeyType="go"
        onSubmitEditing={submit}
      />
      <Button title="Log in" onPress={submit} busy={busy} />
      <Button variant="link" title="New here? Create an account" onPress={() => router.replace('/signup')} />
    </Screen>
  );
}
