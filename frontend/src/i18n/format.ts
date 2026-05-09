import type { Locale } from './types';

const getDateLocale = (locale: Locale) => locale === 'zh-CN' ? 'zh-CN' : 'en-US';

export const formatTime = (value: string | Date, locale: Locale): string => {
  const date = value instanceof Date ? value : new Date(value);
  return date.toLocaleTimeString(getDateLocale(locale), {
    hour: '2-digit',
    minute: '2-digit',
  });
};

export const formatDate = (value: string | Date, locale: Locale): string => {
  const date = value instanceof Date ? value : new Date(value);
  return date.toLocaleDateString(getDateLocale(locale), {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  });
};

export const formatDateTime = (value: string | Date, locale: Locale): string => {
  const date = value instanceof Date ? value : new Date(value);
  return date.toLocaleString(getDateLocale(locale), {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  });
};

export const formatShortDateTime = (value: string | Date, locale: Locale): string => {
  const date = value instanceof Date ? value : new Date(value);
  return date.toLocaleString(getDateLocale(locale), {
    month: 'numeric',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
};

export const formatRelativeTime = (value: string | Date | null, locale: Locale): string => {
  if (!value) {
    return locale === 'zh-CN' ? '未知' : 'Unknown';
  }

  const date = value instanceof Date ? value : new Date(value);
  const now = Date.now();
  const diff = now - date.getTime();
  const minute = 60 * 1000;
  const hour = 60 * minute;
  const day = 24 * hour;

  if (diff < minute) {
    return locale === 'zh-CN' ? '刚刚' : 'just now';
  }

  if (diff < hour) {
    const minutes = Math.floor(diff / minute);
    return locale === 'zh-CN' ? `${minutes}分钟前` : `${minutes} min ago`;
  }

  if (diff < day) {
    const hours = Math.floor(diff / hour);
    return locale === 'zh-CN' ? `${hours}小时前` : `${hours} hr ago`;
  }

  if (diff < 7 * day) {
    const days = Math.floor(diff / day);
    return locale === 'zh-CN' ? `${days}天前` : `${days} days ago`;
  }

  return formatDateTime(date, locale);
};
