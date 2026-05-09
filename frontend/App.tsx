import { useEffect, useState } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import { Sidebar } from './components/Sidebar';
import { Header } from './components/Header';
import { Dashboard } from './components/Dashboard';
import { KnowledgeBase } from './components/KnowledgeBase';
import { KnowledgeBaseDetail } from './components/KnowledgeBaseDetail';
import { DocumentViewer } from './components/DocumentViewer';
import { Chat } from './components/Chat';
import { RetrievalTest } from './components/RetrievalTest';
import { Settings } from './components/Settings';
import { Toaster } from './components/ui/sonner';
import { useI18n } from './src/i18n/useI18n';

export default function App() {
  const { t } = useI18n();
  const [activeView, setActiveView] = useState('dashboard');
  const [selectedKnowledgeBase, setSelectedKnowledgeBase] = useState<string | null>(null);
  const [selectedDocument, setSelectedDocument] = useState<string | null>(null);
  const [pendingChatSessionId, setPendingChatSessionId] = useState<string | null>(null);
  const [isV2, setIsV2] = useState(() => {
    const saved = localStorage.getItem('rag_mode_v2');
    return saved === 'true';
  });

  useEffect(() => {
    localStorage.setItem('rag_mode_v2', String(isV2));
  }, [isV2]);

  const getHeaderTitle = () => {
    switch (activeView) {
      case 'dashboard':
        return t('nav.dashboard');
      case 'knowledge':
        return selectedKnowledgeBase ? t('nav.knowledgeDetail') : t('nav.knowledge');
      case 'chat':
        return t('nav.chat');
      case 'retrieval':
        return t('nav.retrieval');
      case 'settings':
        return t('nav.settings');
      default:
        return t('nav.dashboard');
    }
  };

  const handleNavigate = (view: string) => {
    setActiveView(view);
    setSelectedKnowledgeBase(null);
    setSelectedDocument(null);
    setPendingChatSessionId(null);
  };

  const handleViewKnowledgeBaseDetail = (collectionId: string) => {
    setSelectedKnowledgeBase(collectionId);
  };

  const handleBackToKnowledgeBase = () => {
    setSelectedKnowledgeBase(null);
    setSelectedDocument(null);
  };

  const handleViewDocument = (fileId: string) => {
    setSelectedDocument(fileId);
  };

  const handleBackToDetail = () => {
    // 只清除文档选择，保留知识库选择，返回到知识库详情页
    setSelectedDocument(null);
    // selectedKnowledgeBase 保持不变，这样就返回到知识库详情页
  };

  const handleOpenChatSession = (sessionId: string) => {
    setActiveView('chat');
    setSelectedKnowledgeBase(null);
    setSelectedDocument(null);
    setPendingChatSessionId(sessionId);
  };

  const handleOpenDocumentFromRetrieval = (collectionId: string, fileId: string) => {
    setActiveView('knowledge');
    setSelectedKnowledgeBase(collectionId);
    setSelectedDocument(fileId);
    setPendingChatSessionId(null);
  };

  const handleToggleVersion = () => {
    setIsV2((prev) => !prev);
    setSelectedKnowledgeBase(null);
    setSelectedDocument(null);
    setPendingChatSessionId(null);
  };

  const renderContent = () => {
    if (activeView === 'knowledge') {
      if (selectedDocument) {
        return <DocumentViewer fileId={selectedDocument} onBack={handleBackToDetail} />;
      }
      if (selectedKnowledgeBase) {
        return (
          <KnowledgeBaseDetail
            collectionId={selectedKnowledgeBase}
            onBack={handleBackToKnowledgeBase}
            onViewDocument={handleViewDocument}
            isV2={isV2}
          />
        );
      }
      return <KnowledgeBase onViewDetail={handleViewKnowledgeBaseDetail} isV2={isV2} />;
    }

    switch (activeView) {
      case 'dashboard':
        return <Dashboard onNavigate={handleNavigate} isV2={isV2} />;
      case 'chat':
        return (
          <Chat
            targetSessionId={pendingChatSessionId}
            onTargetSessionHandled={() => setPendingChatSessionId(null)}
            isV2={isV2}
          />
        );
      case 'retrieval':
        return (
          <RetrievalTest
            onOpenChatSession={handleOpenChatSession}
            onOpenDocument={handleOpenDocumentFromRetrieval}
            isV2={isV2}
          />
        );
      case 'settings':
        return <Settings />;
      default:
        return <Dashboard onNavigate={handleNavigate} isV2={isV2} />;
    }
  };

  return (
    <div className="min-h-screen">
      {/* Animated Background Grid */}
      <div className="fixed inset-0 pointer-events-none" style={{ zIndex: 0 }}>
        <div className="absolute inset-0 bg-[linear-gradient(rgba(0,212,255,0.03)_1px,transparent_1px),linear-gradient(90deg,rgba(0,212,255,0.03)_1px,transparent_1px)] bg-[size:50px_50px]" />
        
        {/* Floating Orbs */}
        <motion.div
          className="absolute w-[500px] h-[500px] rounded-full bg-[#00d4ff] opacity-10 blur-[120px]"
          animate={{
            x: [0, 100, 0],
            y: [0, -100, 0],
          }}
          transition={{
            duration: 20,
            repeat: Infinity,
            ease: "easeInOut",
          }}
          style={{ top: '10%', left: '20%' }}
        />
        <motion.div
          className="absolute w-[400px] h-[400px] rounded-full bg-[#0066ff] opacity-10 blur-[120px]"
          animate={{
            x: [0, -80, 0],
            y: [0, 80, 0],
          }}
          transition={{
            duration: 15,
            repeat: Infinity,
            ease: "easeInOut",
          }}
          style={{ bottom: '10%', right: '20%' }}
        />
      </div>

      <Sidebar activeView={activeView} onNavigate={handleNavigate} isV2={isV2} onToggleVersion={handleToggleVersion} />

      <div style={{ marginLeft: '260px', position: 'relative', zIndex: 10, minHeight: '100vh' }}>
        <Header title={getHeaderTitle()} />

        <main style={{
          paddingTop: (activeView === 'chat' || (activeView === 'knowledge' && selectedDocument)) ? '64px' : '80px',
          minHeight: 'calc(100vh - 64px)'
        }}>
          <div className={(activeView === 'chat' || (activeView === 'knowledge' && selectedDocument)) ? '' : 'max-w-[1440px] mx-auto p-6'}>
            <AnimatePresence mode="wait">
              <motion.div
                key={activeView + (selectedKnowledgeBase || '') + (selectedDocument || '')}
                initial={{ opacity: 0, y: 20 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, y: -20 }}
                transition={{ duration: 0.3, ease: "easeOut" }}
              >
                {renderContent()}
              </motion.div>
            </AnimatePresence>
          </div>
        </main>
      </div>

      <Toaster />
    </div>
  );
}
