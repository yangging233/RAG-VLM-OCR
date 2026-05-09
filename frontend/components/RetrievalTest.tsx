import { Database, Eye, FileText, Loader2, MessageSquareText, Search } from 'lucide-react';
import { useEffect, useState } from 'react';
import { motion } from 'motion/react';
import { toast } from 'sonner';
import { Slider } from './ui/slider';
import { config } from '../src/config';
import { formatShortDateTime } from '../src/i18n/format';
import { useI18n } from '../src/i18n/useI18n';
import { matchesPipelineMode, type PipelineType } from '../src/api/config';

type SearchScope = 'all' | 'documents' | 'conversations';

interface RetrievalTestProps {
  onOpenChatSession: (sessionId: string) => void;
  onOpenDocument: (collectionId: string, fileId: string) => void;
  isV2?: boolean;
}

interface KnowledgeBase {
  collection_id: string;
  display_name: string;
  created_at: string;
  pipeline_type?: PipelineType;
}

interface ChatMessage {
  id: string;
  role: 'user' | 'assistant';
  content: string;
  timestamp: string;
}

interface ChatSession {
  id: string;
  title: string;
  messages: ChatMessage[];
  knowledgeBaseId: string;
  knowledgeBaseName: string;
  pipelineType?: PipelineType;
  createdAt: string;
  updatedAt: string;
}

interface ConversationSearchResult {
  sessionId: string;
  title: string;
  knowledgeBaseId: string;
  knowledgeBaseName: string;
  updatedAt: string;
  snippet: string;
  matchedKeywords: string[];
  matchedCount: number;
  messageRole: 'user' | 'assistant';
  score: number;
}

interface DocumentSearchResult {
  collection_id: string;
  collection_name: string;
  filename: string;
  file_id: string;
  chunk_text: string;
  snippet: string;
  score: number;
  match_type: 'content' | 'filename' | 'both';
  matched_keywords: string[];
  metadata: Record<string, any>;
  created_at: string;
}

interface KeywordMatch {
  score: number;
  matchedKeywords: string[];
  snippet: string;
}

const CHAT_SESSION_STORAGE_KEY = 'chat_sessions';

const normalizeKeywords = (queryText: string): string[] => {
  const normalizedQuery = queryText.trim().toLowerCase();
  if (!normalizedQuery) return [];

  const keywords = [normalizedQuery];
  const splitTerms = normalizedQuery.split(/[\s,，。！？；;、/|]+/);

  splitTerms.forEach((term) => {
    const cleaned = term.trim();
    if (cleaned && !keywords.includes(cleaned)) {
      keywords.push(cleaned);
    }
  });

  return keywords.slice(0, 10);
};

const buildSnippet = (content: string, keywords: string[], maxLength = 180): string => {
  const normalizedContent = content.replace(/\s+/g, ' ').trim();
  if (!normalizedContent) return '';

  const lowerContent = normalizedContent.toLowerCase();
  const positions = keywords
    .map((keyword) => lowerContent.indexOf(keyword))
    .filter((index) => index >= 0);

  const start = positions.length > 0 ? Math.max(Math.min(...positions) - 36, 0) : 0;
  const end = Math.min(start + maxLength, normalizedContent.length);

  let snippet = normalizedContent.slice(start, end);
  if (start > 0) snippet = `...${snippet}`;
  if (end < normalizedContent.length) snippet = `${snippet}...`;

  return snippet;
};

const scoreKeywordMatch = (queryText: string, primaryText: string, secondaryText = ''): KeywordMatch | null => {
  const normalizedQuery = queryText.trim().toLowerCase();
  if (!normalizedQuery) return null;

  const keywords = normalizeKeywords(queryText);
  const primary = primaryText || '';
  const secondary = secondaryText || '';
  const primaryLower = primary.toLowerCase();
  const secondaryLower = secondary.toLowerCase();

  const matchedKeywords: string[] = [];
  let score = 0;

  keywords.forEach((keyword) => {
    const matchedPrimary = primaryLower.includes(keyword);
    const matchedSecondary = secondaryLower.includes(keyword);

    if (!matchedPrimary && !matchedSecondary) return;

    if (!matchedKeywords.includes(keyword)) {
      matchedKeywords.push(keyword);
    }

    score += matchedPrimary ? 12 : 0;
    score += matchedSecondary ? 6 : 0;
  });

  if (primaryLower.includes(normalizedQuery)) {
    score += 30;
  }
  if (secondaryLower.includes(normalizedQuery)) {
    score += 16;
  }

  if (matchedKeywords.length === 0 && score === 0) {
    return null;
  }

  const snippetSource = primary.trim() || secondary.trim();

  return {
    score,
    matchedKeywords,
    snippet: buildSnippet(snippetSource, matchedKeywords.length > 0 ? matchedKeywords : [normalizedQuery]),
  };
};

const escapeRegExp = (value: string): string => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

export function RetrievalTest({ onOpenChatSession, onOpenDocument, isV2 = false }: RetrievalTestProps) {
  const { locale, t } = useI18n();
  const [query, setQuery] = useState('');
  const [topK, setTopK] = useState([10]);
  const [knowledgeBases, setKnowledgeBases] = useState<KnowledgeBase[]>([]);
  const [selectedKB, setSelectedKB] = useState('');
  const [searchScope, setSearchScope] = useState<SearchScope>('all');
  const [loading, setLoading] = useState(false);
  const [hasSearched, setHasSearched] = useState(false);
  const [searchDuration, setSearchDuration] = useState(0);
  const [documentResults, setDocumentResults] = useState<DocumentSearchResult[]>([]);
  const [conversationResults, setConversationResults] = useState<ConversationSearchResult[]>([]);

  useEffect(() => {
    const fetchKnowledgeBases = async () => {
      try {
        const response = await fetch(`${config.milvusApiUrl}/knowledge_base/list`);
        const result = await response.json();

        if (result.status === 'success') {
          const filteredKnowledgeBases = (result.knowledge_bases || []).filter((kb: KnowledgeBase) =>
            matchesPipelineMode(kb.pipeline_type, isV2)
          );
          setKnowledgeBases(filteredKnowledgeBases);
        }
      } catch (error) {
        console.error('获取知识库列表失败:', error);
        toast.error(t('retrieval.loadKnowledgeBasesFailed'));
      }
    };

    fetchKnowledgeBases();
  }, [isV2]);

  const renderHighlightedText = (text: string, keywords: string[]) => {
    const uniqueKeywords = Array.from(new Set(keywords.filter(Boolean)));
    if (!text || uniqueKeywords.length === 0) {
      return text;
    }

    const regex = new RegExp(`(${uniqueKeywords.map(escapeRegExp).join('|')})`, 'gi');
    const segments = text.split(regex);
    const loweredKeywords = uniqueKeywords.map((keyword) => keyword.toLowerCase());

    return (
      <>
        {segments.map((segment, index) => {
          const isKeyword = loweredKeywords.includes(segment.toLowerCase());
          return isKeyword ? (
            <mark
              key={`${segment}-${index}`}
              className="bg-[rgba(0,212,255,0.25)] text-[#00d4ff] px-1 rounded"
            >
              {segment}
            </mark>
          ) : (
            <span key={`${segment}-${index}`}>{segment}</span>
          );
        })}
      </>
    );
  };

  const getStoredSessions = (): ChatSession[] => {
    try {
      const raw = localStorage.getItem(CHAT_SESSION_STORAGE_KEY);
      if (!raw) return [];

      const parsed = JSON.parse(raw);
      return Array.isArray(parsed) ? parsed : [];
    } catch (error) {
      console.error('读取历史会话失败:', error);
      return [];
    }
  };

  const searchConversations = (queryText: string, limit: number): ConversationSearchResult[] => {
    const sessions = getStoredSessions();
    const results: ConversationSearchResult[] = [];

    sessions.forEach((session) => {
      if (!matchesPipelineMode(session.pipelineType, isV2)) {
        return;
      }

      if (selectedKB && session.knowledgeBaseId !== selectedKB) {
        return;
      }

      let bestMatch: ConversationSearchResult | null = null;
      let matchedCount = 0;

      const titleMatch = scoreKeywordMatch(queryText, session.title, session.knowledgeBaseName);
      if (titleMatch) {
        bestMatch = {
          sessionId: session.id,
          title: session.title,
          knowledgeBaseId: session.knowledgeBaseId,
          knowledgeBaseName: session.knowledgeBaseName,
          updatedAt: session.updatedAt,
          snippet: titleMatch.snippet,
          matchedKeywords: titleMatch.matchedKeywords,
          matchedCount: 0,
          messageRole: 'user',
          score: titleMatch.score,
        };
      }

      session.messages.forEach((message) => {
        const match = scoreKeywordMatch(queryText, message.content);
        if (!match) return;

        matchedCount += 1;
        const currentScore = match.score + (message.role === 'assistant' ? 1 : 0);

        if (!bestMatch || currentScore > bestMatch.score) {
          bestMatch = {
            sessionId: session.id,
            title: session.title,
            knowledgeBaseId: session.knowledgeBaseId,
            knowledgeBaseName: session.knowledgeBaseName,
            updatedAt: session.updatedAt,
            snippet: match.snippet,
            matchedKeywords: match.matchedKeywords,
            matchedCount,
            messageRole: message.role,
            score: currentScore,
          };
        }
      });

      if (bestMatch) {
        results.push({
          ...bestMatch,
          matchedCount: matchedCount || bestMatch.matchedCount,
        });
      }
    });

    results.sort((left, right) => {
      if (right.score !== left.score) {
        return right.score - left.score;
      }
      return new Date(right.updatedAt).getTime() - new Date(left.updatedAt).getTime();
    });

    return results.slice(0, limit);
  };

  const searchDocuments = async (queryText: string, limit: number): Promise<DocumentSearchResult[]> => {
    const response = await fetch(`${config.milvusApiUrl}/search_keyword`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        query_text: queryText,
        collection_name: selectedKB || null,
        top_k: limit,
      }),
    });

    if (!response.ok) {
      throw new Error(`HTTP error: ${response.status}`);
    }

    const result = await response.json();
    return result.results || [];
  };

  const handleSearch = async () => {
    const trimmedQuery = query.trim();
    if (!trimmedQuery) {
      toast.error(t('retrieval.inputQuery'));
      return;
    }

    setLoading(true);
    setHasSearched(true);

    const startTime = performance.now();

    try {
      const limit = topK[0];
      const nextConversationResults =
        searchScope === 'documents' ? [] : searchConversations(trimmedQuery, limit);
      const nextDocumentResults =
        searchScope === 'conversations' ? [] : await searchDocuments(trimmedQuery, limit);

      setConversationResults(nextConversationResults);
      setDocumentResults(nextDocumentResults);
      setSearchDuration((performance.now() - startTime) / 1000);
    } catch (error) {
      console.error('关键词检索失败:', error);
      setConversationResults([]);
      setDocumentResults([]);
      setSearchDuration((performance.now() - startTime) / 1000);
      toast.error(t('retrieval.searchFailed'));
    } finally {
      setLoading(false);
    }
  };

  const handleKeyPress = (event: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      handleSearch();
    }
  };

  const totalResults = conversationResults.length + documentResults.length;
  const scopeOptions: Array<{ id: SearchScope; label: string; desc: string; icon: string }> = [
    {
      id: 'all',
      label: t('retrieval.scope.all'),
      desc: t('retrieval.scope.allDesc'),
      icon: '⚡',
    },
    {
      id: 'documents',
      label: t('retrieval.scope.documents'),
      desc: t('retrieval.scope.documentsDesc'),
      icon: '📄',
    },
    {
      id: 'conversations',
      label: t('retrieval.scope.conversations'),
      desc: t('retrieval.scope.conversationsDesc'),
      icon: '💬',
    },
  ];

  return (
    <div className="space-y-6">
      <motion.div
        className="glass gradient-border rounded-2xl p-6 space-y-6"
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
      >
        <div className="flex items-start justify-between gap-6">
          <div>
            <div className="flex items-center gap-3 mb-2">
              <div className="w-11 h-11 rounded-xl bg-gradient-to-br from-[#00d4ff] to-[#0066ff] flex items-center justify-center shadow-lg">
                <Search size={20} className="text-[#0a0e27]" />
              </div>
              <div>
                <h3 className="text-[#e8eaed]">{t('retrieval.title')}</h3>
                <p className="text-[#94a3b8] text-sm">{t('retrieval.fastModeHint')}</p>
              </div>
            </div>
          </div>
          <span className="px-4 py-2 rounded-xl glass-strong border border-[rgba(0,212,255,0.2)] text-[#00d4ff] text-sm">
            {t('retrieval.fastModeTag')}
          </span>
        </div>

        <div className="flex gap-4">
          <div className="flex-1 relative">
            <textarea
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              onKeyDown={handleKeyPress}
              placeholder={t('retrieval.placeholder')}
              className="w-full min-h-[110px] px-5 py-4 glass-strong border border-[rgba(0,212,255,0.2)] rounded-xl focus:outline-none focus:ring-2 focus:ring-[#00d4ff] focus:border-[#00d4ff] resize-none text-[#e8eaed] placeholder-[#94a3b8] transition-all duration-300"
            />
          </div>
          <motion.button
            onClick={handleSearch}
            disabled={loading}
            className="w-44 h-12 bg-gradient-to-r from-[#00d4ff] to-[#0066ff] text-[#0a0e27] rounded-xl hover:shadow-[0_0_30px_rgba(0,212,255,0.6)] transition-all flex items-center justify-center gap-2 self-end relative overflow-hidden group disabled:opacity-60"
            whileHover={loading ? {} : { scale: 1.05 }}
            whileTap={loading ? {} : { scale: 0.95 }}
          >
            <div className="absolute inset-0 bg-gradient-to-r from-transparent via-white to-transparent opacity-0 group-hover:opacity-20 shimmer" />
            {loading ? <Loader2 size={20} className="animate-spin relative z-10" /> : <Search size={20} className="relative z-10" />}
            <span className="relative z-10">{loading ? t('retrieval.searching') : t('retrieval.search')}</span>
          </motion.button>
        </div>

        <div className="grid grid-cols-[1.2fr_1fr] gap-6">
          <div className="space-y-3">
            <label className="text-[#94a3b8]">{t('retrieval.knowledgeBaseFilter')}</label>
            <div className="relative">
              <select
                value={selectedKB}
                onChange={(event) => setSelectedKB(event.target.value)}
                className="w-full h-12 px-4 glass-strong border border-[rgba(0,212,255,0.2)] rounded-xl text-[#e8eaed] focus:outline-none focus:ring-2 focus:ring-[#00d4ff] appearance-none"
              >
                <option value="">{t('retrieval.allKnowledgeBases')}</option>
                {knowledgeBases.map((knowledgeBase) => (
                  <option key={knowledgeBase.collection_id} value={knowledgeBase.collection_id}>
                    {knowledgeBase.display_name}
                  </option>
                ))}
              </select>
            </div>
          </div>

          <div className="space-y-3">
            <div className="flex items-center justify-between">
              <label className="text-[#94a3b8]">Top K</label>
              <span className="text-[#00d4ff] px-3 py-1 rounded-lg bg-[rgba(0,212,255,0.1)] border border-[rgba(0,212,255,0.2)]">
                {topK[0]}
              </span>
            </div>
            <Slider
              value={topK}
              onValueChange={setTopK}
              min={1}
              max={20}
              step={1}
              className="w-full"
            />
          </div>
        </div>

        <div className="space-y-3">
          <label className="text-[#94a3b8]">{t('retrieval.scope')}</label>
          <div className="grid grid-cols-3 gap-4">
            {scopeOptions.map((option) => (
              <motion.button
                key={option.id}
                onClick={() => setSearchScope(option.id)}
                whileHover={{ scale: 1.03, y: -2 }}
                whileTap={{ scale: 0.97 }}
                className={`p-4 rounded-xl border-2 transition-all flex flex-col items-center justify-center gap-2 relative overflow-hidden group ${
                  searchScope === option.id
                    ? 'border-[#00d4ff] bg-[rgba(0,212,255,0.1)] shadow-[0_0_20px_rgba(0,212,255,0.3)]'
                    : 'border-[rgba(0,212,255,0.2)] glass hover:border-[rgba(0,212,255,0.4)]'
                }`}
              >
                {searchScope === option.id && (
                  <div className="absolute inset-0 bg-gradient-to-r from-transparent via-[rgba(0,212,255,0.2)] to-transparent shimmer" />
                )}
                <span className="text-2xl relative z-10">{option.icon}</span>
                <span className={`relative z-10 ${searchScope === option.id ? 'text-[#00d4ff]' : 'text-[#e8eaed]'}`}>
                  {option.label}
                </span>
                <span className="text-xs text-[#94a3b8] relative z-10">{option.desc}</span>
              </motion.button>
            ))}
          </div>
        </div>
      </motion.div>

      <motion.div
        className="glass gradient-border rounded-2xl p-6"
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ delay: 0.1 }}
      >
        <div className="flex items-center justify-between gap-4">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-xl bg-gradient-to-br from-[#00d4ff] to-[#0066ff] flex items-center justify-center shadow-lg">
              <Database size={20} className="text-[#0a0e27]" />
            </div>
            <div>
              <h3 className="text-[#e8eaed]">{t('retrieval.results')}</h3>
              <p className="text-[#94a3b8] text-sm">{t('retrieval.resultsSummary', { count: totalResults, time: searchDuration.toFixed(2) })}</p>
            </div>
          </div>
          {hasSearched && (
            <div className="flex gap-2">
              <span className="px-3 py-1.5 rounded-lg glass-strong border border-[rgba(0,212,255,0.2)] text-[#00d4ff] text-sm">
                {t('retrieval.documentResultsBadge', { count: documentResults.length })}
              </span>
              <span className="px-3 py-1.5 rounded-lg glass-strong border border-[rgba(0,255,136,0.2)] text-[#00ff88] text-sm">
                {t('retrieval.conversationResultsBadge', { count: conversationResults.length })}
              </span>
            </div>
          )}
        </div>
      </motion.div>

      {!hasSearched && (
        <motion.div
          className="glass gradient-border rounded-2xl p-10 text-center"
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.2 }}
        >
          <p className="text-[#94a3b8]">{t('retrieval.emptyState')}</p>
        </motion.div>
      )}

      {hasSearched && searchScope !== 'documents' && (
        <motion.div
          className="glass gradient-border rounded-2xl p-6"
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.2 }}
        >
          <div className="flex items-center gap-3 mb-6">
            <div className="w-10 h-10 rounded-xl bg-[rgba(0,255,136,0.15)] border border-[rgba(0,255,136,0.2)] flex items-center justify-center">
              <MessageSquareText size={18} className="text-[#00ff88]" />
            </div>
            <div>
              <h3 className="text-[#e8eaed]">{t('retrieval.conversationResults')}</h3>
              <p className="text-[#94a3b8] text-sm">{t('retrieval.conversationResultsHint')}</p>
            </div>
          </div>

          {conversationResults.length === 0 ? (
            <div className="text-[#94a3b8] text-center py-8">{t('retrieval.noConversationResults')}</div>
          ) : (
            <div className="space-y-4">
              {conversationResults.map((result, index) => (
                <motion.div
                  key={result.sessionId}
                  initial={{ opacity: 0, y: 16 }}
                  animate={{ opacity: 1, y: 0 }}
                  transition={{ delay: 0.25 + index * 0.05 }}
                  className="glass-strong border border-[rgba(0,255,136,0.18)] rounded-xl p-5"
                >
                  <div className="flex items-start justify-between gap-4">
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2 mb-2">
                        <MessageSquareText size={16} className="text-[#00ff88] flex-shrink-0" />
                        <div className="text-[#e8eaed] truncate">{result.title}</div>
                      </div>

                      <div className="flex flex-wrap items-center gap-2 text-sm text-[#94a3b8] mb-3">
                        <span>{result.knowledgeBaseName}</span>
                        <span>•</span>
                        <span>{formatShortDateTime(result.updatedAt, locale)}</span>
                        <span>•</span>
                        <span>{t('retrieval.matchedMessages', { count: result.matchedCount })}</span>
                        <span>•</span>
                        <span>{t(`retrieval.messageRole.${result.messageRole}`)}</span>
                      </div>

                      <div className="text-[#cbd5e1] leading-relaxed">
                        {renderHighlightedText(result.snippet, result.matchedKeywords)}
                      </div>

                      <div className="flex flex-wrap gap-2 mt-4">
                        {result.matchedKeywords.map((keyword) => (
                          <span
                            key={`${result.sessionId}-${keyword}`}
                            className="px-2 py-1 rounded-lg bg-[rgba(0,255,136,0.1)] border border-[rgba(0,255,136,0.2)] text-[#00ff88] text-xs"
                          >
                            {keyword}
                          </span>
                        ))}
                      </div>
                    </div>

                    <motion.button
                      onClick={() => onOpenChatSession(result.sessionId)}
                      whileHover={{ scale: 1.03 }}
                      whileTap={{ scale: 0.97 }}
                      className="px-4 py-2 rounded-xl border border-[rgba(0,255,136,0.3)] text-[#00ff88] hover:bg-[rgba(0,255,136,0.08)] transition-all flex items-center gap-2"
                    >
                      <Eye size={16} />
                      {t('retrieval.openConversation')}
                    </motion.button>
                  </div>
                </motion.div>
              ))}
            </div>
          )}
        </motion.div>
      )}

      {hasSearched && searchScope !== 'conversations' && (
        <motion.div
          className="glass gradient-border rounded-2xl p-6"
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.25 }}
        >
          <div className="flex items-center gap-3 mb-6">
            <div className="w-10 h-10 rounded-xl bg-[rgba(0,212,255,0.15)] border border-[rgba(0,212,255,0.2)] flex items-center justify-center">
              <FileText size={18} className="text-[#00d4ff]" />
            </div>
            <div>
              <h3 className="text-[#e8eaed]">{t('retrieval.documentResults')}</h3>
              <p className="text-[#94a3b8] text-sm">{t('retrieval.documentResultsHint')}</p>
            </div>
          </div>

          {documentResults.length === 0 ? (
            <div className="text-[#94a3b8] text-center py-8">{t('retrieval.noDocumentResults')}</div>
          ) : (
            <div className="space-y-4">
              {documentResults.map((result, index) => {
                const pageStart = result.metadata?.page_start;
                const pageEnd = result.metadata?.page_end;
                const pageLabel = pageStart
                  ? pageStart === pageEnd || !pageEnd
                    ? t('document.pageSingle', { page: pageStart })
                    : t('document.pageRange', { start: pageStart, end: pageEnd })
                  : null;

                return (
                  <motion.div
                    key={`${result.collection_id}-${result.file_id}-${index}`}
                    initial={{ opacity: 0, y: 16 }}
                    animate={{ opacity: 1, y: 0 }}
                    transition={{ delay: 0.3 + index * 0.05 }}
                    className="glass-strong border border-[rgba(0,212,255,0.18)] rounded-xl p-5"
                  >
                    <div className="flex items-start justify-between gap-4">
                      <div className="flex-1 min-w-0">
                        <div className="flex items-center gap-2 mb-2">
                          <FileText size={16} className="text-[#00d4ff] flex-shrink-0" />
                          <div className="text-[#e8eaed] truncate">{result.filename}</div>
                        </div>

                        <div className="flex flex-wrap items-center gap-2 text-sm text-[#94a3b8] mb-3">
                          <span>{result.collection_name}</span>
                          {pageLabel && (
                            <>
                              <span>•</span>
                              <span>{pageLabel}</span>
                            </>
                          )}
                          <span>•</span>
                          <span>{t(`retrieval.matchType.${result.match_type}`)}</span>
                          <span>•</span>
                          <span>{result.score}</span>
                        </div>

                        <div className="text-[#cbd5e1] leading-relaxed">
                          {renderHighlightedText(result.snippet, result.matched_keywords)}
                        </div>

                        <div className="flex flex-wrap gap-2 mt-4">
                          {result.matched_keywords.map((keyword) => (
                            <span
                              key={`${result.file_id}-${keyword}`}
                              className="px-2 py-1 rounded-lg bg-[rgba(0,212,255,0.1)] border border-[rgba(0,212,255,0.2)] text-[#00d4ff] text-xs"
                            >
                              {keyword}
                            </span>
                          ))}
                        </div>
                      </div>

                      <motion.button
                        onClick={() => onOpenDocument(result.collection_id, result.file_id)}
                        disabled={!result.file_id}
                        whileHover={result.file_id ? { scale: 1.03 } : {}}
                        whileTap={result.file_id ? { scale: 0.97 } : {}}
                        className="px-4 py-2 rounded-xl border border-[rgba(0,212,255,0.3)] text-[#00d4ff] hover:bg-[rgba(0,212,255,0.08)] transition-all flex items-center gap-2 disabled:opacity-50 disabled:cursor-not-allowed"
                      >
                        <Eye size={16} />
                        {t('retrieval.openDocument')}
                      </motion.button>
                    </div>
                  </motion.div>
                );
              })}
            </div>
          )}
        </motion.div>
      )}
    </div>
  );
}
