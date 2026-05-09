import { Search, Plus, Trash2, Database } from 'lucide-react';
import { useState, useEffect } from 'react';
import { motion } from 'motion/react';
import { ConfirmDialog } from './ConfirmDialog';
import { Toast } from './Toast';
import { useI18n } from '../src/i18n/useI18n';
import { formatRelativeTime } from '../src/i18n/format';
import { config } from '../src/config';
import { getPipelineTypeForMode, matchesPipelineMode } from '../src/api/config';

interface KnowledgeBaseProps {
  onViewDetail: (collectionId: string) => void;
  isV2?: boolean;
}

interface KnowledgeBaseData {
  id: number;
  collection_id: string;  // Milvus collection ID
  name: string;  // 显示名称（中文）
  icon: string;
  iconBg: string;
  documents: number;
  chunks: number | string;
  updated: string;
  storageUsed: number;
}

export function KnowledgeBase({ onViewDetail, isV2 = false }: KnowledgeBaseProps) {
  const { locale, t } = useI18n();
  const [searchQuery, setSearchQuery] = useState('');
  const [knowledgeBases, setKnowledgeBases] = useState<KnowledgeBaseData[]>([]);
  const [showCreateDialog, setShowCreateDialog] = useState(false);
  const [newKbName, setNewKbName] = useState('');
  const [loading, setLoading] = useState(false);
  const [deleteConfirm, setDeleteConfirm] = useState<{ show: boolean; id: string; name: string }>({
    show: false,
    id: '',
    name: '',
  });
  const [toast, setToast] = useState<{ show: boolean; message: string; type: 'success' | 'error' | 'info' | 'warning' }>({
    show: false,
    message: '',
    type: 'info',
  });

  // 从Milvus API获取知识库列表
  useEffect(() => {
    fetchKnowledgeBases();
  }, [locale]);

  const fetchKnowledgeBases = async () => {
    setLoading(true);
    try {
      const response = await fetch(`${config.milvusApiUrl}/stats/all`);
      const result = await response.json();

      if (result.status === 'success') {
        const collections = result.data.collections || [];

        // 图标映射
        const icons = ['📘', '📗', '📙', '📕', '📔', '📓'];
        const iconBgs = ['bg-blue-100', 'bg-green-100', 'bg-orange-100', 'bg-red-100', 'bg-purple-100', 'bg-pink-100'];

        const filteredCollections = collections.filter((col: any) => {
          return matchesPipelineMode(col.pipeline_type, isV2);
        });

        const kbData = filteredCollections.map((col: any, index: number) => {
          let updated = t('common.unknown');
          if (col.last_updated) {
            updated = formatRelativeTime(col.last_updated, locale);
          }

          let displayName = col.collection_name;

          return {
            id: index + 1,
            collection_id: col.collection_id,
            name: displayName,
            icon: icons[index % icons.length],
            iconBg: iconBgs[index % iconBgs.length],
            documents: col.total_documents || 0,
            chunks: col.total_chunks || 0,
            updated: updated,
            storageUsed: Math.min(95, Math.floor((col.total_chunks || 0) / 100)),
          };
        });

        setKnowledgeBases(kbData);
      }
    } catch (error) {
      console.error('获取知识库列表失败:', error);
      showToast(t('knowledge.fetchFailed'), 'error');
    } finally {
      setLoading(false);
    }
  };

  const showToast = (message: string, type: 'success' | 'error' | 'info' | 'warning' = 'info') => {
    setToast({ show: true, message, type });
  };

  const handleCreateKB = async () => {
    if (!newKbName.trim()) {
      showToast(t('knowledge.inputName'), 'warning');
      return;
    }

    try {
      const params = new URLSearchParams({
        display_name: newKbName.trim(),
        pipeline_type: getPipelineTypeForMode(isV2),
      });
      const response = await fetch(`${config.milvusApiUrl}/knowledge_base/create?${params.toString()}`, {
        method: 'POST',
      });
      const result = await response.json();

      if (result.status === 'success') {
        showToast(t('knowledge.createSuccess'), 'success');
        setShowCreateDialog(false);
        setNewKbName('');
        // 刷新列表
        fetchKnowledgeBases();
      } else {
        showToast(result.message || t('knowledge.createFailed'), 'error');
      }
    } catch (error) {
      console.error('创建知识库失败:', error);
      showToast(`${t('knowledge.createFailed')}: ${error instanceof Error ? error.message : String(error)}`, 'error');
    }
  };

  const confirmDelete = (collectionId: string, displayName: string) => {
    setDeleteConfirm({ show: true, id: collectionId, name: displayName });
  };

  const handleDeleteKB = async () => {
    try {
      const response = await fetch(`${config.milvusApiUrl}/knowledge_base/delete`, {
        method: 'DELETE',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ collection_id: deleteConfirm.id }),
      });
      const result = await response.json();

      if (result.status === 'success') {
        showToast(t('knowledge.deleteSuccess'), 'success');
        // 刷新列表
        fetchKnowledgeBases();
      } else {
        showToast(result.message || t('knowledge.deleteFailed'), 'error');
      }
    } catch (error) {
      console.error('删除知识库失败:', error);
      showToast(t('knowledge.deleteFailed'), 'error');
    }
  };

  // 过滤知识库
  const filteredKBs = knowledgeBases.filter(kb =>
    kb.name.toLowerCase().includes(searchQuery.toLowerCase())
  );

  return (
    <div className="space-y-6">
      {/* Header */}
      <motion.div 
        className="flex items-center justify-between"
        initial={{ opacity: 0, y: -20 }}
        animate={{ opacity: 1, y: 0 }}
      >
        <div className="flex items-center gap-3">
          <div className="w-12 h-12 rounded-xl bg-gradient-to-br from-[#00d4ff] to-[#0066ff] flex items-center justify-center shadow-lg">
            <Database size={24} className="text-[#0a0e27]" />
          </div>
          <h2 className="text-gradient">{t('knowledge.title')}</h2>
        </div>
        <motion.button
          onClick={() => setShowCreateDialog(true)}
          className="px-6 py-3 bg-gradient-to-r from-[#00d4ff] to-[#0066ff] text-[#0a0e27] rounded-xl hover:shadow-[0_0_30px_rgba(0,212,255,0.6)] transition-all flex items-center gap-2 relative overflow-hidden group"
          whileHover={{ scale: 1.05 }}
          whileTap={{ scale: 0.95 }}
        >
          <div className="absolute inset-0 bg-gradient-to-r from-transparent via-white to-transparent opacity-0 group-hover:opacity-20 shimmer" />
          <Plus size={18} className="relative z-10" />
          <span className="relative z-10">{t('knowledge.new')}</span>
        </motion.button>
      </motion.div>

      {/* Stats Summary */}
      {!loading && knowledgeBases.length > 0 && (
        <motion.div
          className="flex items-center gap-6 glass rounded-xl p-4 border border-[rgba(0,212,255,0.2)]"
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.1 }}
        >
          <div className="flex items-center gap-2">
            <span className="text-[#94a3b8] text-sm">{t('knowledge.total')}</span>
            <span className="text-[#e8eaed] font-medium">{t('knowledge.knowledgeBasesCount', { count: knowledgeBases.length })}</span>
          </div>
          <div className="w-px h-4 bg-[rgba(0,212,255,0.2)]" />
          <div className="flex items-center gap-2">
            <span className="text-[#94a3b8] text-sm">{t('knowledge.documents')}</span>
            <span className="text-[#00d4ff] font-medium">
              {t('common.unit.documents', { count: knowledgeBases.reduce((sum, kb) => sum + kb.documents, 0) })}
            </span>
          </div>
          <div className="w-px h-4 bg-[rgba(0,212,255,0.2)]" />
          <div className="flex items-center gap-2">
            <span className="text-[#94a3b8] text-sm">{t('knowledge.chunks')}</span>
            <span className="text-[#00ff88] font-medium">
              {knowledgeBases.reduce((sum, kb) => sum + (typeof kb.chunks === 'number' ? kb.chunks : 0), 0)}
            </span>
          </div>
        </motion.div>
      )}

      {/* Search Bar */}
      <motion.div
        className="relative"
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ delay: 0.2 }}
      >
        <Search className="absolute left-4 top-1/2 transform -translate-y-1/2 text-[#00d4ff]" size={20} />
        <input
          type="text"
          placeholder={t('knowledge.searchPlaceholder')}
          value={searchQuery}
          onChange={(e) => setSearchQuery(e.target.value)}
          className="w-full h-14 pl-12 pr-4 glass-strong rounded-xl border border-[rgba(0,212,255,0.2)] focus:outline-none focus:ring-2 focus:ring-[#00d4ff] focus:border-[#00d4ff] text-[#e8eaed] placeholder-[#94a3b8] transition-all duration-300"
        />
      </motion.div>

      {/* Loading State */}
      {loading && (
        <div className="text-center text-[#94a3b8] py-12">
          <div className="inline-block animate-spin rounded-full h-12 w-12 border-b-2 border-[#00d4ff]"></div>
          <p className="mt-4">{t('knowledge.loading')}</p>
        </div>
      )}

      {/* Empty State */}
      {!loading && filteredKBs.length === 0 && (
        <div className="text-center text-[#94a3b8] py-12">
          <Database size={48} className="mx-auto mb-4 opacity-50" />
          <p>{t('knowledge.empty')}</p>
        </div>
      )}

      {/* Knowledge Base Cards */}
      <div className="space-y-4">
        {!loading && filteredKBs.map((kb, index) => (
          <motion.div
            key={kb.id}
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.4, delay: 0.2 + index * 0.1 }}
            whileHover={{ y: -4, transition: { duration: 0.2 } }}
            className="glass gradient-border rounded-2xl p-6 hover:shadow-[0_0_30px_rgba(0,212,255,0.3)] transition-all cursor-pointer group relative overflow-hidden"
          >
            {/* Hover shimmer effect */}
            <div className="absolute inset-0 opacity-0 group-hover:opacity-100 transition-opacity duration-500">
              <div className="absolute inset-0 bg-gradient-to-r from-transparent via-[rgba(0,212,255,0.1)] to-transparent shimmer" />
            </div>

            <div className="flex items-start gap-4 relative z-10">
              {/* Icon */}
              <div className={`w-16 h-16 rounded-2xl bg-gradient-to-br ${kb.iconBg === 'bg-blue-100' ? 'from-[#00d4ff] to-[#0066ff]' : kb.iconBg === 'bg-green-100' ? 'from-[#00ff88] to-[#00d4a0]' : 'from-[#ffb800] to-[#ff8c00]'} flex items-center justify-center text-3xl flex-shrink-0 shadow-lg group-hover:scale-110 group-hover:rotate-3 transition-transform duration-300`}>
                {kb.icon}
              </div>

              {/* Content */}
              <div className="flex-1">
                <h3 className="mb-2 text-[#e8eaed] group-hover:text-[#00d4ff] transition-colors">{kb.name}</h3>
                
                <div className="text-[#94a3b8] mb-4 text-sm flex items-center gap-3">
                  <span className="px-3 py-1 rounded-lg bg-[rgba(0,212,255,0.1)] text-[#00d4ff] border border-[rgba(0,212,255,0.2)]">
                    {t('knowledge.documentsCount', { count: kb.documents })}
                  </span>
                  <span className="px-3 py-1 rounded-lg bg-[rgba(0,255,136,0.1)] text-[#00ff88] border border-[rgba(0,255,136,0.2)]">
                    {kb.chunks} chunks
                  </span>
                  <span>{t('knowledge.updated', { value: kb.updated })}</span>
                </div>

                {/* Progress Bar */}
                <div className="mb-4">
                  <div className="flex items-center justify-between text-xs text-[#94a3b8] mb-2">
                    <span>{t('knowledge.storageUsage')}</span>
                    <span className="text-[#00d4ff]">{kb.storageUsed}%</span>
                  </div>
                  <div className="h-2 bg-[rgba(15,18,53,0.6)] rounded-full overflow-hidden border border-[rgba(0,212,255,0.2)]">
                    <motion.div
                      initial={{ width: 0 }}
                      animate={{ width: `${kb.storageUsed}%` }}
                      transition={{ duration: 1, delay: 0.5 + index * 0.1 }}
                      className="h-full bg-gradient-to-r from-[#00d4ff] to-[#0066ff] relative overflow-hidden"
                    >
                      <div className="absolute inset-0 bg-gradient-to-r from-transparent via-white to-transparent opacity-30 shimmer" />
                    </motion.div>
                  </div>
                </div>
              </div>

              {/* Actions */}
              <div className="flex gap-2">
                <motion.button
                  onClick={() => onViewDetail(kb.collection_id)}
                  whileHover={{ scale: 1.05 }}
                  whileTap={{ scale: 0.95 }}
                  className="px-6 py-2.5 bg-gradient-to-r from-[#00d4ff] to-[#0066ff] text-[#0a0e27] rounded-xl hover:shadow-[0_0_20px_rgba(0,212,255,0.5)] transition-all"
                >
                  {t('knowledge.enter')}
                </motion.button>
                <motion.button
                  onClick={(e) => {
                    e.stopPropagation();
                    confirmDelete(kb.collection_id, kb.name);
                  }}
                  whileHover={{ scale: 1.05 }}
                  whileTap={{ scale: 0.95 }}
                  className="px-4 py-2.5 border-2 border-[#ff3b5c] text-[#ff3b5c] rounded-xl hover:bg-[rgba(255,59,92,0.1)] transition-all"
                >
                  <Trash2 size={18} />
                </motion.button>
              </div>
            </div>
          </motion.div>
        ))}
      </div>

      {/* Create Knowledge Base Dialog */}
      {showCreateDialog && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm">
          <motion.div
            initial={{ opacity: 0, scale: 0.9, y: 20 }}
            animate={{ opacity: 1, scale: 1, y: 0 }}
            transition={{ duration: 0.3, ease: 'easeOut' }}
            className="glass gradient-border rounded-2xl p-8 w-full max-w-md mx-4 relative overflow-hidden"
          >
            {/* Background shimmer */}
            <div className="absolute inset-0 opacity-5">
              <div className="absolute inset-0 bg-gradient-to-br from-[#00d4ff] to-[#0066ff] blur-3xl" />
            </div>

            <div className="relative z-10">
              <h3 className="text-2xl mb-6 text-[#e8eaed]">{t('knowledge.createTitle')}</h3>

              <div className="mb-6">
                <label className="block text-[#94a3b8] mb-2">{t('knowledge.nameLabel')}</label>
                <input
                  type="text"
                  value={newKbName}
                  onChange={(e) => setNewKbName(e.target.value)}
                  placeholder={t('knowledge.namePlaceholder')}
                  className="w-full px-4 py-3 glass-strong rounded-xl border border-[rgba(0,212,255,0.2)] focus:outline-none focus:ring-2 focus:ring-[#00d4ff] focus:border-[#00d4ff] text-[#e8eaed] placeholder-[#94a3b8] transition-all"
                  onKeyDown={(e) => e.key === 'Enter' && handleCreateKB()}
                  autoFocus
                />
              </div>

              <div className="flex gap-3">
                <motion.button
                  onClick={handleCreateKB}
                  whileHover={{ scale: 1.05 }}
                  whileTap={{ scale: 0.95 }}
                  className="flex-1 px-6 py-3 bg-gradient-to-r from-[#00d4ff] to-[#0066ff] text-[#0a0e27] rounded-xl hover:shadow-[0_0_20px_rgba(0,212,255,0.5)] transition-all relative overflow-hidden group"
                >
                  <div className="absolute inset-0 bg-gradient-to-r from-transparent via-white to-transparent opacity-0 group-hover:opacity-20 shimmer" />
                  <span className="relative z-10">{t('common.create')}</span>
                </motion.button>
                <motion.button
                  onClick={() => {
                    setShowCreateDialog(false);
                    setNewKbName('');
                  }}
                  whileHover={{ scale: 1.05 }}
                  whileTap={{ scale: 0.95 }}
                  className="flex-1 px-6 py-3 border-2 border-[#00d4ff] text-[#00d4ff] rounded-xl hover:bg-[rgba(0,212,255,0.1)] transition-all"
                >
                  {t('common.cancel')}
                </motion.button>
              </div>
            </div>
          </motion.div>
        </div>
      )}

      {/* Delete Confirmation Dialog */}
      <ConfirmDialog
        isOpen={deleteConfirm.show}
        onClose={() => setDeleteConfirm({ show: false, id: '', name: '' })}
        onConfirm={handleDeleteKB}
        title={t('knowledge.deleteTitle')}
        message={t('knowledge.deleteMessage', { name: deleteConfirm.name })}
        type="warning"
        confirmText={t('common.delete')}
        cancelText={t('common.cancel')}
      />

      {/* Toast Notification */}
      <Toast
        isOpen={toast.show}
        onClose={() => setToast({ ...toast, show: false })}
        message={toast.message}
        type={toast.type}
        duration={3000}
      />
    </div>
  );
}
