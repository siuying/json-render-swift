import { defineCatalog } from "@json-render/core";
import { schema } from "./schema";
import {
  actionDefinitions,
  checkTypeDescriptions,
  componentDefinitions,
} from "./catalog";

// Schema
export {
  schema,
  swiftUIFormRules,
  promptExampleJsonl,
  type SwiftUISchema,
  type SwiftUISpec,
} from "./schema";

// Definitions
export {
  componentDefinitions,
  actionDefinitions,
  validationCheckSchema,
  builtInCheckTypes,
  checkTypeDescriptions,
  type BuiltInCheckType,
  type ComponentName,
  type ActionName,
} from "./catalog";

// Spec validation (structural + catalog + per-component props)
export {
  validateSwiftUISpec,
  validateSpecForCatalog,
  autoFixSwiftUISpec,
  autoFixSpecForCatalog,
  type SwiftUISpecIssue,
  type ValidateSpecOptions,
  type SwiftUISpecValidation,
} from "./validate";

// PDF catalog (upstream @json-render/react-pdf definitions)
export {
  pdfSchema,
  pdfCatalog,
  pdfComponentDefinitions,
  pdfDocumentRules,
  pdfNativeRules,
  pdfPromptExampleJsonl,
  type PdfSchema,
  type PdfCatalog,
} from "./pdf";
export {
  chartComponentDefinitions,
  pdfChartComponentDefinitions,
  chartRules,
} from "./charts";
export {
  pdfFormComponentDefinitions,
  pdfFormFieldTypes,
  pdfFormRules,
} from "./pdf-forms";

/**
 * The SwiftUI forms catalog: every component and action the native runtime renders.
 */
export const catalog = defineCatalog(schema, {
  components: componentDefinitions,
  actions: actionDefinitions,
  checkTypes: checkTypeDescriptions,
});

export type SwiftUICatalog = typeof catalog;
