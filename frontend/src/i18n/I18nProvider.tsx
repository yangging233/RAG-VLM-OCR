import { createContext, useCallback, useEffect, useMemo, useState, type ReactNode } from 'react';
import { DEFAULT_LOCALE, LOCALE_STORAGE_KEY, interpolate, messages, normalizeLocale } from './index';
import type { I18nContextValue, Locale, TranslationValues } from './types';

export const I18nContext = createContext<I18nContextValue | undefined>(undefined);

const resolveInitialLocale = (): Locale => {
  if (typeof window === 'undefined') {
    return DEFAULT_LOCALE;
  }

  const storedLocale = window.localStorage.getItem(LOCALE_STORAGE_KEY);
  if (storedLocale) {
    return normalizeLocale(storedLocale);
  }

  return normalizeLocale(window.navigator.language);
};

interface I18nProviderProps {
  children: ReactNode;
}

export function I18nProvider({ children }: I18nProviderProps) {
  const [locale, setLocale] = useState<Locale>(resolveInitialLocale);

  useEffect(() => {
    if (typeof window !== 'undefined') {
      window.localStorage.setItem(LOCALE_STORAGE_KEY, locale);
    }
    document.documentElement.lang = locale;
  }, [locale]);

  const t = useCallback((key: string, values?: TranslationValues) => {
    const template = messages[locale][key] ?? messages[DEFAULT_LOCALE][key] ?? key;
    return interpolate(template, values);
  }, [locale]);

  const value = useMemo<I18nContextValue>(() => ({
    locale,
    setLocale,
    t,
  }), [locale, t]);

  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}
