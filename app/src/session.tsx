import { createContext, use, useCallback, useEffect, useState, type ReactNode } from 'react';
import * as SecureStore from 'expo-secure-store';
import { api, ApiError, onUpgradeRequired, type User } from './api';

const TOKEN_KEY = 'test01.session.token';
const USER_KEY = 'test01.session.user';

type SessionState = {
  /** True until the stored session (if any) has been loaded at startup. */
  isLoading: boolean;
  /** Set once the server reports this app version is no longer supported. */
  upgradeRequired: boolean;
  token: string | null;
  user: User | null;
  login: (email: string, password: string) => Promise<void>;
  signup: (displayName: string, email: string, password: string) => Promise<void>;
  logout: () => Promise<void>;
};

const SessionContext = createContext<SessionState | null>(null);

export function useSession(): SessionState {
  const value = use(SessionContext);
  if (!value) throw new Error('useSession must be used inside <SessionProvider>');
  return value;
}

async function persist(token: string | null, user: User | null) {
  if (token && user) {
    await SecureStore.setItemAsync(TOKEN_KEY, token);
    await SecureStore.setItemAsync(USER_KEY, JSON.stringify(user));
  } else {
    await SecureStore.deleteItemAsync(TOKEN_KEY);
    await SecureStore.deleteItemAsync(USER_KEY);
  }
}

export function SessionProvider({ children }: { children: ReactNode }) {
  const [isLoading, setLoading] = useState(true);
  const [token, setToken] = useState<string | null>(null);
  const [user, setUser] = useState<User | null>(null);
  const [upgradeRequired, setUpgradeRequired] = useState(false);

  useEffect(() => {
    onUpgradeRequired(() => setUpgradeRequired(true));
    return () => onUpgradeRequired(undefined);
  }, []);

  const apply = useCallback(async (t: string | null, u: User | null) => {
    await persist(t, u);
    setToken(t);
    setUser(u);
  }, []);

  // Startup: restore the saved session, then confirm it with the server.
  useEffect(() => {
    (async () => {
      try {
        const t = await SecureStore.getItemAsync(TOKEN_KEY);
        const raw = await SecureStore.getItemAsync(USER_KEY);
        if (!t || !raw) return;
        setToken(t);
        setUser(JSON.parse(raw) as User);
        try {
          const { user: fresh } = await api.me(t);
          await apply(t, fresh);
        } catch (err) {
          // Server rejected the session: forget it. Offline: keep the cached user.
          if (err instanceof ApiError && err.status === 401) await apply(null, null);
        }
      } catch {
        await apply(null, null); // Unreadable storage: start logged out.
      } finally {
        setLoading(false);
      }
    })();
  }, [apply]);

  const login = useCallback(
    async (email: string, password: string) => {
      const r = await api.login(email, password);
      await apply(r.token, r.user);
    },
    [apply],
  );

  const signup = useCallback(
    async (displayName: string, email: string, password: string) => {
      const r = await api.signup(displayName, email, password);
      await apply(r.token, r.user);
    },
    [apply],
  );

  const logout = useCallback(async () => {
    const t = token;
    await apply(null, null);
    // Best effort: the local session is gone even if the server can't be reached.
    if (t) api.logout(t).catch(() => {});
  }, [apply, token]);

  return (
    <SessionContext value={{ isLoading, upgradeRequired, token, user, login, signup, logout }}>
      {children}
    </SessionContext>
  );
}
