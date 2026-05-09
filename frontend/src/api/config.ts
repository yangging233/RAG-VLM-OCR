/**
 * API 配置 - 支持 v1.0 和 v2.0 版本
 */

export interface ExtractionMethod {
  id: string;
  label: string;
  description: string;
}

export type PipelineType = 'vlm' | 'ocr';

export interface APIVersion {
  extraction: {
    endpoint: string;
    uploadEndpoint: string;
    methods: ExtractionMethod[];
  };
  chunking: {
    endpoint: string;
    methods: string[];
  };
  retrieval: {
    endpoint: string;
  };
  chat: {
    endpoint: string;
  };
}

export const API_CONFIG: Record<'v1' | 'v2', APIVersion> = {
  // ============ v1.0 配置 ============
  v1: {
    extraction: {
      endpoint: 'http://localhost:8006/extract',
      uploadEndpoint: 'http://localhost:8006/api/v1/files/upload',
      methods: [
        {
          id: 'fast',
          label: '快速模式 (PyMuPDF4LLM)',
          description: '适合简单文档，速度快'
        },
        {
          id: 'vlm',
          label: '精确模式 (VLM)',
          description: '支持复杂布局，使用视觉语言模型'
        }
      ]
    },
    chunking: {
      endpoint: 'http://localhost:8001/chunk',
      methods: ['header_recursive', 'markdown_only']
    },
    retrieval: {
      endpoint: 'http://localhost:8000'
    },
    chat: {
      endpoint: 'http://localhost:8501'
    }
  },

  // ============ v2.0 配置 (OCR 增强版) ============
  v2: {
    extraction: {
      endpoint: 'http://localhost:8006/extract/v2',
      uploadEndpoint: 'http://localhost:8006/api/v2/files/upload',
      methods: [
        {
          id: 'mineru',
          label: 'MinerU',
          description: '高质量 PDF 解析，支持复杂版面结构'
        },
        {
          id: 'deepseek',
          label: 'DeepSeek-OCR',
          description: 'AI驱动的OCR，支持复杂场景和多语言'
        },
        {
          id: 'paddleocr_vl',
          label: 'PaddleOCR-VL',
          description: '视觉语言模型OCR，高精度文字识别'
        }
      ]
    },
    chunking: {
      endpoint: 'http://localhost:8001/chunk/v2',
      methods: ['ocr_aware', 'layout_based']
    },
    retrieval: {
      endpoint: 'http://localhost:8000'
    },
    chat: {
      endpoint: 'http://localhost:8501'
    }
  }
};

/**
 * 根据版本获取 API 配置
 */
export const getAPIConfig = (isV2: boolean): APIVersion => {
  return isV2 ? API_CONFIG.v2 : API_CONFIG.v1;
};

/**
 * 获取提取方法配置
 */
export const getExtractionMethods = (isV2: boolean): ExtractionMethod[] => {
  return getAPIConfig(isV2).extraction.methods;
};

/**
 * 获取上传端点
 */
export const getUploadEndpoint = (isV2: boolean): string => {
  return getAPIConfig(isV2).extraction.uploadEndpoint;
};

/**
 * 获取默认提取方法
 */
export const getDefaultExtractionMethod = (isV2: boolean): string => {
  return isV2 ? 'mineru' : 'fast';
};

export const getPipelineTypeForMode = (isV2: boolean): PipelineType => {
  return isV2 ? 'ocr' : 'vlm';
};

export const normalizePipelineType = (pipelineType?: string | null): PipelineType => {
  return pipelineType === 'ocr' ? 'ocr' : 'vlm';
};

export const matchesPipelineMode = (pipelineType: string | null | undefined, isV2: boolean): boolean => {
  return normalizePipelineType(pipelineType) === getPipelineTypeForMode(isV2);
};
