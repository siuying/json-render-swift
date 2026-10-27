/**
 * Entry of the shipped json-render-bridge.js (scripts/build-bridge.mjs): installs
 * `globalThis.JSONRenderBridge` with the built-in catalogs when the bundle loads.
 */
import { installBridge } from "./bridge";

installBridge();
