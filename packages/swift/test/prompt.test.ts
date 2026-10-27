import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { buildUserPrompt } from "@json-render/core";
import {
  builtInCheckTypes,
  catalog,
  schema,
  swiftUIFormRules,
} from "../src/index";
import { readJSON, readText, repoDir, specsDir } from "./helpers";

describe("system prompt", () => {
  const prompt = catalog.prompt();

  it("lists every component, action and check type", () => {
    for (const name of catalog.componentNames) {
      expect(prompt).toContain(`- ${name}: `);
    }
    for (const name of catalog.actionNames) {
      expect(prompt).toContain(`- ${name}: `);
    }
    for (const type of builtInCheckTypes) {
      expect(prompt).toContain(`- ${type}: `);
    }
  });

  it("asks for JSONL patches and documents the spec features the runtime supports", () => {
    expect(prompt).toContain("OUTPUT FORMAT (JSONL, RFC 6902 JSON Patch)");
    for (const keyword of [
      "$bindState",
      "$state",
      "$template",
      "$cond",
      '"visible"',
      '"on"',
      "validateOn",
    ]) {
      expect(prompt).toContain(keyword);
    }
    // Out of scope for v1: do not teach repeat / item scopes.
    expect(prompt).not.toContain("repeat");
    expect(prompt).not.toContain("$item");
  });

  it("teaches chart datum bindings and chart presentation options", () => {
    const dynamic = prompt.split("DYNAMIC VALUES")[1]!.split("CHECK TYPES")[0]!;
    expect(dynamic).toContain('{ "$datum": "" }');
    expect(dynamic).toContain("index, label, value, records, fraction?");
    expect(dynamic).toContain('"$datum": "/records/0/filter"');
    for (const explanation of ["horizontal: true puts categories on the vertical axis", "maxCategories includes the Other slot", "otherLabel names the folded group", "accessibilitySummary describes the chart for VoiceOver"]) {
      expect(prompt).toContain(explanation);
    }
  });

  it("numbers the schema rules followed by custom rules", () => {
    expect(schema.defaultRules).toEqual(swiftUIFormRules);
    const custom = catalog.prompt({
      customRules: ["Always add a phone field."],
    });
    expect(custom).toContain(
      `${swiftUIFormRules.length + 1}. Always add a phone field.`,
    );
    expect(custom.startsWith(prompt.split("\nRULES:")[0]!)).toBe(true);
  });

  it("only offers validateOn on components that list it", () => {
    expect(prompt).toContain(
      'components that list "validateOn" accept "change" | "blur" | "submit"',
    );
    expect(prompt).toContain(
      "Stepper and Slider have no validateOn and validate on submit only",
    );
    expect(prompt).toContain(
      '"enabled": <visibility condition> runs the checks',
    );
    expect(prompt).toContain("enabled?: Condition");
    for (const line of prompt.split("\n")) {
      if (line.startsWith("- Stepper:") || line.startsWith("- Slider:")) {
        expect(line).not.toContain("validateOn");
      }
    }
  });

  it("supports inline mode", () => {
    const inline = catalog.prompt({ mode: "inline" });
    expect(inline).toContain("```spec");
    expect(inline).not.toContain("Output ONLY JSONL");
  });

  it("matches docs/system-prompt.sample.txt (run `pnpm gen:prompt` after changing the prompt)", () => {
    const sample = readText(join(repoDir, "docs", "system-prompt.sample.txt"));
    expect(sample).toBe(`${prompt}\n`);
  });
});

describe("user prompt", () => {
  it("includes the current spec for edits", () => {
    const currentSpec = readJSON<
      Parameters<typeof buildUserPrompt>[0]["currentSpec"]
    >(join(specsDir, "registration.json"));
    const prompt = buildUserPrompt({
      prompt: "Add a phone number field",
      currentSpec,
    });
    expect(prompt).toContain("CURRENT UI STATE");
    expect(prompt).toContain('"confirm-password"');
    expect(prompt).toContain("USER REQUEST: Add a phone number field");
  });
});
