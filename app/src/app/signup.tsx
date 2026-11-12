import { useState } from 'react';
import { useRouter } from 'expo-router';
import { Button, ErrorBanner, Field, Screen, Title } from '@/components/ui';
import { useSession } from '@/session';
import { ApiError } from '@/api';

type Fields = 'displayName' | 'email' | 'password' | 'confirm';
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/** Same rules as the server, checked first so the user gets instant feedback. */
function validate(v: Record<Fields, string>): Partial<Record<Fields, string>> {
  const e: Partial<Record<Fields, string>> = {};
  const name = v.displayName.trim();
  if (!name) e.displayName = 'Name is required.';
  else if (name.length > 50) e.displayName = 'Name must be at most 50 characters.';
  const email = v.email.trim();
  if (!email) e.email = 'Email is required.';
  else if (email.length > 254 || !EMAIL_RE.test(email)) e.email = 'Enter a valid email address.';
  if (v.password.length < 8) e.password = 'Password must be at least 8 characters.';
  else if (v.password.length > 128) e.password = 'Password must be at most 128 characters.';
  if (v.confirm !== v.password) e.confirm = 'Passwords do not match.';
  return e;
}

export default function SignupScreen() {
  const { signup } = useSession();
  const router = useRouter();
  const [values, setValues] = useState<Record<Fields, string>>({
    displayName: '',
    email: '',
    password: '',
    confirm: '',
  });
  const [errors, setErrors] = useState<Partial<Record<Fields, string>>>({});
  const [banner, setBanner] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const set = (k: Fields) => (text: string) => {
    setValues((v) => ({ ...v, [k]: text }));
    setErrors((e) => ({ ...e, [k]: undefined }));
  };

  async function submit() {
    if (busy) return;
    const found = validate(values);
    setErrors(found);
    setBanner(null);
    if (Object.keys(found).length) return;
    setBusy(true);
    try {
      await signup(values.displayName, values.email, values.password);
    } catch (err) {
      if (err instanceof ApiError && err.field) setErrors({ [err.field]: err.message });
      else setBanner(err instanceof ApiError ? err.message : 'Something went wrong. Please try again.');
      setBusy(false);
    }
  }

  return (
    <Screen>
      <Title subtitle="Create your account.">Join Test01</Title>
      <ErrorBanner message={banner} />
      <Field label="Name" value={values.displayName} onChangeText={set('displayName')} error={errors.displayName}
        autoComplete="name" textContentType="name" maxLength={50} />
      <Field label="Email" value={values.email} onChangeText={set('email')} error={errors.email}
        placeholder="you@example.com" autoCapitalize="none" autoComplete="email" keyboardType="email-address"
        textContentType="emailAddress" />
      <Field label="Password" value={values.password} onChangeText={set('password')} error={errors.password}
        secureTextEntry autoComplete="new-password" textContentType="newPassword" placeholder="At least 8 characters" />
      <Field label="Confirm password" value={values.confirm} onChangeText={set('confirm')} error={errors.confirm}
        secureTextEntry autoComplete="new-password" textContentType="newPassword" returnKeyType="go"
        onSubmitEditing={submit} />
      <Button title="Create account" onPress={submit} busy={busy} />
      <Button variant="link" title="Already have an account? Log in" onPress={() => router.replace('/login')} />
    </Screen>
  );
}
