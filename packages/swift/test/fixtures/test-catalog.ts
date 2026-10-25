/**
 * A small element-based catalog that is not built in, for testing `installBridge({ catalogs })`.
 * Bundled with test-catalog-bridge.ts into fixtures/bridge/test-catalog-bridge.js for the Swift tests.
 */
import { defineCatalog, defineSchema } from "@json-render/core";
import { z } from "zod";

export const testSchema = defineSchema((s) => ({
  spec: s.object({
    root: s.string(),
    elements: s.record(
      s.object({
        type: s.ref("catalog.components"),
        props: s.propsOf("catalog.components"),
        children: s.array(s.string()),
        visible: { ...s.any(), ...s.optional() },
        on: { ...s.record(s.any()), ...s.optional() },
      }),
    ),
    state: { ...s.record(s.any()), ...s.optional() },
  }),
  catalog: s.object({
    components: s.map({
      props: s.zod(),
      events: s.array(s.string()),
      description: s.string(),
    }),
    actions: s.map({
      params: s.zod(),
      description: s.string(),
    }),
  }),
}));

export const testCatalog = defineCatalog(testSchema, {
  components: {
    Board: {
      props: z.object({ title: z.string() }),
      events: [],
      description: "A dashboard board holding Metric children.",
    },
    Metric: {
      props: z.object({
        label: z.string(),
        value: z.number().nullable().optional(),
      }),
      events: ["press"],
      description: "One labelled number.",
    },
  },
  actions: {
    refresh: {
      params: z.object({ source: z.string() }),
      description: "Reload a data source.",
    },
  },
});

/** A valid spec for testCatalog. */
export const testSpec = {
  root: "board",
  elements: {
    board: {
      type: "Board",
      props: { title: "Today" },
      children: ["visits"],
    },
    visits: {
      type: "Metric",
      props: { label: "Visits", value: { $state: "/visits" } },
      on: { press: { action: "refresh", params: { source: "analytics" } } },
      children: [],
    },
  },
  state: { visits: 42 },
};
