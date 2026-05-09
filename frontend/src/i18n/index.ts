import { enUSMessages } from './messages/en-US';
import { zhCNMessages } from './messages/zh-CN';
import type { Locale, Messages, TranslationValues } from './types';

export const DEFAULT_LOCALE: Locale = 'zh-CN';

export const SUPPORTED_LOCALES: Locale[] = ['zh-CN', 'en-US'];

export const LOCALE_STORAGE_KEY = 'app.locale';

export const messages: Record<Locale, Messages> = {
  'zh-CN': zhCNMessages,
  'en-US': enUSMessages,
};

export const normalizeLocale = (value?: string | null): Locale => {
  if (!value) {
    return DEFAULT_LOCALE;
  }

  const normalized = value.toLowerCase();
  if (normalized.startsWith('zh')) {
    return 'zh-CN';
  }
  if (normalized.startsWith('en')) {
    return 'en-US';
  }
  return DEFAULT_LOCALE;
};

export const interpolate = (template: string, values?: TranslationValues): string => {
  if (!values) {
    return template;
  }

  return template.replace(/\{(\w+)\}/g, (_, key: string) => {
    const value = values[key];
    return value === undefined ? `{${key}}` : String(value);
  });
};
