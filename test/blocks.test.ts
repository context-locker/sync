import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  BLOCK_END,
  BLOCK_START,
  BrokenBlockError,
  blockHash,
  extractBlock,
  findBlock,
  spliceBlock,
} from "../src/index.js";

const block = (body: string) => `${BLOCK_START}\n${body}\n${BLOCK_END}\n`;

describe("finding a managed block", () => {
  it("pairs one start marker with one end marker", () => {
    assert.deepEqual(findBlock(["a", BLOCK_START, "x", BLOCK_END, "b"]), {
      found: true,
      start: 1,
      end: 3,
    });
  });

  it("allows trailing spaces, a carriage return and a later version", () => {
    assert.deepEqual(
      findBlock(["<!-- context-locker:start v2 -->  ", "x", `${BLOCK_END}\r`]),
      { found: true, start: 0, end: 2 },
    );
  });

  it("only counts markers that are whole lines", () => {
    assert.deepEqual(findBlock([`- note: ${BLOCK_START}`, "x"]), {
      found: false,
      broken: false,
    });
  });

  it("calls markers that don't pair up exactly once broken", () => {
    const broken = { found: false, broken: true };
    assert.deepEqual(findBlock([BLOCK_START, "x"]), broken);
    assert.deepEqual(findBlock(["x", BLOCK_END]), broken);
    assert.deepEqual(findBlock([BLOCK_END, BLOCK_START]), broken);
    assert.deepEqual(
      findBlock([BLOCK_START, BLOCK_END, BLOCK_START, BLOCK_END]),
      broken,
    );
  });
});

describe("splicing a managed block", () => {
  const fresh = block("new");

  it("creates the content of an empty file", () => {
    assert.equal(spliceBlock("", fresh), fresh);
    assert.equal(spliceBlock("\n\n", fresh), fresh);
  });

  it("adds a block after a blank line, keeping the file as it was", () => {
    assert.equal(spliceBlock("# Mine\n", fresh), `# Mine\n\n${fresh}`);
    assert.equal(spliceBlock("# Mine", fresh), `# Mine\n\n${fresh}`);
  });

  it("replaces only what's between the markers", () => {
    const file = `# Mine\r\n\r\n${block("old")}\nAfter\n`;
    assert.equal(spliceBlock(file, fresh), `# Mine\r\n\r\n${fresh}\nAfter\n`);
  });

  it("keeps a file that doesn't end with a newline as it was", () => {
    const file = `${block("old")}tail`;
    assert.equal(spliceBlock(file, fresh), `${fresh}tail`);
  });

  it("takes a block out with one blank line beside it", () => {
    assert.equal(spliceBlock(`# Mine\n\n${block("old")}`, null), "# Mine\n");
    assert.equal(spliceBlock(`${block("old")}\n# Mine\n`, null), "# Mine\n");
    assert.equal(spliceBlock(`A\n\n${block("old")}\nB\n`, null), "A\n\nB\n");
    assert.equal(spliceBlock(block("old"), null), "");
  });

  it("leaves a file with no block alone when taking one out", () => {
    assert.equal(spliceBlock("# Mine\n", null), "# Mine\n");
  });

  it("refuses a file whose markers are broken", () => {
    assert.throws(
      () => spliceBlock(`${BLOCK_START}\nhalf\n`, fresh),
      BrokenBlockError,
    );
  });

  it("round-trips: what it splices in is what extracting finds", () => {
    const file = spliceBlock("# Mine\n", fresh);
    assert.equal(extractBlock(file), fresh);
    assert.equal(extractBlock("# Mine\n"), null);
  });
});

describe("a block's hash", () => {
  it("ignores carriage returns", () => {
    assert.equal(blockHash(fresh()), blockHash(fresh().replace(/\n/g, "\r\n")));
  });

  function fresh() {
    return block("- a: b");
  }
});
