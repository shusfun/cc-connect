import { createContext, useCallback, useContext, useMemo, useState, type ReactNode } from 'react';

interface RefreshContextValue {
  generation: number;
  refresh: () => void;
}

const RefreshContext = createContext<RefreshContextValue>({ generation: 0, refresh: () => undefined });

export function RefreshProvider({ children }: { children: ReactNode }) {
  const [generation, setGeneration] = useState(0);
  const refresh = useCallback(() => setGeneration((value) => value + 1), []);
  const value = useMemo(() => ({ generation, refresh }), [generation, refresh]);
  return <RefreshContext.Provider value={value}>{children}</RefreshContext.Provider>;
}

export function useRefresh(): RefreshContextValue {
  return useContext(RefreshContext);
}
