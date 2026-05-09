export type Locale = 'zh-CN' | 'en-US';

export type TranslationValues = Record<string, string | number>;

export type Messages = Record<string, string>;

export interface I18nContextValue {
  locale: Locale;
  setLocale: (locale: Locale) => void;
  t: (key: string, values?: TranslationValues) => string;
}
