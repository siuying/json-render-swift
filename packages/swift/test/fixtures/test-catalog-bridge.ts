/** Bundle entry of fixtures/bridge/test-catalog-bridge.js: the bridge with an extra "test" catalog. */
import { installBridge } from "../../src/bridge";
import { testCatalog } from "./test-catalog";

installBridge({ catalogs: { test: testCatalog } });
