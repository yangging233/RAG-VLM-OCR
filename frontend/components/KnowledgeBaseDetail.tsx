import { ArrowLeft, Search, Upload, Eye, Trash2, ChevronDown, Loader2 } from 'lucide-react';
import { useState, useEffect } from 'react';
import { motion } from 'motion/react';
import { toast } from 'sonner';
import { UploadDialog } from './UploadDialog';
import { useI18n } from '../src/i18n/useI18n';
import { formatDateTime, formatRelativeTime } from '../src/i18n/format';
import { config } from '../src/config';

interface KnowledgeBaseDetailProps {
  collectionId: string;
  onBack: () => void;
  onViewDocument: (fileId: string) => void;
  isV2?: boolean;
}

interface DocumentData {
  filename: string;
  file_id: string;
  chunks: number;
  created_at: string;
  metadata: any;
}

interface KBInfo {
  collection_id: string;
  collection_name: string;
  total_documents: number;
  total_chunks: number;
  last_updated: string | null;
}

export function KnowledgeBaseDetail({ collectionId, onBack, onViewDocument, isV2 = false }: KnowledgeBaseDetailProps) {
  const { locale, t } = useI18n();
  const [searchQuery, setSearchQuery] = useState('');
  const [documents, setDocuments] = useState<DocumentData[]>([]);
  const [kbInfo, setKbInfo] = useState<KBInfo | null>(null);
  const [loading, setLoading] = useState(true);
  const [showUploadDialog, setShowUploadDialog] = useState(false);

  useEffect(() => {
    fetchKBDetails();
  }, [collectionId]);

  const fetchKBDetails = async () => {
    setLoading(true);
    try {
      const response = await fetch(`${config.milvusApiUrl}/knowledge_base/${collectionId}/documents`);
      const result = await response.json();

      if (result.status === 'success') {
        setKbInfo({
          collection_id: result.collection_id,
          collection_name: result.collection_name,
          total_documents: result.total_documents,
          total_chunks: result.total_chunks,
          last_updated: result.last_updated,
        });
        setDocuments(result.documents || []);
      } else {
        toast.error(t('kbDetail.fetchFailed'));
      }
    } catch (error) {
      console.error('获取知识库详情失败:', error);
      toast.error(t('kbDetail.fetchFailed'));
    } finally {
      setLoading(false);
    }
  };

  const getFileIcon = (filename: string) => {
    const ext = filename.split('.').pop()?.toLowerCase();
    switch (ext) {
      case 'pdf':
        return '📄';
      case 'md':
      case 'txt':
        return '📝';
      case 'docx':
      case 'doc':
        return '📘';
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
        return '🖼️';
      default:
        return '📄';
    }
  };

  const formatUploadedAt = (dateStr: string) => {
    if (!dateStr) return t('common.unknown');
    try {
      return formatDateTime(dateStr, locale);
    } catch {
      return dateStr;
    }
  };

  const filteredDocuments = documents.filter((doc) =>
    doc.filename.toLowerCase().includes(searchQuery.toLowerCase())
  );

  const handleUpload = (files: File[], kbId: string, config: any) => {
    console.log('Uploading files:', files, 'to KB:', kbId, 'with config:', config);
    // 上传完成后刷新文档列表
    fetchKBDetails();
  };

  if (loading) {
    return (
      <div className="flex items-center justify-center h-[60vh]">
        <Loader2 size={48} className="text-[#00d4ff] animate-spin" />
      </div>
    );
  }

  if (!kbInfo) {
    return (
      <div className="text-center py-12">
        <p className="text-[#94a3b8]">{t('kbDetail.notFound')}</p>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Header */}
      <motion.div
        className="flex items-center justify-between"
        initial={{ opacity: 0, y: -20 }}
        animate={{ opacity: 1, y: 0 }}
      >
        <div className="flex items-center gap-4">
          <motion.button
            onClick={onBack}
            className="text-[#00d4ff] hover:text-[#00ffaa] flex items-center gap-2 transition-colors group"
            whileHover={{ x: -4 }}
          >
            <ArrowLeft size={18} className="group-hover:animate-pulse" />
            {t('common.back')}
          </motion.button>
          <div className="flex items-center gap-3">
            <div className="w-12 h-12 rounded-xl bg-gradient-to-br from-[#00d4ff] to-[#0066ff] flex items-center justify-center text-2xl shadow-lg">
              📘
            </div>
            <h2 className="text-gradient">{kbInfo.collection_name}</h2>
          </div>
        </div>

        <motion.button
          onClick={() => setShowUploadDialog(true)}
          className="px-6 py-3 bg-gradient-to-r from-[#00d4ff] to-[#0066ff] text-[#0a0e27] rounded-xl hover:shadow-[0_0_30px_rgba(0,212,255,0.6)] transition-all flex items-center gap-2 relative overflow-hidden group"
          whileHover={{ scale: 1.05 }}
          whileTap={{ scale: 0.95 }}
        >
          <div className="absolute inset-0 bg-gradient-to-r from-transparent via-white to-transparent opacity-0 group-hover:opacity-20 shimmer" />
          <Upload size={18} className="relative z-10" />
          <span className="relative z-10">{t('kbDetail.uploadDocuments')}</span>
        </motion.button>
      </motion.div>

      {/* Upload Dialog */}
      <UploadDialog
        isOpen={showUploadDialog}
        onClose={() => setShowUploadDialog(false)}
        onUpload={handleUpload}
        preselectedKB={collectionId}
        isV2={isV2}
      />

      {/* Summary Bar */}
      <motion.div
        className="flex items-center gap-3"
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ delay: 0.1 }}
      >
        <span className="px-4 py-2 glass-strong rounded-xl border border-[rgba(0,212,255,0.2)] text-[#e8eaed]">
          {t('common.unit.documents', { count: kbInfo.total_documents })}
        </span>
        <span className="px-4 py-2 glass-strong rounded-xl border border-[rgba(0,255,136,0.2)] text-[#00ff88]">
          {kbInfo.total_chunks} chunks
        </span>
        <span className="px-4 py-2 glass-strong rounded-xl border border-[rgba(0,212,255,0.2)] text-[#94a3b8]">
          {t('kbDetail.lastUpdated', { value: formatRelativeTime(kbInfo.last_updated, locale) })}
        </span>
      </motion.div>

      {/* Search and Filters */}
      <motion.div
        className="flex items-center gap-4"
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ delay: 0.2 }}
      >
        <div className="relative flex-1 max-w-[320px]">
          <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-[#00d4ff]" size={18} />
          <input
            type="text"
            placeholder={t('kbDetail.searchPlaceholder')}
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            className="w-full h-12 pl-11 pr-4 glass-strong border border-[rgba(0,212,255,0.2)] rounded-xl focus:outline-none focus:ring-2 focus:ring-[#00d4ff] focus:border-transparent text-[#e8eaed] placeholder-[#94a3b8] transition-all"
          />
        </div>

        <motion.button
          className="px-4 py-3 glass-strong border border-[rgba(0,212,255,0.2)] rounded-xl hover:bg-[rgba(0,212,255,0.05)] transition-all flex items-center gap-2 text-[#e8eaed]"
          whileHover={{ scale: 1.05 }}
        >
          {t('kbDetail.sortByTime')}
          <ChevronDown size={16} className="text-[#00d4ff]" />
        </motion.button>

        <motion.button
          className="px-4 py-3 glass-strong border border-[rgba(0,212,255,0.2)] rounded-xl hover:bg-[rgba(0,212,255,0.05)] transition-all flex items-center gap-2 text-[#e8eaed]"
          whileHover={{ scale: 1.05 }}
        >
          {t('kbDetail.sortBySize')}
          <ChevronDown size={16} className="text-[#00d4ff]" />
        </motion.button>
      </motion.div>

      {/* Document List */}
      {filteredDocuments.length === 0 ? (
        <motion.div
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          className="text-center py-12"
        >
          <p className="text-[#94a3b8]">
            {documents.length === 0 ? t('kbDetail.noDocuments') : t('kbDetail.noMatch')}
          </p>
        </motion.div>
      ) : (
        <div className="space-y-3">
          {filteredDocuments.map((doc, index) => (
            <motion.div
              key={doc.file_id}
              initial={{ opacity: 0, y: 20 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.4, delay: 0.3 + index * 0.1 }}
              whileHover={{ y: -2 }}
              className="glass gradient-border rounded-xl p-5 hover:shadow-[0_0_25px_rgba(0,212,255,0.2)] transition-all group relative overflow-hidden"
            >
              {/* Hover shimmer */}
              <div className="absolute inset-0 opacity-0 group-hover:opacity-100 transition-opacity duration-500">
                <div className="absolute inset-0 bg-gradient-to-r from-transparent via-[rgba(0,212,255,0.1)] to-transparent shimmer" />
              </div>

              <div className="flex items-center gap-4 relative z-10">
                {/* File Icon */}
                <div className="w-14 h-14 glass-strong rounded-xl flex items-center justify-center text-3xl flex-shrink-0 border border-[rgba(0,212,255,0.2)] group-hover:scale-110 transition-transform">
                  {getFileIcon(doc.filename)}
                </div>

                {/* File Info */}
                <div className="flex-1 min-w-0">
                  <div className="text-[#e8eaed] mb-2 group-hover:text-[#00d4ff] transition-colors truncate" title={doc.filename}>
                    {doc.filename}
                  </div>
                  <div className="text-[#94a3b8] text-sm flex items-center gap-3">
                    <span className="px-2 py-1 glass rounded-lg border border-[rgba(0,212,255,0.1)]">
                      {doc.chunks} chunks
                    </span>
                    <span>{t('kbDetail.uploadedAt', { value: formatUploadedAt(doc.created_at) })}</span>
                  </div>
                </div>

                {/* Status */}
                <div className="flex items-center gap-2">
                  <span className="px-3 py-1.5 bg-[rgba(0,255,136,0.1)] text-[#00ff88] rounded-lg text-xs border border-[rgba(0,255,136,0.2)] flex items-center gap-1">
                    {t('kbDetail.indexed')}
                  </span>
                </div>

                {/* Actions */}
                <div className="flex gap-2">
                  <motion.button
                    onClick={() => onViewDocument(doc.file_id)}
                    whileHover={{ scale: 1.05 }}
                    whileTap={{ scale: 0.95 }}
                    className="px-4 py-2 border border-[#00d4ff] text-[#00d4ff] rounded-xl hover:bg-[rgba(0,212,255,0.1)] transition-all flex items-center gap-2"
                  >
                    <Eye size={16} />
                    {t('common.view')}
                  </motion.button>
                  <motion.button
                    whileHover={{ scale: 1.05 }}
                    whileTap={{ scale: 0.95 }}
                    className="px-4 py-2 border border-[#ff3b5c] text-[#ff3b5c] rounded-xl hover:bg-[rgba(255,59,92,0.1)] transition-all"
                  >
                    <Trash2 size={16} />
                  </motion.button>
                </div>
              </div>
            </motion.div>
          ))}
        </div>
      )}
    </div>
  );
}
